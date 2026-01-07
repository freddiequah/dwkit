-- #########################################################################
-- Module Name : dwkit.tests.self_test_runner
-- Owner       : Tests
-- Purpose     :
--   - Provide a SAFE, manual-only self-test runner.
--   - Prints PASS/FAIL summary + compatibility baseline output.
--   - Prints canonical identity info (packageId/eventPrefix/dataFolderName/versionTagStyle).
--   - Prints core surfaces + registries + loader/boot wiring checks.
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
--   - Optional: DWKit surfaces (if loader already attached them)
--   - Fallback requires:
--       - require("dwkit.core.runtime_baseline")
--       - require("dwkit.core.identity")
--       - require("dwkit.bus.event_registry")
--       - require("dwkit.bus.command_registry")
-- #########################################################################

local M = {}

M.VERSION = "v2026-01-07A"

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

local function _safecall(fn, ...)
    local ok, res = pcall(fn, ...)
    if ok then return true, res end
    return false, res
end

local function _lineCheck(ok, name, detail)
    if ok then
        _out("  PASS - " .. name .. (detail and detail ~= "" and (" :: " .. detail) or ""))
    else
        _out("  FAIL - " .. name .. (detail and detail ~= "" and (" :: " .. detail) or ""))
    end
end

-- -------------------------
-- Main runner
-- -------------------------
function M.run(opts)
    opts = opts or {}

    local results = {
        version = M.VERSION,
        pass = 0,
        fail = 0,
        checks = {},
        ts = os.time(),
    }

    local function addCheck(name, ok, detail)
        table.insert(results.checks, {
            name = tostring(name),
            ok = ok and true or false,
            detail = tostring(detail or ""),
        })
        if ok then results.pass = results.pass + 1 else results.fail = results.fail + 1 end
    end

    local function check(name, ok, detail)
        addCheck(name, ok, detail)
        return ok
    end

    -- ------------------------------------------------------------
    -- 1) Header (required)
    -- ------------------------------------------------------------
    _out("[DWKit Test] self_test_runner " .. results.version)

    local human = ""
    if type(os.date) == "function" then
        human = os.date("%Y-%m-%d %H:%M:%S")
    end
    if human ~= "" then
        _out("[DWKit Test] ts=" .. tostring(results.ts) .. " (" .. human .. ")")
    else
        _out("[DWKit Test] ts=" .. tostring(results.ts))
    end
    _out("")

    -- ------------------------------------------------------------
    -- Gather core surfaces (no output yet)
    -- ------------------------------------------------------------
    local hasGlobal = (type(_G.DWKit) == "table")
    local DW = hasGlobal and _G.DWKit or nil

    -- identity module
    local ident = nil
    if hasGlobal and type(DW.core) == "table" and type(DW.core.identity) == "table" then
        ident = DW.core.identity
        check("core.identity attached via loader", true, "DWKit.core.identity=YES")
    else
        local okReq, mod = _safeRequire("dwkit.core.identity")
        if okReq and type(mod) == "table" then
            ident = mod
            check("core.identity require() fallback", true, "require(dwkit.core.identity)=OK")
        else
            check("core.identity available", false, "Missing dwkit.core.identity (and not attached on DWKit.core)")
        end
    end

    -- runtime baseline module
    local rb = nil
    if hasGlobal and type(DW.core) == "table" and type(DW.core.runtimeBaseline) == "table" then
        rb = DW.core.runtimeBaseline
        check("core.runtimeBaseline attached via loader", true, "DWKit.core.runtimeBaseline=YES")
    else
        local okReq, mod = _safeRequire("dwkit.core.runtime_baseline")
        if okReq and type(mod) == "table" then
            rb = mod
            check("core.runtimeBaseline require() fallback", true, "require(dwkit.core.runtime_baseline)=OK")
        else
            check("core.runtimeBaseline available", false,
                "Missing dwkit.core.runtime_baseline (and not attached on DWKit.core)")
        end
    end

    -- registries
    local evReg = nil
    if hasGlobal and type(DW.bus) == "table" and type(DW.bus.eventRegistry) == "table" then
        evReg = DW.bus.eventRegistry
        check("bus.eventRegistry attached via loader", true, "DWKit.bus.eventRegistry=YES")
    else
        local okReq, mod = _safeRequire("dwkit.bus.event_registry")
        if okReq and type(mod) == "table" then
            evReg = mod
            check("bus.eventRegistry require() fallback", true, "require(dwkit.bus.event_registry)=OK")
        else
            check("bus.eventRegistry available", false,
                "Missing dwkit.bus.event_registry (and not attached on DWKit.bus)")
        end
    end

    local cmdReg = nil
    if hasGlobal and type(DW.bus) == "table" and type(DW.bus.commandRegistry) == "table" then
        cmdReg = DW.bus.commandRegistry
        check("bus.commandRegistry attached via loader", true, "DWKit.bus.commandRegistry=YES")
    else
        local okReq, mod = _safeRequire("dwkit.bus.command_registry")
        if okReq and type(mod) == "table" then
            cmdReg = mod
            check("bus.commandRegistry require() fallback", true, "require(dwkit.bus.command_registry)=OK")
        else
            check("bus.commandRegistry available", false,
                "Missing dwkit.bus.command_registry (and not attached on DWKit.bus)")
        end
    end

    -- ------------------------------------------------------------
    -- 2) Compatibility Baseline (required)
    -- ------------------------------------------------------------
    _out("[DWKit Test] Compatibility baseline:")

    -- Always print Lua version string (spec requirement)
    _out("[DWKit] lua=" .. tostring(_VERSION or "unknown"))

    -- Prefer the existing baseline printer (already used elsewhere)
    if rb and type(rb.printInfo) == "function" then
        local okPrint, err = pcall(rb.printInfo)
        check("runtimeBaseline.printInfo()", okPrint, okPrint and "Printed baseline" or ("Error: " .. tostring(err)))
    else
        check("runtimeBaseline.printInfo()", false, "printInfo() not available")
        _out("[DWKit] mudlet=(unavailable)")
    end
    _out("")

    -- ------------------------------------------------------------
    -- 3) Canonical Identity (required)
    -- ------------------------------------------------------------
    _out("[DWKit Test] Canonical identity:")
    if ident then
        local idVersion = tostring(ident.VERSION or "unknown")
        local pkgId     = tostring(ident.packageId or "unknown")
        local evp       = tostring(ident.eventPrefix or "unknown")
        local df        = tostring(ident.dataFolderName or "unknown")
        local vts       = tostring(ident.versionTagStyle or "unknown")
        _out("[DWKit] identity=" ..
            idVersion ..
            " packageId=" .. pkgId .. " eventPrefix=" .. evp .. " dataFolder=" .. df .. " versionTagStyle=" .. vts)
        check("identity fields printed", true, "Printed canonical identity fields")
    else
        _out("  (No identity output available)")
        check("identity fields printed", false, "identity module not available")
    end
    _out("")

    -- ------------------------------------------------------------
    -- 4) Core Surface Checks (required)
    -- ------------------------------------------------------------
    _out("[DWKit Test] Core surface checks:")

    local okGlobal = check("DWKit global exists", hasGlobal, "DWKit=" .. _yesNo(hasGlobal))
    _lineCheck(okGlobal, "DWKit global exists", "DWKit=" .. _yesNo(hasGlobal))

    local okCore = (hasGlobal and type(DW.core) == "table")
    check("DWKit.core exists", okCore, "DWKit.core=" .. _yesNo(okCore))
    _lineCheck(okCore, "DWKit.core exists", "DWKit.core=" .. _yesNo(okCore))

    local okIdentSurf = (hasGlobal and type(DW.core) == "table" and type(DW.core.identity) == "table")
    check("DWKit.core.identity exists", okIdentSurf, "DWKit.core.identity=" .. _yesNo(okIdentSurf))
    _lineCheck(okIdentSurf, "DWKit.core.identity exists", "DWKit.core.identity=" .. _yesNo(okIdentSurf))

    local okRbSurf = (hasGlobal and type(DW.core) == "table" and type(DW.core.runtimeBaseline) == "table")
    check("DWKit.core.runtimeBaseline exists", okRbSurf, "DWKit.core.runtimeBaseline=" .. _yesNo(okRbSurf))
    _lineCheck(okRbSurf, "DWKit.core.runtimeBaseline exists", "DWKit.core.runtimeBaseline=" .. _yesNo(okRbSurf))

    local okCmdSurf = (hasGlobal and type(DW.cmd) == "table")
    check("DWKit.cmd (runtime surface) exists", okCmdSurf, "DWKit.cmd=" .. _yesNo(okCmdSurf))
    _lineCheck(okCmdSurf, "DWKit.cmd (runtime surface) exists", "DWKit.cmd=" .. _yesNo(okCmdSurf))

    local okTestSurf = (hasGlobal and type(DW.test) == "table" and type(DW.test.run) == "function")
    check("DWKit.test.run exists", okTestSurf, "DWKit.test.run=" .. _yesNo(okTestSurf))
    _lineCheck(okTestSurf, "DWKit.test.run exists", "DWKit.test.run=" .. _yesNo(okTestSurf))

    _out("")

    -- ------------------------------------------------------------
    -- 5) Registry Checks (required)
    -- ------------------------------------------------------------
    _out("[DWKit Test] Registry checks:")

    local okEvReg = (type(evReg) == "table")
    check("event registry present", okEvReg, "eventRegistry=" .. _yesNo(okEvReg))
    if okEvReg then
        local count = nil
        if type(evReg.listAll) == "function" then
            local okList, list = _safecall(evReg.listAll)
            if okList and type(list) == "table" then
                count = #list
                _lineCheck(true, "event registry listable", "count=" .. tostring(count))
                check("event registry listable", true, "count=" .. tostring(count))
            else
                _lineCheck(false, "event registry listable", "listAll() error")
                check("event registry listable", false, "listAll() error")
            end
        else
            _lineCheck(false, "event registry listable", "listAll() missing")
            check("event registry listable", false, "listAll() missing")
        end
    else
        _lineCheck(false, "event registry present", "missing")
    end

    local okCmdReg = (type(cmdReg) == "table")
    check("command registry present", okCmdReg, "commandRegistry=" .. _yesNo(okCmdReg))
    if okCmdReg then
        local count = nil
        if type(cmdReg.listAll) == "function" then
            local okList, list = _safecall(cmdReg.listAll)
            if okList and type(list) == "table" then
                count = #list
                _lineCheck(true, "command registry listable", "count=" .. tostring(count))
                check("command registry listable", true, "count=" .. tostring(count))
            else
                _lineCheck(false, "command registry listable", "listAll() error")
                check("command registry listable", false, "listAll() error")
            end
        else
            _lineCheck(false, "command registry listable", "listAll() missing")
            check("command registry listable", false, "listAll() missing")
        end
    else
        _lineCheck(false, "command registry present", "missing")
    end

    _out("")

    -- ------------------------------------------------------------
    -- 6) Loader / Boot Wiring Checks (required, SAFE)
    -- ------------------------------------------------------------
    _out("[DWKit Test] Loader and boot wiring checks:")

    local initKnown = (hasGlobal and DW._lastInitTs ~= nil)
    check("loader init status known", initKnown, "lastInitTs=" .. tostring(DW and DW._lastInitTs or "nil"))
    _lineCheck(initKnown, "loader init status known", "lastInitTs=" .. tostring(DW and DW._lastInitTs or "nil"))

    local bootReadyKnown = (hasGlobal and DW._bootReadyEmitted ~= nil)
    check("bootReady emitted flag known", bootReadyKnown,
        "_bootReadyEmitted=" .. tostring(DW and DW._bootReadyEmitted or "nil"))
    _lineCheck(bootReadyKnown, "bootReady emitted flag known",
        "_bootReadyEmitted=" .. tostring(DW and DW._bootReadyEmitted or "nil"))

    local hadEmitError = (hasGlobal and DW._bootReadyEmitError ~= nil and DW._bootReadyEmitError ~= false and DW._bootReadyEmitError ~= "")
    if hasGlobal then
        -- If the field doesn't exist, we still report it as "none"
        local e = DW._bootReadyEmitError
        if e == nil or e == false or e == "" then
            check("bootReady emit error", true, "(none)")
            _lineCheck(true, "bootReady emit error", "(none)")
        else
            check("bootReady emit error", false, tostring(e))
            _lineCheck(false, "bootReady emit error", tostring(e))
        end
    else
        check("bootReady emit error", false, "DWKit global missing")
        _lineCheck(false, "bootReady emit error", "DWKit global missing")
    end

    _out("")

    -- ------------------------------------------------------------
    -- 7) Summary (required)
    -- ------------------------------------------------------------
    _out("[DWKit Test] Summary:")
    local passAll = (results.fail == 0)
    _out("  verdict: " .. (passAll and "PASS" or "FAIL"))
    _out("  PASS=" .. tostring(results.pass) .. " FAIL=" .. tostring(results.fail))

    if not passAll then
        _out("  failed checks:")
        for _, c in ipairs(results.checks) do
            if not c.ok then
                _out("    - " .. c.name)
            end
        end
    end

    return passAll, results
end

return M
