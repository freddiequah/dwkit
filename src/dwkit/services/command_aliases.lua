-- #########################################################################
-- Module Name : dwkit.services.command_aliases
-- Owner       : Services
-- Version     : v2026-01-06F
-- Purpose     :
--   - Install SAFE Mudlet aliases for command discovery/help:
--       * dwcommands [safe|game]
--       * dwhelp <cmd>
--       * dwtest
--       * dwinfo
--       * dwid
--       * dwversion
--       * dwevents
--       * dwevent <EventName>
--   - Calls into DWKit.cmd (dwkit.bus.command_registry), DWKit.test, runtimeBaseline, identity,
--     and event registry surface.
--   - DOES NOT send gameplay commands.
--   - DOES NOT start timers or automation.
--
-- Public API  :
--   - install(opts?) -> boolean ok, string|nil err
--   - uninstall() -> boolean ok, string|nil err
--   - isInstalled() -> boolean
--   - getState() -> table copy
--
-- Events Emitted   : None
-- Events Consumed  : None
-- Persistence      : None
-- Automation Policy: Manual only (invoked by loader.init which is manual)
-- Dependencies     :
--   - Mudlet: tempAlias(), killAlias() (optional but expected)
--   - DWKit.cmd (attached by loader.init)
--   - DWKit.test (attached by loader.init)
--   - DWKit.core.runtimeBaseline (attached by loader.init)
--   - DWKit.core.identity (attached by loader.init)
--   - DWKit.bus.eventRegistry (attached by loader.init)
-- #########################################################################

local M = {}

M.VERSION = "v2026-01-06F"

local STATE = {
    installed = false,
    aliasIds = {
        dwcommands = nil,
        dwhelp = nil,
        dwtest = nil,
        dwinfo = nil,
        dwid = nil,
        dwversion = nil,
        dwevents = nil,
        dwevent = nil,
    },
    lastError = nil,
}

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

local function _err(msg)
    _out("[DWKit Alias] ERROR: " .. tostring(msg))
end

local function _safeRequire(modName)
    local ok, mod = pcall(require, modName)
    if ok then return true, mod end
    return false, mod
end

local function _hasCmd()
    return type(_G.DWKit) == "table" and type(_G.DWKit.cmd) == "table"
end

local function _hasTest()
    return type(_G.DWKit) == "table"
        and type(_G.DWKit.test) == "table"
        and type(_G.DWKit.test.run) == "function"
end

local function _hasBaseline()
    return type(_G.DWKit) == "table"
        and type(_G.DWKit.core) == "table"
        and type(_G.DWKit.core.runtimeBaseline) == "table"
        and type(_G.DWKit.core.runtimeBaseline.printInfo) == "function"
end

local function _hasIdentity()
    return type(_G.DWKit) == "table"
        and type(_G.DWKit.core) == "table"
        and type(_G.DWKit.core.identity) == "table"
end

local function _hasEventRegistry()
    return type(_G.DWKit) == "table"
        and type(_G.DWKit.bus) == "table"
        and type(_G.DWKit.bus.eventRegistry) == "table"
        and type(_G.DWKit.bus.eventRegistry.listAll) == "function"
end

local function _printIdentity()
    if not _hasIdentity() then
        _err("DWKit.core.identity not available. Run loader.init() first.")
        return
    end

    local I = DWKit.core.identity
    local idVersion = tostring(I.VERSION or "unknown")
    local pkgId = tostring(I.packageId or "unknown")
    local evp  = tostring(I.eventPrefix or "unknown")
    local df   = tostring(I.dataFolderName or "unknown")
    local vts  = tostring(I.versionTagStyle or "unknown")

    _out("[DWKit] identity=" .. idVersion .. " packageId=" .. pkgId .. " eventPrefix=" .. evp .. " dataFolder=" .. df .. " versionTagStyle=" .. vts)
end

