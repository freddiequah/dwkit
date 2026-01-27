-- #########################################################################
-- BEGIN FILE: src/dwkit/services/command_aliases.lua
-- #########################################################################
-- Module Name : dwkit.services.command_aliases
-- Owner       : Services
-- Version     : v2026-01-27C
-- Purpose     :
--   - Install SAFE Mudlet aliases for DWKit commands.
--   - AUTO-GENERATES SAFE aliases from the Command Registry (best-effort).
--   - Keeps only a small set of "special-case" aliases that require:
--       * service injection (dwwho/dwroom)
--       * diag bundle access (dwdiag)
--
-- NOTE (Slimming Step 1):
--   - Router fallbacks (dwgui/dwscorestore/dwrelease + generic dispatch wrapper)
--     have been extracted to: dwkit.bus.command_router
--
-- NOTE (Slimming Step 2):
--   - Event diagnostics state injection has been extracted to:
--       * dwkit.services.event_diag_state
--       * dwkit.commands.dweventtap / dweventsub / dweventunsub / dweventlog
--     so these can be auto-generated like normal SAFE commands.
--
-- NOTE (Slimming Step 3 - THIS CHANGE):
--   - SAFE command enumeration + auto SAFE alias generation loop extracted to:
--       * dwkit.services.alias_factory
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

M.VERSION = "v2026-01-27C"

local _GLOBAL_ALIAS_IDS_KEY = "_commandAliasesAliasIds"

local STATE = {
    installed = false,

    -- aliasIds is dynamic (auto-generated):
    --   { [cmdName] = <aliasId>, ... }
    aliasIds = {},

    lastError = nil,

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
-- Event diagnostics ctx helpers (NO state stored here)
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

local function _getEventDiagStateServiceBestEffort()
    local ok, mod = _safeRequire("dwkit.services.event_diag_state")
    if ok and type(mod) == "table" then
        return mod
    end
    return nil
end

local function _getEventDiagStateBestEffort(kit)
    local S = _getEventDiagStateServiceBestEffort()
    if S and type(S.getState) == "function" then
        local okCall, st = pcall(S.getState, kit)
        if okCall and type(st) == "table" then
            return st
        end
    end
    return nil
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

        legacyPrintVersionSummary = function() _legacyPrintVersionSummary() end,
    }
end

