-- src/dwkit/ui/launchpad_ui.lua
-- #########################################################################
-- Module Name : dwkit.ui.launchpad_ui
-- Owner       : UI
-- Version     : v2026-02-10A
-- Purpose     :
--   - Fixed, non-window LaunchPad button strip for temporary show/hide only.
--   - Lists ONLY enabled UIs (excluding internal/admin surfaces).
--   - Appears ONLY when at least 1 other eligible UI is enabled.
--   - Respects its own gui_settings.visible:
--       * If launchpad_ui visible=OFF, it must not appear (no container created).
--   - No title bar, no close button, not draggable, not resizable.
--
-- Public API  :
--   - apply(opts?)  -> bool
--   - dispose(opts?) -> bool
--   - getState() -> table
--
-- Events Emitted   : None
-- Events Consumed  : None
-- Persistence      : None
-- Automation Policy: Manual only
-- Dependencies     : dwkit.ui.ui_base, dwkit.ui.ui_theme, dwkit.ui.ui_button_kit
-- #########################################################################

local M = {}
M.VERSION = "v2026-02-10A"

local U = require("dwkit.ui.ui_base")
local Theme = require("dwkit.ui.ui_theme")
local ButtonKit = require("dwkit.ui.ui_button_kit")

local G = rawget(_G, "Geyser")

local UI_ID = "launchpad_ui"

-- Internal / non-user surfaces to hide from LaunchPad
local HIDDEN_UI_IDS = {
    [UI_ID] = true,           -- never list self
    ["ui_manager_ui"] = true, -- manager surface should not appear on LaunchPad
}

-- Fixed positioning (match old button strip feel)
local POS = {
    x = "-56px",
    y = "48%",
    w = "48px",
    pad = 6,
    gap = 6,
    btnH = 30,
}

local _panel = nil
local _buttons = {}

local _state = {
    inited = false,
    visible = false,
    enabled = nil,
    selfVisible = nil, -- launchpad_ui visible flag from gui_settings
    lastApplySource = nil,
    widgets = {
        hasPanel = false,
        rowCount = 0,
    },
    renderedUiIds = {},
    debug = {
        lastEnabledUiIds = {},
        lastReason = nil,
    },
}

local function _copyArray(arr)
    if type(arr) ~= "table" then return {} end
    local out = {}
    for i = 1, #arr do out[i] = arr[i] end
    return out
end

local function _sortedKeys(t)
    local keys = {}
    if type(t) ~= "table" then return keys end
    for k, _ in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    return keys
end

local function _shortLabel(uiId)
    if type(uiId) ~= "string" or uiId == "" then return "?" end

    -- small, explicit mapping for common UIs (keeps strip legible)
    if uiId == "chat_ui" then return "CH" end
    if uiId == "presence_ui" then return "PR" end
    if uiId == "roomentities_ui" then return "RO" end

    local seg = uiId:match("^([^_]+)") or uiId
    seg = tostring(seg)
    if #seg >= 2 then
        return string.upper(seg:sub(1, 2))
    end
    return string.upper(seg:sub(1, 1))
end

local function _rtVisible(uiId)
    local e = U.getUiStoreEntry(uiId)
    if type(e) ~= "table" or type(e.state) ~= "table" then
        return false
    end
    return (e.state.visible == true)
end

local function _clearButtons()
    for _, b in ipairs(_buttons) do
        if b and type(b.label) == "table" then
            pcall(function() U.safeDelete(b.label) end)
        end
    end
    _buttons = {}
end

-- Best-effort: delete any runtime widgets stored under DWKit._uiStore[launchpad_ui]
-- This is required to prevent orphan panels across module reloads (local handles reset).
-- IMPORTANT: Do NOT clear the ui_store entry (keep deterministic rt state pattern).
local function _deleteOrphanFromStore()
    local e = U.getUiStoreEntry(UI_ID)
    if type(e) ~= "table" then
        return
    end

    local function _deleteWindowList(w)
        if type(w) ~= "table" then return end
        if type(w.windowList) ~= "table" then return end
        for _, child in pairs(w.windowList) do
            if type(child) == "table" then
                pcall(function() U.safeDelete(child) end)
            end
        end
    end

    if type(e.frame) == "table" then
        _deleteWindowList(e.frame)
    end
    if type(e.container) == "table" and e.container ~= e.frame then
        _deleteWindowList(e.container)
    end

    if type(e.frame) == "table" then
        pcall(function() U.safeDelete(e.frame) end)
    end
    if type(e.container) == "table" and e.container ~= e.frame then
        pcall(function() U.safeDelete(e.container) end)
    end
end

