-- #########################################################################
-- Module Name : dwkit.ui.ui_autorefresh
-- Owner       : UI
-- Version     : v2026-01-17A
-- Purpose     :
--   - SAFE, opt-in UI auto-refresh watcher.
--   - Subscribes to DWKit service update events (Presence + RoomEntities).
--   - When a watched service emits an update, auto-applies the corresponding UI
--     ONLY if that UI is enabled + visible (best-effort).
--   - Presence-assisted reclassify:
--       If PresenceService updates and RoomEntities has unknown entries that match
--       Presence players, promote those entries unknown -> players (best-effort),
--       letting RoomEntitiesService emit its own Updated event (no forced emits).
--
-- Public API  :
--   - getModuleVersion() -> string
--   - start(opts?) -> boolean ok, string|nil err
--   - stop(opts?) -> boolean ok, string|nil err
--   - isRunning() -> boolean
--   - getState() -> table copy
--
-- SAFE Constraints:
--   - No gameplay commands
--   - No timers
--   - No automation by default (manual start/stop)
-- #########################################################################

local M = {}

M.VERSION = "v2026-01-17A"

local ID = require("dwkit.core.identity")
local BUS = require("dwkit.bus.event_bus")
local UI_MANAGER = require("dwkit.ui.ui_manager")

local EV_PRESENCE_UPDATED = tostring(ID.eventPrefix or "DWKit:") .. "Service:Presence:Updated"

local _state = {
    running = false,
    tokens = {
        presence = nil,
        roomentities = {}, -- list of tokens
    },
    subscribedEvents = {
        presence = EV_PRESENCE_UPDATED,
        roomentities = {}, -- list of event names
    },
    stats = {
        updatesSeen = 0,
        applyAttempts = 0,
        applied = 0,
        skipped = 0,
        lastTs = nil,
        lastSource = nil,
        lastUiId = nil,
        lastEvent = nil,

        -- Presence-assisted reclassify stats
        reclassifyAttempts = 0,
        reclassifyPromoted = 0,
        lastReclassifyTs = nil,
    },
}

local function _out(line)
    line = tostring(line or "")
    if type(cecho) == "function" then
        cecho(line .. "\n")
    elseif type(echo) == "function" then
        echo(line .. "\n")
    else
        print(line)
    end
end

local function _safeRequire(modName)
    local ok, mod = pcall(require, modName)
    if ok then return true, mod end
    return false, mod
end

local function _getGuiSettingsBestEffort()
    if type(_G.DWKit) == "table"
        and type(_G.DWKit.config) == "table"
        and type(_G.DWKit.config.guiSettings) == "table"
    then
        return _G.DWKit.config.guiSettings
    end

    local ok, mod = _safeRequire("dwkit.config.gui_settings")
    if ok and type(mod) == "table" then return mod end
    return nil
end

local function _isEnabledAndVisible(uiId)
    local gs = _getGuiSettingsBestEffort()
    if type(gs) ~= "table" then
        return false
    end

    local enabled = true
    local visible = false

    if type(gs.isEnabled) == "function" then
        local okE, v = pcall(gs.isEnabled, uiId, true)
        if okE then enabled = (v == true) end
    end

    if type(gs.getVisible) == "function" then
        local okV, v = pcall(gs.getVisible, uiId, false)
        if okV then visible = (v == true) end
    end

    return (enabled == true and visible == true)
end

local function _handle(uiId, eventName, payload)
    _state.stats.updatesSeen = _state.stats.updatesSeen + 1
    _state.stats.lastTs = os.time()
    _state.stats.lastUiId = uiId
    _state.stats.lastEvent = tostring(eventName or "")

    if type(payload) == "table" and type(payload.source) == "string" then
        _state.stats.lastSource = payload.source
    end

    if not _isEnabledAndVisible(uiId) then
        _state.stats.skipped = _state.stats.skipped + 1
        return
    end

    _state.stats.applyAttempts = _state.stats.applyAttempts + 1

    local okApply, errApply = UI_MANAGER.applyOne(uiId, { source = "ui_autorefresh" })
    if okApply then
        _state.stats.applied = _state.stats.applied + 1
    else
        _out("[DWKit UI] autoRefresh apply failed uiId=" .. tostring(uiId) .. " err=" .. tostring(errApply))
    end
