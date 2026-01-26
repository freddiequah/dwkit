-- #########################################################################
-- Module Name : dwkit.commands.alias_legacy
-- Owner       : Commands
-- Version     : v2026-01-26A
-- Purpose     :
--   - Legacy printer + pretty-print helpers used by command_aliases fallbacks.
--   - Extracted to reduce responsibility/size of dwkit.services.command_aliases.
--
-- IMPORTANT:
--   - SAFE: printing only (no timers, no automation).
--   - Accepts ctx (out/err/safeRequire/callBestEffort/getKit/sortedKeys).
-- #########################################################################

local M = {}

M.VERSION = "v2026-01-26A"

local function _out(ctx, line)
    line = tostring(line or "")
    if type(ctx) == "table" and type(ctx.out) == "function" then
        ctx.out(line)
        return
    end
    print(line)
end

local function _err(ctx, msg)
    if type(ctx) == "table" and type(ctx.err) == "function" then
        ctx.err(msg)
        return
    end
    _out(ctx, "[DWKit Legacy] ERROR: " .. tostring(msg))
end

local function _safeRequire(ctx, name)
    if type(ctx) == "table" and type(ctx.safeRequire) == "function" then
        return ctx.safeRequire(name)
    end
    local ok, mod = pcall(require, name)
    return ok, mod
end

local function _callBestEffort(ctx, obj, fnName, ...)
    if type(ctx) == "table" and type(ctx.callBestEffort) == "function" then
        return ctx.callBestEffort(obj, fnName, ...)
    end

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

local function _getKit(ctx)
    if type(ctx) == "table" and type(ctx.getKit) == "function" then
        return ctx.getKit()
    end
    if type(_G) == "table" and type(_G.DWKit) == "table" then return _G.DWKit end
    if type(DWKit) == "table" then return DWKit end
    return nil
end

local function _sortedKeys(ctx, t)
    if type(ctx) == "table" and type(ctx.sortedKeys) == "function" then
        return ctx.sortedKeys(t)
    end
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

function M.ppValue(v)
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

