-- #########################################################################
-- Module Name : dwkit.services.command_aliases
-- Owner       : Services
-- Version     : v2026-01-26F
-- Purpose     :
--   - Install SAFE Mudlet aliases for DWKit commands.
--   - AUTO-GENERATES SAFE aliases from the Command Registry (best-effort).
--   - Keeps only a small set of "special-case" aliases that require:
--       * service injection (dwwho/dwroom)
--       * module state injection (event diag: dweventtap/sub/unsub/log)
--       * router dispatch (dwgui/dwscorestore/dwrelease)
--       * event diag bundle access (dwdiag)
--
-- IMPORTANT:
--   - tempAlias objects persist in Mudlet even if this module is reloaded via package.loaded=nil.
--   - This module stores alias ids in _G.DWKit._commandAliasesAliasIds and cleans them up on install()
--     and uninstall(), preventing duplicate alias execution/output across reloads.
--
-- Public API  :
--   - install(opts?) -> boolean ok, string|nil err
--   - uninstall() -> boolean ok, string|nil err
--   - isInstalled() -> boolean
--   - getState() -> table copy
-- #########################################################################

local M = {}

M.VERSION = "v2026-01-26F"

local _GLOBAL_ALIAS_IDS_KEY = "_commandAliasesAliasIds"

