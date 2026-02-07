-- #########################################################################
-- Module Name : dwkit.ui.sample_ui
-- Owner       : UI
-- Version     : v2026-02-07A
-- Purpose     :
--   - Minimal SAFE UI module that creates a visible Geyser window.
--   - Demonstrates self-seeding gui_settings from inside UI module.
--   - Demonstrates enabled/visible gates and apply() contract.
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
--
-- Fix (v2026-02-07A):
--   - dispose() must NOT clear ui_store entry; keep deterministic state.visible boolean.
-- #########################################################################

local M = {}

M.VERSION = "v2026-02-07A"
M.UI_ID = "sample_ui"

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
            title = "Sample UI",
            x = 420,
            y = 220,
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
            name = "__DWKit_sample_ui_panel",
            x = 0,
            y = 0,
            width = "100%",
            height = "100%",
        }, contentParent)

        ListKit.applyPanelStyle(panel)

        local label = G.Label:new({
            name = "__DWKit_sample_ui_label",
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
        local okSeed, errSeed = gs.register(M.UI_ID, { enabled = true }, { save = false })
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

    -- Start hidden until apply() decides
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

    -- Enabled defaults true, Visible defaults false unless persisted ON
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
        _setLabelText("DWKit sample_ui\n(enabled=ON, visible=ON)")
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

    -- IMPORTANT: Do NOT clear the ui_store entry.
    if type(U.setUiStateVisibleBestEffort) == "function" then
        pcall(U.setUiStateVisibleBestEffort, M.UI_ID, false)
    else
        pcall(U.setUiRuntime, M.UI_ID, { state = { visible = false } })
    end

    local entry = nil
    if type(U.ensureUiStoreEntry) == "function" then
        entry = U.ensureUiStoreEntry(M.UI_ID)
    end
    if type(entry) == "table" then
        entry.state = (type(entry.state) == "table") and entry.state or {}
        entry.state.visible = false
        entry.frame = nil
        entry.container = nil
        entry.content = nil
        entry.panel = nil
        entry.label = nil
    end

    U.safeDelete(_state.widgets.label)
    U.safeDelete(_state.widgets.container)

    _state.widgets.label = nil
    _state.widgets.container = nil
    _state.widgets.panel = nil
    _state.widgets.content = nil

    _state.inited = false
    _state.enabled = nil
    _state.visible = nil
    _state.lastError = nil
    return true, nil
end

return M
