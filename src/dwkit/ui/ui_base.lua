-- #########################################################################
-- Module Name : dwkit.ui.ui_base
-- Owner       : UI
-- Version     : v2026-02-11E
-- Purpose     :
--   - Shared SAFE helper utilities for DWKit UI modules.
--   - Avoids copy/paste across UI modules (store, widgets, show/hide/delete, etc).
--   - Provides best-effort access to guiSettings and Geyser.
--   - Provides SAFE subscription helpers for service "Updated" events
--     (centralized pattern for auto-refresh UIs).
--
-- Public API  :
--   - getModuleVersion() -> string
--   - out(line)
--   - getGuiSettingsBestEffort() -> table|nil
--   - getGeyser() -> table|nil
--   - getUiStore() -> table|nil
--   - getUiStoreEntry(uiId) -> table|nil
--   - ensureUiStoreEntry(uiId) -> table|nil
--   - setUiRuntime(uiId, rt) -> boolean ok
--   - setUiStateVisibleBestEffort(uiId, visible) -> boolean ok
--   - safeHide(widget|uiId, uiId?, opts?) -> boolean ok
--   - safeShow(widget|uiId, uiId?, opts?) -> boolean ok
--   - safeDelete(widget)
--   - safeSetLabelText(label, text)
--   - ensureWidgets(uiId, requiredKeys, createFn) -> boolean ok, table|nil widgets, string|nil err
--   - clearUiStoreEntry(uiId)
--   - subscribeServiceUpdates(uiId, onUpdatedFn, handlerFn, opts?) -> boolean ok, table|nil sub, string|nil err
--   - unsubscribeServiceUpdates(sub) -> boolean ok
--
-- SAFE Constraints:
--   - No gameplay commands
--   - No timers
--   - No automation
--   - Best-effort event subscription/unsubscription ONLY (no emits here)
-- #########################################################################

local M = {}

M.VERSION = "v2026-02-11E"

local function _isNonEmptyString(s)
    return type(s) == "string" and s ~= ""
end

function M.getModuleVersion()
    return M.VERSION
end

function M.out(line)
    line = tostring(line or "")
    if type(cecho) == "function" then
        cecho(line .. "\n")
    elseif type(echo) == "function" then
        echo(line .. "\n")
    else
        print(line)
    end
end

function M.getGuiSettingsBestEffort()
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

function M.getGeyser()
    local G = _G.Geyser
    if type(G) == "table" then return G end
    return nil
end

-- Global UI store to prevent duplicate windows across module reloads
function M.getUiStore()
    if type(_G.DWKit) ~= "table" then return nil end
    if type(_G.DWKit._uiStore) ~= "table" then
        _G.DWKit._uiStore = {}
    end
    return _G.DWKit._uiStore
end

-- Stable accessor (may return nil if not created yet)
function M.getUiStoreEntry(uiId)
    if not _isNonEmptyString(uiId) then return nil end
    local store = M.getUiStore()
    if type(store) ~= "table" then return nil end
    local e = store[uiId]
    if type(e) == "table" then return e end
    return nil
end

-- Deterministic entry creator (never returns non-table)
function M.ensureUiStoreEntry(uiId)
    if not _isNonEmptyString(uiId) then return nil end
    local store = M.getUiStore()
    if type(store) ~= "table" then return nil end

    local e = store[uiId]
    if type(e) ~= "table" then
        -- If legacy code stored a non-table, preserve it in __legacy
        local legacy = e
        e = {}
        if legacy ~= nil then
            e.__legacy = legacy
        end
        store[uiId] = e
    end

    -- Ensure deterministic identity fields exist
    if e.uiId == nil then e.uiId = uiId end
    if e.createdAt == nil then
        e.createdAt = (type(_G.getEpoch) == "function" and _G.getEpoch()) or os.time()
    end
    e.updatedAt = (type(_G.getEpoch) == "function" and _G.getEpoch()) or os.time()

    -- Ensure deterministic state table exists (do not force defaults here)
    if type(e.state) ~= "table" then
        e.state = {}
    end

    return e
end

