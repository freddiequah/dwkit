-- #########################################################################
-- Module Name : dwkit.commands.dwevent
-- Owner       : Commands
-- Version     : v2026-01-26C
-- Purpose     :
--   - Phase 7 Split: dwevent command handler extracted from command_aliases.lua
--   - Prints detailed help for a single event (SAFE; manual-only).
--
-- Public API  :
--   - dispatch(ctx, kit|eventRegistry, tokens|eventName) -> nil
--   - reset() -> nil (best-effort; no state)
-- #########################################################################

local M = {}

M.VERSION = "v2026-01-26C"

local function _mkOut(ctx)
    if type(ctx) == "table" and type(ctx.out) == "function" then
        return ctx.out
    end
    return function(line) print(tostring(line or "")) end
end

local function _mkErr(ctx)
    if type(ctx) == "table" and type(ctx.err) == "function" then
        return ctx.err
    end
    return function(msg) print("[DWKit Event] ERROR: " .. tostring(msg)) end
end

local function _resolveEventRegistry(arg)
    if type(arg) ~= "table" then return nil end

    -- Preferred: kit.bus.eventRegistry
    if type(arg.bus) == "table" and type(arg.bus.eventRegistry) == "table" then
        return arg.bus.eventRegistry
    end

    -- Back-compat: already an EventRegistry object
    if type(arg.help) == "function" or type(arg.listAll) == "function" or type(arg.toMarkdown) == "function" then
        return arg
    end

    return nil
end

local function _resolveEventName(arg)
    -- New dispatcher path: tokens table
    if type(arg) == "table" then
        local v = arg[2]
        if v ~= nil then return tostring(v) end
        return ""
    end
    return tostring(arg or "")
end

local function _callHelpBestEffort(eventRegistry, eventName)
    -- Try obj.fn(name)
    local ok1, a1, b1, c1 = pcall(eventRegistry.help, eventName)
    if ok1 then
        return (a1 == true), b1, c1
    end

    -- Try obj:fn(name)
    local ok2, a2, b2, c2 = pcall(eventRegistry.help, eventRegistry, eventName)
    if ok2 then
        return (a2 == true), b2, c2
    end

    return false, nil, "EventRegistry.help call failed"
end

function M.dispatch(ctx, kitOrRegistry, tokensOrEventName)
    local err = _mkErr(ctx)

    local eventRegistry = _resolveEventRegistry(kitOrRegistry)
    if type(eventRegistry) ~= "table" then
        err("EventRegistry not available. Run loader.init() first.")
        return
    end

    local eventName = _resolveEventName(tokensOrEventName)
    if eventName == "" then
        err("Usage: dwevent <EventName>")
        return
    end

    if type(eventRegistry.help) ~= "function" then
        err("EventRegistry.help not available.")
        return
    end

    local ok, b, c = _callHelpBestEffort(eventRegistry, eventName)
    if not ok then
        err(c or b or ("Unknown event: " .. eventName))
    end
end

function M.reset()
    -- no state
end

return M
