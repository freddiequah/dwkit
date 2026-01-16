-- #########################################################################
-- Module Name : dwkit.ui.presence_ui
-- Owner       : UI
-- Version     : v2026-01-16D
-- Purpose     :
--   - SAFE Presence UI scaffold with live render from PresenceService (data only).
--   - Creates a small Geyser container + label.
--   - Demonstrates gui_settings self-seeding (register) + apply()/dispose() lifecycle.
--   - Subscribes to PresenceService "updated" event to auto-refresh when state changes.
--   - No timers, no send(), no automation.
--
-- Public API  :
--   - getModuleVersion() -> string
--   - getUiId() -> string
--   - init(opts?) -> boolean ok, string|nil err
--   - apply(opts?) -> boolean ok, string|nil err
--   - getState() -> table copy
--   - dispose(opts?) -> boolean ok, string|nil err
-- #########################################################################

local M = {}

M.VERSION = "v2026-01-16D"
M.UI_ID = "presence_ui"

local U = require("dwkit.ui.ui_base")

local function _safeRequire(modName)
    local ok, mod = pcall(require, modName)
    if ok then return true, mod end
    return false, mod
end

local function _sortedKeys(t)
    local keys = {}
    if type(t) ~= "table" then return keys end
    for k, _ in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    return keys
end

local function _asOneLine(x)
    if x == nil then return "nil" end
    if type(x) == "string" then
        local s = x:gsub("\n", " "):gsub("\r", " ")
        if #s > 80 then s = s:sub(1, 80) .. "..." end
        return s
    end
    if type(x) == "number" or type(x) == "boolean" then
        return tostring(x)
    end
    if type(x) == "table" then
        local n = 0
        for _ in pairs(x) do n = n + 1 end
        return "{table,count=" .. tostring(n) .. "}"
    end
    return tostring(x)
end

