-- #########################################################################
-- Module Name : dwkit.services.roomentities_service
-- Owner       : Services
-- Version     : v2026-01-17B
-- Purpose     :
--   - SAFE, profile-portable RoomEntitiesService (data only).
--   - No GMCP dependency, no Mudlet events, no timers, no send().
--   - Emits a registered internal event when state changes.
--   - Provides manual ingestion helpers for "look" output parsing.
--   - Classification (best-effort, SAFE):
--       - Presence-assisted classification during ingest (existing).
--       - WhoStore-assisted classification during ingest (NEW).
--       - AUTO reclassify on WhoStore updates (NEW "superpower"):
--           When WhoStore player set updates, we re-bucket current entities
--           (unknown/mobs/items -> players) when names are now known players,
--           and emit RoomEntities Updated only if state actually changes.
--
-- Public API  :
--   - getVersion() -> string
--   - getState() -> table copy
--   - setState(newState, opts?) -> boolean ok, string|nil err
--   - update(delta, opts?) -> boolean ok, string|nil err
--   - clear(opts?) -> boolean ok, string|nil err
--   - onUpdated(handlerFn) -> boolean ok, number|nil token, string|nil err
--   - getStats() -> table
--   - getUpdatedEventName() -> string
--   - ingestLookLines(lines, opts?) -> boolean ok, string|nil err
--   - ingestLookText(text, opts?) -> boolean ok, string|nil err
--   - reclassifyFromWhoStore(opts?) -> boolean ok, string|nil err
--
-- Events Emitted:
--   - DWKit:Service:RoomEntities:Updated
-- Automation Policy: Manual only (no gameplay commands). WhoStore reclassify is event-driven.
-- Dependencies     : dwkit.core.identity, dwkit.bus.event_bus
-- #########################################################################

local M = {}

M.VERSION = "v2026-01-17B"

local ID = require("dwkit.core.identity")
local BUS = require("dwkit.bus.event_bus")

local EV_UPDATED = tostring(ID.eventPrefix or "DWKit:") .. "Service:RoomEntities:Updated"

-- Expose event name for UIs and consumers (contract)
M.EV_UPDATED = EV_UPDATED

local STATE = {
    state = {},
    lastTs = nil,
    updates = 0,
    emits = 0,
    suppressedEmits = 0,
}

