-- #########################################################################
-- Module Name : dwkit.commands.dwservices
-- Owner       : Commands
-- Version     : v2026-01-24B
-- Purpose     :
--   - Command module for: dwservices
--   - Prints attached DWKit services + versions + load errors (SAFE diagnostics)
--   - Does NOT send gameplay commands
--   - Does NOT start timers or automation
--
-- Public API  :
--   - dispatch(ctx, kit?) -> boolean handled
--   - reset() -> nil
-- #########################################################################

local M = {}

M.VERSION = "v2026-01-24B"

local function _mkOut(ctx)
    if type(ctx) == "table" and type(ctx.out) == "function" then
        return ctx.out
    end
    return function(line)
        line = tostring(line or "")
        if type(cecho) == "function" then
            cecho(line .. "\n")
        elseif type(echo) == "function" then
            echo(line .. "\n")
        else
            print(line)
        end
    end
end

local function _getKitBestEffort(ctx)
    if type(ctx) == "table" and type(ctx.getKit) == "function" then
        local ok, kit = pcall(ctx.getKit)
        if ok and type(kit) == "table" then
            return kit
        end
    end
    if type(_G) == "table" and type(_G.DWKit) == "table" then
        return _G.DWKit
    end
    if type(DWKit) == "table" then
        return DWKit
    end
    return nil
end

function M.dispatch(ctx, kit)
    local out = _mkOut(ctx)

    out("[DWKit Services] Health summary (dwservices)")
    out("")

    -- tolerate both signatures: dispatch(ctx) OR dispatch(ctx, kit)
    if type(kit) ~= "table" then
        kit = _getKitBestEffort(ctx)
    end

    if type(kit) ~= "table" then
        out("  DWKit global: MISSING")
        out("  Next step: lua local L=require(\"dwkit.loader.init\"); L.init()")
        return true
    end

    if type(kit.services) ~= "table" then
        out("  DWKit.services: MISSING")
        return true
    end

    local function showSvc(fieldName, errKey)
        local svc = kit.services[fieldName]
        local ok = (type(svc) == "table")
        local v = ok and tostring(svc.VERSION or "unknown") or "unknown"

        out("  " .. tostring(fieldName) .. " : " .. (ok and "OK" or "MISSING") .. "  version=" .. v)

        local errVal = kit[errKey]
        if errVal ~= nil and tostring(errVal) ~= "" then
            out("    loadError: " .. tostring(errVal))
        end
    end

    -- Keep the EXACT surface used by the legacy inline handler (stable output)
    showSvc("presenceService", "_presenceServiceLoadError")
    showSvc("actionModelService", "_actionModelServiceLoadError")
    showSvc("skillRegistryService", "_skillRegistryServiceLoadError")
    showSvc("scoreStoreService", "_scoreStoreServiceLoadError")

    return true
end

function M.reset()
    -- no internal state (kept for uninstall/reset symmetry)
end

return M
