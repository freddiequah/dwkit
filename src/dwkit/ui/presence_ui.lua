-- #########################################################################
-- Module Name : dwkit.ui.presence_ui
-- Owner       : UI
-- Version     : v2026-02-07A
-- Purpose     :
--   - SAFE Presence UI scaffold with live render from PresenceService (data only).
--   - Creates a small window frame via ui_window + content panel + label.
--   - Demonstrates gui_settings self-seeding (register) + apply()/dispose() lifecycle.
--   - Subscribes to PresenceService "updated" event to auto-refresh when state changes.
--   - No timers, no send(), no automation.
--
-- Key Fixes:
--   v2026-02-07A:
--     1) Deterministic runtime visibility: never clear ui_base store entry on dispose.
--        Instead, set storeEntry.state.visible to boolean and clear widget handles safely.
--        This prevents UI Manager UI runtime visibility (rt:) from becoming nil.
--     2) Safe UI Manager refresh: use ui_manager_ui.refresh() (rows-only) instead of apply().
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

M.VERSION = "v2026-02-07A"
M.UI_ID = "presence_ui"

local U = require("dwkit.ui.ui_base")
local W = require("dwkit.ui.ui_window")
local ListKit = require("dwkit.ui.ui_list_kit")

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

    subscription = nil,

    widgets = {
        container = nil,
        label = nil,
        content = nil,
        panel = nil,
    },
}

local function _out(line, opts)
    opts = (type(opts) == "table") and opts or {}
    if opts.quiet == true then
        return
    end
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
        -- fallback: store via setUiRuntime state merge
        pcall(U.setUiRuntime, M.UI_ID, { state = { visible = (visible == true) } })
    end
end

-- Deep best-effort patching for gui_settings implementations that store ui records
-- in internal tables which setVisible() does not touch (or signature mismatch).
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

-- Robustly set gui_settings.visible=false WITHOUT assuming the setVisible signature.
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

local function _ensureWidgets()
    local ok, widgets, err = U.ensureWidgets(M.UI_ID, { "container", "label", "content", "panel" }, function()
        local G = U.getGeyser()
        if not G then
            return nil
        end

        local bundle = W.create({
            uiId = M.UI_ID,
            title = "Presence",
            x = 30,
            y = 220,
            width = 300,
            height = 260,
            padding = 6,
            onClose = function(b)
                -- ui_window X already does: cfg visible OFF (session) + refresh ui_manager_ui (rows-only)
                -- Keep compatibility net but ensure we do NOT call ui_manager_ui.apply() here.
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

        local panel = G.Container:new({
            name = "__DWKit_presence_ui_panel",
            x = 0,
            y = 0,
            width = "100%",
            height = "100%",
        }, contentParent)

        ListKit.applyPanelStyle(panel)

        local label = G.Label:new({
            name = "__DWKit_presence_ui_label",
            x = 0,
            y = 0,
            width = "100%",
            height = "100%",
        }, panel)

        ListKit.applyTextLabelStyle(label)

        return {
            uiId = M.UI_ID,

            -- runtime identity (from ui_window)
            frame = container,
            container = container,
            content = contentParent,
            meta = meta,
            nameFrame = (type(meta) == "table" and meta.nameFrame) or nil,
            nameContent = (type(meta) == "table" and meta.nameContent) or nil,
            closeLabel = bundle.closeLabel,

            -- widgets
            panel = panel,
            label = label,
        }
    end)

    if not ok or type(widgets) ~= "table" then
        return false, err or "Failed to create widgets"
    end

    _state.widgets.container = widgets.container
    _state.widgets.content = widgets.content
    _state.widgets.panel = widgets.panel
    _state.widgets.label = widgets.label

    -- deterministic runtime signal: created implies visible true only when shown; initialize as false (hidden by default)
    _markRuntimeVisible(false)

    return true, nil
end

local function _setLabelText(txt)
    local label = _state.widgets.label

    if type(label) == "table" and type(label.setText) == "function" then
        pcall(function()
            label:setText(ListKit.toPreHtml(txt))
        end)
        return
    end

    U.safeSetLabelText(label, txt)
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

    _setLabelText(_formatPresenceState(state))
    return true, nil
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
        if _state.enabled == true and _state.visible == true and type(_state.widgets.label) == "table" then
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
            hasLabel = (type(_state.widgets.label) == "table"),
        },
    }
end

function M.dispose(opts)
    opts = (type(opts) == "table") and opts or {}

    -- stop subscriptions first
    U.unsubscribeServiceUpdates(_state.subscription)
    _state.subscription = nil

    -- deterministic runtime signal for UI Manager UI (rt:)
    _markRuntimeVisible(false)

    -- IMPORTANT:
    -- Do NOT clear the ui_base store entry here.
    -- UI Manager depends on storeEntry.state.visible being deterministic (never nil).
    local entry = nil
    if type(U.ensureUiStoreEntry) == "function" then
        entry = U.ensureUiStoreEntry(M.UI_ID)
    end
    if type(entry) == "table" then
        entry.state = (type(entry.state) == "table") and entry.state or {}
        entry.state.visible = false
        -- clear runtime handles (but keep the entry)
        entry.frame = nil
        entry.container = nil
        entry.content = nil
        entry.panel = nil
        entry.label = nil
        entry.closeLabel = nil
    end

    -- delete widgets best-effort
    U.safeDelete(_state.widgets.label)
    U.safeDelete(_state.widgets.panel)
    U.safeDelete(_state.widgets.container)

    _state.widgets.label = nil
    _state.widgets.container = nil
    _state.widgets.content = nil
    _state.widgets.panel = nil

    _state.inited = false
    _state.lastError = nil
    return true, nil
end

return M
