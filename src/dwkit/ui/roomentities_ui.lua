-- #########################################################################
-- Module Name : dwkit.ui.roomentities_ui
-- Owner       : UI
-- Version     : v2026-01-16E
-- Purpose     :
--   - SAFE RoomEntities UI scaffold with live render from RoomEntitiesService (data only).
--   - Creates a small Geyser container + label.
--   - Demonstrates gui_settings self-seeding (register) + apply()/dispose() lifecycle.
--   - Subscribes to RoomEntitiesService Updated event to auto-refresh label.
--   - No timers, no send(), no automation.
-- #########################################################################

local M = {}

M.VERSION = "v2026-01-16E"
M.UI_ID = "roomentities_ui"

local U = require("dwkit.ui.ui_base")

local function _safeRequire(modName)
    local ok, mod = pcall(require, modName)
    if ok then return true, mod end
    return false, mod
end

local function _countAny(x)
    if type(x) ~= "table" then return 0 end
    local n = 0
    for _ in pairs(x) do n = n + 1 end
    return n
end

local function _formatRoomEntitiesState(state)
    state = (type(state) == "table") and state or {}

    local players = state.players
    local mobs = state.mobs
    local items = state.items
    local unknown = state.unknown

    local lines = {}
    lines[#lines + 1] = "DWKit roomentities_ui"
    lines[#lines + 1] = "players=" .. tostring(_countAny(players))
    lines[#lines + 1] = "mobs=" .. tostring(_countAny(mobs))
    lines[#lines + 1] = "items=" .. tostring(_countAny(items))
    lines[#lines + 1] = "unknown=" .. tostring(_countAny(unknown))

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

        local cname = "__DWKit_roomentities_ui_container"
        local lname = "__DWKit_roomentities_ui_label"

        local container = G.Container:new({
            name = cname,
            x = 30,
            y = 310,
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
                background-color: rgba(10,10,10,180);
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

local function _getServiceStateBestEffort()
    local okS, S = _safeRequire("dwkit.services.roomentities_service")
    if not okS or type(S) ~= "table" then
        return {}
    end

    if type(S.getState) == "function" then
        local okGet, v = pcall(S.getState)
        if okGet and type(v) == "table" then
            return v
        end
    end

    return {}
end

local function _renderNow(state)
    state = (type(state) == "table") and state or {}
    _setLabelText(_formatRoomEntitiesState(state))
end

local function _renderFromService()
    local state = _getServiceStateBestEffort()
    _renderNow(state)
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

local function _ensureSubscription()
    if type(_state.subscription) == "table" and _state.subscription.handlerId ~= nil then
        return true, nil
    end

    local okS, S = _safeRequire("dwkit.services.roomentities_service")
    if not okS or type(S) ~= "table" then
        _state.lastError = "RoomEntitiesService not available"
        return false, _state.lastError
    end

    if type(S.onUpdated) ~= "function" then
        _state.lastError = "RoomEntitiesService.onUpdated not available"
        return false, _state.lastError
    end

    local evName = _resolveUpdatedEventName(S)
    if type(evName) ~= "string" or evName == "" then
        _state.lastError = "RoomEntities updated event name not available"
        return false, _state.lastError
    end

    local handlerFn = function(payload)
        -- Only update UI when it is actually visible+enabled
        if _state.enabled ~= true or _state.visible ~= true then
            return
        end

        payload = (type(payload) == "table") and payload or {}

        -- Prefer payload.state if present; fallback to service.getState
        if type(payload.state) == "table" then
            _renderNow(payload.state)
        else
            _renderFromService()
        end
    end

    local okSub, sub, errSub = U.subscribeServiceUpdates(
        M.UI_ID,
        S.onUpdated,
        handlerFn,
        { eventName = evName, debugPrefix = "[DWKit UI] roomentities_ui" }
    )

    if not okSub then
        _state.lastError = tostring(errSub or "subscribe failed")
        return false, _state.lastError
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
            -- Still show UI, but it will only refresh on manual apply/reload
            _out("[DWKit UI] roomentities_ui WARN: " .. tostring(errSub))
        end

        _renderFromService()
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