local function _formatPresenceState(state)
    state = (type(state) == "table") and state or {}
    local keys = _sortedKeys(state)

    local lines = {}
    lines[#lines + 1] = "DWKit presence_ui"
    lines[#lines + 1] = "keys=" .. tostring(#keys)

    -- Friendly fields if present
    if type(state.selfName) == "string" and state.selfName ~= "" then
        lines[#lines + 1] = "self=" .. tostring(state.selfName)
    end

    if type(state.nearbyPlayers) == "table" then
        local cnt = #state.nearbyPlayers
        lines[#lines + 1] = "nearbyPlayers=" .. tostring(cnt)
    end

    -- Show first few keys as a quick debug view
    local shown = 0
    for _, k in ipairs(keys) do
        if shown >= 4 then break end
        if k ~= "selfName" and k ~= "nearbyPlayers" then
            lines[#lines + 1] = tostring(k) .. "=" .. _asOneLine(state[k])
            shown = shown + 1
        end
    end

    return table.concat(lines, "\n")
end

local _state = {
    inited = false,
    lastApply = nil,
    lastError = nil,
    enabled = nil,
    visible = nil,

    -- Centralized subscription record (from U.subscribeServiceUpdates)
    subscription = nil,

    widgets = {
        container = nil,
        label = nil,
    },
}

local function _out(line)
    U.out(line)
end

local function _ensureWidgets()
    local ok, widgets, err = U.ensureWidgets(M.UI_ID, { "container", "label" }, function()
        local G = U.getGeyser()
        if not G then
            return nil
        end

        local cname = "__DWKit_presence_ui_container"
        local lname = "__DWKit_presence_ui_label"

        local container = G.Container:new({
            name = cname,
            x = 30,
            y = 220,
            width = 280,
            height = 80,
        })

        local label = G.Label:new({
            name = lname,
            x = 0,
            y = 0,
            width = "100%",
            height = "100%",
        }, container)

        pcall(function()
            label:setStyleSheet([[
                background-color: rgba(0,0,0,180);
                color: #FFFFFF;
                border: 1px solid #666666;
                padding-left: 8px;
                padding-top: 8px;
                font-size: 10pt;
            ]])
        end)

        return { container = container, label = label }
    end)

    if not ok or type(widgets) ~= "table" then
        return false, err or "Failed to create widgets"
    end

    _state.widgets.container = widgets.container
    _state.widgets.label = widgets.label
    return true, nil
end

local function _setLabelText(txt)
    U.safeSetLabelText(_state.widgets.label, txt)
end

local function _resolveUpdatedEventName(S)
    if type(S) ~= "table" then return nil end
    if type(S.getUpdatedEventName) == "function" then
        local ok, v = pcall(S.getUpdatedEventName)
        if ok and type(v) == "string" and v ~= "" then
            return v
        end
    end
    if type(S.EV_UPDATED) == "string" and S.EV_UPDATED ~= "" then
        return S.EV_UPDATED
    end
    return nil
end

local function _renderFromService()
    local okS, S = _safeRequire("dwkit.services.presence_service")
    if not okS or type(S) ~= "table" then
        return false, "PresenceService not available"
    end

    local state = {}
    if type(S.getState) == "function" then
        local okGet, v = pcall(S.getState)
        if okGet and type(v) == "table" then state = v end
    end

    _setLabelText(_formatPresenceState(state))
    return true, nil
end

local function _ensureSubscription()
    if type(_state.subscription) == "table" and _state.subscription.handlerId ~= nil then
        return true, nil
    end

    local okS, S = _safeRequire("dwkit.services.presence_service")
    if not okS or type(S) ~= "table" then
        return false, "PresenceService not available"
    end

    if type(S.onUpdated) ~= "function" then
        return false, "PresenceService.onUpdated() not available"
    end

    local evName = _resolveUpdatedEventName(S)
    if type(evName) ~= "string" or evName == "" then
        return false, "Presence updated event name not available"
    end

    local handlerFn = function(payload)
        -- Only render when we are supposed to be visible.
        if _state.enabled == true and _state.visible == true and type(_state.widgets.label) == "table" then
            _renderFromService()
        end
    end

    local okSub, sub, errSub = U.subscribeServiceUpdates(
        M.UI_ID,
        S.onUpdated,
        handlerFn,
        { eventName = evName, debugPrefix = "[DWKit UI] presence_ui" }
    )

    if not okSub then
        return false, tostring(errSub or "subscribe failed")
    end

    _state.subscription = sub
    return true, nil
end

function M.getModuleVersion() return M.VERSION end

function M.getUiId() return M.UI_ID end

function M.init(opts)
    opts = (type(opts) == "table") and opts or {}

    local gs = U.getGuiSettingsBestEffort()
    if type(gs) ~= "table" then
        _state.lastError = "guiSettings not available (run loader.init first)"
        return false, _state.lastError
    end

    if type(gs.register) == "function" then
        local okSeed, errSeed = gs.register(M.UI_ID, { enabled = false }, { save = false })
        if not okSeed then
            _state.lastError = "seed failed: " .. tostring(errSeed)
            return false, _state.lastError
        end
    end

    local okW, errW = _ensureWidgets()
    if not okW then
        _state.lastError = tostring(errW)
        return false, _state.lastError
    end

    U.safeHide(_state.widgets.container)

    _state.inited = true
    _state.lastError = nil
    return true, nil
end

function M.apply(opts)
    opts = (type(opts) == "table") and opts or {}

    local gs = U.getGuiSettingsBestEffort()
    if type(gs) ~= "table" then
        _state.lastError = "guiSettings not available"
        return false, _state.lastError
    end

    if _state.inited ~= true then
        local okInit, errInit = M.init()
        if not okInit then
            return false, errInit
        end
    end

    local enabled = true
    local visible = false

    if type(gs.isEnabled) == "function" then
        local okE, v = pcall(gs.isEnabled, M.UI_ID, true)
        if okE then enabled = (v == true) end
    end

    if type(gs.getVisible) == "function" then
        local okV, v = pcall(gs.getVisible, M.UI_ID, false)
        if okV then visible = (v == true) end
    end

    _state.enabled = enabled
    _state.visible = visible
    _state.lastApply = os.time()
    _state.lastError = nil

    local action = "hide"
    if enabled and visible then
        action = "show"

        local okSub, errSub = _ensureSubscription()
        if not okSub then
            _state.lastError = tostring(errSub)
        end

        local okR, errR = _renderFromService()
        if not okR then
            _state.lastError = tostring(errR)
        end

        U.safeShow(_state.widgets.container)
    else
        U.safeHide(_state.widgets.container)
    end

    _out(string.format("[DWKit UI] apply uiId=%s enabled=%s visible=%s action=%s",
        tostring(M.UI_ID),
        tostring(enabled),
        tostring(visible),
        tostring(action)
    ))

    return true, nil
end

function M.getState()
    local sub = (type(_state.subscription) == "table") and _state.subscription or {}

    return {
        uiId = M.UI_ID,
        version = M.VERSION,
        inited = (_state.inited == true),
        enabled = _state.enabled,
        visible = _state.visible,
        lastApply = _state.lastApply,
        lastError = _state.lastError,
        subscription = {
            handlerId = sub.handlerId,
            updatedEventName = sub.updatedEventName,
        },
        widgets = {
            hasContainer = (type(_state.widgets.container) == "table"),
            hasLabel = (type(_state.widgets.label) == "table"),
        },
    }
end

function M.dispose(opts)
    opts = (type(opts) == "table") and opts or {}

    -- Best-effort centralized unsubscribe
    U.unsubscribeServiceUpdates(_state.subscription)
    _state.subscription = nil

    U.clearUiStoreEntry(M.UI_ID)

    U.safeDelete(_state.widgets.label)
    U.safeDelete(_state.widgets.container)

    _state.widgets.label = nil
    _state.widgets.container = nil

    _state.inited = false
    _state.lastError = nil
    return true, nil
end

return M
