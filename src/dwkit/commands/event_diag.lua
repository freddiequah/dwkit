-- #########################################################################
-- Module Name : dwkit.commands.event_diag
-- Owner       : Commands
-- Version     : v2026-01-19A
-- Purpose     :
--   - Event diagnostics command handlers extracted from dwkit.services.command_aliases.
--   - IMPORTANT: This module is intentionally STATELESS.
--     The owning state remains in command_aliases.lua (STATE.eventDiag) to preserve behavior.
--   - Does not create aliases. Handlers only.
--
-- Public API  :
--   - printStatus(ctx, diagState)
--   - printLog(ctx, diagState, n)
--   - tapOn(ctx, diagState)
--   - tapOff(ctx, diagState)
--   - subOn(ctx, diagState, eventName)
--   - subOff(ctx, diagState, eventName)
--   - logClear(ctx, diagState)
--
-- ctx contract (provided by caller):
--   ctx.out(line)
--   ctx.err(msg)
--   ctx.ppTable(t, opts)
--   ctx.ppValue(v)
--   ctx.hasEventBus() -> boolean
--   ctx.hasEventRegistry() -> boolean
--   ctx.getEventBus() -> table|nil   (DWKit.bus.eventBus)
--   ctx.getEventRegistry() -> table|nil (DWKit.bus.eventRegistry)
-- #########################################################################

local M = {}

M.VERSION = "v2026-01-19A"

local function _out(ctx, line) ctx.out(line) end
local function _err(ctx, msg) ctx.err(msg) end

local function _diag(diagState)
    return (type(diagState) == "table") and diagState or { maxLog = 50, log = {}, tapToken = nil, subs = {} }
end

