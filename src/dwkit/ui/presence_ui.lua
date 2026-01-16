-- #########################################################################
-- Module Name : dwkit.ui.presence_ui
-- Owner       : UI
-- Version     : v2026-01-16C
-- Purpose     :
--   - SAFE Presence UI scaffold with live render from PresenceService (data only).
--   - Creates a small Geyser container + label.
--   - Demonstrates gui_settings self-seeding (register) + apply()/dispose() lifecycle.
--   - Event-driven refresh via PresenceService.onUpdated() when visible (no timers).
--   - No send(), no automation.
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

M.VERSION = "v2026-01-16C"
M.UI_ID = "presence_ui"

local U = require("dwkit.ui.ui_base")
local BUS = require("dwkit.bus.event_bus")

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

    if type(state.selfName) == "string" and state.selfName ~= "" then
        lines[#lines + 1] = "self=" .. tostring(state.selfName)
    end

    if type(state.nearbyPlayers) == "table" then
        local cnt = #state.nearbyPlayers
        lines[#lines + 1] = "nearbyPlayers=" .. tostring(cnt)
    end

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

    subToken = nil,

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

local function _getPresenceService()
    local okS, S = _safeRequire("dwkit.services.presence_service")
    if okS and type(S) == "table" then return S end
    return nil
end

local function _renderFromState(state)
    _setLabelText(_formatPresenceState(state))
end

local function _unsubscribe()
    if type(_state.subToken) == "number" then
        pcall(BUS.off, _state.subToken)
    end
    _state.subToken = nil
end

local function _subscribeIfNeeded()
    if type(_state.subToken) == "number" then
        return true, nil
    end

    local S = _getPresenceService()
    if not S or type(S.onUpdated) ~= "function" then
        -- No service available yet; UI can still render static state on apply().
        return true, nil
    end

    local ok, token, err = S.onUpdated(function(payload)
        -- Only refresh when UI is actively meant to be on-screen.
        if not (_state.enabled == true and _state.visible == true) then return end

        local nextState = nil
        if type(payload) == "table" and type(payload.state) == "table" then
            nextState = payload.state
        elseif type(S.getState) == "function" then
            local okGet, v = pcall(S.getState)
            if okGet and type(v) == "table" then nextState = v end
        end

        if type(nextState) == "table" then
            _renderFromState(nextState)
        end
    end)

    if ok and type(token) == "number" then
        _state.subToken = token
        return true, nil
    end

    return false, err or "subscribe failed"
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

        -- Subscribe for live updates while visible.
        local okSub, errSub = _subscribeIfNeeded()
        if not okSub then
            -- Non-fatal: show UI anyway, but record error.
            _state.lastError = tostring(errSub)
        end

        local S = _getPresenceService()
        local state = {}
        if S and type(S.getState) == "function" then
            local okGet, v = pcall(S.getState)
            if okGet and type(v) == "table" then state = v end
        end

        _renderFromState(state)
        U.safeShow(_state.widgets.container)
    else
        -- Not visible: unsubscribe to avoid stale/hidden updates.
        _unsubscribe()
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
    return {
        uiId = M.UI_ID,
        version = M.VERSION,
        inited = (_state.inited == true),
        enabled = _state.enabled,
        visible = _state.visible,
        lastApply = _state.lastApply,
        lastError = _state.lastError,
        subscribed = (type(_state.subToken) == "number"),
        widgets = {
            hasContainer = (type(_state.widgets.container) == "table"),
            hasLabel = (type(_state.widgets.label) == "table"),
        },
    }
end

function M.dispose(opts)
    opts = (type(opts) == "table") and opts or {}

    -- Always unsubscribe on dispose.
    _unsubscribe()

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