-- ------------------------------------------------------------
-- Router module (Step 1 extraction target)
-- ------------------------------------------------------------
local function _getRouterBestEffort()
    local ok, mod = _safeRequire("dwkit.bus.command_router")
    if ok and type(mod) == "table" then return mod end
    return nil
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
    local aliasIds = {}
    for k, v in pairs(STATE.aliasIds or {}) do
        aliasIds[k] = v
    end

    local kit = _getKit()
    local d = _getEventDiagStateBestEffort(kit)

    local subCount = 0
    if type(d) == "table" and type(d.subs) == "table" then
        for _ in pairs(d.subs) do subCount = subCount + 1 end
    end

    return {
        installed = STATE.installed and true or false,
        aliasIds = aliasIds,
        eventDiag = {
            maxLog = (type(d) == "table" and d.maxLog) or 50,
            logCount = (type(d) == "table" and type(d.log) == "table") and #d.log or 0,
            tapToken = (type(d) == "table") and d.tapToken or nil,
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
        "dwkit.commands.dweventtap",
        "dwkit.commands.dweventsub",
        "dwkit.commands.dweventunsub",
        "dwkit.commands.dweventlog",
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

    -- event diag shutdown (best-effort; unload-safe)
    do
        local kit = _getKit()
        local S = _getEventDiagStateServiceBestEffort()
        if S and type(S.shutdown) == "function" then
            pcall(S.shutdown, kit)
        end
    end

    -- Phase splits: reset extracted command modules (best-effort)
    _resetSplitCommandModulesBestEffort()

    if not STATE.installed then
        STATE.lastError = nil
        return true, nil
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
-- Special-case alias builders (need service/router)
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
                getEventDiagState = function()
                    return _getEventDiagStateBestEffort(kit)
                end,

                legacyPrintVersionSummary = function() _legacyPrintVersionSummary() end,
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
        local okED, modED = _safeRequire("dwkit.commands.event_diag")
        if okED and type(modED) == "table" and type(modED.printStatus) == "function" then
            local d = _getEventDiagStateBestEffort(kit) or {}
            local okCall, errOrNil = pcall(modED.printStatus, _makeEventDiagCtx(), d)
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

        local R = _getRouterBestEffort()
        if type(R) ~= "table" or type(R.dispatchRoutered) ~= "function" then
            _err("command_router not available (dispatchRoutered missing)")
            return
        end

        local ok = R.dispatchRoutered(ctx, kit, tokens)
        if ok ~= true then
            _err(cmdName .. " dispatch failed (unhandled)")
        end
    end)
end

-- ------------------------------------------------------------
-- Install (AUTO SAFE aliases via alias_factory + special-cases)
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

    -- Load alias_factory (best-effort) for SAFE enumeration + auto SAFE alias creation
    local okF, F = _safeRequire("dwkit.services.alias_factory")
    if not okF or type(F) ~= "table" then
        F = nil
    end

    local deps = {
        safeRequire = function(name) return _safeRequire(name) end,
        callBestEffort = function(obj, fnName, ...) return _callBestEffort(obj, fnName, ...) end,
        mkAlias = function(pat, fn) return _mkAlias(pat, fn) end,
        tokenizeFromMatches = function() return _tokenizeFromMatches() end,
        hasCmd = function() return _hasCmd() end,
        getKit = function() return _getKit() end,
        getService = function(name) return _getService(name) end,
        getRouter = function() return _getRouterBestEffort() end,
        out = function(line) _out(line) end,
        err = function(msg) _err(msg) end,
        legacyPpTable = function(t, opts2) _legacyPpTable(t, opts2) end,
        makeEventDiagCtx = function() return _makeEventDiagCtx() end,
        getEventDiagStateBestEffort = function(k) return _getEventDiagStateBestEffort(k) end,
        legacyPrintVersionSummary = function() _legacyPrintVersionSummary() end,
        legacyPrintBoot = function() _legacyPrintBootHealth() end,
        legacyPrintServices = function() _legacyPrintServicesHealth() end,
        legacyPrintIdentity = function() _legacyPrintIdentity() end,
        legacyPrintServiceSnapshot = function(label, svcName) return _legacyPrintServiceSnapshot(label, svcName) end,
    }

    -- Build SAFE names from registry (best-effort).
    -- If enumeration fails, fall back to a minimal static list.
    local safeNames = nil
    if F and type(F.getSafeCommandNamesBestEffort) == "function" then
        safeNames = F.getSafeCommandNamesBestEffort(deps, kit)
    end

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

    -- Special-case aliases (need services/router)
    local special = {
        dwwho = true,
        dwroom = true,
        dwgui = true,
        dwscorestore = true,
        dwrelease = true,
        dwdiag = true,
        -- NOTE: event diag commands are now normal SAFE commands (split modules).
        -- NOTE: dwcommands stays auto-generated; generic router keeps inline-safe behavior.
    }

    local created = {} -- cmdName -> aliasId

    -- 1) Special-case installs
    created.dwwho = _installAlias_dwwho()
    created.dwroom = _installAlias_dwroom()
    created.dwdiag = _installAlias_dwdiag()

    created.dwgui = _installAlias_routered("dwgui")
    created.dwscorestore = _installAlias_routered("dwscorestore")
    created.dwrelease = _installAlias_routered("dwrelease")

    -- 2) Auto-generate SAFE aliases for everything else (delegated)
    if F and type(F.installAutoSafeAliases) == "function" then
        local autoCreated = F.installAutoSafeAliases(deps, kit, safeNames, special)
        if type(autoCreated) == "table" then
            for k, v in pairs(autoCreated) do
                created[k] = v
            end
        end
    else
        -- Fallback to error (we keep hard minimal set via special + manual will still be too small)
        -- But we still continue to validate below; nils will trigger fail.
        _out("[DWKit Alias] NOTE: alias_factory not available; SAFE auto generation skipped")
    end

    -- Validate all alias creations succeeded
    local anyFail = false
    for _, v in pairs(created) do
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

-- #########################################################################
-- END FILE: src/dwkit/services/command_aliases.lua
-- #########################################################################