local function _disposePanel()
    _clearButtons()

    -- Always try to remove any previously stored runtime widgets (reload-orphan guard)
    _deleteOrphanFromStore()

    -- Also delete local panel handle if present (normal lifecycle)
    if _panel and type(_panel) == "table" then
        pcall(function() U.safeHide(_panel, UI_ID) end)
        pcall(function() U.safeDelete(_panel) end)
    end

    _panel = nil

    _state.inited = false
    _state.visible = false
    _state.widgets.hasPanel = false
    _state.widgets.rowCount = 0
    _state.renderedUiIds = {}

    -- Deterministic runtime-visible signal (canonical)
    pcall(U.setUiRuntime, UI_ID, { container = nil, frame = nil, state = { visible = false } })
    pcall(U.setUiStateVisibleBestEffort, UI_ID, false)
end

local function _ensurePanel(btnCount)
    if _panel then return true end
    if type(G) ~= "table" then
        return false
    end

    btnCount = tonumber(btnCount or 0) or 0
    if btnCount < 1 then
        return false
    end

    local totalH = POS.pad + (btnCount * POS.btnH) + ((btnCount - 1) * POS.gap) + POS.pad

    _panel = G.Container:new({
        name = "DWKit_LaunchPad_Panel",
        x = POS.x,
        y = POS.y,
        width = POS.w,
        height = tostring(totalH) .. "px",
    })

    if type(_panel) ~= "table" then
        _panel = nil
        return false
    end

    pcall(function()
        if type(_panel.setStyleSheet) == "function" then
            _panel:setStyleSheet(Theme.bodyStyle())
        end
    end)

    _state.inited = true
    _state.visible = true
    _state.widgets.hasPanel = true

    -- Deterministic runtime record
    pcall(U.setUiRuntime, UI_ID, { container = _panel, frame = _panel, state = { visible = true } })
    pcall(U.setUiStateVisibleBestEffort, UI_ID, true)

    return true
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

local function _refreshUiManagerUiRows()
    local ok, Mgr = pcall(require, "dwkit.ui.ui_manager_ui")
    if ok and type(Mgr) == "table" and type(Mgr.refresh) == "function" then
        pcall(Mgr.refresh, { source = "launchpad_ui:toggle", quiet = true })
    end
end

-- IMPORTANT FIX:
-- Prefer ButtonKit styling when available; Theme.buttonStyle via setStyleSheet can repaint unreliably.
local function _applyButtonVisual(label, isOn)
    if type(label) ~= "table" then return end

    if type(ButtonKit) == "table" and type(ButtonKit.applyButtonStyle) == "function" then
        pcall(ButtonKit.applyButtonStyle, label, { enabled = (isOn == true), minHeightPx = POS.btnH })
        return
    end

    if type(label.setStyleSheet) == "function" and type(Theme) == "table" and type(Theme.buttonStyle) == "function" then
        pcall(label.setStyleSheet, label, Theme.buttonStyle(isOn == true))
    end
end

local function _applyOneBestEffort(uiId, source)
    local okM, mgr = pcall(require, "dwkit.ui.ui_manager")
    if okM and type(mgr) == "table" and type(mgr.applyOne) == "function" then
        pcall(mgr.applyOne, uiId, { source = source or "launchpad_ui", quiet = true })
    end
end

local function _syncVisibleSessionBestEffort(uiId, newVis, source)
    local okM, mgr = pcall(require, "dwkit.ui.ui_manager")
    if okM and type(mgr) == "table" and type(mgr.syncVisibleSession) == "function" then
        pcall(mgr.syncVisibleSession, uiId, (newVis == true),
            { source = source or "launchpad_ui:syncVisible", quiet = true })
        return true
    end
    return false
end

local function _toggleChatUi(newVis)
    local okUI, UI = pcall(require, "dwkit.ui.chat_ui")
    if not okUI or type(UI) ~= "table" then
        return false, "chat_ui module missing"
    end

    if newVis == true then
        if type(UI.show) == "function" then
            pcall(UI.show, { source = "launchpad_ui", fixed = false, noClose = false })
        elseif type(UI.toggle) == "function" then
            pcall(UI.toggle, { source = "launchpad_ui" })
        end
    else
        if type(UI.hide) == "function" then
            pcall(UI.hide, { source = "launchpad_ui" })
        elseif type(UI.toggle) == "function" then
            pcall(UI.toggle, { source = "launchpad_ui" })
        end
    end

    -- Best-effort deterministic runtime-visible sync (since chat_ui is not dispatcher-applied)
    pcall(U.setUiStateVisibleBestEffort, "chat_ui", (newVis == true))
    pcall(U.setUiRuntime, "chat_ui",
        { state = { visible = (newVis == true) }, meta = { source = "launchpad_ui:chat_direct" } })

    return true, nil
end

