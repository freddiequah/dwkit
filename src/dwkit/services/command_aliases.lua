-- #########################################################################
-- BEGIN FILE: src/dwkit/services/command_aliases.lua
-- #########################################################################
-- Module Name : dwkit.services.command_aliases
-- Owner       : Services
-- Version     : v2026-01-27Q
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
-- NOTE (StepH):
--   - command-surface lifecycle cleanup (event diag shutdown + reset split command modules)
--     moved OUT of this module into:
--       * dwkit.services.alias_control.cleanupCommandSurfaceBestEffort()
--
-- NOTE (StepL):
--   - command_aliases no longer depends on dwkit.core.mudlet_ctx directly.
--     It uses dwkit.services.command_ctx as the single ctx entrypoint.
--
-- NOTE (StepM):
--   - command_aliases no longer carries duplicated "ctx fallback helpers".
--     It relies on CTX0 (CommandCtx) for out/err/safeRequire/callBestEffort/tokenize/sortedKeys/getService.
--
-- NOTE (StepN):
--   - command_aliases no longer reports Event Diagnostics summary in getState().
--     Event-diag reporting/summary is owned by:
--       * dwkit.services.event_diag_state (e.g. getSummary/getState)
--       * event-diag commands (dwevent* / dwdiag etc.)
--
-- NOTE (StepO):
--   - Removed CTX0 fallback shim. command_aliases assumes CommandCtx.make() is available and canonical.
--
-- NOTE (StepQ):
--   - alias_factory is now REQUIRED (fail-fast if missing).
--   - Removed all fallback alias generation paths from this module:
--       * no safe_command_defaults fallback
--       * no manual alias loop fallback
--     This makes command_aliases a thin orchestrator only.
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

M.VERSION = "v2026-01-27Q"

local AliasCtl = require("dwkit.services.alias_control")
local CommandCtx = require("dwkit.services.command_ctx")

-- Base ctx for this module (single entrypoint via CommandCtx)
local CTX0 = CommandCtx.make({
    kit = nil, -- best-effort resolve
    errPrefix = "[DWKit Alias]",
    commandAliasesVersion = M.VERSION,
})

-- Canonical ctx surface (no duplicated helpers here)
local _out = CTX0.out
local _err = CTX0.err
local _getKit = CTX0.getKit
local _sortedKeys = CTX0.sortedKeys
local _safeRequire = CTX0.safeRequire
local _callBestEffort = CTX0.callBestEffort
local _tokenizeFromMatches = CTX0.tokenizeFromMatches
local _getService = CTX0.getService

local STATE = {
    installed = false,

    -- aliasIds is dynamic (auto-generated):
    --   { [cmdName] = <aliasId>, ... }
    aliasIds = {},

    lastError = nil,
}

local function _hasCmd()
    local kit = _getKit()
    return type(kit) == "table" and type(kit.cmd) == "table"
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

    return {
        installed = STATE.installed and true or false,
        aliasIds = aliasIds,
        lastError = STATE.lastError,
    }
end

function M.uninstall()
    -- If not installed, still do a best-effort cleanup of any persisted ids (reload leftovers)
    if not STATE.installed then
        _cleanupPriorAliasesBestEffort()

        do
            local kit0 = _getKit()
            pcall(AliasCtl.cleanupCommandSurfaceBestEffort, kit0, { reason = "uninstall-not-installed" })
        end

        STATE.aliasIds = {}
        STATE.lastError = nil
        _setGlobalAliasIds(nil)
        return true, nil
    end

    do
        local kit = _getKit()
        pcall(AliasCtl.cleanupCommandSurfaceBestEffort, kit, { reason = "uninstall" })
    end

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
-- Install (AUTO SAFE aliases via alias_factory) - REQUIRED
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

    -- StepQ: alias_factory is required (fail-fast)
    local okF, F = _safeRequire("dwkit.services.alias_factory")
    if not okF or type(F) ~= "table" then
        STATE.lastError = "alias_factory not available (required)"
        STATE.aliasIds = {}
        return false, STATE.lastError
    end

    local deps = {
        safeRequire = _safeRequire,
        callBestEffort = _callBestEffort,
        mkAlias = _mkAlias,
        tokenizeFromMatches = _tokenizeFromMatches,
        hasCmd = _hasCmd,
        getKit = _getKit,
        getService = _getService,
        getRouter = function()
            local ok, mod = _safeRequire("dwkit.bus.command_router")
            if ok and type(mod) == "table" then return mod end
            return nil
        end,
        out = _out,
        err = _err,

        -- Single source of truth: enriched ctx via CommandCtx
        makeCtx = function(kind, k)
            return CommandCtx.make({
                kit = k or kit,
                errPrefix = "[DWKit Alias]",
                commandAliasesVersion = M.VERSION,
            })
        end,
    }

    -- StepQ: Safe name selection is owned by alias_factory only
    local safeNames = nil
    if type(F.getSafeCommandNamesBestEffort) == "function" then
        safeNames = F.getSafeCommandNamesBestEffort(deps, kit)
    end
    if type(safeNames) ~= "table" or #safeNames == 0 then
        if type(F.getDefaultSafeCommandNamesBestEffort) == "function" then
            safeNames = F.getDefaultSafeCommandNamesBestEffort(deps)
        end
    end

    if type(safeNames) ~= "table" or #safeNames == 0 then
        STATE.lastError = "No SAFE commands available (alias_factory returned empty)"
        STATE.aliasIds = {}
        return false, STATE.lastError
    end

    if type(F.installAutoSafeAliases) ~= "function" then
        STATE.lastError = "alias_factory.installAutoSafeAliases missing (required)"
        STATE.aliasIds = {}
        return false, STATE.lastError
    end

    -- No special-cases now (including dwdiag)
    local special = {}
    local created = F.installAutoSafeAliases(deps, kit, safeNames, special)

    if type(created) ~= "table" then
        STATE.lastError = "alias_factory did not return created aliases table"
        STATE.aliasIds = {}
        return false, STATE.lastError
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
