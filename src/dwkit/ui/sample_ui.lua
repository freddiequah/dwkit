-- #########################################################################
-- Module Name : dwkit.ui.sample_ui
-- Owner       : UI
-- Version     : v2026-01-15B
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
-- Invariants       :
--   - MUST remain SAFE. No gameplay commands, no timers.
-- #########################################################################

local M = {}

M.VERSION = "v2026-01-15B"
M.UI_ID = "sample_ui"

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
    line = tostring(line or "")
    if type(cecho) == "function" then
        cecho(line .. "\n")
    elseif type(echo) == "function" then
        echo(line .. "\n")
    else
        print(line)
    end
end

local function _getGuiSettingsBestEffort()
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

local function _getGeyser()
    local G = _G.Geyser
    if type(G) == "table" then return G end
    return nil
end

-- Global UI store to prevent duplicate windows across module reloads
local function _getUiStore()
    if type(_G.DWKit) ~= "table" then return nil end
    if type(_G.DWKit._uiStore) ~= "table" then
        _G.DWKit._uiStore = {}
    end
    return _G.DWKit._uiStore
end

local function _safeHide(w)
    if type(w) ~= "table" then return end
    if type(w.hide) == "function" then pcall(w.hide, w) end
end

local function _safeShow(w)
    if type(w) ~= "table" then return end
    if type(w.show) == "function" then pcall(w.show, w) end
end

local function _safeDelete(w)
    if type(w) ~= "table" then return end
    -- Geyser supports :delete() on many widgets
    if type(w.delete) == "function" then
        pcall(w.delete, w)
        return
    end
    -- fallback: hide only
    _safeHide(w)
end

local function _ensureWidgets()
    local store = _getUiStore()
    if type(store) == "table" and type(store[M.UI_ID]) == "table" then
        local s = store[M.UI_ID]
        if type(s.container) == "table" and type(s.label) == "table" then
            _state.widgets.container = s.container
            _state.widgets.label = s.label
            return true, nil
        end
    end

    local G = _getGeyser()
    if not G then
        return false, "Geyser not available (UI cannot be created)"
    end

    -- Create a simple container + label
    local cname = "__DWKit_sample_ui_container"
    local lname = "__DWKit_sample_ui_label"

    local okC, container = pcall(function()
        return G.Container:new({
            name = cname,
            x = 30,
            y = 80,
            width = 280,
            height = 60,
        })
    end)

    if not okC or type(container) ~= "table" then
        return false, "Failed to create Geyser.Container"
    end

    local okL, label = pcall(function()
        return G.Label:new({
            name = lname,
            x = 0,
            y = 0,
            width = "100%",
            height = "100%",
        }, container)
    end)

    if not okL or type(label) ~= "table" then
        -- cleanup container
        pcall(function() _safeDelete(container) end)
        return false, "Failed to create Geyser.Label"
    end

    -- Style (readable, obvious)
    pcall(function()
        label:setStyleSheet([[
            background-color: rgba(0,0,0,180);
            color: white;
            border: 1px solid #888888;
            padding-left: 8px;
            padding-top: 8px;
            font-size: 10pt;
        ]])
    end)

    _state.widgets.container = container
    _state.widgets.label = label

    if type(store) == "table" then
        store[M.UI_ID] = { container = container, label = label }
    end

    return true, nil
end

local function _setLabelText(txt)
    local label = _state.widgets.label
    if type(label) ~= "table" then return end
    if type(label.echo) == "function" then
        pcall(label.echo, label, tostring(txt or ""))
    end
end

function M.getModuleVersion() return M.VERSION end

function M.getUiId() return M.UI_ID end

function M.init(opts)
    opts = (type(opts) == "table") and opts or {}

    local gs = _getGuiSettingsBestEffort()
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
    _safeHide(_state.widgets.container)

    _state.inited = true
    _state.lastError = nil
    return true, nil
end

function M.apply(opts)
    opts = (type(opts) == "table") and opts or {}

    local gs = _getGuiSettingsBestEffort()
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
        _safeShow(_state.widgets.container)
    else
        _safeHide(_state.widgets.container)
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

    local store = _getUiStore()
    if type(store) == "table" then
        store[M.UI_ID] = nil
    end

    _safeDelete(_state.widgets.label)
    _safeDelete(_state.widgets.container)

    _state.widgets.label = nil
    _state.widgets.container = nil

    _state.inited = false
    _state.lastError = nil
    return true, nil
end

return M
