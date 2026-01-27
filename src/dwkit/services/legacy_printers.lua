-- #########################################################################
-- BEGIN FILE: src/dwkit/services/legacy_printers.lua
-- #########################################################################
-- Module Name : dwkit.services.legacy_printers
-- Owner       : Services
-- Version     : v2026-01-27A
-- Purpose     :
--   - Centralize ctx glue for legacy printing helpers (alias_legacy).
--   - Used by:
--       * dwkit.services.command_aliases (dwdiag + ctx factory for SAFE aliases)
--       * dwkit.bus.command_router (fallback printing when ctx lacks helpers)
--
-- Design:
--   - SAFE: printing only, no timers/automation.
--   - Uses dwkit.core.mudlet_ctx for normalized ctx, and dwkit.commands.alias_legacy
--     for printer implementations.
--
-- Public API:
--   - makeCtx(opts) -> ctx (attached legacy printers + pp helpers)
--   - ensureCtx(ctx, opts) -> ctx (idempotent attach)
--   - printIdentity(ctx, kit)
--   - printVersionSummary(ctx, kit, commandAliasesVersion)
--   - printBootHealth(ctx, kit)
--   - printServicesHealth(ctx, kit)
--   - printServiceSnapshot(ctx, kit, label, svcNameOrSvc)
--   - ppValue(v)
--   - ppTable(ctx, t, opts)
-- #########################################################################

local M = {}

M.VERSION = "v2026-01-27A"

local Ctx = require("dwkit.core.mudlet_ctx")

local function _safeRequire(ctx, name)
    if type(ctx) == "table" and type(ctx.safeRequire) == "function" then
        return ctx.safeRequire(name)
    end
    local ok, mod = pcall(require, name)
    return ok, mod
end

local function _getLegacyBestEffort(ctx)
    local ok, mod = _safeRequire(ctx, "dwkit.commands.alias_legacy")
    if ok and type(mod) == "table" then return mod end
    return nil
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

local function _resolveService(ctx, kit, svcNameOrSvc)
    if type(svcNameOrSvc) == "table" then return svcNameOrSvc end
    local name = tostring(svcNameOrSvc or "")
    if name == "" then return nil end

    if type(ctx) == "table" and type(ctx.getService) == "function" then
        local ok, svc = pcall(ctx.getService, name)
        if ok and type(svc) == "table" then return svc end
    end

    if type(kit) == "table" then
        if type(kit.services) == "table" and type(kit.services[name]) == "table" then
            return kit.services[name]
        end
        if type(kit[name]) == "table" then
            return kit[name]
        end
    end

    return nil
end

function M.ppValue(v)
    local L = _getLegacyBestEffort(nil)
    if L and type(L.ppValue) == "function" then
        return L.ppValue(v)
    end
    return tostring(v)
end

function M.ppTable(ctx, t, opts)
    local L = _getLegacyBestEffort(ctx)
    if L and type(L.ppTable) == "function" then
        return L.ppTable(ctx, t, opts)
    end
    if type(ctx) == "table" and type(ctx.out) == "function" then
        ctx.out(tostring(t))
        return
    end
    print(tostring(t))
end

function M.printIdentity(ctx, kit)
    local L = _getLegacyBestEffort(ctx)
    if L and type(L.printIdentity) == "function" then
        return L.printIdentity(ctx)
    end
    if type(ctx) == "table" and type(ctx.err) == "function" then
        ctx.err("alias_legacy.printIdentity not available")
    end
end

function M.printVersionSummary(ctx, kit, commandAliasesVersion)
    local L = _getLegacyBestEffort(ctx)
    if L and type(L.printVersionSummary) == "function" then
        return L.printVersionSummary(ctx, commandAliasesVersion)
    end
    if type(ctx) == "table" and type(ctx.err) == "function" then
        ctx.err("alias_legacy.printVersionSummary not available")
    end
end

function M.printBootHealth(ctx, kit)
    local L = _getLegacyBestEffort(ctx)
    if L and type(L.printBootHealth) == "function" then
        return L.printBootHealth(ctx)
    end
    if type(ctx) == "table" and type(ctx.err) == "function" then
        ctx.err("alias_legacy.printBootHealth not available")
    end
end

function M.printServicesHealth(ctx, kit)
    local L = _getLegacyBestEffort(ctx)
    if L and type(L.printServicesHealth) == "function" then
        return L.printServicesHealth(ctx)
    end
    if type(ctx) == "table" and type(ctx.err) == "function" then
        ctx.err("alias_legacy.printServicesHealth not available")
    end
end

function M.printServiceSnapshot(ctx, kit, label, svcNameOrSvc)
    local k = _resolveKit(ctx, kit)
    local svc = _resolveService(ctx, k, svcNameOrSvc)

    local L = _getLegacyBestEffort(ctx)
    if L and type(L.printServiceSnapshot) == "function" then
        return L.printServiceSnapshot(ctx, label, svc)
    end
    if type(ctx) == "table" and type(ctx.err) == "function" then
        ctx.err("alias_legacy.printServiceSnapshot not available")
    end
end

local function _attach(ctx, kit, opts)
    opts = opts or {}
    ctx.commandAliasesVersion = tostring(opts.commandAliasesVersion or ctx.commandAliasesVersion or "unknown")

    if type(ctx.ppValue) ~= "function" then
        ctx.ppValue = function(v) return M.ppValue(v) end
    end
    if type(ctx.ppTable) ~= "function" then
        ctx.ppTable = function(t, o) return M.ppTable(ctx, t, o) end
    end

    if type(ctx.legacyPrintIdentity) ~= "function" then
        ctx.legacyPrintIdentity = function() return M.printIdentity(ctx, kit) end
    end
    if type(ctx.legacyPrintVersionSummary) ~= "function" then
        ctx.legacyPrintVersionSummary = function()
            return M.printVersionSummary(ctx, kit, ctx.commandAliasesVersion)
        end
    end
    if type(ctx.legacyPrintBoot) ~= "function" then
        ctx.legacyPrintBoot = function() return M.printBootHealth(ctx, kit) end
    end
    if type(ctx.legacyPrintServices) ~= "function" then
        ctx.legacyPrintServices = function() return M.printServicesHealth(ctx, kit) end
    end

    if type(ctx.printServiceSnapshot) ~= "function" then
        ctx.printServiceSnapshot = function(label, svcNameOrSvc)
            return M.printServiceSnapshot(ctx, kit, label, svcNameOrSvc)
        end
    end

    return ctx
end

function M.makeCtx(opts)
    opts = opts or {}
    local kit = _resolveKit(nil, opts.kit)
    local errPrefix = tostring(opts.errPrefix or "[DWKit Legacy]")
    local ctx = Ctx.make({ kit = kit, errPrefix = errPrefix })

    return _attach(ctx, kit, opts)
end

function M.ensureCtx(ctx, opts)
    opts = opts or {}
    local kit = _resolveKit(ctx, opts.kit)
    ctx = Ctx.ensure(ctx, { kit = kit, errPrefix = tostring(opts.errPrefix or "[DWKit Legacy]") })

    return _attach(ctx, kit, opts)
end

return M

-- #########################################################################
-- END FILE: src/dwkit/services/legacy_printers.lua
-- #########################################################################
