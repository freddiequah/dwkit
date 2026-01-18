-- #########################################################################
-- Module Name : dwkit.ui.all
-- Owner       : UI
-- Version     : v2026-01-18A
-- Purpose     :
--   - Provide a SAFE placeholder UI module for "all" scope operations.
--   - Allows `dwgui validate all` to PASS instead of SKIP (module exists).
--   - Does NOT create windows, timers, triggers, events, or automation.
--
-- Public API  :
--   - getModuleVersion() -> string
--   - getUiId() -> string
--   - init(opts?) -> boolean ok, string|nil err
--   - getState() -> table (copy)
--   - apply(opts?) -> boolean ok, string|nil err
--   - dispose(opts?) -> boolean ok, string|nil err
--
-- Events Emitted   : None
-- Events Consumed  : None
-- Automation Policy: Manual only
-- Dependencies     : None
-- Invariants       :
--   - No UI windows created.
--   - No side effects beyond internal state.
-- #########################################################################

local M = {}

M.VERSION = "v2026-01-18A"
M.UI_ID = "all"

local _state = {
    initialized = false,
    lastInitAt = nil,
    lastApplyAt = nil,
    lastDisposeAt = nil,
    lastError = nil,
}

local function _copyShallow(t)
    if type(t) ~= "table" then return {} end
    local out = {}
    for k, v in pairs(t) do out[k] = v end
    return out
end

function M.getModuleVersion()
    return M.VERSION
end

function M.getUiId()
    return M.UI_ID
end

function M.init(opts)
    opts = opts or {}
    _state.initialized = true
    _state.lastInitAt = os.time()
    _state.lastError = nil
    return true, nil
end

function M.getState()
    return _copyShallow({
        uiId = M.UI_ID,
        moduleName = "dwkit.ui.all",
        version = M.VERSION,
        initialized = (_state.initialized == true),
        lastInitAt = _state.lastInitAt,
        lastApplyAt = _state.lastApplyAt,
        lastDisposeAt = _state.lastDisposeAt,
        lastError = _state.lastError,
    })
end

function M.apply(opts)
    opts = opts or {}
    -- SAFE no-op: "all" is not a real UI window module yet.
    _state.lastApplyAt = os.time()
    _state.lastError = nil
    return true, nil
end

function M.dispose(opts)
    opts = opts or {}
    -- SAFE no-op: nothing to dispose.
    _state.lastDisposeAt = os.time()
    _state.lastError = nil
    return true, nil
end

return M
