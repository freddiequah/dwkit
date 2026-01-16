-- #########################################################################
-- Module Name : dwkit.services.presence_service
-- Owner       : Services
-- Version     : v2026-01-16A
-- Purpose     :
--   - SAFE, profile-portable PresenceService (data only).
--   - No GMCP dependency, no Mudlet events, no timers, no send().
--   - Emits a registered internal event when state changes.
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
-- Automation Policy: Manual only
-- Dependencies     : dwkit.core.identity, dwkit.bus.event_bus
-- #########################################################################

local M = {}

M.VERSION = "v2026-01-16A"

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
    return {
        version = M.VERSION,
        lastTs = STATE.lastTs,
        updates = STATE.updates,
        keys = (function()
            local n = 0
            for _ in pairs(STATE.state) do n = n + 1 end
            return n
        end)(),
    }
end

return M