local STATE = {
    installed = false,

    -- aliasIds is dynamic (auto-generated):
    --   { [cmdName] = <aliasId>, ... }
    aliasIds = {},

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

-- IMPORTANT:
-- Mudlet alias callbacks set `matches[]` such that:
--   - matches[0] is the full matched line (when provided)
--   - matches[1..n] are capture groups
-- For patterns with captures, matches[1] is NOT the full line.
local function _getFullMatchLine()
    if type(matches) == "table" then
        if matches[0] ~= nil then
            return tostring(matches[0])
        end
        if matches[1] ~= nil then
            return tostring(matches[1])
        end
    end
    return ""
end

local function _tokenize(line)
    line = tostring(line or "")
    local tokens = {}
    for w in line:gmatch("%S+") do
        tokens[#tokens + 1] = w
    end
    return tokens
end

local function _tokenizeFromMatches()
    return _tokenize(_getFullMatchLine())
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

-- Best-effort DWKit resolver for alias callback environments
local function _getKit()
    if type(_G) == "table" and type(_G.DWKit) == "table" then
        return _G.DWKit
    end
    if type(DWKit) == "table" then
        return DWKit
    end
    return nil
end

local function _hasCmd()
    local kit = _getKit()
    return type(kit) == "table" and type(kit.cmd) == "table"
end

local function _hasEventRegistry()
    local kit = _getKit()
    return type(kit) == "table"
        and type(kit.bus) == "table"
        and type(kit.bus.eventRegistry) == "table"
        and type(kit.bus.eventRegistry.listAll) == "function"
end

local function _hasEventBus()
    local kit = _getKit()
    return type(kit) == "table"
        and type(kit.bus) == "table"
        and type(kit.bus.eventBus) == "table"
end

local function _getService(name)
    local kit = _getKit()
    if type(kit) ~= "table" or type(kit.services) ~= "table" then return nil end
    local s = kit.services[name]
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

-- ------------------------------------------------------------
-- Legacy printers + pp helpers (extracted)
-- ------------------------------------------------------------
local function _getLegacyBestEffort()
    local ok, mod = _safeRequire("dwkit.commands.alias_legacy")
    if ok and type(mod) == "table" then return mod end
    return nil
end

local function _makeLegacyCtx()
    return {
        out = function(line) _out(line) end,
        err = function(msg) _err(msg) end,
        safeRequire = function(name) return _safeRequire(name) end,
        callBestEffort = function(obj, fnName, ...) return _callBestEffort(obj, fnName, ...) end,
        getKit = function() return _getKit() end,
        sortedKeys = function(t) return _sortedKeys(t) end,
    }
end

local function _legacyPpValue(v)
    local L = _getLegacyBestEffort()
    if L and type(L.ppValue) == "function" then
        return L.ppValue(v)
    end
    return tostring(v)
end

local function _legacyPpTable(t, opts)
    local L = _getLegacyBestEffort()
    if L and type(L.ppTable) == "function" then
        return L.ppTable(_makeLegacyCtx(), t, opts)
    end
    _out(tostring(t))
end

local function _legacyPrintIdentity()
    local L = _getLegacyBestEffort()
    if L and type(L.printIdentity) == "function" then
        return L.printIdentity(_makeLegacyCtx())
    end
    _err("alias_legacy.printIdentity not available")
end

local function _legacyPrintVersionSummary()
    local L = _getLegacyBestEffort()
    if L and type(L.printVersionSummary) == "function" then
        return L.printVersionSummary(_makeLegacyCtx(), M.VERSION)
    end
    _err("alias_legacy.printVersionSummary not available")
end

local function _legacyPrintBootHealth()
    local L = _getLegacyBestEffort()
    if L and type(L.printBootHealth) == "function" then
        return L.printBootHealth(_makeLegacyCtx())
    end
    _err("alias_legacy.printBootHealth not available")
end

local function _legacyPrintServicesHealth()
    local L = _getLegacyBestEffort()
    if L and type(L.printServicesHealth) == "function" then
        return L.printServicesHealth(_makeLegacyCtx())
    end
    _err("alias_legacy.printServicesHealth not available")
end

local function _legacyPrintServiceSnapshot(label, svcName)
    local svc = _getService(svcName)
    local L = _getLegacyBestEffort()
    if L and type(L.printServiceSnapshot) == "function" then
        return L.printServiceSnapshot(_makeLegacyCtx(), label, svc)
    end
    _err("alias_legacy.printServiceSnapshot not available")
end

-- ------------------------------------------------------------
-- Clipboard helper
-- ------------------------------------------------------------
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

-- Best-effort prompt detector for Deathwish style prompts
local function _looksLikePrompt(line)
    line = tostring(line or "")
    if line == "" then return false end

    if line:match("^%s*<?%d+%(%d+%)Hp") then
        return true
    end

    if line:match(">%s*$") and line:match("Hp") and line:match("Mp") then
        return true
    end

    return false
end

-- ------------------------------------------------------------
-- WhoStore / RoomEntities service resolvers (best-effort)
-- ------------------------------------------------------------
local function _getRoomEntitiesServiceBestEffort()
    local svc = _getService("roomEntitiesService")
    if type(svc) == "table" then return svc end
    local ok, mod = _safeRequire("dwkit.services.roomentities_service")
    if ok and type(mod) == "table" then return mod end
    return nil
end

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

-- ------------------------------------------------------------
-- Who/Room capture (manual state; legacy kept for compatibility)
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

-- ------------------------------------------------------------
-- Event diagnostics helpers (STATE.eventDiag injection)
-- ------------------------------------------------------------
local function _getEventBusBestEffort()
    local kit = _getKit()
    if type(kit) == "table" and type(kit.bus) == "table" and type(kit.bus.eventBus) == "table" then
        return kit.bus.eventBus
    end
    local ok, mod = _safeRequire("dwkit.bus.event_bus")
    if ok and type(mod) == "table" then
        return mod
    end
    return nil
end

local function _getEventRegistryBestEffort()
    local kit = _getKit()
    if type(kit) == "table" and type(kit.bus) == "table" and type(kit.bus.eventRegistry) == "table" then
        return kit.bus.eventRegistry
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
        ppTable = function(t, opts) _legacyPpTable(t, opts) end,
        ppValue = function(v) return _legacyPpValue(v) end,
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
-- Router ctx (used by routered aliases)
-- ------------------------------------------------------------
local function _makeRouterCtx()
    return {
        out = function(line) _out(line) end,
        err = function(msg) _err(msg) end,
        ppTable = function(t, opts) _legacyPpTable(t, opts) end,
        ppValue = function(v) return _legacyPpValue(v) end,
        safeRequire = function(name) return _safeRequire(name) end,
        callBestEffort = function(obj, fnName, ...) return _callBestEffort(obj, fnName, ...) end,
        getService = function(name) return _getService(name) end,
        sortedKeys = function(t) return _sortedKeys(t) end,

        getClipboardText = function() return _getClipboardTextBestEffort() end,
        resolveSendFn = function() return _resolveSendFn() end,
        looksLikePrompt = function(line) return _looksLikePrompt(line) end,
        killTrigger = function(id) _killTriggerBestEffort(id) end,
        killTimer = function(id) _killTimerBestEffort(id) end,
    }
end

local function _getScoreStoreServiceBestEffort()
    local svc = _getService("scoreStoreService")
    if type(svc) == "table" then return svc end
    local ok, mod = _safeRequire("dwkit.services.score_store_service")
    if ok and type(mod) == "table" then return mod end
    return nil
end

local function _getGuiSettingsBestEffort()
    local kit = _getKit()
    if type(kit) == "table" and type(kit.config) == "table" and type(kit.config.guiSettings) == "table" then
        return kit.config.guiSettings
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

-- ------------------------------------------------------------
-- Router dispatch table (dwgui/dwscorestore/dwrelease)
-- ------------------------------------------------------------
local function _dispatch_dwgui(ctx, kit, tokens)
    local gs = _getGuiSettingsBestEffort()
    if type(gs) ~= "table" then
        ctx.err("DWKit.config.guiSettings not available. Run loader.init() first.")
        return true
    end

    local alreadyLoaded = false
    if type(gs.isLoaded) == "function" then
        local okLoaded, v = pcall(gs.isLoaded)
        alreadyLoaded = (okLoaded and v == true)
    end

    if (not alreadyLoaded) and type(gs.load) == "function" then
        pcall(gs.load, { quiet = true })
    end

    local sub  = tokens[2] or ""
    local uiId = tokens[3] or ""
    local arg3 = tokens[4] or ""

    -- Delegate FIRST (best-effort).
    do
        local okM, mod = _safeRequire("dwkit.commands.dwgui")
        if okM and type(mod) == "table" and type(mod.dispatch) == "function" then
            local dctx = {
                out = ctx.out,
                err = ctx.err,
                ppTable = ctx.ppTable,
                callBestEffort = ctx.callBestEffort,

                getGuiSettings = function() return gs end,
                getUiValidator = function() return _getUiValidatorBestEffort() end,
                printGuiStatusAndList = function(x) _printGuiStatusAndList(x) end,
                printNoUiNote = function(context) _printNoUiNote(context) end,

                safeRequire = ctx.safeRequire,
            }

            local ok1, err1 = pcall(mod.dispatch, dctx, gs, sub, uiId, arg3)
            if ok1 then
                return true
            end

            local ok2, err2 = pcall(mod.dispatch, dctx, sub, uiId, arg3)
            if ok2 then
                return true
            end

            ctx.out("[DWKit GUI] NOTE: dwgui delegate failed; falling back to inline handler")
            ctx.out("  err1=" .. tostring(err1))
            ctx.out("  err2=" .. tostring(err2))
        end
    end

    -- Inline fallback (legacy behaviour)
    local function usage()
        ctx.out("[DWKit GUI] Usage:")
        ctx.out("  dwgui")
        ctx.out("  dwgui status")
        ctx.out("  dwgui list")
        ctx.out("  dwgui enable <uiId>")
        ctx.out("  dwgui disable <uiId>")
        ctx.out("  dwgui visible <uiId> on|off")
        ctx.out("  dwgui validate")
        ctx.out("  dwgui validate enabled")
        ctx.out("  dwgui validate <uiId>")
        ctx.out("  dwgui apply")
        ctx.out("  dwgui apply <uiId>")
        ctx.out("  dwgui dispose <uiId>")
        ctx.out("  dwgui reload")
        ctx.out("  dwgui reload <uiId>")
        ctx.out("  dwgui state <uiId>")
    end

    if sub == "" or sub == "status" or sub == "list" then
        _printGuiStatusAndList(gs)
        return true
    end

    if (sub == "enable" or sub == "disable") then
        if uiId == "" then
            usage()
            return true
        end
        if type(gs.setEnabled) ~= "function" then
            ctx.err("guiSettings.setEnabled not available.")
            return true
        end
        local enable = (sub == "enable")
        local okCall, errOrNil = pcall(gs.setEnabled, uiId, enable)
        if not okCall then
            ctx.err("setEnabled failed: " .. tostring(errOrNil))
            return true
        end
        ctx.out(string.format("[DWKit GUI] setEnabled uiId=%s enabled=%s", tostring(uiId), enable and "ON" or "OFF"))
        return true
    end

    if sub == "visible" then
        if uiId == "" or (arg3 ~= "on" and arg3 ~= "off") then
            usage()
            return true
        end
        if type(gs.setVisible) ~= "function" then
            ctx.err("guiSettings.setVisible not available.")
            return true
        end
        local vis = (arg3 == "on")
        local okCall, errOrNil = pcall(gs.setVisible, uiId, vis)
        if not okCall then
            ctx.err("setVisible failed: " .. tostring(errOrNil))
            return true
        end
        ctx.out(string.format("[DWKit GUI] setVisible uiId=%s visible=%s", tostring(uiId), vis and "ON" or "OFF"))
        return true
    end

    if sub == "validate" then
        local v = _getUiValidatorBestEffort()
        if type(v) ~= "table" or type(v.validateAll) ~= "function" then
            ctx.err("dwkit.ui.ui_validator.validateAll not available.")
            return true
        end

        local target = uiId
        local verbose = (arg3 == "verbose" or uiId == "verbose")

        if uiId == "enabled" then
            target = "enabled"
        end

        if target == "" then
            local okCall, a, b, c, err = _callBestEffort(v, "validateAll", { source = "dwgui" })
            if not okCall or a ~= true then
                ctx.err("validateAll failed: " .. tostring(b or c or err))
                return true
            end
            if verbose then
                _legacyPpTable(b, { maxDepth = 3, maxItems = 40 })
            else
                ctx.out("[DWKit GUI] validateAll OK")
            end
            return true
        end

        if target == "enabled" and type(v.validateEnabled) == "function" then
            local okCall, a, b, c, err = _callBestEffort(v, "validateEnabled", { source = "dwgui" })
            if not okCall or a ~= true then
                ctx.err("validateEnabled failed: " .. tostring(b or c or err))
                return true
            end
            if verbose then
                _legacyPpTable(b, { maxDepth = 3, maxItems = 40 })
            else
                ctx.out("[DWKit GUI] validateEnabled OK")
            end
            return true
        end

        if target ~= "" and type(v.validateOne) == "function" then
            local okCall, a, b, c, err = _callBestEffort(v, "validateOne", target, { source = "dwgui" })
            if not okCall or a ~= true then
                ctx.err("validateOne failed: " .. tostring(b or c or err))
                return true
            end
            if verbose then
                _legacyPpTable(b, { maxDepth = 3, maxItems = 40 })
            else
                ctx.out("[DWKit GUI] validateOne OK uiId=" .. tostring(target))
            end
            return true
        end

        ctx.err("validate target unsupported (missing validateEnabled/validateOne)")
        return true
    end

    if sub == "apply" or sub == "dispose" or sub == "reload" or sub == "state" then
        local okUM, um = _safeRequire("dwkit.ui.ui_manager")
        if not okUM or type(um) ~= "table" then
            ctx.err("dwkit.ui.ui_manager not available.")
            return true
        end

        local function callAny(fnNames, ...)
            for _, fn in ipairs(fnNames or {}) do
                if type(um[fn]) == "function" then
                    local okCall, errOrNil = pcall(um[fn], ...)
                    if not okCall then
                        ctx.err("ui_manager." .. tostring(fn) .. " failed: " .. tostring(errOrNil))
                    end
                    return true
                end
            end
            return false
        end

        if sub == "apply" then
            if uiId == "" then
                if callAny({ "applyAll" }, { source = "dwgui" }) then return true end
            else
                if callAny({ "applyOne" }, uiId, { source = "dwgui" }) then return true end
            end
            ctx.err("ui_manager apply not supported")
            return true
        end

        if sub == "dispose" then
            if uiId == "" then
                usage()
                return true
            end
            if callAny({ "disposeOne" }, uiId, { source = "dwgui" }) then return true end
            ctx.err("ui_manager.disposeOne not supported")
            return true
        end

        if sub == "reload" then
            if uiId == "" then
                if callAny({ "reloadAllEnabled", "reloadAll" }, { source = "dwgui" }) then return true end
            else
                if callAny({ "reloadOne" }, uiId, { source = "dwgui" }) then return true end
            end
            ctx.err("ui_manager reload not supported")
            return true
        end

        if sub == "state" then
            if uiId == "" then
                usage()
                return true
            end
            if callAny({ "printState", "stateOne" }, uiId) then return true end
            ctx.err("ui_manager state not supported")
            return true
        end
    end

    usage()
    return true
end

local function _dispatch_dwscorestore(ctx, kit, tokens)
    local svc = _getScoreStoreServiceBestEffort()
    if type(svc) ~= "table" then
        ctx.err("ScoreStoreService not available. Run loader.init() first.")
        return true
    end

    local sub = tokens[2] or ""
    local arg = tokens[3] or ""

    local okM, mod = _safeRequire("dwkit.commands.dwscorestore")
    if okM and type(mod) == "table" and type(mod.dispatch) == "function" then
        local dctx = {
            out = ctx.out,
            err = ctx.err,
            callBestEffort = ctx.callBestEffort,
        }

        local ok1, err1 = pcall(mod.dispatch, dctx, svc, sub, arg)
        if ok1 then
            return true
        end

        local ok2, err2 = pcall(mod.dispatch, nil, svc, sub, arg)
        if ok2 then
            return true
        end

        ctx.out("[DWKit ScoreStore] NOTE: dwscorestore delegate failed; falling back to inline handler")
        ctx.out("  err1=" .. tostring(err1))
        ctx.out("  err2=" .. tostring(err2))
    end

    -- Inline fallback (legacy behaviour)
    local function usage()
        ctx.out("[DWKit ScoreStore] Usage:")
        ctx.out("  dwscorestore")
        ctx.out("  dwscorestore status")
        ctx.out("  dwscorestore persist on|off|status")
        ctx.out("  dwscorestore fixture [basic]")
        ctx.out("  dwscorestore clear")
        ctx.out("  dwscorestore wipe [disk]")
        ctx.out("  dwscorestore reset [disk]")
        ctx.out("")
        ctx.out("Notes:")
        ctx.out("  - clear = clears snapshot only (history preserved)")
        ctx.out("  - wipe/reset = clears snapshot + history")
        ctx.out("  - wipe/reset disk = also deletes persisted file (best-effort; requires store.delete)")
    end

    if sub == "" or sub == "status" then
        local ok, _, _, _, err = _callBestEffort(svc, "printSummary")
        if not ok then
            ctx.err("ScoreStoreService.printSummary failed: " .. tostring(err))
        end
        return true
    end

    if sub == "persist" then
        if arg ~= "on" and arg ~= "off" and arg ~= "status" then
            usage()
            return true
        end

        if arg == "status" then
            local ok, _, _, _, err = _callBestEffort(svc, "printSummary")
            if not ok then
                ctx.err("ScoreStoreService.printSummary failed: " .. tostring(err))
            end
            return true
        end

        if type(svc.configurePersistence) ~= "function" then
            ctx.err("ScoreStoreService.configurePersistence not available.")
            return true
        end

        local enable = (arg == "on")
        local ok, _, _, _, err = _callBestEffort(svc, "configurePersistence", { enabled = enable, loadExisting = true })
        if not ok then
            ctx.err("configurePersistence failed: " .. tostring(err))
            return true
        end

        local ok2, _, _, _, err2 = _callBestEffort(svc, "printSummary")
        if not ok2 then
            ctx.err("ScoreStoreService.printSummary failed: " .. tostring(err2))
        end
        return true
    end

    if sub == "fixture" then
        local name = (arg ~= "" and arg) or "basic"
        if type(svc.ingestFixture) ~= "function" then
            ctx.err("ScoreStoreService.ingestFixture not available.")
            return true
        end
        local ok, _, _, _, err = _callBestEffort(svc, "ingestFixture", name, { source = "fixture" })
        if not ok then
            ctx.err("ingestFixture failed: " .. tostring(err))
            return true
        end
        local ok2, _, _, _, err2 = _callBestEffort(svc, "printSummary")
        if not ok2 then
            ctx.err("ScoreStoreService.printSummary failed: " .. tostring(err2))
        end
        return true
    end

    if sub == "clear" then
        if type(svc.clear) ~= "function" then
            ctx.err("ScoreStoreService.clear not available.")
            return true
        end
        local ok, _, _, _, err = _callBestEffort(svc, "clear", { source = "manual" })
        if not ok then
            ctx.err("clear failed: " .. tostring(err))
            return true
        end
        local ok2, _, _, _, err2 = _callBestEffort(svc, "printSummary")
        if not ok2 then
            ctx.err("ScoreStoreService.printSummary failed: " .. tostring(err2))
        end
        return true
    end

    if sub == "wipe" or sub == "reset" then
        if arg ~= "" and arg ~= "disk" then
            usage()
            return true
        end
        if type(svc.wipe) ~= "function" then
            ctx.err("ScoreStoreService.wipe not available. Update dwkit.services.score_store_service first.")
            return true
        end

        local meta = { source = "manual" }
        if arg == "disk" then
            meta.deleteFile = true
        end

        local ok, _, _, _, err = _callBestEffort(svc, "wipe", meta)
        if not ok then
            ctx.err(sub .. " failed: " .. tostring(err))
            return true
        end

        local ok2, _, _, _, err2 = _callBestEffort(svc, "printSummary")
        if not ok2 then
            ctx.err("ScoreStoreService.printSummary failed: " .. tostring(err2))
        end
        return true
    end

    usage()
    return true
end

local function _printReleaseChecklist()
    _out("[DWKit Release] checklist (dwrelease)")
    _out("  NOTE: SAFE + manual-only. This does not run git/gh commands.")
    _out("")

    _out("== versions (best-effort) ==")
    _out("")
    _legacyPrintVersionSummary()
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

local function _dispatch_dwrelease(ctx, kit, tokens)
    local okM, mod = _safeRequire("dwkit.commands.dwrelease")
    if okM and type(mod) == "table" and type(mod.dispatch) == "function" then
        local dctx = {
            out = ctx.out,
            err = ctx.err,
            ppTable = ctx.ppTable,
            callBestEffort = ctx.callBestEffort,
            getKit = function() return kit end,

            legacyPrint = function() _printReleaseChecklist() end,
            legacyPrintVersion = function() _legacyPrintVersionSummary() end,
        }

        local ok1, r1 = pcall(mod.dispatch, dctx, kit, tokens)
        if ok1 and r1 ~= false then return true end

        local ok2, r2 = pcall(mod.dispatch, dctx, tokens)
        if ok2 and r2 ~= false then return true end

        local ok3, r3 = pcall(mod.dispatch, tokens)
        if ok3 and r3 ~= false then return true end

        ctx.out("[DWKit Release] NOTE: dwrelease delegate returned false; falling back to inline handler")
    end

    _printReleaseChecklist()
    return true
end

local function _dispatch(ctx, kit, tokens)
    tokens = (type(tokens) == "table") and tokens or {}
    local cmd = tokens[1] or ""
    cmd = tostring(cmd or "")

    if cmd == "dwgui" then
        return _dispatch_dwgui(ctx, kit, tokens)
    end

    if cmd == "dwscorestore" then
        return _dispatch_dwscorestore(ctx, kit, tokens)
    end

    if cmd == "dwrelease" then
        return _dispatch_dwrelease(ctx, kit, tokens)
    end

    return false
end

-- ------------------------------------------------------------
-- Global alias-id persistence + cleanup
-- ------------------------------------------------------------
local function _getGlobalAliasIds()
    local kit = _getKit()
    if type(kit) ~= "table" then return nil end
    local t = kit[_GLOBAL_ALIAS_IDS_KEY]
    if type(t) == "table" then return t end
    return nil
end

local function _setGlobalAliasIds(t)
    local kit = _getKit()
    if type(kit) ~= "table" then return end
    kit[_GLOBAL_ALIAS_IDS_KEY] = (type(t) == "table") and t or nil
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

    local aliasIds = {}
    for k, v in pairs(STATE.aliasIds or {}) do
        aliasIds[k] = v
    end

    return {
        installed = STATE.installed and true or false,
        aliasIds = aliasIds,
        eventDiag = {
            maxLog = (d and d.maxLog) or 50,
            logCount = #(d and d.log or {}),
            tapToken = d and d.tapToken or nil,
            subsCount = subCount,
        },
        lastError = STATE.lastError,
    }
end

local function _resetSplitCommandModulesBestEffort()
    local mods = {
        "dwkit.commands.dwroom",
        "dwkit.commands.dwwho",
        "dwkit.commands.dwgui",
        "dwkit.commands.dwboot",
        "dwkit.commands.dwcommands",
        "dwkit.commands.dwhelp",
        "dwkit.commands.dwtest",
        "dwkit.commands.dwid",
        "dwkit.commands.dwversion",
        "dwkit.commands.dwinfo",
        "dwkit.commands.dwevents",
        "dwkit.commands.dwevent",
        "dwkit.commands.dwservices",
        "dwkit.commands.dwpresence",
        "dwkit.commands.dwactions",
        "dwkit.commands.dwskills",
        "dwkit.commands.dwdiag",
        "dwkit.commands.dwrelease",
        "dwkit.commands.dwscorestore",
    }

    for _, name in ipairs(mods) do
        local okM, mod = _safeRequire(name)
        if okM and type(mod) == "table" and type(mod.reset) == "function" then
            pcall(mod.reset)
        end
    end
end

function M.uninstall()
    -- CRITICAL: always try persisted cleanup (reload-safe)
    _cleanupPriorAliasesBestEffort()

    -- cancel pending capture sessions (legacy best-effort)
    _whoCaptureReset()
    _roomCaptureReset()

    -- Phase splits: reset extracted command modules (best-effort)
    _resetSplitCommandModulesBestEffort()

    if not STATE.installed then
        STATE.lastError = nil
        return true, nil
    end

    if _hasEventBus() then
        local kit = _getKit()
        local d = STATE.eventDiag
        if d and d.tapToken ~= nil and type(kit.bus.eventBus.tapOff) == "function" then
            pcall(kit.bus.eventBus.tapOff, d.tapToken)
            d.tapToken = nil
        end
        if d and type(kit.bus.eventBus.off) == "function" then
            for ev, tok in pairs(d.subs or {}) do
                pcall(kit.bus.eventBus.off, tok)
                d.subs[ev] = nil
            end
        end
    end

    if type(killAlias) ~= "function" then
        STATE.lastError = "killAlias() not available"
        return false, STATE.lastError
    end

    local allOk = true
    for _, id in pairs(STATE.aliasIds or {}) do
        if id then
            local ok = _killAliasStrict(id)
            if not ok then allOk = false end
        end
    end

    STATE.aliasIds = {}
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

-- ------------------------------------------------------------
-- SAFE alias generation from Command Registry (best-effort)
-- ------------------------------------------------------------
local function _getSafeCommandNamesBestEffort(kit)
    kit = (type(kit) == "table") and kit or _getKit()
    if type(kit) ~= "table" then return nil end

    -- Try DWKit.cmd helper methods first (preferred)
    if type(kit.cmd) == "table" then
        local candidates = {
            "getSafeNames",
            "listSafeNames",
            "safeNames",
            "getSafeCommands",
            "getSafe",
        }

        for _, fnName in ipairs(candidates) do
            if type(kit.cmd[fnName]) == "function" then
                local ok, a, b, c, err = _callBestEffort(kit.cmd, fnName)
                if ok then
                    local v = a
                    if type(v) == "table" then
                        -- Accept array of names OR map of name->record
                        local names = {}
                        local isArray = (v[1] ~= nil)
                        if isArray then
                            for _, x in ipairs(v) do
                                if type(x) == "string" and x ~= "" then
                                    names[#names + 1] = x
                                end
                            end
                        else
                            for k, _ in pairs(v) do
                                if type(k) == "string" and k ~= "" then
                                    names[#names + 1] = k
                                end
                            end
                        end
                        if #names > 0 then
                            table.sort(names)
                            return names
                        end
                    end
                end
            end
        end
    end

    -- Try command_registry module directly (best-effort)
    do
        local okR, reg = _safeRequire("dwkit.bus.command_registry")
        if okR and type(reg) == "table" then
            local candidates = {
                "getSafeNames",
                "listSafeNames",
                "safeNames",
                "getSafe",
            }
            for _, fnName in ipairs(candidates) do
                if type(reg[fnName]) == "function" then
                    local ok, v = pcall(reg[fnName], reg)
                    if ok and type(v) == "table" then
                        local names = {}
                        local isArray = (v[1] ~= nil)
                        if isArray then
                            for _, x in ipairs(v) do
                                if type(x) == "string" and x ~= "" then
                                    names[#names + 1] = x
                                end
                            end
                        else
                            for k, _ in pairs(v) do
                                if type(k) == "string" and k ~= "" then
                                    names[#names + 1] = k
                                end
                            end
                        end
                        if #names > 0 then
                            table.sort(names)
                            return names
                        end
                    end
                end
            end
        end
    end

    return nil
end

-- ------------------------------------------------------------
-- Generic alias callback dispatcher (SAFE)
--   Strategy:
--     0) Inline special-case for dwcommands (directly uses DWKit.cmd.* to avoid legacy split errors)
--     1) Prefer split module: dwkit.commands.<cmd>.dispatch(ctx, kit, tokens)
--        with signature-flex calls.
--     2) Fall back to DWKit.cmd.run(cmd, argString) if present (best-effort).
--     3) Small last-resort fallbacks for a few key commands via alias_legacy.
-- ------------------------------------------------------------
local function _dispatchGenericCommand(cmd, kit, tokens)
    cmd = tostring(cmd or "")
    kit = (type(kit) == "table") and kit or _getKit()
    tokens = (type(tokens) == "table") and tokens or {}

    if cmd == "" then return true end

    -- (0) dwcommands inline (fixes: "DWKit.cmd.listAll not available" spam)
    if cmd == "dwcommands" then
        if type(kit) ~= "table" or type(kit.cmd) ~= "table" then
            _err("DWKit.cmd not available. Run loader.init() first.")
            return true
        end

        local sub = tostring(tokens[2] or "")
        if sub == "" then
            local okCall, _, _, _, err = _callBestEffort(kit.cmd, "listAll")
            if not okCall then
                _err("DWKit.cmd.listAll not available: " .. tostring(err))
            end
            return true
        end

        if sub == "safe" then
            local okCall, _, _, _, err = _callBestEffort(kit.cmd, "listSafe")
            if not okCall then
                _err("DWKit.cmd.listSafe not available: " .. tostring(err))
            end
            return true
        end

        if sub == "game" then
            local okCall, _, _, _, err = _callBestEffort(kit.cmd, "listGame")
            if not okCall then
                _err("DWKit.cmd.listGame not available: " .. tostring(err))
            end
            return true
        end

        if sub == "md" then
            local okCall, md, _, _, err = _callBestEffort(kit.cmd, "toMarkdown")
            if not okCall or type(md) ~= "string" then
                _err("DWKit.cmd.toMarkdown not available: " .. tostring(err))
                return true
            end
            _out(md)
            return true
        end

        _err("Usage: dwcommands [safe|game|md]")
        return true
    end

    local ctx = {
        out = function(line) _out(line) end,
        err = function(msg) _err(msg) end,
        ppTable = function(t, opts) _legacyPpTable(t, opts) end,
        callBestEffort = function(obj, fnName, ...) return _callBestEffort(obj, fnName, ...) end,
        getKit = function() return kit end,
        getService = function(name) return _getService(name) end,
        printServiceSnapshot = function(label, svcName) _legacyPrintServiceSnapshot(label, svcName) end,
        makeEventDiagCtx = function() return _makeEventDiagCtx() end,
        getEventDiagState = function() return STATE.eventDiag end,
        legacyPrintVersion = function() _legacyPrintVersionSummary() end,
        legacyPrintBoot = function() _legacyPrintBootHealth() end,
        legacyPrintServices = function() _legacyPrintServicesHealth() end,
        legacyPrintIdentity = function() _legacyPrintIdentity() end,
    }

    -- 1) Split module dispatch
    local okM, mod = _safeRequire("dwkit.commands." .. cmd)
    if okM and type(mod) == "table" and type(mod.dispatch) == "function" then
        local ok1, r1 = pcall(mod.dispatch, ctx, kit, tokens)
        if ok1 and r1 ~= false then return true end

        local ok2, r2 = pcall(mod.dispatch, ctx, tokens)
        if ok2 and r2 ~= false then return true end

        local ok3, r3 = pcall(mod.dispatch, tokens)
        if ok3 and r3 ~= false then return true end
    end

    -- 2) Try DWKit.cmd.run (best-effort)
    if type(kit) == "table" and type(kit.cmd) == "table" and type(kit.cmd.run) == "function" then
        local argString = ""
        if #tokens >= 2 then
            argString = table.concat(tokens, " ", 2)
        end

        local okA = pcall(kit.cmd.run, cmd, argString)
        if okA then return true end

        local okB = pcall(kit.cmd.run, kit.cmd, cmd, argString)
        if okB then return true end
    end

    -- 3) Micro-fallbacks for a few essential commands
    if cmd == "dwid" then
        _legacyPrintIdentity()
        return true
    end
    if cmd == "dwversion" then
        _legacyPrintVersionSummary()
        return true
    end
    if cmd == "dwboot" then
        _legacyPrintBootHealth()
        return true
    end
    if cmd == "dwservices" then
        _legacyPrintServicesHealth()
        return true
    end
    if cmd == "dwpresence" then
        _legacyPrintServiceSnapshot("PresenceService", "presenceService")
        return true
    end
    if cmd == "dwactions" then
        _legacyPrintServiceSnapshot("ActionModelService", "actionModelService")
        return true
    end
    if cmd == "dwskills" then
        _legacyPrintServiceSnapshot("SkillRegistryService", "skillRegistryService")
        return true
    end

    _err("Command handler not available for: " .. cmd .. " (no split module / no DWKit.cmd.run).")
    return true
