-- #########################################################################
-- Module Name : dwkit.services.roomentities_service
-- Owner       : Services
-- Version     : v2026-01-28A
-- Purpose     :
--   - Maintain best-effort "entities in the room" buckets derived from LOOK output
--   - Buckets: players, mobs, items, unknown
--   - Supports manual fixture ingest for testing
--   - Supports optional WhoStore boost for player classification (best-effort)
-- #########################################################################

local M = {}

M.VERSION = "v2026-01-28A"

local ID = require("dwkit.core.identity")
local BUS = require("dwkit.bus.event_bus")

local function _safeRequire(moduleName)
    local ok, modOrErr = pcall(require, moduleName)
    if ok then
        return true, modOrErr
    end
    return false, nil
end

local function _markRoomSnapshotBestEffort(source)
    -- Best-effort integration: inform RoomFeed status service that we have a fresh room snapshot.
    local okF, RF = _safeRequire("dwkit.services.roomfeed_status_service")
    if okF and type(RF) == "table" and type(RF.markSnapshot) == "function" then
        pcall(function()
            RF.markSnapshot(tostring(source or "svc:roomentities"))
        end)
    end
end

local function _copyOneLevel(t)
    local out = {}
    if type(t) ~= "table" then return out end
    for k, v in pairs(t) do out[k] = v end
    return out
end

local function _newBucket()
    return { list = {}, byKey = {} }
end

local function _ensureBucketPresent(state, name)
    if type(state[name]) ~= "table" then
        state[name] = _newBucket()
    end
    if type(state[name].list) ~= "table" then
        state[name].list = {}
    end
    if type(state[name].byKey) ~= "table" then
        state[name].byKey = {}
    end
    return state[name]
end

local function _ensureBucketsPresent(state)
    state = (type(state) == "table") and state or {}
    _ensureBucketPresent(state, "players")
    _ensureBucketPresent(state, "mobs")
    _ensureBucketPresent(state, "items")
    _ensureBucketPresent(state, "unknown")
    return state
end

local function _bucketCounts(state)
    state = _ensureBucketsPresent(state)

    local function nOf(bucket)
        local b = state[bucket]
        if type(b) ~= "table" or type(b.list) ~= "table" then return 0 end
        return #b.list
    end

    return {
        players = nOf("players"),
        mobs = nOf("mobs"),
        items = nOf("items"),
        unknown = nOf("unknown"),
    }
end

local function _sortCaseInsensitive(list)
    table.sort(list, function(a, b)
        return tostring(a):lower() < tostring(b):lower()
    end)
end

local function _normalizeKey(s)
    s = tostring(s or "")
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    return s
end

