-- #########################################################################
-- Module Name : dwkit.commands.dwcommands
-- Owner       : Commands
-- Version     : v2026-01-20B
-- Purpose     :
--   - Handler for "dwcommands" command surface.
--   - SAFE: lists command registry or prints Markdown export.
--   - Does not send gameplay commands. No timers. Manual only.
--
-- Public API  :
--   - dispatch(ctx, cmdSurface, mode) -> boolean ok, string|nil err
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
    _fallbackOut("[DWKit Commands] ERROR: " .. tostring(msg))
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
    local ok, a = pcall(fn, ...)
    if ok then
        return true, a
    end
    return false, tostring(a)
end

function M.dispatch(ctx, cmdSurface, mode)
    local C = _getCtx(ctx)

    local cmd = _resolveCmdSurface(cmdSurface)
    if type(cmd) ~= "table" then
        C.err("DWKit.cmd not available. Run loader.init() first.")
        return false, "DWKit.cmd missing"
    end

    mode = tostring(mode or "")

    if mode == "safe" then
        if type(cmd.listSafe) ~= "function" then
            C.err("DWKit.cmd.listSafe not available.")
            return false, "listSafe missing"
        end
        local ok, err = _callBestEffort(cmd.listSafe)
        if not ok then
            C.err("dwcommands safe failed: " .. tostring(err))
            return false, err
        end
        return true, nil
    end

    if mode == "game" then
        if type(cmd.listGame) ~= "function" then
            C.err("DWKit.cmd.listGame not available.")
            return false, "listGame missing"
        end
        local ok, err = _callBestEffort(cmd.listGame)
        if not ok then
            C.err("dwcommands game failed: " .. tostring(err))
            return false, err
        end
        return true, nil
    end

    if mode == "md" then
        if type(cmd.toMarkdown) ~= "function" then
            C.err("DWKit.cmd.toMarkdown not available.")
            return false, "toMarkdown missing"
        end
        local ok, mdOrErr = _callBestEffort(cmd.toMarkdown, {})
        if not ok then
            C.err("dwcommands md failed: " .. tostring(mdOrErr))
            return false, mdOrErr
        end
        C.out(tostring(mdOrErr))
        return true, nil
    end

    -- default: list all
    if type(cmd.listAll) ~= "function" then
        C.err("DWKit.cmd.listAll not available.")
        return false, "listAll missing"
    end

    local ok, err = _callBestEffort(cmd.listAll)
    if not ok then
        C.err("dwcommands failed: " .. tostring(err))
        return false, err
    end

    return true, nil
end

function M.reset()
    -- no persistent state
end

return M
