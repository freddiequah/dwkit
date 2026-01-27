-- #########################################################################
-- Module Name : dwkit.services.event_diag_state
-- Owner       : Services
-- Version     : v2026-01-27A
-- Purpose     :
--   - Provide reload-safe storage for Event Diagnostics state.
--   - Moves state ownership OUT of command_aliases.lua.
--   - Allows event-diag commands to be normal SAFE split commands.
--
-- State fields:
--   - maxLog : integer
--   - log    : table (array; ring-ish by trimming)
--   - tapToken : token from eventBus.tapOn
--   - subs     : map eventName -> token (from eventBus.on)
--
-- Public API:
--   - getState(kit?) -> table (live; reload-safe)
--   - getSummary(kit?) -> table
--   - reset(kit?) -> nil
--   - shutdown(kit?) -> nil   best-effort: tapOff + unsub all + reset
-- #########################################################################

local M = {}

M.VERSION = "v2026-01-27A"

local _GLOBAL_KEY = "_eventDiagState"

local function _getKit(kit)
    if type(kit) == "table" then return kit end
    if type(_G) == "table" and type(_G.DWKit) == "table" then
        return _G.DWKit
    end
    if type(DWKit) == "table" then return DWKit end
    return nil
end

local function _defaultState()
    return {
        maxLog = 50,
        log = {},
        tapToken = nil,
        subs = {},
    }
end

local function _ensure(kit)
    local K = _getKit(kit)
    if type(K) ~= "table" then
        return _defaultState() -- non-persisted fallback
    end

    local st = K[_GLOBAL_KEY]
    if type(st) ~= "table" then
        st = _defaultState()
        K[_GLOBAL_KEY] = st
    end

    if type(st.maxLog) ~= "number" or st.maxLog < 1 then st.maxLog = 50 end
    if type(st.log) ~= "table" then st.log = {} end
    if st.subs ~= nil and type(st.subs) ~= "table" then st.subs = {} end
    if st.subs == nil then st.subs = {} end

    return st
end

local function _countMap(t)
    if type(t) ~= "table" then return 0 end
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

local function _getEventBusBestEffort(kit)
    local K = _getKit(kit)
    if type(K) == "table" and type(K.bus) == "table" and type(K.bus.eventBus) == "table" then
        return K.bus.eventBus
    end
    local ok, mod = pcall(require, "dwkit.bus.event_bus")
    if ok and type(mod) == "table" then
        return mod
    end
    return nil
end

function M.getState(kit)
    return _ensure(kit)
end

function M.getSummary(kit)
    local st = _ensure(kit)
    return {
        maxLog = st.maxLog or 50,
        logCount = (type(st.log) == "table") and #st.log or 0,
        tapToken = st.tapToken,
        subsCount = _countMap(st.subs),
    }
end

function M.reset(kit)
    local st = _ensure(kit)
    st.log = {}
    st.tapToken = nil
    st.subs = {}
end

function M.shutdown(kit)
    local st = _ensure(kit)
    local bus = _getEventBusBestEffort(kit)

    if type(bus) == "table" then
        -- tap off
        if st.tapToken ~= nil and type(bus.tapOff) == "function" then
            pcall(bus.tapOff, st.tapToken)
        end

        -- unsubscribe all
        if type(st.subs) == "table" and type(bus.off) == "function" then
            for ev, tok in pairs(st.subs) do
                if tok ~= nil then
                    pcall(bus.off, tok)
                end
                st.subs[ev] = nil
            end
        end
    end

    -- clear tokens regardless
    st.tapToken = nil
    st.subs = st.subs or {}
end

return M
