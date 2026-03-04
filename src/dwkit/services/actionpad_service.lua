-- FILE: src/dwkit/services/actionpad_service.lua
-- #########################################################################
-- Module Name : dwkit.services.actionpad_service
-- Owner       : Services
-- Version     : v2026-03-04D
-- Purpose     :
--   - SAFE ActionPadService (data only).
--   - Produces "online-only" roster rows for ActionPad UI, based on PresenceService
--     roster when available (preferred), otherwise best-effort fallback to owned_profiles
--     + CPC local-online + WhoStore online.
--   - Provides deterministic planning helpers for RemoteExec, WITHOUT sending.
--   - No UI, no persistence, no timers, no send().
--
-- Public API  :
--   - getVersion() -> string
--   - getUpdatedEventName() -> string
--   - getState() -> table copy
--   - getStats() -> table
--   - recompute(opts?) -> boolean ok, string|nil err
--   - getRowsOnlineOnly() -> array of row records (copy)
--   - resolveOwnedProfileLabel(name) -> string|nil profileLabel, string|nil err
--
-- Planning only (NO SEND):
--   - planSelfExec(characterName, cmd, opts?) -> table|nil plan, string|nil err
--   - planAssistExec(healerName, targetName, cmdTemplate, opts?) -> table|nil plan, string|nil err
--     cmdTemplate MUST contain "{target}" placeholder.
--
-- Events Emitted:
--   - DWKit:Service:ActionPad:Updated
-- Automation Policy: Manual only
-- Dependencies     : dwkit.core.identity, dwkit.bus.event_bus, dwkit.config.owned_profiles (best-effort),
--                    dwkit.services.presence_service (preferred), dwkit.services.whostore_service (fallback),
--                    dwkit.services.cross_profile_comm_service (fallback)
-- #########################################################################

local M = {}

M.VERSION = "v2026-03-04D"

local ID = require("dwkit.core.identity")
local BUS = require("dwkit.bus.event_bus")

local EV_UPDATED = tostring(ID.eventPrefix or "DWKit:") .. "Service:ActionPad:Updated"
M.EV_UPDATED = EV_UPDATED

local STATE = {
    rowsOnline = {}, -- array of { name, profileLabel, online=true, here=true/false, source="presence|fallback" }
    lastTs = nil,
    updates = 0,
    lastSource = nil,
    lastErr = nil,
}

-- -------------------------------------------------------------------------
-- small helpers
-- -------------------------------------------------------------------------

local function _shallowCopy(t)
    local out = {}
    if type(t) ~= "table" then return out end
    for k, v in pairs(t) do out[k] = v end
    return out
end

local function _copyArrayOfTables(arr)
    local out = {}
    if type(arr) ~= "table" then return out end
    for i = 1, #arr do
        if type(arr[i]) == "table" then
            out[i] = _shallowCopy(arr[i])
        else
            out[i] = arr[i]
        end
    end
    return out
end

local function _trim(s)
    s = tostring(s or "")
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function _safeRequire(modName)
    local ok, mod = pcall(require, modName)
    if ok then return true, mod end
    return false, mod
end

local function _sortedStringsCaseInsensitive(arr)
    arr = (type(arr) == "table") and arr or {}
    local out = {}
    for i = 1, #arr do out[#out + 1] = tostring(arr[i] or "") end
    table.sort(out, function(a, b)
        local la = tostring(a or ""):lower()
        local lb = tostring(b or ""):lower()
        if la == lb then return tostring(a or "") < tostring(b or "") end
        return la < lb
    end)
    return out
end

