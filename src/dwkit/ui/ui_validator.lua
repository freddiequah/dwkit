-- #########################################################################
-- Module Name : dwkit.ui.ui_validator
-- Owner       : UI
-- Version     : v2026-01-15L
-- Purpose     :
--   - Compatibility + convenience wrapper for UI validation.
--   - Delegates to dwkit.ui.ui_contract_validator (authoritative implementation).
--   - Provides validateAll() and validateOne() APIs expected by dwgui validate.
--   - SAFE: no gameplay commands, no timers, no automation, no event emissions.
--
-- Public API  :
--   - getModuleVersion() -> string
--   - getContractValidatorVersion() -> string
--   - validateOne(uiId, opts?) -> boolean ok, table result
--   - validateAll(opts?) -> boolean ok, table summary
--
-- Notes:
--   - ok boolean is meaningful:
--       * validateOne: ok=false when status=FAIL
--       * validateAll: ok=false when any FAIL exists
--   - Always returns structured tables (no string conversion).
-- #########################################################################

local M = {}

M.VERSION = "v2026-01-15L"

local function _safeRequire(modName)
    local ok, mod = pcall(require, modName)
    if ok then return true, mod end
    return false, mod
end

-- Robust caller for APIs that may be implemented as obj.fn(...) OR obj:fn(...)
-- Tries no-self first, then self (only if the first attempt fails).
-- Returns: ok, a, b, c, err
local function _callBestEffort(obj, fnName, ...)
    if type(obj) ~= "table" then
        return false, nil, nil, nil, "obj not table"
    end

    local fn = obj[fnName]
    if type(fn) ~= "function" then
        return false, nil, nil, nil, "missing function: " .. tostring(fnName)
    end

    local ok1, a1, b1, c1 = pcall(fn, ...)
    if ok1 then
        return true, a1, b1, c1, nil
    end

    local ok2, a2, b2, c2 = pcall(fn, obj, ...)
    if ok2 then
        return true, a2, b2, c2, nil
    end

    return false, nil, nil, nil, "call failed: " .. tostring(a1) .. " | " .. tostring(a2)
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

-- validateOne(uiId, opts?) -> boolean ok, table result
function M.validateOne(uiId, opts)
    opts = (type(opts) == "table") and opts or {}

    local v, err = _getContractValidator()
    if not v then
        return false, { status = "FAIL", error = tostring(err or "contract validator missing") }
    end

    if type(v.validateOne) ~= "function" then
        return false, { status = "FAIL", error = "ui_contract_validator.validateOne not available" }
    end

    local okCall, okFlag, resultOrErr, extra, callErr = _callBestEffort(v, "validateOne", uiId, opts)
    if not okCall then
        return false, { status = "FAIL", error = "validateOne call failed: " .. tostring(callErr) }
    end

    -- Expected:
    --   okFlag = boolean (false only when FAIL)
    --   resultOrErr = table
    return (okFlag == true), resultOrErr
end

-- validateAll(opts?) -> boolean ok, table summary
function M.validateAll(opts)
    opts = (type(opts) == "table") and opts or {}

    local v, err = _getContractValidator()
    if not v then
        return false, { status = "FAIL", error = tostring(err or "contract validator missing") }
    end

    if type(v.validateAll) ~= "function" then
        return false, { status = "FAIL", error = "ui_contract_validator.validateAll not available" }
    end

    local okCall, okFlag, summaryOrErr, extra, callErr = _callBestEffort(v, "validateAll", opts)
    if not okCall then
        return false, { status = "FAIL", error = "validateAll call failed: " .. tostring(callErr) }
    end

    return (okFlag == true), summaryOrErr
end

return M
