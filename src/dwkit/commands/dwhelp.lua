-- #########################################################################
-- Module Name : dwkit.commands.dwhelp
-- Owner       : Commands
-- Version     : v2026-01-20B
-- Purpose     :
--   - Handler for "dwhelp <cmd>" command surface.
--   - SAFE: prints help for a registered DWKit command.
--   - No gameplay sends. No timers. Manual only.
--
-- Public API  :
--   - dispatch(ctx, cmdSurface, name) -> boolean ok, string|nil err
--   - reset() -> nil
-- #########################################################################

local M = {}

M.VERSION = "v2026-01-20B"

local function _fallbackOut(line)
    line = tostring(line or "")
    if type(cecho) == "function" then
        cecho(line .. "\n")
    elseif type(echo) == "function" then
        echo(line .. "\n")
    else
        print(line)
    end
end

local function _fallbackErr(msg)
    _fallbackOut("[DWKit Help] ERROR: " .. tostring(msg))
end

local function _getCtx(ctx)
    ctx = (type(ctx) == "table") and ctx or {}
    return {
        out = (type(ctx.out) == "function") and ctx.out or _fallbackOut,
        err = (type(ctx.err) == "function") and ctx.err or _fallbackErr,
    }
end

local function _resolveCmdSurface(cmdSurface)
    if type(cmdSurface) == "table" then
        return cmdSurface
    end
    if type(_G.DWKit) == "table" and type(_G.DWKit.cmd) == "table" then
        return _G.DWKit.cmd
    end
    return nil
end

local function _callBestEffort(fn, ...)
    if type(fn) ~= "function" then
        return false, "fn not function"
    end
    local ok, a, b, c = pcall(fn, ...)
    if ok then
        return true, a, b, c
    end
    return false, tostring(a)
end

function M.dispatch(ctx, cmdSurface, name)
    local C = _getCtx(ctx)

    local cmd = _resolveCmdSurface(cmdSurface)
    if type(cmd) ~= "table" then
        C.err("DWKit.cmd not available. Run loader.init() first.")
        return false, "DWKit.cmd missing"
    end

    name = tostring(name or "")
    if name == "" then
        C.err("Usage: dwhelp <cmd>")
        return false, "missing cmd name"
    end

    if type(cmd.help) ~= "function" then
        C.err("DWKit.cmd.help not available.")
        return false, "help missing"
    end

    local ok, a, b, c = _callBestEffort(cmd.help, name)
    if not ok then
        C.err("dwhelp failed: " .. tostring(a))
        return false, a
    end

    -- cmd.help returns: ok(bool), cmdOrNil(table), errOrNil(string)
    if a ~= true then
        C.err(tostring(c or b or ("Unknown command: " .. name)))
        return false, tostring(c or b or "unknown command")
    end

    return true, nil
end

function M.reset()
    -- no persistent state
end

return M
