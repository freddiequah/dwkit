-- #########################################################################
-- Module Name : dwkit.commands.who_diag
-- Owner       : Commands
-- Version     : v2026-01-19A
-- Purpose     :
--   - Handler module for dwwho command surface (Router + Handlers Phase 1).
--   - Implements SAFE: status/clear/ingestclip/fixture and GAME: refresh.
--   - Designed to be called by dwkit.services.command_aliases router with a ctx contract.
--   - NO alias installation here.
--
-- Handler API:
--   - printStatus(ctx, svc)
--   - clear(ctx, svc)
--   - ingestClip(ctx, svc)
--   - fixture(ctx, svc)
--   - refresh(ctx, svc, captureState, opts?)
--
-- ctx contract (best-effort; provided by router):
--   - out(line)
--   - err(msg)
--   - getClipboardText() -> string|nil
--   - send(cmd) -> boolean ok
--   - tempRegexTrigger(pattern, fn) -> id|nil
--   - tempTimer(sec, fn) -> id|nil
--   - killTrigger(id)
--   - killTimer(id)
--   - now() -> number (seconds)
-- #########################################################################

local M = {}

M.VERSION = "v2026-01-19A"

local function _out(ctx, line)
    if type(ctx) == "table" and type(ctx.out) == "function" then
        ctx.out(line)
        return
    end
    print(tostring(line or ""))
end

local function _err(ctx, msg)
    if type(ctx) == "table" and type(ctx.err) == "function" then
        ctx.err(msg)
        return
    end
    _out(ctx, "[DWKit Who] ERROR: " .. tostring(msg))
end

local function _sortedKeys(t)
    local keys = {}
    if type(t) ~= "table" then return keys end
    for k, _ in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    return keys
end

local function _whoCountFromState(state)
    state = (type(state) == "table") and state or {}
    local function cnt(t)
        if type(t) ~= "table" then return 0 end
        local n = 0
        for _ in pairs(t) do n = n + 1 end
        return n
    end
    return {
        players = cnt(state.players),
    }
end

local function _callBestEffort(obj, fnName, ...)
    if type(obj) ~= "table" then
        return false, nil, nil, nil, "obj not table"
    end
    local fn = obj[fnName]
    if type(fn) ~= "function" then
        return false, nil, nil, nil, "missing function: " .. tostring(fnName)
    end

    local ok1, a1, b1, c1 = pcall(fn, ...)
    if ok1 then
        return true, a1, b1, c1, nil
    end

    local ok2, a2, b2, c2 = pcall(fn, obj, ...)
    if ok2 then
        return true, a2, b2, c2, nil
    end

    return false, nil, nil, nil, "call failed: " .. tostring(a1) .. " | " .. tostring(a2)
end

