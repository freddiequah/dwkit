-- FILE: src/dwkit/commands/dwremoteexec.lua
-- #########################################################################
-- Module Name : dwkit.commands.dwremoteexec
-- Owner       : Commands
-- Version     : v2026-03-03A
-- Purpose     :
--   - SAFE command surface for RemoteExecService.
--   - Status + allowlist management + SAFE ping test.
--   - Does NOT send gameplay commands by default; RemoteExecService SEND is allowlist-gated.
--
-- Public API:
--   - getVersion() -> string
--   - dispatch(ctx, kit, tokens) -> boolean ok, string|nil err
--
-- Automation Policy: Manual only
-- #########################################################################

local M = {}

M.VERSION = "v2026-03-03A"

local function _out(ctx, s)
    s = tostring(s or "")
    if type(ctx) == "table" and type(ctx.out) == "function" then
        ctx.out(s)
        return
    end
    if type(cecho) == "function" then
        cecho(s .. "\n")
    elseif type(echo) == "function" then
        echo(s .. "\n")
    else
        print(s)
    end
end

local function _err(ctx, s)
    s = tostring(s or "")
    if type(ctx) == "table" and type(ctx.err) == "function" then
        ctx.err(s)
        return
    end
    _out(ctx, s)
end

local function _trim(s)
    s = tostring(s or "")
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function _lc(s)
    return tostring(s or ""):lower()
end

local function _getServiceBestEffort(kit)
    if type(kit) == "table" and type(kit.services) == "table" and type(kit.services.remoteExecService) == "table" then
        return kit.services.remoteExecService
    end
    local ok, mod = pcall(require, "dwkit.services.remote_exec_service")
    if ok and type(mod) == "table" then return mod end
    return nil
end

function M.getVersion()
    return tostring(M.VERSION)
end

local function _printStatus(ctx, S)
    local st = S.status and S.status() or (S.getState and S.getState()) or {}
    local stats = (type(st.stats) == "table") and st.stats or {}

    _out(ctx, "[DWKit RemoteExec] status")
    _out(ctx, "  version   : " .. tostring(st.version or "unknown"))
    _out(ctx, "  installed : " .. tostring(st.installed == true))
    _out(ctx, "  myProfile : " .. tostring(st.myProfile or ""))
    _out(ctx, "  event     : " .. tostring(st.globalEventName or ""))
    _out(ctx, "  allowPrefixes: " .. tostring(type(st.allowPrefixes) == "table" and #st.allowPrefixes or 0))
    if type(st.allowPrefixes) == "table" and #st.allowPrefixes > 0 then
        for i = 1, #st.allowPrefixes do
            _out(ctx, "    - " .. tostring(st.allowPrefixes[i]))
        end
    end
    _out(ctx, "  stats: sends=" .. tostring(stats.sends or 0) ..
        " recv=" .. tostring(stats.recv or 0) ..
        " rejected=" .. tostring(stats.rejected or 0) ..
        " lastSendTs=" .. tostring(stats.lastSendTs or "nil") ..
        " lastRecvTs=" .. tostring(stats.lastRecvTs or "nil") ..
        " lastReject=" .. tostring(stats.lastReject or "nil"))
end

local function _printHelp(ctx)
    _out(ctx, "[DWKit RemoteExec] usage")
    _out(ctx, "  dwremoteexec status")
    _out(ctx, "  dwremoteexec ping <targetProfile>")
    _out(ctx, "  dwremoteexec allow list")
    _out(ctx, "  dwremoteexec allow add <prefix>")
    _out(ctx, "  dwremoteexec allow clear")
    _out(ctx, "")
    _out(ctx, "Notes:")
    _out(ctx, "  - Owned-only enforcement uses owned_profiles values (profile labels).")
    _out(ctx, "  - SEND is allowlist-gated and default OFF (Objective B stays SAFE).")
end

function M.dispatch(ctx, kit, tokens)
    tokens = (type(tokens) == "table") and tokens or {}

    local S = _getServiceBestEffort(kit)
    if type(S) ~= "table" then
        _err(ctx, "[DWKit RemoteExec] ERROR: remote_exec_service not available")
        return false, "service missing"
    end

    local t1 = _lc(tokens[2] or "")
    local t2 = _lc(tokens[3] or "")
    local t3 = tokens[4]

    if t1 == "" or t1 == "help" then
        _printHelp(ctx)
        return true, nil
    end

    if t1 == "status" then
        local okI = true
        if type(S.isInstalled) == "function" and S.isInstalled() ~= true and type(S.install) == "function" then
            local ok, err = S.install({ quiet = true })
            okI = (ok == true)
            if not okI then
                _err(ctx, "[DWKit RemoteExec] install failed: " .. tostring(err))
                return false, tostring(err)
            end
        end
        _printStatus(ctx, S)
        return true, nil
    end

    if t1 == "ping" then
        local target = _trim(tokens[3] or "")
        if target == "" then
            _err(ctx, "[DWKit RemoteExec] ping: targetProfile required")
            return false, "targetProfile required"
        end
        local ok, err = S.ping(target, { source = "dwremoteexec" })
        if ok ~= true then
            _err(ctx, "[DWKit RemoteExec] ping failed: " .. tostring(err))
            return false, tostring(err)
        end
        _out(ctx, "[DWKit RemoteExec] ping sent to: " .. target)
        return true, nil
    end

    if t1 == "allow" then
        if t2 == "list" or t2 == "" then
            local list = (type(S.getAllowlist) == "function") and S.getAllowlist() or {}
            _out(ctx, "[DWKit RemoteExec] allowlist prefixes (" .. tostring(#list) .. "):")
            if #list == 0 then
                _out(ctx, "  (none)  -- SEND is blocked until you add a prefix")
            else
                for i = 1, #list do
                    _out(ctx, "  - " .. tostring(list[i]))
                end
            end
            return true, nil
        end

        if t2 == "add" then
            local prefix = _trim(t3 or "")
            if prefix == "" then
                _err(ctx, "[DWKit RemoteExec] allow add: prefix required")
                return false, "prefix required"
            end
            local ok, err = S.allowPrefix(prefix, { quiet = false })
            if ok ~= true then
                _err(ctx, "[DWKit RemoteExec] allow add failed: " .. tostring(err))
                return false, tostring(err)
            end
            _out(ctx, "[DWKit RemoteExec] allowlist updated (added): " .. prefix)
            return true, nil
        end

        if t2 == "clear" then
            S.clearAllowlist()
            _out(ctx, "[DWKit RemoteExec] allowlist cleared (SEND blocked)")
            return true, nil
        end

        _err(ctx, "[DWKit RemoteExec] unknown allow subcommand: " .. tostring(tokens[3] or ""))
        return false, "unknown allow subcommand"
    end

    _err(ctx, "[DWKit RemoteExec] unknown subcommand: " .. tostring(tokens[2] or ""))
    _printHelp(ctx)
    return false, "unknown subcommand"
end

return M
-- END FILE: src/dwkit/commands/dwremoteexec.lua