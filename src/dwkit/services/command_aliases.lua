-- #########################################################################
-- Module Name : dwkit.services.command_aliases
-- Owner       : Services
-- Version     : v2026-01-26B
-- Purpose     :
--   - Install SAFE Mudlet aliases for command discovery/help:
--       * dwcommands [safe|game|md]
--       * dwhelp <cmd>
--       * dwtest [quiet|ui|room|who|verbose|v] [verbose|v]
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
-- Phase 3 Split (v2026-01-20A):
--   - dwboot alias now delegates to src/dwkit/commands/dwboot.lua when available,
--     with a safe inline fallback to the legacy boot health printer.
--
-- Phase 4 Split (v2026-01-20B):
--   - dwcommands + dwhelp aliases now delegate to:
--       * src/dwkit/commands/dwcommands.lua
--       * src/dwkit/commands/dwhelp.lua
--     with safe inline fallback to the legacy alias implementation.
--
-- Fixes (v2026-01-20C):
--   - install() is idempotent: if already installed, it returns early BEFORE cleaning up persisted
--     alias ids. This prevents an "install nothing" state if install() is called twice.
--
-- Phase 5 Split (v2026-01-20D):
--   - dwtest alias now delegates to src/dwkit/commands/dwtest.lua when available,
--     with safe inline fallback to the legacy dwtest handler.
--   - dwtest parsing no longer relies on optional capture groups; tokenizes matches[1] to avoid stale values.
--
-- Fixes (v2026-01-20E):
--   - dwtest alias no longer hard-fails due to alias callback environment quirks:
--       * dwtest ui runs ui_validator directly (does not depend on DWKit.test.run surface)
--       * dwtest / dwtest quiet runs DWKit.test.run when available, else falls back to self_test_runner.run()
--   - Added _getKit() resolver to reliably reference DWKit inside alias callbacks
--
-- Phase 6 Split (v2026-01-20F):
--   - dwid / dwinfo / dwversion now delegate to:
--       * src/dwkit/commands/dwid.lua
--       * src/dwkit/commands/dwinfo.lua
--       * src/dwkit/commands/dwversion.lua
--     with safe inline fallbacks.
--
-- Phase 7 Split (v2026-01-20G):
--   - dwevents / dwevent now delegate to:
--       * src/dwkit/commands/dwevents.lua
--       * src/dwkit/commands/dwevent.lua
--     with safe inline fallbacks.
--
-- Fixes (v2026-01-20H):
--   - dwevent parsing updated to match Phase 7 patch exactly: uses matches[2] (capture group),
--     rather than tokenizing matches[1].
--
-- Fixes (v2026-01-21B):
--   - dwwho alias now captures and forwards optional arg (e.g. "dwwho fixture party").
--     Previously pattern ended at subcommand and dropped the 2nd token, causing fixture to default to "basic".
--
-- Fixes (v2026-01-21D):
--   - dwwho + dwroom aliases no longer rely on capture groups (Mudlet matches[] can be stale).
--     Tokenizes matches[1] (full line) to derive sub + arg string.
--   - dwwho set now supports multi-token names: "dwwho set Bob Alice" becomes "Bob,Alice".
--
-- Fixes (v2026-01-21F):
--   - Tokenization now uses matches[0] when available (full match line).
--     This fixes cases where capture groups exist and matches[1] is NOT the full line,
--     causing args to be dropped (e.g. "dwwho fixture party" / "dwwho set Bob Alice").
--
-- Fixes (v2026-01-23A):
--   - dwtest now supports suite-style targets: "dwtest room" / "dwtest who" (plus optional "verbose|v").
--   - dwtest pattern is now tolerant and token-based (prevents stale capture group issues and supports new targets).
--
-- Fixes (v2026-01-23B):
--   - dwtest now self-heals if invoked before DWKit.test is wired:
--       * best-effort calls loader.init() internally, then retries DWKit.test.run / self_test_runner.run
--   - _has* helpers now prefer _getKit() to avoid false negatives in alias callback environments.
--
-- Fixes (v2026-01-23C):
--   - dwtest delegation now respects return value from dwkit.commands.dwtest.dispatch.
--     (Previously, any successful pcall would return early even if dispatch returned false.)
--
-- Phase 8 Split (v2026-01-24A):
--   - dwservices alias now delegates to src/dwkit/commands/dwservices.lua when available,
--     with safe inline fallback to legacy services health printer.
--
-- Changed (v2026-01-24C):
--   - Removed dwinit/dwalias alias ownership from this module.
--   - dwinit/dwalias are owned by dwkit.services.alias_control to prevent double-fire.
--
-- Phase 9 Split (v2026-01-25A):
--   - dwpresence / dwactions / dwskills / dwdiag / dwrelease now delegate to:
--       * src/dwkit/commands/dwpresence.lua
--       * src/dwkit/commands/dwactions.lua
--       * src/dwkit/commands/dwskills.lua
--       * src/dwkit/commands/dwdiag.lua
--       * src/dwkit/commands/dwrelease.lua
--     with safe inline fallbacks preserved.
--
-- Phase 10 Split (v2026-01-25B):
--   - dwscorestore now delegates to:
--       * src/dwkit/commands/dwscorestore.lua
--     with safe inline fallback preserved.
--
-- Fixes (v2026-01-25C):
--   - dwhelp now matches zero-args (prints usage) to prevent falling through to MUD "Huh?!?"
--
-- Slim (v2026-01-25D):
--   - Slimmed uninstall() module reset boilerplate into a loop (no behavior changes).
--   - Slimmed getState() and uninstall() alias id list building to avoid repeated boilerplate (no behavior changes).
--
-- Slim (v2026-01-26A):
--   - Legacy printers + pp helpers extracted to: src/dwkit/commands/alias_legacy.lua
--   - command_aliases now calls alias_legacy for fallbacks:
--       * identity/version/boot/services/service-snapshot + ppTable/ppValue
--   - No functional change intended; responsibility reduced.
--
-- Fixes (v2026-01-26B):
--   - dwevent / dweventsub / dweventunsub now match zero-args and print usage
--     (prevents falling through to MUD "Huh?!?" and makes behavior deterministic).
--
-- Public API  :
--   - install(opts?) -> boolean ok, string|nil err
--   - uninstall() -> boolean ok, string|nil err
--   - isInstalled() -> boolean
--   - getState() -> table copy
-- #########################################################################

