-- #########################################################################
-- Module Name : dwkit.commands.dwevent
-- Owner       : Commands
-- Version     : v2026-01-20A
-- Purpose     :
--   - Phase 7 Split: dwevent command handler extracted from command_aliases.lua
--   - Prints detailed help for a single event (SAFE; manual-only).
--
-- Public API  :
--   - dispatch(ctx, eventRegistry, eventName) -> nil
--   - reset() -> nil (best-effort; no state)
-- #########################################################################

local M = {}

M.VERSION = "v2026-01-20A"

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

function M.dispatch(ctx, eventRegistry, eventName)
    local err = _mkErr(ctx)

    if type(eventRegistry) ~= "table" then
        err("EventRegistry not available. Run loader.init() first.")
        return
    end

    eventName = tostring(eventName or "")
    if eventName == "" then
        err("Usage: dwevent <EventName>")
        return
    end

    if type(eventRegistry.help) ~= "function" then
        err("EventRegistry.help not available.")
        return
    end

    local ok, _, e = eventRegistry.help(eventName)
    if not ok then
        err(e or ("Unknown event: " .. eventName))
    end
end

function M.reset()
    -- no state
end

return M
