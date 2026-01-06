-- #########################################################################
-- Module Name : dwkit.services.command_aliases
-- Owner       : Services
-- Version     : v2026-01-06C
-- Purpose     :
--   - Install SAFE Mudlet aliases for command discovery/help:
--       * dwcommands [safe|game]
--       * dwhelp <cmd>
--       * dwtest
--       * dwinfo
--   - Calls into DWKit.cmd (dwkit.bus.command_registry), DWKit.test, and runtimeBaseline.
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
--   - DWKit.test (attached by loader.init)
--   - DWKit.core.runtimeBaseline (attached by loader.init)
-- #########################################################################

local M = {}

local STATE = {
    installed = false,
    aliasIds = {
        dwcommands = nil,
        dwhelp = nil,
        dwtest = nil,
        dwinfo = nil,
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

local function _hasTest()
    return type(_G.DWKit) == "table" and type(_G.DWKit.test) == "table" and type(_G.DWKit.test.run) == "function"
end

local function _hasBaseline()
    return type(_G.DWKit) == "table"
        and type(_G.DWKit.core) == "table"
        and type(_G.DWKit.core.runtimeBaseline) == "table"
        and type(_G.DWKit.core.runtimeBaseline.printInfo) == "function"
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
            dwtest = STATE.aliasIds.dwtest,
            dwinfo = STATE.aliasIds.dwinfo,
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

    local ok1, ok2, ok3, ok4 = true, true, true, true

    if STATE.aliasIds.dwcommands then
        ok1 = pcall(killAlias, STATE.aliasIds.dwcommands)
        STATE.aliasIds.dwcommands = nil
    end

    if STATE.aliasIds.dwhelp then
        ok2 = pcall(killAlias, STATE.aliasIds.dwhelp)
        STATE.aliasIds.dwhelp = nil
    end

    if STATE.aliasIds.dwtest then
        ok3 = pcall(killAlias, STATE.aliasIds.dwtest)
        STATE.aliasIds.dwtest = nil
    end

    if STATE.aliasIds.dwinfo then
        ok4 = pcall(killAlias, STATE.aliasIds.dwinfo)
        STATE.aliasIds.dwinfo = nil
    end

    STATE.installed = false

    if not ok1 or not ok2 or not ok3 or not ok4 then
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

    -- Alias 3: dwtest
    local dwtestPattern = [[^dwtest\s*$]]
    local id3 = tempAlias(dwtestPattern, function()
        if not _hasTest() then
            _err("DWKit.test.run not available. Run loader.init() first.")
            return
        end
        DWKit.test.run()
    end)

    -- Alias 4: dwinfo
    local dwinfoPattern = [[^dwinfo\s*$]]
    local id4 = tempAlias(dwinfoPattern, function()
        if not _hasBaseline() then
            _err("DWKit.core.runtimeBaseline.printInfo not available. Run loader.init() first.")
            return
        end
        DWKit.core.runtimeBaseline.printInfo()
    end)

    if not id1 or not id2 or not id3 or not id4 then
        STATE.lastError = "Failed to create one or more aliases"
        -- Best-effort cleanup if one succeeded
        if type(killAlias) == "function" then
            if id1 then pcall(killAlias, id1) end
            if id2 then pcall(killAlias, id2) end
            if id3 then pcall(killAlias, id3) end
            if id4 then pcall(killAlias, id4) end
        end
        return false, STATE.lastError
    end

    STATE.aliasIds.dwcommands = id1
    STATE.aliasIds.dwhelp = id2
    STATE.aliasIds.dwtest = id3
    STATE.aliasIds.dwinfo = id4
    STATE.installed = true
    STATE.lastError = nil

    if not opts.quiet then
        _out("[DWKit Alias] Installed: dwcommands, dwhelp, dwtest, dwinfo")
    end

    return true, nil
end

return M
