-- #########################################################################
-- Module Name : dwkit.services.event_watcher_service
-- Owner       : Services
-- Version     : v2026-01-23B
-- Purpose     :
--   - SAFE internal event watcher for DWKit event bus.
--   - Subscribes to a registry-derived allowlist (no guessing).
--   - Captures only bounded, shallow snapshots (no large table retention).
--   - Manual-only; no gameplay output; no timers.
--
-- Public API  :
--   - install(opts?) -> boolean ok, string|nil err
--   - uninstall(opts?) -> boolean ok, string|nil err
--   - status(opts?) -> table state  (also prints unless opts.quiet=true)
--   - getState() -> table state (no printing)
--
-- Events Emitted   : None (watcher only)
-- Events Consumed  : Registry allowlist
-- Persistence      : None
-- Automation Policy: Manual only
-- Dependencies     : dwkit.core.identity, dwkit.bus.event_registry, dwkit.bus.event_bus
-- #########################################################################

local M = {}

M.VERSION = "v2026-01-23B"

local ID = require("dwkit.core.identity")

local function _nowTs()
    return os.time()
end

local function _out(line)
    line = tostring(line or "")
    if type(cecho) == "function" then
        cecho(line .. "\n")
    elseif type(echo) == "function" then
        echo(line .. "\n")
    else
        print(line)
    end
end

local function _isNonEmptyString(s) return type(s) == "string" and s ~= "" end

