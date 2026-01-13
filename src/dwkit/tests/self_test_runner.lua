-- #########################################################################
-- Module Name : dwkit.tests.self_test_runner
-- Owner       : Tests
-- Version     : v2026-01-13C
-- Purpose     :
--   - Provide a SAFE, manual-only self-test runner.
--   - Prints PASS/FAIL summary + compatibility baseline output.
--   - Prints canonical identity info (packageId/eventPrefix/dataFolderName/versionTagStyle).
--   - Prints core surfaces + registries + loader/boot wiring checks.
--   - Validates Event Registry contract (SAFE) to detect registry drift early.
--   - Detects docs vs runtime registry version drift early (Objective D1).
--   - Includes SAFE persistence smoke checks (selftest-only files; cleanup best-effort).
--   - DOES NOT send gameplay commands.
--   - DOES NOT start timers or automation.
--
-- Public API  :
--   - run(opts?) -> boolean passAll, table results
--     opts:
--       - quiet: boolean (when true, prefer count-only registry checks)
--
-- Events Emitted   : None
-- Events Consumed  : None
-- Persistence      : None (test writes to selftest/* only; best-effort cleanup)
-- Automation Policy: Manual only
-- Dependencies     :
--   - Optional: DWKit surfaces (if loader already attached them)
--   - Fallback requires:
--       - require("dwkit.core.runtime_baseline")
--       - require("dwkit.core.identity")
--       - require("dwkit.bus.event_registry")
--       - require("dwkit.bus.command_registry")
--   - Optional (persistence smoke checks):
--       - require("dwkit.persist.store")
-- #########################################################################

local M = {}

M.VERSION = "v2026-01-13C"

-- -------------------------
-- Objective D1: Registry version drift locks
-- -------------------------
-- MUST match docs/Event_Registry_v1.0.md "## Version"
local EXPECTED_EVENT_REGISTRY_VERSION = "v1.8"

-- MUST match docs/Command_Registry_v1.0.md "## Version"
local EXPECTED_COMMAND_REGISTRY_VERSION = "v2.9"

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
local function _isNonEmptyString(s) return type(s) == "string" and s ~= "" end

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

local function _countAnyTable(t)
    if type(t) ~= "table" then return 0 end

    -- If it's an array-like list, #t works.
    -- If it's a map keyed by names, #t may be 0, so fall back to pairs().
    local n = #t
    if n and n > 0 then return n end

    n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

local function _getCountNoPrint(reg)
    if type(reg) ~= "table" then return false, "registry not table" end

    -- Prefer explicit count() if present (try both f() and f(self) safely)
    if type(reg.count) == "function" then
        local ok1, n1 = _safecall(reg.count)
        if ok1 and type(n1) == "number" then return true, n1 end

        local ok2, n2 = _safecall(reg.count, reg)
        if ok2 and type(n2) == "number" then return true, n2 end

        return false, "count() error"
    end

    -- Prefer getAll() if present (try both f() and f(self))
    if type(reg.getAll) == "function" then
        local ok1, list1 = _safecall(reg.getAll)
        if ok1 and type(list1) == "table" then
            return true, _countAnyTable(list1)
        end

        local ok2, list2 = _safecall(reg.getAll, reg)
        if ok2 and type(list2) == "table" then
            return true, _countAnyTable(list2)
        end

        return false, "getAll() error"
    end

    -- Fallback to listAll() if present (pass quiet=true to avoid spam; extra args are ignored in Lua)
    if type(reg.listAll) == "function" then
        local ok, list = _safecall(reg.listAll, { quiet = true })
        if ok and type(list) == "table" then
            return true, _countAnyTable(list)
        end

        -- also try as method if implemented that way
        local ok2, list2 = _safecall(reg.listAll, reg, { quiet = true })
        if ok2 and type(list2) == "table" then
            return true, _countAnyTable(list2)
        end

        return false, "listAll() error"
    end

    return false, "no count/getAll/listAll API"
end

local function _getCommandOwnerNoPrint(cmdReg, cmdName)
    if type(cmdReg) ~= "table" then return false, "commandRegistry not table" end
    if type(cmdName) ~= "string" or cmdName == "" then return false, "cmdName invalid" end

    -- Best: getAll() (no prints)
    if type(cmdReg.getAll) == "function" then
        local okAll, all = _safecall(cmdReg.getAll)
        if okAll and type(all) == "table" then
            local def = all[cmdName]
            if type(def) ~= "table" then
                return false, "command not found: " .. tostring(cmdName)
            end
            return true, tostring(def.ownerModule or "")
        end
        -- try method form
        local okAll2, all2 = _safecall(cmdReg.getAll, cmdReg)
        if okAll2 and type(all2) == "table" then
            local def = all2[cmdName]
            if type(def) ~= "table" then
                return false, "command not found: " .. tostring(cmdName)
            end
            return true, tostring(def.ownerModule or "")
        end
        return false, "getAll() error"
    end

    -- Fallback: help(name,{quiet=true}) (should not print)
    if type(cmdReg.help) == "function" then
        local okPcall, okHelp, cmdDef, errOrNil = pcall(cmdReg.help, cmdName, { quiet = true })
        if not okPcall then
            return false, tostring(okHelp) -- pcall error string
        end
        if okHelp and type(cmdDef) == "table" then
            return true, tostring(cmdDef.ownerModule or "")
        end
        return false, tostring(errOrNil or "help() failed")
    end

    return false, "no getAll/help API"
end

local function _getAllCommandsNoPrint(cmdReg)
    if type(cmdReg) ~= "table" then return false, nil, "commandRegistry not table" end

    if type(cmdReg.getAll) == "function" then
        local okAll, all = _safecall(cmdReg.getAll)
        if okAll and type(all) == "table" then
            return true, all, nil
        end
        local okAll2, all2 = _safecall(cmdReg.getAll, cmdReg)
        if okAll2 and type(all2) == "table" then
            return true, all2, nil
        end
        return false, nil, "getAll() error"
    end

    return false, nil, "getAll() missing"
end

local function _getGameListNoPrint(cmdReg)
    if type(cmdReg) ~= "table" then return false, nil, "commandRegistry not table" end
    if type(cmdReg.listGame) ~= "function" then return false, nil, "listGame() missing" end

    local okList, list = _safecall(cmdReg.listGame, { quiet = true })
    if okList and type(list) == "table" then
        return true, list, nil
    end

    local okList2, list2 = _safecall(cmdReg.listGame, cmdReg, { quiet = true })
    if okList2 and type(list2) == "table" then
        return true, list2, nil
    end

    return false, nil, "listGame() error"
end

local function _validateSafeCommandDef(def)
    if type(def) ~= "table" then return false, "def not table" end

    if def.sendsToGame ~= false then
        return false, "sendsToGame must be false"
    end

    if tostring(def.safety or "") ~= "SAFE" then
        return false, "safety must be SAFE"
    end

    if not _isNonEmptyString(def.mode) then
        return false, "mode must be non-empty"
    end

    if not _isNonEmptyString(def.ownerModule) then
        return false, "ownerModule must be non-empty"
    end

    if not _isNonEmptyString(def.syntax) then
        return false, "syntax must be non-empty"
    end

    if not _isNonEmptyString(def.description) then
        return false, "description must be non-empty"
    end

    return true, nil
end

local function _validateGameWrapperDef(def)
    if type(def) ~= "table" then return false, "def not table" end

    if def.sendsToGame ~= true then
        return false, "sendsToGame must be true"
    end

    local safety = tostring(def.safety or "")
    if safety ~= "COMBAT-SAFE" and safety ~= "NOT SAFE" then
        return false, "safety must be COMBAT-SAFE or NOT SAFE"
    end

    if not _isNonEmptyString(def.underlyingGameCommand) then
        return false, "underlyingGameCommand must be non-empty"
    end

    if not _isNonEmptyString(def.sideEffects) then
        return false, "sideEffects must be non-empty"
    end

    if not _isNonEmptyString(def.mode) then
        return false, "mode must be non-empty"
    end

    if not _isNonEmptyString(def.ownerModule) then
        return false, "ownerModule must be non-empty"
    end

    if not _isNonEmptyString(def.syntax) then
        return false, "syntax must be non-empty"
    end

    if not _isNonEmptyString(def.description) then
        return false, "description must be non-empty"
    end

    return true, nil
end

-- -------------------------
-- Persistence smoke helpers (SAFE)
-- -------------------------
local function _isMissingFileErr(msg)
    msg = tostring(msg or "")
    if msg == "" then return false end
    if msg == "file not found" then return true end
    if msg:find("file not found", 1, true) ~= nil then return true end
    if msg:find("no such file", 1, true) ~= nil then return true end
    if msg:find("cannot open", 1, true) ~= nil and msg:find("No such", 1, true) ~= nil then return true end
    return false
end

local function _getPersistStoreBestEffort()
    local DW = (type(_G.DWKit) == "table") and _G.DWKit or nil
    local s = (DW and type(DW.persist) == "table") and DW.persist.store or nil
    if type(s) == "table"
        and type(s.saveEnvelope) == "function"
        and type(s.loadEnvelope) == "function"
        and type(s.delete) == "function"
    then
        return true, s, nil
    end

    local ok, modOrErr = pcall(require, "dwkit.persist.store")
    if ok and type(modOrErr) == "table"
        and type(modOrErr.saveEnvelope) == "function"
        and type(modOrErr.loadEnvelope) == "function"
        and type(modOrErr.delete) == "function"
    then
        return true, modOrErr, nil
    end

    return false, nil, "persist store not available"
end

-- Call a persist store API that returns (ok, value?, err?)
-- Returns: ok(boolean), value(any|nil), err(any|nil)
local function _callStore(fn, ...)
    local okP, okFlag, valueOrErr, errMaybe = pcall(fn, ...)
    if not okP then
        return false, nil, tostring(okFlag)
    end

    local ok = (okFlag == true)
    if ok then
        return true, valueOrErr, errMaybe
    end

    -- When okFlag==false, store may return (false, err) or (false, nil, err)
    if errMaybe ~= nil then
        return false, valueOrErr, errMaybe
    end
    return false, nil, valueOrErr
end

-- -------------------------
-- Main runner
-- -------------------------
function M.run(opts)
    opts = opts or {}
    local quiet = (opts.quiet == true)

    local results = {
        version = M.VERSION,
        pass = 0,
        fail = 0,
        checks = {},
        ts = os.time(),
        quiet = quiet,
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
    _out("[DWKit Test] mode=" .. (quiet and "quiet" or "verbose"))
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

    _out("[DWKit] lua=" .. tostring(_VERSION or "unknown"))

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
    _lineCheck(okCmdSurf, "DWKit.cmd (runtime surface) exists", "DWKit.cmd (runtime surface)=" .. _yesNo(okCmdSurf))

    local okTestSurf = (hasGlobal and type(DW.test) == "table" and type(DW.test.run) == "function")
    check("DWKit.test.run exists", okTestSurf, "DWKit.test.run=" .. _yesNo(okTestSurf))
    _lineCheck(okTestSurf, "DWKit.test.run exists", "DWKit.test.run=" .. _yesNo(okTestSurf))

    local okServices = (hasGlobal and type(DW.services) == "table")
    check("DWKit.services exists", okServices, "DWKit.services=" .. _yesNo(okServices))
    _lineCheck(okServices, "DWKit.services exists", "DWKit.services=" .. _yesNo(okServices))

    local okPresenceSvc = (okServices and type(DW.services.presenceService) == "table")
    check("presenceService attached", okPresenceSvc, "presenceService=" .. _yesNo(okPresenceSvc))
    _lineCheck(okPresenceSvc, "presenceService attached", "presenceService=" .. _yesNo(okPresenceSvc))

    local okActionSvc = (okServices and type(DW.services.actionModelService) == "table")
    check("actionModelService attached", okActionSvc, "actionModelService=" .. _yesNo(okActionSvc))
    _lineCheck(okActionSvc, "actionModelService attached", "actionModelService=" .. _yesNo(okActionSvc))

    local okSkillSvc = (okServices and type(DW.services.skillRegistryService) == "table")
    check("skillRegistryService attached", okSkillSvc, "skillRegistryService=" .. _yesNo(okSkillSvc))
    _lineCheck(okSkillSvc, "skillRegistryService attached", "skillRegistryService=" .. _yesNo(okSkillSvc))

    local okScoreSvc = (okServices and type(DW.services.scoreStoreService) == "table")
    check("scoreStoreService attached", okScoreSvc, "scoreStoreService=" .. _yesNo(okScoreSvc))
    _lineCheck(okScoreSvc, "scoreStoreService attached", "scoreStoreService=" .. _yesNo(okScoreSvc))

    _out("")

    -- ------------------------------------------------------------
    -- 5) Registry Checks (required)
    -- ------------------------------------------------------------
    _out("[DWKit Test] Registry checks:")

    local okEvReg = (type(evReg) == "table")
    check("event registry present", okEvReg, "eventRegistry=" .. _yesNo(okEvReg))
    if okEvReg then
        if quiet then
            local okCount, nOrErr = _getCountNoPrint(evReg)
            if okCount then
                _lineCheck(true, "event registry listable", "count=" .. tostring(nOrErr))
                check("event registry listable", true, "count=" .. tostring(nOrErr))
            else
                _lineCheck(false, "event registry listable", tostring(nOrErr))
                check("event registry listable", false, tostring(nOrErr))
            end
        else
            local count = nil
            if type(evReg.listAll) == "function" then
                local okList, list = _safecall(evReg.listAll)
                if okList and type(list) == "table" then
                    count = _countAnyTable(list)
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
        end

        if type(evReg.getRegistryVersion) == "function" then
            local okVer, actual = _safecall(evReg.getRegistryVersion)
            if okVer and _isNonEmptyString(actual) then
                local pass = (tostring(actual) == tostring(EXPECTED_EVENT_REGISTRY_VERSION))
                _lineCheck(pass, "event registry version locked",
                    "expected=" .. tostring(EXPECTED_EVENT_REGISTRY_VERSION) .. " actual=" .. tostring(actual))
                check("event registry version locked", pass,
                    "expected=" .. tostring(EXPECTED_EVENT_REGISTRY_VERSION) .. " actual=" .. tostring(actual))
            else
                _lineCheck(false, "event registry version locked", "getRegistryVersion() error/empty")
                check("event registry version locked", false, "getRegistryVersion() error/empty")
            end
        else
            _lineCheck(false, "event registry version locked", "getRegistryVersion() missing")
            check("event registry version locked", false, "getRegistryVersion() missing")
        end

        if type(evReg.getModuleVersion) == "function" then
            local okMv, mv = _safecall(evReg.getModuleVersion)
            local pass = (okMv and _isNonEmptyString(mv))
            _lineCheck(pass, "event registry module version present",
                pass and ("moduleVersion=" .. tostring(mv)) or "getModuleVersion() error/empty")
            check("event registry module version present", pass,
                pass and ("moduleVersion=" .. tostring(mv)) or "getModuleVersion() error/empty")
        else
            _lineCheck(false, "event registry module version present", "getModuleVersion() missing")
            check("event registry module version present", false, "getModuleVersion() missing")
        end
    else
        _lineCheck(false, "event registry present", "missing")
    end

    if okEvReg and type(evReg.validateAll) == "function" then
        local okV, passOrErr = _safecall(evReg.validateAll, { strict = true })
        if okV then
            local pass = (passOrErr == true)
            if pass then
                _lineCheck(true, "event registry contract valid", "validateAll(strict)=PASS")
                check("event registry contract valid", true, "validateAll(strict)=PASS")
            else
                local ok2, p, issues = pcall(evReg.validateAll, { strict = true })
                if ok2 and p == false and type(issues) == "table" then
                    _lineCheck(false, "event registry contract valid",
                        "validateAll(strict)=FAIL issues=" .. tostring(#issues))
                    check("event registry contract valid", false, "issues=" .. tostring(#issues))
                    if not quiet then
                        _out("  details:")
                        for _, it in ipairs(issues) do
                            local n = tostring((type(it) == "table" and it.name) or "")
                            local e = tostring((type(it) == "table" and it.error) or "")
                            if n ~= "" or e ~= "" then
                                _out("    - " ..
                                    (n ~= "" and n or "(unknown)") .. " :: " .. (e ~= "" and e or "(no error)"))
                            end
                        end
                    end
                else
                    _lineCheck(false, "event registry contract valid", "validateAll(strict)=FAIL (issues unavailable)")
                    check("event registry contract valid", false, "issues unavailable")
                end
            end
        else
            _lineCheck(false, "event registry contract valid", "validateAll() error: " .. tostring(passOrErr))
            check("event registry contract valid", false, "validateAll() error: " .. tostring(passOrErr))
        end
    else
        _lineCheck(false, "event registry contract validator available", "validateAll() missing")
        check("event registry contract validator available", false, "validateAll() missing")
    end

    if ident and okEvReg and type(evReg.has) == "function" then
        local prefix = tostring(ident.eventPrefix or "DWKit:")
        local required = {
            prefix .. "Boot:Ready",
            prefix .. "Service:Presence:Updated",
            prefix .. "Service:ActionModel:Updated",
            prefix .. "Service:SkillRegistry:Updated",
            prefix .. "Service:ScoreStore:Updated",
        }
        for _, ev in ipairs(required) do
            local okHas, hasOrErr = _safecall(evReg.has, ev)
            local pass = (okHas and hasOrErr == true)
            _lineCheck(pass, "event registered", tostring(ev))
            check("event registered: " .. tostring(ev), pass, pass and "YES" or "NO")
        end
    else
        _lineCheck(false, "required events check", "identity/evReg/evReg.has not available")
        check("required events check", false, "identity/evReg/evReg.has not available")
    end

    local okCmdReg = (type(cmdReg) == "table")
    check("command registry present", okCmdReg, "commandRegistry=" .. _yesNo(okCmdReg))
    if okCmdReg then
        if quiet then
            local okCount, nOrErr = _getCountNoPrint(cmdReg)
            if okCount then
                _lineCheck(true, "command registry listable", "count=" .. tostring(nOrErr))
                check("command registry listable", true, "count=" .. tostring(nOrErr))
            else
                _lineCheck(false, "command registry listable", tostring(nOrErr))
                check("command registry listable", false, tostring(nOrErr))
            end
        else
            local count = nil
            if type(cmdReg.listAll) == "function" then
                local okList, list = _safecall(cmdReg.listAll)
                if okList and type(list) == "table" then
                    count = _countAnyTable(list)
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
        end

        if type(cmdReg.getRegistryVersion) == "function" then
            local okVer, actual = _safecall(cmdReg.getRegistryVersion)
            if okVer and _isNonEmptyString(actual) then
                local pass = (tostring(actual) == tostring(EXPECTED_COMMAND_REGISTRY_VERSION))
                _lineCheck(pass, "command registry version locked",
                    "expected=" .. tostring(EXPECTED_COMMAND_REGISTRY_VERSION) .. " actual=" .. tostring(actual))
                check("command registry version locked", pass,
                    "expected=" .. tostring(EXPECTED_COMMAND_REGISTRY_VERSION) .. " actual=" .. tostring(actual))
            else
                _lineCheck(false, "command registry version locked", "getRegistryVersion() error/empty")
                check("command registry version locked", false, "getRegistryVersion() error/empty")
            end
        else
            _lineCheck(false, "command registry version locked", "getRegistryVersion() missing")
            check("command registry version locked", false, "getRegistryVersion() missing")
        end

        if type(cmdReg.getModuleVersion) == "function" then
            local okMv, mv = _safecall(cmdReg.getModuleVersion)
            local pass = (okMv and _isNonEmptyString(mv))
            _lineCheck(pass, "command registry module version present",
                pass and ("moduleVersion=" .. tostring(mv)) or "getModuleVersion() error/empty")
            check("command registry module version present", pass,
                pass and ("moduleVersion=" .. tostring(mv)) or "getModuleVersion() error/empty")
        else
            _lineCheck(false, "command registry module version present", "getModuleVersion() missing")
            check("command registry module version present", false, "getModuleVersion() missing")
        end

        local expectedSafe = {
            "dwactions",
            "dwboot",
            "dwcommands",
            "dwdiag",
            "dwevent",
            "dwevents",
            "dweventlog",
            "dweventsub",
            "dweventtap",
            "dweventunsub",
            "dwhelp",
            "dwid",
            "dwinfo",
            "dwpresence",
            "dwscorestore",
            "dwservices",
            "dwskills",
            "dwtest",
            "dwversion",
        }

        local okAll, allCmds, allErr = _getAllCommandsNoPrint(cmdReg)
        if okAll and type(allCmds) == "table" then
            local found = 0
            local missing = {}
            for _, name in ipairs(expectedSafe) do
                if type(allCmds[name]) == "table" then
                    found = found + 1
                else
                    table.insert(missing, name)
                end
            end

            local setPass = (found == #expectedSafe)
            if setPass then
                _lineCheck(true, "SAFE command set present",
                    "expected=" .. tostring(#expectedSafe) .. " found=" .. tostring(found))
                check("SAFE command set present", true,
                    "expected=" .. tostring(#expectedSafe) .. " found=" .. tostring(found))
            else
                _lineCheck(false, "SAFE command set present",
                    "expected=" .. tostring(#expectedSafe) .. " found=" .. tostring(found) ..
                    " missing=" .. table.concat(missing, ", "))
                check("SAFE command set present", false,
                    "missing=" .. table.concat(missing, ", "))
            end

            for _, name in ipairs(expectedSafe) do
                local def = allCmds[name]
                if type(def) ~= "table" then
                    _lineCheck(false, "SAFE command contract", name .. " :: missing")
                    check("SAFE command contract :: " .. name, false, "missing")
                else
                    local pass, err = _validateSafeCommandDef(def)
                    if pass then
                        _lineCheck(true, "SAFE command contract", name)
                        check("SAFE command contract :: " .. name, true, "OK")
                    else
                        _lineCheck(false, "SAFE command contract", name .. " :: " .. tostring(err))
                        check("SAFE command contract :: " .. name, false, tostring(err))
                    end
                end
            end

            local gameNames = {}
            for name, def in pairs(allCmds) do
                if type(def) == "table" and def.sendsToGame == true then
                    table.insert(gameNames, tostring(name))
                end
            end
            table.sort(gameNames)

            local okGameList, gameList, gameErr = _getGameListNoPrint(cmdReg)
            if okGameList and type(gameList) == "table" then
                local listCount = _countAnyTable(gameList)
                _lineCheck(true, "game command list queryable", "count=" .. tostring(listCount))
                check("game command list queryable", true, "count=" .. tostring(listCount))

                local mapList = {}
                for _, d in ipairs(gameList) do
                    if type(d) == "table" and _isNonEmptyString(d.command) then
                        mapList[tostring(d.command)] = true
                    end
                end

                local mapAll = {}
                for _, name in ipairs(gameNames) do mapAll[name] = true end

                local missingInList = {}
                for name, _ in pairs(mapAll) do
                    if not mapList[name] then table.insert(missingInList, name) end
                end
                table.sort(missingInList)

                local extraInList = {}
                for name, _ in pairs(mapList) do
                    if not mapAll[name] then table.insert(extraInList, name) end
                end
                table.sort(extraInList)

                local consistent = (#missingInList == 0 and #extraInList == 0)
                if consistent then
                    _lineCheck(true, "GAME command list consistent", "count=" .. tostring(#gameNames))
                    check("GAME command list consistent", true, "count=" .. tostring(#gameNames))
                else
                    _lineCheck(false, "GAME command list consistent",
                        "missingInList=" .. table.concat(missingInList, ", ") ..
                        " extraInList=" .. table.concat(extraInList, ", "))
                    check("GAME command list consistent", false,
                        "missingInList=" .. table.concat(missingInList, ", ") ..
                        " extraInList=" .. table.concat(extraInList, ", "))
                end

                if #gameNames == 0 then
                    _lineCheck(true, "GAME wrapper drift lock", "none")
                    check("GAME wrapper drift lock", true, "none")
                else
                    for _, name in ipairs(gameNames) do
                        local def = allCmds[name]
                        if type(def) ~= "table" then
                            _lineCheck(false, "GAME wrapper contract", name .. " :: missing")
                            check("GAME wrapper contract :: " .. name, false, "missing")
                        else
                            local pass, err = _validateGameWrapperDef(def)
                            if pass then
                                _lineCheck(true, "GAME wrapper contract", name)
                                check("GAME wrapper contract :: " .. name, true, "OK")
                            else
                                _lineCheck(false, "GAME wrapper contract", name .. " :: " .. tostring(err))
                                check("GAME wrapper contract :: " .. name, false, tostring(err))
                            end
                        end
                    end
                end
            else
                _lineCheck(false, "GAME wrapper drift lock", tostring(gameErr or "listGame() unavailable"))
                check("GAME wrapper drift lock", false, tostring(gameErr or "listGame() unavailable"))
            end
        else
            _lineCheck(false, "SAFE command drift lock", tostring(allErr or "getAll() unavailable"))
            check("SAFE command drift lock", false, tostring(allErr or "getAll() unavailable"))
        end

        local expectedOwner = "dwkit.services.command_aliases"
        local lockCommands = { "dwservices", "dwpresence", "dwactions", "dwskills", "dwscorestore" }

        for _, cmdName in ipairs(lockCommands) do
            local okOwner, ownerOrErr = _getCommandOwnerNoPrint(cmdReg, cmdName)
            if okOwner then
                local pass = (tostring(ownerOrErr) == expectedOwner)
                _lineCheck(pass, "command owner locked", cmdName .. " owner=" .. tostring(ownerOrErr))
                check("command owner locked :: " .. cmdName, pass, cmdName .. " owner=" .. tostring(ownerOrErr))
            else
                _lineCheck(false, "command owner locked", cmdName .. " :: " .. tostring(ownerOrErr))
                check("command owner locked :: " .. cmdName, false, tostring(ownerOrErr))
            end
        end
    else
        _lineCheck(false, "command registry present", "missing")
    end

    _out("")

    -- ------------------------------------------------------------
    -- 5b) Persistence Smoke Checks (SAFE; selftest-only paths)
    -- ------------------------------------------------------------
    _out("[DWKit Test] Persistence smoke checks:")

    local okStore, store, storeErr = _getPersistStoreBestEffort()
    _lineCheck(okStore, "persist store available", okStore and "dwkit.persist.store=OK" or tostring(storeErr))
    check("persist store available", okStore, okStore and "OK" or tostring(storeErr))

    if okStore then
        local rel1 = "selftest/persist_smoke.tbl"
        local schema1 = "v0.1"
        local data1 = { ping = "pong" }
        local meta1 = { source = "self_test_runner" }

        do
            local okDel, _, delErr = _callStore(store.delete, rel1)
            if not okDel and not _isMissingFileErr(delErr) then
                -- ignore (best-effort cleanup)
            end
        end

        local okSave, _, saveErr = _callStore(store.saveEnvelope, rel1, schema1, data1, meta1)
        _lineCheck(okSave, "persist saveEnvelope()", "path=" .. rel1 .. (okSave and "" or (" err=" .. tostring(saveErr))))
        check("persist saveEnvelope()", okSave, okSave and ("path=" .. rel1) or ("err=" .. tostring(saveErr)))

        local okLoad, envOrNil, loadErr = _callStore(store.loadEnvelope, rel1)
        local pingOk = (okLoad and type(envOrNil) == "table" and type(envOrNil.data) == "table" and envOrNil.data.ping == "pong")
        _lineCheck(pingOk, "persist loadEnvelope()", pingOk and "ping=pong" or ("err=" .. tostring(loadErr)))
        check("persist loadEnvelope()", pingOk, pingOk and "ping=pong" or ("err=" .. tostring(loadErr)))

        local okDel2, _, delErr2 = _callStore(store.delete, rel1)
        local delPass = okDel2 or _isMissingFileErr(delErr2)
        _lineCheck(delPass, "persist delete()", delPass and ("path=" .. rel1) or ("err=" .. tostring(delErr2)))
        check("persist delete()", delPass, delPass and ("path=" .. rel1) or ("err=" .. tostring(delErr2)))

        -- ScoreStore service-level persistence smoke (SAFE)
        local scoreSvc = nil
        if hasGlobal and type(DW.services) == "table" and type(DW.services.scoreStoreService) == "table" then
            scoreSvc = DW.services.scoreStoreService
        else
            local okReq, mod = _safeRequire("dwkit.services.score_store_service")
            if okReq and type(mod) == "table" then
                scoreSvc = mod
            end
        end

        if type(scoreSvc) == "table" and type(scoreSvc.selfTestPersistenceSmoke) == "function" then
            local okSmoke, smokeErr = scoreSvc.selfTestPersistenceSmoke({
                relPath = "selftest/score_store_service_smoke.tbl",
            })
            _lineCheck(okSmoke, "scoreStore persistence smoke (SAFE)", okSmoke and "OK" or ("err=" .. tostring(smokeErr)))
            check("scoreStore persistence smoke (SAFE)", okSmoke, okSmoke and "OK" or ("err=" .. tostring(smokeErr)))
        else
            _lineCheck(false, "scoreStore persistence smoke (SAFE)", "selfTestPersistenceSmoke() missing")
            check("scoreStore persistence smoke (SAFE)", false, "missing API")
        end
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
    check("bootReady emitted flag known",
        bootReadyKnown,
        "_bootReadyEmitted=" .. tostring(DW and DW._bootReadyEmitted or "nil"))
    _lineCheck(bootReadyKnown,
        "bootReady emitted flag known",
        "_bootReadyEmitted=" .. tostring(DW and DW._bootReadyEmitted or "nil"))

    if hasGlobal then
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
