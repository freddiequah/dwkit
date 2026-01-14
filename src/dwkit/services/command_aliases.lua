-- #########################################################################
-- Module Name : dwkit.services.command_aliases
-- Owner       : Services
-- Version     : v2026-01-14F
-- Purpose     :
--   - Install SAFE Mudlet aliases for command discovery/help:
--       * dwcommands [safe|game|md]
--       * dwhelp <cmd>
--       * dwtest [quiet]
--       * dwinfo
--       * dwid
--       * dwversion
--       * dwdiag
--       * dwevents [md]
--       * dwevent <EventName>
--       * dwboot
--       * dwservices
--       * dwpresence
--       * dwactions
--       * dwskills
--       * dwscorestore [status|persist <on|off|status>|fixture [basic]|clear|wipe [disk]|reset [disk]]
--       * dweventtap [on|off|status|show|clear] [n]
--       * dweventsub <EventName>
--       * dweventunsub <EventName|all>
--       * dweventlog [n]
--       * dwrelease
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
-- #########################################################################

local M = {}

M.VERSION = "v2026-01-14F"

local STATE = {
    installed = false,
    aliasIds = {
        dwcommands   = nil,
        dwhelp       = nil,
        dwtest       = nil,
        dwinfo       = nil,
        dwid         = nil,
        dwversion    = nil,
        dwdiag       = nil,
        dwevents     = nil,
        dwevent      = nil,
        dwboot       = nil,

        dwservices   = nil,
        dwpresence   = nil,
        dwactions    = nil,
        dwskills     = nil,
        dwscorestore = nil,

        dweventtap   = nil,
        dweventsub   = nil,
        dweventunsub = nil,
        dweventlog   = nil,

        dwrelease    = nil,
    },
    lastError = nil,

    -- Event diagnostics harness (SAFE; manual)
    eventDiag = {
        maxLog = 50,
        log = {},       -- ring buffer (simple trim)
        tapToken = nil, -- token from eventBus.tapOn
        subs = {},      -- eventName -> token (from eventBus.on)
    },
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

-- NEW: robust caller for APIs that may be implemented as obj.fn(...) OR obj:fn(...)
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
    if _hasCmd() then
        local okV, v = _callBestEffort(DWKit.cmd, "getRegistryVersion")
        if okV and v then
            cmdRegVersion = tostring(v)
        end
    end

    -- Event registry + bus versions (SAFE diagnostics)
    local evRegVersion = "unknown"
    if type(DWKit.bus) == "table" and type(DWKit.bus.eventRegistry) == "table" then
        local okE, v = _callBestEffort(DWKit.bus.eventRegistry, "getRegistryVersion")
        if okE and v then evRegVersion = tostring(v) end
    else
        local okER, modER = _safeRequire("dwkit.bus.event_registry")
        if okER and type(modER) == "table" then
            local okV, v = pcall(function()
                if type(modER.getRegistryVersion) == "function" then
                    return modER.getRegistryVersion()
                end
                return modER.VERSION
            end)
            if okV and v then evRegVersion = tostring(v) else evRegVersion = "unknown" end
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

        local okD, s = pcall(os.date, "%Y-%m-%d %H:%M:%S", kit._bootReadyTs)
        if okD and s then
            _out("  bootReadyLocal              : " .. tostring(s))
        else
            _out("  bootReadyLocal              : (unavailable)")
        end
    end

    if type(kit._bootReadyTsMs) == "number" then
        _out("  bootReadyTsMs               : " .. tostring(kit._bootReadyTsMs))
    else
        _out("  bootReadyTsMs               : (unknown)")
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

    if type(kit.bus) == "table" and type(kit.bus.eventBus) == "table" and type(kit.bus.eventBus.getStats) == "function" then
        local okS, stats = pcall(kit.bus.eventBus.getStats)
        if okS and type(stats) == "table" then
            _out("")
            _out("  eventBus stats:")
            _out("    version          : " .. tostring(stats.version or "unknown"))
            _out("    subscribers      : " .. tostring(stats.subscribers or 0))
            _out("    tapSubscribers   : " .. tostring(stats.tapSubscribers or 0))
            _out("    emitted          : " .. tostring(stats.emitted or 0))
            _out("    delivered        : " .. tostring(stats.delivered or 0))
            _out("    handlerErrors    : " .. tostring(stats.handlerErrors or 0))
            _out("    tapErrors        : " .. tostring(stats.tapErrors or 0))
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

    if type(svc.getState) == "function" then
        local ok, state, _, _, err = _callBestEffort(svc, "getState")
        if ok then
            _out("  getState(): OK")
            _ppTable(state, { maxDepth = 2, maxItems = 30 })
            return
        end
        _out("  getState(): ERROR")
        if err and err ~= "" then _out("    err=" .. tostring(err)) end
    end

    if type(svc.getAll) == "function" then
        local ok, state, _, _, err = _callBestEffort(svc, "getAll")
        if ok then
            _out("  getAll(): OK")
            _ppTable(state, { maxDepth = 2, maxItems = 30 })
            return
        end
        _out("  getAll(): ERROR")
        if err and err ~= "" then _out("    err=" .. tostring(err)) end
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

-- -------------------------
-- Release checklist (SAFE, bounded)
-- -------------------------
local function _printReleaseChecklist()
    _out("[DWKit Release] checklist (dwrelease)")
    _out("  NOTE: SAFE + manual-only. This does not run git/gh commands.")
    _out("")

    _out("== versions (best-effort) ==")
    _out("")
    _printVersionSummary()
    _out("")

    _out("== PR workflow (PowerShell + gh) ==")
    _out("")
    _out("  1) Start clean:")
    _out("     - git checkout main")
    _out("     - git pull")
    _out("     - git status -sb")
    _out("")
    _out("  2) Create topic branch:")
    _out("     - git checkout -b <topic/name>")
    _out("")
    _out("  3) Commit changes (scope small):")
    _out("     - git status")
    _out("     - git add <paths...>")
    _out("     - git commit -m \"<message>\"")
    _out("")
    _out("  4) Push branch:")
    _out("     - git push --set-upstream origin <topic/name>")
    _out("")
    _out("  5) Create PR:")
    _out("     - gh pr create --base main --head <topic/name> --title \"<title>\" --body \"<body>\"")
    _out("")
    _out("  6) Review + merge (preferred: squash + delete branch):")
    _out("     - gh pr status")
    _out("     - gh pr view")
    _out("     - gh pr diff")
    _out("     - gh pr checks    (if configured)")
    _out("     - gh pr merge <PR_NUMBER> --squash --delete-branch")
    _out("")
    _out("  7) Sync local main AFTER merge:")
    _out("     - git checkout main")
    _out("     - git pull")
    _out("     - git log -1 --oneline --decorate")
    _out("")

    _out("== release tagging discipline (annotated tag on main HEAD) ==")
    _out("")
    _out("  1) Verify main HEAD is correct:")
    _out("     - git checkout main")
    _out("     - git pull")
    _out("     - git log -1 --oneline --decorate")
    _out("")
    _out("  2) Create annotated tag (after merge):")
    _out("     - git tag -a vYYYY-MM-DDX -m \"<tag message>\"")
    _out("     - git push origin vYYYY-MM-DDX")
    _out("")
    _out("  3) Verify tag targets origin/main:")
    _out("     - git rev-parse --verify origin/main")
    _out("     - git rev-parse --verify 'vYYYY-MM-DDX^{}'")
    _out("     - (expected: hashes match)")
    _out("")
    _out("  4) If you tagged wrong commit (fix safely):")
    _out("     - git tag -d vYYYY-MM-DDX")
    _out("     - git push origin :refs/tags/vYYYY-MM-DDX")
    _out("     - (then recreate on correct main HEAD)")
end

-- -------------------------
-- Event diagnostics harness (SAFE)
-- -------------------------
local function _diag()
    return STATE.eventDiag
end

local function _pushEventLog(kind, eventName, payload)
    local d = _diag()
    local rec = {
        ts = os.time(),
        kind = tostring(kind or "unknown"),
        event = tostring(eventName or "unknown"),
        payload = payload,
    }
    d.log[#d.log + 1] = rec

    local maxLog = (type(d.maxLog) == "number" and d.maxLog > 0) and d.maxLog or 50
    while #d.log > maxLog do
        table.remove(d.log, 1)
    end
end

local function _normalizeTapArgs(a, b)
    if type(a) == "string" and type(b) == "table" then
        return b, a
    end
    return a, b
end

local function _printEventDiagStatus()
    if not _hasEventBus() then
        _err("DWKit.bus.eventBus not available. Run loader.init() first.")
        return
    end

    local d = _diag()
    local tapOn = (d.tapToken ~= nil)
    local subCount = 0
    for _ in pairs(d.subs) do subCount = subCount + 1 end

    local stats = {}
    if type(DWKit.bus.eventBus.getStats) == "function" then
        local okS, s = pcall(DWKit.bus.eventBus.getStats)
        if okS and type(s) == "table" then stats = s end
    end

    _out("[DWKit EventDiag] status")
    _out("  tapEnabled     : " .. tostring(tapOn))
    _out("  tapToken       : " .. tostring(d.tapToken))
    _out("  subsCount      : " .. tostring(subCount))
    _out("  logCount       : " .. tostring(#d.log))
    _out("  maxLog         : " .. tostring(d.maxLog))
    _out("  eventBus.version       : " .. tostring(stats.version or "unknown"))
    _out("  eventBus.emitted       : " .. tostring(stats.emitted or 0))
    _out("  eventBus.delivered     : " .. tostring(stats.delivered or 0))
    _out("  eventBus.handlerErrors : " .. tostring(stats.handlerErrors or 0))
    _out("  eventBus.tapSubscribers: " .. tostring(stats.tapSubscribers or 0))
    _out("  eventBus.tapErrors     : " .. tostring(stats.tapErrors or 0))
end

local function _printEventLog(n)
    local d = _diag()
    local total = #d.log
    if total == 0 then
        _out("[DWKit EventDiag] log is empty")
        return
    end

    local limit = tonumber(n or "") or 10
    if limit < 1 then limit = 10 end
    if limit > 50 then limit = 50 end

    local start = math.max(1, total - limit + 1)

    _out("[DWKit EventDiag] last " .. tostring(total - start + 1) .. " events (most recent last)")
    for i = start, total do
        local rec = d.log[i]
        _out("")
        _out("  [" ..
            tostring(i) ..
            "] ts=" .. tostring(rec.ts) .. " kind=" .. tostring(rec.kind) .. " event=" .. tostring(rec.event))
        if type(rec.payload) == "table" then
            _out("    payload=")
            _ppTable(rec.payload, { maxDepth = 2, maxItems = 25 })
        else
            _out("    payload=" .. _ppValue(rec.payload))
        end
    end
end

local function _tapOn()
    if not _hasEventBus() then
        _err("DWKit.bus.eventBus not available. Run loader.init() first.")
        return
    end
    local d = _diag()
    if d.tapToken ~= nil then
        _out("[DWKit EventDiag] tap already enabled token=" .. tostring(d.tapToken))
        return
    end

    if type(DWKit.bus.eventBus.tapOn) ~= "function" then
        _err("eventBus.tapOn not available. Update dwkit.bus.event_bus first.")
        return
    end

    local okCall, ok, token, err = pcall(DWKit.bus.eventBus.tapOn, function(a, b)
        local payload, eventName = _normalizeTapArgs(a, b)
        _pushEventLog("tap", eventName, payload)
    end)

    if not okCall then
        _err("tapOn threw error: " .. tostring(ok))
        return
    end
    if not ok then
        _err(err or "tapOn failed")
        return
    end

    d.tapToken = token
    _out("[DWKit EventDiag] tap enabled token=" .. tostring(token))
end

local function _tapOff()
    if not _hasEventBus() then
        _err("DWKit.bus.eventBus not available. Run loader.init() first.")
        return
    end
    local d = _diag()
    if d.tapToken == nil then
        _out("[DWKit EventDiag] tap already off")
        return
    end

    if type(DWKit.bus.eventBus.tapOff) ~= "function" then
        _err("eventBus.tapOff not available. Update dwkit.bus.event_bus first.")
        return
    end

    local tok = d.tapToken
    local okCall, ok, err = pcall(DWKit.bus.eventBus.tapOff, tok)
    if not okCall then
        _err("tapOff threw error: " .. tostring(ok))
        return
    end
    if not ok then
        _err(err or "tapOff failed")
        return
    end

    d.tapToken = nil
    _out("[DWKit EventDiag] tap disabled token=" .. tostring(tok))
end

local function _subOn(eventName)
    if not _hasEventBus() then
        _err("DWKit.bus.eventBus not available. Run loader.init() first.")
        return
    end
    if not _hasEventRegistry() then
        _err("DWKit.bus.eventRegistry not available. Run loader.init() first.")
        return
    end

    eventName = tostring(eventName or "")
    if eventName == "" then
        _err("Usage: dweventsub <EventName>")
        return
    end

    if type(DWKit.bus.eventRegistry.has) == "function" then
        local okHas, exists = pcall(DWKit.bus.eventRegistry.has, eventName)
        if okHas and not exists then
            _err("event not registered: " .. tostring(eventName))
            return
        end
    end

    local d = _diag()
    if d.subs[eventName] ~= nil then
        _out("[DWKit EventDiag] already subscribed: " .. tostring(eventName) .. " token=" .. tostring(d.subs[eventName]))
        return
    end

    if type(DWKit.bus.eventBus.on) ~= "function" then
        _err("eventBus.on not available.")
        return
    end

    local okCall, ok, token, err = pcall(DWKit.bus.eventBus.on, eventName, function(payload, ev)
        _pushEventLog("sub", ev, payload)
    end)
    if not okCall then
        _err("subscribe threw error: " .. tostring(ok))
        return
    end
    if not ok then
        _err(err or "subscribe failed")
        return
    end

    d.subs[eventName] = token
    _out("[DWKit EventDiag] subscribed: " .. tostring(eventName) .. " token=" .. tostring(token))
end

local function _subOff(eventName)
    if not _hasEventBus() then
        _err("DWKit.bus.eventBus not available. Run loader.init() first.")
        return
    end

    local d = _diag()
    eventName = tostring(eventName or "")

    if eventName == "" then
        _err("Usage: dweventunsub <EventName|all>")
        return
    end

    if type(DWKit.bus.eventBus.off) ~= "function" then
        _err("eventBus.off not available.")
        return
    end

    if eventName == "all" then
        local any = false
        for ev, tok in pairs(d.subs) do
            any = true
            pcall(DWKit.bus.eventBus.off, tok)
            d.subs[ev] = nil
        end
        _out("[DWKit EventDiag] unsubscribed: all (" .. tostring(any and "some" or "none") .. ")")
        return
    end

    local tok = d.subs[eventName]
    if tok == nil then
        _out("[DWKit EventDiag] not subscribed: " .. tostring(eventName))
        return
    end

    local okCall, ok, err = pcall(DWKit.bus.eventBus.off, tok)
    if not okCall then
        _err("unsubscribe threw error: " .. tostring(ok))
        return
    end
    if not ok then
        _err(err or "unsubscribe failed")
        return
    end

    d.subs[eventName] = nil
    _out("[DWKit EventDiag] unsubscribed: " .. tostring(eventName))
end

local function _logClear()
    local d = _diag()
    d.log = {}
    _out("[DWKit EventDiag] log cleared")
end

local function _printDiagBundle()
    _out("[DWKit Diag] bundle (dwdiag)")
    _out("  NOTE: SAFE + manual-only. Does not enable event tap or subscriptions.")
    _out("")

    _out("== dwversion ==")
    _out("")
    _printVersionSummary()
    _out("")

    _out("== dwboot ==")
    _out("")
    _printBootHealth()
    _out("")

    _out("== dwservices ==")
    _out("")
    _printServicesHealth()
    _out("")

    _out("== event diag status ==")
    _out("")
    _printEventDiagStatus()
end

function M.isInstalled()
    return STATE.installed and true or false
end

function M.getState()
    local d = _diag()
    local subCount = 0
    for _ in pairs(d.subs) do subCount = subCount + 1 end

    return {
        installed = STATE.installed and true or false,
        aliasIds = {
            dwcommands = STATE.aliasIds.dwcommands,
            dwhelp = STATE.aliasIds.dwhelp,
            dwtest = STATE.aliasIds.dwtest,
            dwinfo = STATE.aliasIds.dwinfo,
            dwid = STATE.aliasIds.dwid,
            dwversion = STATE.aliasIds.dwversion,
            dwdiag = STATE.aliasIds.dwdiag,
            dwevents = STATE.aliasIds.dwevents,
            dwevent = STATE.aliasIds.dwevent,
            dwboot = STATE.aliasIds.dwboot,

            dwservices = STATE.aliasIds.dwservices,
            dwpresence = STATE.aliasIds.dwpresence,
            dwactions = STATE.aliasIds.dwactions,
            dwskills = STATE.aliasIds.dwskills,
            dwscorestore = STATE.aliasIds.dwscorestore,

            dweventtap = STATE.aliasIds.dweventtap,
            dweventsub = STATE.aliasIds.dweventsub,
            dweventunsub = STATE.aliasIds.dweventunsub,
            dweventlog = STATE.aliasIds.dweventlog,

            dwrelease = STATE.aliasIds.dwrelease,
        },
        eventDiag = {
            maxLog = d.maxLog,
            logCount = #d.log,
            tapToken = d.tapToken,
            subsCount = subCount,
        },
        lastError = STATE.lastError,
    }
end

local function _killAliasStrict(id)
    if not id then return true end
    if type(killAlias) ~= "function" then
        return false, "killAlias() not available"
    end
    local okCall, res = pcall(killAlias, id)
    if not okCall then
        return false, "killAlias threw error for id=" .. tostring(id)
    end
    if res == false then
        return false, "killAlias returned false for id=" .. tostring(id)
    end
    return true
end

function M.uninstall()
    if not STATE.installed then
        return true, nil
    end

    if _hasEventBus() then
        local d = _diag()
        if d.tapToken ~= nil and type(DWKit.bus.eventBus.tapOff) == "function" then
            pcall(DWKit.bus.eventBus.tapOff, d.tapToken)
            d.tapToken = nil
        end
        if type(DWKit.bus.eventBus.off) == "function" then
            for ev, tok in pairs(d.subs) do
                pcall(DWKit.bus.eventBus.off, tok)
                d.subs[ev] = nil
            end
        end
    end

    if type(killAlias) ~= "function" then
        STATE.lastError = "killAlias() not available"
        return false, STATE.lastError
    end

    local ids = STATE.aliasIds
    local allIds = {
        ids.dwcommands, ids.dwhelp, ids.dwtest, ids.dwinfo, ids.dwid, ids.dwversion, ids.dwdiag,
        ids.dwevents, ids.dwevent, ids.dwboot,
        ids.dwservices, ids.dwpresence, ids.dwactions, ids.dwskills, ids.dwscorestore,
        ids.dweventtap, ids.dweventsub, ids.dweventunsub, ids.dweventlog,
        ids.dwrelease,
    }

    local allOk = true
    for _, id in ipairs(allIds) do
        if id then
            local ok = _killAliasStrict(id)
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

local function _mkAlias(pattern, fn)
    if type(tempAlias) ~= "function" then return nil end
    local ok, id = pcall(tempAlias, pattern, fn)
    if not ok then return nil end
    return id
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

    local dwcommandsPattern = [[^dwcommands(?:\s+(safe|game|md))?\s*$]]
    local id1 = _mkAlias(dwcommandsPattern, function()
        if not _hasCmd() then
            _err("DWKit.cmd not available. Run loader.init() first.")
            return
        end

        local mode = (matches and matches[2]) and tostring(matches[2]) or ""
        if mode == "safe" then
            DWKit.cmd.listSafe()
        elseif mode == "game" then
            DWKit.cmd.listGame()
        elseif mode == "md" then
            if type(DWKit.cmd.toMarkdown) ~= "function" then
                _err("DWKit.cmd.toMarkdown not available.")
                return
            end
            local ok, md = pcall(DWKit.cmd.toMarkdown, {})
            if not ok then
                _err("dwcommands md failed: " .. tostring(md))
                return
            end
            _out(tostring(md))
        else
            DWKit.cmd.listAll()
        end
    end)

    local dwhelpPattern = [[^dwhelp\s+(\S+)\s*$]]
    local id2 = _mkAlias(dwhelpPattern, function()
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

    local dwtestPattern = [[^dwtest(?:\s+(quiet))?\s*$]]
    local id3 = _mkAlias(dwtestPattern, function()
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

    local dwinfoPattern = [[^dwinfo\s*$]]
    local id4 = _mkAlias(dwinfoPattern, function()
        if not _hasBaseline() then
            _err("DWKit.core.runtimeBaseline.printInfo not available. Run loader.init() first.")
            return
        end
        DWKit.core.runtimeBaseline.printInfo()
    end)

    local dwidPattern = [[^dwid\s*$]]
    local id5 = _mkAlias(dwidPattern, function()
        _printIdentity()
    end)

    local dwversionPattern = [[^dwversion\s*$]]
    local id6 = _mkAlias(dwversionPattern, function()
        _printVersionSummary()
    end)

    local dweventsPattern = [[^dwevents(?:\s+(md))?\s*$]]
    local id7 = _mkAlias(dweventsPattern, function()
        if not _hasEventRegistry() then
            _err("DWKit.bus.eventRegistry not available. Run loader.init() first.")
            return
        end

        local mode = (matches and matches[2]) and tostring(matches[2]) or ""
        if mode == "md" then
            if type(DWKit.bus.eventRegistry.toMarkdown) ~= "function" then
                _err("DWKit.bus.eventRegistry.toMarkdown not available.")
                return
            end
            local ok, md = pcall(DWKit.bus.eventRegistry.toMarkdown, {})
            if not ok then
                _err("dwevents md failed: " .. tostring(md))
                return
            end
            _out(tostring(md))
            return
        end

        DWKit.bus.eventRegistry.listAll()
    end)

    local dweventPattern = [[^dwevent\s+(\S+)\s*$]]
    local id8 = _mkAlias(dweventPattern, function()
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

    local dwbootPattern = [[^dwboot\s*$]]
    local id9 = _mkAlias(dwbootPattern, function()
        _printBootHealth()
    end)

    local dwservicesPattern = [[^dwservices\s*$]]
    local id10 = _mkAlias(dwservicesPattern, function()
        _printServicesHealth()
    end)

    local dwpresencePattern = [[^dwpresence\s*$]]
    local id11 = _mkAlias(dwpresencePattern, function()
        _printServiceSnapshot("PresenceService", "presenceService")
    end)

    local dwactionsPattern = [[^dwactions\s*$]]
    local id12 = _mkAlias(dwactionsPattern, function()
        _printServiceSnapshot("ActionModelService", "actionModelService")
    end)

    local dwskillsPattern = [[^dwskills\s*$]]
    local id13 = _mkAlias(dwskillsPattern, function()
        _printServiceSnapshot("SkillRegistryService", "skillRegistryService")
    end)

    -- UPDATED: dwscorestore [status|persist <on|off|status>|fixture [basic]|clear|wipe [disk]|reset [disk]]
    local dwscorestorePattern = [[^dwscorestore(?:\s+(\S+))?(?:\s+(\S+))?\s*$]]
    local id14 = _mkAlias(dwscorestorePattern, function()
        local svc = _getScoreStoreServiceBestEffort()
        if type(svc) ~= "table" then
            _err("ScoreStoreService not available. Run loader.init() first.")
            return
        end

        local sub = (matches and matches[2]) and tostring(matches[2]) or ""
        local arg = (matches and matches[3]) and tostring(matches[3]) or ""

        local function usage()
            _out("[DWKit ScoreStore] Usage:")
            _out("  dwscorestore")
            _out("  dwscorestore status")
            _out("  dwscorestore persist on|off|status")
            _out("  dwscorestore fixture [basic]")
            _out("  dwscorestore clear")
            _out("  dwscorestore wipe [disk]")
            _out("  dwscorestore reset [disk]")
            _out("")
            _out("Notes:")
            _out("  - clear = clears snapshot only (history preserved)")
            _out("  - wipe/reset = clears snapshot + history")
            _out("  - wipe/reset disk = also deletes persisted file (best-effort; requires store.delete)")
        end

        if sub == "" or sub == "status" then
            local ok, _, _, _, err = _callBestEffort(svc, "printSummary")
            if not ok then
                _err("ScoreStoreService.printSummary failed: " .. tostring(err))
            end
            return
        end

        if sub == "persist" then
            if arg ~= "on" and arg ~= "off" and arg ~= "status" then
                usage()
                return
            end

            if arg == "status" then
                local ok, _, _, _, err = _callBestEffort(svc, "printSummary")
                if not ok then
                    _err("ScoreStoreService.printSummary failed: " .. tostring(err))
                end
                return
            end

            if type(svc.configurePersistence) ~= "function" then
                _err("ScoreStoreService.configurePersistence not available.")
                return
            end

            local enable = (arg == "on")
            local ok, _, _, _, err = _callBestEffort(svc, "configurePersistence",
                { enabled = enable, loadExisting = true })
            if not ok then
                _err("configurePersistence failed: " .. tostring(err))
                return
            end

            local ok2, _, _, _, err2 = _callBestEffort(svc, "printSummary")
            if not ok2 then
                _err("ScoreStoreService.printSummary failed: " .. tostring(err2))
            end
            return
        end

        if sub == "fixture" then
            local name = (arg ~= "" and arg) or "basic"
            if type(svc.ingestFixture) ~= "function" then
                _err("ScoreStoreService.ingestFixture not available.")
                return
            end
            local ok, _, _, _, err = _callBestEffort(svc, "ingestFixture", name, { source = "fixture" })
            if not ok then
                _err("ingestFixture failed: " .. tostring(err))
                return
            end
            local ok2, _, _, _, err2 = _callBestEffort(svc, "printSummary")
            if not ok2 then
                _err("ScoreStoreService.printSummary failed: " .. tostring(err2))
            end
            return
        end

        if sub == "clear" then
            if type(svc.clear) ~= "function" then
                _err("ScoreStoreService.clear not available.")
                return
            end
            local ok, _, _, _, err = _callBestEffort(svc, "clear", { source = "manual" })
            if not ok then
                _err("clear failed: " .. tostring(err))
                return
            end
            local ok2, _, _, _, err2 = _callBestEffort(svc, "printSummary")
            if not ok2 then
                _err("ScoreStoreService.printSummary failed: " .. tostring(err2))
            end
            return
        end

        if sub == "wipe" or sub == "reset" then
            if arg ~= "" and arg ~= "disk" then
                usage()
                return
            end
            if type(svc.wipe) ~= "function" then
                _err("ScoreStoreService.wipe not available. Update dwkit.services.score_store_service first.")
                return
            end

            local meta = { source = "manual" }
            if arg == "disk" then
                meta.deleteFile = true
            end

            local ok, _, _, _, err = _callBestEffort(svc, "wipe", meta)
            if not ok then
                _err(sub .. " failed: " .. tostring(err))
                return
            end

            local ok2, _, _, _, err2 = _callBestEffort(svc, "printSummary")
            if not ok2 then
                _err("ScoreStoreService.printSummary failed: " .. tostring(err2))
            end
            return
        end

        usage()
    end)

    local dweventtapPattern = [[^dweventtap(?:\s+(on|off|status|show|clear))?(?:\s+(\d+))?\s*$]]
    local id15 = _mkAlias(dweventtapPattern, function()
        local mode = (matches and matches[2]) and tostring(matches[2]) or ""
        local n = (matches and matches[3]) and tostring(matches[3]) or ""

        if mode == "" or mode == "status" then
            _printEventDiagStatus()
            return
        end
        if mode == "on" then
            _tapOn()
            return
        end
        if mode == "off" then
            _tapOff()
            return
        end
        if mode == "show" then
            _printEventLog(n)
            return
        end
        if mode == "clear" then
            _logClear()
            return
        end

        _err("Usage: dweventtap [on|off|status|show|clear] [n]")
    end)

    local dweventsubPattern = [[^dweventsub\s+(\S+)\s*$]]
    local id16 = _mkAlias(dweventsubPattern, function()
        local evName = (matches and matches[2]) and tostring(matches[2]) or ""
        _subOn(evName)
    end)

    local dweventunsubPattern = [[^dweventunsub\s+(\S+)\s*$]]
    local id17 = _mkAlias(dweventunsubPattern, function()
        local evName = (matches and matches[2]) and tostring(matches[2]) or ""
        _subOff(evName)
    end)

    local dweventlogPattern = [[^dweventlog(?:\s+(\d+))?\s*$]]
    local id18 = _mkAlias(dweventlogPattern, function()
        local n = (matches and matches[2]) and tostring(matches[2]) or ""
        _printEventLog(n)
    end)

    local dwdiagPattern = [[^dwdiag\s*$]]
    local id19 = _mkAlias(dwdiagPattern, function()
        _printDiagBundle()
    end)

    local dwreleasePattern = [[^dwrelease\s*$]]
    local id20 = _mkAlias(dwreleasePattern, function()
        _printReleaseChecklist()
    end)

    local all = { id1, id2, id3, id4, id5, id6, id7, id8, id9, id10, id11, id12, id13, id14, id15, id16, id17, id18, id19,
        id20 }
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

    STATE.aliasIds.dweventtap   = id15
    STATE.aliasIds.dweventsub   = id16
    STATE.aliasIds.dweventunsub = id17
    STATE.aliasIds.dweventlog   = id18

    STATE.aliasIds.dwdiag       = id19
    STATE.aliasIds.dwrelease    = id20

    STATE.installed             = true
    STATE.lastError             = nil

    if not opts.quiet then
        _out(
            "[DWKit Alias] Installed: dwcommands, dwhelp, dwtest, dwinfo, dwid, dwversion, dwevents, dwevent, dwboot, dwservices, dwpresence, dwactions, dwskills, dwscorestore, dweventtap, dweventsub, dweventunsub, dweventlog, dwdiag, dwrelease")
    end

    return true, nil
end

return M
