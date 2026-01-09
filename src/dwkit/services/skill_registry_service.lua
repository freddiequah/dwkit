-- #########################################################################
-- Module Name : dwkit.services.skill_registry_service
-- Owner       : Services
-- Version     : v2026-01-09A
-- Purpose     :
--   - SAFE SkillRegistryService (data only).
--   - Owns skill/spell registry (data-driven), emits updates.
--   - No UI, no persistence, no timers, no send().
--
-- Public API  :
--   - getVersion() -> string
--   - getRegistry() -> table copy
--   - setRegistry(registry, opts?) -> boolean ok, string|nil err
--   - upsert(key, def, opts?) -> boolean ok, string|nil err
--   - remove(key, opts?) -> boolean ok, string|nil err
--   - onUpdated(handlerFn) -> boolean ok, number|nil token, string|nil err
--
-- Events Emitted:
--   - DWKit:Service:SkillRegistry:Updated
-- Automation Policy: Manual only
-- Dependencies     : dwkit.core.identity, dwkit.bus.event_bus
-- #########################################################################

local M          = {}

M.VERSION        = "v2026-01-09A"

local ID         = require("dwkit.core.identity")
local BUS        = require("dwkit.bus.event_bus")

local EV_UPDATED = tostring(ID.eventPrefix or "DWKit:") .. "Service:SkillRegistry:Updated"

local STATE      = {
    registry = {}, -- key -> def table
    lastTs = nil,
    updates = 0,
}

local function _shallowCopy(t)
    local out = {}
    if type(t) ~= "table" then return out end
    for k, v in pairs(t) do out[k] = v end
    return out
end

local function _copyRegistry(r)
    local out = {}
    if type(r) ~= "table" then return out end
    for k, def in pairs(r) do
        if type(def) == "table" then
            out[k] = _shallowCopy(def)
        else
            out[k] = def
        end
    end
    return out
end

local function _emit(changed, source)
    local payload = {
        ts = os.time(),
        registry = _copyRegistry(STATE.registry),
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

function M.getRegistry()
    return _copyRegistry(STATE.registry)
end

function M.setRegistry(registry, opts)
    opts = opts or {}
    if type(registry) ~= "table" then
        return false, "setRegistry(registry): registry must be a table"
    end

    STATE.registry = _copyRegistry(registry)
    STATE.lastTs = os.time()
    STATE.updates = STATE.updates + 1

    local okEmit, errEmit = _emit({ setRegistry = true }, opts.source)
    if not okEmit then return false, errEmit end
    return true, nil
end

function M.upsert(key, def, opts)
    opts = opts or {}
    if type(key) ~= "string" or key == "" then
        return false, "upsert(key, def): key must be a non-empty string"
    end
    if type(def) ~= "table" then
        return false, "upsert(key, def): def must be a table"
    end

    STATE.registry[key] = _shallowCopy(def)
    STATE.lastTs = os.time()
    STATE.updates = STATE.updates + 1

    local okEmit, errEmit = _emit({ upsert = key }, opts.source)
    if not okEmit then return false, errEmit end
    return true, nil
end

function M.remove(key, opts)
    opts = opts or {}
    if type(key) ~= "string" or key == "" then
        return false, "remove(key): key must be a non-empty string"
    end

    if STATE.registry[key] == nil then
        return false, "remove(key): unknown key: " .. tostring(key)
    end

    STATE.registry[key] = nil
    STATE.lastTs = os.time()
    STATE.updates = STATE.updates + 1

    local okEmit, errEmit = _emit({ remove = key }, opts.source)
    if not okEmit then return false, errEmit end
    return true, nil
end

function M.onUpdated(handlerFn)
    return BUS.on(EV_UPDATED, handlerFn)
end

function M.getStats()
    local n = 0
    for _ in pairs(STATE.registry) do n = n + 1 end
    return {
        version = M.VERSION,
        lastTs = STATE.lastTs,
        updates = STATE.updates,
        entries = n,
    }
end

return M
