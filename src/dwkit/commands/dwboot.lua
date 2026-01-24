-- #########################################################################
-- Module Name : dwkit.commands.dwboot
-- Owner       : Commands
-- Version     : v2026-01-24A
-- Purpose     :
--   - Command module for: dwboot
--   - Prints DWKit boot wiring/health status (SAFE diagnostics)
--   - Does NOT send gameplay commands
--   - Does NOT start timers or automation
--
-- Public API  :
--   - dispatch(ctx) -> boolean handled
--   - reset() -> nil
-- #########################################################################

local M = {}

M.VERSION = "v2026-01-24A"

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

local function _mkErr(ctx, outFn)
    if type(ctx) == "table" and type(ctx.err) == "function" then
        return ctx.err
    end
    return function(msg)
        outFn("[DWKit Boot] ERROR: " .. tostring(msg))
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

local function _yn(b) return b and "OK" or "MISSING" end

local function _printBootHealth(ctx, out)
    out("[DWKit Boot] Health summary (dwboot)")
    out("")

    local kit = _getKitBestEffort(ctx)
    if type(kit) ~= "table" then
        out("  DWKit global                : MISSING")
        out("")
        out("  Next step:")
        out("    - Run: lua local L=require(\"dwkit.loader.init\"); L.init()")
        return true
    end

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

    out("  DWKit global                : OK")
    out("  core.identity               : " .. _yn(hasIdentity))
    out("  core.runtimeBaseline        : " .. _yn(hasRB))
    out("  cmd (runtime surface)       : " .. _yn(hasCmd))
    out("  bus.commandRegistry         : " .. _yn(hasCmdReg))
    out("  bus.eventRegistry           : " .. _yn(hasEvReg))
    out("  bus.eventBus                : " .. _yn(hasEvBus))
    out("  test.run                    : " .. _yn(hasTest))
    out("  services.commandAliases     : " .. _yn(hasAliases))
    out("")

    local initTs = kit._lastInitTs
    if type(initTs) == "number" then
        out("  lastInitTs                  : " .. tostring(initTs))
    else
        out("  lastInitTs                  : (unknown)")
    end

    local br = kit._bootReadyEmitted
    out("  bootReadyEmitted            : " .. tostring(br == true))

    if type(kit._bootReadyTs) == "number" then
        out("  bootReadyTs                 : " .. tostring(kit._bootReadyTs))

        local okD, s = pcall(os.date, "%Y-%m-%d %H:%M:%S", kit._bootReadyTs)
        if okD and s then
            out("  bootReadyLocal              : " .. tostring(s))
        else
            out("  bootReadyLocal              : (unavailable)")
        end
    end

    if type(kit._bootReadyTsMs) == "number" then
        out("  bootReadyTsMs               : " .. tostring(kit._bootReadyTsMs))
    else
        out("  bootReadyTsMs               : (unknown)")
    end

    if kit._bootReadyEmitError then
        out("  bootReadyEmitError          : " .. tostring(kit._bootReadyEmitError))
    end

    out("")
    out("  load errors (if any):")
    local anyErr = false

    local function showErr(key, val)
        if val ~= nil and tostring(val) ~= "" then
            anyErr = true
            out("    - " .. key .. " = " .. tostring(val))
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
        out("    (none)")
    end

    if type(kit.bus) == "table"
        and type(kit.bus.eventBus) == "table"
        and type(kit.bus.eventBus.getStats) == "function"
    then
        local okS, stats = pcall(kit.bus.eventBus.getStats)
        if okS and type(stats) == "table" then
            out("")
            out("  eventBus stats:")
            out("    version          : " .. tostring(stats.version or "unknown"))
            out("    subscribers      : " .. tostring(stats.subscribers or 0))
            out("    tapSubscribers   : " .. tostring(stats.tapSubscribers or 0))
            out("    emitted          : " .. tostring(stats.emitted or 0))
            out("    delivered        : " .. tostring(stats.delivered or 0))
            out("    handlerErrors    : " .. tostring(stats.handlerErrors or 0))
            out("    tapErrors        : " .. tostring(stats.tapErrors or 0))
        end
    end

    out("")
    out("  Tip: if anything is MISSING, run:")
    out("    lua local L=require(\"dwkit.loader.init\"); L.init()")

    return true
end

function M.dispatch(ctx)
    local out = _mkOut(ctx)
    local err = _mkErr(ctx, out)

    -- If caller provided a legacyPrint fallback, prefer our own implementation,
    -- but keep the fallback callable if something weird happens.
    local okCall, handled = pcall(function()
        return _printBootHealth(ctx, out)
    end)
    if okCall and handled then
        return true
    end

    if type(ctx) == "table" and type(ctx.legacyPrint) == "function" then
        out("[DWKit Boot] NOTE: command module failed; using legacyPrint fallback")
        pcall(ctx.legacyPrint)
        return true
    end

    err("dwboot failed and no legacyPrint fallback available")
    return true
end

function M.reset()
    -- no internal state (kept for uninstall/reset symmetry)
end

return M