local function _dedupe(arr)
    arr = (type(arr) == "table") and arr or {}
    local seen = {}
    local out = {}
    for i = 1, #arr do
        local s = tostring(arr[i] or "")
        if s ~= "" and seen[s] ~= true then
            seen[s] = true
            out[#out + 1] = s
        end
    end
    return out
end

local function _emit(changed, source)
    local payload = {
        ts = os.time(),
        rowsOnline = _copyArrayOfTables(STATE.rowsOnline),
    }
    if type(changed) == "table" then payload.changed = _shallowCopy(changed) end
    if type(source) == "string" and source ~= "" then payload.source = source end

    local ok, delivered, errs = BUS.emit(EV_UPDATED, payload)
    if not ok then
        local first = (type(errs) == "table" and errs[1]) and tostring(errs[1]) or "emit failed"
        return false, first
    end
    return true, nil
end

local function _countMap(t)
    if type(t) ~= "table" then return 0 end
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- -------------------------------------------------------------------------
-- Owned profiles mapping (authoritative for "my profiles")
-- -------------------------------------------------------------------------

local function _getOwnedProfilesMapBestEffort()
    local okO, O = _safeRequire("dwkit.config.owned_profiles")
    if not okO or type(O) ~= "table" then
        return {}
    end
    if type(O.getMap) ~= "function" then
        return {}
    end
    local okM, m = pcall(O.getMap)
    if okM and type(m) == "table" then
        return m
    end
    return {}
end

function M.resolveOwnedProfileLabel(name)
    name = _trim(name)
    if name == "" then
        return nil, "resolveOwnedProfileLabel(name): name invalid"
    end

    local map = _getOwnedProfilesMapBestEffort()
    local label = map[name]
    if type(label) ~= "string" or _trim(label) == "" then
        return nil, "resolveOwnedProfileLabel(name): not mapped in owned_profiles: " .. tostring(name)
    end
    return _trim(label), nil
end

-- -------------------------------------------------------------------------
-- Presence parsing (preferred source)
-- PresenceService.myProfilesOnline lines look like:
--   "Alpha (Profile-A) [ONLINE] [HERE]"
-- -------------------------------------------------------------------------

local function _parsePresenceLine(line)
    line = tostring(line or "")
    line = _trim(line)
    if line == "" then return nil end

    local name, label = line:match("^(.+)%s%((.+)%)")
    if not name or not label then
        return nil
    end

    name = _trim(name)
    label = _trim(label)
    if name == "" or label == "" then return nil end

    local here = (line:find("%[HERE%]", 1, true) ~= nil)

    return {
        name = name,
        profileLabel = label,
        online = true,
        here = (here == true),
        source = "presence",
        raw = line,
    }
end

-- NEW: robust HERE matching using PresenceService.myProfilesHere (authoritative for "here")
local function _buildHereSets(st)
    local byKey = {}
    local byLabel = {}

    local list = (type(st) == "table" and type(st.myProfilesHere) == "table") and st.myProfilesHere or {}
    for i = 1, #list do
        local r = _parsePresenceLine(list[i])
        if r and r.name and r.profileLabel then
            local k = tostring(r.name) .. "||" .. tostring(r.profileLabel)
            byKey[k] = true
            byLabel[tostring(r.profileLabel)] = true
        else
            -- If parsing fails, still try label-only extraction:
            local s = _trim(list[i])
            local _, lbl = s:match("^(.+)%s%((.+)%)")
            if lbl and _trim(lbl) ~= "" then
                byLabel[_trim(lbl)] = true
            end
        end
    end

    return byKey, byLabel
end

local function _rowsFromPresenceBestEffort()
    local okP, P = _safeRequire("dwkit.services.presence_service")
    if not okP or type(P) ~= "table" or type(P.getState) ~= "function" then
        return nil, "presence_service not available"
    end

    local okS, st = pcall(P.getState)
    if not okS or type(st) ~= "table" then
        return nil, "presence_service.getState failed"
    end

    local onlineLines = (type(st.myProfilesOnline) == "table") and st.myProfilesOnline or {}
    local rows = {}

    for i = 1, #onlineLines do
        local r = _parsePresenceLine(onlineLines[i])
        if r then
            rows[#rows + 1] = r
        end
    end

    if #rows == 0 then
        -- Presence may be stale or uninitialized; still return empty (not error)
        return {}, nil
    end

    -- Apply HERE overrides from myProfilesHere (fixes suite determinism)
    do
        local hereByKey, hereByLabel = _buildHereSets(st)
        for i = 1, #rows do
            local r = rows[i]
            local k = tostring(r.name) .. "||" .. tostring(r.profileLabel)
            if hereByKey[k] == true or hereByLabel[tostring(r.profileLabel)] == true then
                r.here = true
            end
        end
    end

    -- Deterministic ordering
    table.sort(rows, function(a, b)
        local la = tostring(a.name or ""):lower()
        local lb = tostring(b.name or ""):lower()
        if la == lb then return tostring(a.name or "") < tostring(b.name or "") end
        return la < lb
    end)

    return rows, nil
end

-- -------------------------------------------------------------------------
-- Fallback online detection (only if Presence not available)
-- -------------------------------------------------------------------------

local function _isLocalProfileOnlineBestEffort(profileLabel)
    profileLabel = _trim(profileLabel)
    if profileLabel == "" then return false end

    local okC, C = _safeRequire("dwkit.services.cross_profile_comm_service")
    if not okC or type(C) ~= "table" then
        return false
    end
    if type(C.isProfileOnline) == "function" then
        local ok, v = pcall(C.isProfileOnline, profileLabel)
        if ok then return (v == true) end
    end
    return false
end

local function _isWhoOnlineBestEffort(name)
    name = _trim(name)
    if name == "" then return false end

    local okW, W = _safeRequire("dwkit.services.whostore_service")
    if not okW or type(W) ~= "table" then
        return false
    end

    if type(W.hasPlayer) == "function" then
        local ok, v = pcall(W.hasPlayer, name)
        if ok then return (v == true) end
    end
    if type(W.getEntry) == "function" then
        local ok, e = pcall(W.getEntry, name)
        if ok and type(e) == "table" then
            return true
        end
    end

    return false
end

local function _rowsFromFallbackBestEffort()
    local map = _getOwnedProfilesMapBestEffort()
    if _countMap(map) <= 0 then
        return {}, nil
    end

    local names = {}
    for n, label in pairs(map) do
        if type(n) == "string" and n ~= "" and type(label) == "string" and label ~= "" then
            names[#names + 1] = n
        end
    end
    names = _sortedStringsCaseInsensitive(_dedupe(names))

    local rows = {}
    for i = 1, #names do
        local n = tostring(names[i] or "")
        local label = _trim(map[n] or "")
        if n ~= "" and label ~= "" then
            local online = (_isLocalProfileOnlineBestEffort(label) == true) or (_isWhoOnlineBestEffort(n) == true)
            if online then
                rows[#rows + 1] = {
                    name = n,
                    profileLabel = label,
                    online = true,
                    here = false,
                    source = "fallback",
                }
            end
        end
    end

    return rows, nil
end

-- -------------------------------------------------------------------------
-- Public API
-- -------------------------------------------------------------------------

function M.getVersion()
    return tostring(M.VERSION)
end

function M.getUpdatedEventName()
    return tostring(EV_UPDATED)
end

function M.getState()
    return {
        version = M.VERSION,
        lastTs = STATE.lastTs,
        updates = STATE.updates,
        lastSource = STATE.lastSource,
        lastErr = STATE.lastErr,
        rowsOnline = _copyArrayOfTables(STATE.rowsOnline),
        rowCount = (type(STATE.rowsOnline) == "table") and #STATE.rowsOnline or 0,
    }
end

function M.getStats()
    local st = M.getState()
    return {
        version = st.version,
        lastTs = st.lastTs,
        updates = st.updates,
        rowCount = st.rowCount,
        lastSource = st.lastSource,
        lastErr = st.lastErr,
    }
end

function M.getRowsOnlineOnly()
    return _copyArrayOfTables(STATE.rowsOnline)
end

function M.recompute(opts)
    opts = (type(opts) == "table") and opts or {}
    local source = tostring(opts.source or "actionpad:recompute")

    local rows, err = _rowsFromPresenceBestEffort()
    local used = "presence"
    if rows == nil then
        rows, err = _rowsFromFallbackBestEffort()
        used = "fallback"
    end
    if type(rows) ~= "table" then
        STATE.lastErr = tostring(err or "recompute failed")
        return false, STATE.lastErr
    end

    STATE.rowsOnline = rows
    STATE.lastTs = os.time()
    STATE.updates = (tonumber(STATE.updates) or 0) + 1
    STATE.lastSource = used
    STATE.lastErr = nil

    local okEmit, errEmit = _emit({ recompute = true, sourceUsed = used }, source)
    if not okEmit then
        STATE.lastErr = tostring(errEmit)
        return false, STATE.lastErr
    end

    return true, nil
end

-- Planning only: NO send, NO raiseGlobalEvent.
local function _validateCmdSingleLine(cmd)
    cmd = tostring(cmd or "")
    cmd = _trim(cmd)
    if cmd == "" then
        return nil, "cmd required"
    end
    if cmd:find("\n", 1, true) or cmd:find("\r", 1, true) then
        return nil, "cmd must be single-line"
    end
    return cmd, nil
end

function M.planSelfExec(characterName, cmd, opts)
    opts = (type(opts) == "table") and opts or {}
    characterName = _trim(characterName)

    if characterName == "" then
        return nil, "planSelfExec(characterName, cmd): characterName invalid"
    end

    local label, err = M.resolveOwnedProfileLabel(characterName)
    if not label then
        return nil, tostring(err)
    end

    local cmd1, errCmd = _validateCmdSingleLine(cmd)
    if not cmd1 then
        return nil, "planSelfExec: " .. tostring(errCmd)
    end

    return {
        kind = "remoteexec_plan",
        action = "SEND",
        targetProfile = label,
        cmd = cmd1,
        source = tostring(opts.source or "actionpad:planSelfExec"),
        note = "PLAN ONLY. Use RemoteExecService.send(targetProfile, cmd) manually if desired.",
    }, nil
end

function M.planAssistExec(healerName, targetName, cmdTemplate, opts)
    opts = (type(opts) == "table") and opts or {}
    healerName = _trim(healerName)
    targetName = _trim(targetName)

    if healerName == "" then
        return nil, "planAssistExec(healerName,...): healerName invalid"
    end
    if targetName == "" then
        return nil, "planAssistExec(..., targetName,...): targetName invalid"
    end

    local healerLabel, err = M.resolveOwnedProfileLabel(healerName)
    if not healerLabel then
        return nil, tostring(err)
    end

    cmdTemplate = tostring(cmdTemplate or "")
    if cmdTemplate == "" then
        return nil, "planAssistExec: cmdTemplate required"
    end

    if cmdTemplate:find("{target}", 1, true) == nil then
        return nil, "planAssistExec: cmdTemplate must contain {target} placeholder"
    end

    local cmdBuilt = cmdTemplate:gsub("{target}", targetName)
    local cmd1, errCmd = _validateCmdSingleLine(cmdBuilt)
    if not cmd1 then
        return nil, "planAssistExec: " .. tostring(errCmd)
    end

    return {
        kind = "remoteexec_plan",
        action = "SEND",
        targetProfile = healerLabel,
        cmd = cmd1,
        healerName = healerName,
        targetName = targetName,
        source = tostring(opts.source or "actionpad:planAssistExec"),
        note = "PLAN ONLY. Use RemoteExecService.send(targetProfile, cmd) manually if desired.",
    }, nil
end

function M.onUpdated(handlerFn)
    return BUS.on(EV_UPDATED, handlerFn)
end

-- Seed initial state (no emit)
do
    STATE.rowsOnline = {}
end

return M
-- END FILE: src/dwkit/services/actionpad_service.lua
