-- #########################################################################
-- Module Name : dwkit.services.roomentities_service
-- Owner       : Services
-- Version     : v2026-01-18A
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
--   - NEW (v2026-01-17E):
--       - Known-player prefix matching:
--           "Scynox the adventurer" becomes player "Scynox" if WhoStore knows Scynox.
--           "Borai hates ..." becomes player "Borai" if WhoStore knows Borai.
--       - Reclassify also canonicalizes keys (renames bucket entries) when prefix matches.
--
--   - NEW (v2026-01-17F):
--       - Ignore non-entity look lines:
--           room title, indented description lines, and exit direction rows.
--       - Better items classification for common room objects:
--           board/bulletin/keg/mechanism/etc => items
--
--   - FIX (v2026-01-17G):
--       - Do NOT discard indented entity lines.
--         Some clipboard/capture flows indent ALL lines.
--         If an indented line contains "is here." or "standing here.", treat as entity.
--
--   - NEW (v2026-01-17H):
--       - Support more player postures:
--           standing/sitting/sleeping/resting/kneeling/meditating.
--       - Opt-in ingestion noise filters (caller-controlled):
--           opts.ignorePatterns (Lua patterns) + opts.ignoreSubstrings (plain contains).
--
--   - NEW (v2026-01-18A):
--       - Normalize internal state to ALWAYS contain the 4 buckets:
--           players/mobs/items/unknown (even after clear()).
--         This avoids consumers handling nil buckets and makes state equality stable.
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

M.VERSION = "v2026-01-18A"

local ID = require("dwkit.core.identity")
local BUS = require("dwkit.bus.event_bus")

local EV_UPDATED = tostring(ID.eventPrefix or "DWKit:") .. "Service:RoomEntities:Updated"

-- Expose event name for UIs and consumers (contract)
M.EV_UPDATED = EV_UPDATED

local function _newBuckets()
    return {
        players = {},
        mobs = {},
        items = {},
        unknown = {},
    }
end

local function _ensureBucketsPresent(s)
    if type(s) ~= "table" then
        return _newBuckets()
    end
    if type(s.players) ~= "table" then s.players = {} end
    if type(s.mobs) ~= "table" then s.mobs = {} end
    if type(s.items) ~= "table" then s.items = {} end
    if type(s.unknown) ~= "table" then s.unknown = {} end
    return s
end

local STATE = {
    state = _newBuckets(),
    lastTs = nil,
    updates = 0,
    emits = 0,
    suppressedEmits = 0,
}