local function _renderButtons(uiIds)
    if not _panel then return end
    _clearButtons()

    local y = POS.pad

    for i = 1, #uiIds do
        local uiId = uiIds[i]
        local uiIdLocal = uiId -- closure safety
        local isOn = _rtVisible(uiIdLocal)

        local label = G.Label:new({
            name = "DWKit_LaunchPad_Btn_" .. tostring(uiIdLocal),
            x = POS.pad,
            y = tostring(y) .. "px",
            width = "-" .. tostring(POS.pad * 2) .. "px",
            height = tostring(POS.btnH) .. "px",
        }, _panel)

        if type(label) == "table" then
            pcall(function() label:echo(_shortLabel(uiIdLocal)) end)

            -- Apply visual style (reliable path)
            _applyButtonVisual(label, isOn)

            local function _onClick()
                local gs = U.getGuiSettingsBestEffort()
                if type(gs) ~= "table" then return end

                if type(gs.enableVisiblePersistence) == "function" then
                    pcall(gs.enableVisiblePersistence, { noSave = true })
                end

                local curVis = false
                if type(gs.getVisible) == "function" then
                    local okV, v = pcall(gs.getVisible, uiIdLocal, false)
                    if okV then curVis = (v == true) end
                elseif type(gs.isVisible) == "function" then
                    local okV, v = pcall(gs.isVisible, uiIdLocal, false)
                    if okV then curVis = (v == true) end
                end

                local newVis = (curVis ~= true)

                if type(gs.setVisible) == "function" then
                    pcall(gs.setVisible, uiIdLocal, newVis, { noSave = true })
                end

                -- IMPORTANT: chat_ui does not implement apply(), so dispatcher applyOne won't show/hide it.
                if uiIdLocal == "chat_ui" then
                    _syncVisibleSessionBestEffort(uiIdLocal, newVis, "launchpad_ui:chat_direct")
                    _toggleChatUi(newVis)
                else
                    -- Apply target UI so rt.visible updates deterministically (normal path)
                    _applyOneBestEffort(uiIdLocal, "launchpad_ui:toggle")
                end

                -- Refresh UI Manager rows if open
                _refreshUiManagerUiRows()

                -- Preferred: refresh LaunchPad via ui_manager.applyOne(launchpad_ui),
                -- NOT by calling M.apply directly (keeps a single control surface and avoids recursion patterns).
                _applyOneBestEffort(UI_ID, "launchpad_ui:toggle_refresh_self")
            end

            if type(ButtonKit) == "table" and type(ButtonKit.wireClick) == "function" then
                pcall(function() ButtonKit.wireClick(label, _onClick) end)
            elseif type(label.setClickCallback) == "function" then
                pcall(function() label:setClickCallback(_onClick) end)
            end

            _buttons[#_buttons + 1] = { uiId = uiIdLocal, label = label }
        end

        y = y + POS.btnH + POS.gap
    end
end

function M.apply(opts)
    opts = (type(opts) == "table") and opts or {}
    _state.lastApplySource = opts.source or "unknown"

    local gs = U.getGuiSettingsBestEffort()

    -- Read enabled + visible for LaunchPad itself
    if type(gs) == "table" then
        if type(gs.isEnabled) == "function" then
            local okE, vE = pcall(gs.isEnabled, UI_ID, true)
            if okE then _state.enabled = (vE == true) end
        end
        if type(gs.isVisible) == "function" then
            local okV, vV = pcall(gs.isVisible, UI_ID, true)
            if okV then _state.selfVisible = (vV == true) end
        elseif type(gs.getVisible) == "function" then
            local okV, vV = pcall(gs.getVisible, UI_ID, true)
            if okV then _state.selfVisible = (vV == true) end
        end
    end

    -- If disabled OR self visible is OFF -> must not exist
    if _state.enabled == false then
        _disposePanel()
        _state.debug.lastReason = "disabled"
        return true
    end
    if _state.selfVisible == false then
        _disposePanel()
        _state.debug.lastReason = "selfVisibleOff"
        return true
    end

    local enabledUiIds = _getEnabledUiIdsFromSettings()

    _state.debug.lastEnabledUiIds = _copyArray(enabledUiIds)
    _state.debug.lastReason = "enabledSource=settings"

    _state.renderedUiIds = _copyArray(enabledUiIds)
    _state.widgets.rowCount = #enabledUiIds

    -- Governance: only appear if at least 1 other eligible UI enabled.
    if #enabledUiIds == 0 then
        _disposePanel()
        _state.visible = false
        _state.debug.lastReason = "noEligibleEnabledUi"
        return true
    end

    local okP = _ensurePanel(#enabledUiIds)
    if not okP then
        _state.debug.lastReason = "panel_create_failed"
        _state.visible = false
        return false, "panel_create_failed"
    end

    pcall(function() U.safeShow(_panel, UI_ID) end)
    _state.visible = true

    _renderButtons(enabledUiIds)

    _state.widgets.rowCount = #enabledUiIds
    _state.renderedUiIds = _copyArray(enabledUiIds)

    pcall(U.setUiStateVisibleBestEffort, UI_ID, true)

    return true
end

function M.dispose(opts)
    opts = (type(opts) == "table") and opts or {}
    _disposePanel()
    _state.enabled = nil
    _state.selfVisible = nil
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
        selfVisible = _state.selfVisible,
        lastApplySource = _state.lastApplySource,
        widgets = {
            hasPanel = _state.widgets.hasPanel,
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