-- Store runtime handles deterministically (frame/container/content/nameFrame/etc)
-- rt = { frame=?, container=?, content=?, nameFrame=?, nameContent=?, meta=?, state=? }
function M.setUiRuntime(uiId, rt)
    if not _isNonEmptyString(uiId) then return false end
    if type(rt) ~= "table" then return false end

    local e = M.ensureUiStoreEntry(uiId)
    if type(e) ~= "table" then return false end

    -- Merge without destroying existing widget keys from ensureWidgets users
    if rt.frame ~= nil then e.frame = rt.frame end
    if rt.container ~= nil then e.container = rt.container end
    if rt.content ~= nil then e.content = rt.content end
    if _isNonEmptyString(rt.nameFrame) then e.nameFrame = rt.nameFrame end
    if _isNonEmptyString(rt.nameContent) then e.nameContent = rt.nameContent end
    if type(rt.meta) == "table" then e.meta = rt.meta end

    -- merge deterministic runtime state (e.state.*)
    if type(rt.state) == "table" then
        e.state = (type(e.state) == "table") and e.state or {}
        for k, v in pairs(rt.state) do
            e.state[k] = v
        end
    end

    e.runtimeUpdatedAt = (type(_G.getEpoch) == "function" and _G.getEpoch()) or os.time()
    return true
end

-- Deterministic boolean runtime signal used by UI Manager UI (rt:)
function M.setUiStateVisibleBestEffort(uiId, visible)
    if not _isNonEmptyString(uiId) then return false end
    local e = M.ensureUiStoreEntry(uiId)
    if type(e) ~= "table" then return false end
    e.state = (type(e.state) == "table") and e.state or {}
    e.state.visible = (visible == true)
    e.runtimeUpdatedAt = (type(_G.getEpoch) == "function" and _G.getEpoch()) or os.time()
    return true
end

function M.clearUiStoreEntry(uiId)
    if not _isNonEmptyString(uiId) then return end
    local store = M.getUiStore()
    if type(store) ~= "table" then return end
    store[uiId] = nil
end

-- Internal hide SHOULD NOT be treated as "user clicked X".
-- We suppress ui_window hide-hook sync during safeHide (dispose/reload/apply internals).
local function _setSuppressHideHookBestEffort(w, v)
    if type(w) ~= "table" then return end
    w._dwkitSuppressHideHook = (v == true)

    -- Adjustable often uses frame.window as the real widget; suppress both.
    if type(w.window) == "table" then
        w.window._dwkitSuppressHideHook = (v == true)
    end
end

-- Best-effort: resolve uiId for helpers that may receive (widget|uiId)
local function _resolveUiIdBestEffort(w, uiIdMaybe, opts)
    opts = (type(opts) == "table") and opts or {}

    if _isNonEmptyString(uiIdMaybe) then
        return uiIdMaybe
    end

    if _isNonEmptyString(w) then
        return w
    end

    if type(w) == "table" and _isNonEmptyString(w.uiId) then
        return w.uiId
    end

    if type(w) == "table" and _isNonEmptyString(w.name) then
        -- Not canonical, but can help in some cases.
        return w.name
    end

    if _isNonEmptyString(opts.uiId) then
        return opts.uiId
    end

    return nil
end

function M.getUiContainer(uiId)
    local e = M.getUiStoreEntry(uiId)
    if type(e) == "table" and type(e.container) == "table" then
        return e.container
    end
    return nil
end

function M.getUiFrame(uiId)
    local e = M.getUiStoreEntry(uiId)
    if type(e) == "table" and type(e.frame) == "table" then
        return e.frame
    end
    return nil
end

function M.getUiContent(uiId)
    local e = M.getUiStoreEntry(uiId)
    if type(e) == "table" and type(e.content) == "table" then
        return e.content
    end
    return nil
end

