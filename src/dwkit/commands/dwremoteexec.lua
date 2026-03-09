-- FILE: src/dwkit/commands/dwremoteexec.lua
-- #########################################################################
-- Module Name : dwkit.commands.dwremoteexec
-- Owner       : Commands
-- Version     : v2026-03-09A
-- Purpose     :
--   - SAFE command surface for RemoteExecService.
--   - Status + allowlist management + SAFE ping test.
--   - Adds manual SEND surface for Bucket D. SEND is still receiver allowlist-gated.
--   - No timers, no hidden automation.
--
-- Public API:
--   - getVersion() -> string
--   - dispatch(ctx, kit, tokens) -> boolean ok, string|nil err
--
-- Automation Policy: Manual only
-- #########################################################################

local M = {}

M.VERSION = "v2026-03-09A"

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

local function _joinTokens(tokens, startIndex)
    if type(tokens) ~= "table" then return "" end
    startIndex = tonumber(startIndex) or 1
    if startIndex < 1 then startIndex = 1 end
    local out = {}
    for i = startIndex, #tokens do
        local v = tokens[i]
        if v ~= nil and v ~= "" then
            out[#out + 1] = tostring(v)
        end
    end
    return table.concat(out, " ")
end

local function _stripOuterQuotes(s)
    s = _trim(s)
    if s == "" then return s end
    local first = s:sub(1, 1)
    local last = s:sub(-1)
    if (first == '"' and last == '"') or (first == "'" and last == "'") then
        s = s:sub(2, -2)
        s = _trim(s)
    end
    return s
end

function M.getVersion()
    return tostring(M.VERSION)
end

local function _printStatus(ctx, S)
    local st = S.status and S.status() or (S.getState and S.getState()) or {}
    local stats = (type(st.stats) == "table") and st.stats or {}
    local test = (type(st.test) == "table") and st.test or {}
    local lastCaptured = (type(test.lastCaptured) == "table") and test.lastCaptured or nil

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
    _out(ctx, "  test: hasSendSink=" .. tostring(test.hasSendSink == true))
    if lastCaptured then
        _out(ctx, "  test.lastCaptured: cmd=" .. tostring(lastCaptured.cmd or "") ..
            " from=" .. tostring(lastCaptured.fromProfile or "") ..
            " to=" .. tostring(lastCaptured.toProfile or "") ..
            " source=" .. tostring(lastCaptured.source or ""))
    end
end

local function _printHelp(ctx)
    _out(ctx, "[DWKit RemoteExec] usage")
    _out(ctx, "  dwremoteexec status")
    _out(ctx, "  dwremoteexec ping <targetProfile>")
    _out(ctx, "  dwremoteexec send <targetProfile> <cmd>")
    _out(ctx, "  dwremoteexec can <cmd>")
    _out(ctx, "  dwremoteexec allow list")
    _out(ctx, "  dwremoteexec allow add <prefix>")
    _out(ctx, "  dwremoteexec allow clear")
    _out(ctx, "")
    _out(ctx, "Notes:")
    _out(ctx, "  - Owned-only enforcement uses owned_profiles values (profile labels).")
    _out(ctx, "  - ping/send accept profile labels with spaces (quotes optional).")
    _out(ctx, "  - SEND is receiver allowlist-gated and default OFF until prefix is added.")
end

local function _parseSendTargetAndCmd(tokens)
    local t3 = _trim(tokens[3] or "")
    if t3 == "" then
        return nil, nil, "targetProfile required"
    end

    local target = ""
    local cmdStart = 4

    if t3:sub(1, 1) == '"' or t3:sub(1, 1) == "'" then
        local quote = t3:sub(1, 1)
        local parts = { t3 }
        local closed = (t3:sub(-1) == quote and #t3 >= 2)
        local i = 4
        while closed ~= true and i <= #tokens do
            parts[#parts + 1] = tostring(tokens[i] or "")
            if tostring(tokens[i] or ""):sub(-1) == quote then
                closed = true
                cmdStart = i + 1
                break
            end
            i = i + 1
        end
        if closed == true and cmdStart == 4 then
            cmdStart = 4
        end
        target = _stripOuterQuotes(table.concat(parts, " "))
        if closed ~= true then
            return nil, nil, "unterminated quoted targetProfile"
        end
    else
        target = t3
        cmdStart = 4
    end

    local cmd = _joinTokens(tokens, cmdStart)
    cmd = _stripOuterQuotes(cmd)

    if _trim(target) == "" then
        return nil, nil, "targetProfile required"
    end
    if _trim(cmd) == "" then
        return nil, nil, "cmd required"
    end

    return target, cmd, nil
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
        if type(S.isInstalled) == "function" and S.isInstalled() ~= true and type(S.install) == "function" then
            local ok, err = S.install({ quiet = true })
            if ok ~= true then
                _err(ctx, "[DWKit RemoteExec] install failed: " .. tostring(err))
                return false, tostring(err)
            end
        end
        _printStatus(ctx, S)
        return true, nil
    end

    if t1 == "ping" then
        local raw = _joinTokens(tokens, 3)
        local target = _stripOuterQuotes(raw)
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

    if t1 == "send" then
        local target, cmd, perr = _parseSendTargetAndCmd(tokens)
        if not target then
            _err(ctx, "[DWKit RemoteExec] send: " .. tostring(perr))
            return false, tostring(perr)
        end

        if type(S.canSend) == "function" then
            local gate = S.canSend(cmd)
            if type(gate) == "table" and gate.enabled ~= true then
                _out(ctx, "[DWKit RemoteExec] local allowlist hint: reason=" ..
                    tostring(gate.reason or "unknown") .. " detail=" .. tostring(gate.detail or ""))
            end
        end

        local ok, err = S.send(target, cmd, { source = "dwremoteexec" })
        if ok ~= true then
            _err(ctx, "[DWKit RemoteExec] send failed: " .. tostring(err))
            return false, tostring(err)
        end
        _out(ctx, "[DWKit RemoteExec] send published target=" .. tostring(target) .. " cmd=" .. tostring(cmd))
        return true, nil
    end

    if t1 == "can" then
        local cmd = _joinTokens(tokens, 3)
        cmd = _stripOuterQuotes(cmd)
        if cmd == "" then
            _err(ctx, "[DWKit RemoteExec] can: cmd required")
            return false, "cmd required"
        end
        if type(S.canSend) ~= "function" then
            _err(ctx, "[DWKit RemoteExec] can: RemoteExecService.canSend not available")
            return false, "canSend missing"
        end
        local gate = S.canSend(cmd)
        _out(ctx, "[DWKit RemoteExec] can enabled=" .. tostring(gate.enabled == true) ..
            " reason=" .. tostring(gate.reason or "") ..
            " detail=" .. tostring(gate.detail or "") ..
            " cmd=" .. tostring(gate.cmd or ""))
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