end

local function _busOff(token)
    if token == nil then return end
    if type(BUS.off) == "function" then
        pcall(BUS.off, token)
        return
    end
    if type(BUS.unsub) == "function" then
        pcall(BUS.unsub, token)
        return
    end
    if type(BUS.unsubscribe) == "function" then
        pcall(BUS.unsubscribe, token)
        return
    end
end

local function _dedupe(list)
    local seen = {}
    local out = {}
    for _, v in ipairs(list or {}) do
        local s = tostring(v or "")
        if s ~= "" and not seen[s] then
            seen[s] = true
            out[#out + 1] = s
        end
    end
    return out
end

local function _resolveRoomEntitiesEvents()
    local base = tostring(ID.eventPrefix or "DWKit:")

    local candidates = {
        base .. "Service:RoomEntities:Updated", -- our assumed standard
        base .. "Service:RoomEntities:Update",  -- common near-miss
        base .. "Service:RoomEntities:Changed", -- common alt wording
        base .. "Service:RoomEntities:State",   -- alt pattern
        base .. "RoomEntities:Updated",         -- older/shorter
        base .. "RoomEntities:Changed",
    }

    -- Attempt to discover actual event name from the service module if exposed
    local okS, S = _safeRequire("dwkit.services.roomentities_service")
    if okS and type(S) == "table" then
        if type(S.getUpdatedEventName) == "function" then
            local okN, ev = pcall(S.getUpdatedEventName)
            if okN and type(ev) == "string" and ev ~= "" then
                candidates[#candidates + 1] = ev
            end
        end

        -- common constant fields
        local fields = { "EV_UPDATED", "EVENT_UPDATED", "UPDATED_EVENT", "EVT_UPDATED" }
        for _, k in ipairs(fields) do
            local ev = S[k]
            if type(ev) == "string" and ev ~= "" then
                candidates[#candidates + 1] = ev
            end
        end
    end

    return _dedupe(candidates)
end

local function _copySet(t)
    local out = {}
    if type(t) ~= "table" then return out end
    for k, v in pairs(t) do
        if v == true and type(k) == "string" and k ~= "" then
            out[k] = true
        end
    end
    return out
end

local function _countSet(t)
    if type(t) ~= "table" then return 0 end
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

local function _extractPresencePlayers(payload)
    payload = (type(payload) == "table") and payload or {}

    -- Prefer payload.state.players if present
    if type(payload.state) == "table" and type(payload.state.players) == "table" then
        return payload.state.players
    end

    -- Best-effort fallback to PresenceService.getState()
    local okP, P = _safeRequire("dwkit.services.presence_service")
    if okP and type(P) == "table" and type(P.getState) == "function" then
        local okS, st = pcall(P.getState)
        if okS and type(st) == "table" and type(st.players) == "table" then
            return st.players
        end
    end

    return {}
end

-- Presence-assisted reclassify:
-- Promote any RoomEntities unknown entries that match Presence players set.
-- Best-effort only. We do NOT forceEmit. RoomEntitiesService will suppress emits if no changes.
local function _presenceAssistReclassifyRoomEntities(payload)
    _state.stats.reclassifyAttempts = _state.stats.reclassifyAttempts + 1

    local presencePlayers = _extractPresencePlayers(payload)
    if type(presencePlayers) ~= "table" or _countSet(presencePlayers) == 0 then
        return
    end

    local okR, R = _safeRequire("dwkit.services.roomentities_service")
    if not okR or type(R) ~= "table" then
        return
    end

    if type(R.getState) ~= "function" or type(R.setState) ~= "function" then
        return
    end

    local okGet, rs = pcall(R.getState)
    if not okGet or type(rs) ~= "table" then
        return
    end

    local unknown = rs.unknown
    if type(unknown) ~= "table" then
        return
    end

    local promote = {}
    for name, v in pairs(unknown) do
        if v == true and presencePlayers[name] == true then
            promote[name] = true
        end
    end

    local promoteCount = _countSet(promote)
    if promoteCount == 0 then
        return
    end

    local nextState = {
        players = _copySet(rs.players),
        mobs = _copySet(rs.mobs),
        items = _copySet(rs.items),
        unknown = _copySet(rs.unknown),
    }

    for name in pairs(promote) do
        nextState.players[name] = true
        nextState.unknown[name] = nil
    end

    local okSet = pcall(R.setState, nextState, { source = "presence_reclassify" })
    if okSet then
        _state.stats.reclassifyPromoted = _state.stats.reclassifyPromoted + promoteCount
        _state.stats.lastReclassifyTs = os.time()
    end
end

function M.getModuleVersion()
    return M.VERSION
end

function M.isRunning()
    return _state.running == true
end

function M.getState()
    return {
        version = M.VERSION,
        running = (_state.running == true),
        subscribedEvents = {
            presence = _state.subscribedEvents.presence,
            roomentities = _state.subscribedEvents.roomentities,
        },
        stats = {
            updatesSeen = _state.stats.updatesSeen,
            applyAttempts = _state.stats.applyAttempts,
            applied = _state.stats.applied,
            skipped = _state.stats.skipped,
            lastTs = _state.stats.lastTs,
            lastSource = _state.stats.lastSource,
            lastUiId = _state.stats.lastUiId,
            lastEvent = _state.stats.lastEvent,

            reclassifyAttempts = _state.stats.reclassifyAttempts,
            reclassifyPromoted = _state.stats.reclassifyPromoted,
            lastReclassifyTs = _state.stats.lastReclassifyTs,
        },
    }
end

function M.start(opts)
    opts = (type(opts) == "table") and opts or {}

    if _state.running == true then
        return true, nil
    end

    -- Presence
    local ok1, tok1 = BUS.on(EV_PRESENCE_UPDATED, function(...)
        local payload = select(1, ...)
        _handle("presence_ui", EV_PRESENCE_UPDATED, payload)

        -- Best-effort: Presence-assisted unknown->players promotion in RoomEntities
        _presenceAssistReclassifyRoomEntities(payload)
    end)

    if ok1 ~= true then
        return false, "failed to subscribe presence updated"
    end

    _state.tokens.presence = tok1
    _state.subscribedEvents.presence = EV_PRESENCE_UPDATED

    -- RoomEntities (subscribe to multiple candidates; first one that matches will fire)
    local evs = _resolveRoomEntitiesEvents()
    _state.subscribedEvents.roomentities = evs
    _state.tokens.roomentities = {}

    for _, ev in ipairs(evs) do
        local ok2, tok2 = BUS.on(ev, function(...)
            local payload = select(1, ...)
            _handle("roomentities_ui", ev, payload)
        end)
        if ok2 == true then
            _state.tokens.roomentities[#_state.tokens.roomentities + 1] = tok2
        end
    end

    _state.running = true

    _out("[DWKit UI] autoRefresh started")
    _out("  presenceEvent=" .. tostring(EV_PRESENCE_UPDATED))
    _out("  roomentitiesEvents=" .. tostring(#evs))

    return true, nil
end

function M.stop(opts)
    opts = (type(opts) == "table") and opts or {}

    if _state.running ~= true then
        return true, nil
    end

    _busOff(_state.tokens.presence)
    _state.tokens.presence = nil

    if type(_state.tokens.roomentities) == "table" then
        for _, t in ipairs(_state.tokens.roomentities) do
            _busOff(t)
        end
    end
    _state.tokens.roomentities = {}

    _state.running = false

    _out("[DWKit UI] autoRefresh stopped")
    return true, nil
end

return M
