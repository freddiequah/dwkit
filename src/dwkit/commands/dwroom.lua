-- #########################################################################
-- Module Name : dwkit.commands.dwroom
-- Owner       : Commands
-- Version     : v2026-01-19A
-- Purpose     :
--   - Implements dwroom command handler (SAFE + GAME refresh capture).
--   - Split out from dwkit.services.command_aliases (Phase 1 split).
--
-- Public API  :
--   - dispatch(ctx, roomEntitiesSvc, sub, arg)
--   - reset()  (best-effort cancel pending capture session)
--
-- Notes:
--   - ctx must provide:
--       * out(line), err(msg)
--       * callBestEffort(obj, fnName, ...) -> ok, a, b, c, err
--       * getClipboardText() -> string|nil
--       * resolveSendFn() -> function|nil
--       * looksLikePrompt(line) -> boolean
--       * killTrigger(id), killTimer(id)
--       * tempRegexTrigger(pattern, fn) -> id
--       * tempTimer(seconds, fn) -> id
-- #########################################################################

local M = {}
M.VERSION = "v2026-01-19A"

-- Room capture session local to this command handler
local CAP = {
    active = false,
    started = false,
    lines = nil,
    trigAny = nil,
    timer = nil,
    startedAt = nil,
    assumeCap = false,
}

local function _reset(ctx)
    CAP.active = false
    CAP.started = false
    CAP.lines = nil
    CAP.startedAt = nil
    CAP.assumeCap = false

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
    -- best-effort if someone calls reset() without ctx (rare)
    -- no-op if we cannot kill triggers/timers
    CAP.active = false
    CAP.started = false
    CAP.lines = nil
    CAP.startedAt = nil
    CAP.assumeCap = false
    CAP.trigAny = nil
    CAP.timer = nil
end

local function _usage(ctx)
    ctx.out("[DWKit Room] Usage:")
    ctx.out("  dwroom")
    ctx.out("  dwroom status")
    ctx.out("  dwroom clear")
    ctx.out("  dwroom ingestclip [cap]")
    ctx.out("  dwroom fixture")
    ctx.out("  dwroom refresh [cap]")
    ctx.out("")
    ctx.out("Notes:")
    ctx.out("  - ingestclip reads your clipboard and parses it as LOOK output")
    ctx.out("  - refresh sends 'look' to the MUD and captures output (GAME)")
    ctx.out("  - 'cap' treats Capitalized names as players (temporary heuristic)")
end

local function _ingestLook(ctx, svc, text, meta)
    meta = (type(meta) == "table") and meta or {}

    if type(svc) ~= "table" or type(svc.ingestLookText) ~= "function" then
        ctx.err("RoomEntitiesService.ingestLookText not available.")
        return false, "missing ingestLookText"
    end

    local okCall, a, b, c, err = ctx.callBestEffort(svc, "ingestLookText", text, meta)
    if not okCall or a == false then
        return false, tostring(b or c or err or "ingestLookText failed")
    end
    return true, nil
end

