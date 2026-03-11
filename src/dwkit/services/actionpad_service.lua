-- FILE: src/dwkit/services/actionpad_service.lua
-- #########################################################################
-- Module Name : dwkit.services.actionpad_service
-- Owner       : Services
-- Version     : v2026-03-11A
-- Purpose     :
--   - SAFE ActionPadService (data only).
--   - Produces "online-only" roster rows for ActionPad UI, based on PresenceService
--     roster when available (preferred), otherwise best-effort fallback to owned_profiles
--     + CPC local-online + WhoStore online.
--   - Provides deterministic planning helpers for RemoteExec.
--   - Provides deterministic dispatch helpers for RemoteExec (Bucket D), WITHOUT UI,
--     WITHOUT persistence, manual-triggered only.
--   - Provides deterministic gating helpers for ActionPad UI (Practice/Score/Registry),
--     WITHOUT sending.
--   - Supports represented-row facts for gating when provided by caller
--     (for example CPC-fed row facts), while preserving current local-store
--     fallback behavior when row facts are absent.
--   - When represented-row facts are present but incomplete, does NOT leak
--     viewer-local PracticeStore/ScoreStore state into that row's gate result.
--   - Provides best-effort row-facts lookup by represented character using existing
--     owned_profiles + CPC composition.
--   - Provides deterministic assistBy/healer selection helpers for ActionPad UI (Bucket C),
--     WITHOUT sending, WITHOUT persistence.
--   - No UI, no persistence, no timers.
--
-- Public API  :
--   - getVersion() -> string
--   - getUpdatedEventName() -> string
--   - getState() -> table copy
--   - getStats() -> table
--   - recompute(opts?) -> boolean ok, string|nil err
--   - getRowsOnlineOnly() -> array of row records (copy)
--   - resolveOwnedProfileLabel(name) -> string|nil profileLabel, string|nil err
--   - getRowFactsForCharacter(name) -> table|nil
--
-- AssistBy / Healer selection (NO SEND):
--   - getAssistByState() -> table (copy)
--       returns { mode="auto|manual", selectedName?, resolvedName?, resolvedOnline?,
--                 candidates={names...}, lastReason? }
--   - setAssistByAuto(opts?) -> boolean ok, string|nil err
--   - setAssistBySelected(name, opts?) -> boolean ok, string|nil err
--   - cycleAssistBy(delta, opts?) -> string|nil resolvedName, string|nil err
--
-- Planning only:
--   - planSelfExec(characterName, cmd, opts?) -> table|nil plan, string|nil err
--   - planAssistExec(healerName, targetName, cmdTemplate, opts?) -> table|nil plan, string|nil err
--     cmdTemplate MUST contain "{target}" placeholder.
--
-- Dispatch (Bucket D; manual-triggered only):
--   - dispatchSelfExec(characterName, cmd, opts?) -> table|nil result, string|nil err
--   - dispatchAssistExec(healerName, targetName, cmdTemplate, opts?) -> table|nil result, string|nil err
--     result:
--       {
--         kind="remoteexec_dispatch",
--         action="SEND",
--         dispatched=true|false,
--         mode="dispatch|plan_only",
--         reason="ok|todo_placeholder",
--         detail=string,
--         targetProfile=...,
--         cmd=...,
--         source=...,
--         healerName?,
--         targetName?
--       }
--
-- Gating (NO SEND):
--   - resolveActionGate(spec, opts?) -> table gate
--       spec: { kind, practiceKey, displayName?, minLevel?, classKey?, rowFacts? }
--       opts:
--         - honorSpec=true: if spec explicitly provides classKey/minLevel, do not override
--           those fields from SkillRegistry def. (Default false; UI uses default behavior.)
--         - rowFacts=table: represented-row facts override local viewer facts when provided.
--           Supported best-effort fields:
--             * name
--             * classKey or class
--             * level
--             * practiceStatusByKey[practiceKey] = { ok, learned, reason, ... }
--             * learnedByPracticeKey[practiceKey] = true|false
--             * practiceStale=true
--             * scoreStale=true
--       gate: { enabled, reason, detail, learned?, tier?, cost?, percent?, level?, classKey? }
--
-- Events Emitted:
--   - DWKit:Service:ActionPad:Updated
-- Automation Policy: Manual only
-- Dependencies     : dwkit.core.identity, dwkit.bus.event_bus, dwkit.config.owned_profiles (best-effort),
--                    dwkit.services.presence_service (preferred), dwkit.services.whostore_service (fallback),
--                    dwkit.services.cross_profile_comm_service (fallback),
--                    dwkit.services.practice_store_service (best-effort),
--                    dwkit.services.score_store_service (best-effort),
--                    dwkit.services.skill_registry_service (best-effort),
--                    dwkit.services.remote_exec_service (best-effort; Bucket D)
-- #########################################################################

