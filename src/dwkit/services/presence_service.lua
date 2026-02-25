-- #########################################################################
-- Module Name : dwkit.services.presence_service
-- Owner       : Services
-- Version     : v2026-02-24B
-- Purpose     :
--   - SAFE, profile-portable PresenceService (data only).
--   - No GMCP dependency, no Mudlet events, no timers, no send().
--   - Emits a registered internal event when state changes.
--   - Service-layer bridge: listens to RoomEntities Updated and updates Presence state.
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
--
-- Events Emitted:
--   - DWKit:Service:Presence:Updated
-- Automation Policy: Manual only (no gameplay commands). Bridge is internal event-driven (SAFE).
-- Dependencies     : dwkit.core.identity, dwkit.bus.event_bus, dwkit.config.owned_profiles (best-effort)
-- #########################################################################

local M = {}

M.VERSION = "v2026-02-24B"

local ID = require("dwkit.core.identity")
local BUS = require("dwkit.bus.event_bus")

local EV_UPDATED = tostring(ID.eventPrefix or "DWKit:") .. "Service:Presence:Updated"

-- Expose event name for UIs and consumers (contract)
M.EV_UPDATED = EV_UPDATED

local STATE = {
    state = {},
    lastTs = nil,
    updates = 0,
}

local function _shallowCopy(t)
    local out = {}
    if type(t) ~= "table" then return out end
    for k, v in pairs(t) do out[k] = v end
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
    -- BUS.emit already returns ok, deliveredCount, errors. We do not fail the service
    -- just because no one is listening. But we do bubble up registry/validation errors.
    if not ok then
        local first = (type(errs) == "table" and errs[1]) and tostring(errs[1]) or "emit failed"
        return false, first
    end
    return true, nil
end

local function _safeRequire(modName)
    local ok, mod = pcall(require, modName)
    if ok then return true, mod end
    return false, mod
end

