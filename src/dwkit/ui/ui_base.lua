-- #########################################################################
-- Module Name : dwkit.ui.ui_base
-- Owner       : UI
-- Version     : v2026-01-16B
-- Purpose     :
--   - Shared SAFE helper utilities for DWKit UI modules.
--   - Avoids copy/paste across UI modules (store, widgets, show/hide/delete, etc).
--   - Provides best-effort access to guiSettings and Geyser.
--   - Provides SAFE subscription helpers for service "Updated" events
--     (centralized pattern for auto-refresh UIs).
--
-- Public API  :
--   - getModuleVersion() -> string
--   - out(line)
--   - getGuiSettingsBestEffort() -> table|nil
--   - getGeyser() -> table|nil
--   - getUiStore() -> table|nil
--   - safeHide(widget)
--   - safeShow(widget)
--   - safeDelete(widget)
--   - safeSetLabelText(label, text)
--   - ensureWidgets(uiId, requiredKeys, createFn) -> boolean ok, table|nil widgets, string|nil err
--   - clearUiStoreEntry(uiId)
--   - subscribeServiceUpdates(uiId, onUpdatedFn, handlerFn, opts?) -> boolean ok, table|nil sub, string|nil err
--   - unsubscribeServiceUpdates(sub) -> boolean ok
--
-- SAFE Constraints:
--   - No gameplay commands
--   - No timers
--   - No automation
--   - Best-effort event subscription/unsubscription ONLY (no emits here)
-- #########################################################################

local M = {}

M.VERSION = "v2026-01-16B"

local function _isNonEmptyString(s)
    return type(s) == "string" and s ~= ""
end

function M.getModuleVersion()
    return M.VERSION
end

function M.out(line)
    line = tostring(line or "")
    if type(cecho) == "function" then
        cecho(line .. "\n")
    elseif type(echo) == "function" then
        echo(line .. "\n")
    else
        print(line)
    end
end

function M.getGuiSettingsBestEffort()
    if type(_G.DWKit) == "table"
        and type(_G.DWKit.config) == "table"
        and type(_G.DWKit.config.guiSettings) == "table"
    then
        return _G.DWKit.config.guiSettings
    end

    local ok, mod = pcall(require, "dwkit.config.gui_settings")
    if ok and type(mod) == "table" then
        return mod
    end

    return nil
end

function M.getGeyser()
    local G = _G.Geyser
    if type(G) == "table" then return G end
    return nil
end

-- Global UI store to prevent duplicate windows across module reloads
function M.getUiStore()
    if type(_G.DWKit) ~= "table" then return nil end
    if type(_G.DWKit._uiStore) ~= "table" then
        _G.DWKit._uiStore = {}
    end
    return _G.DWKit._uiStore
end

function M.clearUiStoreEntry(uiId)
    if not _isNonEmptyString(uiId) then return end
    local store = M.getUiStore()
    if type(store) ~= "table" then return end
    store[uiId] = nil
end

function M.safeHide(w)
    if type(w) ~= "table" then return end
    if type(w.hide) == "function" then
        pcall(w.hide, w)
    end
end

function M.safeShow(w)
    if type(w) ~= "table" then return end
    if type(w.show) == "function" then
        pcall(w.show, w)
    end
end

function M.safeDelete(w)
    if type(w) ~= "table" then return end
    -- Geyser supports :delete() on many widgets
    if type(w.delete) == "function" then
        pcall(w.delete, w)
        return
    end
    -- fallback: hide only
    M.safeHide(w)
end

function M.safeSetLabelText(label, txt)
    if type(label) ~= "table" then return end
    if type(label.echo) == "function" then
        pcall(label.echo, label, tostring(txt or ""))
    end
end

local function _hasRequiredKeys(t, requiredKeys)
    if type(t) ~= "table" then return false end
    if type(requiredKeys) ~= "table" or #requiredKeys == 0 then
        return true
    end
    for _, k in ipairs(requiredKeys) do
        if t[k] == nil then
            return false
        end
    end
    return true
end

