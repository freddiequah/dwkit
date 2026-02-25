-- FILE: src/dwkit/ui/presence_ui.lua
-- #########################################################################
-- BEGIN FILE: src/dwkit/ui/presence_ui.lua
-- #########################################################################
-- Module Name : dwkit.ui.presence_ui
-- Owner       : UI
-- Version     : v2026-02-25D
-- Purpose     :
--   - SAFE Presence UI (consumer-only) rendered from PresenceService (data only).
--   - Renders "My profiles" vs "Other players" split from PresenceService state.
--   - Row-based UI, aligned with RoomEntities UI style and DWKit standard look.
--   - Uses shared ui_window frame + panel + listRoot rows.
--   - Subscribes to PresenceService "updated" event to auto-refresh while visible.
--   - No timers, no send(), no automation.
--
-- Key Changes:
--   v2026-02-25B:
--     - REFACTOR(UI): remove MiniConsole multiline approach.
--       Presence UI is now row-based to match DWKit UI standard and eliminate grey slab issues.
--
--   v2026-02-25C:
--     - STANDARDIZE: render via shared ui_row_scaffold so future UIs start from the same
--       row-based scaffold and we never fight widget-internal paint behavior again.
--
--   v2026-02-25D:
--     - UI: hide metaLine ("Status: OK Reason: none") when not stale.
--       Meta line is shown only when stale=true.
-- #########################################################################

local M = {}

M.VERSION = "v2026-02-25D"
M.UI_ID = "presence_ui"

local U = require("dwkit.ui.ui_base")
local W = require("dwkit.ui.ui_window")
local ListKit = require("dwkit.ui.ui_list_kit")
local RowScaffold = require("dwkit.ui.ui_row_scaffold")

local function _safeRequire(modName)
    local ok, mod = pcall(require, modName)
    if ok then return true, mod end
    return false, mod
end

