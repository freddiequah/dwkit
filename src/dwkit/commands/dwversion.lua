-- #########################################################################
-- BEGIN FILE: src/dwkit/commands/dwversion.lua
-- #########################################################################
-- Module Name : dwkit.commands.dwversion
-- Owner       : Commands
-- Version     : v2026-01-27A
-- Purpose     :
--   - Command module for: dwversion
--   - Prints consolidated DWKit module versions + runtime baseline (SAFE diagnostics)
--   - Does NOT send gameplay commands
--   - Does NOT start timers or automation
--
-- Public API  :
--   - dispatch(ctx, kit, aliasVersion) -> boolean handled
--   - reset() -> nil
-- #########################################################################

local M = {}

M.VERSION = "v2026-01-27A"

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

local function _safeRequire(name)
    local ok, mod = pcall(require, name)
    if ok then return true, mod end
    return false, mod
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

local function _formatAliasVersion(aliasVersion)
    if aliasVersion == nil then
        return "unknown"
    end

    local t = type(aliasVersion)
    if t == "string" or t == "number" then
        return tostring(aliasVersion)
    end

    if t == "table" then
        local keys = { "VERSION", "serviceVersion", "version", "serviceVersionTag" }
        for _, k in ipairs(keys) do
            local v = aliasVersion[k]
            if type(v) == "string" or type(v) == "number" then
                return tostring(v)
            end
        end
        return "unknown"
    end

    return "unknown"
end

local function _printVersionSummary(ctx, out, kit, aliasVersion)
    if type(kit) ~= "table" then
        out("[DWKit] ERROR: DWKit global not available. Run loader.init() first.")
        return true
    end

    local ident = nil
    if type(kit.core) == "table" and type(kit.core.identity) == "table" then
        ident = kit.core.identity
    else
        local okI, modI = _safeRequire("dwkit.core.identity")
        if okI and type(modI) == "table" then ident = modI end
    end

    local rb = nil
    if type(kit.core) == "table" and type(kit.core.runtimeBaseline) == "table" then
        rb = kit.core.runtimeBaseline
    else
        local okRB, modRB = _safeRequire("dwkit.core.runtime_baseline")
        if okRB and type(modRB) == "table" then rb = modRB end
    end

    local cmdRegVersion = "unknown"
    if type(kit.cmd) == "table" then
        local okV, v = _callBestEffort(kit.cmd, "getRegistryVersion")
        if okV and v then
            cmdRegVersion = tostring(v)
        end
    end

    local evRegVersion = "unknown"
    if type(kit.bus) == "table" and type(kit.bus.eventRegistry) == "table" then
        local okE, v = _callBestEffort(kit.bus.eventRegistry, "getRegistryVersion")
        if okE and v then evRegVersion = tostring(v) end
    else
        local okER, modER = _safeRequire("dwkit.bus.event_registry")
        if okER and type(modER) == "table" then
            local okV, v = pcall(function()
                if type(modER.getRegistryVersion) == "function" then
                    return modER.getRegistryVersion()
                end
                return modER.VERSION
            end)
            if okV and v then evRegVersion = tostring(v) else evRegVersion = "unknown" end
        end
    end

    local evBusVersion = "unknown"
    local okEB, modEB = _safeRequire("dwkit.bus.event_bus")
    if okEB and type(modEB) == "table" then
        evBusVersion = tostring(modEB.VERSION or "unknown")
    end

    local stVersion = "unknown"
    local okST, st = _safeRequire("dwkit.tests.self_test_runner")
    if okST and type(st) == "table" then
        stVersion = tostring(st.VERSION or "unknown")
    end

    local idVersion = ident and tostring(ident.VERSION or "unknown") or "unknown"
    local rbVersion = rb and tostring(rb.VERSION or "unknown") or "unknown"

    local pkgId     = ident and tostring(ident.packageId or "unknown") or "unknown"
    local evp       = ident and tostring(ident.eventPrefix or "unknown") or "unknown"
    local df        = ident and tostring(ident.dataFolderName or "unknown") or "unknown"
    local vts       = ident and tostring(ident.versionTagStyle or "unknown") or "unknown"

    local luaV      = "unknown"
    local mudletV   = "unknown"
    if rb and type(rb.getInfo) == "function" then
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
    out("  commandAliases  = " .. _formatAliasVersion(aliasVersion))
    out("")
    out("[DWKit] Identity (locked):")
    out("  packageId=" .. pkgId .. " eventPrefix=" .. evp .. " dataFolder=" .. df .. " versionTagStyle=" .. vts)
    out("[DWKit] Runtime baseline:")
    out("  lua=" .. luaV .. " mudlet=" .. mudletV)

    return true
end

function M.dispatch(ctx, kit, aliasVersion)
    local out = _mkOut(ctx)
    local err = _mkErr(ctx, out)

    if type(kit) ~= "table" then
        kit = _getKitBestEffort(ctx)
    end

    local okCall, handled = pcall(function()
        return _printVersionSummary(ctx, out, kit, aliasVersion)
    end)

    if okCall and handled then
        return true
    end

    err("dwversion failed: " .. tostring(handled))
    return true
end

function M.reset()
    -- no internal state (kept for uninstall/reset symmetry)
end

return M

-- #########################################################################
-- END FILE: src/dwkit/commands/dwversion.lua
-- #########################################################################
