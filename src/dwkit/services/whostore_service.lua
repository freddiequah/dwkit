-- #########################################################################
-- Module Name : dwkit.services.whostore_service
-- Owner       : Services
-- Version     : v2026-01-19C
-- Purpose     :
--   - SAFE WhoStore service (manual-only) to cache authoritative player names
--     derived from parsing WHO output (No-GMCP compatible).
--   - Provides a player set used by other services (e.g. RoomEntities) for
--     best-effort player classification.
--   - Emits Updated event on changes (SAFE; no gameplay commands; no timers).
--
-- Public API  :
--   - getVersion() -> string
--   - getUpdatedEventName() -> string
--   - onUpdated(handlerFn) -> boolean ok, any tokenOrNil, string|nil err
--   - getState() -> table copy
--   - setState(newState, opts?) -> boolean ok, string|nil err
--   - update(delta, opts?) -> boolean ok, string|nil err
--   - clear(opts?) -> boolean ok, string|nil err
--   - ingestWhoLines(lines, opts?) -> boolean ok, string|nil err
--   - ingestWhoText(text, opts?) -> boolean ok, string|nil err
--   - hasPlayer(name) -> boolean
--   - getAllPlayers() -> array (sorted)
--
-- ingestWho* behavior:
--   - Default: REPLACE mode (authoritative snapshot) to match real WHO output.
--   - Opt-in MERGE mode: pass opts.merge=true to add without removing existing.
--
-- SAFE Constraints:
--   - No gameplay commands
--   - No timers
--   - No automation by default
--
-- Fix (v2026-01-18C):
--   - _emitUpdated MUST check BUS.emit() return ok flag.
--     pcall() success only means no error, NOT that emit succeeded.
--
-- Fix (v2026-01-19C):
--   - event_bus.emit() requires 3-arg signature: emit(eventName, payload, meta)
--     Without meta, emit does not deliver (seen in live verification).
-- #########################################################################

local M = {}

M.VERSION = "v2026-01-19C"

local ID = require("dwkit.core.identity")
local BUS = require("dwkit.bus.event_bus")

M.EV_UPDATED = tostring(ID.eventPrefix or "DWKit:") .. "Service:WhoStore:Updated"

local _state = {
    players = {},        -- map: name -> true
    lastUpdatedTs = nil, -- os.time()
    source = nil,        -- string
    rawCount = 0,        -- count of names parsed from last ingest snapshot
    stats = {
        ingests = 0,
        updates = 0,
        emits = 0, -- counts successful emits only (v2026-01-18C)
        lastEmitTs = nil,
        lastEmitSource = nil,
        lastEmitErr = nil,
    },
}

local function _copyTable(t)
    local out = {}
    if type(t) ~= "table" then return out end
    for k, v in pairs(t) do
        out[k] = v
    end
    return out
end

local function _countMap(t)
    if type(t) ~= "table" then return 0 end
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

