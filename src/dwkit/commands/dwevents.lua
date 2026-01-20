-- #########################################################################
-- Module Name : dwkit.commands.dwevents
-- Owner       : Commands
-- Version     : v2026-01-20A
-- Purpose     :
--   - Phase 7 Split: dwevents command handler extracted from command_aliases.lua
--   - Prints event registry list or Markdown export (SAFE; manual-only).
--
-- Public API  :
--   - dispatch(ctx, eventRegistry, mode) -> nil
--       mode: "" | "md"
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
    return function(msg) print("[DWKit Events] ERROR: " .. tostring(msg)) end
end

function M.dispatch(ctx, eventRegistry, mode)
    local out = _mkOut(ctx)
    local err = _mkErr(ctx)

    if type(eventRegistry) ~= "table" then
        err("EventRegistry not available. Run loader.init() first.")
        return
    end

    mode = tostring(mode or "")

    if mode == "md" then
        if type(eventRegistry.toMarkdown) ~= "function" then
            err("EventRegistry.toMarkdown not available.")
            return
        end

        local ok, md = pcall(eventRegistry.toMarkdown, {})
        if not ok then
            err("dwevents md failed: " .. tostring(md))
            return
        end

        out(tostring(md))
        return
    end

    if type(eventRegistry.listAll) ~= "function" then
        err("EventRegistry.listAll not available.")
        return
    end

    eventRegistry.listAll()
end

function M.reset()
    -- no state
end

return M
