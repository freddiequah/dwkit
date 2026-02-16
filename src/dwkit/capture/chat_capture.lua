-- FILE: src/dwkit/capture/chat_capture.lua
-- #########################################################################
-- Module Name : dwkit.capture.chat_capture
-- Owner       : Capture
-- Version     : v2026-02-15B
-- Purpose     :
--   - SAFE passive capture of MUD output lines for chat parsing.
--   - Installs a single tempRegexTrigger line hook (^(.*)$) and forwards lines to:
--       dwkit.services.chat_router_service.ingestMudLine(line, meta)
--   - MUST NOT send gameplay commands. No timers required. No GMCP.
--
-- Public API:
--   - getVersion() -> string
--   - install(opts?) -> boolean ok, string|nil err
--   - uninstall(opts?) -> boolean ok, string|nil err
--   - getDebugState() -> table
--   - _testIngestLine(line, meta?) -> boolean ok, string|nil err (SAFE test helper; no triggers)
--
-- Notes:
--   - Best-effort prompt filtering: ignore lines that look like prompt (ctx.looksLikePrompt).
--   - If Mudlet APIs missing (tempRegexTrigger/killTrigger), install will fail safely.
--   - Debug breadcrumbs: lastIgnoreKind/lastIgnoreLine updated for empty/prompt ignores.
-- #########################################################################

local M = {}

M.VERSION = "v2026-02-15B"

local Ctx = require("dwkit.core.mudlet_ctx")

local ROOT = {
    installed = false,
    lineTriggerId = nil,

    lastOkTs = nil,
    lastErr = nil,
    lastLine = nil,

    -- NEW: ignore breadcrumbs (why we dropped a line before forwarding)
    lastIgnoreTs = nil,
    lastIgnoreKind = nil, -- "empty" | "prompt"
    lastIgnoreLine = nil,

    seenCount = 0,
    forwardedCount = 0,
    ignoredPromptCount = 0,
    ignoredEmptyCount = 0,
}

local function _nowTs()
    return (type(os) == "table" and type(os.time) == "function") and os.time() or 0
end

local function _trim(s)
    if type(s) ~= "string" then s = tostring(s or "") end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function _isFn(name)
    return (type(_G) == "table" and type(_G[name]) == "function")
end

local function _out(msg, opts)
    opts = (type(opts) == "table") and opts or {}
    if opts.quiet == true then return end
    local s = tostring(msg or "")
    if _isFn("cecho") then
        cecho(s .. "\n")
    elseif _isFn("echo") then
        echo(s .. "\n")
    else
        print(s)
    end
end

local function _setIgnore(kind, line)
    ROOT.lastIgnoreTs = _nowTs()
    ROOT.lastIgnoreKind = tostring(kind or "")
    ROOT.lastIgnoreLine = tostring(line or "")
end

local function _forwardLine(line, meta)
    meta = (type(meta) == "table") and meta or {}

    local okR, RouterOrErr = pcall(require, "dwkit.services.chat_router_service")
    if (not okR) or type(RouterOrErr) ~= "table" then
        return false, "ChatRouterService not available: " .. tostring(RouterOrErr)
    end
    local Router = RouterOrErr

    if type(Router.ingestMudLine) ~= "function" then
        return false, "ChatRouterService.ingestMudLine missing"
    end

    local ok, err = Router.ingestMudLine(line, meta)
    if not ok then
        return false, err
    end

    return true, nil
end

function M.getVersion()
    return tostring(M.VERSION or "unknown")
end

function M.getDebugState()
    return {
        installed = (ROOT.installed == true),
        lineTriggerId = ROOT.lineTriggerId,

        lastOkTs = ROOT.lastOkTs,
        lastErr = ROOT.lastErr,
        lastLine = ROOT.lastLine,

        lastIgnoreTs = ROOT.lastIgnoreTs,
        lastIgnoreKind = ROOT.lastIgnoreKind,
        lastIgnoreLine = ROOT.lastIgnoreLine,

        seenCount = ROOT.seenCount,
        forwardedCount = ROOT.forwardedCount,
        ignoredPromptCount = ROOT.ignoredPromptCount,
        ignoredEmptyCount = ROOT.ignoredEmptyCount,

        version = M.VERSION,
    }