local M = {}

M.VERSION = "v2026-01-26B"

local _GLOBAL_ALIAS_IDS_KEY = "_commandAliasesAliasIds"

local _ALIAS_KEYS = {
    "dwcommands",
    "dwhelp",
    "dwtest",
    "dwinfo",
    "dwid",
    "dwversion",
    "dwdiag",
    "dwgui",
    "dwevents",
    "dwevent",
    "dwboot",

    "dwservices",
    "dwpresence",
    "dwroom",
    "dwwho",
    "dwactions",
    "dwskills",
    "dwscorestore",

    "dweventtap",
    "dweventsub",
    "dweventunsub",
    "dweventlog",

    "dwrelease",
}

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

local function _hasTest()
    local kit = _getKit()
    return type(kit) == "table"
        and type(kit.test) == "table"
        and type(kit.test.run) == "function"
end

local function _hasBaseline()
    local kit = _getKit()
    return type(kit) == "table"
        and type(kit.core) == "table"
        and type(kit.core.runtimeBaseline) == "table"
        and type(kit.core.runtimeBaseline.printInfo) == "function"
end

local function _hasIdentity()
    local kit = _getKit()
    return type(kit) == "table"
        and type(kit.core) == "table"
        and type(kit.core.identity) == "table"
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

local function _hasServices()
    local kit = _getKit()
    return type(kit) == "table"
        and type(kit.services) == "table"
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
-- SAFE deferral helper (avoid killing currently-running alias mid-callback)
-- ------------------------------------------------------------
local function _defer(fn)
    if type(fn) ~= "function" then return end
    if type(tempTimer) == "function" then
        pcall(tempTimer, 0, fn)
        return
    end
    -- fallback: immediate (best-effort)
    pcall(fn)
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
    -- ultra-min fallback
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

