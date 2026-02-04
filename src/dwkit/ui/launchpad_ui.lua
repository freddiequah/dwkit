-- src/dwkit/ui/launchpad_ui.lua
-- DWKit LaunchPad (UI control surface)
--
-- Purpose:
--   - List enabled UIs and provide quick visible toggle (show/hide).
--   - Must only appear if at least 1 other UI is enabled.
--
-- Semantics:
--   - LaunchPad is a *temporary* show/hide surface by default (noSave=true).
--   - Persistent visibility changes should be done via dwgui visible <uiId> on|off.

local M = {}
M.VERSION = "v2026-02-04F"

local U = require("dwkit.ui.ui_base")
local Window = require("dwkit.ui.ui_window")
local Theme = require("dwkit.ui.ui_theme")
local ListKit = require("dwkit.ui.ui_list_kit")
local ButtonKit = require("dwkit.ui.ui_button_kit")

local G = rawget(_G, "Geyser")

local UI_ID = "launchpad_ui"
local UI_LABEL = "LaunchPad"

-- Internal / non-user surfaces to hide from LaunchPad
local HIDDEN_UI_IDS = {
    [UI_ID] = true,           -- never list self
    ["ui_manager_ui"] = true, -- manager surface should not appear on LaunchPad
}

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
        lastEnabledUiIds = {},
        lastReason = nil,
    },
}

local function _safePrint(msg)
    if type(msg) ~= "string" then msg = tostring(msg) end
    if type(cecho) == "function" then
        cecho(msg .. "\n")
    elseif type(echo) == "function" then
        echo(msg .. "\n")
    else
        print(msg)
    end
end

local function _sortedKeys(t)
    local keys = {}
    if type(t) ~= "table" then return keys end
    for k, _ in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    return keys
end

local function _copyArray(arr)
    if type(arr) ~= "table" then return {} end
    local out = {}
    for i = 1, #arr do out[i] = arr[i] end
    return out
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

local function _forceSelfHiddenNoSave(gs)
    if type(gs) ~= "table" or type(gs.setVisible) ~= "function" then return end
    pcall(gs.enableVisiblePersistence, { noSave = true })
    pcall(gs.setVisible, UI_ID, false, { noSave = true })
end

