-- #########################################################################
-- Module Name : dwkit.ui.test_ui
-- Owner       : UI
-- Version     : v2026-01-15B
-- Purpose     :
--   - Minimal SAFE UI module that creates a visible Geyser window.
--   - Mirrors sample_ui contract so we can validate multi-UI management.
--   - Demonstrates enabled/visible gates and apply()/dispose() lifecycle.
--
-- Public API  :
--   - getModuleVersion() -> string
--   - getUiId() -> string
--   - init(opts?) -> boolean ok, string|nil err
--   - apply(opts?) -> boolean ok, string|nil err
--   - getState() -> table copy
--   - dispose(opts?) -> boolean ok, string|nil err
--
-- Events Emitted   : None (SAFE)
-- Events Consumed  : None (SAFE)
-- Gameplay Sends   : None
-- Automation       : None
-- Dependencies     :
--   - DWKit.config.guiSettings (preferred) or require("dwkit.config.gui_settings")
--   - Mudlet Geyser (Label / Container)
--   - dwkit.ui.ui_base
-- Invariants       :
--   - MUST remain SAFE. No gameplay commands, no timers.
-- #########################################################################

local M = {}

M.VERSION = "v2026-01-28A"
M.UI_ID = "test_ui"

local U = require("dwkit.ui.ui_base")
local W = require("dwkit.ui.ui_window")
local ListKit = require("dwkit.ui.ui_list_kit")

local _state = {
    inited = false,
    lastApply = nil,
    lastError = nil,
    enabled = nil,
    visible = nil,
    widgets = {
        container = nil,
        label = nil,
    },
}

local function _out(line)
    U.out(line)
end

local function _ensureWidgets()
    local ok, widgets, err = U.ensureWidgets(M.UI_ID, { "container", "label", "content", "panel" }, function()
        local G = U.getGeyser()
        if not G then
            return nil
        end

        local bundle = W.create({
            uiId = M.UI_ID,
            title = "Test UI",
            x = 420,
            y = 480,
            width = 360,
            height = 240,
            padding = 6,
            onClose = function(b)
                if type(b) == "table" and type(b.frame) == "table" then
                    U.safeHide(b.frame)
                end
            end,
        })

        if type(bundle) ~= "table" or type(bundle.frame) ~= "table" or type(bundle.content) ~= "table" then
            return nil
        end

        local container = bundle.frame
        local contentParent = bundle.content

        local panel = G.Container:new({
            name = "__DWKit_test_ui_panel",
            x = 0,
            y = 0,
            width = "100%",
            height = "100%",
        }, contentParent)

        ListKit.applyPanelStyle(panel)

        local label = G.Label:new({
            name = "__DWKit_test_ui_label",
            x = 0,
            y = 0,
            width = "100%",
            height = "100%",
        }, panel)

        ListKit.applyTextLabelStyle(label)

        return { container = container, content = contentParent, panel = panel, label = label }
    end)

    if not ok or type(widgets) ~= "table" then
        return false, err or "Failed to create widgets"
    end

    _state.widgets.container = widgets.container
    _state.widgets.content = widgets.content
    _state.widgets.panel = widgets.panel
    _state.widgets.label = widgets.label
    return true, nil
end

local function _setLabelText(txt)
    U.safeSetLabelText(_state.widgets.label, txt)
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

    -- Seed UI id here (does NOT overwrite existing record)
    if type(gs.register) == "function" then
        local okSeed, errSeed = gs.register(M.UI_ID, { enabled = true, visible = true }, { save = false })
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
        _setLabelText("DWKit test_ui\n(enabled=ON, visible=ON)")
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
    return {
        uiId = M.UI_ID,
        version = M.VERSION,
        inited = (_state.inited == true),
        enabled = _state.enabled,
        visible = _state.visible,
        lastApply = _state.lastApply,
        lastError = _state.lastError,
        widgets = {
            hasContainer = (type(_state.widgets.container) == "table"),
            hasLabel = (type(_state.widgets.label) == "table"),
        },
    }
end

function M.dispose(opts)
    opts = (type(opts) == "table") and opts or {}

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
