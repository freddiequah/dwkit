-- #########################################################################
-- Module Name : dwkit.services.command_aliases
-- Owner       : Services
-- Version     : v2026-01-10D
-- Purpose     :
--   - Install SAFE Mudlet aliases for command discovery/help:
--       * dwcommands [safe|game]
--       * dwhelp <cmd>
--       * dwtest [quiet]
--       * dwinfo
--       * dwid
--       * dwversion
--       * dwevents
--       * dwevent <EventName>
--       * dwboot
--       * dwservices
--       * dwpresence
--       * dwactions
--       * dwskills
--       * dwscorestore
--   - Calls into DWKit.cmd (dwkit.bus.command_registry), DWKit.test, runtimeBaseline, identity,
--     event registry surface, and SAFE spine services (presence/action/skills/scoreStore).
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
--   - DWKit.bus.eventBus (attached by loader.init)
--   - DWKit.services.* (presence/actionModel/skillRegistry/scoreStore) (attached by loader.init)
-- #########################################################################

local M = {}

M.VERSION = "v2026-01-10D"

local STATE = {
    installed = false,
    aliasIds = {
        dwcommands   = nil,
        dwhelp       = nil,
        dwtest       = nil,
        dwinfo       = nil,
        dwid         = nil,
        dwversion    = nil,
        dwevents     = nil,
        dwevent      = nil,
        dwboot       = nil,

        dwservices   = nil,
        dwpresence   = nil,
        dwactions    = nil,
        dwskills     = nil,
        dwscorestore = nil,
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

local function _hasEventBus()
    return type(_G.DWKit) == "table"
        and type(_G.DWKit.bus) == "table"
        and type(_G.DWKit.bus.eventBus) == "table"
end

local function _hasServices()
    return type(_G.DWKit) == "table"
        and type(_G.DWKit.services) == "table"
end

local function _getService(name)
    if not _hasServices() then return nil end
    local s = _G.DWKit.services[name]
    if type(s) == "table" then return s end
    return nil
end

local function _sortedKeys(t)
    local keys = {}
    if type(t) ~= "table" then return keys end
    for k, _ in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    return keys
end

local function _isArrayLike(t)
    if type(t) ~= "table" then return false end
    local n = #t
    if n == 0 then return false end
    for i = 1, n do
        if t[i] == nil then return false end
    end
    return true
end

local function _countAnyTable(t)
    if type(t) ~= "table" then return 0 end
    if _isArrayLike(t) then return #t end
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

local function _ppValue(v)
    local tv = type(v)
    if tv == "string" then
        local s = v
        if #s > 120 then s = s:sub(1, 120) .. "..." end
        return string.format("%q", s)
    elseif tv == "number" or tv == "boolean" then
        return tostring(v)
    elseif tv == "nil" then
        return "nil"
    elseif tv == "table" then
        return "{...}"
    else
        return "<" .. tv .. ">"
    end
end

-- Pretty-print (SAFE, bounded output)
local function _ppTable(t, opts)
    opts = opts or {}
    local maxDepth = (type(opts.maxDepth) == "number") and opts.maxDepth or 2
    local maxItems = (type(opts.maxItems) == "number") and opts.maxItems or 30

    local seen = {}

    local function walk(x, depth, prefix)
        if type(x) ~= "table" then
            _out(prefix .. _ppValue(x))
            return
        end
        if seen[x] then
            _out(prefix .. "{<cycle>}")
            return
        end
        seen[x] = true

        local count = _countAnyTable(x)
        _out(prefix .. "{ table, count=" .. tostring(count) .. " }")

        if depth >= maxDepth then
            return
        end

        if _isArrayLike(x) then
            local n = #x
            local limit = math.min(n, maxItems)
            for i = 1, limit do
                local v = x[i]
                if type(v) == "table" then
                    _out(prefix .. "  [" .. tostring(i) .. "] =")
                    walk(v, depth + 1, prefix .. "    ")
                else
                    _out(prefix .. "  [" .. tostring(i) .. "] = " .. _ppValue(v))
                end
            end
            if n > limit then
                _out(prefix .. "  ... (" .. tostring(n - limit) .. " more)")
            end
            return
        end

        local keys = _sortedKeys(x)
        local limit = math.min(#keys, maxItems)
        for i = 1, limit do
            local k = keys[i]
            local v = x[k]
            if type(v) == "table" then
                _out(prefix .. "  " .. tostring(k) .. " =")
                walk(v, depth + 1, prefix .. "    ")
            else
                _out(prefix .. "  " .. tostring(k) .. " = " .. _ppValue(v))
            end
        end
        if #keys > limit then
            _out(prefix .. "  ... (" .. tostring(#keys - limit) .. " more keys)")
        end
    end

    walk(t, 0, "")
end

local function _printIdentity()
    if not _hasIdentity() then
        _err("DWKit.core.identity not available. Run loader.init() first.")
        return
    end

    local I         = DWKit.core.identity
    local idVersion = tostring(I.VERSION or "unknown")
    local pkgId     = tostring(I.packageId or "unknown")
    local evp       = tostring(I.eventPrefix or "unknown")
    local df        = tostring(I.dataFolderName or "unknown")
    local vts       = tostring(I.versionTagStyle or "unknown")

    _out("[DWKit] identity=" ..
        idVersion ..
        " packageId=" .. pkgId .. " eventPrefix=" .. evp .. " dataFolder=" .. df .. " versionTagStyle=" .. vts)
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

    local pkgId     = ident and tostring(ident.packageId or "unknown") or "unknown"
    local evp       = ident and tostring(ident.eventPrefix or "unknown") or "unknown"
    local df        = ident and tostring(ident.dataFolderName or "unknown") or "unknown"
    local vts       = ident and tostring(ident.versionTagStyle or "unknown") or "unknown"

    local luaV      = "unknown"
    local mudletV   = "unknown"
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

local function _yn(b) return b and "OK" or "MISSING" end

local function _printBootHealth()
    _out("[DWKit Boot] Health summary (dwboot)")
    _out("")

    if type(_G.DWKit) ~= "table" then
        _out("  DWKit global                : MISSING")
        _out("")
        _out("  Next step:")
        _out("    - Run: lua local L=require(\"dwkit.loader.init\"); L.init()")
        return
    end

    local kit = _G.DWKit

    local hasCore = (type(kit.core) == "table")
    local hasBus = (type(kit.bus) == "table")
    local hasServices = (type(kit.services) == "table")

    local hasIdentity = hasCore and (type(kit.core.identity) == "table")
    local hasRB = hasCore and (type(kit.core.runtimeBaseline) == "table")
    local hasCmd = (type(kit.cmd) == "table")
    local hasCmdReg = hasBus and (type(kit.bus.commandRegistry) == "table")
    local hasEvReg = hasBus and (type(kit.bus.eventRegistry) == "table")
    local hasEvBus = hasBus and (type(kit.bus.eventBus) == "table")
    local hasTest = (type(kit.test) == "table") and (type(kit.test.run) == "function")
    local hasAliases = hasServices and (type(kit.services.commandAliases) == "table")

    _out("  DWKit global                : OK")
    _out("  core.identity               : " .. _yn(hasIdentity))
    _out("  core.runtimeBaseline        : " .. _yn(hasRB))
    _out("  cmd (runtime surface)       : " .. _yn(hasCmd))
    _out("  bus.commandRegistry         : " .. _yn(hasCmdReg))
    _out("  bus.eventRegistry           : " .. _yn(hasEvReg))
    _out("  bus.eventBus                : " .. _yn(hasEvBus))
    _out("  test.run                    : " .. _yn(hasTest))
    _out("  services.commandAliases     : " .. _yn(hasAliases))
    _out("")

    local initTs = kit._lastInitTs
    if type(initTs) == "number" then
        _out("  lastInitTs                  : " .. tostring(initTs))
    else
        _out("  lastInitTs                  : (unknown)")
    end

    local br = kit._bootReadyEmitted
    _out("  bootReadyEmitted            : " .. tostring(br == true))
    if type(kit._bootReadyTs) == "number" then
        _out("  bootReadyTs                 : " .. tostring(kit._bootReadyTs))
    end
    if kit._bootReadyEmitError then
        _out("  bootReadyEmitError          : " .. tostring(kit._bootReadyEmitError))
    end

    _out("")
    _out("  load errors (if any):")
    local anyErr = false

    local function showErr(key, val)
        if val ~= nil and tostring(val) ~= "" then
            anyErr = true
            _out("    - " .. key .. " = " .. tostring(val))
        end
    end

    showErr("_cmdRegistryLoadError", kit._cmdRegistryLoadError)
    showErr("_eventRegistryLoadError", kit._eventRegistryLoadError)
    showErr("_eventBusLoadError", kit._eventBusLoadError)
    showErr("_commandAliasesLoadError", kit._commandAliasesLoadError)

    showErr("_presenceServiceLoadError", kit._presenceServiceLoadError)
    showErr("_actionModelServiceLoadError", kit._actionModelServiceLoadError)
    showErr("_skillRegistryServiceLoadError", kit._skillRegistryServiceLoadError)
    showErr("_scoreStoreServiceLoadError", kit._scoreStoreServiceLoadError)

    if type(kit.test) == "table" then
        showErr("test._selfTestLoadError", kit.test._selfTestLoadError)
    end

    if not anyErr then
        _out("    (none)")
    end

    if hasEvBus and type(kit.bus.eventBus.getStats) == "function" then
        local okS, stats = pcall(kit.bus.eventBus.getStats)
        if okS and type(stats) == "table" then
            _out("")
            _out("  eventBus stats:")
            _out("    version      : " .. tostring(stats.version or "unknown"))
            _out("    subscribers  : " .. tostring(stats.subscribers or 0))
            _out("    emitted      : " .. tostring(stats.emitted or 0))
            _out("    delivered    : " .. tostring(stats.delivered or 0))
            _out("    handlerErrors: " .. tostring(stats.handlerErrors or 0))
        end
    end

    _out("")
    _out("  Tip: if anything is MISSING, run:")
    _out("    lua local L=require(\"dwkit.loader.init\"); L.init()")
end

local function _printServicesHealth()
    _out("[DWKit Services] Health summary (dwservices)")
    _out("")

    if type(_G.DWKit) ~= "table" then
        _out("  DWKit global: MISSING")
        _out("  Next step: lua local L=require(\"dwkit.loader.init\"); L.init()")
        return
    end

    local kit = _G.DWKit
    if type(kit.services) ~= "table" then
        _out("  DWKit.services: MISSING")
        return
    end

    local function showSvc(fieldName, errKey)
        local svc = kit.services[fieldName]
        local ok = (type(svc) == "table")
        local v = ok and tostring(svc.VERSION or "unknown") or "unknown"
        _out("  " .. fieldName .. " : " .. (ok and "OK" or "MISSING") .. "  version=" .. v)

        local errVal = kit[errKey]
        if errVal ~= nil and tostring(errVal) ~= "" then
            _out("    loadError: " .. tostring(errVal))
        end
    end

    showSvc("presenceService", "_presenceServiceLoadError")
    showSvc("actionModelService", "_actionModelServiceLoadError")
    showSvc("skillRegistryService", "_skillRegistryServiceLoadError")
    showSvc("scoreStoreService", "_scoreStoreServiceLoadError")
end

local function _printServiceSnapshot(label, svcName)
    _out("[DWKit Service] " .. tostring(label))
    local svc = _getService(svcName)
    if not svc then
        _err("DWKit.services." .. tostring(svcName) .. " not available. Run loader.init() first.")
        return
    end

    _out("  version=" .. tostring(svc.VERSION or "unknown"))

    -- Best-effort snapshot: prefer getState(), else getAll(), else dump keys
    if type(svc.getState) == "function" then
        local ok, state = pcall(svc.getState)
        if ok then
            _out("  getState(): OK")
            _ppTable(state, { maxDepth = 2, maxItems = 30 })
            return
        end
        _out("  getState(): ERROR")
    end

    if type(svc.getAll) == "function" then
        local ok, state = pcall(svc.getAll)
        if ok then
            _out("  getAll(): OK")
            _ppTable(state, { maxDepth = 2, maxItems = 30 })
            return
        end
        _out("  getAll(): ERROR")
    end

    local keys = _sortedKeys(svc)
    _out("  APIs available (keys on service table): count=" .. tostring(#keys))
    local limit = math.min(#keys, 40)
    for i = 1, limit do
        _out("    - " .. tostring(keys[i]))
    end
    if #keys > limit then
        _out("    ... (" .. tostring(#keys - limit) .. " more)")
    end
end

local function _getScoreStoreServiceBestEffort()
    local svc = _getService("scoreStoreService")
    if type(svc) == "table" then return svc end
    local ok, mod = _safeRequire("dwkit.services.score_store_service")
    if ok and type(mod) == "table" then return mod end
    return nil
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
            dwboot = STATE.aliasIds.dwboot,

            dwservices = STATE.aliasIds.dwservices,
            dwpresence = STATE.aliasIds.dwpresence,
            dwactions = STATE.aliasIds.dwactions,
            dwskills = STATE.aliasIds.dwskills,
            dwscorestore = STATE.aliasIds.dwscorestore,
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

    local ids = STATE.aliasIds
    local allIds = {
        ids.dwcommands, ids.dwhelp, ids.dwtest, ids.dwinfo, ids.dwid, ids.dwversion,
        ids.dwevents, ids.dwevent, ids.dwboot,
        ids.dwservices, ids.dwpresence, ids.dwactions, ids.dwskills, ids.dwscorestore,
    }

    local allOk = true
    for _, id in ipairs(allIds) do
        if id then
            local ok = pcall(killAlias, id)
            if not ok then allOk = false end
        end
    end

    for k, _ in pairs(STATE.aliasIds) do
        STATE.aliasIds[k] = nil
    end

    STATE.installed = false

    if not allOk then
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

    -- Alias 3: dwtest [quiet]
    local dwtestPattern = [[^dwtest(?:\s+(quiet))?\s*$]]
    local id3 = tempAlias(dwtestPattern, function()
        if not _hasTest() then
            _err("DWKit.test.run not available. Run loader.init() first.")
            return
        end
        local mode = (matches and matches[2]) and tostring(matches[2]) or ""
        if mode == "quiet" then
            DWKit.test.run({ quiet = true })
        else
            DWKit.test.run()
        end
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

    -- Alias 9: dwboot
    local dwbootPattern = [[^dwboot\s*$]]
    local id9 = tempAlias(dwbootPattern, function()
        _printBootHealth()
    end)

    -- Alias 10: dwservices
    local dwservicesPattern = [[^dwservices\s*$]]
    local id10 = tempAlias(dwservicesPattern, function()
        _printServicesHealth()
    end)

    -- Alias 11: dwpresence
    local dwpresencePattern = [[^dwpresence\s*$]]
    local id11 = tempAlias(dwpresencePattern, function()
        _printServiceSnapshot("PresenceService", "presenceService")
    end)

    -- Alias 12: dwactions
    local dwactionsPattern = [[^dwactions\s*$]]
    local id12 = tempAlias(dwactionsPattern, function()
        _printServiceSnapshot("ActionModelService", "actionModelService")
    end)

    -- Alias 13: dwskills
    local dwskillsPattern = [[^dwskills\s*$]]
    local id13 = tempAlias(dwskillsPattern, function()
        _printServiceSnapshot("SkillRegistryService", "skillRegistryService")
    end)

    -- Alias 14: dwscorestore
    local dwscorestorePattern = [[^dwscorestore\s*$]]
    local id14 = tempAlias(dwscorestorePattern, function()
        local svc = _getScoreStoreServiceBestEffort()
        if type(svc) ~= "table" then
            _err("ScoreStoreService not available. Run loader.init() first.")
            return
        end
        if type(svc.printSummary) ~= "function" then
            _err("ScoreStoreService.printSummary not available.")
            return
        end
        local ok = pcall(svc.printSummary)
        if not ok then
            _err("ScoreStoreService.printSummary failed (see console/log).")
        end
    end)

    local all = { id1, id2, id3, id4, id5, id6, id7, id8, id9, id10, id11, id12, id13, id14 }
    for _, id in ipairs(all) do
        if not id then
            STATE.lastError = "Failed to create one or more aliases"
            if type(killAlias) == "function" then
                for _, xid in ipairs(all) do
                    if xid then pcall(killAlias, xid) end
                end
            end
            return false, STATE.lastError
        end
    end

    STATE.aliasIds.dwcommands   = id1
    STATE.aliasIds.dwhelp       = id2
    STATE.aliasIds.dwtest       = id3
    STATE.aliasIds.dwinfo       = id4
    STATE.aliasIds.dwid         = id5
    STATE.aliasIds.dwversion    = id6
    STATE.aliasIds.dwevents     = id7
    STATE.aliasIds.dwevent      = id8
    STATE.aliasIds.dwboot       = id9

    STATE.aliasIds.dwservices   = id10
    STATE.aliasIds.dwpresence   = id11
    STATE.aliasIds.dwactions    = id12
    STATE.aliasIds.dwskills     = id13
    STATE.aliasIds.dwscorestore = id14

    STATE.installed             = true
    STATE.lastError             = nil

    if not opts.quiet then
        _out(
            "[DWKit Alias] Installed: dwcommands, dwhelp, dwtest, dwinfo, dwid, dwversion, dwevents, dwevent, dwboot, dwservices, dwpresence, dwactions, dwskills, dwscorestore")
    end

    return true, nil
end

return M
