-- #########################################################################
-- Module Name : dwkit.services.command_aliases
-- Owner       : Services
-- Version     : v2026-01-19K
-- Purpose     :
--   - Install SAFE Mudlet aliases for command discovery/help:
--       * dwcommands [safe|game|md]
--       * dwhelp <cmd>
--       * dwtest [quiet|ui]
--       * dwinfo
--       * dwid
--       * dwversion
--       * dwdiag
--       * dwgui
--       * dwevents [md]
--       * dwevent <EventName>
--       * dwboot
--       * dwservices
--       * dwpresence
--       * dwroom
--       * dwwho
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
--   - DOES NOT start timers or automation (except bounded capture sessions for refresh commands).
--
-- IMPORTANT:
--   - tempAlias objects persist in Mudlet even if this module is reloaded via package.loaded=nil.
--   - This module stores alias ids in _G.DWKit._commandAliasesAliasIds and cleans them up on install()
--     and uninstall(), preventing duplicate alias execution/output across reloads.
--
-- Fixes (v2026-01-19F):
--   - uninstall() always attempts persisted alias cleanup even if STATE.installed=false (reload-safe).
--   - WhoStore service resolution is STRICT: do not return partial/stale objects (avoids "unknown API").
--   - dwwho refresh uses _G.send or _G.sendAll explicitly (more robust across environments).
--   - who refresh ingest uses best-effort ingest (ingestWhoText OR ingestWhoLines).
--
-- Fixes (v2026-01-19G):
--   - dwwho: DISABLE who_diag delegation by default (avoids false "ingestWhoText not available" errors).
--     Inline fallback handler is canonical until who_diag API contract is proven compatible.
--   - refresh: error message references send/sendAll (matches resolver).
--
-- Fixes (v2026-01-19H):
--   - dwroom refresh added (GAME): sends 'look', captures output, ingests via RoomEntitiesService.ingestLookText.
--   - Capture end detection uses prompt-like regex (best-effort) + timeout fallback.
--   - uninstall() also cancels pending room capture sessions (reload-safe).
--
-- Phase 1 Split (v2026-01-19I):
--   - Extracted dwroom + dwwho command handlers into:
--       * src/dwkit/commands/dwroom.lua
--       * src/dwkit/commands/dwwho.lua
--   - command_aliases now delegates to those handlers (keeps alias patterns stable).
--
-- Phase 2 Split (v2026-01-19J):
--   - dwgui handler now delegates to src/dwkit/commands/dwgui.lua when available,
--     with a safe inline fallback if the module signature differs or is missing.
--
-- Fixes (v2026-01-19K):
--   - dwgui alias parsing no longer relies on optional capture groups (Mudlet matches[] can be stale).
--     Instead, sub/uiId/arg3 are derived from tokenizing matches[1] (the full line).
--
-- Public API  :
--   - install(opts?) -> boolean ok, string|nil err
--   - uninstall() -> boolean ok, string|nil err
--   - isInstalled() -> boolean
--   - getState() -> table copy
-- #########################################################################

local M = {}

M.VERSION = "v2026-01-19K"

