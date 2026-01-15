-- #########################################################################
-- Module Name : dwkit.ui.ui_validator
-- Owner       : UI
-- Version     : v2026-01-15J
-- Purpose     :
--   - Compatibility + convenience wrapper for UI validation.
--   - Delegates to dwkit.ui.ui_contract_validator (authoritative implementation).
--   - Provides validateAll() and validateOne() APIs expected by dwgui validate.
--   - SAFE: no gameplay commands, no timers, no automation, no event emissions.
--
-- Public API  :
--   - getModuleVersion() -> string
--   - getContractValidatorVersion() -> string
--   - validateOne(uiId, opts?) -> boolean ok, table result | false, string err
--   - validateAll(opts?) -> boolean ok, table results | false, string err
--
-- Notes:
--   - This module exists because dwgui expects: require("dwkit.ui.ui_validator")
--   - The actual validation rules live in ui_contract_validator.
-- #########################################################################

local M = {}

M.VERSION = "v2026-01-15J"

local function _safeRequire(modName)
    local ok, mod = pcall(require, modName)
    if ok then return true, mod end
    return false, mod
end

local function _getContractValidator()
    local ok, v = _safeRequire("dwkit.ui.ui_contract_validator")
    if not ok or type(v) ~= "table" then
        return nil, "dwkit.ui.ui_contract_validator not available"
    end
    return v, nil
end

function M.getModuleVersion()
    return M.VERSION
end

function M.getContractValidatorVersion()
    local v, _ = _getContractValidator()
    if type(v) == "table" then
        return tostring(v.VERSION or "unknown")
    end
    return "missing"
end

-- validateOne(uiId, opts?) -> boolean ok, table result | false, string err
function M.validateOne(uiId, opts)
    opts = (type(opts) == "table") and opts or {}

    local v, err = _getContractValidator()
    if not v then
        return false, tostring(err or "contract validator missing")
    end

    if type(v.validateOne) ~= "function" then
        return false, "ui_contract_validator.validateOne not available"
    end

    -- Contract validator returns: true, resultTable  OR  false, resultTable
    local okCall, a, b = pcall(v.validateOne, uiId, opts)
    if not okCall then
        return false, "validateOne threw error: " .. tostring(a)
    end

    if a == true then
        return true, b
    end

    -- a == false -> b is still a result table (best-effort); convert to string err
    if type(b) == "table" then
        local msg = "validateOne failed"
        if type(b.errors) == "table" and #b.errors > 0 then
            msg = tostring(b.errors[1] or msg)
        end
        return false, msg
    end

    return false, tostring(b or "validateOne failed")
end

-- validateAll(opts?) -> boolean ok, table results | false, string err
function M.validateAll(opts)
    opts = (type(opts) == "table") and opts or {}

    local v, err = _getContractValidator()
    if not v then
        return false, tostring(err or "contract validator missing")
    end

    if type(v.validateAll) ~= "function" then
        return false, "ui_contract_validator.validateAll not available"
    end

    -- Contract validator returns:
    --   true, { status="OK", count=n, results=[...] }
    --   false, { status="FAIL", error="...", results=[...] }
    local okCall, a, b = pcall(v.validateAll, opts)
    if not okCall then
        return false, "validateAll threw error: " .. tostring(a)
    end

    if a == true then
        return true, b
    end

    -- a == false, b likely a failure object
    if type(b) == "table" then
        local msg = b.error or "validateAll failed"
        return false, tostring(msg)
    end

    return false, tostring(b or "validateAll failed")
end

return M
