-- #########################################################################
-- BEGIN FILE: src/dwkit/services/command_ctx.lua
-- #########################################################################
-- Module Name : dwkit.services.command_ctx
-- Owner       : Services
-- Version     : v2026-01-27A
-- Purpose     :
--   - Objective extraction from command_aliases.lua:
--       * Provide ONE canonical "command ctx" factory for SAFE commands.
--       * Centralize ctx enrichment that some commands expect:
--           - ctx.makeEventDiagCtx()
--           - ctx.getEventDiagState()
--       * Ensure legacy printer glue is attached via legacy_printers.makeCtx/ensureCtx.
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

M.VERSION = "v2026-01-27A"

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
    if type(_G) == "table" and type(_G.DWKit) == "table" then return _G.DWKit end
    if type(DWKit) == "table" then return DWKit end
    return nil
end

local function _getEventBusBestEffort(ctx, kit)
    local k = _resolveKit(ctx, kit)
    if type(k) == "table" and type(k.bus) == "table" and type(k.bus.eventBus) == "table" then
        return k.bus.eventBus
    end
    local ok, mod = _safeRequire(ctx, "dwkit.bus.event_bus")
    if ok and type(mod) == "table" then
        return mod
    end
    return nil
end

local function _getEventRegistryBestEffort(ctx, kit)
    local k = _resolveKit(ctx, kit)
    if type(k) == "table" and type(k.bus) == "table" and type(k.bus.eventRegistry) == "table" then
        return k.bus.eventRegistry
    end
    local ok, mod = _safeRequire(ctx, "dwkit.bus.event_registry")
    if ok and type(mod) == "table" then
        return mod
    end
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
    opts = opts or {}
    local k = _resolveKit(ctx, kit)

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

    return ctx
end

function M.make(opts)
    opts = opts or {}
    local kit = _resolveKit(nil, opts.kit)

    local ctx = Legacy.makeCtx({
        kit = kit,
        errPrefix = tostring(opts.errPrefix or "[DWKit]"),
        commandAliasesVersion = tostring(opts.commandAliasesVersion or "unknown"),
    })

    return _attach(ctx, kit, opts)
end

function M.ensure(ctx, opts)
    opts = opts or {}
    local kit = _resolveKit(ctx, opts.kit)

    ctx = Legacy.ensureCtx(ctx, {
        kit = kit,
        errPrefix = tostring(opts.errPrefix or "[DWKit]"),
        commandAliasesVersion = tostring(opts.commandAliasesVersion or
        (type(ctx) == "table" and ctx.commandAliasesVersion) or "unknown"),
    })

    return _attach(ctx, kit, opts)
end

return M

-- #########################################################################
-- END FILE: src/dwkit/services/command_ctx.lua
-- #########################################################################