function M.printStatus(ctx, svc)
    if type(svc) ~= "table" then
        _err(ctx, "WhoStoreService not available. Run loader.init() first.")
        return
    end

    local state = {}
    if type(svc.getState) == "function" then
        local ok, v, _, _, err = _callBestEffort(svc, "getState")
        if ok and type(v) == "table" then
            state = v
        elseif err then
            _out(ctx, "[DWKit Who] getState failed: " .. tostring(err))
        end
    end

    local c = _whoCountFromState(state)

    _out(ctx, "[DWKit Who] status (dwwho)")
    _out(ctx, "  serviceVersion=" .. tostring(svc.VERSION or "unknown"))
    _out(ctx, "  players=" .. tostring(c.players))
    _out(ctx, "  lastUpdatedTs=" .. tostring(state.lastUpdatedTs or ""))
    _out(ctx, "  source=" .. tostring(state.source or ""))

    local names = _sortedKeys(state.players)
    local limit = math.min(#names, 12)
    if limit > 0 then
        _out(ctx, "  top=" .. table.concat({ unpack(names, 1, limit) }, ", "))
        if #names > limit then
            _out(ctx, "  ... (" .. tostring(#names - limit) .. " more)")
        end
    end
end

function M.clear(ctx, svc)
    if type(svc) ~= "table" then
        _err(ctx, "WhoStoreService not available. Create src/dwkit/services/whostore_service.lua first.")
        return
    end
    if type(svc.clear) ~= "function" then
        _err(ctx, "WhoStoreService.clear not available.")
        return
    end
    local ok, _, _, _, err = _callBestEffort(svc, "clear", { source = "dwwho" })
    if not ok then
        _err(ctx, "clear failed: " .. tostring(err))
        return
    end
    M.printStatus(ctx, svc)
end

function M.ingestClip(ctx, svc)
    if type(svc) ~= "table" then
        _err(ctx, "WhoStoreService not available. Create src/dwkit/services/whostore_service.lua first.")
        return
    end
    if type(svc.ingestWhoText) ~= "function" then
        _err(ctx, "WhoStoreService.ingestWhoText not available.")
        return
    end

    local text = nil
    if type(ctx) == "table" and type(ctx.getClipboardText) == "function" then
        local okT, t = pcall(ctx.getClipboardText)
        if okT and type(t) == "string" then text = t end
    end

    if type(text) ~= "string" or text:gsub("%s+", "") == "" then
        _err(ctx, "clipboard is empty (copy WHO output first).")
        return
    end

    local ok, _, _, _, err = _callBestEffort(svc, "ingestWhoText", text, { source = "dwwho:clipboard" })
    if not ok then
        _err(ctx, "ingestclip failed: " .. tostring(err))
        return
    end

    _out(ctx, "[DWKit Who] ingestclip OK")
    M.printStatus(ctx, svc)
end

function M.fixture(ctx, svc)
    if type(svc) ~= "table" then
        _err(ctx, "WhoStoreService not available. Create src/dwkit/services/whostore_service.lua first.")
        return
    end
    if type(svc.ingestWhoText) ~= "function" then
        _err(ctx, "WhoStoreService.ingestWhoText not available.")
        return
    end

    local fixture = table.concat({
        "Zeq",
        "Vzae",
        "Xi",
        "Scynox",
    }, "\n")

    local ok, _, _, _, err = _callBestEffort(svc, "ingestWhoText", fixture, { source = "dwwho:fixture" })
    if not ok then
        _err(ctx, "fixture ingest failed: " .. tostring(err))
        return
    end

    _out(ctx, "[DWKit Who] fixture ingested")
    M.printStatus(ctx, svc)
end

local function _killTriggerBestEffort(ctx, id)
    if not id then return end
    if type(ctx) ~= "table" or type(ctx.killTrigger) ~= "function" then return end
    pcall(ctx.killTrigger, id)
end

local function _killTimerBestEffort(ctx, id)
    if not id then return end
    if type(ctx) ~= "table" or type(ctx.killTimer) ~= "function" then return end
    pcall(ctx.killTimer, id)
end

local function _captureReset(ctx, cap)
    cap.active = false
    cap.started = false
    cap.lines = nil
    cap.startedAt = nil

    _killTriggerBestEffort(ctx, cap.trigAny)
    cap.trigAny = nil

    _killTimerBestEffort(ctx, cap.timer)
    cap.timer = nil
end

local function _captureFinalize(ctx, cap, ok, reason, svc)
    local lines = cap.lines or {}
    _captureReset(ctx, cap)

    if not ok then
        _out(ctx, "[DWKit Who] refresh FAILED reason=" .. tostring(reason or "unknown"))
        return
    end

    if type(svc) ~= "table" or type(svc.ingestWhoLines) ~= "function" then
        _out(ctx, "[DWKit Who] refresh FAILED: WhoStoreService.ingestWhoLines not available")
        return
    end

    local okIngest, err = svc.ingestWhoLines(lines, { source = "dwwho:refresh" })
    if okIngest then
        _out(ctx, "[DWKit Who] refresh OK lines=" .. tostring(#lines))
        M.printStatus(ctx, svc)
    else
        _out(ctx, "[DWKit Who] refresh ingest FAILED err=" .. tostring(err))
    end
end

function M.refresh(ctx, svc, captureState, opts)
    opts = opts or {}
    local timeoutSec = tonumber(opts.timeoutSec or 4) or 4
    if timeoutSec < 2 then timeoutSec = 2 end
    if timeoutSec > 10 then timeoutSec = 10 end

    local cap = (type(captureState) == "table") and captureState or nil
    if type(cap) ~= "table" then
        _err(ctx, "who capture state not provided")
        return
    end

    if cap.active then
        _out(ctx, "[DWKit Who] refresh already running (canceling old session)")
        _captureReset(ctx, cap)
    end

    if type(ctx) ~= "table" or type(ctx.send) ~= "function" then
        _out(ctx, "[DWKit Who] refresh FAILED: send() not available in this Mudlet environment")
        return
    end

    cap.active = true
    cap.started = false
    cap.lines = {}
    cap.startedAt = (type(ctx.now) == "function" and ctx.now()) or os.time()

    if type(ctx.tempRegexTrigger) ~= "function" then
        _captureFinalize(ctx, cap, false, "tempRegexTrigger unavailable", svc)
        return
    end
    if type(ctx.tempTimer) ~= "function" then
        _captureFinalize(ctx, cap, false, "tempTimer unavailable", svc)
        return
    end

    cap.trigAny = ctx.tempRegexTrigger([[^(.*)$]], function()
        if not cap.active then return end
        local line = (matches and matches[2]) and tostring(matches[2]) or ""

        if not cap.started then
            if line == "Players" or line:match("^%[") or line:match("^Total players:") then
                cap.started = true
            else
                return
            end
        end

        cap.lines[#cap.lines + 1] = line

        if line:match("^%s*%d+%s+characters displayed%.%s*$") then
            _captureFinalize(ctx, cap, true, nil, svc)
        end
    end)

    cap.timer = ctx.tempTimer(timeoutSec, function()
        if not cap.active then return end
        _captureFinalize(ctx, cap, false, "timeout(" .. tostring(timeoutSec) .. "s)", svc)
    end)

    _out(ctx, "[DWKit Who] refresh: sending 'who' + capturing output...")
    ctx.send("who")
end

return M
