-- #########################################################################
-- Module Name : dwkit.services.roomfeed_status_service
-- Owner       : Services
-- Version     : v2026-02-02B
-- Purpose     :
--   - Provide a shared, UI-consumable "Room Watch Health State" for passive room output capture.
--   - Owns the persistent watch toggle (on/off) and tracks capture freshness / degradation hints.
--   - Does NOT install triggers itself (separation: capture module owns triggers).
--   - SAFE: no gameplay commands, no timers, no hidden automation.
--
-- Public API  :
--   - getVersion() -> string
--   - getUpdatedEventName() -> string
--   - getState() -> table (copy)   (includes compat fields for dwroom)
--   - getHealth(nowTs?) -> table { state="LIVE|PAUSED|STALE|DEGRADED", note=string, ageSec=number|nil }
--   - getWatchEnabled() -> boolean|nil
--   - hasUserSetWatch() -> boolean
--   - setWatchEnabled(enabled:boolean, opts?) -> boolean ok, string|nil err
--       opts.noSave=true to avoid persistence (verification use)
--   - noteSnapshot(meta?) -> boolean ok, string|nil err
--   - noteAbort(reason:string, meta?) -> boolean ok, string|nil err
--   - noteDegraded(reason:string, meta?) -> boolean ok, string|nil err
--   - clearDegraded(opts?) -> boolean ok, string|nil err
--   - status(opts?) -> table state (also prints unless opts.quiet=true)
--
-- Compatibility (for dwroom.lua that is already applied):
--   - setEnabled(enabled:boolean, opts?) -> ok, err   (alias to setWatchEnabled)
--   - getHealthState(opts?) -> healthStateString, stateTable
--       opts.nowTs optional
--
-- Events Emitted   :
--   - DWKit:Service:RoomFeedStatus:Updated
--     payload: { ts, delta, state }
-- Events Consumed  : None
-- Persistence      :
--   - fileKey: roomfeed_status
--   - schemaVersion: 1
-- Automation Policy: Manual + Passive Capture support (no active polling)
-- Dependencies     : dwkit.core.identity, dwkit.persist.store, dwkit.bus.event_bus
-- #########################################################################

local M = {}

M.VERSION = "v2026-02-02B"

local ID = require("dwkit.core.identity")

local EV_UPDATED = tostring(ID.eventPrefix or "DWKit:") .. "Service:RoomFeedStatus:Updated"
M.EV_UPDATED = EV_UPDATED

local FILE_KEY = "roomfeed_status"
local SCHEMA_VERSION = 1

local DEFAULT_STALE_SEC = 90

local STATE = {
    loaded = false,
    state = {
        -- canonical keys
        watchEnabled = nil,
        userSetWatch = false,
        lastSetTs = nil,

        lastSnapshotTs = nil,
        lastSnapshotSource = nil,

        lastAbortReason = nil,
        lastAbortTs = nil,

        degradedReason = nil,
        degradedTs = nil,

        updates = 0,
        emits = 0,
        lastEmitTs = nil,

        staleThresholdSec = DEFAULT_STALE_SEC,
    },
}

local function _nowTs()
    return os.time()
end

local function _out(line)
    line = tostring(line or "")
    if line == "" then return end
    if _G.echo then
        _G.echo("[DWKit RoomWatch] " .. line .. "\n")
    else
        print("[DWKit RoomWatch] " .. line)
    end
end

local function _copyOneLevel(t)
    if type(t) ~= "table" then return {} end
    local o = {}
    for k, v in pairs(t) do
        if type(v) == "table" then
            local a = {}
            for i = 1, #v do a[i] = v[i] end
            o[k] = a
        else
            o[k] = v
        end
    end
    return o
end

local function _resolveStore()
    local DW = rawget(_G, tostring(ID.packageRootGlobal or "DWKit"))
    local s = (type(DW) == "table") and DW.persist and DW.persist.store or nil

    if type(s) == "table"
        and (type(s.saveEnvelope) == "function" or type(s.save) == "function")
        and (type(s.loadEnvelope) == "function" or type(s.load) == "function")
    then
        return true, s, nil
    end

    local ok, modOrErr = pcall(require, "dwkit.persist.store")
    if ok and type(modOrErr) == "table" then
        return true, modOrErr, nil
    end
    return false, nil, tostring(modOrErr)
end

local function _resolveBus()
    local ok, modOrErr = pcall(require, "dwkit.bus.event_bus")
    if ok and type(modOrErr) == "table" and type(modOrErr.emit) == "function" then
        return true, modOrErr, nil
    end
    return false, nil, tostring(modOrErr)
end

local function _wrapEnvelope(Store, data, schemaVersion)
    if type(Store) ~= "table" then
        return { schemaVersion = schemaVersion, data = data }
    end
    if type(Store.wrap) == "function" then
        return Store.wrap(data, schemaVersion)
    end
    if type(Store.wrapEnvelope) == "function" then
        return Store.wrapEnvelope(data, schemaVersion)
    end
    return { schemaVersion = schemaVersion, data = data }
