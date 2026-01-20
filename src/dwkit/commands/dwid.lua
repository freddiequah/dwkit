-- #########################################################################
-- Module Name : dwkit.commands.dwid
-- Owner       : Commands
-- Version     : v2026-01-20F
-- Purpose     :
--   - Command handler for: dwid
--   - SAFE identity surface printer.
--   - No gameplay automation. No timers. No send().
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
        outFn("[DWKit ID] ERROR: " .. tostring(msg))
    end
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

function M.dispatch(ctx, kit)
    local out = _mkOut(ctx)
    local err = _mkErr(ctx, out)

    local I = _resolveIdentity(kit)
    if type(I) ~= "table" then
        err("dwkit.core.identity not available. Run loader.init() first.")
        return false, "identity missing"
    end

    local idVersion = tostring(I.VERSION or "unknown")
    local pkgId     = tostring(I.packageId or "unknown")
    local evp       = tostring(I.eventPrefix or "unknown")
    local df        = tostring(I.dataFolderName or "unknown")
    local vts       = tostring(I.versionTagStyle or "unknown")

    out("[DWKit] identity=" .. idVersion
        .. " packageId=" .. pkgId
        .. " eventPrefix=" .. evp
        .. " dataFolder=" .. df
        .. " versionTagStyle=" .. vts)

    return true, nil
end

function M.reset()
    return true
end

return M