end

function M._testIngestLine(line, meta)
    line = tostring(line or "")
    return _forwardLine(line, meta or { source = "test:chat_capture" })
end

function M.install(opts)
    opts = (type(opts) == "table") and opts or {}

    if ROOT.installed == true and ROOT.lineTriggerId ~= nil then
        return true, nil
    end

    local ctx = Ctx.make({ errPrefix = "[DWKit ChatCapture]" })

    if type(ctx.tempRegexTrigger) ~= "function" then
        ROOT.lastErr = "tempRegexTrigger unavailable (Mudlet API missing)"
        return false, ROOT.lastErr
    end
    if type(ctx.killTrigger) ~= "function" then
        ROOT.lastErr = "killTrigger unavailable (Mudlet API missing)"
        return false, ROOT.lastErr
    end

    -- Install a single catch-all line hook. We keep processing minimal and SAFE.
    local trigId = ctx.tempRegexTrigger("^(.*)$", function()
        local line = ""
        if type(_G) == "table" and type(_G.matches) == "table" then
            -- matches[1] usually contains the full line for tempRegexTrigger("^(.*)$", ...)
            line = tostring(_G.matches[1] or _G.matches[0] or "")
        end

        ROOT.seenCount = (tonumber(ROOT.seenCount or 0) or 0) + 1
        ROOT.lastLine = line

        local clean = _trim(line)
        if clean == "" then
            ROOT.ignoredEmptyCount = (tonumber(ROOT.ignoredEmptyCount or 0) or 0) + 1
            _setIgnore("empty", line)
            return
        end

        if type(ctx.looksLikePrompt) == "function" then
            local okP, isPrompt = pcall(ctx.looksLikePrompt, clean)
            if okP and isPrompt == true then
                ROOT.ignoredPromptCount = (tonumber(ROOT.ignoredPromptCount or 0) or 0) + 1
                _setIgnore("prompt", clean)
                return
            end
        end

        local okF, errF = _forwardLine(clean, {
            source = opts.source or "capture:mud",
            ts = _nowTs(),
            raw = line,
        })

        if okF then
            ROOT.forwardedCount = (tonumber(ROOT.forwardedCount or 0) or 0) + 1
            ROOT.lastOkTs = _nowTs()
            ROOT.lastErr = nil
        else
            ROOT.lastErr = tostring(errF)
        end
    end)

    if trigId == nil then
        ROOT.lastErr = "failed to install tempRegexTrigger"
        return false, ROOT.lastErr
    end

    ROOT.installed = true
    ROOT.lineTriggerId = trigId
    ROOT.lastOkTs = _nowTs()
    ROOT.lastErr = nil

    _out(string.format("[DWKit ChatCapture] installed (id=%s)", tostring(trigId)), opts)

    return true, nil
end

function M.uninstall(opts)
    opts = (type(opts) == "table") and opts or {}

    if ROOT.lineTriggerId ~= nil then
        local ctx = Ctx.make({ errPrefix = "[DWKit ChatCapture]" })
        if type(ctx.killTrigger) == "function" then
            pcall(ctx.killTrigger, ROOT.lineTriggerId)
        elseif type(killTrigger) == "function" then
            pcall(killTrigger, ROOT.lineTriggerId)
        end
    end

    ROOT.installed = false
    ROOT.lineTriggerId = nil
    ROOT.lastOkTs = _nowTs()
    ROOT.lastErr = nil

    _out("[DWKit ChatCapture] uninstalled", opts)

    return true, nil
end

return M