local M = {}

M.VERSION = "v2026-03-11A"

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

    assistBy = {
        mode = "auto",
        selectedName = nil,
        resolvedName = nil,
        resolvedOnline = false,
        candidates = {},
        lastReason = nil,
    },
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

local function _deepCopy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, val in pairs(v) do
        out[k] = _deepCopy(val)
    end
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

local function _isTodoCmd(cmd)
    cmd = _trim(cmd)
    if cmd == "" then return false end
    return (_trim(cmd):match("^%[TODO%]") ~= nil)
end

local function _getRemoteExecBestEffort()
    local okR, R = _safeRequire("dwkit.services.remote_exec_service")
    if not okR or type(R) ~= "table" then
        return nil, "remote_exec_service not available"
    end
    return R, nil
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

local function _findOnlineRowByName(name)
    name = _trim(name)
    if name == "" then return nil end
    local rows = (type(STATE.rowsOnline) == "table") and STATE.rowsOnline or {}
    for i = 1, #rows do
        local r = rows[i]
        if type(r) == "table" and tostring(r.name or "") == name then
            return r
        end
    end
    return nil
end

-- -------------------------------------------------------------------------
-- Presence parsing (preferred source)
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
        return {}, nil
    end

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

    table.sort(rows, function(a, b)
        local la = tostring(a.name or ""):lower()
        local lb = tostring(b.name or ""):lower()
        if la == lb then return tostring(a.name or "") < tostring(b.name or "") end
        return la < lb
    end)

    return rows, nil
end

-- -------------------------------------------------------------------------
-- Fallback online detection
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
-- Bucket C: assistBy/healer selection
-- -------------------------------------------------------------------------