local function _sortedCopy(arr)
    arr = (type(arr) == "table") and arr or {}
    local out = {}
    for i = 1, #arr do
        out[#out + 1] = tostring(arr[i] or "")
    end
    table.sort(out, function(a, b) return tostring(a):lower() < tostring(b):lower() end)
    return out
end

local _state = {
    inited = false,
    lastApply = nil,
    lastError = nil,
    enabled = nil,
    visible = nil,

    subscription = nil,

    lastRender = {
        myCount = 0,
        otherCount = 0,
        rowCount = 0,
        stale = false,
        staleReason = nil,
        metaShown = false,
        overflow = false,
        overflowMore = 0,
        lastError = nil,
    },

    widgets = {
        container = nil,
        content = nil,
        panel = nil,
        listRoot = nil,
        rendered = {}, -- dynamic rows/headers we must delete on refresh
    },
}

local function _isQuiet(opts)
    return type(opts) == "table" and opts.quiet == true
end

local function _out(line, opts)
    if _isQuiet(opts) then return end
    U.out(line)
end

local function _applyViaUiManagerBestEffort(source)
    local okM, mgr = pcall(require, "dwkit.ui.ui_manager")
    if okM and type(mgr) == "table" and type(mgr.applyOne) == "function" then
        pcall(function()
            mgr.applyOne(M.UI_ID, { source = source or "presence_ui:onClose", quiet = true })
        end)
    end
end

local function _refreshUiManagerUiRowsBestEffort(source)
    local okU, uiMgrUi = pcall(require, "dwkit.ui.ui_manager_ui")
    if okU and type(uiMgrUi) == "table" and type(uiMgrUi.refresh) == "function" then
        pcall(function()
            uiMgrUi.refresh({ source = source or "presence_ui:onClose", quiet = true })
        end)
    end
end

local function _markRuntimeVisible(visible)
    _state.visible = (visible == true)
    if type(U.setUiStateVisibleBestEffort) == "function" then
        pcall(U.setUiStateVisibleBestEffort, M.UI_ID, (visible == true))
    else
        pcall(U.setUiRuntime, M.UI_ID, { state = { visible = (visible == true) } })
    end
end

local function _forceVisibleFalseDeep(gs)
    if type(gs) ~= "table" then return false end
    local uiId = M.UI_ID
    local changed = false

    local function patchRecord(rec)
        if type(rec) ~= "table" then return end
        if rec.visible ~= nil and rec.visible ~= false then
            rec.visible = false
            changed = true
        elseif rec.visible == nil then
            rec.visible = false
            changed = true
        end
    end

    local function scanTable(t, depth, visited)
        if type(t) ~= "table" then return end
        visited = visited or {}
        if visited[t] then return end
        visited[t] = true
        depth = depth or 0
        if depth > 4 then return end

        if type(t[uiId]) == "table" then
            patchRecord(t[uiId])
        end

        for _, v in pairs(t) do
            if type(v) == "table" then
                if type(v[uiId]) == "table" then
                    patchRecord(v[uiId])
                end
                scanTable(v, depth + 1, visited)
            end
        end
    end

    scanTable(gs, 0, nil)
    return changed
end

local function _setVisibleOffSessionBestEffort()
    local okGS, gs = pcall(require, "dwkit.config.gui_settings")
    if not okGS or type(gs) ~= "table" then
        _markRuntimeVisible(false)
        return
    end

    if type(gs.enableVisiblePersistence) == "function" then
        pcall(gs.enableVisiblePersistence, { noSave = true })
        pcall(gs.enableVisiblePersistence, true)
        pcall(gs.enableVisiblePersistence, { save = false })
    end

    local okSet = false

    if type(gs.setVisible) == "function" then
        if pcall(gs.setVisible, M.UI_ID, false, { noSave = true }) then okSet = true end
        if (not okSet) and pcall(gs.setVisible, M.UI_ID, false, { save = false }) then okSet = true end
        if (not okSet) and pcall(gs.setVisible, M.UI_ID, false, false) then okSet = true end
        if (not okSet) and pcall(gs.setVisible, M.UI_ID, false) then okSet = true end
    end

    if (not okSet) and type(gs.set) == "function" then
        if pcall(gs.set, M.UI_ID, "visible", false, { noSave = true }) then okSet = true end
        if (not okSet) and pcall(gs.set, M.UI_ID, "visible", false, { save = false }) then okSet = true end
        if (not okSet) and pcall(gs.set, M.UI_ID, "visible", false, false) then okSet = true end
        if (not okSet) and pcall(gs.set, M.UI_ID, "visible", false) then okSet = true end
    end

    if (not okSet) and type(gs.register) == "function" then
        pcall(gs.register, M.UI_ID, { visible = false }, { save = false })
        pcall(gs.register, M.UI_ID, { visible = false }, { noSave = true })
    end

    if type(gs.getVisible) == "function" then
        local okV, v = pcall(gs.getVisible, M.UI_ID, nil)
        if okV and v == true then
            _forceVisibleFalseDeep(gs)
        end
    else
        _forceVisibleFalseDeep(gs)
    end

    _markRuntimeVisible(false)
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

local function _renderRows(state)
    state = (type(state) == "table") and state or {}

    local root = _state.widgets.listRoot
    if type(root) ~= "table" then
        return false, "listRoot not available"
    end

    local my = _sortedCopy(state.myProfilesInRoom)
    local other = _sortedCopy(state.otherPlayersInRoom)

    local stale = (state.stale == true)
    local staleReason = tostring(state.staleReason or "")
    if staleReason == "" then staleReason = "none" end

    -- v2026-02-25D: meta line is only shown when stale
    local metaShown = (stale == true)
    local metaLine = nil
    if metaShown then
        local status = "STALE"
        metaLine = string.format("Status: %s   Reason: %s", status, staleReason)
    end

    local metaH = metaShown and 26 or 0

    local okR, result, errR = RowScaffold.render({
        root = root,
        rendered = _state.widgets.rendered,
        ListKit = ListKit,
        U = U,
        metaLine = metaLine,
        sections = {
            { title = "My profiles",   items = my,    emptySuffix = "(empty)", itemPrefix = "  - " },
            { title = "Other players", items = other, emptySuffix = "(empty)", itemPrefix = "  - " },
        },
        layout = {
            topPad = 3,
            bottomPad = 2,
            gap = 3,
            headerH = 30,
            rowH = 26,
            metaH = metaH,
        },
        overflowRowTextFn = function(moreN)
            return string.format("... (more rows not shown: +%d)", tonumber(moreN) or 0)
        end,
    })

    if not okR then
        _state.lastRender.lastError = tostring(errR or "render failed")
        return false, errR
    end

    result = (type(result) == "table") and result or {}

    _state.lastRender.myCount = #my
    _state.lastRender.otherCount = #other
    _state.lastRender.rowCount = tonumber(result.rowCount) or 0
    _state.lastRender.stale = (stale == true)
    _state.lastRender.staleReason = staleReason
    _state.lastRender.metaShown = (metaShown == true)
    _state.lastRender.overflow = (result.overflow == true)
    _state.lastRender.overflowMore = tonumber(result.overflowMore) or 0
    _state.lastRender.lastError = nil

    return true, nil
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

    return _renderRows(state)
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

    local handlerFn = function(_payload)
        if _state.enabled == true and _state.visible == true and type(_state.widgets.listRoot) == "table" then
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

local function _tryCreateListRoot(panel, tag)
    local name = "__DWKit_presence_ui_listRoot_" .. tostring(tag or "default")

    local okRoot, root, err = RowScaffold.createListRoot(panel, name)
    if not okRoot or type(root) ~= "table" then
        return false, nil, err or "Failed to create listRoot"
    end

    if type(ListKit.applyListRootStyle) == "function" then
        pcall(function() ListKit.applyListRootStyle(root) end)
    end

    return true, root, nil
end

local function _ensureWidgets()
    local ok, widgets, err = U.ensureWidgets(M.UI_ID, { "container", "content", "panel", "listRoot" }, function()
        local G = U.getGeyser()
        if not G then
            return nil
        end

        local bundle = W.create({
            uiId = M.UI_ID,
            title = "Presence",
            x = 30,
            y = 220,
            width = 320,
            height = 300,
            padding = 6,
            onClose = function(b)
                _setVisibleOffSessionBestEffort()
                _applyViaUiManagerBestEffort("presence_ui:onClose")
                _refreshUiManagerUiRowsBestEffort("presence_ui:onClose")

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
        local meta = bundle.meta or {}

        local tag = tostring((type(meta) == "table" and meta.profileTag) or "")
        if tag == "" then tag = "default" end

        local panelName = "__DWKit_presence_ui_panel_" .. tag

        local panel = G.Container:new({
            name = panelName,
            x = 0,
            y = 0,
            width = "100%",
            height = "100%",
        }, contentParent)

        ListKit.applyPanelStyle(panel)

        local okRoot, listRoot = _tryCreateListRoot(panel, tag)
        if not okRoot then
            return nil
        end

        return {
            container = container,
            content = contentParent,
            panel = panel,
            listRoot = listRoot,
        }
    end)

    if not ok or type(widgets) ~= "table" then
        return false, err or "Failed to create widgets"
    end

    _state.widgets.container = widgets.container
    _state.widgets.content = widgets.content
    _state.widgets.panel = widgets.panel
    _state.widgets.listRoot = widgets.listRoot

    _markRuntimeVisible(false)

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
    _markRuntimeVisible(false)

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
        local okInit, errInit = M.init(opts)
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
        _markRuntimeVisible(true)
    else
        U.safeHide(_state.widgets.container)
        _markRuntimeVisible(false)
    end

    _out(string.format("[DWKit UI] apply uiId=%s enabled=%s visible=%s action=%s",
        tostring(M.UI_ID),
        tostring(enabled),
        tostring(visible),
        tostring(action)
    ), opts)

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
            hasPanel = (type(_state.widgets.panel) == "table"),
            hasListRoot = (type(_state.widgets.listRoot) == "table"),
        },
        lastRender = {
            myCount = _state.lastRender.myCount,
            otherCount = _state.lastRender.otherCount,
            rowCount = _state.lastRender.rowCount,
            stale = _state.lastRender.stale,
            staleReason = _state.lastRender.staleReason,
            metaShown = _state.lastRender.metaShown,
            overflow = _state.lastRender.overflow,
            overflowMore = _state.lastRender.overflowMore,
            lastError = _state.lastRender.lastError,
        },
    }
end

function M.dispose(opts)
    opts = (type(opts) == "table") and opts or {}

    U.unsubscribeServiceUpdates(_state.subscription)
    _state.subscription = nil

    _markRuntimeVisible(false)

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
        entry.listRoot = nil
        entry.closeLabel = nil
    end

    RowScaffold.clearRendered(_state.widgets.rendered, U)

    U.safeDelete(_state.widgets.listRoot)
    U.safeDelete(_state.widgets.panel)
    U.safeDelete(_state.widgets.container)

    _state.widgets.listRoot = nil
    _state.widgets.panel = nil
    _state.widgets.container = nil
    _state.widgets.content = nil
    _state.widgets.rendered = {}

    _state.inited = false
    _state.lastError = nil
    _state.lastRender.lastError = nil
    return true, nil
end

return M
-- #########################################################################
-- END FILE: src/dwkit/ui/presence_ui.lua
-- #########################################################################
