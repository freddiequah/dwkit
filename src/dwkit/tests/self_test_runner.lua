-- #########################################################################
-- Module Name : dwkit.tests.self_test_runner
-- Owner       : Tests
-- Purpose     :
--   - Provide a SAFE, manual-only self-test runner skeleton.
--   - Prints PASS/FAIL summary + compatibility baseline output.
--   - DOES NOT send gameplay commands.
--   - DOES NOT start timers or automation.
--
-- Public API  :
--   - run(opts?) -> boolean passAll, table results
--
-- Events Emitted   : None
-- Events Consumed  : None
-- Persistence      : None
-- Automation Policy: Manual only
-- Dependencies     :
--   - Optional: DWKit.core.runtimeBaseline (if loader already attached it)
--   - Fallback: require("dwkit.core.runtime_baseline")
-- #########################################################################

local M = {}

-- -------------------------
-- Safe output helper
-- -------------------------
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

local function _yesNo(v) return v and "YES" or "NO" end

local function _safeRequire(modName)
    local ok, mod = pcall(require, modName)
    if ok then return true, mod end
    return false, mod
end

-- -------------------------
-- Main runner
-- -------------------------
function M.run(opts)
    opts = opts or {}

    local results = {
        version = "v2026-01-06A",
        pass = 0,
        fail = 0,
        checks = {},
    }

    local function addCheck(name, ok, detail)
        table.insert(results.checks, {
            name = tostring(name),
            ok = ok and true or false,
            detail = tostring(detail or ""),
        })
        if ok then results.pass = results.pass + 1 else results.fail = results.fail + 1 end
    end

    _out("[DWKit Test] self_test_runner " .. results.version)
    _out("")

    -- Check 1: loader/global presence (optional but recommended)
    local hasGlobal = (type(_G.DWKit) == "table")
    addCheck("Global present (DWKit)", hasGlobal, "DWKit=" .. _yesNo(hasGlobal))

    -- Check 2: runtime baseline availability
    local rb = nil
    if hasGlobal and type(_G.DWKit.core) == "table" and type(_G.DWKit.core.runtimeBaseline) == "table" then
        rb = _G.DWKit.core.runtimeBaseline
        addCheck("runtimeBaseline attached via loader", true, "DWKit.core.runtimeBaseline=YES")
    else
        local okReq, mod = _safeRequire("dwkit.core.runtime_baseline")
        if okReq and type(mod) == "table" then
            rb = mod
            addCheck("runtimeBaseline require() fallback", true, "require(dwkit.core.runtime_baseline)=OK")
        else
            addCheck("runtimeBaseline available", false,
                "Missing dwkit.core.runtime_baseline (and not attached on DWKit.core)")
        end
    end

    _out("")
    _out("[DWKit Test] Compatibility baseline:")
    if rb and type(rb.printInfo) == "function" then
        -- Preferred: reuse the already-verified baseline printer
        local okPrint, err = pcall(rb.printInfo)
        addCheck("runtimeBaseline.printInfo()", okPrint, okPrint and "Printed baseline" or ("Error: " .. tostring(err)))
    else
        addCheck("runtimeBaseline.printInfo()", false, "printInfo() not available")
        _out("  (No baseline output available)")
    end

    -- Summary
    _out("")
    _out("[DWKit Test] Summary: PASS=" .. tostring(results.pass) .. " FAIL=" .. tostring(results.fail))

    -- Optional: print details for failures (copy/paste friendly)
    if results.fail > 0 then
        _out("")
        _out("[DWKit Test] Fail details:")
        for _, c in ipairs(results.checks) do
            if not c.ok then
                _out("  - FAIL " .. c.name .. " :: " .. c.detail)
            end
        end
    end

    local passAll = (results.fail == 0)
    return passAll, results
end

return M
