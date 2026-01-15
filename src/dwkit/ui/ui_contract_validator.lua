-- #########################################################################
-- Module Name : dwkit.ui.ui_contract_validator
-- Owner       : UI
-- Version     : v2026-01-15C
-- Purpose     :
--   - SAFE UI contract validator for DWKit UI modules.
--   - Validates basic module contract compliance:
--       * module table exists
--       * VERSION (string) present
--       * UI_ID (string) present
--       * UI_ID matches expected uiId (when provided)
--       * optional functions: init/apply/dispose/getState
--       * apply() recommended (WARN if missing)
--   - Provides validateAll() (based on gui_settings list) and validateOne(uiId).
--   - SAFE: no gameplay commands, no timers, no automation, no event emissions.
--
-- Public API  :
--   - getModuleVersion() -> string
--   - validateOne(uiId, opts?) -> boolean ok, table result
--   - validateAll(opts?) -> boolean ok, table summary
--
-- Notes:
--   - Missing UI module file is treated as SKIP (not FAIL) to support staged rollout.
--   - IMPORTANT: ok boolean reflects overall PASS/WARN/SKIP vs FAIL.
--       * PASS/WARN/SKIP => ok=true
--       * FAIL           => ok=false
--
-- Options:
--   - validateAll({ onlyEnabled=true }) : validates only gui_settings entries where enabled=true
-- #########################################################################

local M = {}

M.VERSION = "v2026-01-15C"

local function _isNonEmptyString(s)
    return type(s) == "string" and s ~= ""
end

local function _sortedKeys(t)
    local keys = {}
    if type(t) ~= "table" then return keys end
    for k, _ in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    return keys
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
    if ok and type(mod) == "table" then
        return mod
    end

    return nil
end

local function _ensureLoaded(gs)
    if type(gs) ~= "table" then
        return false, "guiSettings missing"
    end

    local alreadyLoaded = false
    if type(gs.isLoaded) == "function" then
        local okLoaded, v = pcall(gs.isLoaded)
        alreadyLoaded = (okLoaded and v == true)
    end

    if (not alreadyLoaded) and type(gs.load) == "function" then
        pcall(gs.load, { quiet = true })
    end

    return true, nil
end

local function _mkResult(uiId, moduleName)
    return {
        uiId = tostring(uiId or ""),
        moduleName = tostring(moduleName or ""),
        status = "UNKNOWN", -- PASS|WARN|FAIL|SKIP
        version = nil,
        moduleUiId = nil,
        has = {
            init = false,
            apply = false,
            dispose = false,
            getState = false,
        },
        warnings = {},
        errors = {},
        notes = {},
    }
end