end

-- ------------------------------------------------------------
-- Special-case alias builders (need service/state injection)
-- ------------------------------------------------------------
local function _installAlias_dwwho()
    local pat = [[^dwwho(?:\s+(status|clear|ingestclip|fixture|refresh|set))?(?:\s+(.+))?\s*$]]
    return _mkAlias(pat, function()
        local svc = _getWhoStoreServiceBestEffort()
        if type(svc) ~= "table" then
            _err(
                "WhoStoreService not available or incomplete. Create/repair src/dwkit/services/whostore_service.lua, then loader.init().")
            return
        end

        local line = _getFullMatchLine()
        local tokens = {}
        for w in tostring(line or ""):gmatch("%S+") do
            tokens[#tokens + 1] = w
        end

        local sub = tokens[2] or ""
        local arg = ""

        if #tokens >= 3 then
            if sub == "set" then
                local names = {}
                for i = 3, #tokens do
                    names[#names + 1] = tokens[i]
                end
                arg = table.concat(names, ",")
            else
                arg = table.concat(tokens, " ", 3)
            end
        end

        local okM, mod = _safeRequire("dwkit.commands.dwwho")
        if not okM or type(mod) ~= "table" or type(mod.dispatch) ~= "function" then
            _err("dwkit.commands.dwwho not available. Ensure src/dwkit/commands/dwwho.lua exists.")
            return
        end

        local ctx = {
            out = function(line2) _out(line2) end,
            err = function(msg) _err(msg) end,
            callBestEffort = function(obj, fnName, ...) return _callBestEffort(obj, fnName, ...) end,
            getClipboardText = function() return _getClipboardTextBestEffort() end,
            resolveSendFn = function() return _resolveSendFn() end,
            killTrigger = function(id) _killTriggerBestEffort(id) end,
            killTimer = function(id) _killTimerBestEffort(id) end,
            tempRegexTrigger = function(p, fn) return tempRegexTrigger(p, fn) end,
            tempTimer = function(sec, fn) return tempTimer(sec, fn) end,
            whoIngestTextBestEffort = function(s, text, meta) return _whoIngestTextBestEffort(s, text, meta) end,
            printWhoStatus = function(s) _printWhoStatus(s) end,
        }

        local ok1, err1 = pcall(mod.dispatch, ctx, svc, sub, arg)
        if ok1 then return end

        local ok2, err2 = pcall(mod.dispatch, ctx, svc, sub)
        if ok2 then return end

        _err("dwwho handler threw error: " .. tostring(err1 or err2))
    end)
end

local function _installAlias_dwroom()
    local pat = [[^dwroom(?:\s+(status|clear|ingestclip|fixture|refresh))?(?:\s+(\S+))?\s*$]]
    return _mkAlias(pat, function()
        local svc = _getRoomEntitiesServiceBestEffort()
        if type(svc) ~= "table" then
            _err("RoomEntitiesService not available. Run loader.init() first.")
            return
        end

        local line = _getFullMatchLine()
        local tokens = {}
        for w in tostring(line or ""):gmatch("%S+") do
            tokens[#tokens + 1] = w
        end

        local sub = tokens[2] or ""
        local arg = ""
        if #tokens >= 3 then
            arg = table.concat(tokens, " ", 3)
        end

        local okM, mod = _safeRequire("dwkit.commands.dwroom")
        if not okM or type(mod) ~= "table" or type(mod.dispatch) ~= "function" then
            _err("dwkit.commands.dwroom not available. Ensure src/dwkit/commands/dwroom.lua exists.")
            return
        end

        local ctx = {
            out = function(line2) _out(line2) end,
            err = function(msg) _err(msg) end,
            callBestEffort = function(obj, fnName, ...) return _callBestEffort(obj, fnName, ...) end,
            getClipboardText = function() return _getClipboardTextBestEffort() end,
            resolveSendFn = function() return _resolveSendFn() end,
            looksLikePrompt = function(line2) return _looksLikePrompt(line2) end,
            killTrigger = function(id) _killTriggerBestEffort(id) end,
            killTimer = function(id) _killTimerBestEffort(id) end,
            tempRegexTrigger = function(p, fn) return tempRegexTrigger(p, fn) end,
            tempTimer = function(sec, fn) return tempTimer(sec, fn) end,
            printRoomEntitiesStatus = function(s) _printRoomEntitiesStatus(s) end,
        }

        local okCall, errOrNil = pcall(mod.dispatch, ctx, svc, sub, arg)
        if not okCall then
            _err("dwroom handler threw error: " .. tostring(errOrNil))
        end
    end)
end

local function _installAlias_eventDiagTap()
    local pat = [[^dweventtap(?:\s+(on|off|status|show|clear))?(?:\s+(\d+))?\s*$]]
    return _mkAlias(pat, function()
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
end

local function _installAlias_eventDiagSub()
    local pat = [[^dweventsub(?:\s+(\S+))?\s*$]]
    return _mkAlias(pat, function()
        local evName = (matches and matches[2]) and tostring(matches[2]) or ""
        if evName == "" then
            _err("Usage: dweventsub <EventName>")
            return
        end

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
end

local function _installAlias_eventDiagUnsub()
    local pat = [[^dweventunsub(?:\s+(\S+))?\s*$]]
    return _mkAlias(pat, function()
        local evName = (matches and matches[2]) and tostring(matches[2]) or ""
        if evName == "" then
            _err("Usage: dweventunsub <EventName|all>")
            return
        end

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
end

local function _installAlias_eventDiagLog()
    local pat = [[^dweventlog(?:\s+(\d+))?\s*$]]
    return _mkAlias(pat, function()
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
end

local function _installAlias_dwdiag()
    local pat = [[^dwdiag(?:\s+(.+))?\s*$]]
    return _mkAlias(pat, function()
        local kit = _getKit()
        local tokens = _tokenizeFromMatches()

        local okM, mod = _safeRequire("dwkit.commands.dwdiag")
        if okM and type(mod) == "table" and type(mod.dispatch) == "function" then
            local ctx = {
                out = function(line2) _out(line2) end,
                err = function(msg) _err(msg) end,
                ppTable = function(t, opts2) _legacyPpTable(t, opts2) end,
                callBestEffort = function(obj, fnName, ...) return _callBestEffort(obj, fnName, ...) end,

                getKit = function() return kit end,
                makeEventDiagCtx = function() return _makeEventDiagCtx() end,
                getEventDiagState = function() return STATE.eventDiag end,

                legacyPrintVersion = function() _legacyPrintVersionSummary() end,
                legacyPrintBoot = function() _legacyPrintBootHealth() end,
                legacyPrintServices = function() _legacyPrintServicesHealth() end,
            }

            local ok1, r1 = pcall(mod.dispatch, ctx, kit, tokens)
            if ok1 and r1 ~= false then return end

            local ok2, r2 = pcall(mod.dispatch, ctx, tokens)
            if ok2 and r2 ~= false then return end

            local ok3, r3 = pcall(mod.dispatch, tokens)
            if ok3 and r3 ~= false then return end

            _out("[DWKit Diag] NOTE: dwdiag delegate returned false; falling back to inline handler")
        end

        _out("[DWKit Diag] bundle (dwdiag)")
        _out("  NOTE: SAFE + manual-only. Does not enable event tap or subscriptions.")
        _out("")

        _out("== dwversion ==")
        _out("")
        _legacyPrintVersionSummary()
        _out("")

        _out("== dwboot ==")
        _out("")
        _legacyPrintBootHealth()
        _out("")

        _out("== dwservices ==")
        _out("")
        _legacyPrintServicesHealth()
        _out("")

        _out("== event diag status ==")
        _out("")
        local modED = _getEventDiagModuleBestEffort()
        if type(modED) == "table" and type(modED.printStatus) == "function" then
            local okCall, errOrNil = pcall(modED.printStatus, _makeEventDiagCtx(), STATE.eventDiag)
            if not okCall then
                _err("event_diag.printStatus threw error: " .. tostring(errOrNil))
            end
        else
            _err("dwkit.commands.event_diag not available (cannot print event diag status)")
        end
    end)
end

local function _installAlias_routered(cmdName)
    cmdName = tostring(cmdName or "")
    local pat = "^" .. cmdName .. "(?:\\s+(.+))?\\s*$"
    return _mkAlias(pat, function()
        local kit = _getKit()
        local ctx = _makeRouterCtx()
        local tokens = _tokenizeFromMatches()

        local ok = _dispatch(ctx, kit, tokens)
        if ok ~= true then
            _err(cmdName .. " dispatch failed (unhandled)")
        end
    end)
end

-- ------------------------------------------------------------
-- Install (AUTO SAFE aliases + special-cases)
-- ------------------------------------------------------------
function M.install(opts)
    opts = opts or {}

    if type(tempAlias) ~= "function" then
        STATE.lastError = "tempAlias() not available"
        return false, STATE.lastError
    end

    if STATE.installed then
        return true, nil
    end

    -- Always cleanup persisted aliases first (safe across reloads)
    _cleanupPriorAliasesBestEffort()

    local kit = _getKit()
    if type(kit) ~= "table" then
        STATE.lastError = "DWKit not available. Run loader.init() first."
        return false, STATE.lastError
    end

    -- Build SAFE names from registry (best-effort).
    -- If registry enumeration fails, we will fall back to a minimal static list.
    local safeNames = _getSafeCommandNamesBestEffort(kit)

    if type(safeNames) ~= "table" or #safeNames == 0 then
        -- Minimal fallback set (keeps your current SAFE surface alive)
        safeNames = {
            "dwactions",
            "dwboot",
            "dwcommands",
            "dwdiag",
            "dwevent",
            "dweventlog",
            "dwevents",
            "dweventsub",
            "dweventtap",
            "dweventunsub",
            "dwgui",
            "dwhelp",
            "dwid",
            "dwinfo",
            "dwpresence",
            "dwrelease",
            "dwroom",
            "dwscorestore",
            "dwservices",
            "dwskills",
            "dwtest",
            "dwversion",
            "dwwho",
        }
    end

    -- Special-case aliases (need state/services/router)
    local special = {
        dwwho = true,
        dwroom = true,
        dweventtap = true,
        dweventsub = true,
        dweventunsub = true,
        dweventlog = true,
        dwgui = true,
        dwscorestore = true,
        dwrelease = true,
        dwdiag = true,
        -- NOTE: dwcommands stays auto-generated, but runtime dispatch is now inline-safe in _dispatchGenericCommand()
    }

    local created = {} -- cmdName -> aliasId

    -- 1) Special-case installs
    created.dwwho = _installAlias_dwwho()
    created.dwroom = _installAlias_dwroom()
    created.dweventtap = _installAlias_eventDiagTap()
    created.dweventsub = _installAlias_eventDiagSub()
    created.dweventunsub = _installAlias_eventDiagUnsub()
    created.dweventlog = _installAlias_eventDiagLog()
    created.dwdiag = _installAlias_dwdiag()

    created.dwgui = _installAlias_routered("dwgui")
    created.dwscorestore = _installAlias_routered("dwscorestore")
    created.dwrelease = _installAlias_routered("dwrelease")

    -- 2) Auto-generate SAFE aliases for everything else
    for _, cmdName in ipairs(safeNames) do
        cmdName = tostring(cmdName or "")
        if cmdName ~= "" and (special[cmdName] ~= true) then
            local pat = "^" .. cmdName .. "(?:\\s+(.+))?\\s*$"
            local id = _mkAlias(pat, function()
                if not _hasCmd() then
                    _err("DWKit.cmd not available. Run loader.init() first.")
                    return
                end
                local k = _getKit()
                local tokens = _tokenizeFromMatches()
                local cmd = tokens[1] or cmdName
                _dispatchGenericCommand(cmd, k, tokens)
            end)
            created[cmdName] = id
        end
    end

    -- Validate all alias creations succeeded
    local anyFail = false
    for k, v in pairs(created) do
        if v == nil then
            anyFail = true
            break
        end
    end

    if anyFail then
        STATE.lastError = "Failed to create one or more aliases"
        if type(killAlias) == "function" then
            for _, xid in pairs(created) do
                if xid then pcall(killAlias, xid) end
            end
        end
        STATE.aliasIds = {}
        return false, STATE.lastError
    end

    STATE.aliasIds = created
    STATE.installed = true
    STATE.lastError = nil

    _setGlobalAliasIds(created)

    if not opts.quiet then
        local keys = _sortedKeys(created)
        _out("[DWKit Alias] Installed (" .. tostring(#keys) .. "): " .. table.concat(keys, ", "))
    end

    return true, nil
end

return M
