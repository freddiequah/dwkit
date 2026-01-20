-- #########################################################################
-- Module Name : dwkit.commands.dwversion
-- Owner       : Commands
-- Version     : v2026-01-20F
-- Purpose     :
--   - Command handler for: dwversion
--   - Prints a DWKit version summary (identity, runtime baseline, registries).
--   - SAFE only. No gameplay automation. No timers. No send().
--
-- Public API  :
--   - dispatch(ctx?, kit?, aliasesVersion?) -> boolean ok, string|nil err
--   - reset() -> boolean ok
-- #########################################################################

local M = {}

M.VERSION = "v2026-01-20F"

local function _safeRequire(modName)
    local ok, mod = pcall(require, modName)
    if ok then return true, mod end
    return false, mod
end

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
        outFn("[DWKit Version] ERROR: " .. tostring(msg))
    end
end

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

local function _resolveIdentity(kit)
    if type(kit) == "table" and type(kit.core) == "table" and type(kit.core.identity) == "table" then
        return kit.core.identity
    end
    local okI, modI = _safeRequire("dwkit.core.identity")
    if okI and type(modI) == "table" then
        return modI
    end
    return nil
end

local function _resolveRuntimeBaseline(kit)
    if type(kit) == "table" and type(kit.core) == "table" and type(kit.core.runtimeBaseline) == "table" then
        return kit.core.runtimeBaseline
    end
    local okRB, modRB = _safeRequire("dwkit.core.runtime_baseline")
    if okRB and type(modRB) == "table" then
        return modRB
    end
    return nil
end

local function _resolveEventRegistry(kit)
    if type(kit) == "table" and type(kit.bus) == "table" and type(kit.bus.eventRegistry) == "table" then
        return kit.bus.eventRegistry
    end
    local okER, modER = _safeRequire("dwkit.bus.event_registry")
    if okER and type(modER) == "table" then
        return modER
    end
    return nil
end

local function _resolveEventBusModule()
    local okEB, modEB = _safeRequire("dwkit.bus.event_bus")
    if okEB and type(modEB) == "table" then
        return modEB
    end
    return nil
end

local function _resolveSelfTestRunner()
    local okST, st = _safeRequire("dwkit.tests.self_test_runner")
    if okST and type(st) == "table" then
        return st
    end
    return nil
end

function M.dispatch(ctx, kit, aliasesVersion)
    local out = _mkOut(ctx)
    local err = _mkErr(ctx, out)

    kit = (type(kit) == "table") and kit or _G.DWKit

    if type(kit) ~= "table" then
        err("DWKit global not available. Run loader.init() first.")
        return false, "kit missing"
    end

    local ident = _resolveIdentity(kit)
    local rb    = _resolveRuntimeBaseline(kit)

    local cmdRegVersion = "unknown"
    if type(kit.cmd) == "table" then
        local okV, v = _callBestEffort(kit.cmd, "getRegistryVersion")
        if okV and v then
            cmdRegVersion = tostring(v)
        end
    end

    local evRegVersion = "unknown"
    local evReg = _resolveEventRegistry(kit)
    if type(evReg) == "table" then
        local okV, v = _callBestEffort(evReg, "getRegistryVersion")
        if okV and v then
            evRegVersion = tostring(v)
        elseif type(evReg.VERSION) == "string" then
            evRegVersion = tostring(evReg.VERSION)
        end
    end

    local evBusVersion = "unknown"
    local ebMod = _resolveEventBusModule()
    if type(ebMod) == "table" then
        evBusVersion = tostring(ebMod.VERSION or "unknown")
    end

    local st = _resolveSelfTestRunner()
    local stVersion = (type(st) == "table") and tostring(st.VERSION or "unknown") or "unknown"

    local idVersion = (type(ident) == "table") and tostring(ident.VERSION or "unknown") or "unknown"
    local rbVersion = (type(rb) == "table") and tostring(rb.VERSION or "unknown") or "unknown"

    local pkgId = (type(ident) == "table") and tostring(ident.packageId or "unknown") or "unknown"
    local evp   = (type(ident) == "table") and tostring(ident.eventPrefix or "unknown") or "unknown"
    local df    = (type(ident) == "table") and tostring(ident.dataFolderName or "unknown") or "unknown"
    local vts   = (type(ident) == "table") and tostring(ident.versionTagStyle or "unknown") or "unknown"

    local luaV = "unknown"
    local mudletV = "unknown"
    if type(rb) == "table" and type(rb.getInfo) == "function" then
        local okInfo, info = pcall(rb.getInfo)
        if okInfo and type(info) == "table" then
            luaV = tostring(info.luaVersion or "unknown")
            mudletV = tostring(info.mudletVersion or "unknown")
        end
    end

    out("[DWKit] Version summary:")
    out("  identity        = " .. idVersion)
    out("  runtimeBaseline = " .. rbVersion)
    out("  selfTestRunner  = " .. stVersion)
    out("  commandRegistry = " .. cmdRegVersion)
    out("  eventRegistry   = " .. evRegVersion)
    out("  eventBus        = " .. evBusVersion)
    out("  commandAliases  = " .. tostring(aliasesVersion or "unknown"))
    out("")
    out("[DWKit] Identity (locked):")
    out("  packageId=" .. pkgId .. " eventPrefix=" .. evp .. " dataFolder=" .. df .. " versionTagStyle=" .. vts)
    out("[DWKit] Runtime baseline:")
    out("  lua=" .. luaV .. " mudlet=" .. mudletV)

    return true, nil
end

function M.reset()
    return true
end

return M
