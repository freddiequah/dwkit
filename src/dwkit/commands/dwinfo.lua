-- #########################################################################
-- Module Name : dwkit.commands.dwinfo
-- Owner       : Commands
-- Version     : v2026-01-20F
-- Purpose     :
--   - Command handler for: dwinfo
--   - Prints runtime baseline information (Mudlet/Lua env).
--   - SAFE only. No timers. No send().
--
-- Public API  :
--   - dispatch(ctx?, kit?) -> boolean ok, string|nil err
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
        outFn("[DWKit Info] ERROR: " .. tostring(msg))
    end
end

local function _resolveRuntimeBaseline(kit)
    if type(kit) == "table"
        and type(kit.core) == "table"
        and type(kit.core.runtimeBaseline) == "table"
    then
        return kit.core.runtimeBaseline
    end

    local okRB, modRB = _safeRequire("dwkit.core.runtime_baseline")
    if okRB and type(modRB) == "table" then
        return modRB
    end

    return nil
end

function M.dispatch(ctx, kit)
    local out = _mkOut(ctx)
    local err = _mkErr(ctx, out)

    local rb = _resolveRuntimeBaseline(kit)
    if type(rb) ~= "table" or type(rb.printInfo) ~= "function" then
        err("DWKit.core.runtimeBaseline.printInfo not available. Run loader.init() first.")
        return false, "runtimeBaseline missing"
    end

    local okCall, callErr = pcall(rb.printInfo)
    if not okCall then
        err("runtimeBaseline.printInfo failed: " .. tostring(callErr))
        return false, tostring(callErr)
    end

    return true, nil
end

function M.reset()
    return true
end

return M