local function _pushEventLog(diagState, kind, eventName, payload)
    local d = _diag(diagState)
    local rec = {
        ts = os.time(),
        kind = tostring(kind or "unknown"),
        event = tostring(eventName or "unknown"),
        payload = payload,
    }
    d.log[#d.log + 1] = rec

    local maxLog = (type(d.maxLog) == "number" and d.maxLog > 0) and d.maxLog or 50
    while #d.log > maxLog do
        table.remove(d.log, 1)
    end
end

local function _normalizeTapArgs(a, b)
    if type(a) == "string" and type(b) == "table" then
        return b, a
    end
    return a, b
end

function M.printStatus(ctx, diagState)
    if not (ctx and ctx.hasEventBus and ctx.hasEventBus()) then
        _err(ctx, "DWKit.bus.eventBus not available. Run loader.init() first.")
        return
    end

    local eb = ctx.getEventBus and ctx.getEventBus() or nil
    if type(eb) ~= "table" then
        _err(ctx, "DWKit.bus.eventBus not available. Run loader.init() first.")
        return
    end

    local d = _diag(diagState)
    local tapOn = (d.tapToken ~= nil)
    local subCount = 0
    for _ in pairs(d.subs or {}) do subCount = subCount + 1 end

    local stats = {}
    if type(eb.getStats) == "function" then
        local okS, s = pcall(eb.getStats)
        if okS and type(s) == "table" then stats = s end
    end

    _out(ctx, "[DWKit EventDiag] status")
    _out(ctx, "  tapEnabled     : " .. tostring(tapOn))
    _out(ctx, "  tapToken       : " .. tostring(d.tapToken))
    _out(ctx, "  subsCount      : " .. tostring(subCount))
    _out(ctx, "  logCount       : " .. tostring(#(d.log or {})))
    _out(ctx, "  maxLog         : " .. tostring(d.maxLog))
    _out(ctx, "  eventBus.version       : " .. tostring(stats.version or "unknown"))
    _out(ctx, "  eventBus.emitted       : " .. tostring(stats.emitted or 0))
    _out(ctx, "  eventBus.delivered     : " .. tostring(stats.delivered or 0))
    _out(ctx, "  eventBus.handlerErrors : " .. tostring(stats.handlerErrors or 0))
    _out(ctx, "  eventBus.tapSubscribers: " .. tostring(stats.tapSubscribers or 0))
    _out(ctx, "  eventBus.tapErrors     : " .. tostring(stats.tapErrors or 0))
end

function M.printLog(ctx, diagState, n)
    local d = _diag(diagState)
    local total = #(d.log or {})
    if total == 0 then
        _out(ctx, "[DWKit EventDiag] log is empty")
        return
    end

    local limit = tonumber(n or "") or 10
    if limit < 1 then limit = 10 end
    if limit > 50 then limit = 50 end

    local start = math.max(1, total - limit + 1)

    _out(ctx, "[DWKit EventDiag] last " .. tostring(total - start + 1) .. " events (most recent last)")
    for i = start, total do
        local rec = d.log[i]
        _out(ctx, "")
        _out(ctx, "  [" ..
            tostring(i) ..
            "] ts=" .. tostring(rec.ts) .. " kind=" .. tostring(rec.kind) .. " event=" .. tostring(rec.event))
        if type(rec.payload) == "table" then
            _out(ctx, "    payload=")
            ctx.ppTable(rec.payload, { maxDepth = 2, maxItems = 25 })
        else
            _out(ctx, "    payload=" .. ctx.ppValue(rec.payload))
        end
    end
end

function M.tapOn(ctx, diagState)
    if not (ctx and ctx.hasEventBus and ctx.hasEventBus()) then
        _err(ctx, "DWKit.bus.eventBus not available. Run loader.init() first.")
        return
    end

    local eb = ctx.getEventBus and ctx.getEventBus() or nil
    if type(eb) ~= "table" then
        _err(ctx, "DWKit.bus.eventBus not available. Run loader.init() first.")
        return
    end

    local d = _diag(diagState)
    if d.tapToken ~= nil then
        _out(ctx, "[DWKit EventDiag] tap already enabled token=" .. tostring(d.tapToken))
        return
    end

    if type(eb.tapOn) ~= "function" then
        _err(ctx, "eventBus.tapOn not available. Update dwkit.bus.event_bus first.")
        return
    end

    local okCall, ok, token, err = pcall(eb.tapOn, function(a, b)
        local payload, eventName = _normalizeTapArgs(a, b)
        _pushEventLog(d, "tap", eventName, payload)
    end)

    if not okCall then
        _err(ctx, "tapOn threw error: " .. tostring(ok))
        return
    end
    if not ok then
        _err(ctx, err or "tapOn failed")
        return
    end

    d.tapToken = token
    _out(ctx, "[DWKit EventDiag] tap enabled token=" .. tostring(token))
end

function M.tapOff(ctx, diagState)
    if not (ctx and ctx.hasEventBus and ctx.hasEventBus()) then
        _err(ctx, "DWKit.bus.eventBus not available. Run loader.init() first.")
        return
    end

    local eb = ctx.getEventBus and ctx.getEventBus() or nil
    if type(eb) ~= "table" then
        _err(ctx, "DWKit.bus.eventBus not available. Run loader.init() first.")
        return
    end

    local d = _diag(diagState)
    if d.tapToken == nil then
        _out(ctx, "[DWKit EventDiag] tap already off")
        return
    end

    if type(eb.tapOff) ~= "function" then
        _err(ctx, "eventBus.tapOff not available. Update dwkit.bus.event_bus first.")
        return
    end

    local tok = d.tapToken
    local okCall, ok, err = pcall(eb.tapOff, tok)
    if not okCall then
        _err(ctx, "tapOff threw error: " .. tostring(ok))
        return
    end
    if not ok then
        _err(ctx, err or "tapOff failed")
        return
    end

    d.tapToken = nil
    _out(ctx, "[DWKit EventDiag] tap disabled token=" .. tostring(tok))
end

function M.subOn(ctx, diagState, eventName)
    if not (ctx and ctx.hasEventBus and ctx.hasEventBus()) then
        _err(ctx, "DWKit.bus.eventBus not available. Run loader.init() first.")
        return
    end
    if not (ctx and ctx.hasEventRegistry and ctx.hasEventRegistry()) then
        _err(ctx, "DWKit.bus.eventRegistry not available. Run loader.init() first.")
        return
    end

    local eb = ctx.getEventBus and ctx.getEventBus() or nil
    local er = ctx.getEventRegistry and ctx.getEventRegistry() or nil
    if type(eb) ~= "table" then
        _err(ctx, "DWKit.bus.eventBus not available. Run loader.init() first.")
        return
    end
    if type(er) ~= "table" then
        _err(ctx, "DWKit.bus.eventRegistry not available. Run loader.init() first.")
        return
    end

    eventName = tostring(eventName or "")
    if eventName == "" then
        _err(ctx, "Usage: dweventsub <EventName>")
        return
    end

    if type(er.has) == "function" then
        local okHas, exists = pcall(er.has, eventName)
        if okHas and not exists then
            _err(ctx, "event not registered: " .. tostring(eventName))
            return
        end
    end

    local d = _diag(diagState)
    d.subs = (type(d.subs) == "table") and d.subs or {}

    if d.subs[eventName] ~= nil then
        _out(ctx,
            "[DWKit EventDiag] already subscribed: " .. tostring(eventName) .. " token=" .. tostring(d.subs[eventName]))
        return
    end

    if type(eb.on) ~= "function" then
        _err(ctx, "eventBus.on not available.")
        return
    end

    local okCall, ok, token, err = pcall(eb.on, eventName, function(payload, ev)
        _pushEventLog(d, "sub", ev, payload)
    end)
    if not okCall then
        _err(ctx, "subscribe threw error: " .. tostring(ok))
        return
    end
    if not ok then
        _err(ctx, err or "subscribe failed")
        return
    end

    d.subs[eventName] = token
    _out(ctx, "[DWKit EventDiag] subscribed: " .. tostring(eventName) .. " token=" .. tostring(token))
end

function M.subOff(ctx, diagState, eventName)
    if not (ctx and ctx.hasEventBus and ctx.hasEventBus()) then
        _err(ctx, "DWKit.bus.eventBus not available. Run loader.init() first.")
        return
    end

    local eb = ctx.getEventBus and ctx.getEventBus() or nil
    if type(eb) ~= "table" then
        _err(ctx, "DWKit.bus.eventBus not available. Run loader.init() first.")
        return
    end

    local d = _diag(diagState)
    d.subs = (type(d.subs) == "table") and d.subs or {}

    eventName = tostring(eventName or "")
    if eventName == "" then
        _err(ctx, "Usage: dweventunsub <EventName|all>")
        return
    end

    if type(eb.off) ~= "function" then
        _err(ctx, "eventBus.off not available.")
        return
    end

    if eventName == "all" then
        local any = false
        for ev, tok in pairs(d.subs) do
            any = true
            pcall(eb.off, tok)
            d.subs[ev] = nil
        end
        _out(ctx, "[DWKit EventDiag] unsubscribed: all (" .. tostring(any and "some" or "none") .. ")")
        return
    end

    local tok = d.subs[eventName]
    if tok == nil then
        _out(ctx, "[DWKit EventDiag] not subscribed: " .. tostring(eventName))
        return
    end

    local okCall, ok, err = pcall(eb.off, tok)
    if not okCall then
        _err(ctx, "unsubscribe threw error: " .. tostring(ok))
        return
    end
    if not ok then
        _err(ctx, err or "unsubscribe failed")
        return
    end

    d.subs[eventName] = nil
    _out(ctx, "[DWKit EventDiag] unsubscribed: " .. tostring(eventName))
end

function M.logClear(ctx, diagState)
    local d = _diag(diagState)
    d.log = {}
    _out(ctx, "[DWKit EventDiag] log cleared")
end

return M