-- Supported player postures in "is <posture> here."
local POSTURES = {
    standing = true,
    sitting = true,
    sleeping = true,
    resting = true,
    kneeling = true,
    meditating = true,
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

    local ca = 0
    for _ in pairs(a) do ca = ca + 1 end

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

    for k in pairs(a) do
        if b[k] ~= true then
            return false
        end
    end

    return true
end

local function _statesEqual(s1, s2)
    s1 = _ensureBucketsPresent((type(s1) == "table") and s1 or {})
    s2 = _ensureBucketsPresent((type(s2) == "table") and s2 or {})

    if not _bucketKeysEqual(s1.players, s2.players) then return false end
    if not _bucketKeysEqual(s1.mobs, s2.mobs) then return false end
    if not _bucketKeysEqual(s1.items, s2.items) then return false end
    if not _bucketKeysEqual(s1.unknown, s2.unknown) then return false end

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

    _absorbNamesFromTable(set, pState)

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

    if type(opts.knownPlayers) == "table" then
        local set = {}
        _absorbNamesFromTable(set, opts.knownPlayers)
        return set
    end

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

local function _extractKnownPlayersSetFromWhoStoreState(wState)
    local set = {}
    if type(wState) ~= "table" then
        return set
    end

    if type(wState.players) == "table" then
        _absorbNamesFromTable(set, wState.players)
    else
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

local function _getKnownPlayersSetCombined(opts)
    opts = (type(opts) == "table") and opts or {}

    if type(opts.knownPlayers) == "table" then
        local set = {}
        _absorbNamesFromTable(set, opts.knownPlayers)
        return set
    end

    local set = {}

    if opts.usePresence == nil or opts.usePresence == true then
        local pSet = _getKnownPlayersSetBestEffort(opts)
        _merge(set, pSet)
    end

    if opts.useWhoStore == nil or opts.useWhoStore == true then
        local wSet = _getWhoStoreKnownPlayersSetBestEffort()
        _merge(set, wSet)
    end

    return set
end

local function _extractKnownPlayerPrefixName(phrase, knownPlayersSet)
    if type(phrase) ~= "string" then return nil end
    if type(knownPlayersSet) ~= "table" then return nil end

    local raw = _trim(phrase)
    if raw == "" then return nil end

    local lower = raw:lower()

    for knownLower in pairs(knownPlayersSet) do
        if type(knownLower) == "string" and knownLower ~= "" then
            if lower:sub(1, #knownLower) == knownLower then
                local nextChar = lower:sub(#knownLower + 1, #knownLower + 1)
                if nextChar == "" or nextChar:match("%s") then
                    return _trim(raw:sub(1, #knownLower))
                end
            end
        end
    end

    return nil
end

local function _looksLikeExitRow(lineLower)
    if type(lineLower) ~= "string" then return false end
    return (lineLower:match("^(north|south|east|west|up|down)%s+%-%s+") ~= nil)
end

local function _looksLikeRoomTitle(line)
    if type(line) ~= "string" then return false end
    if line:find("%.") then return false end
    if #line > 60 then return false end
    if line:match("^%s+") then return false end
    if line:lower():find(" is here") or line:lower():find("standing here") then return false end
    if line:lower():find("^obvious exits:") then return false end
    if line:lower():find("^exits:") then return false end

    if line:match("^[%a%s']+$") then
        return true
    end
    return false
end

local function _isProbablyItemPhrase(phraseLower)
    if type(phraseLower) ~= "string" then return false end

    local itemKeys = {
        "board", "bulletin", "announcement", "keg", "mechanism", "altar",
        "portal", "sign", "plaque", "statue", "fountain", "table", "chair",
        "bench", "door", "gate", "lever", "switch", "chest", "bag",
        "scroll", "potion", "sword", "shield", "corpse",
    }

    for _, k in ipairs(itemKeys) do
        if phraseLower:find(k, 1, true) then
            return true
        end
    end

    return false
end

local function _isEntityishPostureLine(lowerTrimmed)
    if type(lowerTrimmed) ~= "string" then return false end

    -- quick accept "is here."
    if lowerTrimmed:find("is here%.", 1, true) ~= nil then
        return true
    end

    -- accept "is <posture> here."
    local posture = lowerTrimmed:match("^.-%s+is%s+(%a+)%s+here%.$")
    if type(posture) == "string" and posture ~= "" then
        if POSTURES[posture] == true then
            return true
        end
    end

    return false
end

local function _shouldIgnoreByCallerRules(trimmed, opts)
    opts = (type(opts) == "table") and opts or {}
    if type(trimmed) ~= "string" or trimmed == "" then
        return false
    end

    -- plain contains rules
    if type(opts.ignoreSubstrings) == "table" then
        for _, sub in ipairs(opts.ignoreSubstrings) do
            if type(sub) == "string" and sub ~= "" then
                if trimmed:find(sub, 1, true) ~= nil then
                    return true
                end
            end
        end
    end

    -- Lua pattern rules
    if type(opts.ignorePatterns) == "table" then
        for _, pat in ipairs(opts.ignorePatterns) do
            if type(pat) == "string" and pat ~= "" then
                local okMatch, res = pcall(function()
                    return (trimmed:match(pat) ~= nil)
                end)
                if okMatch and res == true then
                    return true
                end
            end
        end
    end

    return false
end

-- FIXED: indentation safety (v2026-01-17G)
-- Enhanced postures + opt-in noise filtering (v2026-01-17H)
local function _classifyLookLine(line, opts, knownPlayersSet)
    opts = (type(opts) == "table") and opts or {}
    if type(line) ~= "string" then return nil, nil end

    local rawLine = line
    local trimmed = _trim(line)
    if trimmed == "" then return nil, nil end

    -- Opt-in noise filter (caller-controlled)
    if _shouldIgnoreByCallerRules(trimmed, opts) then
        return nil, nil
    end

    local lowerTrimmed = trimmed:lower()

    -- If line is indented, it might be a description line OR it might be an entity line
    -- depending on clipboard/capture formatting.
    if rawLine:match("^%s%s%s+") then
        local isEntityish = _isEntityishPostureLine(lowerTrimmed)
        if not isEntityish then
            return nil, nil
        end
        -- else: allow it through as an entity line.
    end

    local lineClean = trimmed
    local lower = lowerTrimmed

    -- ignore common non-entity look lines
    if lower == "you see nothing special." then return nil, nil end
    if lower:find("^exits:") then return nil, nil end
    if lower:find("^obvious exits:") then return nil, nil end
    if _looksLikeExitRow(lower) then return nil, nil end

    -- common systemic messages (not prompts, but noise)
    if lower == "huh?!?" then return nil, nil end
    if lower == "you are hungry." then return nil, nil end
    if lower == "you are thirsty." then return nil, nil end

    if _looksLikeRoomTitle(lineClean) then
        return nil, nil
    end

    -- pattern: "<NamePhrase> is <posture> here."
    do
        local phrase, posture = lineClean:match("^(.-)%s+is%s+(%a+)%s+here%.$")
        if type(phrase) == "string" and type(posture) == "string" then
            posture = posture:lower()
            if POSTURES[posture] == true then
                phrase = _trim(phrase)
                if phrase ~= "" then
                    local canon = _extractKnownPlayerPrefixName(phrase, knownPlayersSet)
                    if canon then
                        return "players", _asKey(canon)
                    end

                    if _isKnownPlayer(phrase, knownPlayersSet) then
                        return "players", _asKey(phrase)
                    end

                    if opts.assumeCapitalizedAsPlayer == true then
                        local first = phrase:sub(1, 1)
                        if first:match("%u") then
                            return "players", _asKey(phrase)
                        end
                    end

                    return "unknown", _asKey(phrase)
                end
            end
        end
    end

    -- pattern: "<something> is here."
    do
        local phrase = lineClean:match("^(.-)%s+is%s+here%.$")
        if type(phrase) == "string" then
            phrase = _trim(phrase)
            if phrase ~= "" then
                local canon = _extractKnownPlayerPrefixName(phrase, knownPlayersSet)
                if canon then
                    return "players", _asKey(canon)
                end

                if _isKnownPlayer(phrase, knownPlayersSet) then
                    return "players", _asKey(phrase)
                end

                if lower:find("corpse") then
                    return "items", _asKey(phrase)
                end

                local pLower = phrase:lower()

                if pLower:match("^(a%s+)") or pLower:match("^(an%s+)") or pLower:match("^(the%s+)") then
                    if _isProbablyItemPhrase(pLower) then
                        return "items", _asKey(phrase)
                    end
                    return "mobs", _asKey(phrase)
                end

                return "unknown", _asKey(phrase)
            end
        end
    end

    if lower:find("corpse") then
        return "items", _asKey(lineClean)
    end

    return "unknown", _asKey(lineClean)
end

-- ############################################################
-- WhoStore "superpower" wiring (SAFE)
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
    current = _ensureBucketsPresent((type(current) == "table") and current or {})
    knownPlayersSet = (type(knownPlayersSet) == "table") and knownPlayersSet or {}

    local next = _newBuckets()

    local function moveIfKnown(name)
        if type(name) ~= "string" or name == "" then return false, nil end

        local key = _normName(name)
        if key ~= "" and knownPlayersSet[key] == true then
            next.players[name] = true
            return true, name
        end

        local canon = _extractKnownPlayerPrefixName(name, knownPlayersSet)
        if canon then
            next.players[canon] = true
            return true, canon
        end

        return false, nil
    end

    local moved = 0

    for k, v in pairs(current.players) do
        if v == true and type(k) == "string" and k ~= "" then
            local okMove, canon = moveIfKnown(k)
            if okMove then
                if canon ~= k then moved = moved + 1 end
            else
                next.players[k] = true
            end
        end
    end

    for k, v in pairs(current.unknown) do
        if v == true and type(k) == "string" and k ~= "" then
            local okMove, canon = moveIfKnown(k)
            if okMove then
                moved = moved + 1
            else
                next.unknown[k] = true
            end
        end
    end

    for k, v in pairs(current.mobs) do
        if v == true and type(k) == "string" and k ~= "" then
            local okMove, canon = moveIfKnown(k)
            if okMove then
                moved = moved + 1
            else
                next.mobs[k] = true
            end
        end
    end

    for k, v in pairs(current.items) do
        if v == true and type(k) == "string" and k ~= "" then
            local okMove, canon = moveIfKnown(k)
            if okMove then
                moved = moved + 1
            else
                next.items[k] = true
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
    local before = _copyOneLevel(_ensureBucketsPresent(STATE.state))

    local next, moved = _reclassifyBucketsWithKnownPlayers(before, knownPlayersSet)

    if opts.forceEmit ~= true and _statesEqual(before, next) then
        STATE.suppressedEmits = STATE.suppressedEmits + 1
        _who.reclassifyRunning = false
        return true, nil
    end

    STATE.state = _copyOneLevel(_ensureBucketsPresent(next))
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
    return _copyOneLevel(_ensureBucketsPresent(STATE.state))
end

function M.setState(newState, opts)
    opts = (type(opts) == "table") and opts or {}
    if type(newState) ~= "table" then
        return false, "setState(newState): newState must be a table"
    end

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

    STATE.state = _ensureBucketsPresent(STATE.state)

    local before = _copyOneLevel(STATE.state)

    _merge(STATE.state, delta)
    STATE.state = _ensureBucketsPresent(STATE.state)

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

    STATE.state = _ensureBucketsPresent(STATE.state)
    local before = _copyOneLevel(STATE.state)

    STATE.state = _newBuckets()
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

function M.reclassifyFromWhoStore(opts)
    opts = (type(opts) == "table") and opts or {}
    _ensureWhoStoreSubscription()
    return _applyReclassifyNow({ source = opts.source or "manual:reclassify", forceEmit = (opts.forceEmit == true) })
end

-- opts:
--   - source: string
--   - assumeCapitalizedAsPlayer: boolean
--   - usePresence: boolean (default true)
--   - useWhoStore: boolean (default true)
--   - knownPlayers: table (optional override; set/list of names)
--   - forceEmit: boolean
--   - ignorePatterns: table of Lua patterns (optional)
--   - ignoreSubstrings: table of plain substrings (optional)
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

return M