end

local function _loadEnvelopeBestEffort(Store, fileKey)
    if type(Store) ~= "table" then return nil end
    if type(Store.loadEnvelope) == "function" then
        local ok, v = pcall(function() return Store.loadEnvelope(fileKey) end)
        if ok then return v end
        return nil
    end
    if type(Store.load) == "function" then
        local ok, v = pcall(function() return Store.load(fileKey) end)
        if ok then return v end
        return nil
    end
    return nil
end

local function _saveEnvelopeBestEffort(Store, fileKey, env)
    if type(Store) ~= "table" then return false end
    if type(Store.saveEnvelope) == "function" then
        local ok = pcall(function() return Store.saveEnvelope(fileKey, env) end)
        return ok == true
    end
    if type(Store.save) == "function" then
        local ok = pcall(function() return Store.save(fileKey, env) end)
        return ok == true
    end
    return false
end

local function _loadOnce()
    if STATE.loaded then return true end

    local okS, Store = _resolveStore()
    if not okS then
        STATE.loaded = true
        return true
    end

    local envOrNil = _loadEnvelopeBestEffort(Store, FILE_KEY)

    if type(envOrNil) == "table" then
        local env = envOrNil
        local data = env.data
        local schema = tonumber(env.schemaVersion or env.schema or 0) or 0

        if schema == SCHEMA_VERSION and type(data) == "table" then
            if type(data.watchEnabled) == "boolean" then
                STATE.state.watchEnabled = data.watchEnabled
            end
            if type(data.userSetWatch) == "boolean" then
                STATE.state.userSetWatch = data.userSetWatch
            end
            if type(data.staleThresholdSec) == "number" and data.staleThresholdSec > 0 then
                STATE.state.staleThresholdSec = math.floor(data.staleThresholdSec)
            end
        end
    end

    STATE.loaded = true
    return true
end

local function _saveBestEffort(opts)
    opts = (type(opts) == "table") and opts or {}
    if opts.noSave == true then return true end

    local okS, Store = _resolveStore()
    if not okS then return false end

    local data = {
        watchEnabled = STATE.state.watchEnabled,
        userSetWatch = STATE.state.userSetWatch,
        staleThresholdSec = STATE.state.staleThresholdSec,
    }

    local env = _wrapEnvelope(Store, data, SCHEMA_VERSION)
    return _saveEnvelopeBestEffort(Store, FILE_KEY, env)
end

local function _health(nowTs)
    local st = STATE.state
    nowTs = tonumber(nowTs or _nowTs()) or _nowTs()

    if st.watchEnabled ~= true then
        return { state = "PAUSED", note = "watch OFF", ageSec = nil }
    end

    local lastTs = tonumber(st.lastSnapshotTs or 0)
    local age = (lastTs > 0) and (nowTs - lastTs) or nil

    local staleSec = tonumber(st.staleThresholdSec or DEFAULT_STALE_SEC) or DEFAULT_STALE_SEC
    if age == nil or age < 0 then
        return { state = "STALE", note = "no snapshot yet", ageSec = age }
    end
    if age > staleSec then
        return { state = "STALE", note = string.format("last snapshot %ds ago", age), ageSec = age }
    end

    if type(st.degradedReason) == "string" and st.degradedReason ~= "" then
        return { state = "DEGRADED", note = st.degradedReason, ageSec = age }
    end

    return { state = "LIVE", note = "watch ON", ageSec = age }
end

local function _buildCompatStateCopy()
    local st = _copyOneLevel(STATE.state)
    local h = _health()

    -- compat keys expected by your already-installed dwroom.lua watch status printer
    st.enabled = (st.watchEnabled == true)
    st.lastCaptureTs = st.lastSnapshotTs
    st.lastError = st.degradedReason
    st.health = h.state
    st.healthNote = h.note
    st.snapshotAgeSec = h.ageSec

    return st
end

local function _emitUpdated(delta, ts, source)
    local okB, Bus = _resolveBus()
    if not okB then
        return false, "event_bus not available"
    end

    ts = tonumber(ts or _nowTs()) or _nowTs()
    delta = (type(delta) == "table") and delta or {}

    STATE.state.updates = (tonumber(STATE.state.updates or 0) or 0) + 1

    local payload = {
        ts = ts,
        delta = _copyOneLevel(delta),
        state = _buildCompatStateCopy(),
    }

    local meta = {
        source = tostring(source or "svc:roomfeed_status"),
        service = "dwkit.services.roomfeed_status_service",
        ts = ts,
    }

    local ok = pcall(function()
        -- allow event_bus implementations that accept 2 or 3 args
        return Bus.emit(EV_UPDATED, payload, meta)
    end)

    if ok then
        STATE.state.emits = (tonumber(STATE.state.emits or 0) or 0) + 1
        STATE.state.lastEmitTs = ts
        return true
    end
    return false, "emit failed"
end

function M.getVersion()
    return tostring(M.VERSION)
end

