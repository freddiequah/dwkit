-- #########################################################################
-- BEGIN FILE: src/dwkit/services/command_aliases.lua
-- #########################################################################
-- Module Name : dwkit.services.command_aliases
-- Owner       : Services
-- Version     : v2026-01-27K
-- Purpose     :
--   - Install SAFE Mudlet aliases for DWKit commands.
--   - AUTO-GENERATES SAFE aliases from the Command Registry (best-effort).
--
-- NOTE (Slimming Step 1):
--   - Router fallbacks (routing glue, routered behavior) extracted to:
--       * dwkit.bus.command_router
--
-- NOTE (Slimming Step 2):
--   - Event diagnostics state injection has been extracted to:
--       * dwkit.services.event_diag_state
--       * dwkit.commands.dweventtap / dweventsub / dweventunsub / dweventlog
--     so these can be auto-generated like normal SAFE commands.
--
-- NOTE (Slimming Step 3):
--   - SAFE command enumeration + auto SAFE alias generation loop extracted to:
--       * dwkit.services.alias_factory
--
-- NOTE (StepB/B1-B3):
--   - Mudlet ctx plumbing is centralized in dwkit.core.mudlet_ctx.
--   - dwwho/dwroom are no longer special-cased here.
--     They now rely on ctx (mudlet_ctx) and their own command modules.
--
-- NOTE (StepC):
--   - dwgui/dwscorestore/dwrelease are no longer special-cased here.
--     They are AUTO-SAFE aliases now, and any required special routing lives in:
--       * dwkit.bus.command_router.dispatchGenericCommand() (router-internal)
--
-- NOTE (StepD):
--   - Legacy printer ctx glue extracted to:
--       * dwkit.services.legacy_printers
--   - Command alias-id lifecycle extracted to:
--       * dwkit.services.alias_control (command alias id store/cleanup helpers)
--
-- NOTE (StepE):
--   - dwdiag is no longer special-cased here.
--     It is an AUTO-SAFE alias like the others (dispatch handled by dwkit.commands.dwdiag).
--
-- NOTE (StepF):
--   - Command ctx enrichment extracted to:
--       * dwkit.services.command_ctx
--     (centralizes ctx.makeEventDiagCtx + ctx.getEventDiagState + legacy printers glue)
--
-- NOTE (StepG):
--   - command_aliases no longer provides legacy/event wrapper helpers in deps.
--     alias_factory should rely on deps.makeCtx() (CommandCtx) as the single source of truth.
--
-- IMPORTANT:
--   - tempAlias objects persist in Mudlet even if this module is reloaded via package.loaded=nil.
--   - This module stores alias ids in DWKit root (kit._commandAliasesAliasIds) and cleans them up
--     on install() and uninstall(), preventing duplicate alias execution/output across reloads.
--
-- Public API  :
--   - install(opts?) -> boolean ok, string|nil err
--   - uninstall() -> boolean ok, string|nil err
--   - isInstalled() -> boolean
--   - getState() -> table copy
-- #########################################################################

local M = {}

M.VERSION = "v2026-01-27K"

local Ctx = require("dwkit.core.mudlet_ctx")
local AliasCtl = require("dwkit.services.alias_control")
local CommandCtx = require("dwkit.services.command_ctx")

local CTX0 = Ctx.make({ errPrefix = "[DWKit Alias]" })

local STATE = {
    installed = false,

    -- aliasIds is dynamic (auto-generated):
    --   { [cmdName] = <aliasId>, ... }
    aliasIds = {},

    lastError = nil,
}

local function _out(line) CTX0.out(line) end
local function _err(msg) CTX0.err(msg) end

local function _getKit()
    return CTX0.getKit()
end

local function _hasCmd()
    local kit = _getKit()
    return type(kit) == "table" and type(kit.cmd) == "table"
end

local function _sortedKeys(t)
    return CTX0.sortedKeys(t)
end

local function _safeRequire(modName)
    return CTX0.safeRequire(modName)
end

local function _callBestEffort(obj, fnName, ...)
    return CTX0.callBestEffort(obj, fnName, ...)
end

local function _tokenizeFromMatches()
    return CTX0.tokenizeFromMatches()
end

-- ------------------------------------------------------------
-- Alias-id persistence + cleanup (delegated to AliasCtl)
-- ------------------------------------------------------------
local function _cleanupPriorAliasesBestEffort()
    local kit = _getKit()
    local any = false
    local okCall, res = pcall(AliasCtl.cleanupPriorCommandAliasesBestEffort, kit)
    if okCall and res == true then
        any = true
    end
    if any then
        _out("[DWKit Alias] cleaned up prior aliases (best-effort)")
    end
    return true