local function _sortedStringKeys(t)
    local keys = {}
    if type(t) ~= "table" then return keys end
    for k, _ in pairs(t) do
        if type(k) == "string" and k ~= "" then
            keys[#keys + 1] = k
        end
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    return keys
end

-- -------------------------------------------------------------------------
-- RoomEntities -> Presence bridge (SAFE, event-driven)
-- -------------------------------------------------------------------------

local _bridge = {
    subscribed = false,
    token = nil,
    eventName = nil,
    lastErr = nil,
    running = false,
    lastRoomTs = nil,
}

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

local function _countMap(t)
    if type(t) ~= "table" then return 0 end
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

local function _extractRoomPlayersBestEffort(payload)
    payload = (type(payload) == "table") and payload or {}

    -- Preferred: ask RoomEntitiesService state (agreement).
    -- IMPORTANT: RoomEntitiesService.getState() does NOT expose lastTs; use getStats().lastTs for freshness.
    do
        local okR, R = _safeRequire("dwkit.services.roomentities_service")
        if okR and type(R) == "table" and type(R.getState) == "function" then
            local okS, st = pcall(R.getState)
            if okS and type(st) == "table"
                and type(st.entitiesV2) == "table"
                and type(st.entitiesV2.players) == "table"
            then
                local roomTs = nil

                if type(R.getStats) == "function" then
                    local okG, stats = pcall(R.getStats)
                    if okG and type(stats) == "table" then
                        roomTs = stats.lastTs
                    end
                end

                if roomTs == nil then
                    roomTs = payload.ts
                end

                return _sortedStringKeys(st.entitiesV2.players), roomTs
            end
        end
    end

    -- Fallback: payload.entitiesV2.players keys
    if type(payload.entitiesV2) == "table" and type(payload.entitiesV2.players) == "table" then
        return _sortedStringKeys(payload.entitiesV2.players), payload.ts
    end

    -- Fallback: legacy payload.state.players set-map
    if type(payload.state) == "table" and type(payload.state.players) == "table" then
        return _sortedStringKeys(payload.state.players), payload.ts
    end

    return {}, payload.ts
end

local function _computePresenceSnapshotFromRoomEntities(payload, source)
    local roomPlayers, roomTs = _extractRoomPlayersBestEffort(payload)

    local map = _getOwnedProfilesMapBestEffort()
    local mapCount = _countMap(map)
    local mappingMissing = (mapCount <= 0)

    local myProfilesInRoom = {}
    local otherPlayersInRoom = {}

    for i = 1, #roomPlayers do
        local name = tostring(roomPlayers[i] or "")
        if name ~= "" then
            local prof = map[name]
            if type(prof) == "string" and prof ~= "" then
                myProfilesInRoom[#myProfilesInRoom + 1] = name .. " (" .. prof .. ")"
            else
                otherPlayersInRoom[#otherPlayersInRoom + 1] = name
            end
        end
    end

    local hasSnapshot = (roomTs ~= nil)

    local stale = (hasSnapshot ~= true)
    local staleReason = nil
    if stale then
        staleReason = "no room snapshot yet"
    end

    return {
        ts = os.time(),
        source = tostring(source or "presence_bridge:roomentities"),
        roomTs = roomTs,
        roomPlayerCount = #roomPlayers,
        roomPlayers = roomPlayers, -- raw list (names)
        myProfilesInRoom = myProfilesInRoom,
        otherPlayersInRoom = otherPlayersInRoom,
        mapping = {
            count = mapCount,
            missing = mappingMissing,
            hint = mappingMissing and
                "Configure owned profiles mapping (characterName -> profileLabel) in dwkit.config.owned_profiles." or nil,
        },
        stale = stale,
        staleReason = staleReason,
    }
end

local function _applyPresenceSnapshot(snapshot, source)
    if type(snapshot) ~= "table" then
        return false, "snapshot must be table"
    end
    return M.setState(snapshot, { source = source or snapshot.source or "presence_bridge:setState" })
end

local function _onRoomEntitiesUpdated(payload)
    if _bridge.running == true then
        return
    end
    _bridge.running = true

    local snap = _computePresenceSnapshotFromRoomEntities(payload, "presence_bridge:roomentities")
    _bridge.lastRoomTs = snap.roomTs

    local ok, err = _applyPresenceSnapshot(snap, "presence_bridge:roomentities")
    if ok ~= true then
        _bridge.lastErr = tostring(err)
    else
        _bridge.lastErr = nil
    end

    _bridge.running = false
end

local function _resolveRoomEntitiesUpdatedEventNameBestEffort()
    -- Prefer RoomEntitiesService contract if available
    local okR, R = _safeRequire("dwkit.services.roomentities_service")
    if okR and type(R) == "table" then
        if type(R.getUpdatedEventName) == "function" then
            local ok, v = pcall(R.getUpdatedEventName)
            if ok and type(v) == "string" and v ~= "" then
                return v
            end
        end
        if type(R.EV_UPDATED) == "string" and R.EV_UPDATED ~= "" then
            return R.EV_UPDATED
        end
    end

    -- Fallback to identity-based string
    return tostring(ID.eventPrefix or "DWKit:") .. "Service:RoomEntities:Updated"
end

local function _ensureRoomEntitiesSubscription()
    if _bridge.subscribed == true then
        return true, nil
    end

    if type(BUS) ~= "table" or type(BUS.on) ~= "function" then
        _bridge.lastErr = "event bus .on not available"
        return false, _bridge.lastErr
    end

    local evName = _resolveRoomEntitiesUpdatedEventNameBestEffort()
    if type(evName) ~= "string" or evName == "" then
        _bridge.lastErr = "RoomEntities updated event name not available"
        return false, _bridge.lastErr
    end

    local okSub, tokenOrErr, maybeErr = BUS.on(evName, _onRoomEntitiesUpdated)
    if okSub ~= true then
        _bridge.lastErr = tostring(maybeErr or tokenOrErr or "RoomEntities subscribe failed")
        return false, _bridge.lastErr
    end

    _bridge.subscribed = true
    _bridge.token = tokenOrErr
    _bridge.eventName = evName
    _bridge.lastErr = nil
    return true, nil
end

local function _armRoomEntitiesSubscriptionBestEffort()
    local ok, err = _ensureRoomEntitiesSubscription()
    if ok ~= true then
        _bridge.lastErr = tostring(err or _bridge.lastErr or "RoomEntities subscribe failed")
    end
end

function M.getVersion()
    return tostring(M.VERSION)
end

function M.getUpdatedEventName()
    return tostring(EV_UPDATED)
end

function M.getState()
    return _shallowCopy(STATE.state)
end

function M.setState(newState, opts)
    opts = opts or {}
    if type(newState) ~= "table" then
        return false, "setState(newState): newState must be a table"
    end

    STATE.state = _shallowCopy(newState)
    STATE.lastTs = os.time()
    STATE.updates = STATE.updates + 1

    local okEmit, errEmit = _emit(_shallowCopy(STATE.state), nil, opts.source)
    if not okEmit then
        return false, errEmit
    end

    return true, nil
end

function M.update(delta, opts)
    opts = opts or {}
    if type(delta) ~= "table" then
        return false, "update(delta): delta must be a table"
    end

    _merge(STATE.state, delta)
    STATE.lastTs = os.time()
    STATE.updates = STATE.updates + 1

    local okEmit, errEmit = _emit(_shallowCopy(STATE.state), _shallowCopy(delta), opts.source)
    if not okEmit then
        return false, errEmit
    end

    return true, nil
end

function M.clear(opts)
    opts = opts or {}
    STATE.state = {}
    STATE.lastTs = os.time()
    STATE.updates = STATE.updates + 1

    local okEmit, errEmit = _emit(_shallowCopy(STATE.state), { cleared = true }, opts.source)
    if not okEmit then
        return false, errEmit
    end

    return true, nil
end

function M.onUpdated(handlerFn)
    return BUS.on(EV_UPDATED, handlerFn)
end

function M.getStats()
    local map = _getOwnedProfilesMapBestEffort()

    return {
        version = M.VERSION,
        lastTs = STATE.lastTs,
        updates = STATE.updates,
        keys = (function()
            local n = 0
            for _ in pairs(STATE.state) do n = n + 1 end
            return n
        end)(),
        bridge = {
            subscribed = (_bridge.subscribed == true),
            eventName = _bridge.eventName,
            hasToken = (_bridge.token ~= nil),
            lastErr = _bridge.lastErr,
            lastRoomTs = _bridge.lastRoomTs,
        },
        mapping = {
            count = _countMap(map),
        },
    }
end

-- Arm subscription at module load (best-effort) so Presence can populate as soon as RoomEntities emits.
_armRoomEntitiesSubscriptionBestEffort()

return M