local function _trim(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function _normName(s)
    s = _trim(s or "")
    if s == "" then return "" end
    return s:lower()
end

local function _shallowCopy(t)
    local out = {}
    if type(t) ~= "table" then return out end
    for k, v in pairs(t) do out[k] = v end
    return out
end

-- shallow copy with 1-level copy for nested tables (good enough for buckets)
local function _copyOneLevel(t)
    local out = {}
    if type(t) ~= "table" then return out end
    for k, v in pairs(t) do
        if type(v) == "table" then
            local inner = {}
            for kk, vv in pairs(v) do inner[kk] = vv end
            out[k] = inner
        else
            out[k] = v
        end
    end
    return out
end

local function _merge(dst, src)
    if type(dst) ~= "table" or type(src) ~= "table" then return end
    for k, v in pairs(src) do
        dst[k] = v
    end
end

local function _emit(stateCopy, deltaCopy, source)
    local payload = {
        ts = os.time(),
        state = stateCopy,
    }
    if type(deltaCopy) == "table" then payload.delta = deltaCopy end
    if type(source) == "string" and source ~= "" then payload.source = source end

    local ok, delivered, errs = BUS.emit(EV_UPDATED, payload)
    if not ok then
        local first = (type(errs) == "table" and errs[1]) and tostring(errs[1]) or "emit failed"
        return false, first
    end
    return true, nil
end

local function _newBuckets()
    return {
        players = {},
        mobs = {},
        items = {},
        unknown = {},
    }
end

local function _asKey(s)
    s = _trim(s or "")
    if s == "" then return nil end
    return s
end

local function _addBucket(bucket, key)
    if type(bucket) ~= "table" then return end
    if type(key) ~= "string" or key == "" then return end
    bucket[key] = true
end

local function _bucketKeysEqual(a, b)
    if type(a) ~= "table" then a = {} end
    if type(b) ~= "table" then b = {} end

    -- count a
    local ca = 0
    for _ in pairs(a) do ca = ca + 1 end

    -- count b + ensure all keys exist in a
    local cb = 0
    for k in pairs(b) do
        cb = cb + 1
        if a[k] ~= true then
            return false
        end
    end

    if ca ~= cb then
        return false
    end

    -- ensure all keys exist in b
    for k in pairs(a) do
        if b[k] ~= true then
            return false
        end
    end

    return true
end

local function _statesEqual(s1, s2)
    if type(s1) ~= "table" then s1 = {} end
    if type(s2) ~= "table" then s2 = {} end

    -- treat missing buckets as empty
    if not _bucketKeysEqual(s1.players, s2.players) then return false end
    if not _bucketKeysEqual(s1.mobs, s2.mobs) then return false end
    if not _bucketKeysEqual(s1.items, s2.items) then return false end
    if not _bucketKeysEqual(s1.unknown, s2.unknown) then return false end

    -- if there are extra top-level keys beyond buckets, compare them shallowly
    local known = { players = true, mobs = true, items = true, unknown = true }

    for k, v in pairs(s1) do
        if not known[k] then
            if s2[k] ~= v then return false end
        end
    end
    for k, v in pairs(s2) do
        if not known[k] then
            if s1[k] ~= v then return false end
        end
    end

    return true
end

-- Presence-assisted known-player extraction (best-effort, SAFE)
-- We do NOT assume any specific PresenceService schema.
-- If PresenceService is unavailable or state shape is unknown, we return empty set.
local function _safeRequire(modName)
    local ok, mod = pcall(require, modName)
    if ok then return true, mod end
    return false, mod
end

local function _addToSet(set, name)
    if type(set) ~= "table" then return end
    if type(name) ~= "string" then return end
    local key = _normName(name)
    if key == "" then return end
    set[key] = true
end

local function _isArrayTable(t)
    if type(t) ~= "table" then return false end
    for k in pairs(t) do
        if type(k) ~= "number" then
            return false
        end
    end
    return true
end

local function _absorbNamesFromTable(set, t)
    if type(set) ~= "table" or type(t) ~= "table" then return end

    if _isArrayTable(t) then
        for _, v in ipairs(t) do
            if type(v) == "string" then
                _addToSet(set, v)
            elseif type(v) == "table" and type(v.name) == "string" then
                _addToSet(set, v.name)
            end
        end
        return
    end

    for k, v in pairs(t) do
        if type(k) == "string" then
            if v == true then
                _addToSet(set, k)
            elseif type(v) == "string" then
                _addToSet(set, v)
            elseif type(v) == "table" then
                if type(v.name) == "string" then
                    _addToSet(set, v.name)
                end
            end
        elseif type(v) == "string" then
            _addToSet(set, v)
        elseif type(v) == "table" and type(v.name) == "string" then
            _addToSet(set, v.name)
        end
    end
end

local function _extractKnownPlayersSetFromPresenceState(pState)
    local set = {}
    if type(pState) ~= "table" then
        return set
    end

    -- If presence state itself is already a set/list of names
    _absorbNamesFromTable(set, pState)

    -- Common candidate keys (best-effort)
    local keys = { "players", "nearby", "present", "who", "names", "list" }
    for _, k in ipairs(keys) do
        local v = pState[k]
        if type(v) == "table" then
            _absorbNamesFromTable(set, v)
        end
    end

    return set
end

local function _getKnownPlayersSetBestEffort(opts)
    opts = (type(opts) == "table") and opts or {}

    -- Caller may explicitly supply known players (highest priority)
    if type(opts.knownPlayers) == "table" then
        local set = {}
        _absorbNamesFromTable(set, opts.knownPlayers)
        return set
    end

    -- Opt-out switch (if caller wants pure heuristics)
    if opts.usePresence ~= nil and opts.usePresence ~= true then
        return {}
    end

    local okP, P = _safeRequire("dwkit.services.presence_service")
    if not okP or type(P) ~= "table" then
        return {}
    end

    if type(P.getState) ~= "function" then
        return {}
    end

    local okS, pState = pcall(P.getState)
    if not okS or type(pState) ~= "table" then
        return {}
    end

    return _extractKnownPlayersSetFromPresenceState(pState)
end

local function _isKnownPlayer(name, knownPlayersSet)
    if type(knownPlayersSet) ~= "table" then return false end
    local key = _normName(name)
    if key == "" then return false end
    return (knownPlayersSet[key] == true)
end

-- WhoStore-assisted known-player extraction (best-effort, SAFE)
-- We treat WhoStore player set as authoritative for "is this a player name".
local function _extractKnownPlayersSetFromWhoStoreState(wState)
    local set = {}
    if type(wState) ~= "table" then
        return set
    end

    -- Common shape: wState.players is map {Name=true} or list {"Name", ...}
    if type(wState.players) == "table" then
        _absorbNamesFromTable(set, wState.players)
    else
        -- Sometimes the state table itself might be a set/list
        _absorbNamesFromTable(set, wState)
    end

    return set
end

local function _getWhoStoreKnownPlayersSetBestEffort()
    local okW, W = _safeRequire("dwkit.services.whostore_service")
    if not okW or type(W) ~= "table" then
        return {}
    end
    if type(W.getState) ~= "function" then
        return {}
    end

    local okS, wState = pcall(W.getState)
    if not okS or type(wState) ~= "table" then
        return {}
    end

    return _extractKnownPlayersSetFromWhoStoreState(wState)
end

-- Combine known players from Presence + WhoStore (WhoStore is authoritative when present)
local function _getKnownPlayersSetCombined(opts)
    opts = (type(opts) == "table") and opts or {}

    -- Caller may override explicitly (highest priority)
    if type(opts.knownPlayers) == "table" then
        local set = {}
        _absorbNamesFromTable(set, opts.knownPlayers)
        return set
    end

    local set = {}

    -- Presence (optional)
    if opts.usePresence == nil or opts.usePresence == true then
        local pSet = _getKnownPlayersSetBestEffort(opts)
        _merge(set, pSet)
    end

    -- WhoStore (optional; default true)
    if opts.useWhoStore == nil or opts.useWhoStore == true then
        local wSet = _getWhoStoreKnownPlayersSetBestEffort()
        _merge(set, wSet)
    end

    return set
end

-- Very light, SAFE heuristics for look-line classification.
-- This is intentionally conservative; improved using PresenceService / WhoStore over time.
local function _classifyLookLine(line, opts, knownPlayersSet)
    opts = (type(opts) == "table") and opts or {}
    line = _trim(line or "")
    if line == "" then return nil, nil end

    -- ignore common non-entity look lines
    local lower = line:lower()
    if lower == "you see nothing special." then return nil, nil end
    if lower:find("^exits:") then return nil, nil end

    -- pattern: "<Name> is standing here."
    do
        local name = line:match("^(.-)%s+is%s+standing%s+here%.$")
        if type(name) == "string" then
            name = _trim(name)
            if name ~= "" then
                -- Known player classification (Presence/WhoStore)
                if _isKnownPlayer(name, knownPlayersSet) then
                    return "players", _asKey(name)
                end

                -- optional heuristic: capitalized => player
                if opts.assumeCapitalizedAsPlayer == true then
                    local first = name:sub(1, 1)
                    if first:match("%u") then
                        return "players", _asKey(name)
                    end
                end

                -- otherwise unknown until Presence/Who is integrated
                return "unknown", _asKey(name)
            end
        end
    end

    -- pattern: "<something> is here."
    do
        local thing = line:match("^(.-)%s+is%s+here%.$")
        if type(thing) == "string" then
            thing = _trim(thing)
            if thing ~= "" then
                -- Known player classification (Presence/WhoStore)
                if _isKnownPlayer(thing, knownPlayersSet) then
                    return "players", _asKey(thing)
                end

                -- corpses/items are usually not mobs
                if lower:find("corpse") then
                    return "items", _asKey(thing)
                end

                -- crude: "a/an/the ..." tends to be NPC/mob, but can be items too.
                if thing:lower():match("^(a%s+)") or thing:lower():match("^(an%s+)") or thing:lower():match("^(the%s+)") then
                    -- if it looks like an object keyword, push to items (very light)
                    if lower:find("sword") or lower:find("shield") or lower:find("scroll") or lower:find("potion") then
                        return "items", _asKey(thing)
                    end
                    return "mobs", _asKey(thing)
                end

                return "unknown", _asKey(thing)
            end
        end
    end

    -- fallback rules
    if lower:find("corpse") then
        return "items", _asKey(line)
    end

    return "unknown", _asKey(line)
end

-- ############################################################
-- WhoStore "superpower" wiring (SAFE):
--   - Subscribe to WhoStore Updated event (best-effort)
--   - Reclassify current buckets when new players become known
-- ############################################################

local _who = {
    subscribed = false,
    token = nil,
    eventName = nil,
    lastErr = nil,
    reclassifyRunning = false,
}

local function _resolveWhoStoreUpdatedEventName(W)
    if type(W) ~= "table" then return nil end
    if type(W.getUpdatedEventName) == "function" then
        local ok, v = pcall(W.getUpdatedEventName)
        if ok and type(v) == "string" and v ~= "" then
            return v
        end
    end
    if type(W.EV_UPDATED) == "string" and W.EV_UPDATED ~= "" then
        return W.EV_UPDATED
    end
    return nil
end

local function _reclassifyBucketsWithKnownPlayers(current, knownPlayersSet)
    current = (type(current) == "table") and current or {}
    knownPlayersSet = (type(knownPlayersSet) == "table") and knownPlayersSet or {}

    local next = _newBuckets()

    local function moveIfKnown(name)
        if type(name) ~= "string" or name == "" then return false end
        local key = _normName(name)
        if key == "" then return false end
        if knownPlayersSet[key] == true then
            next.players[name] = true
            return true
        end
        return false
    end

    local moved = 0

    -- players bucket always preserved
    if type(current.players) == "table" then
        for k, v in pairs(current.players) do
            if v == true and type(k) == "string" and k ~= "" then
                next.players[k] = true
            end
        end
    end

    -- unknown -> players if known; else unknown
    if type(current.unknown) == "table" then
        for k, v in pairs(current.unknown) do
            if v == true and type(k) == "string" and k ~= "" then
                if moveIfKnown(k) then
                    moved = moved + 1
                else
                    next.unknown[k] = true
                end
            end
        end
    end

    -- mobs -> players if known; else mobs
    if type(current.mobs) == "table" then
        for k, v in pairs(current.mobs) do
            if v == true and type(k) == "string" and k ~= "" then
                if moveIfKnown(k) then
                    moved = moved + 1
                else
                    next.mobs[k] = true
                end
            end
        end
    end

    -- items -> players if known; else items
    if type(current.items) == "table" then
        for k, v in pairs(current.items) do
            if v == true and type(k) == "string" and k ~= "" then
                if moveIfKnown(k) then
                    moved = moved + 1
                else
                    next.items[k] = true
                end
            end
        end
    end

    return next, moved
end

local function _applyReclassifyNow(opts)
    opts = (type(opts) == "table") and opts or {}

    if _who.reclassifyRunning == true then
        return true, nil
    end

    _who.reclassifyRunning = true

    local knownPlayersSet = _getWhoStoreKnownPlayersSetBestEffort()
    local before = _copyOneLevel(STATE.state)

    local next, moved = _reclassifyBucketsWithKnownPlayers(before, knownPlayersSet)

    if opts.forceEmit ~= true and _statesEqual(before, next) then
        STATE.suppressedEmits = STATE.suppressedEmits + 1
        _who.reclassifyRunning = false
        return true, nil
    end

    STATE.state = _copyOneLevel(next)
    STATE.lastTs = os.time()
    STATE.updates = STATE.updates + 1

    local src = tostring(opts.source or "reclassify:whostore")
    local delta = { reclassified = moved }

    local okEmit, errEmit = _emit(_copyOneLevel(STATE.state), delta, src)
    if not okEmit then
        _who.reclassifyRunning = false
        return false, errEmit
    end

    STATE.emits = STATE.emits + 1
    _who.reclassifyRunning = false
    return true, nil
end

local function _ensureWhoStoreSubscription()
    if _who.subscribed == true then
        return true, nil
    end

    -- Must have an event bus with .on
    if type(BUS) ~= "table" or type(BUS.on) ~= "function" then
        _who.lastErr = "event bus .on not available"
        return false, _who.lastErr
    end

    local okW, W = _safeRequire("dwkit.services.whostore_service")
    if not okW or type(W) ~= "table" then
        _who.lastErr = "WhoStoreService not available"
        return false, _who.lastErr
    end

    local evName = _resolveWhoStoreUpdatedEventName(W)
    if type(evName) ~= "string" or evName == "" then
        _who.lastErr = "WhoStore updated event name not available"
        return false, _who.lastErr
    end

    local handlerFn = function(payload)
        -- SAFE: reclassify current state if WhoStore changed
        -- No printing, no gameplay commands, no timers.
        _applyReclassifyNow({ source = "whostore:updated" })
    end

    local okSub, tokenOrErr, maybeErr = BUS.on(evName, handlerFn)
    if okSub ~= true then
        _who.lastErr = tostring(maybeErr or tokenOrErr or "WhoStore subscribe failed")
        return false, _who.lastErr
    end

    _who.subscribed = true
    _who.token = tokenOrErr
    _who.eventName = evName
    _who.lastErr = nil
    return true, nil
end

function M.getVersion()
    return tostring(M.VERSION)
end

function M.getUpdatedEventName()
    return tostring(EV_UPDATED)
end

function M.getState()
    return _copyOneLevel(STATE.state)
end

function M.setState(newState, opts)
    opts = (type(opts) == "table") and opts or {}
    if type(newState) ~= "table" then
        return false, "setState(newState): newState must be a table"
    end

    local nextState = _copyOneLevel(newState)

    if opts.forceEmit ~= true and _statesEqual(STATE.state, nextState) then
        STATE.suppressedEmits = STATE.suppressedEmits + 1
        return true, nil
    end

    STATE.state = nextState
    STATE.lastTs = os.time()
    STATE.updates = STATE.updates + 1

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

    local before = _copyOneLevel(STATE.state)

    _merge(STATE.state, delta)
    local after = _copyOneLevel(STATE.state)

    if opts.forceEmit ~= true and _statesEqual(before, after) then
        STATE.suppressedEmits = STATE.suppressedEmits + 1
        return true, nil
    end

    STATE.lastTs = os.time()
    STATE.updates = STATE.updates + 1

    local okEmit, errEmit = _emit(_copyOneLevel(STATE.state), _copyOneLevel(delta), opts.source)
    if not okEmit then
        return false, errEmit
    end

    STATE.emits = STATE.emits + 1
    return true, nil
end

function M.clear(opts)
    opts = (type(opts) == "table") and opts or {}

    local before = _copyOneLevel(STATE.state)

    STATE.state = {}
    local after = _copyOneLevel(STATE.state)

    if opts.forceEmit ~= true and _statesEqual(before, after) then
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

function M.onUpdated(handlerFn)
    return BUS.on(EV_UPDATED, handlerFn)
end

-- Manual / callable "superpower": reclassify buckets from WhoStore right now
-- opts:
--   - source: string
--   - forceEmit: boolean
function M.reclassifyFromWhoStore(opts)
    opts = (type(opts) == "table") and opts or {}
    -- Ensure subscription exists (best-effort; no hard fail)
    _ensureWhoStoreSubscription()
    return _applyReclassifyNow({ source = opts.source or "manual:reclassify", forceEmit = (opts.forceEmit == true) })
end

-- Manual ingest helper: takes array of look lines
-- opts:
--   - source: string
--   - assumeCapitalizedAsPlayer: boolean
--   - usePresence: boolean (default true)
--   - useWhoStore: boolean (default true)
--   - knownPlayers: table (optional override; set/list of names)
--   - forceEmit: boolean
function M.ingestLookLines(lines, opts)
    opts = (type(opts) == "table") and opts or {}
    if type(lines) ~= "table" then
        return false, "ingestLookLines(lines): lines must be a table"
    end

    -- Best-effort: enable WhoStore subscription once module is used
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

-- Manual ingest helper: takes full look text, splits into lines
-- opts: same as ingestLookLines
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
    return {
        version = M.VERSION,
        lastTs = STATE.lastTs,
        updates = STATE.updates,
        emits = STATE.emits,
        suppressedEmits = STATE.suppressedEmits,
        keys = (function()
            local n = 0
            for _ in pairs(STATE.state) do n = n + 1 end
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

return M
