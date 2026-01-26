-- #########################################################################
-- Module Name : dwkit.commands.dwevents
-- Owner       : Commands
-- Version     : v2026-01-26C
-- Purpose     :
--   - Phase 7 Split: dwevents command handler extracted from command_aliases.lua
--   - Prints event registry list or Markdown export (SAFE; manual-only).
--
-- Public API  :
--   - dispatch(ctx, kit|eventRegistry, tokens|mode) -> nil
--       mode: "" | "md"
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
    return function(msg) print("[DWKit Events] ERROR: " .. tostring(msg)) end
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

local function _resolveMode(arg)
    -- New dispatcher path: tokens table
    if type(arg) == "table" then
        local v = arg[2]
        if v ~= nil then return tostring(v) end
        return ""
    end
    return tostring(arg or "")
end

local function _callToMarkdownBestEffort(eventRegistry)
    -- Try obj.fn({})
    local ok1, md1 = pcall(eventRegistry.toMarkdown, {})
    if ok1 then
        return true, md1
    end

    -- Try obj:fn({})
    local ok2, md2 = pcall(eventRegistry.toMarkdown, eventRegistry, {})
    if ok2 then
        return true, md2
    end

    return false, "EventRegistry.toMarkdown call failed"
end

local function _callListAllBestEffort(eventRegistry)
    -- Try obj.fn()
    local ok1, err1 = pcall(eventRegistry.listAll)
    if ok1 then return true, nil end

    -- Try obj:fn()
    local ok2, err2 = pcall(eventRegistry.listAll, eventRegistry)
    if ok2 then return true, nil end

    return false, tostring(err1 or err2 or "EventRegistry.listAll call failed")
end

function M.dispatch(ctx, kitOrRegistry, tokensOrMode)
    local out = _mkOut(ctx)
    local err = _mkErr(ctx)

    local eventRegistry = _resolveEventRegistry(kitOrRegistry)
    if type(eventRegistry) ~= "table" then
        err("EventRegistry not available. Run loader.init() first.")
        return
    end

    local mode = _resolveMode(tokensOrMode)

    if mode == "md" then
        if type(eventRegistry.toMarkdown) ~= "function" then
            err("EventRegistry.toMarkdown not available.")
            return
        end

        local ok, mdOrErr = _callToMarkdownBestEffort(eventRegistry)
        if not ok then
            err("dwevents md failed: " .. tostring(mdOrErr))
            return
        end

        out(tostring(mdOrErr))
        return
    end

    if type(eventRegistry.listAll) ~= "function" then
        err("EventRegistry.listAll not available.")
        return
    end

    local okList, listErr = _callListAllBestEffort(eventRegistry)
    if not okList then
        err("dwevents list failed: " .. tostring(listErr))
    end
end

function M.reset()
    -- no state
end

return M