local function _push(t, msg)
    if type(t) ~= "table" then return end
    t[#t + 1] = tostring(msg or "")
end

local function _isFn(x) return type(x) == "function" end

local function _validateModuleTable(mod, expectedUiId, res)
    if type(mod) ~= "table" then
        res.status = "FAIL"
        _push(res.errors, "module is not a table")
        return res
    end

    -- Required: VERSION, UI_ID
    local ver = mod.VERSION
    local mid = mod.UI_ID

    if not _isNonEmptyString(ver) then
        _push(res.errors, "missing/invalid VERSION (string)")
    else
        res.version = tostring(ver)
    end

    if not _isNonEmptyString(mid) then
        _push(res.errors, "missing/invalid UI_ID (string)")
    else
        res.moduleUiId = tostring(mid)
    end

    if _isNonEmptyString(expectedUiId) and _isNonEmptyString(res.moduleUiId) then
        if tostring(expectedUiId) ~= tostring(res.moduleUiId) then
            _push(res.errors,
                "UI_ID mismatch: expected=" .. tostring(expectedUiId) .. " got=" .. tostring(res.moduleUiId))
        end
    end

    -- Optional functions (apply recommended)
    res.has.init = _isFn(mod.init)
    res.has.apply = _isFn(mod.apply)
    res.has.dispose = _isFn(mod.dispose)
    res.has.getState = _isFn(mod.getState)

    if not res.has.apply then
        _push(res.warnings, "apply() is missing (recommended)")
    end

    -- Decide status
    if #res.errors > 0 then
        res.status = "FAIL"
        return res
    end

    if #res.warnings > 0 then
        res.status = "WARN"
        return res
    end

    res.status = "PASS"
    return res
end

function M.getModuleVersion()
    return M.VERSION
end

-- validateOne(uiId) -> ok, resultTable
-- ok=true for PASS/WARN/SKIP, ok=false for FAIL
function M.validateOne(uiId, opts)
    opts = (type(opts) == "table") and opts or {}

    local moduleName = "dwkit.ui." .. tostring(uiId or "")
    local res = _mkResult(uiId, moduleName)

    if not _isNonEmptyString(uiId) then
        res.status = "FAIL"
        _push(res.errors, "uiId invalid")
        return false, res
    end

    local okR, modOrErr = _safeRequire(moduleName)
    if not okR or type(modOrErr) ~= "table" then
        res.status = "SKIP"
        _push(res.notes, "no module yet (require failed)")
        return true, res
    end

    _validateModuleTable(modOrErr, uiId, res)

    if res.status == "FAIL" then
        return false, res
    end

    return true, res
end

local function _mkFailSummary(errMsg)
    return {
        status = "FAIL",
        error = tostring(errMsg or "validateAll failed"),
        count = 0,
        passCount = 0,
        warnCount = 0,
        failCount = 0,
        skipCount = 0,
        results = {},
    }
end

-- validateAll() -> ok, summaryTable
-- ok=false if any FAIL exists, even if others PASS/WARN/SKIP
function M.validateAll(opts)
    opts = (type(opts) == "table") and opts or {}
    local onlyEnabled = (opts.onlyEnabled == true)

    local gs = _getGuiSettingsBestEffort()
    if type(gs) ~= "table" then
        return false, _mkFailSummary("guiSettings not available (run loader.init first)")
    end

    local okLoad, loadErr = _ensureLoaded(gs)
    if not okLoad then
        return false, _mkFailSummary(loadErr)
    end

    if type(gs.list) ~= "function" then
        return false, _mkFailSummary("guiSettings.list not available")
    end

    local okL, uiMap = pcall(gs.list)
    if not okL or type(uiMap) ~= "table" then
        return false, _mkFailSummary("guiSettings.list failed")
    end

    local keys = _sortedKeys(uiMap)
    local results = {}

    local passCount = 0
    local warnCount = 0
    local failCount = 0
    local skipCount = 0

    for _, id in ipairs(keys) do
        -- Optional filter: only validate enabled UI
        if onlyEnabled then
            local rec = uiMap[id]
            if type(rec) == "table" and rec.enabled ~= true then
                -- ignore disabled
            else
                local okOne, r = M.validateOne(id, opts)

                if type(r) ~= "table" then
                    local fallback = _mkResult(id, "dwkit.ui." .. tostring(id))
                    fallback.status = "FAIL"
                    _push(fallback.errors, "validateOne returned invalid result")
                    results[#results + 1] = fallback
                    failCount = failCount + 1
                else
                    results[#results + 1] = r

                    if r.status == "PASS" then passCount = passCount + 1 end
                    if r.status == "WARN" then warnCount = warnCount + 1 end
                    if r.status == "FAIL" then failCount = failCount + 1 end
                    if r.status == "SKIP" then skipCount = skipCount + 1 end
                end
            end
        else
            local okOne, r = M.validateOne(id, opts)

            if type(r) ~= "table" then
                local fallback = _mkResult(id, "dwkit.ui." .. tostring(id))
                fallback.status = "FAIL"
                _push(fallback.errors, "validateOne returned invalid result")
                results[#results + 1] = fallback
                failCount = failCount + 1
            else
                results[#results + 1] = r

                if r.status == "PASS" then passCount = passCount + 1 end
                if r.status == "WARN" then warnCount = warnCount + 1 end
                if r.status == "FAIL" then failCount = failCount + 1 end
                if r.status == "SKIP" then skipCount = skipCount + 1 end
            end
        end
    end

    local overallStatus = "PASS"
    if failCount > 0 then
        overallStatus = "FAIL"
    elseif warnCount > 0 then
        overallStatus = "WARN"
    else
        overallStatus = "PASS"
    end

    local summary = {
        status = overallStatus,
        count = #results,
        passCount = passCount,
        warnCount = warnCount,
        failCount = failCount,
        skipCount = skipCount,
        results = results,
    }

    if overallStatus == "FAIL" then
        summary.error = "One or more UI modules failed contract validation"
        return false, summary
    end

    return true, summary
end

return M
