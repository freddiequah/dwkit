-- #########################################################################
-- Module Name : dwkit.commands.dwwho
-- Owner       : Commands
-- Version     : v2026-01-19A
-- Purpose     :
--   - Implements dwwho command handler (SAFE + GAME refresh capture).
--   - Split out from dwkit.services.command_aliases (Phase 1 split).
--
-- Public API  :
--   - dispatch(ctx, whoStoreSvc, sub)
--   - reset()  (best-effort cancel pending capture session)
--
-- Notes:
--   - ctx must provide:
--       * out(line), err(msg)
--       * callBestEffort(obj, fnName, ...) -> ok, a, b, c, err
--       * getClipboardText() -> string|nil
--       * resolveSendFn() -> function|nil
--       * killTrigger(id), killTimer(id)
--       * tempRegexTrigger(pattern, fn) -> id
--       * tempTimer(seconds, fn) -> id
--       * whoIngestTextBestEffort(svc, text, meta) -> ok, err|nil
--       * printWhoStatus(svc)
-- #########################################################################

local M = {}
M.VERSION = "v2026-01-19A"

local CAP = {
    active = false,
    started = false,
    lines = nil,
    trigAny = nil,
    timer = nil,
    startedAt = nil,
}

local function _reset(ctx)
    CAP.active = false
    CAP.started = false
    CAP.lines = nil
    CAP.startedAt = nil

    if CAP.trigAny then
        pcall(ctx.killTrigger, CAP.trigAny)
        CAP.trigAny = nil
    end
    if CAP.timer then
        pcall(ctx.killTimer, CAP.timer)
        CAP.timer = nil
    end
end

function M.reset()
    CAP.active = false
    CAP.started = false
    CAP.lines = nil
    CAP.startedAt = nil
    CAP.trigAny = nil
    CAP.timer = nil
end

local function _usage(ctx)
    ctx.out("[DWKit Who] Usage:")
    ctx.out("  dwwho")
    ctx.out("  dwwho status")
    ctx.out("  dwwho clear")
    ctx.out("  dwwho ingestclip")
    ctx.out("  dwwho fixture")
    ctx.out("  dwwho refresh")
    ctx.out("")
    ctx.out("Notes:")
    ctx.out("  - ingestclip reads your clipboard and parses it as WHO output")
    ctx.out("  - SAFE: status/clear/ingestclip/fixture do not send gameplay commands")
    ctx.out("  - GAME: refresh sends 'who' to the MUD and captures output")
end

local function _finalize(ctx, ok, reason, svc)
    local lines = CAP.lines or {}
    _reset(ctx)

    if not ok then
        ctx.out("[DWKit Who] refresh FAILED reason=" .. tostring(reason or "unknown"))
        return
    end

    if type(svc) ~= "table" then
        ctx.out("[DWKit Who] refresh FAILED: WhoStoreService not available")
        return
    end

    local text = table.concat(lines, "\n")

    if type(ctx.whoIngestTextBestEffort) ~= "function" then
        ctx.out("[DWKit Who] refresh ingest FAILED err=whoIngestTextBestEffort ctx helper missing")
        return
    end

    local okIngest, err = ctx.whoIngestTextBestEffort(svc, text, { source = "dwwho:refresh" })
    if okIngest then
        ctx.out("[DWKit Who] refresh OK lines=" .. tostring(#lines))
        if type(ctx.printWhoStatus) == "function" then
            ctx.printWhoStatus(svc)
        end
    else
        ctx.out("[DWKit Who] refresh ingest FAILED err=" .. tostring(err))
    end
end

local function _startCapture(ctx, svc, opts)
    opts = opts or {}
    local timeoutSec = tonumber(opts.timeoutSec or 5) or 5
    if timeoutSec < 2 then timeoutSec = 2 end
    if timeoutSec > 10 then timeoutSec = 10 end

    if CAP.active then
        ctx.out("[DWKit Who] refresh already running (canceling old session)")
        _reset(ctx)
    end

    local sendFn = ctx.resolveSendFn()
    if type(sendFn) ~= "function" then
        ctx.out("[DWKit Who] refresh FAILED: send/sendAll not available in this Mudlet environment")
        return
    end

    CAP.active = true
    CAP.started = false
    CAP.lines = {}
    CAP.startedAt = os.time()

    CAP.trigAny = ctx.tempRegexTrigger([[^(.*)$]], function()
        if not CAP.active then return end
        local line = (matches and matches[2]) and tostring(matches[2]) or ""

        if not CAP.started then
            if line == "Players" or line:match("^%[") or line:match("^Total players:") then
                CAP.started = true
            else
                return
            end
        end

        CAP.lines[#CAP.lines + 1] = line

        if line:match("^%s*%d+%s+characters displayed%.%s*$") then
            _finalize(ctx, true, nil, svc)
        end
    end)

    CAP.timer = ctx.tempTimer(timeoutSec, function()
        if not CAP.active then return end
        _finalize(ctx, false, "timeout(" .. tostring(timeoutSec) .. "s)", svc)
    end)

    ctx.out("[DWKit Who] refresh: sending 'who' + capturing output...")
    pcall(sendFn, "who")
end

function M.dispatch(ctx, svc, sub)
    ctx = ctx or {}
    if type(ctx.out) ~= "function" or type(ctx.err) ~= "function" then
        return
    end

    sub = tostring(sub or "")

    if sub == "" or sub == "status" then
        if type(ctx.printWhoStatus) == "function" then
            ctx.printWhoStatus(svc)
        else
            ctx.err("printWhoStatus ctx helper missing")
        end
        return
    end

    if sub == "clear" then
        local okCall, _, _, _, err = ctx.callBestEffort(svc, "clear", { source = "dwwho" })
        if not okCall then
            ctx.err("clear failed: " .. tostring(err))
            return
        end
        if type(ctx.printWhoStatus) == "function" then
            ctx.printWhoStatus(svc)
        end
        return
    end

    if sub == "ingestclip" then
        local text = ctx.getClipboardText()
        if type(text) ~= "string" or text:gsub("%s+", "") == "" then
            ctx.err("clipboard is empty (copy WHO output first).")
            return
        end

        if type(ctx.whoIngestTextBestEffort) ~= "function" then
            ctx.err("whoIngestTextBestEffort ctx helper missing")
            return
        end

        local okIngest, err = ctx.whoIngestTextBestEffort(svc, text, { source = "dwwho:clipboard" })
        if okIngest then
            ctx.out("[DWKit Who] ingestclip OK")
            if type(ctx.printWhoStatus) == "function" then
                ctx.printWhoStatus(svc)
            end
            return
        end

        ctx.err("ingestclip failed: " .. tostring(err))
        return
    end

    if sub == "fixture" then
        local fixture = table.concat({
            "Zeq",
            "Vzae",
            "Xi",
            "Scynox",
        }, "\n")

        if type(ctx.whoIngestTextBestEffort) ~= "function" then
            ctx.err("whoIngestTextBestEffort ctx helper missing")
            return
        end

        local okIngest, err = ctx.whoIngestTextBestEffort(svc, fixture, { source = "dwwho:fixture" })
        if okIngest then
            ctx.out("[DWKit Who] fixture ingested")
            if type(ctx.printWhoStatus) == "function" then
                ctx.printWhoStatus(svc)
            end
            return
        end

        ctx.err("fixture ingest failed: " .. tostring(err))
        return
    end

    if sub == "refresh" then
        _startCapture(ctx, svc, { timeoutSec = 5 })
        return
    end

    _usage(ctx)
end

return M