local _GLOBAL_ALIAS_IDS_KEY = "_commandAliasesAliasIds"

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
        dwgui        = nil,
        dwevents     = nil,
        dwevent      = nil,
        dwboot       = nil,

        dwservices   = nil,
        dwpresence   = nil,
        dwroom       = nil,
        dwwho        = nil,
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

    -- Who capture session (manual; used by dwwho refresh)
    whoCapture = {
        active = false,
        started = false,
        lines = nil,
        trigAny = nil,
        timer = nil,
        startedAt = nil,
    },

    -- RoomEntities capture session (manual; used by dwroom refresh)
    roomCapture = {
        active = false,
        started = false,
        lines = nil,
        trigAny = nil,
        timer = nil,
        startedAt = nil,
        assumeCap = false,
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

-- ------------------------------------------------------------
-- RoomEntities helpers (SAFE manual surface)
-- ------------------------------------------------------------
local function _getRoomEntitiesServiceBestEffort()
    local svc = _getService("roomEntitiesService")
    if type(svc) == "table" then return svc end
    local ok, mod = _safeRequire("dwkit.services.roomentities_service")
    if ok and type(mod) == "table" then return mod end
    return nil
end

-- ------------------------------------------------------------
-- WhoStore helpers (SAFE manual surface)
-- ------------------------------------------------------------
local function _looksLikeWhoStoreService(svc)
    if type(svc) ~= "table" then return false end
    local hasState = (type(svc.getState) == "function")
    local hasIngest = (type(svc.ingestWhoText) == "function") or (type(svc.ingestWhoLines) == "function")
    local hasClear = (type(svc.clear) == "function")
    return (hasState and hasIngest and hasClear)
end

local function _getWhoStoreServiceBestEffort()
    -- STRICT: do NOT return partial/stale objects.
    local svc = _getService("whoStoreService")
    if _looksLikeWhoStoreService(svc) then
        return svc
    end

    local ok, mod = _safeRequire("dwkit.services.whostore_service")
    if ok and type(mod) == "table" and _looksLikeWhoStoreService(mod) then
        return mod
    end

    return nil
end

local function _whoIngestTextBestEffort(svc, text, meta)
    meta = (type(meta) == "table") and meta or {}
    text = tostring(text or "")

    if type(svc) ~= "table" then
        return false, "svc not available"
    end

    if type(svc.ingestWhoText) == "function" then
        local okCall, a, b, c, err = _callBestEffort(svc, "ingestWhoText", text, meta)
        if okCall and a ~= false then
            return true, nil
        end
        return false, tostring(b or c or err or "ingestWhoText failed")
    end

    if type(svc.ingestWhoLines) == "function" then
        local lines = {}
        text = text:gsub("\r", "")
        for line in text:gmatch("([^\n]+)") do
            lines[#lines + 1] = line
        end
        local okCall, a, b, c, err = _callBestEffort(svc, "ingestWhoLines", lines, meta)
        if okCall and a ~= false then
            return true, nil
        end
        return false, tostring(b or c or err or "ingestWhoLines failed")
    end

    return false, "WhoStoreService ingestWhoText/ingestWhoLines not available"
end

local function _whoCountFromState(state)
    state = (type(state) == "table") and state or {}
    local function cnt(t)
        if type(t) ~= "table" then return 0 end
        local n = 0
        for _ in pairs(t) do n = n + 1 end
        return n
    end
    return {
        players = cnt(state.players),
    }
end

local function _sortedKeys(t)
    local keys = {}
    if type(t) ~= "table" then return keys end
    for k, _ in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    return keys
end

local function _printWhoStatus(svc)
    if type(svc) ~= "table" then
        _err("WhoStoreService not available. Create src/dwkit/services/whostore_service.lua first, then loader.init().")
        return
    end

    local state = {}
    if type(svc.getState) == "function" then
        local ok, v, _, _, err = _callBestEffort(svc, "getState")
        if ok and type(v) == "table" then
            state = v
        elseif err then
            _out("[DWKit Who] getState failed: " .. tostring(err))
        end
    end

    local c = _whoCountFromState(state)

    _out("[DWKit Who] status (dwwho)")
    _out("  serviceVersion=" .. tostring(svc.VERSION or "unknown"))
    _out("  players=" .. tostring(c.players))
    _out("  lastUpdatedTs=" .. tostring(state.lastUpdatedTs or ""))
    _out("  source=" .. tostring(state.source or ""))

    local names = _sortedKeys(state.players)
    local limit = math.min(#names, 12)
    if limit > 0 then
        _out("  top=" .. table.concat({ unpack(names, 1, limit) }, ", "))
        if #names > limit then
            _out("  ... (" .. tostring(#names - limit) .. " more)")
        end
    end
end

local function _roomCountsFromState(state)
    state = (type(state) == "table") and state or {}
    local function cnt(t)
        if type(t) ~= "table" then return 0 end
        local n = 0
        for _ in pairs(t) do n = n + 1 end
        return n
    end
    return {
        players = cnt(state.players),
        mobs = cnt(state.mobs),
        items = cnt(state.items),
        unknown = cnt(state.unknown),
    }
end

local function _printRoomEntitiesStatus(svc)
    if type(svc) ~= "table" then
        _err("RoomEntitiesService not available. Run loader.init() first.")
        return
    end

    local state = {}
    if type(svc.getState) == "function" then
        local ok, v, _, _, err = _callBestEffort(svc, "getState")
        if ok and type(v) == "table" then
            state = v
        elseif err then
            _out("[DWKit Room] getState failed: " .. tostring(err))
        end
    end

    local c = _roomCountsFromState(state)
    _out("[DWKit Room] status (dwroom)")
    _out("  serviceVersion=" .. tostring(svc.VERSION or "unknown"))
    _out("  players=" .. tostring(c.players))
    _out("  mobs=" .. tostring(c.mobs))
    _out("  items=" .. tostring(c.items))
    _out("  unknown=" .. tostring(c.unknown))
end

local function _getClipboardTextBestEffort()
    if type(getClipboardText) == "function" then
        local ok, t = pcall(getClipboardText)
        if ok and type(t) == "string" then
            return t
        end
    end
    return nil
end

-- ------------------------------------------------------------
-- Capture helpers (Who + Room)
-- ------------------------------------------------------------
local function _killTriggerBestEffort(id)
    if not id then return end
    if type(killTrigger) ~= "function" then return end
    pcall(killTrigger, id)
end

local function _killTimerBestEffort(id)
    if not id then return end
    if type(killTimer) ~= "function" then return end
    pcall(killTimer, id)
end

local function _resolveSendFn()
    if type(_G.send) == "function" then return _G.send end
    if type(_G.sendAll) == "function" then return _G.sendAll end
    return nil
end

-- Best-effort prompt detector for Deathwish style prompts like:
--   <716(716)Hp 100(100)Mp 82(82)Mv>
-- or:
--   716(716)Hp 100(100)Mp 82(82)Mv>
local function _looksLikePrompt(line)
    line = tostring(line or "")
    if line == "" then return false end

    -- optional leading '<', then digits, then "(digits)Hp"
    if line:match("^%s*<?%d+%(%d+%)Hp") then
        return true
    end

    -- fallback: common prompt closer
    if line:match(">%s*$") and line:match("Hp") and line:match("Mp") then
        return true
    end

    return false
end

-- ------------------------------------------------------------
-- Who capture (manual state; legacy kept for compatibility)
-- ------------------------------------------------------------
local function _whoCaptureReset()
    STATE.whoCapture.active = false
    STATE.whoCapture.started = false
    STATE.whoCapture.lines = nil
    STATE.whoCapture.startedAt = nil

    _killTriggerBestEffort(STATE.whoCapture.trigAny)
    STATE.whoCapture.trigAny = nil

    _killTimerBestEffort(STATE.whoCapture.timer)
    STATE.whoCapture.timer = nil
end

-- ------------------------------------------------------------
-- Room capture (manual state; legacy kept for compatibility)
-- ------------------------------------------------------------
local function _roomCaptureReset()
    STATE.roomCapture.active = false
    STATE.roomCapture.started = false
    STATE.roomCapture.lines = nil
    STATE.roomCapture.startedAt = nil
    STATE.roomCapture.assumeCap = false

    _killTriggerBestEffort(STATE.roomCapture.trigAny)
    STATE.roomCapture.trigAny = nil

    _killTimerBestEffort(STATE.roomCapture.timer)
    STATE.roomCapture.timer = nil
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

    local ident = nil
    if _hasIdentity() then
        ident = DWKit.core.identity
    else
        local okI, modI = _safeRequire("dwkit.core.identity")
        if okI and type(modI) == "table" then ident = modI end
    end

    local rb = nil
    if type(DWKit.core) == "table" and type(DWKit.core.runtimeBaseline) == "table" then
        rb = DWKit.core.runtimeBaseline
    else
        local okRB, modRB = _safeRequire("dwkit.core.runtime_baseline")
        if okRB and type(modRB) == "table" then rb = modRB end
    end

    local cmdRegVersion = "unknown"
    if _hasCmd() then
        local okV, v = _callBestEffort(DWKit.cmd, "getRegistryVersion")
        if okV and v then
            cmdRegVersion = tostring(v)
        end
    end

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

local function _getGuiSettingsBestEffort()
    if type(_G.DWKit) == "table" and type(_G.DWKit.config) == "table" and type(_G.DWKit.config.guiSettings) == "table" then
        return _G.DWKit.config.guiSettings
    end
    local ok, mod = _safeRequire("dwkit.config.gui_settings")
    if ok and type(mod) == "table" then return mod end
    return nil
end

local function _getUiValidatorBestEffort()
    local ok, mod = _safeRequire("dwkit.ui.ui_validator")
    if ok and type(mod) == "table" then
        return mod
    end
    return nil
end

local function _printGuiStatusAndList(gs)
    local okS, st = pcall(gs.status)
    if not okS or type(st) ~= "table" then
        _err("guiSettings.status failed")
        return
    end

    _out("[DWKit GUI] status (dwgui)")
    _out("  version=" .. tostring(gs.VERSION or "unknown"))
    _out("  loaded=" .. tostring(st.loaded == true))
    _out("  relPath=" .. tostring(st.relPath or ""))
    _out("  uiCount=" .. tostring(st.uiCount or 0))
    if type(st.options) == "table" then
        _out("  options.visiblePersistenceEnabled=" .. tostring(st.options.visiblePersistenceEnabled == true))
        _out("  options.enabledDefault=" .. tostring(st.options.enabledDefault == true))
        _out("  options.visibleDefault=" .. tostring(st.options.visibleDefault == true))
    end
    if st.lastError then
        _out("  lastError=" .. tostring(st.lastError))
    end

    local okL, uiMap = pcall(gs.list)
    if not okL or type(uiMap) ~= "table" then
        _err("guiSettings.list failed")
        return
    end

    _out("")
    _out("[DWKit GUI] list (uiId -> enabled/visible)")

    local keys = _sortedKeys(uiMap)
    if #keys == 0 then
        _out("  (none)")
        return
    end

    for _, uiId in ipairs(keys) do
        local rec = uiMap[uiId]
        local en = (type(rec) == "table" and rec.enabled == true) and "ON" or "OFF"
        local vis = "(unset)"
        if type(rec) == "table" then
            if rec.visible == true then
                vis = "ON"
            elseif rec.visible == false then
                vis = "OFF"
            end
        end
        _out("  - " .. tostring(uiId) .. "  enabled=" .. en .. "  visible=" .. vis)
    end
end

local function _printNoUiNote(context)
    context = tostring(context or "UI")
    _out("  NOTE: No UI modules found for this profile (" .. context .. ").")
    _out("  Tips:")
    _out("    - dwgui list")
    _out("    - dwgui enable <uiId>")
    _out("    - dwgui apply   (optional: render enabled UI)")
end

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
-- Event diagnostics (delegated handlers; STATE stays here)
-- -------------------------
local function _getEventBusBestEffort()
    if type(_G.DWKit) == "table" and type(_G.DWKit.bus) == "table" and type(_G.DWKit.bus.eventBus) == "table" then
        return _G.DWKit.bus.eventBus
    end
    local ok, mod = _safeRequire("dwkit.bus.event_bus")
    if ok and type(mod) == "table" then
        return mod
    end
    return nil
end

local function _getEventRegistryBestEffort()
    if type(_G.DWKit) == "table" and type(_G.DWKit.bus) == "table" and type(_G.DWKit.bus.eventRegistry) == "table" then
        return _G.DWKit.bus.eventRegistry
    end
    local ok, mod = _safeRequire("dwkit.bus.event_registry")
    if ok and type(mod) == "table" then
        return mod
    end
    return nil
end

local function _getEventDiagModuleBestEffort()
    local ok, mod = _safeRequire("dwkit.commands.event_diag")
    if ok and type(mod) == "table" then
        return mod
    end
    return nil
end

local function _makeEventDiagCtx()
    return {
        out = function(line) _out(line) end,
        err = function(msg) _err(msg) end,
        ppTable = function(t, opts) _ppTable(t, opts) end,
        ppValue = function(v) return _ppValue(v) end,
        hasEventBus = function()
            return type(_getEventBusBestEffort()) == "table"
        end,
        hasEventRegistry = function()
            return type(_getEventRegistryBestEffort()) == "table"
        end,
        getEventBus = function()
            return _getEventBusBestEffort()
        end,
        getEventRegistry = function()
            return _getEventRegistryBestEffort()
        end,
    }
end

-- ------------------------------------------------------------
-- Who diagnostics (delegated handlers; STATE.whoCapture stays here)
-- ------------------------------------------------------------
local function _getWhoDiagModuleBestEffort()
    local ok, mod = _safeRequire("dwkit.commands.who_diag")
    if ok and type(mod) == "table" then
        return mod
    end
    return nil
end

local function _makeWhoDiagCtx()
    return {
        out = function(line) _out(line) end,
        err = function(msg) _err(msg) end,
        ppTable = function(t, opts) _ppTable(t, opts) end,
        ppValue = function(v) return _ppValue(v) end,

        getWhoStoreService = function()
            return _getWhoStoreServiceBestEffort()
        end,
        getClipboardText = function()
            return _getClipboardTextBestEffort()
        end,

        printWhoStatus = function(svc)
            _printWhoStatus(svc)
        end,
    }
end

-- ------------------------------------------------------------
-- Global alias-id persistence + cleanup
-- ------------------------------------------------------------
local function _getGlobalAliasIds()
    if type(_G.DWKit) ~= "table" then return nil end
    local t = _G.DWKit[_GLOBAL_ALIAS_IDS_KEY]
    if type(t) == "table" then return t end
    return nil
end

local function _setGlobalAliasIds(t)
    if type(_G.DWKit) ~= "table" then return end
    _G.DWKit[_GLOBAL_ALIAS_IDS_KEY] = (type(t) == "table") and t or nil
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

local function _cleanupPriorAliasesBestEffort()
    local t = _getGlobalAliasIds()
    if type(t) ~= "table" then
        return true
    end
    if type(killAlias) ~= "function" then
        return true
    end

    local any = false
    for _, id in pairs(t) do
        if id ~= nil then
            any = true
            pcall(killAlias, id)
        end
    end

    _setGlobalAliasIds(nil)

    if any then
        _out("[DWKit Alias] cleaned up prior aliases (best-effort)")
    end
    return true
end

function M.isInstalled()
    return STATE.installed and true or false
end

function M.getState()
    local d = STATE.eventDiag
    local subCount = 0
    for _ in pairs((d and d.subs) or {}) do subCount = subCount + 1 end

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
            dwgui = STATE.aliasIds.dwgui,
            dwevents = STATE.aliasIds.dwevents,
            dwevent = STATE.aliasIds.dwevent,
            dwboot = STATE.aliasIds.dwboot,

            dwservices = STATE.aliasIds.dwservices,
            dwpresence = STATE.aliasIds.dwpresence,
            dwroom = STATE.aliasIds.dwroom,
            dwwho = STATE.aliasIds.dwwho,
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
            maxLog = (d and d.maxLog) or 50,
            logCount = #(d and d.log or {}),
            tapToken = d and d.tapToken or nil,
            subsCount = subCount,
        },
        lastError = STATE.lastError,
    }
end

function M.uninstall()
    -- CRITICAL: always try persisted cleanup (reload-safe)
    _cleanupPriorAliasesBestEffort()

    -- cancel pending capture sessions (legacy best-effort)
    _whoCaptureReset()
    _roomCaptureReset()

    -- Phase splits: reset extracted command modules (best-effort)
    do
        local okR, roomMod = _safeRequire("dwkit.commands.dwroom")
        if okR and type(roomMod) == "table" and type(roomMod.reset) == "function" then
            pcall(roomMod.reset)
        end
        local okW, whoMod = _safeRequire("dwkit.commands.dwwho")
        if okW and type(whoMod) == "table" and type(whoMod.reset) == "function" then
            pcall(whoMod.reset)
        end
        local okG, guiMod = _safeRequire("dwkit.commands.dwgui")
        if okG and type(guiMod) == "table" and type(guiMod.reset) == "function" then
            pcall(guiMod.reset)
        end
    end

    if not STATE.installed then
        STATE.lastError = nil
        return true, nil
    end

    if _hasEventBus() then
        local d = STATE.eventDiag
        if d and d.tapToken ~= nil and type(DWKit.bus.eventBus.tapOff) == "function" then
            pcall(DWKit.bus.eventBus.tapOff, d.tapToken)
            d.tapToken = nil
        end
        if d and type(DWKit.bus.eventBus.off) == "function" then
            for ev, tok in pairs(d.subs or {}) do
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
        ids.dwcommands, ids.dwhelp, ids.dwtest, ids.dwinfo, ids.dwid, ids.dwversion, ids.dwdiag, ids.dwgui,
        ids.dwevents, ids.dwevent, ids.dwboot,
        ids.dwservices, ids.dwpresence, ids.dwroom, ids.dwwho, ids.dwactions, ids.dwskills, ids.dwscorestore,
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
    _setGlobalAliasIds(nil)

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

    if type(tempAlias) ~= "function" then
        STATE.lastError = "tempAlias() not available"
        return false, STATE.lastError
    end

    -- Always cleanup persisted aliases first (safe across reloads)
    _cleanupPriorAliasesBestEffort()

    if STATE.installed then
        return true, nil
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

    local dwtestPattern = [[^dwtest(?:\s+(quiet|ui))?(?:\s+(verbose|v))?\s*$]]
    local id3 = _mkAlias(dwtestPattern, function()
        if not _hasTest() then
            _err("DWKit.test.run not available. Run loader.init() first.")
            return
        end

        local mode = (matches and matches[2]) and tostring(matches[2]) or ""
        local arg2 = (matches and matches[3]) and tostring(matches[3]) or ""

        if mode == "quiet" then
            DWKit.test.run({ quiet = true })
            return
        end

        if mode == "ui" then
            local verbose = (arg2 == "verbose" or arg2 == "v")

            local v = _getUiValidatorBestEffort()
            if type(v) ~= "table" then
                _err("dwkit.ui.ui_validator not available. Create src/dwkit/ui/ui_validator.lua first.")
                return
            end
            if type(v.validateAll) ~= "function" then
                _err("ui_validator.validateAll not available.")
                return
            end

            _out("[DWKit Test] UI Safety Gate (dwtest ui)")
            _out("  validator=" .. tostring(v.VERSION or "unknown"))
            _out("  mode=" .. (verbose and "verbose" or "compact"))
            _out("")

            local function firstMsgFrom(r)
                if type(r) ~= "table" then return nil end
                if type(r.errors) == "table" and #r.errors > 0 then return tostring(r.errors[1]) end
                if type(r.warnings) == "table" and #r.warnings > 0 then return tostring(r.warnings[1]) end
                if type(r.notes) == "table" and #r.notes > 0 then return tostring(r.notes[1]) end
                return nil
            end

            local function summarizeAll(details, opts)
                opts = (type(opts) == "table") and opts or {}
                local includeSkipInList = (opts.includeSkipInList == true)

                local resArr = nil
                if type(details) ~= "table" then
                    return { pass = 0, warn = 0, fail = 0, skip = 0, count = 0, list = {} }
                end

                if type(details.results) == "table" and _isArrayLike(details.results) then
                    resArr = details.results
                elseif type(details.details) == "table" and type(details.details.results) == "table" and _isArrayLike(details.details.results) then
                    resArr = details.details.results
                end

                local counts = { pass = 0, warn = 0, fail = 0, skip = 0, count = 0, list = {} }

                if type(resArr) ~= "table" then
                    return counts
                end

                counts.count = #resArr

                for _, r in ipairs(resArr) do
                    local st = (type(r) == "table" and type(r.status) == "string") and r.status or "UNKNOWN"
                    if st == "PASS" then
                        counts.pass = counts.pass + 1
                    elseif st == "WARN" then
                        counts.warn = counts.warn + 1
                        counts.list[#counts.list + 1] = r
                    elseif st == "FAIL" then
                        counts.fail = counts.fail + 1
                        counts.list[#counts.list + 1] = r
                    elseif st == "SKIP" then
                        counts.skip = counts.skip + 1
                        if includeSkipInList then
                            counts.list[#counts.list + 1] = r
                        end
                    else
                        counts.warn = counts.warn + 1
                        counts.list[#counts.list + 1] = r
                    end
                end

                return counts
            end

            local okCall, a, b, c, err = _callBestEffort(v, "validateAll", { source = "dwtest" })
            if not okCall then
                _err("validateAll failed: " .. tostring(err))
                return
            end
            if a ~= true then
                local msg = b or c or err or "validateAll failed"
                _err(tostring(msg))
                return
            end

            if verbose then
                _out("[DWKit Test] UI validateAll details (bounded)")
                _ppTable(b, { maxDepth = 3, maxItems = 40 })
                if type(b) == "table" and tonumber(b.count or 0) == 0 then
                    _out("")
                    _printNoUiNote("dwtest ui")
                end
                return
            end

            local cts = summarizeAll(b, { includeSkipInList = false })
            _out(string.format("[DWKit Test] UI summary: PASS=%d WARN=%d FAIL=%d SKIP=%d total=%d",
                cts.pass, cts.warn, cts.fail, cts.skip, cts.count))

            if cts.count == 0 then
                _out("")
                _printNoUiNote("dwtest ui")
                return
            end

            if #cts.list > 0 then
                _out("")
                _out("[DWKit Test] UI WARN/FAIL (compact)")
                local limit = math.min(#cts.list, 25)
                for i = 1, limit do
                    local r = cts.list[i]
                    local st = tostring(r.status or "UNKNOWN")
                    local id = tostring(r.uiId or "?")
                    local msg = firstMsgFrom(r) or ""
                    if msg ~= "" then
                        _out(string.format("  - %s  uiId=%s  msg=%s", st, id, msg))
                    else
                        _out(string.format("  - %s  uiId=%s", st, id))
                    end
                end
                if #cts.list > limit then
                    _out("  ... (" .. tostring(#cts.list - limit) .. " more)")
                end
            end

            return
        end

        if arg2 ~= "" then
            _err("Usage: dwtest [quiet|ui] [verbose]")
            return
        end

        DWKit.test.run()
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

    -- Phase 1 split: dwroom delegates to dwkit.commands.dwroom
    local dwroomPattern = [[^dwroom(?:\s+(status|clear|ingestclip|fixture|refresh))?(?:\s+(\S+))?\s*$]]
    local id11b = _mkAlias(dwroomPattern, function()
        local svc = _getRoomEntitiesServiceBestEffort()
        if type(svc) ~= "table" then
            _err("RoomEntitiesService not available. Run loader.init() first.")
            return
        end

        local sub = (matches and matches[2]) and tostring(matches[2]) or ""
        local arg = (matches and matches[3]) and tostring(matches[3]) or ""

        local okM, mod = _safeRequire("dwkit.commands.dwroom")
        if not okM or type(mod) ~= "table" or type(mod.dispatch) ~= "function" then
            _err("dwkit.commands.dwroom not available. Ensure src/dwkit/commands/dwroom.lua exists.")
            return
        end

        local ctx = {
            out = function(line) _out(line) end,
            err = function(msg) _err(msg) end,
            callBestEffort = function(obj, fnName, ...) return _callBestEffort(obj, fnName, ...) end,
            getClipboardText = function() return _getClipboardTextBestEffort() end,
            resolveSendFn = function() return _resolveSendFn() end,
            looksLikePrompt = function(line) return _looksLikePrompt(line) end,
            killTrigger = function(id) _killTriggerBestEffort(id) end,
            killTimer = function(id) _killTimerBestEffort(id) end,
            tempRegexTrigger = function(pat, fn) return tempRegexTrigger(pat, fn) end,
            tempTimer = function(sec, fn) return tempTimer(sec, fn) end,
            printRoomEntitiesStatus = function(s) _printRoomEntitiesStatus(s) end,
        }

        local okCall, errOrNil = pcall(mod.dispatch, ctx, svc, sub, arg)
        if not okCall then
            _err("dwroom handler threw error: " .. tostring(errOrNil))
        end
    end)

    -- Phase 1 split: dwwho delegates to dwkit.commands.dwwho
    local dwwhoPattern = [[^dwwho(?:\s+(status|clear|ingestclip|fixture|refresh))?\s*$]]
    local id11c = _mkAlias(dwwhoPattern, function()
        local svc = _getWhoStoreServiceBestEffort()
        local sub = (matches and matches[2]) and tostring(matches[2]) or ""

        if type(svc) ~= "table" then
            _err(
                "WhoStoreService not available or incomplete. Create/repair src/dwkit/services/whostore_service.lua, then loader.init().")
            return
        end

        local okM, mod = _safeRequire("dwkit.commands.dwwho")
        if not okM or type(mod) ~= "table" or type(mod.dispatch) ~= "function" then
            _err("dwkit.commands.dwwho not available. Ensure src/dwkit/commands/dwwho.lua exists.")
            return
        end

        local ctx = {
            out = function(line) _out(line) end,
            err = function(msg) _err(msg) end,
            callBestEffort = function(obj, fnName, ...) return _callBestEffort(obj, fnName, ...) end,
            getClipboardText = function() return _getClipboardTextBestEffort() end,
            resolveSendFn = function() return _resolveSendFn() end,
            killTrigger = function(id) _killTriggerBestEffort(id) end,
            killTimer = function(id) _killTimerBestEffort(id) end,
            tempRegexTrigger = function(pat, fn) return tempRegexTrigger(pat, fn) end,
            tempTimer = function(sec, fn) return tempTimer(sec, fn) end,
            whoIngestTextBestEffort = function(s, text, meta) return _whoIngestTextBestEffort(s, text, meta) end,
            printWhoStatus = function(s) _printWhoStatus(s) end,
        }

        local okCall, errOrNil = pcall(mod.dispatch, ctx, svc, sub)
        if not okCall then
            _err("dwwho handler threw error: " .. tostring(errOrNil))
        end
    end)

    local dwactionsPattern = [[^dwactions\s*$]]
    local id12 = _mkAlias(dwactionsPattern, function()
        _printServiceSnapshot("ActionModelService", "actionModelService")
    end)

    local dwskillsPattern = [[^dwskills\s*$]]
    local id13 = _mkAlias(dwskillsPattern, function()
        _printServiceSnapshot("SkillRegistryService", "skillRegistryService")
    end)

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

        local mod = _getEventDiagModuleBestEffort()
        if type(mod) ~= "table" then
            _err("dwkit.commands.event_diag not available. Ensure src/dwkit/commands/event_diag.lua exists.")
            return
        end

        local ctx = _makeEventDiagCtx()
        local d = STATE.eventDiag

        local function call(fnName, ...)
            if type(mod[fnName]) ~= "function" then
                _err("event_diag." .. tostring(fnName) .. " not available")
                return
            end
            local okCall, errOrNil = pcall(mod[fnName], ctx, d, ...)
            if not okCall then
                _err("event_diag." .. tostring(fnName) .. " threw error: " .. tostring(errOrNil))
            end
        end

        if mode == "" or mode == "status" then
            call("printStatus")
            return
        end
        if mode == "on" then
            call("tapOn")
            return
        end
        if mode == "off" then
            call("tapOff")
            return
        end
        if mode == "show" then
            call("printLog", n)
            return
        end
        if mode == "clear" then
            call("logClear")
            return
        end

        _err("Usage: dweventtap [on|off|status|show|clear] [n]")
    end)

    local dweventsubPattern = [[^dweventsub\s+(\S+)\s*$]]
    local id16 = _mkAlias(dweventsubPattern, function()
        local evName = (matches and matches[2]) and tostring(matches[2]) or ""

        local mod = _getEventDiagModuleBestEffort()
        if type(mod) ~= "table" then
            _err("dwkit.commands.event_diag not available. Ensure src/dwkit/commands/event_diag.lua exists.")
            return
        end

        local ctx = _makeEventDiagCtx()
        local d = STATE.eventDiag

        if type(mod.subOn) ~= "function" then
            _err("event_diag.subOn not available")
            return
        end

        local okCall, errOrNil = pcall(mod.subOn, ctx, d, evName)
        if not okCall then
            _err("event_diag.subOn threw error: " .. tostring(errOrNil))
        end
    end)

    local dweventunsubPattern = [[^dweventunsub\s+(\S+)\s*$]]
    local id17 = _mkAlias(dweventunsubPattern, function()
        local evName = (matches and matches[2]) and tostring(matches[2]) or ""

        local mod = _getEventDiagModuleBestEffort()
        if type(mod) ~= "table" then
            _err("dwkit.commands.event_diag not available. Ensure src/dwkit/commands/event_diag.lua exists.")
            return
        end

        local ctx = _makeEventDiagCtx()
        local d = STATE.eventDiag

        if type(mod.subOff) ~= "function" then
            _err("event_diag.subOff not available")
            return
        end

        local okCall, errOrNil = pcall(mod.subOff, ctx, d, evName)
        if not okCall then
            _err("event_diag.subOff threw error: " .. tostring(errOrNil))
        end
    end)

    local dweventlogPattern = [[^dweventlog(?:\s+(\d+))?\s*$]]
    local id18 = _mkAlias(dweventlogPattern, function()
        local n = (matches and matches[2]) and tostring(matches[2]) or ""

        local mod = _getEventDiagModuleBestEffort()
        if type(mod) ~= "table" then
            _err("dwkit.commands.event_diag not available. Ensure src/dwkit/commands/event_diag.lua exists.")
            return
        end

        local ctx = _makeEventDiagCtx()
        local d = STATE.eventDiag

        if type(mod.printLog) ~= "function" then
            _err("event_diag.printLog not available")
            return
        end

        local okCall, errOrNil = pcall(mod.printLog, ctx, d, n)
        if not okCall then
            _err("event_diag.printLog threw error: " .. tostring(errOrNil))
        end
    end)

    local dwdiagPattern = [[^dwdiag\s*$]]
    local id19 = _mkAlias(dwdiagPattern, function()
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
        local mod = _getEventDiagModuleBestEffort()
        if type(mod) == "table" and type(mod.printStatus) == "function" then
            local okCall, errOrNil = pcall(mod.printStatus, _makeEventDiagCtx(), STATE.eventDiag)
            if not okCall then
                _err("event_diag.printStatus threw error: " .. tostring(errOrNil))
            end
        else
            _err("dwkit.commands.event_diag not available (cannot print event diag status)")
        end
    end)

    -- dwgui: SAFE config + optional lifecycle helpers
    -- Phase 2 split: delegates to dwkit.commands.dwgui when available, with fallback here.
    local dwguiPattern =
    [[^dwgui(?:\s+(status|list|enable|disable|visible|validate|apply|dispose|reload|state))?(?:\s+(\S+))?(?:\s+(\S+))?\s*$]]
    local id20a = _mkAlias(dwguiPattern, function()
        local gs = _getGuiSettingsBestEffort()
        if type(gs) ~= "table" then
            _err("DWKit.config.guiSettings not available. Run loader.init() first.")
            return
        end

        local alreadyLoaded = false
        if type(gs.isLoaded) == "function" then
            local okLoaded, v = pcall(gs.isLoaded)
            alreadyLoaded = (okLoaded and v == true)
        end

        if (not alreadyLoaded) and type(gs.load) == "function" then
            pcall(gs.load, { quiet = true })
        end

        -- IMPORTANT: Mudlet optional capture groups can leave stale matches[n] values.
        -- Use matches[1] (the full line) and tokenize instead.
        local line = (matches and matches[1]) and tostring(matches[1]) or ""
        local tokens = {}
        for w in line:gmatch("%S+") do
            tokens[#tokens + 1] = w
        end

        -- tokens[1] = "dwgui"
        local sub  = tokens[2] or ""
        local uiId = tokens[3] or ""
        local arg3 = tokens[4] or ""

        -- Try delegated handler FIRST (best-effort).
        -- Signature tolerance:
        --   dispatch(ctx, gs, sub, uiId, arg3)
        --   dispatch(ctx, sub, uiId, arg3)
        do
            local okM, mod = _safeRequire("dwkit.commands.dwgui")
            if okM and type(mod) == "table" and type(mod.dispatch) == "function" then
                local ctx = {
                    out = function(line2) _out(line2) end,
                    err = function(msg) _err(msg) end,
                    ppTable = function(t, opts) _ppTable(t, opts) end,
                    callBestEffort = function(obj, fnName, ...) return _callBestEffort(obj, fnName, ...) end,

                    getGuiSettings = function() return gs end,
                    getUiValidator = function() return _getUiValidatorBestEffort() end,
                    printGuiStatusAndList = function(x) _printGuiStatusAndList(x) end,
                    printNoUiNote = function(context) _printNoUiNote(context) end,

                    safeRequire = function(name) return _safeRequire(name) end,
                }

                local ok1, err1 = pcall(mod.dispatch, ctx, gs, sub, uiId, arg3)
                if ok1 then
                    return
                end

                local ok2, err2 = pcall(mod.dispatch, ctx, sub, uiId, arg3)
                if ok2 then
                    return
                end

                -- If delegation fails, we fall back to inline legacy handler below.
                _out("[DWKit GUI] NOTE: dwgui delegate failed; falling back to inline handler")
                _out("  err1=" .. tostring(err1))
                _out("  err2=" .. tostring(err2))
            end
        end

        -- Inline fallback (legacy behaviour)
        local function usage()
            _out("[DWKit GUI] Usage:")
            _out("  dwgui")
            _out("  dwgui status")
            _out("  dwgui list")
            _out("  dwgui enable <uiId>")
            _out("  dwgui disable <uiId>")
            _out("  dwgui visible <uiId> on|off")
            _out("  dwgui validate")
            _out("  dwgui validate enabled")
            _out("  dwgui validate <uiId>")
            _out("  dwgui apply")
            _out("  dwgui apply <uiId>")
            _out("  dwgui dispose <uiId>")
            _out("  dwgui reload")
            _out("  dwgui reload <uiId>")
            _out("  dwgui state <uiId>")
        end

        if sub == "" or sub == "status" or sub == "list" then
            _printGuiStatusAndList(gs)
            return
        end

        if (sub == "enable" or sub == "disable") then
            if uiId == "" then
                usage()
                return
            end
            if type(gs.setEnabled) ~= "function" then
                _err("guiSettings.setEnabled not available.")
                return
            end
            local enable = (sub == "enable")
            local okCall, errOrNil = pcall(gs.setEnabled, uiId, enable)
            if not okCall then
                _err("setEnabled failed: " .. tostring(errOrNil))
                return
            end
            _out(string.format("[DWKit GUI] setEnabled uiId=%s enabled=%s", tostring(uiId), enable and "ON" or "OFF"))
            return
        end

        if sub == "visible" then
            if uiId == "" or (arg3 ~= "on" and arg3 ~= "off") then
                usage()
                return
            end
            if type(gs.setVisible) ~= "function" then
                _err("guiSettings.setVisible not available.")
                return
            end
            local vis = (arg3 == "on")
            local okCall, errOrNil = pcall(gs.setVisible, uiId, vis)
            if not okCall then
                _err("setVisible failed: " .. tostring(errOrNil))
                return
            end
            _out(string.format("[DWKit GUI] setVisible uiId=%s visible=%s", tostring(uiId), vis and "ON" or "OFF"))
            return
        end

        if sub == "validate" then
            local v = _getUiValidatorBestEffort()
            if type(v) ~= "table" or type(v.validateAll) ~= "function" then
                _err("dwkit.ui.ui_validator.validateAll not available.")
                return
            end

            local target = uiId
            local verbose = (arg3 == "verbose" or uiId == "verbose")

            -- validate enabled shortcut
            if uiId == "enabled" then
                target = "enabled"
            end

            if target == "" then
                local okCall, a, b, c, err = _callBestEffort(v, "validateAll", { source = "dwgui" })
                if not okCall or a ~= true then
                    _err("validateAll failed: " .. tostring(b or c or err))
                    return
                end
                if verbose then
                    _ppTable(b, { maxDepth = 3, maxItems = 40 })
                else
                    _out("[DWKit GUI] validateAll OK")
                end
                return
            end

            if target == "enabled" and type(v.validateEnabled) == "function" then
                local okCall, a, b, c, err = _callBestEffort(v, "validateEnabled", { source = "dwgui" })
                if not okCall or a ~= true then
                    _err("validateEnabled failed: " .. tostring(b or c or err))
                    return
                end
                if verbose then
                    _ppTable(b, { maxDepth = 3, maxItems = 40 })
                else
                    _out("[DWKit GUI] validateEnabled OK")
                end
                return
            end

            if target ~= "" and type(v.validateOne) == "function" then
                local okCall, a, b, c, err = _callBestEffort(v, "validateOne", target, { source = "dwgui" })
                if not okCall or a ~= true then
                    _err("validateOne failed: " .. tostring(b or c or err))
                    return
                end
                if verbose then
                    _ppTable(b, { maxDepth = 3, maxItems = 40 })
                else
                    _out("[DWKit GUI] validateOne OK uiId=" .. tostring(target))
                end
                return
            end

            _err("validate target unsupported (missing validateEnabled/validateOne)")
            return
        end

        if sub == "apply" or sub == "dispose" or sub == "reload" or sub == "state" then
            local okUM, um = _safeRequire("dwkit.ui.ui_manager")
            if not okUM or type(um) ~= "table" then
                _err("dwkit.ui.ui_manager not available.")
                return
            end

            local function callAny(fnNames, ...)
                for _, fn in ipairs(fnNames or {}) do
                    if type(um[fn]) == "function" then
                        local okCall, errOrNil = pcall(um[fn], ...)
                        if not okCall then
                            _err("ui_manager." .. tostring(fn) .. " failed: " .. tostring(errOrNil))
                        end
                        return true
                    end
                end
                return false
            end

            if sub == "apply" then
                if uiId == "" then
                    if callAny({ "applyAll" }, { source = "dwgui" }) then return end
                else
                    if callAny({ "applyOne" }, uiId, { source = "dwgui" }) then return end
                end
                _err("ui_manager apply not supported")
                return
            end

            if sub == "dispose" then
                if uiId == "" then
                    usage()
                    return
                end
                if callAny({ "disposeOne" }, uiId, { source = "dwgui" }) then return end
                _err("ui_manager.disposeOne not supported")
                return
            end

            if sub == "reload" then
                if uiId == "" then
                    if callAny({ "reloadAllEnabled", "reloadAll" }, { source = "dwgui" }) then return end
                else
                    if callAny({ "reloadOne" }, uiId, { source = "dwgui" }) then return end
                end
                _err("ui_manager reload not supported")
                return
            end

            if sub == "state" then
                if uiId == "" then
                    usage()
                    return
                end
                if callAny({ "printState", "stateOne" }, uiId) then return end
                _err("ui_manager state not supported")
                return
            end
        end

        usage()
    end)

    local dwreleasePattern = [[^dwrelease\s*$]]
    local id20 = _mkAlias(dwreleasePattern, function()
        _printReleaseChecklist()
    end)

    local all = {
        id1, id2, id3, id4, id5, id6, id7, id8, id9,
        id10, id11, id11b, id11c, id12, id13, id14,
        id15, id16, id17, id18, id19,
        id20a, id20
    }

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
    STATE.aliasIds.dwroom       = id11b
    STATE.aliasIds.dwwho        = id11c
    STATE.aliasIds.dwactions    = id12
    STATE.aliasIds.dwskills     = id13
    STATE.aliasIds.dwscorestore = id14

    STATE.aliasIds.dweventtap   = id15
    STATE.aliasIds.dweventsub   = id16
    STATE.aliasIds.dweventunsub = id17
    STATE.aliasIds.dweventlog   = id18

    STATE.aliasIds.dwdiag       = id19
    STATE.aliasIds.dwgui        = id20a
    STATE.aliasIds.dwrelease    = id20

    STATE.installed             = true
    STATE.lastError             = nil

    _setGlobalAliasIds({
        dwcommands   = id1,
        dwhelp       = id2,
        dwtest       = id3,
        dwinfo       = id4,
        dwid         = id5,
        dwversion    = id6,
        dwevents     = id7,
        dwevent      = id8,
        dwboot       = id9,
        dwservices   = id10,
        dwpresence   = id11,
        dwroom       = id11b,
        dwwho        = id11c,
        dwactions    = id12,
        dwskills     = id13,
        dwscorestore = id14,
        dweventtap   = id15,
        dweventsub   = id16,
        dweventunsub = id17,
        dweventlog   = id18,
        dwdiag       = id19,
        dwgui        = id20a,
        dwrelease    = id20,
    })

    if not opts.quiet then
        _out(
            "[DWKit Alias] Installed: dwcommands, dwhelp, dwtest, dwinfo, dwid, dwversion, dwevents, dwevent, dwboot, dwservices, dwpresence, dwroom, dwwho, dwactions, dwskills, dwscorestore, dweventtap, dweventsub, dweventunsub, dweventlog, dwdiag, dwgui, dwrelease")
    end

    return true, nil
end

return M