local function _filterEligible(uiIds)
    if type(uiIds) ~= "table" then return {} end
    local out = {}
    for i = 1, #uiIds do
        local uiId = uiIds[i]
        if type(uiId) == "string" and uiId ~= "" and HIDDEN_UI_IDS[uiId] ~= true then
            out[#out + 1] = uiId
        end
    end
    table.sort(out)
    return out
end

-- Authoritative source: gui_settings.list() -> { uiId -> {enabled=bool, visible=bool} }
local function _getEnabledUiIdsFromSettings()
    local gs = U.getGuiSettingsBestEffort()
    if type(gs) ~= "table" or type(gs.list) ~= "function" then
        return {}
    end

    local ok, uiMap = pcall(gs.list)
    if not ok or type(uiMap) ~= "table" then
        return {}
    end

    local out = {}
    local keys = _sortedKeys(uiMap)
    for _, uiId in ipairs(keys) do
        uiId = tostring(uiId)
        if HIDDEN_UI_IDS[uiId] ~= true then
            local rec = uiMap[uiId]
            if type(rec) == "table" and rec.enabled == true then
                out[#out + 1] = uiId
            end
        end
    end

    table.sort(out)
    return out
end

-- Fallback: ui_manager.listEnabled may return:
--  - strings: "presence_ui"
--  - records: {uiId="presence_ui"} or {id="presence_ui"}
local function _getEnabledUiIdsFallback()
    local okM, mgr = pcall(require, "dwkit.ui.ui_manager")
    if not okM or type(mgr) ~= "table" then
        return {}
    end

    if type(mgr.listEnabled) ~= "function" then
        return {}
    end

    local enabled = nil
    local ok, v = pcall(mgr.listEnabled, { records = true })
    if ok then enabled = v end
    if type(enabled) ~= "table" then
        local ok2, v2 = pcall(mgr.listEnabled)
        if ok2 then enabled = v2 end
    end

    if type(enabled) ~= "table" then
        return {}
    end

    local out = {}
    for i = 1, #enabled do
        local item = enabled[i]
        local uiId = nil
        if type(item) == "string" then
            uiId = item
        elseif type(item) == "table" then
            uiId = item.uiId or item.id
        end
        uiId = (type(uiId) == "string") and uiId or nil
        if uiId and HIDDEN_UI_IDS[uiId] ~= true then
            out[#out + 1] = uiId
        end
    end

    table.sort(out)
    return out
end

local function _getEnabledUiIds()
    local ids = _getEnabledUiIdsFromSettings()
    if #ids > 0 then
        return ids, "settings"
    end
    local fb = _getEnabledUiIdsFallback()
    if #fb > 0 then
        return fb, "fallback"
    end
    return {}, "none"
end

local function _ensureFrame()
    if _frame then return true end
    if type(G) ~= "table" then
        _safePrint("[DWKit] launchpad_ui: Geyser not available")
        return false
    end

    local ok, bundle = pcall(Window.create, {
        uiId = UI_ID,
        title = UI_LABEL,
        width = 330,
        height = 300,
        x = 20,
        y = 80,
        resizable = true,
    })
    if not ok or type(bundle) ~= "table" then
        return false
    end

    local root = bundle.content or bundle.frame or bundle
    if not root then
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
                name = "DWKit_LaunchPad_ListRoot",
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
            name = "DWKit_LaunchPad_ListRoot_Fallback",
            x = 10,
            y = 10,
            width = -20,
            height = -20,
        }, root)
    end

    return true
end

local function _renderList(uiIds)
    if not _listRoot then return end
    _clearRows()

    local gs = U.getGuiSettingsBestEffort()
    if type(gs) ~= "table" then
        return
    end

    local y = 0
    local rowH = 30

    for i = 1, #uiIds do
        local uiId = uiIds[i]

        local enabled = false
        local visible = false

        if type(gs.isEnabled) == "function" then
            local okE, v = pcall(gs.isEnabled, uiId, false)
            if okE then enabled = (v == true) end
        end
        if type(gs.getVisible) == "function" then
            local okV, v = pcall(gs.getVisible, uiId, false)
            if okV then visible = (v == true) end
        end

        local row = { uiId = uiId, enabled = enabled, visible = visible }

        row.container = G.Container:new({
            name = "DWKit_LaunchPad_Row_" .. tostring(uiId),
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
            name = "DWKit_LaunchPad_Label_" .. tostring(uiId),
            x = 8,
            y = 6,
            width = "-90px",
            height = rowH - 10,
        }, row.container)

        pcall(function() row.label:echo(uiId) end)

        local btnLabel = visible and "Hide" or "Show"
        row.button = G.Label:new({
            name = "DWKit_LaunchPad_Btn_" .. tostring(uiId),
            x = "-80px",
            y = 4,
            width = "72px",
            height = rowH - 8,
        }, row.container)

        pcall(function()
            if type(ButtonKit.applyButtonStyle) == "function" then
                ButtonKit.applyButtonStyle(row.button, { enabled = true, minHeightPx = rowH - 8 })
            end
            row.button:echo(btnLabel)
        end)

        local function _onToggle()
            local gs2 = U.getGuiSettingsBestEffort()
            if type(gs2) ~= "table" then return end

            if type(gs2.enableVisiblePersistence) == "function" then
                pcall(gs2.enableVisiblePersistence, { noSave = true })
            end

            local curVis = false
            if type(gs2.getVisible) == "function" then
                local okV, v = pcall(gs2.getVisible, uiId, false)
                if okV then curVis = (v == true) end
            end
            local newVis = (curVis ~= true)

            if type(gs2.setVisible) == "function" then
                pcall(gs2.setVisible, uiId, newVis, { noSave = true })
            end

            local okM, mgr = pcall(require, "dwkit.ui.ui_manager")
            if okM and type(mgr) == "table" and type(mgr.applyOne) == "function" then
                pcall(mgr.applyOne, uiId, { source = "launchpad_ui:toggle", quiet = true })
            end

            pcall(M.apply, { source = "launchpad_ui:toggle" })
        end

        if type(ButtonKit.wireClick) == "function" then
            pcall(function() ButtonKit.wireClick(row.button, _onToggle) end)
        elseif type(row.button.setClickCallback) == "function" then
            pcall(function() row.button:setClickCallback(_onToggle) end)
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

    local enabledUiIdsRaw, src = _getEnabledUiIds()
    local enabledUiIds = _filterEligible(enabledUiIdsRaw)

    _state.debug.lastEnabledUiIds = _copyArray(enabledUiIds)
    _state.debug.lastReason = "enabledSource=" .. tostring(src)

    _state.renderedUiIds = _copyArray(enabledUiIds)
    _state.widgets.rowCount = #enabledUiIds

    -- Governance: only appear if at least 1 other eligible UI enabled.
    if #enabledUiIds == 0 then
        _forceSelfHiddenNoSave(gs)
        _state.visible = false
        _clearRows()
        if _frame then pcall(function() _frame:hide() end) end
        return true
    end

    -- If visible OFF: keep hidden, but state already reflects enabled list for tests/diagnostics.
    if _state.visible ~= true then
        _clearRows()
        if _frame then pcall(function() _frame:hide() end) end
        return true
    end

    local okFrame = _ensureFrame()
    if not okFrame then
        _state.debug.lastReason = "frame_create_failed"
        return false, "frame_create_failed"
    end

    pcall(function() _frame:show() end)
    _renderList(enabledUiIds)

    _state.widgets.rowCount = #enabledUiIds
    _state.renderedUiIds = _copyArray(enabledUiIds)

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
        renderedUiIds = _copyArray(_state.renderedUiIds),
        debug = {
            lastEnabledUiIds = _copyArray(_state.debug.lastEnabledUiIds),
            lastReason = _state.debug.lastReason,
        },
    }
end

return M
