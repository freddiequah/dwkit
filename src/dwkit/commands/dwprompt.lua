-- FILE: src/dwkit/commands/dwprompt.lua
-- #########################################################################
-- Module Name : dwkit.commands.dwprompt
-- Owner       : Commands
-- Version     : v2026-02-25B
-- Purpose     :
--   - Implements dwprompt command handler (SAFE + informational GAME wrapper).
--   - Provides prompt detector status/config controls and a manual 'prompt' refresh.
--
-- NOTE:
--   - This command is treated as SAFE under DWKit semantics (informational commands).
--   - Subcommand 'refresh' sends the MUD command 'prompt' (manual only).
--
-- Handler API:
--   - dispatch(ctx, kit, tokens)
-- #########################################################################

local M = {}
M.VERSION = "v2026-02-25B"

local function _getCtx(ctx)
    ctx = (type(ctx) == "table") and ctx or {}
    local C = {
        out  = (type(ctx.out) == "function") and ctx.out or function() end,
        err  = (type(ctx.err) == "function") and ctx.err or function() end,
        send = (type(ctx.send) == "function") and ctx.send or function() return false end,
    }
    return C
end

local function _resolveSvc()
    local ok, svc = pcall(require, "dwkit.services.prompt_detector_service")
    if ok and type(svc) == "table" then
        return true, svc
    end
    return false, tostring(svc)
end

local function _usage(C)
    C.out("[DWKit Prompt] usage")
    C.out("  dwprompt status")
    C.out("  dwprompt refresh          (sends: prompt)")
    C.out("  dwprompt clear            (clears stored prompt spec + user regexes)")
    C.out("  dwprompt set regex <pat>  (replace user regex list)")
    C.out("  dwprompt add regex <pat>  (append user regex)")
    C.out("  dwprompt clear regex      (clear user regex list)")
    C.out("")
    C.out("Notes:")
    C.out("  - Prompt learning is also passive: when you run MUD command 'prompt',")
    C.out("    DWKit will capture 'Your prompt is currently: ...' and persist it.")
    C.out("  - Lua patterns are used for <pat> (not PCRE).")
end

local function _printStatus(C, svc)
    local st = (type(svc.getStatus) == "function") and svc.getStatus() or {}
    C.out("[DWKit Prompt] status (dwprompt)")
    C.out("  serviceVersion=" .. tostring(st.serviceVersion or "unknown"))
    C.out("  configured=" .. tostring(st.configured))
    C.out("  lastUpdatedTs=" .. tostring(st.ts or "nil"))
    C.out("  source=" .. tostring(st.source or "nil"))
    C.out("  lineCountMin=" .. tostring(st.lineCountMin or 0))
    C.out("  lineCountMax=" .. tostring(st.lineCountMax or 0))
    C.out("  userRegexCount=" .. tostring(st.userRegexCount or 0))
    C.out("  derivedRegexCount=" .. tostring(st.derivedRegexCount or 0))

    if type(st.persist) == "table" then
        C.out("[DWKit Prompt] persist")
        C.out("  enabled=" .. tostring(st.persist.enabled))
        C.out("  path=" .. tostring(st.persist.path or "nil"))
        C.out("  lastLoadErr=" .. tostring(st.persist.lastLoadErr or "nil"))
        C.out("  lastSaveErr=" .. tostring(st.persist.lastSaveErr or "nil"))
    end

    if type(st.watcher) == "table" then
        C.out("[DWKit Prompt] watcher")
        C.out("  enabled=" .. tostring(st.watcher.enabled))
        C.out("  installed=" .. tostring(st.watcher.installed))
        C.out("  triggerId=" .. tostring(st.watcher.triggerId or "nil"))
        C.out("  lastErr=" .. tostring(st.watcher.lastErr or "nil"))
    end

    if st.configured ~= true then
        C.out("")
        C.out("  NOTE: prompt spec is not yet stored for this profile.")
        C.out("  - Run: prompt  (MUD command)  OR: dwprompt refresh")
        C.out("  - If capture still fails, add a custom regex: dwprompt add regex <pat>")
    end
end

local function _joinFrom(tokens, idx)
    local out = {}
    for i = idx, #tokens do
        out[#out + 1] = tostring(tokens[i] or "")
    end
    return table.concat(out, " ")
end

function M.dispatch(ctx, kit, tokens)
    local C = _getCtx(ctx)
    if type(tokens) ~= "table" or type(tokens[1]) ~= "string" then
        _usage(C)
        return
    end

    local okS, svcOrErr = _resolveSvc()
    if not okS then
        C.err("[DWKit Prompt] error: failed to load prompt detector service: " .. tostring(svcOrErr))
        return
    end
    local svc = svcOrErr

    local a = tostring(tokens[2] or ""):lower()

    if a == "" or a == "status" then
        _printStatus(C, svc)
        return
    end

    if a == "refresh" then
        C.out("[DWKit Prompt] refresh: sending 'prompt' (watcher will capture output)...")
        local ok = C.send("prompt")
        if ok ~= true then
            C.err("[DWKit Prompt] refresh: send failed (no send() in ctx?)")
        end
        return
    end

    if a == "clear" then
        local b = tostring(tokens[3] or ""):lower()
        if b == "regex" then
            if type(svc.clearUserRegexes) == "function" then
                svc.clearUserRegexes()
                C.out("[DWKit Prompt] cleared user regexes")
            end
            return
        end

        if type(svc.resetAll) == "function" then
            svc.resetAll()
            C.out("[DWKit Prompt] cleared stored prompt spec + regexes (reset)")
        end
        return
    end

    if a == "set" then
        local b = tostring(tokens[3] or ""):lower()
        if b ~= "regex" then
            _usage(C)
            return
        end
        local pat = _joinFrom(tokens, 4)
        pat = tostring(pat or "")
        pat = pat:gsub("^%s+", ""):gsub("%s+$", "")
        if pat == "" then
            C.err("[DWKit Prompt] set regex: empty pattern")
            return
        end
        if type(svc.setUserRegexes) == "function" then
            local ok, err = svc.setUserRegexes({ pat })
            if ok then
                C.out("[DWKit Prompt] set user regex (1)")
            else
                C.err("[DWKit Prompt] set regex failed: " .. tostring(err))
            end
        end
        return
    end

    if a == "add" then
        local b = tostring(tokens[3] or ""):lower()
        if b ~= "regex" then
            _usage(C)
            return
        end
        local pat = _joinFrom(tokens, 4)
        pat = tostring(pat or "")
        pat = pat:gsub("^%s+", ""):gsub("%s+$", "")
        if pat == "" then
            C.err("[DWKit Prompt] add regex: empty pattern")
            return
        end
        if type(svc.addUserRegex) == "function" then
            local ok, err = svc.addUserRegex(pat)
            if ok then
                C.out("[DWKit Prompt] added user regex")
            else
                C.err("[DWKit Prompt] add regex failed: " .. tostring(err))
            end
        end
        return
    end

    _usage(C)
end

return M