local function _assistByBuildCandidates()
    local names = {}
    local rows = (type(STATE.rowsOnline) == "table") and STATE.rowsOnline or {}
    for i = 1, #rows do
        local r = rows[i] or {}
        local n = _trim(r.name)
        if n ~= "" then
            names[#names + 1] = n
        end
    end
    names = _sortedStringsCaseInsensitive(_dedupe(names))
    return names
end

local function _assistByIsOnline(name)
    name = _trim(name)
    if name == "" then return false end
    local rows = (type(STATE.rowsOnline) == "table") and STATE.rowsOnline or {}
    for i = 1, #rows do
        local r = rows[i] or {}
        if tostring(r.name or "") == name and r.online == true then
            return true
        end
    end
    return false
end

local function _assistByResolve()
    local st = STATE.assistBy
    st.candidates = _assistByBuildCandidates()

    if st.mode == "manual" then
        local sel = _trim(st.selectedName)
        if sel ~= "" and _assistByIsOnline(sel) == true then
            st.resolvedName = sel
            st.resolvedOnline = true
            st.lastReason = "manual:ok"
            return st.resolvedName
        end
        st.resolvedName = nil
        st.resolvedOnline = false
        if sel == "" then
            st.lastReason = "manual:missing"
        else
            st.lastReason = "manual:offline"
        end
        return nil
    end

    if type(st.candidates) == "table" and #st.candidates > 0 then
        st.resolvedName = tostring(st.candidates[1])
        st.resolvedOnline = true
        st.lastReason = "auto:first_online"
        return st.resolvedName
    end

    st.resolvedName = nil
    st.resolvedOnline = false
    st.lastReason = "auto:none_online"
    return nil
end

function M.getAssistByState()
    _assistByResolve()
    return _shallowCopy(STATE.assistBy)
end

function M.setAssistByAuto(opts)
    opts = (type(opts) == "table") and opts or {}
    STATE.assistBy.mode = "auto"
    STATE.assistBy.selectedName = nil
    _assistByResolve()

    local src = tostring(opts.source or "actionpad:setAssistByAuto")
    local okEmit, errEmit = _emit({ assistBy = "auto" }, src)
    if not okEmit then
        return false, tostring(errEmit)
    end
    return true, nil
end

function M.setAssistBySelected(name, opts)
    opts = (type(opts) == "table") and opts or {}
    name = _trim(name)
    if name == "" then
        return false, "setAssistBySelected(name): name invalid"
    end

    local _, err = M.resolveOwnedProfileLabel(name)
    if err then
        return false, "setAssistBySelected: " .. tostring(err)
    end

    STATE.assistBy.mode = "manual"
    STATE.assistBy.selectedName = name
    _assistByResolve()

    local src = tostring(opts.source or "actionpad:setAssistBySelected")
    local okEmit, errEmit = _emit({ assistBy = "manual", selectedName = name }, src)
    if not okEmit then
        return false, tostring(errEmit)
    end
    return true, nil
end

function M.cycleAssistBy(delta, opts)
    opts = (type(opts) == "table") and opts or {}
    delta = tonumber(delta or 1) or 1
    if delta == 0 then delta = 1 end

    local names = _assistByBuildCandidates()
    if type(names) ~= "table" or #names == 0 then
        STATE.assistBy.mode = "auto"
        STATE.assistBy.selectedName = nil
        _assistByResolve()
        return nil, "cycleAssistBy: no online owned candidates"
    end

    local cur = _trim(STATE.assistBy.resolvedName)
    local idx = 0
    if cur ~= "" then
        for i = 1, #names do
            if tostring(names[i]) == cur then
                idx = i
                break
            end
        end
    end
    if idx == 0 then idx = 1 end

    local n = #names
    local nextIdx = idx + delta
    while nextIdx < 1 do nextIdx = nextIdx + n end
    while nextIdx > n do nextIdx = nextIdx - n end

    local pick = tostring(names[nextIdx])
    STATE.assistBy.mode = "manual"
    STATE.assistBy.selectedName = pick
    _assistByResolve()

    local src = tostring(opts.source or "actionpad:cycleAssistBy")
    local okEmit, errEmit = _emit({ assistBy = "manual", selectedName = pick }, src)
    if not okEmit then
        return nil, tostring(errEmit)
    end

    return pick, nil
end

-- -------------------------------------------------------------------------
-- Represented-row facts helpers
-- -------------------------------------------------------------------------

local function _getCrossProfileRowFactsBestEffort(profileLabel)
    profileLabel = _trim(profileLabel)
    if profileLabel == "" then return nil end

    local okC, C = _safeRequire("dwkit.services.cross_profile_comm_service")
    if not okC or type(C) ~= "table" then
        return nil
    end
    if type(C.getRowFactsByProfile) ~= "function" then
        return nil
    end

    local ok, rf = pcall(C.getRowFactsByProfile, profileLabel)
    if not ok or type(rf) ~= "table" then
        return nil
    end
    return _deepCopy(rf)
end

function M.getRowFactsForCharacter(name)
    name = _trim(name)
    if name == "" then return nil end

    local row = _findOnlineRowByName(name)
    if type(row) ~= "table" then
        return nil
    end

    local profileLabel = _trim(row.profileLabel)
    if profileLabel == "" then
        return nil
    end

    local rf = _getCrossProfileRowFactsBestEffort(profileLabel)
    if type(rf) ~= "table" then
        return nil
    end

    if _trim(rf.name) == "" then
        rf.name = name
    end
    rf.profileLabel = profileLabel
    return rf
end

-- -------------------------------------------------------------------------
-- Gating helpers
-- -------------------------------------------------------------------------

local function _normalizePracticeKeyBestEffort(raw)
    local okP, P = _safeRequire("dwkit.services.practice_store_service")
    if okP and type(P) == "table" and type(P.normalizePracticeKey) == "function" then
        local ok, k = pcall(P.normalizePracticeKey, tostring(raw or ""))
        if ok and type(k) == "string" and _trim(k) ~= "" then
            return _trim(k)
        end
    end
    return _trim(raw)
end

local function _normalizeClassKeyBestEffort(displayClass)
    local okR, R = _safeRequire("dwkit.services.skill_registry_service")
    if okR and type(R) == "table" and type(R.normalizeClassKey) == "function" then
        local ok, ck, err = pcall(R.normalizeClassKey, tostring(displayClass or ""))
        if ok and type(ck) == "string" and ck ~= "" then
            return ck, nil
        end
        return nil, tostring(err or "normalizeClassKey failed")
    end
    return nil, "skill_registry_service.normalizeClassKey not available"
end

local function _skillRegistryResolveBestEffort(kind, practiceKey)
    kind = _trim(kind)
    practiceKey = _normalizePracticeKeyBestEffort(practiceKey)

    local okS, S = _safeRequire("dwkit.services.skill_registry_service")
    if not okS or type(S) ~= "table" then
        return nil
    end

    local def = nil

    if type(S.resolveByPracticeKey) == "function" then
        local ok, v = pcall(S.resolveByPracticeKey, practiceKey)
        if ok and type(v) == "table" then def = v end
    end

    if not def and type(S.getRegistry) == "function" then
        local ok, reg = pcall(S.getRegistry)
        if ok and type(reg) == "table" then
            def = reg[practiceKey]
        end
    end

    if type(def) ~= "table" then
        return nil
    end

    if kind ~= "" and tostring(def.kind or "") ~= "" then
        if tostring(def.kind) ~= kind then
            return nil
        end
    end

    return def
end

local function _skillRegistryLearnReqBestEffort(def, rowClassKey)
    if type(def) ~= "table" then
        return nil
    end

    local okS, S = _safeRequire("dwkit.services.skill_registry_service")
    if okS and type(S) == "table" and type(S.getLearnRequirementForClass) == "function" then
        local ok, req, err = pcall(S.getLearnRequirementForClass, def, rowClassKey)
        if ok and type(req) == "table" then
            return req
        end
    end

    if type(rowClassKey) == "string" and rowClassKey ~= "" then
        local specs = def.learnSpecs
        if type(specs) == "table" then
            for i = 1, #specs do
                local spec = specs[i]
                if type(spec) == "table" and tostring(spec.classKey or "") == rowClassKey then
                    return {
                        classKey = tostring(spec.classKey or ""),
                        minLevel = tonumber(spec.minLevel or 0) or 0,
                        tags = type(spec.tags) == "table" and spec.tags or {},
                        source = "learnSpecs:fallback",
                        matched = true,
                    }
                end
            end
        end
    end

    if _trim(def.classKey) ~= "" and tonumber(def.minLevel) ~= nil then
        return {
            classKey = _trim(def.classKey),
            minLevel = tonumber(def.minLevel),
            tags = type(def.tags) == "table" and def.tags or {},
            source = "legacy:fallback",
            matched = true,
        }
    end

    local specs = def.learnSpecs
    if type(specs) == "table" and #specs == 1 and type(specs[1]) == "table" then
        return {
            classKey = tostring(specs[1].classKey or ""),
            minLevel = tonumber(specs[1].minLevel or 0) or 0,
            tags = type(specs[1].tags) == "table" and specs[1].tags or {},
            source = "learnSpecs:first_fallback",
            matched = true,
        }
    end

    return nil
end

local function _scoreCoreBestEffort()
    local okS, S = _safeRequire("dwkit.services.score_store_service")
    if not okS or type(S) ~= "table" or type(S.getCore) ~= "function" then
        return { ok = false, reason = "unknown_stale" }
    end
    local ok, core = pcall(S.getCore)
    if not ok or type(core) ~= "table" then
        return { ok = false, reason = "unknown_stale" }
    end
    return core
end

local function _practiceLearnStatusBestEffort(kind, practiceKey)
    local okP, P = _safeRequire("dwkit.services.practice_store_service")
    if not okP or type(P) ~= "table" or type(P.getLearnStatus) ~= "function" then
        return {
            ok = false,
            learned = false,
            reason = "unknown_stale",
            hasSnapshot = false,
            hasParsed = false,
        }
    end
    local ok, st = pcall(P.getLearnStatus, tostring(kind or ""), tostring(practiceKey or ""))
    if not ok or type(st) ~= "table" then
        return {
            ok = false,
            learned = false,
            reason = "unknown_stale",
            hasSnapshot = false,
            hasParsed = false,
        }
    end
    return st
end

local function _resolveRowFacts(spec, opts)
    spec = (type(spec) == "table") and spec or {}
    opts = (type(opts) == "table") and opts or {}
    local rowFacts = nil

    if type(opts.rowFacts) == "table" then
        rowFacts = opts.rowFacts
    elseif type(spec.rowFacts) == "table" then
        rowFacts = spec.rowFacts
    end

    if type(rowFacts) ~= "table" then
        return nil
    end

    return rowFacts
end

local function _practiceStatusFromRowFacts(rowFacts, kind, practiceKey)
    if type(rowFacts) ~= "table" then
        return nil
    end

    if rowFacts.practiceStale == true or tostring(rowFacts.practiceState or "") == "stale" then
        return {
            ok = false,
            learned = false,
            reason = "unknown_stale",
            hasSnapshot = false,
            hasParsed = false,
            source = "rowFacts",
        }
    end

    local map = nil
    if type(rowFacts.practiceStatusByKey) == "table" then
        map = rowFacts.practiceStatusByKey
    elseif type(rowFacts.practiceStatuses) == "table" then
        map = rowFacts.practiceStatuses
    end

    if type(map) == "table" then
        local st = map[practiceKey] or map[tostring(kind or "") .. ":" .. tostring(practiceKey or "")]
        if type(st) == "table" then
            local out = _shallowCopy(st)
            if out.ok == nil and out.learned == true and _trim(out.reason) == "" then
                out.ok = true
                out.reason = "ok"
            elseif out.ok == nil and out.learned == false and _trim(out.reason) == "" then
                out.ok = true
                out.reason = "not_learned"
            end
            if _trim(out.reason) == "" then
                out.reason = "ok"
            end
            out.source = "rowFacts"
            return out
        end
    end

    local learnedMap = nil
    if type(rowFacts.learnedByPracticeKey) == "table" then
        learnedMap = rowFacts.learnedByPracticeKey
    elseif type(rowFacts.practiceKeysLearned) == "table" then
        learnedMap = rowFacts.practiceKeysLearned
    end

    if type(learnedMap) == "table" then
        local v = learnedMap[practiceKey]
        if v == true then
            return {
                ok = true,
                learned = true,
                reason = "ok",
                hasSnapshot = true,
                hasParsed = true,
                source = "rowFacts",
            }
        elseif v == false then
            return {
                ok = true,
                learned = false,
                reason = "not_learned",
                hasSnapshot = true,
                hasParsed = true,
                source = "rowFacts",
            }
        end
    end

    return nil
end

local function _missingPracticeStatusFromRowFacts(rowFacts)
    return {
        ok = false,
        learned = false,
        reason = "unknown_stale",
        hasSnapshot = false,
        hasParsed = false,
        source = "rowFacts:missing_practice",
    }
end

local function _rowFactsClassKey(rowFacts)
    if type(rowFacts) ~= "table" then
        return nil
    end

    local ck = _trim(rowFacts.classKey)
    if ck ~= "" then
        local norm, err = _normalizeClassKeyBestEffort(ck)
        if norm then return norm end
    end

    local cls = _trim(rowFacts.class)
    if cls ~= "" then
        local norm, err = _normalizeClassKeyBestEffort(cls)
        if norm then return norm end
    end

    return nil
end

local function _missingScoreCoreFromRowFacts(rowFacts)
    rowFacts = (type(rowFacts) == "table") and rowFacts or {}
    return {
        ok = false,
        reason = "unknown_stale",
        source = "rowFacts:missing_score",
        name = _trim(rowFacts.name),
        class = _trim(rowFacts.class),
        classKey = _rowFactsClassKey(rowFacts),
        level = tonumber(rowFacts.level),
    }
end

local function _rowFactsScoreCore(rowFacts)
    if type(rowFacts) ~= "table" then
        return nil
    end

    if rowFacts.scoreStale == true or tostring(rowFacts.scoreState or "") == "stale" then
        return {
            ok = false,
            reason = "unknown_stale",
            source = "rowFacts",
        }
    end

    local level = tonumber(rowFacts.level)
    local classKey = _rowFactsClassKey(rowFacts)
    local classDisplay = _trim(rowFacts.class)
    local name = _trim(rowFacts.name)
    local hasClass = (classKey ~= nil) or (classDisplay ~= "")

    if level ~= nil and hasClass then
        return {
            ok = true,
            reason = "ok",
            source = "rowFacts",
            level = level,
            classKey = classKey,
            class = classDisplay ~= "" and classDisplay or classKey,
            name = name,
        }
    end

    return nil
end

local function _mkGate(enabled, reason, detail)
    return {
        enabled = (enabled == true),
        reason = tostring(reason or ""),
        detail = tostring(detail or ""),
    }
end

function M.resolveActionGate(spec, opts)
    spec = (type(spec) == "table") and spec or {}
    opts = (type(opts) == "table") and opts or {}

    local rawSpecMin = spec.minLevel
    local rawSpecClass = spec.classKey

    local kind = _trim(spec.kind)
    local practiceKey = _normalizePracticeKeyBestEffort(spec.practiceKey)
    local displayName = _trim(spec.displayName)
    local wantMinLevel = tonumber(spec.minLevel)
    local wantClassKey = _trim(spec.classKey)

    if kind == "" or practiceKey == "" then
        return _mkGate(false, "bad_spec", "missing kind/practiceKey")
    end

    local rowFacts = _resolveRowFacts(spec, opts)
    local rowFactsActive = (type(rowFacts) == "table")
    local rowClassKey = _rowFactsClassKey(rowFacts)

    local def = _skillRegistryResolveBestEffort(kind, practiceKey)
    if type(def) == "table" then
        local honorSpec = (opts.honorSpec == true)
        local learnReq = _skillRegistryLearnReqBestEffort(def, rowClassKey)

        if honorSpec ~= true or rawSpecMin == nil then
            if type(learnReq) == "table" and tonumber(learnReq.minLevel) ~= nil then
                wantMinLevel = tonumber(learnReq.minLevel)
            elseif tonumber(def.minLevel) ~= nil then
                wantMinLevel = tonumber(def.minLevel)
            end
        end

        if honorSpec ~= true or rawSpecClass == nil then
            if type(learnReq) == "table" and _trim(learnReq.classKey) ~= "" then
                wantClassKey = _trim(learnReq.classKey)
            elseif _trim(def.classKey) ~= "" then
                wantClassKey = _trim(def.classKey)
            end
        end

        if displayName == "" and _trim(def.displayName) ~= "" then displayName = _trim(def.displayName) end
    end
    if displayName == "" then displayName = practiceKey end

    local pst = _practiceStatusFromRowFacts(rowFacts, kind, practiceKey)
    if type(pst) ~= "table" then
        if rowFactsActive == true then
            pst = _missingPracticeStatusFromRowFacts(rowFacts)
        else
            pst = _practiceLearnStatusBestEffort(kind, practiceKey)
        end
    end

    if tostring(pst.reason or "") == "unknown_stale" then
        local g = _mkGate(false, "unknown_stale.practice", "Practice snapshot missing/stale")
        g.learned = (pst.learned == true)
        g.tier = pst.tier
        g.cost = pst.cost
        g.percent = pst.percent
        g.source = pst.source
        return g
    end

    if tostring(pst.reason or "") == "not_learned" or pst.learned == false then
        local g = _mkGate(false, "not_learned", "Not learned: " .. tostring(displayName))
        g.learned = false
        g.tier = pst.tier
        g.cost = pst.cost
        g.percent = pst.percent
        g.source = pst.source
        return g
    end

    if pst.ok ~= true or tostring(pst.reason or "") ~= "ok" then
        local g = _mkGate(false, "not_listed", "Not listed in PracticeStore: " .. tostring(displayName))
        g.learned = (pst.learned == true)
        g.tier = pst.tier
        g.cost = pst.cost
        g.percent = pst.percent
        g.source = pst.source
        return g
    end

    local scoreNeeded = false
    if tonumber(wantMinLevel) ~= nil then scoreNeeded = true end
    if wantClassKey ~= "" then scoreNeeded = true end

    local core = nil
    local classKey = nil
    local level = nil

    if scoreNeeded then
        core = _rowFactsScoreCore(rowFacts)
        if type(core) ~= "table" then
            if rowFactsActive == true then
                core = _missingScoreCoreFromRowFacts(rowFacts)
            else
                core = _scoreCoreBestEffort()
            end
        end

        if tostring(core.reason or "") == "unknown_stale" or core.ok ~= true then
            local g = _mkGate(false, "unknown_stale.score", "Score snapshot missing/stale")
            g.learned = true
            g.level = core.level
            g.class = core.class
            g.classKey = core.classKey
            g.name = core.name
            g.source = core.source
            return g
        end

        level = tonumber(core.level or 0) or 0
        classKey = _trim(core.classKey)
        if classKey == "" then
            local ck, errCk = _normalizeClassKeyBestEffort(core.class)
            classKey = ck
        end

        if wantClassKey ~= "" and classKey ~= wantClassKey then
            local got = tostring(classKey or "unknown")
            local g = _mkGate(false, "wrong_class",
                string.format("Wrong class: need=%s got=%s", tostring(wantClassKey), got))
            g.learned = true
            g.level = level
            g.classKey = classKey
            g.class = core.class
            g.name = core.name
            g.source = core.source
            return g
        end

        if tonumber(wantMinLevel) ~= nil and level < tonumber(wantMinLevel) then
            local g = _mkGate(false, "below_level",
                string.format("Below level: need=%s got=%s", tostring(wantMinLevel), tostring(level)))
            g.learned = true
            g.level = level
            g.classKey = classKey
            g.class = core.class
            g.name = core.name
            g.source = core.source
            return g
        end
    end

    local g = _mkGate(true, "ok", "OK: " .. tostring(displayName))
    g.learned = true
    g.tier = pst.tier
    g.cost = pst.cost
    g.percent = pst.percent
    g.level = level
    g.classKey = classKey
    g.name = type(rowFacts) == "table" and _trim(rowFacts.name) or nil
    if type(core) == "table" then
        g.class = core.class
        g.name = g.name or core.name
        g.source = core.source or pst.source
    else
        g.source = pst.source
    end
    return g
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
        assistBy = _shallowCopy(M.getAssistByState()),
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

    _assistByResolve()

    local okEmit, errEmit = _emit({ recompute = true, sourceUsed = used }, source)
    if not okEmit then
        STATE.lastErr = tostring(errEmit)
        return false, STATE.lastErr
    end

    return true, nil
end

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

function M.dispatchSelfExec(characterName, cmd, opts)
    opts = (type(opts) == "table") and opts or {}
    local plan, errPlan = M.planSelfExec(characterName, cmd, opts)
    if not plan then
        return nil, tostring(errPlan)
    end

    if _isTodoCmd(plan.cmd) == true then
        return {
            kind = "remoteexec_dispatch",
            action = "SEND",
            dispatched = false,
            mode = "plan_only",
            reason = "todo_placeholder",
            detail = "Placeholder command remains PLAN-only",
            targetProfile = tostring(plan.targetProfile),
            cmd = tostring(plan.cmd),
            source = tostring(plan.source),
        }, nil
    end

    local R, errR = _getRemoteExecBestEffort()
    if not R then
        return nil, tostring(errR)
    end

    local okSend, errSend = R.send(plan.targetProfile, plan.cmd, { source = plan.source })
    if okSend ~= true then
        return nil, "dispatchSelfExec: " .. tostring(errSend)
    end

    return {
        kind = "remoteexec_dispatch",
        action = "SEND",
        dispatched = true,
        mode = "dispatch",
        reason = "ok",
        detail = "Delivery attempted via RemoteExecService.send; receiver allowlist still applies",
        targetProfile = tostring(plan.targetProfile),
        cmd = tostring(plan.cmd),
        source = tostring(plan.source),
    }, nil
end

function M.dispatchAssistExec(healerName, targetName, cmdTemplate, opts)
    opts = (type(opts) == "table") and opts or {}
    local plan, errPlan = M.planAssistExec(healerName, targetName, cmdTemplate, opts)
    if not plan then
        return nil, tostring(errPlan)
    end

    if _isTodoCmd(plan.cmd) == true then
        return {
            kind = "remoteexec_dispatch",
            action = "SEND",
            dispatched = false,
            mode = "plan_only",
            reason = "todo_placeholder",
            detail = "Placeholder command remains PLAN-only",
            targetProfile = tostring(plan.targetProfile),
            cmd = tostring(plan.cmd),
            healerName = tostring(plan.healerName or ""),
            targetName = tostring(plan.targetName or ""),
            source = tostring(plan.source),
        }, nil
    end

    local R, errR = _getRemoteExecBestEffort()
    if not R then
        return nil, tostring(errR)
    end

    local okSend, errSend = R.send(plan.targetProfile, plan.cmd, { source = plan.source })
    if okSend ~= true then
        return nil, "dispatchAssistExec: " .. tostring(errSend)
    end

    return {
        kind = "remoteexec_dispatch",
        action = "SEND",
        dispatched = true,
        mode = "dispatch",
        reason = "ok",
        detail = "Delivery attempted via RemoteExecService.send; receiver allowlist still applies",
        targetProfile = tostring(plan.targetProfile),
        cmd = tostring(plan.cmd),
        healerName = tostring(plan.healerName or ""),
        targetName = tostring(plan.targetName or ""),
        source = tostring(plan.source),
    }, nil
end

function M.onUpdated(handlerFn)
    return BUS.on(EV_UPDATED, handlerFn)
end

do
    STATE.rowsOnline = {}
    _assistByResolve()
end

return M
-- END FILE: src/dwkit/services/actionpad_service.lua
