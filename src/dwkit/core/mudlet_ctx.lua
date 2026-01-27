-- #########################################################################
-- BEGIN FILE: src/dwkit/core/mudlet_ctx.lua
-- #########################################################################
-- Module Name : dwkit.core.mudlet_ctx
-- Owner       : Core
-- Version     : v2026-01-27A
-- Purpose     :
--   - Centralize Mudlet context plumbing ("ctx") in ONE place.
--   - Provide a canonical ctx object with best-effort wrappers for Mudlet APIs
--     (output, require safety, callBestEffort, clipboard, triggers/timers, etc.).
--   - Reduce duplicated ctx glue in command_aliases / alias_factory / router.
--
-- Public API:
--   - make(opts?) -> ctx
--   - ensure(ctx, opts?) -> ctx (fills missing fields best-effort; does not override)
--   - getKitBestEffort() -> DWKit|nil
--
-- Notes:
--   - This module MUST NOT depend on higher layers (Bus/Services/UI).
--   - It MAY call Mudlet globals best-effort (cecho/echo/tempRegexTrigger/etc).
--   - errPrefix is caller-provided (default "[DWKit]") to preserve module prefixes.
--
-- Events Emitted   : None
-- Events Consumed  : None
-- Persistence      : None
-- Automation Policy: Manual only
-- Dependencies     : None (Mudlet globals best-effort)
-- #########################################################################

local M = {}

M.VERSION = "v2026-01-27A"

function M.getKitBestEffort()
    if type(_G) == "table" and type(_G.DWKit) == "table" then
        return _G.DWKit
    end
    if type(DWKit) == "table" then
        return DWKit
    end
    return nil
end

local function _defaultOut(line)
    line = tostring(line or "")
    if type(cecho) == "function" then
        cecho(line .. "\n")
    elseif type(echo) == "function" then
        echo(line .. "\n")
    else
        print(line)
    end
end

local function _safeRequire(modName)
    local ok, mod = pcall(require, modName)
    if ok then return true, mod end
    return false, mod
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

local function _sortedKeys(t)
    local keys = {}
    if type(t) ~= "table" then return keys end
    for k, _ in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    return keys
end

local function _getServiceBestEffort(kit, name)
    if type(kit) ~= "table" or type(kit.services) ~= "table" then return nil end
    local s = kit.services[name]
    if type(s) == "table" then return s end
    return nil
end

local function _getClipboardTextBestEffort()
    if type(getClipboardText) == "function" then
        local ok, t = pcall(getClipboardText)
        if ok and type(t) == "string" then
            return t
        end
    end
    return nil
end

local function _resolveSendFn()
    if type(_G.send) == "function" then return _G.send end
    if type(_G.sendAll) == "function" then return _G.sendAll end
    return nil
end

local function _killTriggerBestEffort(id)
    if not id then return end
    if type(killTrigger) ~= "function" then return end
    pcall(killTrigger, id)
end

local function _killTimerBestEffort(id)
    if not id then return end
    if type(killTimer) ~= "function" then return end
    pcall(killTimer, id)
end

local function _tempRegexTriggerBestEffort(pat, fn)
    if type(tempRegexTrigger) ~= "function" then return nil end
    local ok, id = pcall(tempRegexTrigger, pat, fn)
    if ok then return id end
    return nil
end

local function _tempTimerBestEffort(sec, fn)
    if type(tempTimer) ~= "function" then return nil end
    local ok, id = pcall(tempTimer, sec, fn)
    if ok then return id end
    return nil
end

local function _tokenize(line)
    line = tostring(line or "")
    local tokens = {}
    for w in line:gmatch("%S+") do
        tokens[#tokens + 1] = w
    end
    return tokens
end

-- Mudlet alias callbacks set `matches[]`:
--   matches[0] full line (when provided), matches[1..n] capture groups
local function _getFullMatchLine(matchesTable)
    local m = matchesTable
    if type(m) ~= "table" and type(_G) == "table" and type(_G.matches) == "table" then
        m = _G.matches
    end

    if type(m) == "table" then
        if m[0] ~= nil then
            return tostring(m[0])
        end
        if m[1] ~= nil then
            return tostring(m[1])
        end
    end
    return ""
end

local function _tokenizeFromMatches(matchesTable)
    return _tokenize(_getFullMatchLine(matchesTable))
end

local function _looksLikePrompt(line)
    line = tostring(line or "")
    if line == "" then return false end

    if line:match("^%s*<?%d+%(%d+%)Hp") then
        return true
    end

    if line:match(">%s*$") and line:match("Hp") and line:match("Mp") then
        return true
    end

    return false
end

function M.make(opts)
    opts = (type(opts) == "table") and opts or {}

    local kit = (type(opts.kit) == "table") and opts.kit or M.getKitBestEffort()
    local out = (type(opts.out) == "function") and opts.out or _defaultOut

    local prefix = tostring(opts.errPrefix or "[DWKit]")
    local err = (type(opts.err) == "function") and opts.err or function(msg)
        out(prefix .. " ERROR: " .. tostring(msg))
    end

    local ctx = {
        -- basic I/O
        out = out,
        err = err,

        -- kit/service
        getKit = function() return kit end,
        getService = function(name) return _getServiceBestEffort(kit, name) end,

        -- helpers
        sortedKeys = _sortedKeys,
        tokenize = _tokenize,
        getFullMatchLine = function(mt) return _getFullMatchLine(mt) end,
        tokenizeFromMatches = function(mt) return _tokenizeFromMatches(mt) end,

        -- require/call safety
        safeRequire = _safeRequire,
        callBestEffort = _callBestEffort,

        -- Mudlet best-effort wrappers
        getClipboardText = _getClipboardTextBestEffort,
        resolveSendFn = _resolveSendFn,
        looksLikePrompt = _looksLikePrompt,

        tempRegexTrigger = _tempRegexTriggerBestEffort,
        tempTimer = _tempTimerBestEffort,
        killTrigger = _killTriggerBestEffort,
        killTimer = _killTimerBestEffort,
    }

    return ctx
end

function M.ensure(ctx, opts)
    if type(ctx) ~= "table" then
        ctx = {}
    end

    local base = M.make(opts)

    for k, v in pairs(base) do
        if ctx[k] == nil then
            ctx[k] = v
        end
    end

    return ctx
end

return M

-- #########################################################################
-- END FILE: src/dwkit/core/mudlet_ctx.lua
-- #########################################################################
