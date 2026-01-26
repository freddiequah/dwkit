-- #########################################################################
-- Module Name : dwkit.commands.dwhelp
-- Owner       : Commands
-- Version     : v2026-01-26A
-- Purpose     :
--   - Handler for "dwhelp <cmd>" command surface.
--   - SAFE: prints help for a registered DWKit command.
--   - No gameplay sends. No timers. Manual only.
--
-- Public API  :
--   - dispatch(ctx, kit, tokens) -> boolean ok, string|nil err
--     (also supports legacy forms: dispatch(ctx, cmdSurface, name) and dispatch(ctx, tokens))
--   - reset() -> nil
-- #########################################################################

local M = {}

M.VERSION = "v2026-01-26A"

-- -------------------------
-- Safe output helpers
-- -------------------------
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

local function _safeRequire(modName)
    local ok, mod = pcall(require, modName)
    if ok then return true, mod end
    return false, mod
end

local function _tokenize(line)
    line = tostring(line or "")
    local tokens = {}
    for w in line:gmatch("%S+") do
        tokens[#tokens + 1] = w
    end
    return tokens
end

local function _usage(ctx)
    ctx.out("[DWKit Help] Usage:")
    ctx.out("  dwhelp <cmd>")
end

-- -------------------------
-- Resolve command surface (DWKit.cmd preferred)
-- -------------------------
local function _resolveCmdSurfaceBestEffort(arg2)
    -- If caller passed a cmd surface explicitly (legacy)
    if type(arg2) == "table" then
        -- If it looks like DWKit root, prefer .cmd
        if type(arg2.cmd) == "table" then
            return arg2.cmd
        end
        -- Or it might already be a command surface/registry
        return arg2
    end

    -- Prefer runtime surface
    if type(_G.DWKit) == "table" and type(_G.DWKit.cmd) == "table" then
        return _G.DWKit.cmd
    end

    -- Fallback to command registry module
    local okR, reg = _safeRequire("dwkit.bus.command_registry")
    if okR and type(reg) == "table" then
        return reg
    end

    return nil
end

-- Call cmdSurface.help best-effort (function-style and method-style)
local function _callHelpBestEffort(cmdSurface, name)
    if type(cmdSurface) ~= "table" then return false, nil, "cmdSurface not available" end
    if type(cmdSurface.help) ~= "function" then return false, nil, "help() not available" end
    name = tostring(name or "")
    if name == "" then return false, nil, "name empty" end

    -- function-style
    do
        local okP, okFlag, defOrNil, errOrNil = pcall(cmdSurface.help, name, { quiet = true })
        if okP then
            if okFlag == true and type(defOrNil) == "table" then
                return true, defOrNil, nil
            end
            return false, defOrNil, errOrNil or "help() returned false"
        end
    end

    -- method-style
    do
        local okP, okFlag, defOrNil, errOrNil = pcall(cmdSurface.help, cmdSurface, name, { quiet = true })
        if okP then
            if okFlag == true and type(defOrNil) == "table" then
                return true, defOrNil, nil
            end
            return false, defOrNil, errOrNil or "help() returned false"
        end
    end

    return false, nil, "help() threw error"
end

local function _printHelp(ctx, name, def)
    ctx.out("[DWKit Help] " .. tostring(name))

    local owner = tostring(def.ownerModule or "")
    local safety = tostring(def.safety or "")
    local mode = tostring(def.mode or "")
    local syntax = tostring(def.syntax or "")
    local desc = tostring(def.description or "")

    if syntax ~= "" then
        ctx.out("  syntax: " .. syntax)
    end
    if desc ~= "" then
        ctx.out("  desc  : " .. desc)
    end
    if owner ~= "" then
        ctx.out("  owner : " .. owner)
    end
    if mode ~= "" then
        ctx.out("  mode  : " .. mode)
    end
    if safety ~= "" then
        ctx.out("  safety: " .. safety)
    end

    -- Optional extras (best-effort, no assumptions)
    if def.underlyingGameCommand then
        ctx.out("  gameCmd: " .. tostring(def.underlyingGameCommand))
    end
    if def.sideEffects then
        ctx.out("  effects: " .. tostring(def.sideEffects))
    end
end

-- -------------------------
-- Public API
-- -------------------------
function M.dispatch(ctx, a2, a3)
    ctx = _getCtx(ctx)

    -- Supported call shapes:
    --  A) dispatch(ctx, kit, tokens)           <-- preferred (from command_aliases)
    --  B) dispatch(ctx, tokens)               <-- sometimes used
    --  C) dispatch(ctx, cmdSurface, name)     <-- legacy (documented older signature)

    local cmdSurface = nil
    local name = ""

    if type(a2) == "table" and type(a3) == "table" then
        -- A) (kit, tokens)
        cmdSurface = _resolveCmdSurfaceBestEffort(a2)
        local tokens = a3
        name = tostring(tokens[2] or "")
    elseif type(a2) == "table" and a3 == nil then
        -- B) (tokens) OR (kit)
        -- If it's an array-like table and tokens[1] looks like "dwhelp", treat as tokens.
        if a2[1] ~= nil then
            local tokens = a2
            cmdSurface = _resolveCmdSurfaceBestEffort(nil)
            name = tostring(tokens[2] or "")
        else
            -- Probably kit/cmdSurface
            cmdSurface = _resolveCmdSurfaceBestEffort(a2)
            name = ""
        end
    else
        -- C) (cmdSurface, name)
        cmdSurface = _resolveCmdSurfaceBestEffort(a2)
        name = tostring(a3 or "")
    end

    if not cmdSurface then
        ctx.err("DWKit command surface not available. Run loader.init() first.")
        return true
    end

    name = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then
        _usage(ctx)
        return true
    end

    -- Accept "dwhelp dwhelp" etc; just ask registry.
    local ok, def, err = _callHelpBestEffort(cmdSurface, name)
    if not ok or type(def) ~= "table" then
        ctx.err("No help available for: " .. tostring(name) .. (err and (" (" .. tostring(err) .. ")") or ""))
        return true
    end

    _printHelp(ctx, name, def)
    return true
end

function M.reset()
    -- No module state to reset; kept for contract symmetry.
end

return M