end

local function _setGlobalAliasIds(t)
    local kit = _getKit()
    pcall(AliasCtl.setCommandAliasesAliasIds, kit, t)
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
    local ctx = CommandCtx.make({
        kit = kit,
        errPrefix = "[DWKit Alias]",
        commandAliasesVersion = M.VERSION,
    })

    local d = nil
    if type(ctx.getEventDiagState) == "function" then
        d = ctx.getEventDiagState()
    end

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

local function _getEventDiagStateServiceBestEffort()
    local ok, mod = _safeRequire("dwkit.services.event_diag_state")
    if ok and type(mod) == "table" then
        return mod
    end
    return nil
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
    -- If not installed, still do a best-effort cleanup of any persisted ids (reload leftovers)
    if not STATE.installed then
        _cleanupPriorAliasesBestEffort()

        do
            local kit0 = _getKit()
            local S0 = _getEventDiagStateServiceBestEffort()
            if S0 and type(S0.shutdown) == "function" then
                pcall(S0.shutdown, kit0)
            end
        end

        _resetSplitCommandModulesBestEffort()

        STATE.aliasIds = {}
        STATE.lastError = nil
        _setGlobalAliasIds(nil)
        return true, nil
    end

    do
        local kit = _getKit()
        local S = _getEventDiagStateServiceBestEffort()
        if S and type(S.shutdown) == "function" then
            pcall(S.shutdown, kit)
        end
    end

    _resetSplitCommandModulesBestEffort()

    if type(killAlias) ~= "function" then
        STATE.lastError = "killAlias() not available"
        return false, STATE.lastError
    end

    local allOk = true
    for _, id in pairs(STATE.aliasIds or {}) do
        if id then
            local okKill = false
            local okCall, resOk, _ = pcall(AliasCtl.killAliasStrict, id)
            if okCall and resOk == true then
                okKill = true
            end
            if not okKill then allOk = false end
        end
    end

    STATE.aliasIds = {}
    STATE.installed = false
    _setGlobalAliasIds(nil)

    -- also try to remove any stale persisted ids (should be none if we set nil)
    _cleanupPriorAliasesBestEffort()

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
-- Install (AUTO SAFE aliases via alias_factory)
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

    _cleanupPriorAliasesBestEffort()

    local kit = _getKit()
    if type(kit) ~= "table" then
        STATE.lastError = "DWKit not available. Run loader.init() first."
        return false, STATE.lastError
    end

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
        getService = function(name) return CTX0.getService(name) end,
        getRouter = function()
            local ok, mod = _safeRequire("dwkit.bus.command_router")
            if ok and type(mod) == "table" then return mod end
            return nil
        end,
        out = function(line) _out(line) end,
        err = function(msg) _err(msg) end,

        -- Single source of truth: enriched ctx via CommandCtx
        makeCtx = function(kind, k)
            return CommandCtx.make({
                kit = k or kit,
                errPrefix = "[DWKit Alias]",
                commandAliasesVersion = M.VERSION,
            })
        end,
    }

    local safeNames = nil
    if F and type(F.getSafeCommandNamesBestEffort) == "function" then
        safeNames = F.getSafeCommandNamesBestEffort(deps, kit)
    end

    if type(safeNames) ~= "table" or #safeNames == 0 then
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

    local created = {}

    if F and type(F.installAutoSafeAliases) == "function" then
        -- No special-cases now (including dwdiag)
        local special = {}
        local autoCreated = F.installAutoSafeAliases(deps, kit, safeNames, special)
        if type(autoCreated) == "table" then
            for k, v in pairs(autoCreated) do
                created[k] = v
            end
        end
    else
        _out("[DWKit Alias] NOTE: alias_factory not available; SAFE auto generation skipped")

        local R = deps.getRouter()
        if type(R) ~= "table" or type(R.dispatchGenericCommand) ~= "function" then
            STATE.lastError = "command_router not available (dispatchGenericCommand missing)"
            STATE.aliasIds = {}
            return false, STATE.lastError
        end

        for _, cmdName in ipairs(safeNames) do
            cmdName = tostring(cmdName or "")
            if cmdName ~= "" then
                local pat = "^" .. cmdName .. "(?:\\s+(.+))?\\s*$"
                created[cmdName] = _mkAlias(pat, function()
                    local k = _getKit()
                    local tokens = _tokenizeFromMatches()
                    local ctx = deps.makeCtx("generic", k)
                    R.dispatchGenericCommand(ctx, k, cmdName, tokens)
                end)
            end
        end
    end

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
