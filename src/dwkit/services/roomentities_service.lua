-- FILE: src/dwkit/services/roomentities_service.lua
-- #########################################################################
-- Module Name : dwkit.services.roomentities_service
-- Owner       : Services
-- Version     : v2026-02-09D
-- Purpose     :
--   - SAFE, profile-portable RoomEntitiesService (data only).
--   - No GMCP dependency, no Mudlet events, no timers, no send().
--   - Emits a registered internal event when state changes.
--   - Provides ingestion helpers for look/snapshot output parsing.
--
--   DWKit RoomEntities Capture & Unknown Tagging Agreement (DISCUSSION-LOCK)
--   Alignment (v2026-02-09C):
--     - Unknown-first strategy:
--         * ONLY players may be auto-typed (WhoStore confidence gate, exact name match).
--         * All non-player entity candidates default to "unknown".
--         * Do NOT auto-classify mob vs item/object in the service.
--     - Preserve snapshot duplicate counts:
--         * Keep a V2 structure (state.entitiesV2) carrying counts + raw lines.
--         * Maintain legacy bucket sets (players/mobs/items/unknown) for compatibility,
--           but mobs/items remain empty unless upstream/overrides fill them (UI does).
--     - Strict entity region support (service-side best-effort):
--         * When ingesting full snapshot lines, scan entity candidates ONLY before
--           "Obvious exits:".
--         * Description/title lines are ignored (conservative).
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
--   - emitUpdated(meta?) -> boolean ok, string|nil err
--   - ingestFixture(opts?) -> boolean ok, string|nil err
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

M.VERSION = "v2026-02-09D"

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