local function _shallowCopy(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do out[k] = v end
    return out
end

local function _truncate(s, maxLen)
    s = tostring(s or "")
    maxLen = tonumber(maxLen) or 200
    if #s <= maxLen then return s end
    return s:sub(1, maxLen) .. "…"
end

-- bounded snapshot: only primitive keys; table values summarized
local function _snapPayload(payload, opts)
    opts = opts or {}
    local maxKeys = tonumber(opts.maxKeys) or 24
    local maxStrLen = tonumber(opts.maxStrLen) or 200

    if type(payload) ~= "table" then
        if type(payload) == "string" then return _truncate(payload, maxStrLen) end
        return payload
    end

    local out = {}
    local keys = {}
    for k, _ in pairs(payload) do
        keys[#keys + 1] = k
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)

    local count = 0
    for _, k in ipairs(keys) do
        count = count + 1
        if count > maxKeys then
            out._truncated = true
            out._truncatedAt = maxKeys
            break
        end

        local v = payload[k]
        local tv = type(v)
        if tv == "string" then
            out[k] = _truncate(v, maxStrLen)
        elseif tv == "number" or tv == "boolean" or tv == "nil" then
            out[k] = v
        elseif tv == "table" then
            -- do not retain nested tables; keep a small hint only
            local n = 0
            for _k, _v in pairs(v) do
                n = n + 1
                if n >= 50 then break end
            end
            out[k] = "<table keys~" .. tostring(n) .. ">"
        else
            out[k] = "<" .. tv .. ">"
        end
    end

    return out
end

local function _getEventBus()
    local eb = (DWKit and DWKit.bus and DWKit.bus.eventBus) or nil
    if type(eb) ~= "table" then return nil end
    return eb
end

local function _resolveSubscribeFn(eb)
    if type(eb.subscribe) == "function" then return "subscribe", eb.subscribe end
    if type(eb.sub) == "function" then return "sub", eb.sub end
    if type(eb.on) == "function" then return "on", eb.on end
    return nil, nil
end

local function _resolveUnsubscribeFn(eb)
    if type(eb.unsubscribe) == "function" then return "unsubscribe", eb.unsubscribe end
    if type(eb.unsub) == "function" then return "unsub", eb.unsub end
    if type(eb.off) == "function" then return "off", eb.off end
    return nil, nil
end

local function _buildAllowlistFromRegistry(registry, opts)
    opts = opts or {}
    local allow = {}

    -- minimal conservative default: Boot + Service Updated events only (as defined in registry)
    local prefix = tostring(ID.eventPrefix or "DWKit:")
    local candidates = {
        prefix .. "Boot:Ready",
        prefix .. "Service:Presence:Updated",
        prefix .. "Service:ActionModel:Updated",
        prefix .. "Service:SkillRegistry:Updated",
        prefix .. "Service:ScoreStore:Updated",
        prefix .. "Service:RoomEntities:Updated",
        prefix .. "Service:WhoStore:Updated",
    }

    for _, name in ipairs(candidates) do
        if type(registry) == "table" and type(registry.has) == "function" then
            if registry.has(name) then
                allow[#allow + 1] = name
            end
        else
            -- if registry API not present, be safe: subscribe to none
        end
    end

    -- caller may override/append
    if type(opts.extraEvents) == "table" then
        for _, n in ipairs(opts.extraEvents) do
            if _isNonEmptyString(n) and (type(registry) == "table" and type(registry.has) == "function" and registry.has(n)) then
                allow[#allow + 1] = n
            end
        end
    end

    -- de-dupe
    local seen, out = {}, {}
    for _, n in ipairs(allow) do
        if not seen[n] then
            seen[n] = true
            out[#out + 1] = n
        end
    end
    table.sort(out)
    return out
end

-- state
local S = {
    installed = false,
    installedAt = nil,
    version = M.VERSION,
    subscribed = {}, -- name -> token|true
    subscribedCount = 0,

    receivedCount = 0,
    lastEventName = nil,
    lastReceivedAt = nil,
    lastPayload = nil,

    opts = {
        maxKeys = 24,
        maxStrLen = 200,
    }
}

local function _recountSubs()
    local n = 0
    for _, _ in pairs(S.subscribed or {}) do n = n + 1 end
    S.subscribedCount = n
end

local function _handlerFactory(evName, opts)
    return function(payload)
        S.receivedCount = (tonumber(S.receivedCount) or 0) + 1
        S.lastEventName = tostring(evName or "")
        S.lastReceivedAt = _nowTs()
        S.lastPayload = _snapPayload(payload, opts or S.opts)
        return true
    end
end

function M.install(opts)
    opts = opts or {}
    if S.installed then
        return true, nil
    end

    local eb = _getEventBus()
    if not eb then
        return false, "eventBus not available on DWKit.bus.eventBus"
    end

    local subName, subFn = _resolveSubscribeFn(eb)
    if not subFn then
        return false, "eventBus subscribe function not available (expected subscribe/sub/on)"
    end

    local registryOk, registryOrErr = pcall(require, "dwkit.bus.event_registry")
    if not registryOk then
        return false, "event_registry require failed: " .. tostring(registryOrErr)
    end
    local registry = registryOrErr

    -- merge snapshot opts
    S.opts.maxKeys = tonumber(opts.maxKeys) or S.opts.maxKeys
    S.opts.maxStrLen = tonumber(opts.maxStrLen) or S.opts.maxStrLen

    local allowlist = _buildAllowlistFromRegistry(registry, opts)

    -- subscribe
    S.subscribed = {}
    for _, evName in ipairs(allowlist) do
        local handler = _handlerFactory(evName, S.opts)
        local okCall, a, b = pcall(subFn, eb, evName, handler)

        -- tolerate differing return signatures:
        -- (ok, token) or (token) or (true)
        if okCall then
            local token = nil
            if type(a) == "string" or type(a) == "number" then
                token = a
            elseif type(b) == "string" or type(b) == "number" then
                token = b
            end
            S.subscribed[evName] = token or true
        else
            -- if any single subscribe fails, we keep going (best-effort)
            -- but record a sentinel so status shows it
            S.subscribed[evName] = false
        end
    end

    _recountSubs()

    S.installed = true
    S.installedAt = _nowTs()

    if not opts.quiet then
        _out("[DWKit EventWatcher] install OK")
        _out("  version=" .. tostring(M.VERSION))
        _out("  subscribedCount=" .. tostring(S.subscribedCount))
        _out("  subscribeFn=" .. tostring(subName))
    end

    return true, nil
end

function M.uninstall(opts)
    opts = opts or {}
    if not S.installed then
        return true, nil
    end

    local eb = _getEventBus()
    local unName, unFn = eb and _resolveUnsubscribeFn(eb) or nil, nil
    if eb then
        unName, unFn = _resolveUnsubscribeFn(eb)
    end

    if eb and unFn then
        for evName, token in pairs(S.subscribed or {}) do
            -- try token-based, but tolerate signature differences
            pcall(unFn, eb, evName, token)
        end
    end

    S.installed = false
    S.installedAt = nil
    S.subscribed = {}
    S.subscribedCount = 0

    if not opts.quiet then
        _out("[DWKit EventWatcher] uninstall OK" ..
        (unFn and (" (via " .. tostring(unName) .. ")") or " (no unsubscribe fn)"))
    end

    return true, nil
end

function M.getState()
    local c = {
        version = M.VERSION,
        installed = S.installed,
        installedAt = S.installedAt,
        subscribedCount = S.subscribedCount,
        receivedCount = S.receivedCount,
        lastEventName = S.lastEventName,
        lastReceivedAt = S.lastReceivedAt,
        lastPayload = _shallowCopy(S.lastPayload),
    }
    return c
end

function M.status(opts)
    opts = opts or {}
    local st = M.getState()

    if not opts.quiet then
        _out("[DWKit EventWatcher] status")
        _out("  version=" .. tostring(st.version))
        _out("  installed=" .. tostring(st.installed))
        _out("  subscribedCount=" .. tostring(st.subscribedCount))
        _out("  receivedCount=" .. tostring(st.receivedCount))
        _out("  lastEventName=" .. tostring(st.lastEventName))
        _out("  lastReceivedAt=" .. tostring(st.lastReceivedAt))
        if st.lastPayload ~= nil then
            if type(st.lastPayload) == "table" then
                local keys = {}
                for k, _ in pairs(st.lastPayload) do keys[#keys + 1] = tostring(k) end
                table.sort(keys)
                _out("  lastPayload keys=" .. tostring(#keys))
                for _, k in ipairs(keys) do
                    _out("    " .. k .. "=" .. tostring(st.lastPayload[k]))
                end
            else
                _out("  lastPayload=" .. tostring(st.lastPayload))
            end
        end
    end

    return st
end

return M