-- -------------------------
-- Event diagnostics (delegated handlers; STATE stays here)
-- -------------------------
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
        ppTable = function(t, opts) _legacyPpTable(t, opts) end,
        ppValue = function(v) return _legacyPpValue(v) end,

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
    for _, k in ipairs(_ALIAS_KEYS) do
        aliasIds[k] = STATE.aliasIds[k]
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
        -- Phase 1/2/3/4/5 split modules
        "dwkit.commands.dwroom",
        "dwkit.commands.dwwho",
        "dwkit.commands.dwgui",
        "dwkit.commands.dwboot",
        "dwkit.commands.dwcommands",
        "dwkit.commands.dwhelp",
        "dwkit.commands.dwtest",

        -- Phase 6 split
        "dwkit.commands.dwid",
        "dwkit.commands.dwversion",
        "dwkit.commands.dwinfo",

        -- Phase 7 split
        "dwkit.commands.dwevents",
        "dwkit.commands.dwevent",

        -- Phase 8 split
        "dwkit.commands.dwservices",

        -- Phase 9 split
        "dwkit.commands.dwpresence",
        "dwkit.commands.dwactions",
        "dwkit.commands.dwskills",
        "dwkit.commands.dwdiag",
        "dwkit.commands.dwrelease",

        -- Phase 10 split
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
    for _, k in ipairs(_ALIAS_KEYS) do
        local id = STATE.aliasIds[k]
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

    -- FIX (v2026-01-20C):
    -- If already installed, do NOT cleanup persisted alias ids here.
    -- install() is idempotent; uninstall() must be called explicitly to reinstall.
    if STATE.installed then
        return true, nil
    end

    -- Always cleanup persisted aliases first (safe across reloads)
    _cleanupPriorAliasesBestEffort()

    local dwcommandsPattern = [[^dwcommands(?:\s+(safe|game|md))?\s*$]]
    local id1 = _mkAlias(dwcommandsPattern, function()
        if not _hasCmd() then
            _err("DWKit.cmd not available. Run loader.init() first.")
            return
        end

        -- Robust parse: optional capture groups can be stale; tokenize full line.
        local line = _getFullMatchLine()
        local tokens = {}
        for w in line:gmatch("%S+") do
            tokens[#tokens + 1] = w
        end
        local mode = tokens[2] or ""

        local kit = _getKit()

        -- Phase 4 split: try delegated handler FIRST (best-effort), then fallback to legacy inline output.
        local okM, mod = _safeRequire("dwkit.commands.dwcommands")
        if okM and type(mod) == "table" and type(mod.dispatch) == "function" then
            local ctx = {
                out = function(line2) _out(line2) end,
                err = function(msg) _err(msg) end,
            }

            local ok1, err1 = pcall(mod.dispatch, ctx, kit.cmd, mode)
            if ok1 then
                return
            end

            local ok2, err2 = pcall(mod.dispatch, nil, kit.cmd, mode)
            if ok2 then
                return
            end

            _out("[DWKit Commands] NOTE: dwcommands delegate failed; falling back to inline handler")
            _out("  err1=" .. tostring(err1))
            _out("  err2=" .. tostring(err2))
        end

        -- Inline fallback (legacy behaviour)
        mode = tostring(mode or "")
        if mode == "safe" then
            kit.cmd.listSafe()
        elseif mode == "game" then
            kit.cmd.listGame()
        elseif mode == "md" then
            if type(kit.cmd.toMarkdown) ~= "function" then
                _err("DWKit.cmd.toMarkdown not available.")
                return
            end
            local ok, md = pcall(kit.cmd.toMarkdown, {})
            if not ok then
                _err("dwcommands md failed: " .. tostring(md))
                return
            end
            _out(tostring(md))
        else
            kit.cmd.listAll()
        end
    end)

    -- FIX (v2026-01-25C): accept zero-args for dwhelp (prints usage instead of falling through to MUD)
    local dwhelpPattern = [[^dwhelp(?:\s+(\S+))?\s*$]]
    local id2 = _mkAlias(dwhelpPattern, function()
        if not _hasCmd() then
            _err("DWKit.cmd not available. Run loader.init() first.")
            return
        end

        -- NOTE: Mudlet tempAlias commonly sets:
        --   matches[0] = full match
        --   matches[1] = full match (sometimes)
        --   matches[2] = first capture group (when present)
        local name = (matches and matches[2]) and tostring(matches[2]) or ""
        name = tostring(name or "")

        if name == "" then
            _out("[DWKit Help] Usage: dwhelp <cmd>")
            _out("  Try: dwcommands")
            _out("  Example: dwhelp dwtest")
            return
        end

        local kit = _getKit()

        -- Phase 4 split: try delegated handler FIRST (best-effort), then fallback to legacy inline output.
        local okM, mod = _safeRequire("dwkit.commands.dwhelp")
        if okM and type(mod) == "table" and type(mod.dispatch) == "function" then
            local ctx = {
                out = function(line2) _out(line2) end,
                err = function(msg) _err(msg) end,
            }

            local ok1, err1 = pcall(mod.dispatch, ctx, kit.cmd, name)
            if ok1 then
                return
            end

            local ok2, err2 = pcall(mod.dispatch, nil, kit.cmd, name)
            if ok2 then
                return
            end

            _out("[DWKit Help] NOTE: dwhelp delegate failed; falling back to inline handler")
            _out("  err1=" .. tostring(err1))
            _out("  err2=" .. tostring(err2))
        end

        -- Inline fallback (legacy behaviour)
        local ok, _, err = kit.cmd.help(name)
        if not ok then
            _err(err or ("Unknown command: " .. name))
        end
    end)

    -- FIX (v2026-01-23A): token-based dwtest to support suite targets (room/who) + verbose flag.
    local dwtestPattern = [[^dwtest(?:\s+(.+))?\s*$]]
    local id3 = _mkAlias(dwtestPattern, function()
        local line = _getFullMatchLine()
        local tokens = {}
        for w in tostring(line or ""):gmatch("%S+") do
            tokens[#tokens + 1] = w
        end

        -- tokens[1] = "dwtest"
        local mode = tokens[2] or ""
        local arg2 = tokens[3] or ""
        local arg3 = tokens[4] or ""

        local function hasVerboseFlag()
            for i = 2, #tokens do
                local t = tokens[i]
                if t == "verbose" or t == "v" then
                    return true
                end
            end
            return false
        end

        local function usage()
            _out("[DWKit Test] Usage:")
            _out("  dwtest")
            _out("  dwtest quiet")
            _out("  dwtest ui [verbose|v]")
            _out("  dwtest room [verbose|v]")
            _out("  dwtest who  [verbose|v]")
            _out("  dwtest verbose|v     (run all tests verbose, if supported)")
        end

        -- ============================================================
        -- Mode: UI Safety Gate (does NOT require DWKit.test.run)
        -- ============================================================
        if mode == "ui" then
            local verbose = hasVerboseFlag()

            local okV, v = _safeRequire("dwkit.ui.ui_validator")
            if not okV or type(v) ~= "table" then
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

            local okCall, a, b, c, err = _callBestEffort(v, "validateAll", { source = "dwtest" })
            if not okCall or a ~= true then
                _err("validateAll failed: " .. tostring(b or c or err))
                return
            end

            if verbose then
                _out("[DWKit Test] UI validateAll details (bounded)")
                _legacyPpTable(b, { maxDepth = 3, maxItems = 40 })
                return
            end

            _out("[DWKit Test] UI validateAll OK")
            return
        end

        -- ============================================================
        -- Test runner: DWKit.test.run OR fallback to self_test_runner.run
        -- (v2026-01-23B): self-heal by calling loader.init() if needed
        -- ============================================================
        local function runSelfTests(opts2)
            opts2 = (type(opts2) == "table") and opts2 or {}
            if opts2.source == nil then
                opts2.source = "dwtest"
            end

            local function tryKitRun()
                local kit = _getKit()
                if type(kit) == "table" and type(kit.test) == "table" and type(kit.test.run) == "function" then
                    local ok, errOrNil = pcall(kit.test.run, opts2)
                    if not ok then
                        _err("DWKit.test.run failed: " .. tostring(errOrNil))
                    end
                    return true
                end
                return false
            end

            local function tryRunnerRun()
                local okR, runner = _safeRequire("dwkit.tests.self_test_runner")
                if okR and type(runner) == "table" and type(runner.run) == "function" then
                    local ok, errOrNil = pcall(runner.run, opts2)
                    if not ok then
                        _err("self_test_runner.run failed: " .. tostring(errOrNil))
                    end
                    return true
                end
                return false
            end

            -- 1) Try immediately
            if tryKitRun() then return true end
            if tryRunnerRun() then return true end

            -- 2) Self-heal: best-effort loader.init(), then retry
            local okL, L = _safeRequire("dwkit.loader.init")
            if okL and type(L) == "table" and type(L.init) == "function" then
                pcall(L.init)
            end

            if tryKitRun() then return true end
            if tryRunnerRun() then return true end

            return false
        end

        -- ============================================================
        -- Optional delegation to dwkit.commands.dwtest (future-proof; best-effort)
        -- (v2026-01-23C): only return if dispatch() returns true
        -- ============================================================
        do
            local okM, mod = _safeRequire("dwkit.commands.dwtest")
            if okM and type(mod) == "table" and type(mod.dispatch) == "function" then
                local kit = _getKit()
                local ctx = {
                    out = function(line2) _out(line2) end,
                    err = function(msg) _err(msg) end,
                    ppTable = function(t, opts2) _legacyPpTable(t, opts2) end,
                    callBestEffort = function(obj, fnName, ...) return _callBestEffort(obj, fnName, ...) end,
                    getKit = function() return kit end,
                    getUiValidator = function()
                        local okV, v = _safeRequire("dwkit.ui.ui_validator")
                        if okV and type(v) == "table" then return v end
                        return nil
                    end,
                }

                -- Try a few tolerant signatures; accept only if dispatch returns true.
                local ok1, r1 = pcall(mod.dispatch, ctx, kit, tokens)
                if ok1 and r1 == true then return end

                local ok2, r2 = pcall(mod.dispatch, ctx, tokens)
                if ok2 and r2 == true then return end

                local ok3, r3 = pcall(mod.dispatch, tokens)
                if ok3 and r3 == true then return end
                -- else continue to inline fallback below
            end
        end

        -- ============================================================
        -- Inline behavior
        -- ============================================================
        if mode == "" then
            if not runSelfTests({}) then
                _err("No test runner available (DWKit.test.run or dwkit.tests.self_test_runner.run). Try: dwinit")
            end
            return
        end

        if mode == "quiet" then
            if not runSelfTests({ quiet = true }) then
                _err("No test runner available (DWKit.test.run or dwkit.tests.self_test_runner.run). Try: dwinit")
            end
            return
        end

        -- allow: dwtest verbose
        if mode == "verbose" or mode == "v" then
            if not runSelfTests({ verbose = true }) then
                _err("No test runner available (DWKit.test.run or dwkit.tests.self_test_runner.run). Try: dwinit")
            end
            return
        end

        -- suite-style targets: room / who
        if mode == "room" or mode == "who" then
            local verbose = hasVerboseFlag()

            -- Best-effort: many runners accept suite/target; we provide BOTH.
            local opts2 = {
                suite = mode,
                target = mode,
                verbose = verbose,
            }

            if not runSelfTests(opts2) then
                _err("No test runner available (DWKit.test.run or dwkit.tests.self_test_runner.run). Try: dwinit")
            end
            return
        end

        -- Anything else is invalid/unknown
        usage()
    end)

    -- Phase 6 split: dwinfo delegates to dwkit.commands.dwinfo (with fallback)
    local dwinfoPattern = [[^dwinfo\s*$]]
    local id4 = _mkAlias(dwinfoPattern, function()
        local kit = _getKit()

        local okM, mod = _safeRequire("dwkit.commands.dwinfo")
        if okM and type(mod) == "table" and type(mod.dispatch) == "function" then
            local ctx = {
                out = function(line2) _out(line2) end,
                err = function(msg) _err(msg) end,
            }

            local ok1, err1 = pcall(mod.dispatch, ctx, kit)
            if ok1 then
                return
            end

            local ok2, err2 = pcall(mod.dispatch, nil, kit)
            if ok2 then
                return
            end

            _out("[DWKit Info] NOTE: dwinfo delegate failed; falling back to inline handler")
            _out("  err1=" .. tostring(err1))
            _out("  err2=" .. tostring(err2))
        end

        -- Inline fallback (legacy behaviour)
        if not _hasBaseline() then
            _err("DWKit.core.runtimeBaseline.printInfo not available. Run loader.init() first.")
            return
        end
        kit.core.runtimeBaseline.printInfo()
    end)

    -- Phase 6 split: dwid delegates to dwkit.commands.dwid (with fallback)
    local dwidPattern = [[^dwid\s*$]]
    local id5 = _mkAlias(dwidPattern, function()
        local kit = _getKit()

        local okM, mod = _safeRequire("dwkit.commands.dwid")
        if okM and type(mod) == "table" and type(mod.dispatch) == "function" then
            local ctx = {
                out = function(line2) _out(line2) end,
                err = function(msg) _err(msg) end,
            }

            local ok1, err1 = pcall(mod.dispatch, ctx, kit)
            if ok1 then
                return
            end

            local ok2, err2 = pcall(mod.dispatch, nil, kit)
            if ok2 then
                return
            end

            _out("[DWKit ID] NOTE: dwid delegate failed; falling back to inline handler")
            _out("  err1=" .. tostring(err1))
            _out("  err2=" .. tostring(err2))
        end

        -- Inline fallback (legacy behaviour) -> alias_legacy
        _legacyPrintIdentity()
    end)

    -- Phase 6 split: dwversion delegates to dwkit.commands.dwversion (with fallback)
    local dwversionPattern = [[^dwversion\s*$]]
    local id6 = _mkAlias(dwversionPattern, function()
        local kit = _getKit()

        local okM, mod = _safeRequire("dwkit.commands.dwversion")
        if okM and type(mod) == "table" and type(mod.dispatch) == "function" then
            local ctx = {
                out = function(line2) _out(line2) end,
                err = function(msg) _err(msg) end,
            }

            local ok1, err1 = pcall(mod.dispatch, ctx, kit, M.VERSION)
            if ok1 then
                return
            end

            local ok2, err2 = pcall(mod.dispatch, nil, kit, M.VERSION)
            if ok2 then
                return
            end

            _out("[DWKit Version] NOTE: dwversion delegate failed; falling back to inline handler")
            _out("  err1=" .. tostring(err1))
            _out("  err2=" .. tostring(err2))
        end

        -- Inline fallback (legacy behaviour) -> alias_legacy
        _legacyPrintVersionSummary()
    end)

    -- Phase 7 split: dwevents delegates to dwkit.commands.dwevents (with fallback)
    local dweventsPattern = [[^dwevents(?:\s+(md))?\s*$]]
    local id7 = _mkAlias(dweventsPattern, function()
        if not _hasEventRegistry() then
            _err("DWKit.bus.eventRegistry not available. Run loader.init() first.")
            return
        end

        -- Robust parse: optional capture groups can be stale; tokenize full line.
        local line = _getFullMatchLine()
        local tokens = {}
        for w in line:gmatch("%S+") do
            tokens[#tokens + 1] = w
        end
        local mode = tokens[2] or ""

        local kit = _getKit()

        -- Phase 7 split: delegate FIRST, fallback inline
        local okM, mod = _safeRequire("dwkit.commands.dwevents")
        if okM and type(mod) == "table" and type(mod.dispatch) == "function" then
            local ctx = {
                out = function(line2) _out(line2) end,
                err = function(msg) _err(msg) end,
            }

            local ok1, err1 = pcall(mod.dispatch, ctx, kit.bus.eventRegistry, mode)
            if ok1 then
                return
            end

            local ok2, err2 = pcall(mod.dispatch, nil, kit.bus.eventRegistry, mode)
            if ok2 then
                return
            end

            _out("[DWKit Events] NOTE: dwevents delegate failed; falling back to inline handler")
            _out("  err1=" .. tostring(err1))
            _out("  err2=" .. tostring(err2))
        end

        -- Inline fallback (legacy behaviour)
        if mode == "md" then
            if type(kit.bus.eventRegistry.toMarkdown) ~= "function" then
                _err("DWKit.bus.eventRegistry.toMarkdown not available.")
                return
            end
            local ok, md = pcall(kit.bus.eventRegistry.toMarkdown, {})
            if not ok then
                _err("dwevents md failed: " .. tostring(md))
                return
            end
            _out(tostring(md))
            return
        end

        kit.bus.eventRegistry.listAll()
    end)

    -- FIX (v2026-01-26B): dwevent now accepts zero-args and prints usage
    local dweventPattern = [[^dwevent(?:\s+(\S+))?\s*$]]
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

        local kit = _getKit()

        -- Phase 7 split: delegate FIRST, fallback inline
        local okM, mod = _safeRequire("dwkit.commands.dwevent")
        if okM and type(mod) == "table" and type(mod.dispatch) == "function" then
            local ctx = {
                out = function(line2) _out(line2) end,
                err = function(msg) _err(msg) end,
            }

            local ok1, err1 = pcall(mod.dispatch, ctx, kit.bus.eventRegistry, evName)
            if ok1 then
                return
            end

            local ok2, err2 = pcall(mod.dispatch, nil, kit.bus.eventRegistry, evName)
            if ok2 then
                return
            end

            _out("[DWKit Event] NOTE: dwevent delegate failed; falling back to inline handler")
            _out("  err1=" .. tostring(err1))
            _out("  err2=" .. tostring(err2))
        end

        -- Inline fallback (legacy behaviour)
        local ok, _, err = kit.bus.eventRegistry.help(evName)
        if not ok then
            _err(err or ("Unknown event: " .. evName))
        end
    end)

    local dwbootPattern = [[^dwboot\s*$]]
    local id9 = _mkAlias(dwbootPattern, function()
        -- Phase 3 split: try delegated handler FIRST (best-effort), then fallback to legacy inline output.
        local okM, mod = _safeRequire("dwkit.commands.dwboot")
        if okM and type(mod) == "table" and type(mod.dispatch) == "function" then
            local ctx = {
                out = function(line) _out(line) end,
                err = function(msg) _err(msg) end,
                callBestEffort = function(obj, fnName, ...) return _callBestEffort(obj, fnName, ...) end,
                legacyPrint = function() _legacyPrintBootHealth() end,
            }

            local ok1, err1 = pcall(mod.dispatch, ctx)
            if ok1 then
                return
            end

            local ok2, err2 = pcall(mod.dispatch)
            if ok2 then
                return
            end

            _out("[DWKit Boot] NOTE: dwboot delegate failed; falling back to inline handler")
            _out("  err1=" .. tostring(err1))
            _out("  err2=" .. tostring(err2))
        end

        _legacyPrintBootHealth()
    end)

    local dwservicesPattern = [[^dwservices\s*$]]
    local id10 = _mkAlias(dwservicesPattern, function()
        -- Phase 8 split: delegate FIRST, fallback to inline legacy printer.
        local okM, mod = _safeRequire("dwkit.commands.dwservices")
        if okM and type(mod) == "table" and type(mod.dispatch) == "function" then
            local kit = _getKit()
            local ctx = {
                out = function(line) _out(line) end,
                err = function(msg) _err(msg) end,
                callBestEffort = function(obj, fnName, ...) return _callBestEffort(obj, fnName, ...) end,
                legacyPrint = function() _legacyPrintServicesHealth() end,
            }

            -- tolerant signatures
            local ok1, err1 = pcall(mod.dispatch, ctx, kit)
            if ok1 then return end

            local ok2, err2 = pcall(mod.dispatch, ctx)
            if ok2 then return end

            local ok3, err3 = pcall(mod.dispatch, kit)
            if ok3 then return end

            _out("[DWKit Services] NOTE: dwservices delegate failed; falling back to inline handler")
            _out("  err1=" .. tostring(err1))
            _out("  err2=" .. tostring(err2))
            _out("  err3=" .. tostring(err3))
        end

        _legacyPrintServicesHealth()
    end)

    -- Phase 9 split: dwpresence delegates to dwkit.commands.dwpresence (with fallback)
    local dwpresencePattern = [[^dwpresence(?:\s+(.+))?\s*$]]
    local id11 = _mkAlias(dwpresencePattern, function()
        local line = _getFullMatchLine()
        local tokens = {}
        for w in tostring(line or ""):gmatch("%S+") do
            tokens[#tokens + 1] = w
        end

        local kit = _getKit()

        local okM, mod = _safeRequire("dwkit.commands.dwpresence")
        if okM and type(mod) == "table" and type(mod.dispatch) == "function" then
            local ctx = {
                out = function(line2) _out(line2) end,
                err = function(msg) _err(msg) end,
                ppTable = function(t, opts2) _legacyPpTable(t, opts2) end,
                callBestEffort = function(obj, fnName, ...) return _callBestEffort(obj, fnName, ...) end,
                getKit = function() return kit end,
                getService = function(name) return _getService(name) end,
                printServiceSnapshot = function(label, svcName) _legacyPrintServiceSnapshot(label, svcName) end,
            }

            -- tolerant signatures; treat explicit false as "not handled"
            local ok1, r1 = pcall(mod.dispatch, ctx, kit, tokens)
            if ok1 and r1 ~= false then return end

            local ok2, r2 = pcall(mod.dispatch, ctx, tokens)
            if ok2 and r2 ~= false then return end

            local ok3, r3 = pcall(mod.dispatch, tokens)
            if ok3 and r3 ~= false then return end

            _out("[DWKit Presence] NOTE: dwpresence delegate returned false; falling back to inline handler")
        end

        -- Inline fallback (legacy behaviour) -> alias_legacy snapshot
        _legacyPrintServiceSnapshot("PresenceService", "presenceService")
    end)

    -- Phase 1 split: dwroom delegates to dwkit.commands.dwroom
    local dwroomPattern = [[^dwroom(?:\s+(status|clear|ingestclip|fixture|refresh))?(?:\s+(\S+))?\s*$]]
    local id11b = _mkAlias(dwroomPattern, function()
        local svc = _getRoomEntitiesServiceBestEffort()
        if type(svc) ~= "table" then
            _err("RoomEntitiesService not available. Run loader.init() first.")
            return
        end

        -- FIX (v2026-01-21F): tokenize FULL match line (matches[0]) when captures exist
        local line = _getFullMatchLine()
        local tokens = {}
        for w in line:gmatch("%S+") do
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
    local dwwhoPattern = [[^dwwho(?:\s+(status|clear|ingestclip|fixture|refresh|set))?(?:\s+(.+))?\s*$]]
    local id11c = _mkAlias(dwwhoPattern, function()
        local svc = _getWhoStoreServiceBestEffort()

        if type(svc) ~= "table" then
            _err(
                "WhoStoreService not available or incomplete. Create/repair src/dwkit/services/whostore_service.lua, then loader.init().")
            return
        end

        -- FIX (v2026-01-21F): tokenize FULL match line (matches[0]) when captures exist
        local line = _getFullMatchLine()
        local tokens = {}
        for w in line:gmatch("%S+") do
            tokens[#tokens + 1] = w
        end

        local sub = tokens[2] or ""
        local arg = ""

        if #tokens >= 3 then
            if sub == "set" then
                -- Allow: dwwho set Bob Alice  => "Bob,Alice"
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
            tempRegexTrigger = function(pat, fn) return tempRegexTrigger(pat, fn) end,
            tempTimer = function(sec, fn) return tempTimer(sec, fn) end,
            whoIngestTextBestEffort = function(s, text, meta) return _whoIngestTextBestEffort(s, text, meta) end,
            printWhoStatus = function(s) _printWhoStatus(s) end,
        }

        local ok1, err1 = pcall(mod.dispatch, ctx, svc, sub, arg)
        if ok1 then
            return
        end

        local ok2, err2 = pcall(mod.dispatch, ctx, svc, sub)
        if ok2 then
            return
        end

        _err("dwwho handler threw error: " .. tostring(err1 or err2))
    end)

    -- Phase 9 split: dwactions delegates to dwkit.commands.dwactions (with fallback)
    local dwactionsPattern = [[^dwactions(?:\s+(.+))?\s*$]]
    local id12 = _mkAlias(dwactionsPattern, function()
        local line = _getFullMatchLine()
        local tokens = {}
        for w in tostring(line or ""):gmatch("%S+") do
            tokens[#tokens + 1] = w
        end

        local kit = _getKit()

        local okM, mod = _safeRequire("dwkit.commands.dwactions")
        if okM and type(mod) == "table" and type(mod.dispatch) == "function" then
            local ctx = {
                out = function(line2) _out(line2) end,
                err = function(msg) _err(msg) end,
                ppTable = function(t, opts2) _legacyPpTable(t, opts2) end,
                callBestEffort = function(obj, fnName, ...) return _callBestEffort(obj, fnName, ...) end,
                getKit = function() return kit end,
                getService = function(name) return _getService(name) end,
                printServiceSnapshot = function(label, svcName) _legacyPrintServiceSnapshot(label, svcName) end,
            }

            local ok1, r1 = pcall(mod.dispatch, ctx, kit, tokens)
            if ok1 and r1 ~= false then return end

            local ok2, r2 = pcall(mod.dispatch, ctx, tokens)
            if ok2 and r2 ~= false then return end

            local ok3, r3 = pcall(mod.dispatch, tokens)
            if ok3 and r3 ~= false then return end

            _out("[DWKit Actions] NOTE: dwactions delegate returned false; falling back to inline handler")
        end

        -- Inline fallback (legacy behaviour) -> alias_legacy snapshot
        _legacyPrintServiceSnapshot("ActionModelService", "actionModelService")
    end)

    -- Phase 9 split: dwskills delegates to dwkit.commands.dwskills (with fallback)
    local dwskillsPattern = [[^dwskills(?:\s+(.+))?\s*$]]
    local id13 = _mkAlias(dwskillsPattern, function()
        local line = _getFullMatchLine()
        local tokens = {}
        for w in tostring(line or ""):gmatch("%S+") do
            tokens[#tokens + 1] = w
        end

        local kit = _getKit()

        local okM, mod = _safeRequire("dwkit.commands.dwskills")
        if okM and type(mod) == "table" and type(mod.dispatch) == "function" then
            local ctx = {
                out = function(line2) _out(line2) end,
                err = function(msg) _err(msg) end,
                ppTable = function(t, opts2) _legacyPpTable(t, opts2) end,
                callBestEffort = function(obj, fnName, ...) return _callBestEffort(obj, fnName, ...) end,
                getKit = function() return kit end,
                getService = function(name) return _getService(name) end,
                printServiceSnapshot = function(label, svcName) _legacyPrintServiceSnapshot(label, svcName) end,
            }

            local ok1, r1 = pcall(mod.dispatch, ctx, kit, tokens)
            if ok1 and r1 ~= false then return end

            local ok2, r2 = pcall(mod.dispatch, ctx, tokens)
            if ok2 and r2 ~= false then return end

            local ok3, r3 = pcall(mod.dispatch, tokens)
            if ok3 and r3 ~= false then return end

            _out("[DWKit Skills] NOTE: dwskills delegate returned false; falling back to inline handler")
        end

        -- Inline fallback (legacy behaviour) -> alias_legacy snapshot
        _legacyPrintServiceSnapshot("SkillRegistryService", "skillRegistryService")
    end)

    local function _getScoreStoreServiceBestEffort()
        local svc = _getService("scoreStoreService")
        if type(svc) == "table" then return svc end
        local ok, mod = _safeRequire("dwkit.services.score_store_service")
        if ok and type(mod) == "table" then return mod end
        return nil
    end

    -- Phase 10 split: dwscorestore delegates to dwkit.commands.dwscorestore (with fallback)
    local dwscorestorePattern = [[^dwscorestore(?:\s+(\S+))?(?:\s+(\S+))?\s*$]]
    local id14 = _mkAlias(dwscorestorePattern, function()
        local svc = _getScoreStoreServiceBestEffort()
        if type(svc) ~= "table" then
            _err("ScoreStoreService not available. Run loader.init() first.")
            return
        end

        -- NOTE: pattern has capture groups; parse directly (safe enough here)
        local sub = (matches and matches[2]) and tostring(matches[2]) or ""
        local arg = (matches and matches[3]) and tostring(matches[3]) or ""

        local okM, mod = _safeRequire("dwkit.commands.dwscorestore")
        if okM and type(mod) == "table" and type(mod.dispatch) == "function" then
            local ctx = {
                out = function(line2) _out(line2) end,
                err = function(msg) _err(msg) end,
                callBestEffort = function(obj, fnName, ...) return _callBestEffort(obj, fnName, ...) end,
            }

            local ok1, err1 = pcall(mod.dispatch, ctx, svc, sub, arg)
            if ok1 then
                return
            end

            local ok2, err2 = pcall(mod.dispatch, nil, svc, sub, arg)
            if ok2 then
                return
            end

            _out("[DWKit ScoreStore] NOTE: dwscorestore delegate failed; falling back to inline handler")
            _out("  err1=" .. tostring(err1))
            _out("  err2=" .. tostring(err2))
        end

        -- Inline fallback (legacy behaviour)
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

    -- FIX (v2026-01-26B): dweventsub now accepts zero-args and prints usage
    local dweventsubPattern = [[^dweventsub(?:\s+(\S+))?\s*$]]
    local id16 = _mkAlias(dweventsubPattern, function()
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

    -- FIX (v2026-01-26B): dweventunsub now accepts zero-args and prints usage
    local dweventunsubPattern = [[^dweventunsub(?:\s+(\S+))?\s*$]]
    local id17 = _mkAlias(dweventunsubPattern, function()
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

    -- Phase 9 split: dwdiag delegates to dwkit.commands.dwdiag (with fallback)
    local dwdiagPattern = [[^dwdiag(?:\s+(.+))?\s*$]]
    local id19 = _mkAlias(dwdiagPattern, function()
        local line = _getFullMatchLine()
        local tokens = {}
        for w in tostring(line or ""):gmatch("%S+") do
            tokens[#tokens + 1] = w
        end

        local kit = _getKit()

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

        -- Inline fallback (legacy behaviour)
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

        -- IMPORTANT: tokenize FULL match line (matches[0]) when captures exist
        local line = _getFullMatchLine()
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
                    ppTable = function(t, opts2) _legacyPpTable(t, opts2) end,
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
                    _legacyPpTable(b, { maxDepth = 3, maxItems = 40 })
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
                    _legacyPpTable(b, { maxDepth = 3, maxItems = 40 })
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
                    _legacyPpTable(b, { maxDepth = 3, maxItems = 40 })
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

    -- Phase 9 split: dwrelease delegates to dwkit.commands.dwrelease (with fallback)
    local dwreleasePattern = [[^dwrelease(?:\s+(.+))?\s*$]]
    local id20 = _mkAlias(dwreleasePattern, function()
        local line = _getFullMatchLine()
        local tokens = {}
        for w in tostring(line or ""):gmatch("%S+") do
            tokens[#tokens + 1] = w
        end

        local kit = _getKit()

        local okM, mod = _safeRequire("dwkit.commands.dwrelease")
        if okM and type(mod) == "table" and type(mod.dispatch) == "function" then
            local ctx = {
                out = function(line2) _out(line2) end,
                err = function(msg) _err(msg) end,
                ppTable = function(t, opts2) _legacyPpTable(t, opts2) end,
                callBestEffort = function(obj, fnName, ...) return _callBestEffort(obj, fnName, ...) end,
                getKit = function() return kit end,

                legacyPrint = function() _printReleaseChecklist() end,
                legacyPrintVersion = function() _legacyPrintVersionSummary() end,
            }

            local ok1, r1 = pcall(mod.dispatch, ctx, kit, tokens)
            if ok1 and r1 ~= false then return end

            local ok2, r2 = pcall(mod.dispatch, ctx, tokens)
            if ok2 and r2 ~= false then return end

            local ok3, r3 = pcall(mod.dispatch, tokens)
            if ok3 and r3 ~= false then return end

            _out("[DWKit Release] NOTE: dwrelease delegate returned false; falling back to inline handler")
        end

        -- Inline fallback (legacy behaviour)
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