-- V2: occurrence-aware structure (per snapshot ingest)
-- NOTE: mobs/items are present for completeness; service keeps them empty by policy.
local function _newEntitiesV2()
    return {
        players = {}, -- { [displayName] = { label=displayName, key=displayName, count=1, raws={...} } }
        mobs = {},    -- intentionally empty (policy)
        items = {},   -- intentionally empty (policy)
        unknown = {}, -- { [normKey] = { label=displayName, key=normKey, count=N, raws={...} } }
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

local function _ensureEntitiesV2Present(s)
    if type(s) ~= "table" then
        return _newEntitiesV2()
    end
    if type(s.players) ~= "table" then s.players = {} end
    if type(s.mobs) ~= "table" then s.mobs = {} end
    if type(s.items) ~= "table" then s.items = {} end
    if type(s.unknown) ~= "table" then s.unknown = {} end
    return s
end

local STATE = {
    state = _newBuckets(),         -- legacy sets
    entitiesV2 = _newEntitiesV2(), -- V2 occurrence map
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

-- Strip trailing parenthetical tags like "(glowing)" "(humming)" etc.
-- Repeats to remove multiple tags at end.
local function _stripTrailingParenTags(s)
    if type(s) ~= "string" then return "" end
    local out = _trim(s)
    if out == "" then return "" end

    local changed = true
    while changed do
        changed = false
        local before = out
        out = out:gsub("%s*%b()%s*$", "")
        out = _trim(out)
        if out ~= before then
            changed = true
        end
    end

    return out
end

-- Strip trailing bracket/flag blocks like "[ INDOORS IMMROOM ]" or "[FIGHTING]"
-- Repeats to remove multiple blocks at end.
local function _stripTrailingBracketTags(s)
    if type(s) ~= "string" then return "" end
    local out = _trim(s)
    if out == "" then return "" end

    local changed = true
    while changed do
        changed = false
        local before = out
        out = out:gsub("%s*%b[]%s*$", "")
        out = _trim(out)
        if out ~= before then
            changed = true
        end
    end

    return out
end

-- Strip trailing id tokens:
--   "(#12345)"  (already covered by paren stripping, but kept explicit for clarity)
--   "#12345"
local function _stripTrailingIdTokens(s)
    if type(s) ~= "string" then return "" end
    local out = _trim(s)
    if out == "" then return "" end

    local changed = true
    while changed do
        changed = false
        local before = out

        out = out:gsub("%s*%(%s*#%d+%s*%)%s*$", "")
        out = _trim(out)

        out = out:gsub("%s*#%d+%s*$", "")
        out = _trim(out)

        if out ~= before then
            changed = true
        end
    end

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

local function _copyEntitiesV2(v2)
    local out = _newEntitiesV2()
    v2 = _ensureEntitiesV2Present(v2)

    local function copyBucket(dst, src)
        if type(src) ~= "table" then return end
        for k, e in pairs(src) do
            if type(k) == "string" and type(e) == "table" then
                local ee = {
                    label = tostring(e.label or k),
                    key = tostring(e.key or k),
                    count = tonumber(e.count) or 1,
                    raws = {},
                }
                if type(e.raws) == "table" then
                    for i = 1, #e.raws do
                        ee.raws[i] = tostring(e.raws[i] or "")
                    end
                end
                dst[k] = ee
            end
        end
    end

    copyBucket(out.players, v2.players)
    copyBucket(out.mobs, v2.mobs)
    copyBucket(out.items, v2.items)
    copyBucket(out.unknown, v2.unknown)

    return out
end

local function _merge(dst, src)
    if type(dst) ~= "table" or type(src) ~= "table" then return end
    for k, v in pairs(src) do
        dst[k] = v
    end
end

-- FIXED: event_bus.emit requires (eventName, payload, meta) in this DWKit environment.
local function _emit(stateCopy, deltaCopy, source)
    local payload = {
        ts = os.time(),
        state = stateCopy,
        entitiesV2 = _copyEntitiesV2(STATE.entitiesV2),
    }
    if type(deltaCopy) == "table" then payload.delta = deltaCopy end
    if type(source) == "string" and source ~= "" then payload.source = source end

    local meta = {
        source = tostring(source or "RoomEntitiesService"),
        service = "dwkit.services.roomentities_service",
        ts = payload.ts,
    }

    local okCall, okEmit, delivered, errs = pcall(BUS.emit, EV_UPDATED, payload, meta)

    if okCall and okEmit == true then
        return true, nil
    end

    local errMsg = nil
    if okCall ~= true then
        errMsg = tostring(okEmit)
    else
        if type(errs) == "table" and errs[1] ~= nil then
            errMsg = tostring(errs[1])
        else
            errMsg = "emit returned ok=false"
        end
    end

    return false, errMsg
end

-- Normalize + build a stable key for buckets.
-- IMPORTANT: legacy buckets remain keyed by display label ONLY (string), even if ids exist in output.
local function _asKey(s)
    s = _trim(s or "")
    if s == "" then return nil end

    local out = _stripTrailingParenTags(s)
    out = _stripTrailingBracketTags(out)
    out = _stripTrailingIdTokens(out)

    out = _trim(out)
    if out == "" then return nil end
    return out
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

local function _isArrayTable(t)
    if type(t) ~= "table" then return false end
    for k in pairs(t) do
        if type(k) ~= "number" then
            return false
        end
    end
    return true
end

-- ############################################################
-- Confidence gate helpers (exact display-name match required)
-- ############################################################

local function _newNameIndex()
    return {
        set = {},          -- { [lower] = true }
        canonByLower = {}, -- { [lower] = "DisplayName" }
    }
end

local function _indexAdd(idx, name)
    if type(idx) ~= "table" or type(name) ~= "string" then return end

    local canon = _asKey(name)
    if type(canon) ~= "string" or canon == "" then return end

    local lower = _normName(canon)
    if lower == "" then return end

    idx.set[lower] = true
    idx.canonByLower[lower] = canon
end

-- candidate-only add: membership without a canonical display name
local function _indexAddLowerOnly(idx, name)
    if type(idx) ~= "table" or type(name) ~= "string" then return end
    local canon = _asKey(name)
    if type(canon) ~= "string" or canon == "" then return end
    local lower = _normName(canon)
    if lower == "" then return end
    idx.set[lower] = true
end

local function _indexMerge(dst, src)
    if type(dst) ~= "table" or type(src) ~= "table" then return end
    if type(src.set) == "table" then
        for k, v in pairs(src.set) do
            if v == true then dst.set[k] = true end
        end
    end
    if type(src.canonByLower) == "table" then
        for k, v in pairs(src.canonByLower) do
            if type(k) == "string" and type(v) == "string" and v ~= "" then
                dst.canonByLower[k] = v
            end
        end
    end
end

local function _absorbNamesToIndex(idx, t)
    if type(idx) ~= "table" or type(t) ~= "table" then return end

    if _isArrayTable(t) then
        for _, v in ipairs(t) do
            if type(v) == "string" then
                _indexAdd(idx, v)
            elseif type(v) == "table" and type(v.name) == "string" then
                _indexAdd(idx, v.name)
            end
        end
        return
    end

    for k, v in pairs(t) do
        if type(k) == "string" then
            if v == true then
                _indexAdd(idx, k)
            elseif type(v) == "string" then
                _indexAdd(idx, v)
            elseif type(v) == "table" and type(v.name) == "string" then
                _indexAdd(idx, v.name)
            end
        elseif type(v) == "string" then
            _indexAdd(idx, v)
        elseif type(v) == "table" and type(v.name) == "string" then
            _indexAdd(idx, v.name)
        end
    end
end

-- returns "exact" | "candidate" | "none"
local function _confidenceForName(name, idx)
    if type(name) ~= "string" then return "none" end
    idx = (type(idx) == "table") and idx or _newNameIndex()

    local canon = _asKey(name)
    if type(canon) ~= "string" or canon == "" then
        return "none"
    end

    local lower = _normName(canon)
    if lower == "" then
        return "none"
    end

    if idx.set[lower] ~= true then
        return "none"
    end

    local expected = idx.canonByLower[lower]
    if type(expected) == "string" and expected ~= "" then
        if expected == canon then
            return "exact"
        end
        return "candidate"
    end

    return "candidate"
end

-- ############################################################
-- Presence / WhoStore known player extraction (index form)
-- ############################################################

local function _extractKnownPlayersIndexFromPresenceState(pState)
    local idx = _newNameIndex()
    if type(pState) ~= "table" then
        return idx
    end

    _absorbNamesToIndex(idx, pState)

    local keys = { "players", "nearby", "present", "who", "names", "list" }
    for _, k in ipairs(keys) do
        local v = pState[k]
        if type(v) == "table" then
            _absorbNamesToIndex(idx, v)
        end
    end

    return idx
end

local function _getPresenceKnownPlayersIndexBestEffort(opts)
    opts = (type(opts) == "table") and opts or {}

    if type(opts.knownPlayers) == "table" then
        local idx = _newNameIndex()
        _absorbNamesToIndex(idx, opts.knownPlayers)
        return idx
    end

    if opts.usePresence ~= nil and opts.usePresence ~= true then
        return _newNameIndex()
    end

    local okP, P = _safeRequire("dwkit.services.presence_service")
    if not okP or type(P) ~= "table" then
        return _newNameIndex()
    end
    if type(P.getState) ~= "function" then
        return _newNameIndex()
    end

    local okS, pState = pcall(P.getState)
    if not okS or type(pState) ~= "table" then
        return _newNameIndex()
    end

    return _extractKnownPlayersIndexFromPresenceState(pState)
end

local function _extractKnownPlayersIndexFromWhoStoreState(wState)
    local idx = _newNameIndex()
    if type(wState) ~= "table" then
        return idx
    end

    do
        local snap = wState.snapshot
        if type(snap) ~= "table" and type(wState.byName) == "table" then
            snap = wState
        end

        if type(snap) == "table" and type(snap.byName) == "table" then
            for _, e in pairs(snap.byName) do
                if type(e) == "table" and type(e.name) == "string" and e.name ~= "" then
                    _indexAdd(idx, e.name)
                end
            end
            return idx
        end

        if type(snap) == "table" and type(snap.entries) == "table" then
            for i = 1, #snap.entries do
                local e = snap.entries[i]
                if type(e) == "table" and type(e.name) == "string" and e.name ~= "" then
                    _indexAdd(idx, e.name)
                end
            end
            if next(idx.set) ~= nil then
                return idx
            end
        end
    end

    if type(wState.players) == "table" then
        for k, v in pairs(wState.players) do
            if v == true and type(k) == "string" and k ~= "" then
                _indexAddLowerOnly(idx, k)
            end
        end
        return idx
    end

    _absorbNamesToIndex(idx, wState)
    return idx
end

local function _getWhoStoreKnownPlayersIndexBestEffort()
    local okW, W = _safeRequire("dwkit.services.whostore_service")
    if not okW or type(W) ~= "table" then
        return _newNameIndex()
    end
    if type(W.getState) ~= "function" then
        return _newNameIndex()
    end

    local okS, wState = pcall(W.getState)
    if not okS or type(wState) ~= "table" then
        return _newNameIndex()
    end

    return _extractKnownPlayersIndexFromWhoStoreState(wState)
end

local function _getKnownPlayersIndexCombined(opts)
    opts = (type(opts) == "table") and opts or {}

    if type(opts.knownPlayers) == "table" then
        local idx = _newNameIndex()
        _absorbNamesToIndex(idx, opts.knownPlayers)
        return idx
    end

    local idx = _newNameIndex()

    if opts.usePresence == nil or opts.usePresence == true then
        local pIdx = _getPresenceKnownPlayersIndexBestEffort(opts)
        _indexMerge(idx, pIdx)
    end

    if opts.useWhoStore == nil or opts.useWhoStore == true then
        local wIdx = _getWhoStoreKnownPlayersIndexBestEffort()
        _indexMerge(idx, wIdx)
    end

    return idx
end

-- ############################################################
-- Entity candidate detection (simple, stable allowlist)
-- ############################################################

local function _isNoiseLine(lowerTrimmed)
    if type(lowerTrimmed) ~= "string" then return false end
    if lowerTrimmed == "" then return true end

    if lowerTrimmed:find("^%<%d+") then return true end -- prompt-ish
    if lowerTrimmed:find("gossips,") then return true end
    if lowerTrimmed:find("tells you") then return true end
    if lowerTrimmed:find("shouts,") then return true end
    if lowerTrimmed:find("auction:") then return true end
    return false
end

local function _isExitBoundary(lowerTrimmed)
    if type(lowerTrimmed) ~= "string" then return false end
    if lowerTrimmed:find("^obvious exits:") then return true end
    if lowerTrimmed:find("^exits:") then return true end
    return false
end

local function _looksLikeExitRow(lineLower)
    if type(lineLower) ~= "string" then return false end
    return (lineLower:match("^(north|south|east|west|up|down)%s+%-%s+") ~= nil)
end

local function _looksLikeRoomTitle(line)
    if type(line) ~= "string" then return false end
    if line:find("%.") then return false end
    if #line > 70 then return false end
    if line:match("^%s+") then return false end
    local l = line:lower()
    if l:find(" is here") or l:find("standing here") then return false end
    if l:find("^obvious exits:") then return false end
    if l:find("^exits:") then return false end
    return true
end

-- Returns phrase (label) if this is a candidate entity line, else nil.
-- Allowed:
--   "<X> is here..."
--   "<X> is <posture> here..."
--   "<X> stands here..."
--   "<X> lies here..."
--   "<X> has been placed here..."
--   "<X> is standing here..."
--   "<X> is mounted <...> here..."   (added for bulletin boards / mounted objects)
local function _extractEntityPhrase(lineClean)
    if type(lineClean) ~= "string" then return nil end
    local trimmed = _trim(lineClean)
    if trimmed == "" then return nil end

    local lower = trimmed:lower()
    if _isNoiseLine(lower) then return nil end
    if _isExitBoundary(lower) then return nil end
    if _looksLikeExitRow(lower) then return nil end
    if _looksLikeRoomTitle(trimmed) and lower:find(" here") == nil then
        -- conservative: treat title/description as non-entity unless it matches entity patterns
        -- (entity patterns below will still catch "X is here" etc)
    end

    do
        local phrase = trimmed:match("^(.-)%s+has%s+been%s+placed%s+here[%s,%.]")
        phrase = _trim(phrase or "")
        if phrase ~= "" then return phrase end
    end

    do
        local phrase = trimmed:match("^(.-)%s+lies%s+here[%s,%.]")
        phrase = _trim(phrase or "")
        if phrase ~= "" then return phrase end
    end

    do
        local phrase = trimmed:match("^(.-)%s+stands%s+here[%s,%.]")
        phrase = _trim(phrase or "")
        if phrase ~= "" then return phrase end
    end

    do
        local phrase = trimmed:match("^(.-)%s+is%s+standing%s+here[%s,%.]")
        phrase = _trim(phrase or "")
        if phrase ~= "" then return phrase end
    end

    -- NEW: capture lines like:
    --   "A large bulletin board is mounted on a wall here."
    do
        local phrase = trimmed:match("^(.-)%s+is%s+mounted%s+.-%s+here[%s,%.]")
        phrase = _trim(phrase or "")
        if phrase ~= "" then return phrase end
    end

    do
        local phrase, posture = trimmed:match("^(.-)%s+is%s+(%a+)%s+here[%s,%.]")
        phrase = _trim(phrase or "")
        posture = tostring(posture or ""):lower()
        if phrase ~= "" and posture ~= "" then
            -- allow any word, but this is primarily posture support
            if POSTURES[posture] == true then
                return phrase
            end
            -- still accept as candidate (agreement: allowlist is simple, stable; errs go to unknown)
            return phrase
        end
    end

    do
        local phrase = trimmed:match("^(.-)%s+is%s+here[%s,%.]")
        phrase = _trim(phrase or "")
        if phrase ~= "" then return phrase end
    end

    return nil
end

local function _shouldIgnoreByCallerRules(trimmed, opts)
    opts = (type(opts) == "table") and opts or {}
    if type(trimmed) ~= "string" or trimmed == "" then
        return false
    end

    if type(opts.ignoreSubstrings) == "table" then
        for _, sub in ipairs(opts.ignoreSubstrings) do
            if type(sub) == "string" and sub ~= "" then
                if trimmed:find(sub, 1, true) ~= nil then
                    return true
                end
            end
        end
    end

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

-- ############################################################
-- WhoStore "superpower" wiring (SAFE)
-- Still allowed: auto promote to players when WhoStore becomes confident.
-- But per agreement: ONLY players can be auto-typed; everything else remains unknown.
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

local function _reclassifyUnknownToPlayersOnly(current, knownIdx)
    current = _ensureBucketsPresent((type(current) == "table") and current or {})
    knownIdx = (type(knownIdx) == "table") and knownIdx or _newNameIndex()

    local next = _newBuckets()
    local moved = 0

    -- keep legacy mobs/items as-is (typically empty); policy is unknown-first.
    next.mobs = _copyOneLevel(current.mobs)
    next.items = _copyOneLevel(current.items)

    local function placeNameFromUnknown(name)
        if type(name) ~= "string" or name == "" then return end
        local conf = _confidenceForName(name, knownIdx)
        if conf == "exact" then
            next.players[name] = true
            moved = moved + 1
        else
            next.unknown[name] = true
        end
    end

    for k, v in pairs(current.players) do
        if v == true and type(k) == "string" and k ~= "" then
            next.players[k] = true
        end
    end
    for k, v in pairs(current.unknown) do
        if v == true and type(k) == "string" and k ~= "" then
            placeNameFromUnknown(k)
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

    local knownIdx = _getWhoStoreKnownPlayersIndexBestEffort()
    local before = _copyOneLevel(_ensureBucketsPresent(STATE.state))

    local next, moved = _reclassifyUnknownToPlayersOnly(before, knownIdx)

    if opts.forceEmit ~= true and _statesEqual(before, next) then
        STATE.suppressedEmits = STATE.suppressedEmits + 1
        _who.reclassifyRunning = false
        return true, nil
    end

    STATE.state = _copyOneLevel(_ensureBucketsPresent(next))
    STATE.lastTs = os.time()
    STATE.updates = STATE.updates + 1

    local src = tostring(opts.source or "reclassify:whostore")
    local delta = { reclassifiedPlayers = moved }

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

    local handlerFn = function(_payload)
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

local function _armWhoStoreSubscriptionBestEffort()
    local ok, err = _ensureWhoStoreSubscription()
    if ok ~= true then
        _who.lastErr = tostring(err or _who.lastErr or "WhoStore subscribe failed")
    end
end

function M.getVersion()
    return tostring(M.VERSION)
end

function M.getUpdatedEventName()
    return tostring(EV_UPDATED)
end

function M.getState()
    local out = _copyOneLevel(_ensureBucketsPresent(STATE.state))
    out.entitiesV2 = _copyEntitiesV2(STATE.entitiesV2)
    return out
end

function M.emitUpdated(meta)
    meta = (type(meta) == "table") and meta or {}

    _armWhoStoreSubscriptionBestEffort()

    local source = nil
    if type(meta.source) == "string" and meta.source ~= "" then
        source = meta.source
    end

    local delta = _copyOneLevel(meta)
    delta.source = nil
    delta.ts = nil
    delta.state = nil
    delta.delta = nil
    delta.entitiesV2 = nil

    local hasAny = false
    for _ in pairs(delta) do
        hasAny = true
        break
    end
    if not hasAny then
        delta = nil
    end

    local okEmit, errEmit = _emit(_copyOneLevel(_ensureBucketsPresent(STATE.state)), delta, source)
    if not okEmit then
        return false, errEmit
    end

    STATE.emits = STATE.emits + 1
    return true, nil
end

function M.ingestFixture(opts)
    opts = (type(opts) == "table") and opts or {}

    _ensureWhoStoreSubscription()

    local buckets = _newBuckets()
    local v2 = _newEntitiesV2()

    -- V2 helper: preserve duplicates by incrementing count and storing raws.
    local function addV2(bucketMap, label, rawLine)
        bucketMap = (type(bucketMap) == "table") and bucketMap or {}
        label = tostring(label or "")
        rawLine = tostring(rawLine or label)

        local key = _asKey(label) or label
        key = _trim(key)
        if key == "" then return end

        local e = bucketMap[key]
        if type(e) ~= "table" then
            e = { label = label, key = key, count = 0, raws = {} }
            bucketMap[key] = e
        end

        e.count = (tonumber(e.count) or 0) + 1
        e.raws[#e.raws + 1] = rawLine
    end

    local function absorbSetOrArray(dstBucket, dstV2, src)
        if type(src) ~= "table" then return false end

        local addedAny = false

        local function addName(name)
            name = tostring(name or "")
            local label = _asKey(name) or name
            label = _trim(label)
            if label == "" then return end

            _addBucket(dstBucket, label)
            addV2(dstV2, label, label .. " is here.")
            addedAny = true
        end

        if _isArrayTable(src) then
            for _, v in ipairs(src) do
                if type(v) == "string" then
                    addName(v)
                elseif type(v) == "table" and type(v.name) == "string" then
                    addName(v.name)
                end
            end
            return addedAny
        end

        for k, v in pairs(src) do
            if v == true and type(k) == "string" then
                addName(k)
            elseif type(v) == "string" then
                addName(v)
            elseif type(v) == "table" and type(v.name) == "string" then
                addName(v.name)
            end
        end

        return addedAny
    end

    local hasAny = false
    if type(opts.players) == "table" then
        if absorbSetOrArray(buckets.players, v2.players, opts.players) then
            hasAny = true
        end
    end
    if type(opts.unknown) == "table" then
        if absorbSetOrArray(buckets.unknown, v2.unknown, opts.unknown) then
            hasAny = true
        end
    end

    -- Backward-compatible default fixture if caller provided nothing usable.
    if not hasAny then
        buckets.players["FixturePlayer"] = true
        buckets.unknown["Mysterious figure"] = true

        v2.players["FixturePlayer"] = { label = "FixturePlayer", key = "FixturePlayer", count = 1, raws = { "FixturePlayer is here." } }
        v2.unknown["Mysterious figure"] = { label = "Mysterious figure", key = "Mysterious figure", count = 1, raws = { "Mysterious figure is here." } }
    end

    local src = tostring(opts.source or "fixture:roomentities")
    return M.setState({ state = buckets, entitiesV2 = v2 }, { source = src, forceEmit = (opts.forceEmit == true) })
end

function M.setState(newState, opts)
    opts = (type(opts) == "table") and opts or {}
    if type(newState) ~= "table" then
        return false, "setState(newState): newState must be a table"
    end

    _armWhoStoreSubscriptionBestEffort()

    -- Accept two shapes:
    --   A) legacy: {players=..., mobs=..., items=..., unknown=...}
    --   B) wrapped: { state=legacyBuckets, entitiesV2=v2 }
    local incomingBuckets = newState
    local incomingV2 = nil

    if type(newState.state) == "table" then
        incomingBuckets = newState.state
    end
    if type(newState.entitiesV2) == "table" then
        incomingV2 = newState.entitiesV2
    end

    local nextState = _copyOneLevel(incomingBuckets)
    nextState = _ensureBucketsPresent(nextState)

    local before = _ensureBucketsPresent(STATE.state)

    local sameLegacy = _statesEqual(before, nextState)
    local nextV2 = (type(incomingV2) == "table") and _copyEntitiesV2(incomingV2) or _newEntitiesV2()

    -- If caller didn't provide V2, keep existing V2 only when legacy is unchanged.
    if type(incomingV2) ~= "table" and sameLegacy then
        nextV2 = _copyEntitiesV2(STATE.entitiesV2)
    end

    if opts.forceEmit ~= true and sameLegacy and type(incomingV2) ~= "table" then
        STATE.suppressedEmits = STATE.suppressedEmits + 1
        return true, nil
    end

    STATE.state = nextState
    STATE.entitiesV2 = _ensureEntitiesV2Present(nextV2)
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

    _armWhoStoreSubscriptionBestEffort()

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

    _armWhoStoreSubscriptionBestEffort()

    STATE.state = _ensureBucketsPresent(STATE.state)
    local before = _copyOneLevel(STATE.state)

    STATE.state = _newBuckets()
    STATE.entitiesV2 = _newEntitiesV2()
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

-- Best-effort entity-region scan:
--   - Collect candidates until "Obvious exits:" (or exit rows).
--   - Ignore room title / description lines conservatively.
function M.ingestLookLines(lines, opts)
    opts = (type(opts) == "table") and opts or {}
    if type(lines) ~= "table" then
        return false, "ingestLookLines(lines): lines must be a table"
    end

    _ensureWhoStoreSubscription()

    local knownPlayersIdx = _getKnownPlayersIndexCombined(opts)

    local buckets = _newBuckets()
    local v2 = _newEntitiesV2()

    local function addV2(bucketMap, key, label, rawLine)
        bucketMap = (type(bucketMap) == "table") and bucketMap or {}
        key = tostring(key or "")
        label = tostring(label or key)
        rawLine = tostring(rawLine or "")
        if key == "" then return end

        local e = bucketMap[key]
        if type(e) ~= "table" then
            e = { label = label, key = key, count = 0, raws = {} }
            bucketMap[key] = e
        end

        e.count = (tonumber(e.count) or 0) + 1
        e.raws[#e.raws + 1] = rawLine
    end

    for _, raw in ipairs(lines) do
        local line = tostring(raw or "")
        local trimmed = _trim(line)
        if trimmed ~= "" then
            if _shouldIgnoreByCallerRules(trimmed, opts) then
                -- skip
            else
                local lower = trimmed:lower()
                if _isExitBoundary(lower) or _looksLikeExitRow(lower) then
                    break
                end

                local phrase = _extractEntityPhrase(trimmed)
                if phrase ~= nil then
                    local label = _asKey(phrase) or phrase
                    if label ~= "" then
                        local conf = _confidenceForName(label, knownPlayersIdx)
                        if conf == "exact" then
                            _addBucket(buckets.players, label)
                            addV2(v2.players, label, label, trimmed)
                        else
                            _addBucket(buckets.unknown, label)
                            addV2(v2.unknown, label, label, trimmed)
                        end
                    end
                end
            end
        end
    end

    -- Policy: service does not auto-fill mobs/items; leave empty.
    local wrapped = { state = buckets, entitiesV2 = v2 }
    return M.setState(wrapped, { source = opts.source or "ingestLookLines", forceEmit = (opts.forceEmit == true) })
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

-- END FILE: src/dwkit/services/roomentities_service.lua