function M.safeHide(w, uiIdMaybe, opts)
    opts = (type(opts) == "table") and opts or {}

    -- Supports:
    --   safeHide(widget)
    --   safeHide(uiId)                (best-effort; resolves from store)
    --   safeHide(widget, uiId, opts)  (preferred; explicit)
    local uiId = _resolveUiIdBestEffort(w, uiIdMaybe, opts)

    local target = w
    if type(target) == "string" and target ~= "" then
        target = M.getUiContainer(target) or M.getUiFrame(target)
    end

    if type(target) ~= "table" then
        return true
    end

    -- Mark runtime state first so observers see intent even if widget hide fails.
    if _isNonEmptyString(uiId) then
        M.setUiStateVisibleBestEffort(uiId, false)
    end

    -- NOTE:
    -- Adjustable.Container often renders via target.window (the actual widget).
    -- Some builds have frame:hide that does not fully hide the underlying window,
    -- so we best-effort hide both target and target.window.
    local function _hideOne(obj)
        if type(obj) ~= "table" then return end
        if type(obj.hide) ~= "function" then return end
        _setSuppressHideHookBestEffort(obj, true)
        pcall(obj.hide, obj)
        _setSuppressHideHookBestEffort(obj, false)
    end

    _hideOne(target)
    if type(target.window) == "table" and target.window ~= target then
        _hideOne(target.window)
    end

    return true
end

function M.safeShow(w, uiIdMaybe, opts)
    opts = (type(opts) == "table") and opts or {}

    -- Supports:
    --   safeShow(widget)
    --   safeShow(uiId)                (best-effort; resolves from store)
    --   safeShow(widget, uiId, opts)  (preferred; explicit)
    local uiId = _resolveUiIdBestEffort(w, uiIdMaybe, opts)

    local target = w
    if type(target) == "string" and target ~= "" then
        target = M.getUiContainer(target) or M.getUiFrame(target)
    end

    if type(target) ~= "table" then
        return true
    end

    if _isNonEmptyString(uiId) then
        M.setUiStateVisibleBestEffort(uiId, true)
    end

    local function _showOne(obj)
        if type(obj) ~= "table" then return end
        if type(obj.show) ~= "function" then return end
        pcall(obj.show, obj)
    end

    _showOne(target)
    if type(target.window) == "table" and target.window ~= target then
        _showOne(target.window)
    end

    return true
end

function M.safeDelete(w)
    if type(w) ~= "table" then return end

    -- Best-effort delete; if unavailable, hide only.
    local function _delOne(obj)
        if type(obj) ~= "table" then return false end
        if type(obj.delete) == "function" then
            return pcall(obj.delete, obj)
        end
        return false
    end

    local ok = _delOne(w)

    -- Adjustable wrappers sometimes keep the real widget at .window
    if type(w.window) == "table" and w.window ~= w then
        _delOne(w.window)
    end

    if not ok then
        M.safeHide(w)
    end
end

function M.safeSetLabelText(label, txt)
    if type(label) ~= "table" then return end
    if type(label.echo) == "function" then
        pcall(label.echo, label, tostring(txt or ""))
    end
end

local function _hasRequiredKeys(t, requiredKeys)
    if type(t) ~= "table" then return false end
    if type(requiredKeys) ~= "table" or #requiredKeys == 0 then
        return true
    end
    for _, k in ipairs(requiredKeys) do
        if t[k] == nil then
            return false
        end
    end
    return true
end

local function _stampIdentityFieldsBestEffort(e, uiId)
    if type(e) ~= "table" then return end
    e.uiId = e.uiId or uiId
    if e.createdAt == nil then
        e.createdAt = (type(_G.getEpoch) == "function" and _G.getEpoch()) or os.time()
    end
    e.updatedAt = (type(_G.getEpoch) == "function" and _G.getEpoch()) or os.time()
    if type(e.state) ~= "table" then
        e.state = {}
    end
end

local function _mergeIntoEntryBestEffort(entry, widgets)
    if type(entry) ~= "table" or type(widgets) ~= "table" then
        return false
    end

    -- Merge: do not wipe existing keys (runtime identity, etc).
    for k, v in pairs(widgets) do
        entry[k] = v
    end

    return true
end

