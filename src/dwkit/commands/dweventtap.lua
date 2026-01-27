-- #########################################################################
-- Module Name : dwkit.commands.dweventtap
-- Owner       : Commands
-- Version     : v2026-01-27A
-- Purpose     :
--   - Split SAFE command: dweventtap
--   - Delegates behavior to dwkit.commands.event_diag
--   - State is stored in dwkit.services.event_diag_state (reload-safe)
--
-- Supported:
--   - dweventtap
--   - dweventtap status
--   - dweventtap on
--   - dweventtap off
--   - dweventtap show [n]
--   - dweventtap clear
--
-- Public API:
--   - dispatch(ctx, kit, tokens) -> boolean (true handled)
--   - dispatch(ctx, tokens) -> boolean
--   - dispatch(tokens) -> boolean
--   - reset() -> nil
-- #########################################################################

local M = {}
M.VERSION = "v2026-01-27A"

local function _fallbackOut(line)
    line = tostring(line or "")
    if type(cecho) == "function" then
        cecho(line .. "\n")
    elseif type(echo) == "function" then
        echo(line .. "\n")
    else
        print(line)
    end
end

local function _fallbackErr(msg)
    _fallbackOut("[DWKit EventDiag] ERROR: " .. tostring(msg))
end

local function _isArrayLike(t)
    if type(t) ~= "table" then return false end
    local n = #t
    if n == 0 then return false end
    for i = 1, n do
        if t[i] == nil then return false end
    end
    return true
end

local function _resolveKit(kit)
    if type(kit) == "table" then return kit end
    if type(_G) == "table" and type(_G.DWKit) == "table" then return _G.DWKit end
    if type(DWKit) == "table" then return DWKit end
    return nil
end

local function _safeRequire(name)
    local ok, mod = pcall(require, name)
    if ok and type(mod) == "table" then return true, mod, nil end
    return false, nil, tostring(mod)
end

local function _getLegacyPp()
    local ok, L = _safeRequire("dwkit.commands.alias_legacy")
    if ok and type(L) == "table" then return L end
    return nil
end

local function _getEventBusBestEffort(kit)
    local K = _resolveKit(kit)
    if type(K) == "table" and type(K.bus) == "table" and type(K.bus.eventBus) == "table" then
        return K.bus.eventBus
    end
    local ok, mod = _safeRequire("dwkit.bus.event_bus")
    if ok then return mod end
    return nil
end

local function _getEventRegistryBestEffort(kit)
    local K = _resolveKit(kit)
    if type(K) == "table" and type(K.bus) == "table" and type(K.bus.eventRegistry) == "table" then
        return K.bus.eventRegistry
    end
    local ok, mod = _safeRequire("dwkit.bus.event_registry")
    if ok then return mod end
    return nil
end

local function _makeDiagCtx(ctx, kit)
    ctx = (type(ctx) == "table") and ctx or {}
    local L = _getLegacyPp()

    local outFn = (type(ctx.out) == "function") and ctx.out or _fallbackOut
    local errFn = (type(ctx.err) == "function") and ctx.err or _fallbackErr

    local ppTableFn = ctx.ppTable
    if type(ppTableFn) ~= "function" and L and type(L.ppTable) == "function" then
        ppTableFn = function(t, opts)
            return L.ppTable({ out = outFn, err = errFn }, t, opts)
        end
    end

    local ppValueFn = ctx.ppValue
    if type(ppValueFn) ~= "function" and L and type(L.ppValue) == "function" then
        ppValueFn = function(v) return L.ppValue(v) end
    end

    return {
        out = outFn,
        err = errFn,
        ppTable = ppTableFn or function(t) outFn(tostring(t)) end,
        ppValue = ppValueFn or function(v) return tostring(v) end,
        hasEventBus = function() return type(_getEventBusBestEffort(kit)) == "table" end,
        hasEventRegistry = function() return type(_getEventRegistryBestEffort(kit)) == "table" end,
        getEventBus = function() return _getEventBusBestEffort(kit) end,
        getEventRegistry = function() return _getEventRegistryBestEffort(kit) end,
    }
end

local function _resolveState(kit)
    local okS, S, errS = _safeRequire("dwkit.services.event_diag_state")
    if not okS or type(S.getState) ~= "function" then
        return nil, "event_diag_state not available (" .. tostring(errS) .. ")"
    end
    local okCall, st = pcall(S.getState, kit)
    if okCall and type(st) == "table" then
        return st, nil
    end
    return nil, "event_diag_state.getState failed"
end

local function _parse(tokens)
    tokens = (type(tokens) == "table") and tokens or {}
    local sub = tostring(tokens[2] or "")
    local n = tostring(tokens[3] or "")
    return sub, n
end

function M.dispatch(...)
    local a1, a2, a3 = ...
    local ctx, kit, tokens

    if _isArrayLike(a1) and tostring(a1[1] or "") == "dweventtap" then
        ctx = nil
        kit = nil
        tokens = a1
    else
        ctx = a1
        if _isArrayLike(a2) and tostring(a2[1] or "") == "dweventtap" then
            kit = nil
            tokens = a2
        elseif _isArrayLike(a3) and tostring(a3[1] or "") == "dweventtap" then
            kit = a2
            tokens = a3
        else
            -- unsupported signature
            return false
        end
    end

    kit = _resolveKit(kit)
    local D = _makeDiagCtx(ctx, kit)

    local st, errSt = _resolveState(kit)
    if type(st) ~= "table" then
        D.err(tostring(errSt or "event diag state not available"))
        return true
    end

    local okED, ED, errED = _safeRequire("dwkit.commands.event_diag")
    if not okED or type(ED) ~= "table" then
        D.err("dwkit.commands.event_diag not available (" .. tostring(errED) .. ")")
        return true
    end

    local sub, n = _parse(tokens)

    local function call(fnName, ...)
        if type(ED[fnName]) ~= "function" then
            D.err("event_diag." .. tostring(fnName) .. " not available")
            return
        end
        local okCall, errOrNil = pcall(ED[fnName], D, st, ...)
        if not okCall then
            D.err("event_diag." .. tostring(fnName) .. " threw error: " .. tostring(errOrNil))
        end
    end

    if sub == "" or sub == "status" then
        call("printStatus")
        return true
    end
    if sub == "on" then
        call("tapOn")
        return true
    end
    if sub == "off" then
        call("tapOff")
        return true
    end
    if sub == "show" then
        call("printLog", n)
        return true
    end
    if sub == "clear" then
        call("logClear")
        return true
    end

    D.err("Usage: dweventtap [on|off|status|show|clear] [n]")
    return true
end

function M.reset()
    -- no persistent state (state is in event_diag_state service)
end

return M
