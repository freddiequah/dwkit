-- src/dwkit/ui/ui_manager_ui.lua
-- DWKit UI Manager UI (enable/disable + show/hide surface)
--
-- Purpose:
--   - List registered UI ids from gui_settings.
--   - Allow enable/disable AND show/hide from a UI window.
--   - When disabling: force visible=OFF best-effort (so disable always stands down cleanly).
--   - When show/hide: requires enabled=ON (button is disabled if UI is disabled).
--   - Calls ui_manager.applyOne(uiId) after changes to apply/stand-down immediately.
--
-- SAFE:
--   - No gameplay commands.
--   - No timers/automation.
--   - Writes only when user clicks Enable/Disable or Show/Hide.

local M = {}
M.VERSION = "v2026-02-05C"

local U = require("dwkit.ui.ui_base")
local Window = require("dwkit.ui.ui_window")
local Theme = require("dwkit.ui.ui_theme")
local ListKit = require("dwkit.ui.ui_list_kit")
local ButtonKit = require("dwkit.ui.ui_button_kit")

local G = rawget(_G, "Geyser")

local UI_ID = "ui_manager_ui"
local UI_LABEL = "UI Manager"

local _frame = nil
local _listRoot = nil
local _rows = {}

local _state = {
    inited = false,
    visible = false,
    enabled = nil,
    lastApplySource = nil,
    widgets = {
        hasFrame = false,
        rowCount = 0,
    },
    renderedUiIds = {},
    debug = {
        lastReason = nil,
        lastAction = nil,
    },
}

local function _sortedKeys(t)
    local keys = {}
    if type(t) ~= "table" then return keys end
    for k, _ in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    return keys
end

local function _disposeFrame()
    if _frame then
        pcall(function() _frame:hide() end)
        pcall(function() _frame:delete() end)
    end
    _frame = nil
    _listRoot = nil
    _rows = {}

    _state.inited = false
    _state.widgets.hasFrame = false
    _state.widgets.rowCount = 0
    _state.renderedUiIds = {}
end

local function _clearRows()
    for _, row in ipairs(_rows) do
        if row and row.container then
            pcall(function() row.container:delete() end)
        end
    end
    _rows = {}
    _state.widgets.rowCount = 0
    _state.renderedUiIds = {}
end

local function _ensureFrame()
    if _frame then return true end
    if type(G) ~= "table" then
        _state.debug.lastReason = "geyser_missing"
        return false
    end

    local ok, bundle = pcall(Window.create, {
        uiId = UI_ID,
        title = UI_LABEL,
        width = 460,
        height = 360,
        x = 20,
        y = 400,
        resizable = true,
    })
    if not ok or type(bundle) ~= "table" then
        _state.debug.lastReason = "window_create_failed"
        return false
    end

    local root = bundle.content or bundle.frame or bundle
    if not root then
        _state.debug.lastReason = "window_root_missing"
        return false
    end

    _frame = bundle.frame or bundle
    _state.inited = true
    _state.widgets.hasFrame = true

    pcall(function()
        if type(Theme.applyToFrame) == "function" then
            Theme.applyToFrame(_frame, { variant = "standard" })
        end
    end)

    local okList, listRoot = pcall(function()
        if type(ListKit.newListRoot) == "function" then
            return ListKit.newListRoot(root, {
                name = "DWKit_UIManager_ListRoot",
                x = 10,
                y = 10,
                width = -20,
                height = -20,
            })
        end
        return nil
    end)

    if okList and listRoot then
        _listRoot = listRoot
    else
        _listRoot = G.Container:new({
            name = "DWKit_UIManager_ListRoot_Fallback",
            x = 10,
            y = 10,
            width = -20,
            height = -20,
        }, root)
        pcall(function() ListKit.applyListRootStyle(_listRoot) end)
    end

    return true
end