-- ensureWidgets
-- - Reuses widgets from global store if present and valid
-- - Otherwise creates new via createFn()
-- Returns: ok, widgets, err
function M.ensureWidgets(uiId, requiredKeys, createFn)
    if not _isNonEmptyString(uiId) then
        return false, nil, "uiId invalid"
    end
    if type(createFn) ~= "function" then
        return false, nil, "createFn invalid"
    end

    local store = M.getUiStore()
    if type(store) == "table" and type(store[uiId]) == "table" then
        local cached = store[uiId]
        if _hasRequiredKeys(cached, requiredKeys) then
            return true, cached, nil
        end
    end

    local okCreate, widgetsOrErr = pcall(createFn)
    if not okCreate or type(widgetsOrErr) ~= "table" then
        return false, nil, "createFn failed"
    end

    if not _hasRequiredKeys(widgetsOrErr, requiredKeys) then
        return false, nil, "createFn returned incomplete widgets"
    end

    if type(store) == "table" then
        store[uiId] = widgetsOrErr
    end

    return true, widgetsOrErr, nil
end

-- =========================================================================
-- Service Updated Event Subscription Helpers (SAFE)
-- =========================================================================

local function _bestEffortBusOff(handlerId)
    if handlerId == nil then return true end

    local okBus, BUS = pcall(require, "dwkit.bus.event_bus")
    if not okBus or type(BUS) ~= "table" then
        return false
    end

    -- Try common unsubscribe/off patterns (best-effort, no hard dependency)
    local candidates = { "off", "unsubscribe", "unsub", "remove", "removeHandler", "removeListener" }
    for _, fnName in ipairs(candidates) do
        if type(BUS[fnName]) == "function" then
            local ok = pcall(BUS[fnName], handlerId)
            if ok then return true end
        end
    end

    return false
end

-- subscribeServiceUpdates
-- - Centralized helper for service event subscriptions used by UIs
--
-- Params:
--   uiId        : string (for state/debug)
--   onUpdatedFn : function(handlerFn) -> ok, token|any, err?  (e.g. service.onUpdated)
--   handlerFn   : function(payload, subscription?)           (UI refresh logic)
--   opts        : table? { eventName=string, debugPrefix=string }
--
-- Returns:
--   ok, sub, err
--   sub = { uiId, handlerId, updatedEventName, debugPrefix }
function M.subscribeServiceUpdates(uiId, onUpdatedFn, handlerFn, opts)
    opts = (type(opts) == "table") and opts or {}

    if not _isNonEmptyString(uiId) then
        return false, nil, "uiId invalid"
    end
    if type(onUpdatedFn) ~= "function" then
        return false, nil, "onUpdatedFn invalid"
    end
    if type(handlerFn) ~= "function" then
        return false, nil, "handlerFn invalid"
    end

    local sub = {
        uiId = uiId,
        handlerId = nil,
        updatedEventName = (_isNonEmptyString(opts.eventName) and opts.eventName) or nil,
        debugPrefix = (_isNonEmptyString(opts.debugPrefix) and opts.debugPrefix) or "DWKit",
    }

    local function _wrapped(payload)
        -- handlerFn should never throw; protect UI from breaking the event bus
        pcall(handlerFn, payload, sub)
    end

    -- IMPORTANT:
    -- service.onUpdated typically returns: ok(bool), token(any), err(string|nil)
    -- pcall returns: pOk, ret1, ret2, ret3...
    local pOk, ret1, ret2, ret3 = pcall(onUpdatedFn, _wrapped)
    if not pOk then
        return false, nil, "onUpdatedFn pcall failed"
    end

    -- Common: (true, token, nil)
    if ret1 == false then
        return false, nil, tostring(ret2 or "subscribe failed")
    end

    local token = nil
    if type(ret1) ~= "boolean" then
        -- onUpdated returned only token (non-standard but supported)
        token = ret1
    else
        -- onUpdated returned ok(bool) first; token likely ret2
        token = ret2
        if token == nil and ret3 ~= nil then
            -- some odd shapes: (true, nil, token)
            token = ret3
        end
    end

    sub.handlerId = token
    return true, sub, nil
end

-- unsubscribeServiceUpdates
-- - Best-effort unsubscribe using known bus patterns.
-- - Safe if unsubscribe not supported yet.
function M.unsubscribeServiceUpdates(sub)
    if type(sub) ~= "table" then
        return true
    end
    local handlerId = sub.handlerId
    if handlerId == nil then
        return true
    end
    _bestEffortBusOff(handlerId)
    return true
end

return M