local function _printVersionSummary()
    if type(_G.DWKit) ~= "table" then
        _err("DWKit global not available. Run loader.init() first.")
        return
    end

    -- Identity
    local ident = nil
    if _hasIdentity() then
        ident = DWKit.core.identity
    else
        local okI, modI = _safeRequire("dwkit.core.identity")
        if okI and type(modI) == "table" then ident = modI end
    end

    -- Runtime baseline module (for VERSION + baseline getInfo)
    local rb = nil
    if type(DWKit.core) == "table" and type(DWKit.core.runtimeBaseline) == "table" then
        rb = DWKit.core.runtimeBaseline
    else
        local okRB, modRB = _safeRequire("dwkit.core.runtime_baseline")
        if okRB and type(modRB) == "table" then rb = modRB end
    end

    -- Command registry version
    local cmdRegVersion = "unknown"
    if _hasCmd() and type(DWKit.cmd.getRegistryVersion) == "function" then
        local okV, v = pcall(DWKit.cmd.getRegistryVersion)
        if okV and v then cmdRegVersion = tostring(v) end
    end

    -- Event registry + bus versions (SAFE diagnostics)
    local evRegVersion = "unknown"
    if type(DWKit.bus) == "table" and type(DWKit.bus.eventRegistry) == "table" and type(DWKit.bus.eventRegistry.getRegistryVersion) == "function" then
        local okE, v = pcall(DWKit.bus.eventRegistry.getRegistryVersion)
        if okE and v then evRegVersion = tostring(v) end
    else
        local okER, modER = _safeRequire("dwkit.bus.event_registry")
        if okER and type(modER) == "table" then
            evRegVersion = tostring(modER.getRegistryVersion and modER.getRegistryVersion() or modER.VERSION or "unknown")
        end
    end

    local evBusVersion = "unknown"
    local okEB, modEB = _safeRequire("dwkit.bus.event_bus")
    if okEB and type(modEB) == "table" then
        evBusVersion = tostring(modEB.VERSION or "unknown")
    end

    -- Self-test runner version (module constant, does NOT run tests)
    local stVersion = "unknown"
    local okST, st = _safeRequire("dwkit.tests.self_test_runner")
    if okST and type(st) == "table" then
        stVersion = tostring(st.VERSION or "unknown")
    end

    local idVersion = ident and tostring(ident.VERSION or "unknown") or "unknown"
    local rbVersion = rb and tostring(rb.VERSION or "unknown") or "unknown"

    local pkgId = ident and tostring(ident.packageId or "unknown") or "unknown"
    local evp  = ident and tostring(ident.eventPrefix or "unknown") or "unknown"
    local df   = ident and tostring(ident.dataFolderName or "unknown") or "unknown"
    local vts  = ident and tostring(ident.versionTagStyle or "unknown") or "unknown"

    local luaV = "unknown"
    local mudletV = "unknown"
    if rb and type(rb.getInfo) == "function" then
        local okInfo, info = pcall(rb.getInfo)
        if okInfo and type(info) == "table" then
            luaV = tostring(info.luaVersion or "unknown")
            mudletV = tostring(info.mudletVersion or "unknown")
        end
    end

    _out("[DWKit] Version summary:")
    _out("  identity        = " .. idVersion)
    _out("  runtimeBaseline = " .. rbVersion)
    _out("  selfTestRunner  = " .. stVersion)
    _out("  commandRegistry = " .. cmdRegVersion)
    _out("  eventRegistry   = " .. evRegVersion)
    _out("  eventBus        = " .. evBusVersion)
    _out("  commandAliases  = " .. tostring(M.VERSION or "unknown"))
    _out("")
    _out("[DWKit] Identity (locked):")
    _out("  packageId=" .. pkgId .. " eventPrefix=" .. evp .. " dataFolder=" .. df .. " versionTagStyle=" .. vts)
    _out("[DWKit] Runtime baseline:")
    _out("  lua=" .. luaV .. " mudlet=" .. mudletV)
end

function M.isInstalled()
    return STATE.installed and true or false
end

function M.getState()
    return {
        installed = STATE.installed and true or false,
        aliasIds = {
            dwcommands = STATE.aliasIds.dwcommands,
            dwhelp = STATE.aliasIds.dwhelp,
            dwtest = STATE.aliasIds.dwtest,
            dwinfo = STATE.aliasIds.dwinfo,
            dwid = STATE.aliasIds.dwid,
            dwversion = STATE.aliasIds.dwversion,
            dwevents = STATE.aliasIds.dwevents,
            dwevent = STATE.aliasIds.dwevent,
        },
        lastError = STATE.lastError,
    }
end

function M.uninstall()
    if not STATE.installed then
        return true, nil
    end

    if type(killAlias) ~= "function" then
        STATE.lastError = "killAlias() not available"
        return false, STATE.lastError
    end

    local ok1, ok2, ok3, ok4, ok5, ok6, ok7, ok8 = true, true, true, true, true, true, true, true

    if STATE.aliasIds.dwcommands then
        ok1 = pcall(killAlias, STATE.aliasIds.dwcommands)
        STATE.aliasIds.dwcommands = nil
    end

    if STATE.aliasIds.dwhelp then
        ok2 = pcall(killAlias, STATE.aliasIds.dwhelp)
        STATE.aliasIds.dwhelp = nil
    end

    if STATE.aliasIds.dwtest then
        ok3 = pcall(killAlias, STATE.aliasIds.dwtest)
        STATE.aliasIds.dwtest = nil
    end

    if STATE.aliasIds.dwinfo then
        ok4 = pcall(killAlias, STATE.aliasIds.dwinfo)
        STATE.aliasIds.dwinfo = nil
    end

    if STATE.aliasIds.dwid then
        ok5 = pcall(killAlias, STATE.aliasIds.dwid)
        STATE.aliasIds.dwid = nil
    end

    if STATE.aliasIds.dwversion then
        ok6 = pcall(killAlias, STATE.aliasIds.dwversion)
        STATE.aliasIds.dwversion = nil
    end

    if STATE.aliasIds.dwevents then
        ok7 = pcall(killAlias, STATE.aliasIds.dwevents)
        STATE.aliasIds.dwevents = nil
    end

    if STATE.aliasIds.dwevent then
        ok8 = pcall(killAlias, STATE.aliasIds.dwevent)
        STATE.aliasIds.dwevent = nil
    end

    STATE.installed = false

    if not ok1 or not ok2 or not ok3 or not ok4 or not ok5 or not ok6 or not ok7 or not ok8 then
        STATE.lastError = "One or more aliases failed to uninstall"
        return false, STATE.lastError
    end

    STATE.lastError = nil
    return true, nil