local function _getAllUiRecords()
    local gs = U.getGuiSettingsBestEffort()
    if type(gs) ~= "table" or type(gs.list) ~= "function" then
        return {}
    end

    local ok, uiMap = pcall(gs.list)
    if not ok or type(uiMap) ~= "table" then
        return {}
    end

    local keys = _sortedKeys(uiMap)
    local outIds = {}

    for _, uiId in ipairs(keys) do
        uiId = tostring(uiId)
        if uiId ~= UI_ID then
            outIds[#outIds + 1] = uiId
        end
    end

    return outIds
end

local function _applyOneBestEffort(uiId, source)
    local okM, mgr = pcall(require, "dwkit.ui.ui_manager")
    if okM and type(mgr) == "table" and type(mgr.applyOne) == "function" then
        pcall(mgr.applyOne, uiId, { source = source or "ui_manager_ui", quiet = true })
    end
end

-- ===== Runtime visibility (truth) =========================================

local function _tryContainerVisibleBestEffort(c)
    if type(c) ~= "table" then return nil end
    local ok, v = pcall(function()
        if type(c.isVisible) == "function" then
            return c:isVisible()
        end
        if c.hidden ~= nil then
            return not c.hidden
        end
        return nil
    end)
    if ok then return v end
    return nil
end

local function _tryModuleStateVisibleBestEffort(uiId)
    uiId = tostring(uiId or "")
    if uiId == "" then return nil end

    local okMod, mod = pcall(require, "dwkit.ui." .. uiId)
    if not okMod or type(mod) ~= "table" then return nil end

    if type(mod.getState) == "function" then
        local okS, st = pcall(mod.getState, { quiet = true })
        if okS and type(st) == "table" then
            if st.visible ~= nil then return st.visible == true end
            if st.isVisible ~= nil then return st.isVisible == true end
            -- common nested shapes
            if type(st.widgets) == "table" then
                if st.widgets.visible ~= nil then return st.widgets.visible == true end
            end
            -- fallback: if module exposes container/frame in state
            local c = st.container or st.frame
            local cv = _tryContainerVisibleBestEffort(c)
            if cv ~= nil then return cv end
        end
    end

    return nil
end

local function _getRuntimeVisibleBestEffort(uiId)
    -- 1) module state (best-effort)
    local mv = _tryModuleStateVisibleBestEffort(uiId)
    if mv ~= nil then return mv end

    -- 2) ui_base store container/frame (best-effort)
    local e = (type(U.getUiStoreEntry) == "function") and U.getUiStoreEntry(uiId) or nil
    if type(e) == "table" then
        local c = e.container or e.frame
        local cv = _tryContainerVisibleBestEffort(c)
        if cv ~= nil then return cv end
    end

    return nil
end

-- ==========================================================================

function M.setUiEnabled(uiId, enabled, opts)
    opts = (type(opts) == "table") and opts or {}
    if type(uiId) ~= "string" or uiId == "" then
        return false, "uiId invalid"
    end

    local gs = U.getGuiSettingsBestEffort()
    if type(gs) ~= "table" then
        return false, "guiSettings not available"
    end

    if type(gs.enableVisiblePersistence) == "function" then
        pcall(gs.enableVisiblePersistence, { noSave = true })
    end

    if type(gs.setEnabled) ~= "function" then
        return false, "guiSettings.setEnabled missing"
    end

    local okE, errE = gs.setEnabled(uiId, enabled == true, (opts.noSave == true) and { noSave = true } or nil)
    if okE ~= true and errE ~= nil then
        return false, tostring(errE)
    end

    if enabled ~= true then
        if type(gs.setVisible) == "function" then
            pcall(gs.setVisible, uiId, false, (opts.noSave == true) and { noSave = true } or nil)
        end
    end

    _applyOneBestEffort(uiId, opts.source or "ui_manager_ui:setUiEnabled")
    return true, nil
end

function M.setUiVisible(uiId, visible, opts)
    opts = (type(opts) == "table") and opts or {}
    if type(uiId) ~= "string" or uiId == "" then
        return false, "uiId invalid"
    end

    local gs = U.getGuiSettingsBestEffort()
    if type(gs) ~= "table" then
        return false, "guiSettings not available"
    end

    if type(gs.enableVisiblePersistence) == "function" then
        pcall(gs.enableVisiblePersistence, { noSave = true })
    end

    if type(gs.isEnabled) == "function" then
        local okE, v = pcall(gs.isEnabled, uiId, false)
        if okE and v ~= true then
            return false, "ui is disabled (enable first)"
        end
    end

    if type(gs.setVisible) ~= "function" then
        return false, "guiSettings.setVisible missing"
    end

    local okV, errV = gs.setVisible(uiId, visible == true, (opts.noSave == true) and { noSave = true } or nil)
    if okV ~= true and errV ~= nil then
        return false, tostring(errV)
    end

    _applyOneBestEffort(uiId, opts.source or "ui_manager_ui:setUiVisible")
    return true, nil
