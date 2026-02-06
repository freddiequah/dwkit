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
--
-- Key Fixes:
--   v2026-02-06E:
--     - Added refresh(): redraw rows without enforcing gui_settings.visible(ui_manager_ui).
--       This prevents "refresh" calls from closing the UI Manager window.
--   v2026-02-06F:
--     - FIX: Always use dwkit.config.gui_settings module instance for list/get/set.
--   v2026-02-06G:
--     - FIX: Self-heal if gs.list() returns empty at render time (bootstrap from ui_manager runtime registry).
--   v2026-02-06H:
--     - FIX: Treat "list has ONLY ui_manager_ui" as effectively empty, then bootstrap.
--     - Add debug capture of raw gs.list keys and filtered ids to explain rowCount=0 cases.
--   v2026-02-06I:
--     - FIX: _clearRows() was resetting state (rowCount/renderedUiIds) during redraw, making getState() report 0 rows.
--       Now: redraw-clear keeps state; rowCount is set after rendering.
--     - HARDEN: do not call GS.load() on every access if already loaded (prevents accidental registry wipe on redraw).

local M = {}
M.VERSION = "v2026-02-06I"

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
        lastBootstrap = nil,

        -- deep diagnostics
        lastGsListCount = nil,
        lastGsListKeys = nil,  -- comma string
        lastFilteredCount = nil,
        lastFilteredIds = nil, -- comma string
    },
}

local function _getGuiSettingsModuleBestEffort()
    local ok, GS = pcall(require, "dwkit.config.gui_settings")
    if ok and type(GS) == "table" then
        -- Important: avoid calling load() repeatedly during redraw.
        local loaded = nil
        if type(GS.isLoaded) == "function" then
            local okL, v = pcall(GS.isLoaded)
            if okL then loaded = (v == true) end
        end

        if loaded ~= true and type(GS.load) == "function" then
            pcall(GS.load)
        end

        return GS
    end
    return nil
end

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

local function _clearRows(opts)
    opts = (type(opts) == "table") and opts or {}
    local keepState = (opts.keepState == true)

    for _, row in ipairs(_rows) do
        if row and row.container then
            pcall(function() row.container:delete() end)
        end
    end
    _rows = {}

    if not keepState then
        _state.widgets.rowCount = 0
        _state.renderedUiIds = {}
    end
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

