-- #########################################################################
-- BEGIN FILE: src/dwkit/services/command_ctx.lua
-- #########################################################################
-- Module Name : dwkit.services.command_ctx
-- Owner       : Services
-- Version     : v2026-01-27C
-- Purpose     :
--   - Objective extraction from command_aliases.lua:
--       * Provide ONE canonical "command ctx" factory for SAFE commands.
--       * Centralize ctx enrichment that some commands expect:
--           - ctx.makeEventDiagCtx()
--           - ctx.getEventDiagState()
--       * Ensure legacy printer glue is attached via legacy_printers.ensureCtx().
--
-- StepH follow-up fix:
--   - Expose guiSettings via ctx.getService("guiSettings") best-effort,
--     so dwgui works under the canonical ctx path (no re-special-casing in command_aliases).
--
-- StepO (slimming impact):
--   - Base ctx now comes from dwkit.core.mudlet_ctx (single core entrypoint),
--     then is enriched by legacy_printers + event_diag_state accessors here.
--
-- Design:
--   - SAFE: printing/status only, no timers/automation.
--   - Allowed deps: dwkit.core.mudlet_ctx, dwkit.services.legacy_printers,
--     and best-effort require of dwkit.services.event_diag_state.
--
-- Public API:
--   - make(opts) -> ctx
--   - ensure(ctx, opts) -> ctx
--
-- opts:
--   - kit (table|nil)
--   - errPrefix (string|nil)
--   - commandAliasesVersion (string|nil)
-- #########################################################################

local M = {}

M.VERSION = "v2026-01-27C"

local BaseCtx = require("dwkit.core.mudlet_ctx")
local Legacy = require("dwkit.services.legacy_printers")

local function _safeRequire(ctx, name)
    if type(ctx) == "table" and type(ctx.safeRequire) == "function" then
        return ctx.safeRequire(name)
    end
    local ok, mod = pcall(require, name)
    return ok, mod
end

local function _resolveKit(ctx, kit)
    if type(kit) == "table" then return kit end
    if type(ctx) == "table" and type(ctx.getKit) == "function" then
        local ok, k = pcall(ctx.getKit)
        if ok and type(k) == "table" then return k end
    end
    if type(BaseCtx) == "table" and type(BaseCtx.getKitBestEffort) == "function" then
        local k2 = BaseCtx.getKitBestEffort()
        if type(k2) == "table" then return k2 end
    end
    if type(_G) == "table" and type(_G.DWKit) == "table" then return _G.DWKit end
    if type(DWKit) == "table" then return DWKit end
    return nil
end

local function _getGuiSettingsBestEffort(ctx, kit)
    local k = _resolveKit(ctx, kit)
    if type(k) ~= "table" then return nil end
    if type(k.config) == "table" and type(k.config.guiSettings) == "table" then
        return k.config.guiSettings
    end
    if type(k.core) == "table" and type(k.core.config) == "table" and type(k.core.config.guiSettings) == "table" then
        return k.core.config.guiSettings
    end
    return nil
end

local function _wrapGetServiceForGuiSettings(ctx, kit)
    if type(ctx) ~= "table" then return end
    if ctx._dwkitCommandCtxGetServiceWrapped == true then return end

    local k = _resolveKit(ctx, kit)
    local orig = ctx.getService

    ctx.getService = function(name)
        if tostring(name or "") == "guiSettings" then
            return _getGuiSettingsBestEffort(ctx, k)
        end
        if type(orig) == "function" then
            return orig(name)
        end
        return nil
    end

    ctx._dwkitCommandCtxGetServiceWrapped = true
end

local function _getEventBusBestEffort(ctx, kit)
    local k = _resolveKit(ctx, kit)
    if type(k) == "table" and type(k.bus) == "table" and type(k.bus.eventBus) == "table" then
        return k.bus.eventBus
    end
    local ok, mod = _safeRequire(ctx, "dwkit.bus.event_bus")
    if ok and type(mod) == "table" then return mod end
    return nil
end

local function _getEventRegistryBestEffort(ctx, kit)
    local k = _resolveKit(ctx, kit)
    if type(k) == "table" and type(k.bus) == "table" and type(k.bus.eventRegistry) == "table" then
        return k.bus.eventRegistry
    end
    local ok, mod = _safeRequire(ctx, "dwkit.bus.event_registry")
    if ok and type(mod) == "table" then return mod end
    return nil
