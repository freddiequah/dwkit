-- #########################################################################
-- Module Name : dwkit.services.action_model_service
-- Owner       : Services
-- Version     : v2026-01-09A
-- Purpose     :
--   - SAFE ActionModelService (data only).
--   - Owns an action model (map of actions / metadata), emits updates.
--   - No UI, no persistence, no timers, no send().
--
-- Public API  :
--   - getVersion() -> string
--   - getModel() -> table copy
--   - setModel(model, opts?) -> boolean ok, string|nil err
--   - upsert(name, def, opts?) -> boolean ok, string|nil err
--   - remove(name, opts?) -> boolean ok, string|nil err
--   - onUpdated(handlerFn) -> boolean ok, number|nil token, string|nil err
--
-- Events Emitted:
--   - DWKit:Service:ActionModel:Updated
-- Automation Policy: Manual only
-- Dependencies     : dwkit.core.identity, dwkit.bus.event_bus
-- #########################################################################

local M          = {}

M.VERSION        = "v2026-01-09A"

local ID         = require("dwkit.core.identity")
local BUS        = require("dwkit.bus.event_bus")

local EV_UPDATED = tostring(ID.eventPrefix or "DWKit:") .. "Service:ActionModel:Updated"

local STATE      = {
    model = {}, -- name -> def table (shallow)
    lastTs = nil,
    updates = 0,
}

local function _shallowCopy(t)
    local out = {}
    if type(t) ~= "table" then return out end
    for k, v in pairs(t) do out[k] = v end
    return out
end

local function _copyModel(m)
    local out = {}
    if type(m) ~= "table" then return out end
    for name, def in pairs(m) do
        if type(def) == "table" then
            out[name] = _shallowCopy(def)
        else
            out[name] = def
        end
    end
    return out
end

local function _emit(changed, source)
    local payload = {
        ts = os.time(),
        model = _copyModel(STATE.model),
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

function M.getVersion()
    return tostring(M.VERSION)
end

function M.getModel()
    return _copyModel(STATE.model)
end

function M.setModel(model, opts)
    opts = opts or {}
    if type(model) ~= "table" then
        return false, "setModel(model): model must be a table"
    end

    STATE.model = _copyModel(model)
    STATE.lastTs = os.time()
    STATE.updates = STATE.updates + 1

    local okEmit, errEmit = _emit({ setModel = true }, opts.source)
    if not okEmit then return false, errEmit end
    return true, nil
end

function M.upsert(name, def, opts)
    opts = opts or {}
    if type(name) ~= "string" or name == "" then
        return false, "upsert(name, def): name must be a non-empty string"
    end
    if type(def) ~= "table" then
        return false, "upsert(name, def): def must be a table"
    end

    STATE.model[name] = _shallowCopy(def)
    STATE.lastTs = os.time()
    STATE.updates = STATE.updates + 1

    local okEmit, errEmit = _emit({ upsert = name }, opts.source)
    if not okEmit then return false, errEmit end
    return true, nil
end

function M.remove(name, opts)
    opts = opts or {}
    if type(name) ~= "string" or name == "" then
        return false, "remove(name): name must be a non-empty string"
    end

    if STATE.model[name] == nil then
        return false, "remove(name): unknown action: " .. tostring(name)
    end

    STATE.model[name] = nil
    STATE.lastTs = os.time()
    STATE.updates = STATE.updates + 1

    local okEmit, errEmit = _emit({ remove = name }, opts.source)
    if not okEmit then return false, errEmit end
    return true, nil
end

function M.onUpdated(handlerFn)
    return BUS.on(EV_UPDATED, handlerFn)
end

function M.getStats()
    local n = 0
    for _ in pairs(STATE.model) do n = n + 1 end
    return {
        version = M.VERSION,
        lastTs = STATE.lastTs,
        updates = STATE.updates,
        actions = n,
    }
end

return M