function M.ppTable(ctx, t, opts)
    opts = opts or {}
    local maxDepth = (type(opts.maxDepth) == "number") and opts.maxDepth or 2
    local maxItems = (type(opts.maxItems) == "number") and opts.maxItems or 30

    local seen = {}

    local function walk(x, depth, prefix)
        if type(x) ~= "table" then
            _out(ctx, prefix .. M.ppValue(x))
            return
        end
        if seen[x] then
            _out(ctx, prefix .. "{<cycle>}")
            return
        end
        seen[x] = true

        local count = _countAnyTable(x)
        _out(ctx, prefix .. "{ table, count=" .. tostring(count) .. " }")

        if depth >= maxDepth then
            return
        end

        if _isArrayLike(x) then
            local n = #x
            local limit = math.min(n, maxItems)
            for i = 1, limit do
                local v = x[i]
                if type(v) == "table" then
                    _out(ctx, prefix .. "  [" .. tostring(i) .. "] =")
                    walk(v, depth + 1, prefix .. "    ")
                else
                    _out(ctx, prefix .. "  [" .. tostring(i) .. "] = " .. M.ppValue(v))
                end
            end
            if n > limit then
                _out(ctx, prefix .. "  ... (" .. tostring(n - limit) .. " more)")
            end
            return
        end

        local keys = _sortedKeys(ctx, x)
        local limit = math.min(#keys, maxItems)
        for i = 1, limit do
            local k = keys[i]
            local v = x[k]
            if type(v) == "table" then
                _out(ctx, prefix .. "  " .. tostring(k) .. " =")
                walk(v, depth + 1, prefix .. "    ")
            else
                _out(ctx, prefix .. "  " .. tostring(k) .. " = " .. M.ppValue(v))
            end
        end
        if #keys > limit then
            _out(ctx, prefix .. "  ... (" .. tostring(#keys - limit) .. " more keys)")
        end
    end

    walk(t, 0, "")
end

function M.printIdentity(ctx)
    local kit = _getKit(ctx)
    if type(kit) ~= "table" or type(kit.core) ~= "table" or type(kit.core.identity) ~= "table" then
        _err(ctx, "DWKit.core.identity not available. Run loader.init() first.")
        return
    end

    local I         = kit.core.identity
    local idVersion = tostring(I.VERSION or "unknown")
    local pkgId     = tostring(I.packageId or "unknown")
    local evp       = tostring(I.eventPrefix or "unknown")
    local df        = tostring(I.dataFolderName or "unknown")
    local vts       = tostring(I.versionTagStyle or "unknown")

    _out(ctx, "[DWKit] identity=" ..
        idVersion ..
        " packageId=" .. pkgId .. " eventPrefix=" .. evp .. " dataFolder=" .. df .. " versionTagStyle=" .. vts)
end

function M.printVersionSummary(ctx, commandAliasesVersion)
    local kit = _getKit(ctx)
    if type(kit) ~= "table" then
        _err(ctx, "DWKit global not available. Run loader.init() first.")
        return
    end

    local ident = nil
    if type(kit.core) == "table" and type(kit.core.identity) == "table" then
        ident = kit.core.identity
    else
        local okI, modI = _safeRequire(ctx, "dwkit.core.identity")
        if okI and type(modI) == "table" then ident = modI end
    end

    local rb = nil
    if type(kit.core) == "table" and type(kit.core.runtimeBaseline) == "table" then
        rb = kit.core.runtimeBaseline
    else
        local okRB, modRB = _safeRequire(ctx, "dwkit.core.runtime_baseline")
        if okRB and type(modRB) == "table" then rb = modRB end
    end

    local cmdRegVersion = "unknown"
    if type(kit.cmd) == "table" then
        local okV, v = _callBestEffort(ctx, kit.cmd, "getRegistryVersion")
        if okV and v then cmdRegVersion = tostring(v) end
    end

    local evRegVersion = "unknown"
    if type(kit.bus) == "table" and type(kit.bus.eventRegistry) == "table" then
        local okE, v = _callBestEffort(ctx, kit.bus.eventRegistry, "getRegistryVersion")
        if okE and v then evRegVersion = tostring(v) end
    else
        local okER, modER = _safeRequire(ctx, "dwkit.bus.event_registry")
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
    do
        local okEB, modEB = _safeRequire(ctx, "dwkit.bus.event_bus")
        if okEB and type(modEB) == "table" then
            evBusVersion = tostring(modEB.VERSION or "unknown")
        end
    end

    local stVersion = "unknown"
    do
        local okST, st = _safeRequire(ctx, "dwkit.tests.self_test_runner")
        if okST and type(st) == "table" then
            stVersion = tostring(st.VERSION or "unknown")
        end
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

    _out(ctx, "[DWKit] Version summary:")
    _out(ctx, "  identity        = " .. idVersion)
    _out(ctx, "  runtimeBaseline = " .. rbVersion)
    _out(ctx, "  selfTestRunner  = " .. stVersion)
    _out(ctx, "  commandRegistry = " .. cmdRegVersion)
    _out(ctx, "  eventRegistry   = " .. evRegVersion)
    _out(ctx, "  eventBus        = " .. evBusVersion)
    _out(ctx, "  commandAliases  = " .. tostring(commandAliasesVersion or "unknown"))
    _out(ctx, "")
    _out(ctx, "[DWKit] Identity (locked):")
    _out(ctx, "  packageId=" .. pkgId .. " eventPrefix=" .. evp .. " dataFolder=" .. df .. " versionTagStyle=" .. vts)
    _out(ctx, "[DWKit] Runtime baseline:")
    _out(ctx, "  lua=" .. luaV .. " mudlet=" .. mudletV)
end

local function _yn(b) return b and "OK" or "MISSING" end

function M.printBootHealth(ctx)
    _out(ctx, "[DWKit Boot] Health summary (dwboot)")
    _out(ctx, "")

    local kit = _getKit(ctx)
    if type(kit) ~= "table" then
        _out(ctx, "  DWKit global                : MISSING")
        _out(ctx, "")
        _out(ctx, "  Next step:")
        _out(ctx, "    - Run: lua local L=require(\"dwkit.loader.init\"); L.init()")
        return
    end

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

    _out(ctx, "  DWKit global                : OK")
    _out(ctx, "  core.identity               : " .. _yn(hasIdentity))
    _out(ctx, "  core.runtimeBaseline        : " .. _yn(hasRB))
    _out(ctx, "  cmd (runtime surface)       : " .. _yn(hasCmd))
    _out(ctx, "  bus.commandRegistry         : " .. _yn(hasCmdReg))
    _out(ctx, "  bus.eventRegistry           : " .. _yn(hasEvReg))
    _out(ctx, "  bus.eventBus                : " .. _yn(hasEvBus))
    _out(ctx, "  test.run                    : " .. _yn(hasTest))
    _out(ctx, "  services.commandAliases     : " .. _yn(hasAliases))
    _out(ctx, "")

    local initTs = kit._lastInitTs
    if type(initTs) == "number" then
        _out(ctx, "  lastInitTs                  : " .. tostring(initTs))
    else
        _out(ctx, "  lastInitTs                  : (unknown)")
    end

    local br = kit._bootReadyEmitted
    _out(ctx, "  bootReadyEmitted            : " .. tostring(br == true))
    if type(kit._bootReadyTs) == "number" then
        _out(ctx, "  bootReadyTs                 : " .. tostring(kit._bootReadyTs))

        local okD, s = pcall(os.date, "%Y-%m-%d %H:%M:%S", kit._bootReadyTs)
        if okD and s then
            _out(ctx, "  bootReadyLocal              : " .. tostring(s))
        else
            _out(ctx, "  bootReadyLocal              : (unavailable)")
        end
    end

    if type(kit._bootReadyTsMs) == "number" then
        _out(ctx, "  bootReadyTsMs               : " .. tostring(kit._bootReadyTsMs))
    else
        _out(ctx, "  bootReadyTsMs               : (unknown)")
    end

    if kit._bootReadyEmitError then
        _out(ctx, "  bootReadyEmitError          : " .. tostring(kit._bootReadyEmitError))
    end

    _out(ctx, "")
    _out(ctx, "  load errors (if any):")
    local anyErr = false

    local function showErr(key, val)
        if val ~= nil and tostring(val) ~= "" then
            anyErr = true
            _out(ctx, "    - " .. key .. " = " .. tostring(val))
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
        _out(ctx, "    (none)")
    end

    if type(kit.bus) == "table" and type(kit.bus.eventBus) == "table" and type(kit.bus.eventBus.getStats) == "function" then
        local okS, stats = pcall(kit.bus.eventBus.getStats)
        if okS and type(stats) == "table" then
            _out(ctx, "")
            _out(ctx, "  eventBus stats:")
            _out(ctx, "    version          : " .. tostring(stats.version or "unknown"))
            _out(ctx, "    subscribers      : " .. tostring(stats.subscribers or 0))
            _out(ctx, "    tapSubscribers   : " .. tostring(stats.tapSubscribers or 0))
            _out(ctx, "    emitted          : " .. tostring(stats.emitted or 0))
            _out(ctx, "    delivered        : " .. tostring(stats.delivered or 0))
            _out(ctx, "    handlerErrors    : " .. tostring(stats.handlerErrors or 0))
            _out(ctx, "    tapErrors        : " .. tostring(stats.tapErrors or 0))
        end
    end

    _out(ctx, "")
    _out(ctx, "  Tip: if anything is MISSING, run:")
    _out(ctx, "    lua local L=require(\"dwkit.loader.init\"); L.init()")
end

function M.printServicesHealth(ctx)
    _out(ctx, "[DWKit Services] Health summary (dwservices)")
    _out(ctx, "")

    local kit = _getKit(ctx)
    if type(kit) ~= "table" then
        _out(ctx, "  DWKit global: MISSING")
        _out(ctx, "  Next step: lua local L=require(\"dwkit.loader.init\"); L.init()")
        return
    end

    if type(kit.services) ~= "table" then
        _out(ctx, "  DWKit.services: MISSING")
        return
    end

    local function showSvc(fieldName, errKey)
        local svc = kit.services[fieldName]
        local ok = (type(svc) == "table")
        local v = ok and tostring(svc.VERSION or "unknown") or "unknown"
        _out(ctx, "  " .. fieldName .. " : " .. (ok and "OK" or "MISSING") .. "  version=" .. v)

        local errVal = kit[errKey]
        if errVal ~= nil and tostring(errVal) ~= "" then
            _out(ctx, "    loadError: " .. tostring(errVal))
        end
    end

    showSvc("presenceService", "_presenceServiceLoadError")
    showSvc("actionModelService", "_actionModelServiceLoadError")
    showSvc("skillRegistryService", "_skillRegistryServiceLoadError")
    showSvc("scoreStoreService", "_scoreStoreServiceLoadError")
end

function M.printServiceSnapshot(ctx, label, svc)
    _out(ctx, "[DWKit Service] " .. tostring(label))

    if type(svc) ~= "table" then
        _err(ctx, "Service not available. Run loader.init() first.")
        return
    end

    _out(ctx, "  version=" .. tostring(svc.VERSION or "unknown"))

    if type(svc.getState) == "function" then
        local ok, state, _, _, err = _callBestEffort(ctx, svc, "getState")
        if ok then
            _out(ctx, "  getState(): OK")
            M.ppTable(ctx, state, { maxDepth = 2, maxItems = 30 })
            return
        end
        _out(ctx, "  getState(): ERROR")
        if err and err ~= "" then _out(ctx, "    err=" .. tostring(err)) end
    end

    if type(svc.getAll) == "function" then
        local ok, state, _, _, err = _callBestEffort(ctx, svc, "getAll")
        if ok then
            _out(ctx, "  getAll(): OK")
            M.ppTable(ctx, state, { maxDepth = 2, maxItems = 30 })
            return
        end
        _out(ctx, "  getAll(): ERROR")
        if err and err ~= "" then _out(ctx, "    err=" .. tostring(err)) end
    end

    local keys = _sortedKeys(ctx, svc)
    _out(ctx, "  APIs available (keys on service table): count=" .. tostring(#keys))
    local limit = math.min(#keys, 40)
    for i = 1, limit do
        _out(ctx, "    - " .. tostring(keys[i]))
    end
    if #keys > limit then
        _out(ctx, "    ... (" .. tostring(#keys - limit) .. " more)")
    end
end

function M.printNoUiNote(ctx, context)
    context = tostring(context or "UI")
    _out(ctx, "  NOTE: No UI modules found for this profile (" .. context .. ").")
    _out(ctx, "  Tips:")
    _out(ctx, "    - dwgui list")
    _out(ctx, "    - dwgui enable <uiId>")
    _out(ctx, "    - dwgui apply   (optional: render enabled UI)")
end

function M.printReleaseChecklist(ctx, commandAliasesVersion)
    _out(ctx, "[DWKit Release] checklist (dwrelease)")
    _out(ctx, "  NOTE: SAFE + manual-only. This does not run git/gh commands.")
    _out(ctx, "")

    _out(ctx, "== versions (best-effort) ==")
    _out(ctx, "")
    M.printVersionSummary(ctx, commandAliasesVersion)
    _out(ctx, "")

    _out(ctx, "== PR workflow (PowerShell + gh) ==")
    _out(ctx, "")
    _out(ctx, "  1) Start clean:")
    _out(ctx, "     - git checkout main")
    _out(ctx, "     - git pull")
    _out(ctx, "     - git status -sb")
    _out(ctx, "")
    _out(ctx, "  2) Create topic branch:")
    _out(ctx, "     - git checkout -b <topic/name>")
    _out(ctx, "")
    _out(ctx, "  3) Commit changes (scope small):")
    _out(ctx, "     - git status")
    _out(ctx, "     - git add <paths...>")
    _out(ctx, "     - git commit -m \"<message>\"")
    _out(ctx, "")
    _out(ctx, "  4) Push branch:")
    _out(ctx, "     - git push --set-upstream origin <topic/name>")
    _out(ctx, "")
    _out(ctx, "  5) Create PR:")
    _out(ctx, "     - gh pr create --base main --head <topic/name> --title \"<title>\" --body \"<body>\"")
    _out(ctx, "")
    _out(ctx, "  6) Review + merge (preferred: squash + delete branch):")
    _out(ctx, "     - gh pr status")
    _out(ctx, "     - gh pr view")
    _out(ctx, "     - gh pr diff")
    _out(ctx, "     - gh pr checks    (if configured)")
    _out(ctx, "     - gh pr merge <PR_NUMBER> --squash --delete-branch")
    _out(ctx, "")
    _out(ctx, "  7) Sync local main AFTER merge:")
    _out(ctx, "     - git checkout main")
    _out(ctx, "     - git pull")
    _out(ctx, "     - git log -1 --oneline --decorate")
    _out(ctx, "")

    _out(ctx, "== release tagging discipline (annotated tag on main HEAD) ==")
    _out(ctx, "")
    _out(ctx, "  1) Verify main HEAD is correct:")
    _out(ctx, "     - git checkout main")
    _out(ctx, "     - git pull")
    _out(ctx, "     - git log -1 --oneline --decorate")
    _out(ctx, "")
    _out(ctx, "  2) Create annotated tag (after merge):")
    _out(ctx, "     - git tag -a vYYYY-MM-DDX -m \"<tag message>\"")
    _out(ctx, "     - git push origin vYYYY-MM-DDX")
    _out(ctx, "")
    _out(ctx, "  3) Verify tag targets origin/main:")
    _out(ctx, "     - git rev-parse --verify origin/main")
    _out(ctx, "     - git rev-parse --verify 'vYYYY-MM-DDX^{}'")
    _out(ctx, "     - (expected: hashes match)")
    _out(ctx, "")
    _out(ctx, "  4) If you tagged wrong commit (fix safely):")
    _out(ctx, "     - git tag -d vYYYY-MM-DDX")
    _out(ctx, "     - git push origin :refs/tags/vYYYY-MM-DDX")
    _out(ctx, "     - (then recreate on correct main HEAD)")
end

return M