-- -----------------------------------------------------------------------------
-- Self-heal bootstrap from ui_manager runtime registry.
-- "Effectively empty" means:
--   - gs.list() truly empty, OR
--   - gs.list() contains ONLY ui_manager_ui.
-- -----------------------------------------------------------------------------
local function _bootstrapUiRecordsBestEffort(gs, listKeys)
    if type(gs) ~= "table" or type(gs.list) ~= "function" then
        return false, "gs_invalid"
    end

    listKeys = (type(listKeys) == "table") and listKeys or {}

    local onlySelf = (#listKeys == 1 and tostring(listKeys[1]) == UI_ID) or false
    local isEmpty = (#listKeys == 0) or false
    if not isEmpty and not onlySelf then
        _state.debug.lastBootstrap = "skip_nonempty"
        return false, "skip_nonempty"
    end

    local okMgr, mgr = pcall(require, "dwkit.ui.ui_manager")
    if not okMgr or type(mgr) ~= "table" then
        _state.debug.lastBootstrap = "mgr_missing"
        return false, "mgr_missing"
    end

    local st = nil
    if type(mgr.getState) == "function" then
        local okS, v = pcall(mgr.getState, { quiet = true })
        if okS and type(v) == "table" then st = v end
    end

    local uis = (type(st) == "table") and st.uis or nil
    if type(uis) ~= "table" then
        _state.debug.lastBootstrap = "mgr_uis_missing"
        return false, "mgr_uis_missing"
    end

    if type(gs.register) ~= "function" then
        _state.debug.lastBootstrap = "gs_register_missing"
        return false, "gs_register_missing"
    end

    local seeded = 0
    for uiId, _ in pairs(uis) do
        uiId = tostring(uiId or "")
        if uiId ~= "" and uiId ~= UI_ID then
            local okR = pcall(gs.register, uiId, { enabled = false }, { save = false })
            if okR then seeded = seeded + 1 end
        end
    end

    -- Ensure UI Manager itself exists too (in case other code expects it)
    pcall(gs.register, UI_ID, { enabled = true }, { save = false })

    _state.debug.lastBootstrap = "seeded_" .. tostring(seeded) .. (onlySelf and "_from_onlySelf" or "_from_empty")
    return true, _state.debug.lastBootstrap
end

local function _captureListDebug(keys, filtered)
    local function _join(t)
        if type(t) ~= "table" or #t == 0 then return "" end
        return table.concat(t, ",")
    end
    _state.debug.lastGsListCount = (type(keys) == "table") and #keys or 0
    _state.debug.lastGsListKeys = _join(keys)
    _state.debug.lastFilteredCount = (type(filtered) == "table") and #filtered or 0
    _state.debug.lastFilteredIds = _join(filtered)
end

local function _getAllUiRecords()
    local gs = _getGuiSettingsModuleBestEffort()
    if type(gs) ~= "table" or type(gs.list) ~= "function" then
        _captureListDebug({}, {})
        return {}
    end

    -- 1) Read raw list
    local ok, uiMap = pcall(gs.list)
    if not ok or type(uiMap) ~= "table" then
        _captureListDebug({}, {})
        return {}
    end

    local keys = _sortedKeys(uiMap)

    -- 2) Bootstrap if empty or only-self
    pcall(_bootstrapUiRecordsBestEffort, gs, keys)

    -- 3) Re-read after bootstrap attempt
    local ok2, uiMap2 = pcall(gs.list)
    if not ok2 or type(uiMap2) ~= "table" then
        _captureListDebug(keys, {})
        return {}
    end

    local keys2 = _sortedKeys(uiMap2)
    local outIds = {}

    for _, uiId in ipairs(keys2) do
        uiId = tostring(uiId)
        if uiId ~= UI_ID then
            outIds[#outIds + 1] = uiId
        end
    end

    _captureListDebug(keys2, outIds)
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

local function _tryStoreVisibleBestEffort(uiId)
    if type(U.getUiStoreEntry) ~= "function" then return nil end
    local okE, e = pcall(U.getUiStoreEntry, uiId)
    if not okE or type(e) ~= "table" then return nil end
    local c = e.container or e.frame
    local cv = _tryContainerVisibleBestEffort(c)
    if cv ~= nil then return cv end
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
            if type(st.widgets) == "table" and st.widgets.visible ~= nil then
                return st.widgets.visible == true
            end
            local c = st.container or st.frame
            local cv = _tryContainerVisibleBestEffort(c)
            if cv ~= nil then return cv end
        end
    end

    return nil
end

local function _getRuntimeVisibleBestEffort(uiId)
    local sv = _tryStoreVisibleBestEffort(uiId)
    if sv ~= nil then return sv end

    local mv = _tryModuleStateVisibleBestEffort(uiId)
    if mv ~= nil then return mv end

    return nil
end

-- ==========================================================================

function M.setUiEnabled(uiId, enabled, opts)
    opts = (type(opts) == "table") and opts or {}
    if type(uiId) ~= "string" or uiId == "" then
        return false, "uiId invalid"
    end

    local gs = _getGuiSettingsModuleBestEffort()
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

    local gs = _getGuiSettingsModuleBestEffort()
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

    -- Redraw clear should NOT reset renderedUiIds/rowCount mid-flight.
    _clearRows({ keepState = true })

    local gs = _getGuiSettingsModuleBestEffort()
    if type(gs) ~= "table" then
        _state.debug.lastReason = "guiSettings_missing"
        _state.widgets.rowCount = 0
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

        local runtimeVisible = _getRuntimeVisibleBestEffort(uiId)
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
        local text = string.format("%s  [en:%s cfg:%s rt:%s]", uiId, enabled and "ON" or "OFF",
            cfgVisible and "ON" or "OFF", rtText)
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
                    cecho("[DWKit UI] ui_manager_ui: enable toggle failed uiId=" ..
                        tostring(uiId) .. " err=" .. tostring(errSet) .. "\n")
                else
                    print("[DWKit UI] ui_manager_ui: enable toggle failed uiId=" ..
                        tostring(uiId) .. " err=" .. tostring(errSet))
                end
            end

            pcall(M.apply, { source = "ui_manager_ui:toggleEnabled" })
        end

        local function _onToggleVisible()
            if enabled ~= true then
                return
            end

            local newVisible = not cfgVisible
            _state.debug.lastAction = string.format("toggle-visible %s -> %s", tostring(uiId), tostring(newVisible))

            local okSet, errSet = M.setUiVisible(uiId, newVisible, { source = "ui_manager_ui:toggleVisible" })
            if not okSet then
                if type(cecho) == "function" then
                    cecho("[DWKit UI] ui_manager_ui: visible toggle failed uiId=" ..
                        tostring(uiId) .. " err=" .. tostring(errSet) .. "\n")
                else
                    print("[DWKit UI] ui_manager_ui: visible toggle failed uiId=" ..
                        tostring(uiId) .. " err=" .. tostring(errSet))
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

    -- After render: reflect truth for dwtest FINAL gate.
    _state.widgets.rowCount = #uiIds
end

function M.refresh(opts)
    opts = (type(opts) == "table") and opts or {}
    _state.lastApplySource = opts.source or _state.lastApplySource

    if not _frame or _state.inited ~= true then
        _state.debug.lastReason = "refresh_not_open"
        return false, "not_open"
    end

    local uiIds = _getAllUiRecords()
    _state.renderedUiIds = uiIds

    pcall(function() _frame:show() end)
    _renderList(uiIds)

    _state.debug.lastReason = "refresh_ok"
    return true
end

function M.apply(opts)
    opts = (type(opts) == "table") and opts or {}
    _state.lastApplySource = opts.source or "unknown"

    local gs = _getGuiSettingsModuleBestEffort()
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

    if _state.visible ~= true then
        _clearRows({ keepState = false })
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
