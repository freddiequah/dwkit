-- #########################################################################
-- Module Name : dwkit.services.command_aliases
-- Owner       : Services
-- Version     : v2026-01-06A
-- Purpose     :
--   - Install SAFE Mudlet aliases for command discovery/help:
--       * dwcommands [safe|game]
--       * dwhelp <cmd>
--   - Calls into DWKit.cmd (dwkit.bus.command_registry).
--   - DOES NOT send gameplay commands.
--   - DOES NOT start timers or automation.
--
-- Public API  :
--   - install(opts?) -> boolean ok, string|nil err
--   - uninstall() -> boolean ok, string|nil err
--   - isInstalled() -> boolean
--   - getState() -> table copy
--
-- Events Emitted   : None
-- Events Consumed  : None
-- Persistence      : None
-- Automation Policy: Manual only (invoked by loader.init which is manual)
-- Dependencies     :
--   - Mudlet: tempAlias(), killAlias() (optional but expected)
--   - DWKit.cmd (attached by loader.init)
-- #########################################################################

local M = {}

local STATE = {
    installed = false,
    aliasIds = {
        dwcommands = nil,
        dwhelp = nil,
    },
    lastError = nil,
}

local function _out(line)
    line = tostring(line or "")
    if type(cecho) == "function" then
        cecho(line .. "\n")
    elseif type(echo) == "function" then
        echo(line .. "\n")
    else
        print(line)
    end
end

local function _err(msg)
    _out("[DWKit Alias] ERROR: " .. tostring(msg))
end

local function _hasCmd()
    return type(_G.DWKit) == "table" and type(_G.DWKit.cmd) == "table"
end

function M.isInstalled()
    return STATE.installed and true or false
end

function M.getState()
    return {
        installed = STATE.installed and true or false,
        aliasIds = {
            dwcommands = STATE.aliasIds.dwcommands,
            dwhelp = STATE.aliasIds.dwhelp,
        },
        lastError = STATE.lastError,
    }
end

function M.uninstall()
    if not STATE.installed then
        return true, nil
    end

    if type(killAlias) ~= "function" then
        STATE.lastError = "killAlias() not available"
        return false, STATE.lastError
    end

    local ok1, err1 = true, nil
    local ok2, err2 = true, nil

    if STATE.aliasIds.dwcommands then
        ok1 = pcall(killAlias, STATE.aliasIds.dwcommands)
        STATE.aliasIds.dwcommands = nil
    end

    if STATE.aliasIds.dwhelp then
        ok2 = pcall(killAlias, STATE.aliasIds.dwhelp)
        STATE.aliasIds.dwhelp = nil
    end

    STATE.installed = false

    if not ok1 or not ok2 then
        STATE.lastError = "One or more aliases failed to uninstall"
        return false, STATE.lastError
    end

    STATE.lastError = nil
    return true, nil
end

function M.install(opts)
    opts = opts or {}

    if STATE.installed then
        return true, nil
    end

    if type(tempAlias) ~= "function" then
        STATE.lastError = "tempAlias() not available"
        return false, STATE.lastError
    end

    -- Alias 1: dwcommands [safe|game]
    -- matches[2] is optional group: safe|game
    local dwcommandsPattern = [[^dwcommands(?:\s+(safe|game))?\s*$]]
    local id1 = tempAlias(dwcommandsPattern, function()
        if not _hasCmd() then
            _err("DWKit.cmd not available. Run loader.init() first.")
            return
        end

        local mode = (matches and matches[2]) and tostring(matches[2]) or ""
        if mode == "safe" then
            DWKit.cmd.listSafe()
        elseif mode == "game" then
            DWKit.cmd.listGame()
        else
            DWKit.cmd.listAll()
        end
    end)

    -- Alias 2: dwhelp <cmd>
    -- matches[2] is the command name
    local dwhelpPattern = [[^dwhelp\s+(\S+)\s*$]]
    local id2 = tempAlias(dwhelpPattern, function()
        if not _hasCmd() then
            _err("DWKit.cmd not available. Run loader.init() first.")
            return
        end

        local name = (matches and matches[2]) and tostring(matches[2]) or ""
        if name == "" then
            _err("Usage: dwhelp <cmd>")
            return
        end

        local ok, _, err = DWKit.cmd.help(name)
        if not ok then
            _err(err or ("Unknown command: " .. name))
        end
    end)

    if not id1 or not id2 then
        STATE.lastError = "Failed to create one or more aliases"
        -- Best-effort cleanup if one succeeded
        if type(killAlias) == "function" then
            if id1 then pcall(killAlias, id1) end
            if id2 then pcall(killAlias, id2) end
        end
        return false, STATE.lastError
    end

    STATE.aliasIds.dwcommands = id1
    STATE.aliasIds.dwhelp = id2
    STATE.installed = true
    STATE.lastError = nil

    if not opts.quiet then
        _out("[DWKit Alias] Installed: dwcommands, dwhelp")
    end

    return true, nil
end

return M
