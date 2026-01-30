-- #########################################################################
-- Module Name : dwkit.services.roomfeed_status_service
-- Owner       : Services
-- Version     : v2026-01-30A
-- Purpose     :
--   - SAFE, per-profile Room Feed status signal for modules depending on room text capture.
--   - Tracks watchEnabled, lastSnapshotTs/source, and degraded mode.
--   - Emits status event on change; manual-only persistence on toggle.
-- #########################################################################

local M     = {}

M.VERSION   = "v2026-01-30A"

local ID    = require("dwkit.core.identity")
local BUS   = require("dwkit.bus.event_bus")

M.EV_STATUS = tostring(ID.eventPrefix or "DWKit:") .. "Service:RoomFeed:Status"

local STATE = {
    watchEnabled = true,
    lastSnapshotTs = nil,
    lastSnapshotSource = nil,
    degraded = false,
    degradedReason = nil,
    staleSeconds = 120,
    updates = 0,
}

local function _now()
    local ok, v = pcall(os.time)
    if ok and tonumber(v) then return tonumber(v) end
    return nil
end

local function _shallowCopy(t)
    local out = {}
    if type(t) ~= "table" then return out end
    for k, v in pairs(t) do out[k] = v end
    return out
end

local function _getPersistStoreBestEffort()
    if type(_G.DWKit) == "table" and type(_G.DWKit.persist) == "table" then
        local s = _G.DWKit.persist.store
        if type(s) == "table" and type(s.saveEnvelope) == "function" and type(s.loadEnvelope) == "function" then
            return true, s, nil
        end
    end
    local ok, modOrErr = pcall(require, "dwkit.persist.store")
    if ok and type(modOrErr) == "table" and type(modOrErr.saveEnvelope) == "function" and type(modOrErr.loadEnvelope) == "function" then
        return true, modOrErr, nil
    end
    return false, nil, "persist store not available"
end

local function _persistRelPath()
    return "services/room_feed/status.tbl"
end

local function _persistLoad()
    local okS, store = _getPersistStoreBestEffort()
    if not okS then return false end
    local okL, env = store.loadEnvelope(_persistRelPath())
    if not okL or type(env) ~= "table" or type(env.data) ~= "table" then
        return false
    end
    if type(env.data.watchEnabled) == "boolean" then
        STATE.watchEnabled = env.data.watchEnabled
    end
    if tonumber(env.data.staleSeconds) then
        local n = tonumber(env.data.staleSeconds)
        if n >= 10 and n <= 600 then STATE.staleSeconds = n end
    end
    return true
end

local function _persistSave(source)
    local okS, store = _getPersistStoreBestEffort()
    if not okS then return false end
    local data = { watchEnabled = (STATE.watchEnabled == true), staleSeconds = tonumber(STATE.staleSeconds) or 120 }
    local meta = { source = tostring(source or "svc:roomfeed:save"), ts = _now(), version = tostring(M.VERSION) }
    local okW = store.saveEnvelope(_persistRelPath(), "v1", data, meta)
    return okW == true
end

local function _computeHealth(nowTs)
    nowTs = tonumber(nowTs) or _now()
    if STATE.watchEnabled ~= true then return "PAUSED" end
    if STATE.degraded == true then return "DEGRADED" end
    if not tonumber(STATE.lastSnapshotTs) then return "STALE" end
    if tonumber(nowTs) and tonumber(STATE.staleSeconds) then
        local age = tonumber(nowTs) - tonumber(STATE.lastSnapshotTs)
        if age > tonumber(STATE.staleSeconds) then return "STALE" end
    end
    return "LIVE"
end

local function _emitStatusBestEffort(source, note)
    local nowTs = _now()
    local payload = {
        watchEnabled = (STATE.watchEnabled == true),
        lastSnapshotTs = STATE.lastSnapshotTs,
        lastSnapshotSource = STATE.lastSnapshotSource,
        degraded = (STATE.degraded == true),
        degradedReason = STATE.degradedReason,
        staleSeconds = STATE.staleSeconds,
        health = _computeHealth(nowTs),
        ts = nowTs,
        updates = STATE.updates,
        note = note,
    }
    local meta = { source = tostring(source or "svc:roomfeed"), service = "dwkit.services.roomfeed_status_service", ts =
    nowTs, version = tostring(M.VERSION) }
    if type(BUS) == "table" and type(BUS.emit) == "function" then
        pcall(function() BUS.emit(M.EV_STATUS, payload, meta) end)
    end
end

pcall(function() _persistLoad() end)

function M.getVersion() return tostring(M.VERSION) end

function M.getStatusEventName() return tostring(M.EV_STATUS) end

function M.getHealth() return _computeHealth(_now()) end

function M.getState()
    local out = _shallowCopy(STATE)
    out.watchEnabled = (STATE.watchEnabled == true)
    out.degraded = (STATE.degraded == true)
    out.health = _computeHealth(_now())
    return out
end

function M.setWatchEnabled(enabled, opts)
    opts = (type(opts) == "table") and opts or {}
    local v = (enabled == true)
    if STATE.watchEnabled == v then
        if opts.forceEmit == true then _emitStatusBestEffort(opts.source, "watch unchanged") end
        return true, nil
    end
    STATE.watchEnabled = v
    STATE.updates = STATE.updates + 1
    pcall(function() _persistSave(opts.source) end)
    _emitStatusBestEffort(opts.source or "svc:roomfeed:setWatchEnabled", v and "watch on" or "watch off")
    return true, nil
end

function M.markSnapshot(source, opts)
    opts = (type(opts) == "table") and opts or {}
    STATE.lastSnapshotTs = _now()
    STATE.lastSnapshotSource = tostring(source or opts.source or "unknown")
    STATE.degraded = false
    STATE.degradedReason = nil
    STATE.updates = STATE.updates + 1
    _emitStatusBestEffort(source or opts.source or "svc:roomfeed:markSnapshot", "snapshot")
end

function M.markDegraded(reason, source, opts)
    opts = (type(opts) == "table") and opts or {}
    if STATE.watchEnabled ~= true then return end
    STATE.degraded = true
    STATE.degradedReason = tostring(reason or "unknown")
    STATE.updates = STATE.updates + 1
    _emitStatusBestEffort(source or opts.source or "svc:roomfeed:markDegraded", "degraded")
end

function M.clearDegraded(source, opts)
    opts = (type(opts) == "table") and opts or {}
    if STATE.degraded ~= true then return end
    STATE.degraded = false
    STATE.degradedReason = nil
    STATE.updates = STATE.updates + 1
    _emitStatusBestEffort(source or opts.source or "svc:roomfeed:clearDegraded", "clear degraded")
end

return M