local function _captureFinalize(ctx, ok, reason, svc)
    local lines = CAP.lines or {}
    local assumeCap = (CAP.assumeCap == true)

    _reset(ctx)

    if not ok then
        ctx.out("[DWKit Room] refresh FAILED reason=" .. tostring(reason or "unknown"))
        return
    end

    if type(svc) ~= "table" then
        ctx.out("[DWKit Room] refresh FAILED: RoomEntitiesService not available")
        return
    end

    -- Remove trailing prompt line if accidentally captured
    if #lines > 0 and ctx.looksLikePrompt(lines[#lines]) then
        table.remove(lines, #lines)
    end

    local text = table.concat(lines, "\n")
    if text:gsub("%s+", "") == "" then
        ctx.out("[DWKit Room] refresh FAILED: captured empty look output")
        return
    end

    local okIngest, err = _ingestLook(ctx, svc, text, {
        source = "dwroom:refresh",
        assumeCapitalizedAsPlayer = assumeCap,
    })

    if not okIngest then
        ctx.out("[DWKit Room] refresh ingest FAILED err=" .. tostring(err))
        return
    end

    ctx.out("[DWKit Room] refresh OK lines=" .. tostring(#lines) .. " cap=" .. tostring(assumeCap == true))

    if type(ctx.printRoomEntitiesStatus) == "function" then
        ctx.printRoomEntitiesStatus(svc)
    end
end

local function _captureStart(ctx, svc, opts)
    opts = opts or {}
    local timeoutSec = tonumber(opts.timeoutSec or 5) or 5
    if timeoutSec < 2 then timeoutSec = 2 end
    if timeoutSec > 10 then timeoutSec = 10 end

    local assumeCap = (opts.assumeCap == true)

    if CAP.active then
        ctx.out("[DWKit Room] refresh already running (canceling old session)")
        _reset(ctx)
    end

    local sendFn = ctx.resolveSendFn()
    if type(sendFn) ~= "function" then
        ctx.out("[DWKit Room] refresh FAILED: send/sendAll not available in this Mudlet environment")
        return
    end

    CAP.active = true
    CAP.started = false
    CAP.lines = {}
    CAP.startedAt = os.time()
    CAP.assumeCap = assumeCap

    CAP.trigAny = ctx.tempRegexTrigger([[^(.*)$]], function()
        if not CAP.active then return end
        local line = (matches and matches[2]) and tostring(matches[2]) or ""

        -- End condition: prompt-like line (best-effort)
        if CAP.started and ctx.looksLikePrompt(line) then
            _captureFinalize(ctx, true, nil, svc)
            return
        end

        -- Ignore the echoed command itself if it appears
        if not CAP.started then
            if line == "" then return end
            if line:lower() == "look" then return end
            if ctx.looksLikePrompt(line) then return end
            CAP.started = true
        end

        CAP.lines[#CAP.lines + 1] = line
    end)

    CAP.timer = ctx.tempTimer(timeoutSec, function()
        if not CAP.active then return end
        _captureFinalize(ctx, false, "timeout(" .. tostring(timeoutSec) .. "s)", svc)
    end)

    ctx.out("[DWKit Room] refresh: sending 'look' + capturing output...")
    pcall(sendFn, "look")
end

function M.dispatch(ctx, svc, sub, arg)
    ctx = ctx or {}
    if type(ctx.out) ~= "function" or type(ctx.err) ~= "function" then
        return
    end

    sub = tostring(sub or "")
    arg = tostring(arg or "")

    if sub == "" or sub == "status" then
        if type(ctx.printRoomEntitiesStatus) == "function" then
            ctx.printRoomEntitiesStatus(svc)
        else
            ctx.err("printRoomEntitiesStatus ctx helper missing")
        end
        return
    end

    if sub == "clear" then
        if type(svc) ~= "table" or type(svc.clear) ~= "function" then
            ctx.err("RoomEntitiesService.clear not available.")
            return
        end
        local okCall, _, _, _, err = ctx.callBestEffort(svc, "clear", { source = "dwroom" })
        if not okCall then
            ctx.err("clear failed: " .. tostring(err))
            return
        end
        if type(ctx.printRoomEntitiesStatus) == "function" then
            ctx.printRoomEntitiesStatus(svc)
        end
        return
    end

    if sub == "ingestclip" then
        local text = ctx.getClipboardText()
        if type(text) ~= "string" or text:gsub("%s+", "") == "" then
            ctx.err("clipboard is empty (copy LOOK output first).")
            return
        end

        local cap = (arg == "cap" or arg == "playercap")
        local okIngest, err = _ingestLook(ctx, svc, text, {
            source = "dwroom:clipboard",
            assumeCapitalizedAsPlayer = cap,
        })

        if not okIngest then
            ctx.err("ingestclip failed: " .. tostring(err))
            return
        end

        ctx.out("[DWKit Room] ingestclip OK (cap=" .. tostring(cap == true) .. ")")
        if type(ctx.printRoomEntitiesStatus) == "function" then
            ctx.printRoomEntitiesStatus(svc)
        end
        return
    end

    if sub == "fixture" then
        local fixture = table.concat({
            "A quiet stone hallway.",
            "Exits: north south",
            "Zerath is standing here.",
            "a city guard is standing here.",
            "the corpse of a rat is here.",
            "a rusty sword is here.",
            "a small lantern is here.",
        }, "\n")

        local okIngest, err = _ingestLook(ctx, svc, fixture, {
            source = "dwroom:fixture",
            assumeCapitalizedAsPlayer = true,
        })

        if not okIngest then
            ctx.err("fixture ingest failed: " .. tostring(err))
            return
        end

        ctx.out("[DWKit Room] fixture ingested")
        if type(ctx.printRoomEntitiesStatus) == "function" then
            ctx.printRoomEntitiesStatus(svc)
        end
        return
    end

    if sub == "refresh" then
        local cap = (arg == "cap" or arg == "playercap")
        _captureStart(ctx, svc, { timeoutSec = 5, assumeCap = cap })
        return
    end

    _usage(ctx)
end

return M