-- ensureWidgets
-- - Reuses widgets from global store if present and valid
-- - Otherwise creates new via createFn()
-- Returns: ok, widgets, err
--
-- NOTE:
--   store[uiId] remains a TABLE to preserve compatibility.
--   We allow additional runtime/meta keys (frame/container/nameFrame/etc) on the same table.
--
-- IMPORTANT:
--   We MERGE newly created widgets into an existing store entry (if any)
--   instead of replacing store[uiId] with a new table. This prevents loss of
--   runtime identity fields set by ui_window (nameFrame/meta/closeLabel/etc).
function M.ensureWidgets(uiId, requiredKeys, createFn)
    if not _isNonEmptyString(uiId) then
        return false, nil, "uiId invalid"
    end
    if type(createFn) ~= "function" then
        return false, nil, "createFn invalid"
    end

    local store = M.getUiStore()

    -- If an entry exists and already has required keys, reuse it.
    if type(store) == "table" and type(store[uiId]) == "table" then
        local cached = store[uiId]
        if _hasRequiredKeys(cached, requiredKeys) then
            _stampIdentityFieldsBestEffort(cached, uiId)
            return true, cached, nil
        end
    end

    local okCreate, widgetsOrErr = pcall(createFn)
    if not okCreate or type(widgetsOrErr) ~= "table" then
        -- Still ensure deterministic store entry exists for debugging
        M.ensureUiStoreEntry(uiId)
        return false, nil, "createFn failed"
    end

    if not _hasRequiredKeys(widgetsOrErr, requiredKeys) then
        M.ensureUiStoreEntry(uiId)
        return false, nil, "createFn returned incomplete widgets"
    end

    -- Ensure we have a stable entry table, then merge created widgets into it.
    local entry = M.ensureUiStoreEntry(uiId)
    if type(entry) ~= "table" then
        return false, nil, "store entry missing"
    end

    _mergeIntoEntryBestEffort(entry, widgetsOrErr)
    _stampIdentityFieldsBestEffort(entry, uiId)

    -- Ensure store points to the stable entry (defensive)
    if type(store) == "table" then
        store[uiId] = entry
    end

    return true, entry, nil
end

-- =========================================================================
-- Service Updated Event Subscription Helpers (SAFE)
-- =========================================================================

local function _bestEffortBusOff(handlerId)
    if handlerId == nil then return true end

    local okBus, BUS = pcall(require, "dwkit.bus.event_bus")
    if not okBus or type(BUS) ~= "table" then
        return false
    end

    -- Try common unsubscribe/off patterns (best-effort, no hard dependency)
    local candidates = { "off", "unsubscribe", "unsub", "remove", "removeHandler", "removeListener" }
    for _, fnName in ipairs(candidates) do
        if type(BUS[fnName]) == "function" then
            local ok = pcall(BUS[fnName], handlerId)
            if ok then return true end
        end
    end

    return false
end

function M.subscribeServiceUpdates(uiId, onUpdatedFn, handlerFn, opts)
    opts = (type(opts) == "table") and opts or {}

    if not _isNonEmptyString(uiId) then
        return false, nil, "uiId invalid"
    end
    if type(onUpdatedFn) ~= "function" then
        return false, nil, "onUpdatedFn invalid"
    end
    if type(handlerFn) ~= "function" then
        return false, nil, "handlerFn invalid"
    end

    local sub = {
        uiId = uiId,
        handlerId = nil,
        updatedEventName = (_isNonEmptyString(opts.eventName) and opts.eventName) or nil,
        debugPrefix = (_isNonEmptyString(opts.debugPrefix) and opts.debugPrefix) or "DWKit",
    }

    local function _wrapped(payload)
        pcall(handlerFn, payload, sub)
    end

    local pOk, ret1, ret2, ret3 = pcall(onUpdatedFn, _wrapped)
    if not pOk then
        return false, nil, "onUpdatedFn pcall failed"
    end

    if ret1 == false then
        return false, nil, tostring(ret2 or "subscribe failed")
    end

    local token = nil
    if type(ret1) ~= "boolean" then
        token = ret1
    else
        token = ret2
        if token == nil and ret3 ~= nil then
            token = ret3
        end
    end

    sub.handlerId = token
    return true, sub, nil
end

function M.unsubscribeServiceUpdates(sub)
    if type(sub) ~= "table" then
        return true
    end
    local handlerId = sub.handlerId
    if handlerId == nil then
        return true
    end
    _bestEffortBusOff(handlerId)
    return true
end

return M