local function _addBucket(bucket, key)
    if type(bucket) ~= "table" then return end
    key = _normalizeKey(key)
    if key == "" then return end
    if bucket.byKey[key] == true then return end
    bucket.byKey[key] = true
    bucket.list[#bucket.list + 1] = key
end

local function _statesEqual(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return false end

    local keys = { "players", "mobs", "items", "unknown" }
    for _, k in ipairs(keys) do
        local la = (type(a[k]) == "table" and type(a[k].list) == "table") and a[k].list or {}
        local lb = (type(b[k]) == "table" and type(b[k].list) == "table") and b[k].list or {}
        if #la ~= #lb then return false end
        for i = 1, #la do
            if tostring(la[i]) ~= tostring(lb[i]) then
                return false
            end
        end
    end

    return true
end

M.EV_UPDATED = tostring(ID.eventPrefix or "DWKit:") .. "RoomEntities:Updated"

local STATE = {
    state = _ensureBucketsPresent({}),
    lastTs = nil,
    updates = 0,
    emits = 0,
    suppressedEmits = 0,
}

local _who = {
    subscribed = false,
    eventName = nil,
    token = nil,
    lastErr = nil,
}

local function _emit(state, delta, source)
    if type(BUS) ~= "table" or type(BUS.emit) ~= "function" then
        return false, "event bus unavailable"
    end

    local payload = {
        state = state,
        delta = delta,
        counts = _bucketCounts(state),
        ts = os.time(),
        updates = STATE.updates,
        emits = STATE.emits,
        suppressedEmits = STATE.suppressedEmits,
    }

    local meta = {
        source = tostring(source or "unknown"),
        service = "dwkit.services.roomentities_service",
        version = tostring(M.VERSION),
    }

    local ok, err = pcall(function()
        BUS.emit(M.EV_UPDATED, payload, meta)
    end)
    if not ok then
        return false, tostring(err or "emit failed")
    end
    return true, nil
end

local function _armWhoStoreSubscriptionBestEffort()
    if _who.subscribed == true then
        return true
    end

    local okWS, WhoStore = _safeRequire("dwkit.services.whostore_service")
    if not okWS or type(WhoStore) ~= "table" then
        _who.lastErr = "WhoStore not available"
        return false
    end

    local ok, evName = pcall(function()
        if type(WhoStore.getUpdatedEventName) == "function" then
            return WhoStore.getUpdatedEventName()
        end
        return nil
    end)
    if not ok or type(evName) ~= "string" or evName == "" then
        _who.lastErr = "WhoStore event name unavailable"
        return false
    end

    _who.eventName = evName

    if type(BUS) ~= "table" or type(BUS.subscribe) ~= "function" then
        _who.lastErr = "event bus unavailable"
        return false
    end

    local okS, tokenOrErr = pcall(function()
        return BUS.subscribe(_who.eventName, function(payload, meta)
            -- Best-effort: reclassify using WhoStore if enabled by caller; we do not auto-reclassify here to avoid surprises.
            -- This hook is retained for future integrations.
        end, { source = "svc:roomentities:whostore_sub" })
    end)
    if not okS or tokenOrErr == nil then
        _who.lastErr = tostring(tokenOrErr or "subscribe failed")
        return false
    end

    _who.token = tokenOrErr
    _who.subscribed = true
    _who.lastErr = nil
    return true
end

local function _ensureWhoStoreSubscription()
    if _who.subscribed ~= true then
        _armWhoStoreSubscriptionBestEffort()
    end
end

local function _getKnownPlayersSetCombined(opts)
    opts = (type(opts) == "table") and opts or {}
    if opts.useWhoStore ~= true then
        return nil
    end

    local okWS, WhoStore = _safeRequire("dwkit.services.whostore_service")
    if not okWS or type(WhoStore) ~= "table" then
        return nil
    end

    if type(WhoStore.getKnownPlayersSet) ~= "function" then
        return nil
    end

    local ok, set = pcall(function()
        return WhoStore.getKnownPlayersSet()
    end)
    if not ok or type(set) ~= "table" then
        return nil
    end

    return set
end

local function _classifyLookLine(raw, opts, knownPlayersSet)
    opts = (type(opts) == "table") and opts or {}
    local line = tostring(raw or "")
    line = line:gsub("^%s+", ""):gsub("%s+$", "")

    if line == "" then return nil, nil end

    -- Naive bucket heuristics: caller can override by injecting knownPlayersSet or by UI overrides.
    local key = line
    if knownPlayersSet and type(knownPlayersSet) == "table" then
        -- Best-effort: match exact key or lower case fallback
        if knownPlayersSet[key] == true then
            return "players", key
        end
        local low = key:lower()
        if knownPlayersSet[low] == true then
            return "players", key
        end
    end

    -- Very simple heuristic; real rules can be refined later.
    if line:find("%[") and line:find("%]") then
        return "players", key
    end

    return "unknown", key
end

local function _newBuckets()
    local buckets = _ensureBucketsPresent({})
    buckets.players.list = {}
    buckets.players.byKey = {}
    buckets.mobs.list = {}
    buckets.mobs.byKey = {}
    buckets.items.list = {}
    buckets.items.byKey = {}
    buckets.unknown.list = {}
    buckets.unknown.byKey = {}
    return buckets
end

function M.getVersion()
    return tostring(M.VERSION)
end

function M.getUpdatedEventName()
    return tostring(M.EV_UPDATED)
end

function M.getState()
    local s = _ensureBucketsPresent(STATE.state)
    return _copyOneLevel(s)
end

function M.getCounts()
    return _bucketCounts(STATE.state)
end

function M.setState(newState, opts)
    opts = (type(opts) == "table") and opts or {}
    if type(newState) ~= "table" then
        return false, "setState(newState): newState must be a table"
    end

    _armWhoStoreSubscriptionBestEffort()

    local nextState = _copyOneLevel(newState)
    nextState = _ensureBucketsPresent(nextState)

    local before = _ensureBucketsPresent(STATE.state)

    if opts.forceEmit ~= true and _statesEqual(before, nextState) then
        STATE.suppressedEmits = STATE.suppressedEmits + 1
        return true, nil
    end

    STATE.state = nextState
    STATE.lastTs = os.time()
    STATE.updates = STATE.updates + 1

    _markRoomSnapshotBestEffort(opts.source)

    local okEmit, errEmit = _emit(_copyOneLevel(STATE.state), nil, opts.source)
    if not okEmit then
        return false, errEmit
    end

    STATE.emits = STATE.emits + 1
    return true, nil
end

function M.update(delta, opts)
    opts = (type(opts) == "table") and opts or {}
    if type(delta) ~= "table" then
        return false, "update(delta): delta must be a table"
    end

    _armWhoStoreSubscriptionBestEffort()

    STATE.state = _ensureBucketsPresent(STATE.state)

    local before = _copyOneLevel(STATE.state)

    local keys = { "players", "mobs", "items", "unknown" }
    for _, b in ipairs(keys) do
        if type(delta[b]) == "table" then
            for _, key in ipairs(delta[b]) do
                _addBucket(STATE.state[b], key)
            end
        end
    end

    -- normalize
    for _, b in ipairs(keys) do
        _sortCaseInsensitive(STATE.state[b].list)
    end

    if opts.forceEmit ~= true and _statesEqual(before, STATE.state) then
        STATE.suppressedEmits = STATE.suppressedEmits + 1
        return true, nil
    end

    STATE.lastTs = os.time()
    STATE.updates = STATE.updates + 1

    local okEmit, errEmit = _emit(_copyOneLevel(STATE.state), delta, opts.source)
    if not okEmit then
        return false, errEmit
    end

    STATE.emits = STATE.emits + 1
    return true, nil
end

function M.clear(opts)
    opts = (type(opts) == "table") and opts or {}

    _armWhoStoreSubscriptionBestEffort()

    STATE.state = _ensureBucketsPresent(STATE.state)
    local before = _copyOneLevel(STATE.state)

    STATE.state.players.list = {}
    STATE.state.players.byKey = {}

    STATE.state.mobs.list = {}
    STATE.state.mobs.byKey = {}

    STATE.state.items.list = {}
    STATE.state.items.byKey = {}

    STATE.state.unknown.list = {}
    STATE.state.unknown.byKey = {}

    if opts.forceEmit ~= true and _statesEqual(before, STATE.state) then
        STATE.suppressedEmits = STATE.suppressedEmits + 1
        return true, nil
    end

    STATE.lastTs = os.time()
    STATE.updates = STATE.updates + 1

    local okEmit, errEmit = _emit(_copyOneLevel(STATE.state), { cleared = true }, opts.source)
    if not okEmit then
        return false, errEmit
    end

    STATE.emits = STATE.emits + 1
    return true, nil
end

function M.ingestFixture(name, opts)
    opts = (type(opts) == "table") and opts or {}
    name = tostring(name or "")

    local fixtures = {
        small = {
            "Players",
            "------",
            "[ 50 Cle ] Snorrin ZZZZZVo tezzzz of Snert Industries",
            "[ 22 War ] Hammar <-- down",
            "A huge ogre.",
            "A brass lantern",
        },
    }

    local f = fixtures[name]
    if type(f) ~= "table" then
        return false, "unknown fixture: " .. tostring(name)
    end

    local buckets = _newBuckets()
    for _, raw in ipairs(f) do
        local bucketName, key = _classifyLookLine(raw, opts, nil)
        if bucketName and key then
            _addBucket(buckets[bucketName], key)
        end
    end

    return M.setState(buckets, { source = opts.source or "ingestFixture:" .. name, forceEmit = (opts.forceEmit == true) })
end

function M.ingestLookLines(lines, opts)
    opts = (type(opts) == "table") and opts or {}
    if type(lines) ~= "table" then
        return false, "ingestLookLines(lines): lines must be a table"
    end

    _ensureWhoStoreSubscription()

    local knownPlayersSet = _getKnownPlayersSetCombined(opts)
    local buckets = _newBuckets()

    for _, raw in ipairs(lines) do
        local bucketName, key = _classifyLookLine(raw, opts, knownPlayersSet)
        if bucketName and key then
            _addBucket(buckets[bucketName], key)
        end
    end

    return M.setState(buckets, { source = opts.source or "ingestLookLines", forceEmit = (opts.forceEmit == true) })
end

function M.ingestLookText(text, opts)
    opts = (type(opts) == "table") and opts or {}
    if type(text) ~= "string" then
        return false, "ingestLookText(text): text must be a string"
    end

    local lines = {}
    for line in tostring(text):gmatch("[^\r\n]+") do
        lines[#lines + 1] = line
    end

    return M.ingestLookLines(lines, opts)
end

function M.getStats()
    local s = _ensureBucketsPresent(STATE.state)

    return {
        version = M.VERSION,
        lastTs = STATE.lastTs,
        updates = STATE.updates,
        emits = STATE.emits,
        suppressedEmits = STATE.suppressedEmits,
        keys = (function()
            local n = 0
            for _ in pairs(s) do n = n + 1 end
            return n
        end)(),
        who = {
            subscribed = (_who.subscribed == true),
            eventName = _who.eventName,
            hasToken = (_who.token ~= nil),
            lastErr = _who.lastErr,
        },
    }
end

-- Arm subscription at module load (best-effort) so init() immediately reflects subscribed=true
-- when WhoStore + BUS are available.
_armWhoStoreSubscriptionBestEffort()

return M