end

local function _makeEventDiagCtx(ctx, kit)
    local k = _resolveKit(ctx, kit)

    return {
        out = (type(ctx) == "table" and type(ctx.out) == "function") and ctx.out or function(_) end,
        err = (type(ctx) == "table" and type(ctx.err) == "function") and ctx.err or function(_) end,
        ppTable = (type(ctx) == "table" and type(ctx.ppTable) == "function") and ctx.ppTable or nil,
        ppValue = (type(ctx) == "table" and type(ctx.ppValue) == "function") and ctx.ppValue or nil,

        hasEventBus = function()
            return type(_getEventBusBestEffort(ctx, k)) == "table"
        end,
        hasEventRegistry = function()
            return type(_getEventRegistryBestEffort(ctx, k)) == "table"
        end,
        getEventBus = function()
            return _getEventBusBestEffort(ctx, k)
        end,
        getEventRegistry = function()
            return _getEventRegistryBestEffort(ctx, k)
        end,
    }
end

local function _getEventDiagStateBestEffort(ctx, kit)
    local k = _resolveKit(ctx, kit)
    local ok, S = _safeRequire(ctx, "dwkit.services.event_diag_state")
    if ok and type(S) == "table" and type(S.getState) == "function" then
        local okCall, st = pcall(S.getState, k)
        if okCall and type(st) == "table" then
            return st
        end
    end
    return nil
end

local function _attach(ctx, kit, opts)
    opts = (type(opts) == "table") and opts or {}
    local k = _resolveKit(ctx, kit)

    -- stable metadata used by downstream consumers
    if ctx.commandAliasesVersion == nil then
        ctx.commandAliasesVersion = tostring(opts.commandAliasesVersion or "unknown")
    end

    if type(ctx.makeEventDiagCtx) ~= "function" then
        ctx.makeEventDiagCtx = function()
            return _makeEventDiagCtx(ctx, k)
        end
    end

    if type(ctx.getEventDiagState) ~= "function" then
        ctx.getEventDiagState = function()
            return _getEventDiagStateBestEffort(ctx, k)
        end
    end

    -- StepH fix: make dwgui work through canonical ctx path
    _wrapGetServiceForGuiSettings(ctx, k)

    return ctx
end

function M.make(opts)
    opts = (type(opts) == "table") and opts or {}
    local kit = _resolveKit(nil, opts.kit)

    -- Base ctx from core (single entrypoint)
    local ctx = BaseCtx.make({
        kit = kit,
        errPrefix = tostring(opts.errPrefix or "[DWKit]"),
    })

    -- Enrich with legacy printer helpers (best-effort, does not override)
    local okLegacy, ctx2 = pcall(Legacy.ensureCtx, ctx, {
        kit = kit,
        errPrefix = tostring(opts.errPrefix or "[DWKit]"),
        commandAliasesVersion = tostring(opts.commandAliasesVersion or "unknown"),
    })
    if okLegacy and type(ctx2) == "table" then
        ctx = ctx2
    end

    return _attach(ctx, kit, opts)
end

function M.ensure(ctx, opts)
    opts = (type(opts) == "table") and opts or {}
    local kit = _resolveKit(ctx, opts.kit)

    -- Fill missing core ctx fields (best-effort; does not override)
    ctx = BaseCtx.ensure(ctx, {
        kit = kit,
        errPrefix = tostring(opts.errPrefix or "[DWKit]"),
    })

    -- Enrich with legacy printer helpers (best-effort, does not override)
    local okLegacy, ctx2 = pcall(Legacy.ensureCtx, ctx, {
        kit = kit,
        errPrefix = tostring(opts.errPrefix or "[DWKit]"),
        commandAliasesVersion = tostring(
            opts.commandAliasesVersion or
            (type(ctx) == "table" and ctx.commandAliasesVersion) or
            "unknown"
        ),
    })
    if okLegacy and type(ctx2) == "table" then
        ctx = ctx2
    end

    return _attach(ctx, kit, opts)
end

return M

-- #########################################################################
-- END FILE: src/dwkit/services/command_ctx.lua
-- #########################################################################