local function _sortedKeys(t)
    local keys = {}
    if type(t) ~= "table" then return keys end
    for k, _ in pairs(t) do
        keys[#keys + 1] = k
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    return keys
end

-- Guard: prevent common DWKit commands / headers from being treated as player names
local _BLOCKED_TOKENS = {
    -- commands / aliases (common)
    ["dwwho"] = true,
    ["dw"] = true,
    ["dwcommands"] = true,
    ["dwhelp"] = true,
    ["dwtest"] = true,
    ["dwinfo"] = true,
    ["dwid"] = true,
    ["dwversion"] = true,
    ["dwdiag"] = true,
    ["dwgui"] = true,
    ["dwevents"] = true,
    ["dwevent"] = true,
    ["dwboot"] = true,
    ["dwservices"] = true,
    ["dwpresence"] = true,
    ["dwroom"] = true,
    ["dwactions"] = true,
    ["dwskills"] = true,
    ["dwscorestore"] = true,
    ["dweventtap"] = true,
    ["dweventsub"] = true,
    ["dweventunsub"] = true,
    ["dweventlog"] = true,
    ["dwrelease"] = true,

    -- common WHO noise / headers
    ["name"] = true,
    ["names"] = true,
    ["player"] = true,
    ["players"] = true,
    ["total"] = true,
    ["characters"] = true,
    ["displayed"] = true,
}

local function _isBlockedToken(name)
    if type(name) ~= "string" then return true end
    local k = name:lower()
    if _BLOCKED_TOKENS[k] then
        return true
    end
    return false
end

local function _stripLeadingBracketTags(s)
    if type(s) ~= "string" then return s end
    -- WHO lines often start with tags like:
    -- [48 War] Name ...
    -- [ IMPL ] Name ...
    -- [ MGOD ] Name ...
    -- Strip one or more leading [ ... ] blocks safely.
    for _ = 1, 4 do
        local t = s:match("^%s*(%b[])%s*")
        if not t then break end
        s = s:gsub("^%s*%b[]%s*", "")
    end
    return s
end

local function _normalizeName(s)
    if type(s) ~= "string" then return nil end

    -- normalize whitespace
    s = s:gsub("\r", "")
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then return nil end

    -- remove common mudlet/mud color codes (best-effort)
    s = s:gsub("\27%[[%d;]*m", "")

    -- ignore divider-ish lines (e.g. "-----", "=====")
    if s:match("^[-=_%*]+$") then
        return nil
    end

    local lower = s:lower()

    -- ignore WHO footer lines
    -- e.g. "12 characters displayed."
    if lower:match("^%d+%s+characters%s+displayed%.?$") then
        return nil
    end

    -- Strip [..] class/level tags first so we don't capture "War/Cle/etc"
    s = _stripLeadingBracketTags(s)

    -- trim again after stripping
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then return nil end

    -- Capture first plausible name token.
    -- Accept letters/numbers/' with leading letter.
    local name = s:match("([A-Za-z][A-Za-z0-9']*)")
    if not name or name == "" then
        return nil
    end

    -- prevent command/header tokens from polluting the player set
    if _isBlockedToken(name) then
        return nil
    end

    return name
end

local function _asPlayersMap(players)
    -- Accept either map {Name=true} OR array {"Name", ...}
    local out = {}

    if type(players) ~= "table" then
        return out
    end

    -- array-like
    if #players > 0 then
        for i = 1, #players do
            local n = _normalizeName(tostring(players[i] or ""))
            if n then out[n] = true end
        end
        return out
    end

    -- map-like
    for k, v in pairs(players) do
        if v == true then
            local n = _normalizeName(tostring(k or ""))
            if n then out[n] = true end
        end
    end

    return out
end

local function _emitUpdated(payload)
    payload = (type(payload) == "table") and payload or {}

    if type(BUS) ~= "table" then
        _state.stats.lastEmitErr = "event bus not available"
        return false
    end

    if type(BUS.emit) ~= "function" then
        _state.stats.lastEmitErr = "event bus .emit not available"
        return false
    end

    -- IMPORTANT:
    -- In this DWKit environment, event_bus.emit requires:
    --   emit(eventName, payload, meta)
    -- If meta is missing, emit will not deliver (verified live).
    local meta = {
        source = tostring(payload.source or _state.source or "WhoStoreService"),
        service = "dwkit.services.whostore_service",
        ts = payload.ts,
    }

    local okCall, okEmit, delivered, errs = pcall(BUS.emit, M.EV_UPDATED, payload, meta)

    if okCall and okEmit == true then
        _state.stats.emits = _state.stats.emits + 1
        _state.stats.lastEmitTs = os.time()
        _state.stats.lastEmitSource = meta.source
        _state.stats.lastEmitErr = nil
        return true
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

    _state.stats.lastEmitErr = errMsg
    return false
end

function M.getVersion()
    return M.VERSION
end

function M.getUpdatedEventName()
    return M.EV_UPDATED
end

function M.onUpdated(handlerFn)
    if type(handlerFn) ~= "function" then
        return false, nil, "handlerFn must be function"
    end
    if type(BUS) ~= "table" then
        return false, nil, "event bus not available"
    end
    if type(BUS.on) ~= "function" then
        return false, nil, "event bus .on not available"
    end

    local ok, tokenOrErr, maybeErr = BUS.on(M.EV_UPDATED, handlerFn)
    if ok == true then
        return true, tokenOrErr, nil
    end

    return false, nil, maybeErr or tokenOrErr or "subscribe failed"
end

function M.getState()
    return {
        version = M.VERSION,
        updatedEventName = M.EV_UPDATED,
        players = _copyTable(_state.players),
        lastUpdatedTs = _state.lastUpdatedTs,
        source = _state.source,
        rawCount = _state.rawCount,
        stats = _copyTable(_state.stats),
    }
end

function M.hasPlayer(name)
    local n = _normalizeName(tostring(name or ""))
    if not n then return false end
    return (_state.players[n] == true)
end

function M.getAllPlayers()
    return _sortedKeys(_state.players)
end

function M.setState(newState, opts)
    newState = (type(newState) == "table") and newState or {}
    opts = (type(opts) == "table") and opts or {}

    local players = _asPlayersMap(newState.players)

    _state.players = players
    _state.lastUpdatedTs = os.time()
    _state.source = tostring(opts.source or newState.source or "setState")
    _state.rawCount = _countMap(players)
    _state.stats.updates = _state.stats.updates + 1

    _emitUpdated({
        ts = _state.lastUpdatedTs,
        state = M.getState(),
        source = _state.source,
        delta = { added = _state.rawCount, removed = 0, total = _state.rawCount, mode = "setState" },
    })

    return true, nil
end

function M.update(delta, opts)
    delta = (type(delta) == "table") and delta or {}
    opts = (type(opts) == "table") and opts or {}

    local before = _countMap(_state.players)

    -- delta.players can be map or array
    if delta.players ~= nil then
        local addMap = _asPlayersMap(delta.players)
        for n, _ in pairs(addMap) do
            _state.players[n] = true
        end
    end

    -- Optional explicit remove list: delta.remove = {"Name", ...}
    if type(delta.remove) == "table" then
        for _, v in ipairs(delta.remove) do
            local n = _normalizeName(tostring(v or ""))
            if n then _state.players[n] = nil end
        end
    end

    local after = _countMap(_state.players)

    _state.lastUpdatedTs = os.time()
    _state.source = tostring(opts.source or "update")
    _state.rawCount = after
    _state.stats.updates = _state.stats.updates + 1

    local changed = (after ~= before)

    if changed then
        local added = (after > before) and (after - before) or 0
        local removed = (before > after) and (before - after) or (0)
        _emitUpdated({
            ts = _state.lastUpdatedTs,
            state = M.getState(),
            source = _state.source,
            delta = { added = added, removed = removed, total = after, mode = "update" },
        })
    end

    return true, nil
end

function M.clear(opts)
    opts = (type(opts) == "table") and opts or {}

    local before = _countMap(_state.players)

    _state.players = {}
    _state.lastUpdatedTs = os.time()
    _state.source = tostring(opts.source or "clear")
    _state.rawCount = 0
    _state.stats.updates = _state.stats.updates + 1

    if before > 0 then
        _emitUpdated({
            ts = _state.lastUpdatedTs,
            state = M.getState(),
            source = _state.source,
            delta = { added = 0, removed = before, total = 0, mode = "clear" },
        })
    end

    return true, nil
end

function M.ingestWhoLines(lines, opts)
    opts = (type(opts) == "table") and opts or {}
    if type(lines) ~= "table" then
        return false, "lines must be table"
    end

    local names = {}

    for _, line in ipairs(lines) do
        local s = tostring(line or "")
        local n = _normalizeName(s)
        if n then
            names[n] = true
        end
    end

    _state.stats.ingests = _state.stats.ingests + 1

    local mode = (opts.merge == true) and "merge" or "replace"

    local beforeMap = _state.players
    local beforeCount = _countMap(beforeMap)

    local afterMap = {}
    if mode == "merge" then
        -- merge = add-only
        afterMap = _copyTable(beforeMap)
        for n, _ in pairs(names) do
            afterMap[n] = true
        end
    else
        -- replace = authoritative snapshot
        afterMap = names
    end

    local afterCount = _countMap(afterMap)

    local added = 0
    local removed = 0

    if mode == "merge" then
        for n, _ in pairs(afterMap) do
            if beforeMap[n] ~= true then
                added = added + 1
            end
        end
        removed = 0
    else
        for n, _ in pairs(afterMap) do
            if beforeMap[n] ~= true then
                added = added + 1
            end
        end
        for n, _ in pairs(beforeMap) do
            if afterMap[n] ~= true then
                removed = removed + 1
            end
        end
    end

    _state.players = afterMap
    _state.lastUpdatedTs = os.time()
    _state.source = tostring(opts.source or "ingestWhoLines")
    _state.rawCount = _countMap(names)
    _state.stats.updates = _state.stats.updates + 1

    local changed = (added > 0) or (removed > 0)

    if changed then
        _emitUpdated({
            ts = _state.lastUpdatedTs,
            state = M.getState(),
            source = _state.source,
            delta = { added = added, removed = removed, total = afterCount, mode = mode, rawCount = _state.rawCount },
        })
    end

    return true, nil
end

function M.ingestWhoText(text, opts)
    opts = (type(opts) == "table") and opts or {}
    if type(text) ~= "string" then
        return false, "text must be string"
    end

    text = text:gsub("\r", "")
    local lines = {}

    for line in text:gmatch("([^\n]+)") do
        lines[#lines + 1] = line
    end

    return M.ingestWhoLines(lines, opts)
end

return M