function M.getUpdatedEventName()
    return tostring(EV_UPDATED)
end

function M.getState()
    _loadOnce()
    return _buildCompatStateCopy()
end

function M.getHealth(nowTs)
    _loadOnce()
    return _health(nowTs)
end

function M.getWatchEnabled()
    _loadOnce()
    return (STATE.state.watchEnabled == true) and true or ((STATE.state.watchEnabled == false) and false or nil)
end

function M.hasUserSetWatch()
    _loadOnce()
    return (STATE.state.userSetWatch == true)
end

function M.setWatchEnabled(enabled, opts)
    _loadOnce()
    opts = (type(opts) == "table") and opts or {}
    if type(enabled) ~= "boolean" then
        return false, "setWatchEnabled(enabled): enabled must be boolean"
    end

    STATE.state.watchEnabled = enabled
    STATE.state.userSetWatch = true
    STATE.state.lastSetTs = _nowTs()

    _saveBestEffort(opts)

    local delta = {
        watchEnabled = STATE.state.watchEnabled,
        userSetWatch = STATE.state.userSetWatch,
        lastSetTs = STATE.state.lastSetTs,
    }
    _emitUpdated(delta, STATE.state.lastSetTs, "svc:roomfeed_status:setWatchEnabled")

    return true, nil
end

-- compat alias (dwroom.lua uses setEnabled)
function M.setEnabled(enabled, opts)
    return M.setWatchEnabled(enabled, opts)
end

function M.noteSnapshot(meta)
    _loadOnce()
    meta = (type(meta) == "table") and meta or {}

    local ts = tonumber(meta.ts or _nowTs()) or _nowTs()
    local src = (type(meta.source) == "string" and meta.source ~= "") and meta.source or nil

    STATE.state.lastSnapshotTs = ts
    STATE.state.lastSnapshotSource = src
    STATE.state.lastAbortReason = nil
    STATE.state.lastAbortTs = nil
    STATE.state.degradedReason = nil
    STATE.state.degradedTs = nil

    local delta = {
        lastSnapshotTs = ts,
        lastSnapshotSource = src,
        lastAbortReason = nil,
        lastAbortTs = nil,
        degradedReason = nil,
        degradedTs = nil,
    }

    _emitUpdated(delta, ts, "svc:roomfeed_status:noteSnapshot")
    return true, nil
end

function M.noteAbort(reason, meta)
    _loadOnce()
    reason = tostring(reason or "")
    if reason == "" then reason = "abort" end
    meta = (type(meta) == "table") and meta or {}

    local ts = tonumber(meta.ts or _nowTs()) or _nowTs()

    STATE.state.lastAbortReason = reason
    STATE.state.lastAbortTs = ts

    local delta = { lastAbortReason = reason, lastAbortTs = ts }
    _emitUpdated(delta, ts, "svc:roomfeed_status:noteAbort")
    return true, nil
end

function M.noteDegraded(reason, meta)
    _loadOnce()
    reason = tostring(reason or "")
    if reason == "" then reason = "degraded" end
    meta = (type(meta) == "table") and meta or {}

    local ts = tonumber(meta.ts or _nowTs()) or _nowTs()

    STATE.state.degradedReason = reason
    STATE.state.degradedTs = ts

    local delta = { degradedReason = reason, degradedTs = ts }
    _emitUpdated(delta, ts, "svc:roomfeed_status:noteDegraded")
    return true, nil
end

function M.clearDegraded()
    _loadOnce()
    if STATE.state.degradedReason == nil and STATE.state.degradedTs == nil then
        return true, nil
    end

    STATE.state.degradedReason = nil
    STATE.state.degradedTs = nil

    local ts = _nowTs()
    local delta = { degradedReason = nil, degradedTs = nil }
    _emitUpdated(delta, ts, "svc:roomfeed_status:clearDegraded")

    return true, nil
end

-- compat helper (dwroom.lua tries getHealthState first)
function M.getHealthState(opts)
    _loadOnce()
    opts = (type(opts) == "table") and opts or {}
    local nowTs = tonumber(opts.nowTs) or _nowTs()
    local h = _health(nowTs)
    local st = _buildCompatStateCopy()
    return tostring(h.state), st
end

function M.status(opts)
    _loadOnce()
    opts = (type(opts) == "table") and opts or {}

    local s = _buildCompatStateCopy()
    local h = _health()

    if opts.quiet ~= true then
        _out("status (room watch)")
        _out(string.format("  watchEnabled=%s userSet=%s", tostring(s.watchEnabled), tostring(s.userSetWatch)))
        _out(string.format("  health=%s note=%s", tostring(h.state), tostring(h.note)))
        if h.ageSec ~= nil then
            _out(string.format("  snapshotAgeSec=%s source=%s", tostring(h.ageSec), tostring(s.lastSnapshotSource)))
        end
        if s.lastAbortReason then
            _out(string.format("  lastAbort=%s", tostring(s.lastAbortReason)))
        end
    end

    s.healthDetail = h
    return s
end

return M