end

local function _renderList(uiIds)
    if not _listRoot then return end
    _clearRows()

    local gs = U.getGuiSettingsBestEffort()
    if type(gs) ~= "table" then
        _state.debug.lastReason = "guiSettings_missing"
        return
    end

    local y = 0
    local rowH = 32

    for i = 1, #uiIds do
        local uiId = uiIds[i]

        local enabled = false
        local cfgVisible = false

        if type(gs.isEnabled) == "function" then
            local okE, v = pcall(gs.isEnabled, uiId, false)
            if okE then enabled = (v == true) end
        end
        if type(gs.getVisible) == "function" then
            local okV, v = pcall(gs.getVisible, uiId, false)
            if okV then cfgVisible = (v == true) end
        end

        -- Runtime truth (best-effort)
        local runtimeVisible = _getRuntimeVisibleBestEffort(uiId)

        -- What UI Manager shows is runtime-first; fallback to config
        local shownVisible = (runtimeVisible ~= nil) and runtimeVisible or cfgVisible

        local row = {
            uiId = uiId,
            enabled = enabled,
            visible = cfgVisible,
            runtimeVisible = runtimeVisible,
            shownVisible = shownVisible,
        }

        row.container = G.Container:new({
            name = "DWKit_UIManager_Row_" .. tostring(uiId),
            x = 0,
            y = y,
            width = "100%",
            height = rowH,
        }, _listRoot)

        pcall(function()
            if type(ListKit.applyRowStyle) == "function" then
                ListKit.applyRowStyle(row.container, { variant = ((i % 2) == 0) and "alt" or "base" })
            end
        end)

        row.label = G.Label:new({
            name = "DWKit_UIManager_Label_" .. tostring(uiId),
            x = 8,
            y = 6,
            width = "-250px",
            height = rowH - 10,
        }, row.container)

        local rtText = (runtimeVisible == nil) and "?" or (runtimeVisible and "ON" or "OFF")
        local text = string.format("%s  [en:%s cfg:%s rt:%s]", uiId, enabled and "ON" or "OFF", cfgVisible and "ON" or "OFF", rtText)
        pcall(function()
            if type(ListKit.applyRowTextStyle) == "function" then
                ListKit.applyRowTextStyle(row.label)
            end
            row.label:echo(text)
        end)

        local btnEnLabel = enabled and "Disable" or "Enable"
        row.btnEnable = G.Label:new({
            name = "DWKit_UIManager_BtnEnable_" .. tostring(uiId),
            x = "-220px",
            y = 4,
            width = "100px",
            height = rowH - 8,
        }, row.container)

        pcall(function()
            ButtonKit.applyButtonStyle(row.btnEnable, { enabled = true, minHeightPx = rowH - 8 })
            row.btnEnable:echo(btnEnLabel)
        end)

        -- IMPORTANT: label uses runtime-truth if known
        local btnVisLabel = row.shownVisible and "Hide" or "Show"
        row.btnVisible = G.Label:new({
            name = "DWKit_UIManager_BtnVisible_" .. tostring(uiId),
            x = "-110px",
            y = 4,
            width = "100px",
            height = rowH - 8,
        }, row.container)

        pcall(function()
            ButtonKit.applyButtonStyle(row.btnVisible, { enabled = (enabled == true), minHeightPx = rowH - 8 })
            row.btnVisible:echo(btnVisLabel)
        end)

        local function _onToggleEnabled()
            local newEnabled = not enabled
            _state.debug.lastAction = string.format("toggle-enabled %s -> %s", tostring(uiId), tostring(newEnabled))

            local okSet, errSet = M.setUiEnabled(uiId, newEnabled, { source = "ui_manager_ui:toggleEnabled" })
            if not okSet then
                if type(cecho) == "function" then
                    cecho("[DWKit UI] ui_manager_ui: enable toggle failed uiId=" .. tostring(uiId) .. " err=" .. tostring(errSet) .. "\n")
                else
                    print("[DWKit UI] ui_manager_ui: enable toggle failed uiId=" .. tostring(uiId) .. " err=" .. tostring(errSet))
                end
            end

            pcall(M.apply, { source = "ui_manager_ui:toggleEnabled" })
        end

        local function _onToggleVisible()
            if enabled ~= true then
                return
            end

            -- Toggle is still config-driven (intent), but label is runtime-truth
            local newVisible = not cfgVisible
            _state.debug.lastAction = string.format("toggle-visible %s -> %s", tostring(uiId), tostring(newVisible))

            local okSet, errSet = M.setUiVisible(uiId, newVisible, { source = "ui_manager_ui:toggleVisible" })
            if not okSet then
                if type(cecho) == "function" then
                    cecho("[DWKit UI] ui_manager_ui: visible toggle failed uiId=" .. tostring(uiId) .. " err=" .. tostring(errSet) .. "\n")
                else
                    print("[DWKit UI] ui_manager_ui: visible toggle failed uiId=" .. tostring(uiId) .. " err=" .. tostring(errSet))
                end
            end

            pcall(M.apply, { source = "ui_manager_ui:toggleVisible" })
        end

        if type(ButtonKit.wireClick) == "function" then
            pcall(function() ButtonKit.wireClick(row.btnEnable, _onToggleEnabled) end)
            pcall(function() ButtonKit.wireClick(row.btnVisible, _onToggleVisible) end)
        else
            if type(row.btnEnable.setClickCallback) == "function" then
                pcall(function() row.btnEnable:setClickCallback(_onToggleEnabled) end)
            end
            if type(row.btnVisible.setClickCallback) == "function" then
                pcall(function() row.btnVisible:setClickCallback(_onToggleVisible) end)
            end
        end

        _rows[#_rows + 1] = row
        y = y + rowH
    end
end

function M.apply(opts)
    opts = (type(opts) == "table") and opts or {}
    _state.lastApplySource = opts.source or "unknown"

    local gs = U.getGuiSettingsBestEffort()
    if type(gs) == "table" then
        if type(gs.isEnabled) == "function" then
            local okE, v = pcall(gs.isEnabled, UI_ID, true)
            if okE then _state.enabled = (v == true) end
        end
        if type(gs.getVisible) == "function" then
            local okV, v = pcall(gs.getVisible, UI_ID, false)
            if okV then _state.visible = (v == true) end
        end
    end

    if _state.enabled == false then
        _disposeFrame()
        _state.visible = false
        _state.debug.lastReason = "disabled"
        return true
    end

    local uiIds = _getAllUiRecords()
    _state.renderedUiIds = uiIds
    _state.widgets.rowCount = #uiIds

    if _state.visible ~= true then
        _clearRows()
        if _frame then pcall(function() _frame:hide() end) end
        _state.debug.lastReason = "visible_off"
        return true
    end

    local okFrame = _ensureFrame()
    if not okFrame then
        _state.debug.lastReason = "frame_create_failed"
        return false, "frame_create_failed"
    end

    pcall(function() _frame:show() end)
    _renderList(uiIds)

    _state.widgets.rowCount = #uiIds
    _state.renderedUiIds = uiIds
    _state.debug.lastReason = "render_ok"

    return true
end

function M.dispose(opts)
    opts = (type(opts) == "table") and opts or {}
    _disposeFrame()
    _state.visible = false
    _state.enabled = nil
    _state.lastApplySource = opts.source or _state.lastApplySource
    _state.debug.lastReason = "disposed"
    return true
end

function M.getState()
    return {
        uiId = UI_ID,
        version = M.VERSION,
        inited = _state.inited,
        enabled = _state.enabled,
        visible = _state.visible,
        lastApplySource = _state.lastApplySource,
        widgets = {
            hasFrame = _state.widgets.hasFrame,
            rowCount = _state.widgets.rowCount,
        },
        renderedUiIds = _state.renderedUiIds,
        debug = _state.debug,
    }
end

return M