end

function M.install(opts)
    opts = opts or {}

    if STATE.installed then
        return true, nil
    end

    if type(tempAlias) ~= "function" then
        STATE.lastError = "tempAlias() not available"
        return false, STATE.lastError
    end

    -- Alias 1: dwcommands [safe|game]
    local dwcommandsPattern = [[^dwcommands(?:\s+(safe|game))?\s*$]]
    local id1 = tempAlias(dwcommandsPattern, function()
        if not _hasCmd() then
            _err("DWKit.cmd not available. Run loader.init() first.")
            return
        end

        local mode = (matches and matches[2]) and tostring(matches[2]) or ""
        if mode == "safe" then
            DWKit.cmd.listSafe()
        elseif mode == "game" then
            DWKit.cmd.listGame()
        else
            DWKit.cmd.listAll()
        end
    end)

    -- Alias 2: dwhelp <cmd>
    local dwhelpPattern = [[^dwhelp\s+(\S+)\s*$]]
    local id2 = tempAlias(dwhelpPattern, function()
        if not _hasCmd() then
            _err("DWKit.cmd not available. Run loader.init() first.")
            return
        end

        local name = (matches and matches[2]) and tostring(matches[2]) or ""
        if name == "" then
            _err("Usage: dwhelp <cmd>")
            return
        end

        local ok, _, err = DWKit.cmd.help(name)
        if not ok then
            _err(err or ("Unknown command: " .. name))
        end
    end)

    -- Alias 3: dwtest
    local dwtestPattern = [[^dwtest\s*$]]
    local id3 = tempAlias(dwtestPattern, function()
        if not _hasTest() then
            _err("DWKit.test.run not available. Run loader.init() first.")
            return
        end
        DWKit.test.run()
    end)

    -- Alias 4: dwinfo
    local dwinfoPattern = [[^dwinfo\s*$]]
    local id4 = tempAlias(dwinfoPattern, function()
        if not _hasBaseline() then
            _err("DWKit.core.runtimeBaseline.printInfo not available. Run loader.init() first.")
            return
        end
        DWKit.core.runtimeBaseline.printInfo()
    end)

    -- Alias 5: dwid
    local dwidPattern = [[^dwid\s*$]]
    local id5 = tempAlias(dwidPattern, function()
        _printIdentity()
    end)

    -- Alias 6: dwversion
    local dwversionPattern = [[^dwversion\s*$]]
    local id6 = tempAlias(dwversionPattern, function()
        _printVersionSummary()
    end)

    -- Alias 7: dwevents
    local dweventsPattern = [[^dwevents\s*$]]
    local id7 = tempAlias(dweventsPattern, function()
        if not _hasEventRegistry() then
            _err("DWKit.bus.eventRegistry not available. Run loader.init() first.")
            return
        end
        DWKit.bus.eventRegistry.listAll()
    end)

    -- Alias 8: dwevent <EventName>
    local dweventPattern = [[^dwevent\s+(\S+)\s*$]]
    local id8 = tempAlias(dweventPattern, function()
        if not _hasEventRegistry() then
            _err("DWKit.bus.eventRegistry not available. Run loader.init() first.")
            return
        end

        local evName = (matches and matches[2]) and tostring(matches[2]) or ""
        if evName == "" then
            _err("Usage: dwevent <EventName>")
            return
        end

        local ok, _, err = DWKit.bus.eventRegistry.help(evName)
        if not ok then
            _err(err or ("Unknown event: " .. evName))
        end
    end)

    if not id1 or not id2 or not id3 or not id4 or not id5 or not id6 or not id7 or not id8 then
        STATE.lastError = "Failed to create one or more aliases"
        if type(killAlias) == "function" then
            if id1 then pcall(killAlias, id1) end
            if id2 then pcall(killAlias, id2) end
            if id3 then pcall(killAlias, id3) end
            if id4 then pcall(killAlias, id4) end
            if id5 then pcall(killAlias, id5) end
            if id6 then pcall(killAlias, id6) end
            if id7 then pcall(killAlias, id7) end
            if id8 then pcall(killAlias, id8) end
        end
        return false, STATE.lastError
    end

    STATE.aliasIds.dwcommands = id1
    STATE.aliasIds.dwhelp = id2
    STATE.aliasIds.dwtest = id3
    STATE.aliasIds.dwinfo = id4
    STATE.aliasIds.dwid = id5
    STATE.aliasIds.dwversion = id6
    STATE.aliasIds.dwevents = id7
    STATE.aliasIds.dwevent = id8
    STATE.installed = true
    STATE.lastError = nil

    if not opts.quiet then
        _out("[DWKit Alias] Installed: dwcommands, dwhelp, dwtest, dwinfo, dwid, dwversion, dwevents, dwevent")
    end

    return true, nil
end

return M
