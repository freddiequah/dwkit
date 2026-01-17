-- #########################################################################
-- Module Name : dwkit.services.whostore_service
-- Owner       : Services
-- Version     : v2026-01-17B
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
-- SAFE Constraints:
--   - No gameplay commands
--   - No timers
--   - No automation by default
-- #########################################################################

local M = {}

M.VERSION = "v2026-01-17B"

local ID = require("dwkit.core.identity")
local BUS = require("dwkit.bus.event_bus")

M.EV_UPDATED = tostring(ID.eventPrefix or "DWKit:") .. "Service:WhoStore:Updated"

local _state = {
    players = {},        -- map: name -> true
    lastUpdatedTs = nil, -- os.time()
    source = nil,        -- string
    rawCount = 0,        -- count of names parsed from last ingest
    stats = {
        ingests = 0,
        updates = 0,
        emits = 0,
        lastEmitTs = nil,
        lastEmitSource = nil,
    },
}

local function _safeRequire(modName)
    local ok, mod = pcall(require, modName)
    if ok then return true, mod end
    return false, mod
end

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
}

local function _isBlockedToken(name)
    if type(name) ~= "string" then return true end
    local k = name:lower()
    if _BLOCKED_TOKENS[k] then
        return true
    end
    return false
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

local function _emitUpdated(payload)
    payload = (type(payload) == "table") and payload or {}

    _state.stats.emits = _state.stats.emits + 1
    _state.stats.lastEmitTs = os.time()
    if type(payload.source) == "string" then
        _state.stats.lastEmitSource = payload.source
    end

    if type(BUS) ~= "table" then
        return false
    end

    -- Best-effort: event_bus emit signature may vary.
    if type(BUS.emit) == "function" then
        local ok1 = pcall(BUS.emit, M.EV_UPDATED, payload)
        if ok1 then return true end
        pcall(BUS.emit, payload, M.EV_UPDATED)
        return true
    end

    -- Fall back to common alternates
    if type(BUS.raise) == "function" then
        pcall(BUS.raise, M.EV_UPDATED, payload)
        return true
    end
    if type(BUS.publish) == "function" then
        pcall(BUS.publish, M.EV_UPDATED, payload)
        return true
    end

    return false
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
        _emitUpdated({
            ts = _state.lastUpdatedTs,
            state = M.getState(),
            source = _state.source,
        })
    end

    return true, nil
end

function M.clear(opts)
    opts = (type(opts) == "table") and opts or {}

    local hadAny = (_countMap(_state.players) > 0)

    _state.players = {}
    _state.lastUpdatedTs = os.time()
    _state.source = tostring(opts.source or "clear")
    _state.rawCount = 0
    _state.stats.updates = _state.stats.updates + 1

    if hadAny then
        _emitUpdated({
            ts = _state.lastUpdatedTs,
            state = M.getState(),
            source = _state.source,
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
    local added = 0

    for _, line in ipairs(lines) do
        local s = tostring(line or "")
        local n = _normalizeName(s)
        if n then
            names[n] = true
        end
    end

    _state.stats.ingests = _state.stats.ingests + 1

    local before = _countMap(_state.players)

    for n, _ in pairs(names) do
        if _state.players[n] ~= true then
            added = added + 1
        end
        _state.players[n] = true
    end

    local after = _countMap(_state.players)

    _state.lastUpdatedTs = os.time()
    _state.source = tostring(opts.source or "ingestWhoLines")
    _state.rawCount = _countMap(names)
    _state.stats.updates = _state.stats.updates + 1

    if after ~= before then
        _emitUpdated({
            ts = _state.lastUpdatedTs,
            state = M.getState(),
            source = _state.source,
            delta = { added = added },
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
