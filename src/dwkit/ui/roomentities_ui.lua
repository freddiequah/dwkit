-- FILE: src/dwkit/ui/roomentities_ui.lua
-- #########################################################################
-- Module Name : dwkit.ui.roomentities_ui
-- Owner       : UI
-- Version     : v2026-02-11A
-- Purpose     :
--   - SAFE RoomEntities UI (consumer-only) that renders a per-entity ROW LIST with
--     sections: Players / Mobs / Items-Objects / Unknown.
--   - Supports per-entity manual override via DIRECT buttons:
--       MOB / ITEM / IGN (Unknown)
--       * Clicking a button sets that override.
--       * Clicking the same button again clears back to AUTO (no override).
--   - Uses WhoStore as an authority signal (auto-mode boost) WITH CONFIDENCE GATE:
--       * Case-insensitive WhoStore lookup is allowed as a candidate signal only.
--       * Auto "player" boost requires exact display-name match (name == entry.name).
--       * If not exact, prefer Unknown unless explicit override forces a type.
--   - Creates a shared-frame window (ui_window + ui_theme) + list-style content.
--   - Subscribes to RoomEntitiesService Updated (and WhoStore Updated best-effort)
--     to re-render while visible.
--   - No timers, no send(), no hidden automation.
--   - IMPORTANT: caches the last rendered data state so override clicks re-render
--     the same dataset (prevents clearing when RoomEntitiesService state is empty).
--
--   - FIX (v2026-02-10A):
--       * Replace single-cycle override button with 3 direct buttons: MOB / ITEM / IGN.
--       * Explicitly set button texts (prevents "Look" / wrong defaults).
--       * Wire click callbacks to each button label explicitly.
--
--   - NEW (v2026-02-10B):
--       * Persist per-entity overrides using RoomEntitiesOverrideStore (best-effort).
--
--   - FIX (v2026-02-10C):
--       * Align UI persistence to real RoomEntitiesOverrideStore API:
--           - getAll() returns { [key] = { type="mob|item|ignore", ts=... } }
--           - set(key,typeStr) / clear(key)
--       * IGN uses store type "ignore" (not "unknown").
--       * Overrides are keyed by a normalized entity key: lower(trim(name)).
--
--   - FIX (v2026-02-10D):
--       * Persistence load timing: DO NOT "load once" when dataset is empty.
--
--   - FIX (v2026-02-10E):
--       * Overrides are per-profile memory (cross-room), NOT per-snapshot.
--         Prior code pruned overrides whenever an entity wasn't in current snapshot keys,
--         which causes "reset to unknown" during startup/partial updates.
--       * Now:
--           - Load ALL overrides from store (no filtering by current snapshot keys).
--           - NEVER prune overrides based on current snapshot.
--           - If store isn't ready at first try, keep overridesLoaded=false so we retry later.
--
--   - FIX (v2026-02-10G):
--       * Revert persistence diagnostics to SAFE mode:
--           - Wrap OS.set/OS.clear in pcall so click callbacks can never hard-error
--             (hard errors can break/disable subsequent label clicks in Mudlet UI).
--           - Still captures (ok, err) return values when the call succeeds.
--
--   - FIX (v2026-02-11A):
--       * Button click reliability: STOP using Geyser.HBox for rows (HBox can ignore x/width
--         and stack children unexpectedly, causing overlapping labels and "unclickable" buttons).
--         Always render each row as a plain Container with explicit x/width regions.
--       * Dispose correctness: dispose() must not clear/remove ui_store entry (align rtvis2
--         deterministic visible state approach). Instead set module visible/enabled false and
--         best-effort mark store state visible=false if helper exists.
-- #########################################################################

local M = {}

M.VERSION = "v2026-02-11A"
M.UI_ID = "roomentities_ui"
M.id = M.UI_ID -- convenience alias (some tooling/debug expects ui.id)

-- Enabled-mode dependencies (Model A). Provider lifecycle is managed externally (ui_manager).
M.REQUIRED_PROVIDERS = { "roomfeed_watch" }

function M.getRequiredProviders()
    return M.REQUIRED_PROVIDERS
end

local U = require("dwkit.ui.ui_base")
local W = require("dwkit.ui.ui_window")
local ListKit = require("dwkit.ui.ui_list_kit")

local function _safeRequire(modName)
    local ok, mod = pcall(require, modName)
    if ok then return true, mod end
    return false, mod
end

local function _isQuiet(opts)
    return type(opts) == "table" and opts.quiet == true
end

local function _out(line, opts)
    if _isQuiet(opts) then return end
    U.out(line)
end

local function _err(msg)
    U.out("[DWKit UI] ERROR: " .. tostring(msg))
end

local function _escapeHtml(s)
    s = tostring(s or "")
    s = s:gsub("&", "&amp;")
    s = s:gsub("<", "&lt;")
    s = s:gsub(">", "&gt;")
    s = s:gsub("\"", "&quot;")
    return s
end

local function _toPreHtml(multilineText)
    local safe = _escapeHtml(multilineText)
    return "<pre style='margin:0; white-space:pre-wrap;'>" .. safe .. "</pre>"
end

local function _formatFallbackText(state, effectiveLists, overrideCount)
    state = (type(state) == "table") and state or {}
    effectiveLists = (type(effectiveLists) == "table") and effectiveLists or {}

    local function fmtSection(label, list, maxNames)
        maxNames = tonumber(maxNames) or 6
        if maxNames < 0 then maxNames = 0 end

        local total = (type(list) == "table") and #list or 0
        local shown = {}
        if maxNames > 0 and total > 0 then
            for i = 1, total do
                if #shown >= maxNames then break end
                shown[#shown + 1] = list[i]
            end
        end

        local suffix = ""
        if #shown > 0 then
            suffix = " [" .. table.concat(shown, ", ") .. "]"
            if total > #shown then
                suffix = suffix .. " (+" .. tostring(total - #shown) .. ")"
            end
        end

        return tostring(label) .. "=" .. tostring(total) .. suffix
    end

    local lines = {}
    lines[#lines + 1] = "DWKit roomentities_ui (row list)"
    lines[#lines + 1] = "overrides=" .. tostring(overrideCount or 0)
    lines[#lines + 1] = fmtSection("Players", effectiveLists.players, 8)
    lines[#lines + 1] = fmtSection("Mobs", effectiveLists.mobs, 8)
    lines[#lines + 1] = fmtSection("Items", effectiveLists.items, 8)
    lines[#lines + 1] = fmtSection("Unknown", effectiveLists.unknown, 8)

    return table.concat(lines, "\n")
end

local function _trim(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function _keyForName(name)
    name = _trim(tostring(name or ""))
    if name == "" then return "" end
    return tostring(name):lower()
end

local function _getRoomEntitiesStateBestEffort()
    local okS, S = _safeRequire("dwkit.services.roomentities_service")
    if not okS or type(S) ~= "table" then
        return {}
    end

    if type(S.getState) == "function" then
        local okGet, v = pcall(S.getState)
        if okGet and type(v) == "table" then
            return v
        end
    end

    return {}
end

local function _getWhoStoreServiceBestEffort()
    local okW, WS = _safeRequire("dwkit.services.whostore_service")
    if not okW or type(WS) ~= "table" then
        return nil
    end
    return WS
end

-- Real override store exists: dwkit.services.roomentities_override_store
local function _getOverrideStoreBestEffort()
    local okO, OS = _safeRequire("dwkit.services.roomentities_override_store")
    if not okO or type(OS) ~= "table" then
        return nil
    end
    return OS
end

local function _setLabelTextHtml(label, html)
    if type(label) == "table" and type(label.setText) == "function" then
        pcall(function()
            label:setText(html)
        end)
        return true
    end
    return false
end

local function _setLabelText(label, txt)
    if _setLabelTextHtml(label, ListKit.toPreHtml(txt)) then
        return
    end
    U.safeSetLabelText(label, txt)
end

local _state = {
    inited = false,
    lastApply = nil,
    lastError = nil,
    enabled = nil,
    visible = nil,

    subscriptionRoomEntities = nil,
    subscriptionWhoStore = nil,

    -- overrides keyed by normalized key (lower(trim(name))) -> "mob|item|ignore"
    overrides = {},

    -- Persistence wiring
    overrideStore = nil,
    overridesLoaded = false,
    warnedNoOverrideStore = false,

    -- Cache last data state rendered (service or injected)
    lastDataState = nil,

    lastRender = {
        counts = { players = 0, mobs = 0, items = 0, unknown = 0 },
        overrideCount = 0,
        usedWhoStoreBoost = false,
        usedRowUi = false,
        lastError = nil,
    },

    widgets = {
        container = nil,
        content = nil,
        panel = nil,
        label = nil,
        listRoot = nil,
        rendered = {},
    },
}

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

local function _clearRenderedWidgets()
    local r = _state.widgets.rendered
    if type(r) ~= "table" then
        _state.widgets.rendered = {}
        return
    end

    for i = #r, 1, -1 do
        local w = r[i]
        if type(w) == "table" then
            U.safeDelete(w)
        end
        r[i] = nil
    end
end

local function _tryCreateRowUiRoot(parent)
    local G = U.getGeyser()
    if not G then return false, "Geyser not available" end

    local root = nil
    local ok = pcall(function()
        root = G.Container:new({
            name = "__DWKit_roomentities_ui_listRoot",
            x = 0,
            y = 0,
            width = "100%",
            height = "100%",
        }, parent)
    end)

    if ok and type(root) == "table" then
        return true, root
    end

    return false, "Failed to create list root"
end

local function _ensureWidgets()
    local ok, widgets, err = U.ensureWidgets(M.UI_ID, { "container", "label", "content", "panel", "listRoot" },
        function()
            local G = U.getGeyser()
            if not G then
                return nil
            end

            local bundle = W.create({
                uiId = M.UI_ID,
                title = "Room Entities",
                x = 30,
                y = 310,
                width = 360,
                height = 260,
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

            local TITLE_INSET = 12

            local panel = nil
            local okPanel = pcall(function()
                panel = G.Container:new({
                    name = "__DWKit_roomentities_ui_panel",
                    x = 0,
                    y = TITLE_INSET,
                    width = "100%",
                    height = "100%-" .. tostring(TITLE_INSET),
                }, contentParent)
            end)

            if not okPanel or type(panel) ~= "table" then
                panel = G.Container:new({
                    name = "__DWKit_roomentities_ui_panel",
                    x = 0,
                    y = TITLE_INSET,
                    width = "100%",
                    height = "100%",
                }, contentParent)
            end

            ListKit.applyPanelStyle(panel)

            local label = G.Label:new({
                name = "__DWKit_roomentities_ui_label",
                x = 0,
                y = 0,
                width = "100%",
                height = "100%",
            }, panel)

            ListKit.applyTextLabelStyle(label)

            local okRoot, listRootOrErr = _tryCreateRowUiRoot(panel)
            local listRoot = nil
            if okRoot then
                listRoot = listRootOrErr
            end

            if type(listRoot) == "table" and type(ListKit.applyListRootStyle) == "function" then
                pcall(function() ListKit.applyListRootStyle(listRoot) end)
            end

            return {
                container = container,
                content = contentParent,
                panel = panel,
                label = label,
                listRoot = listRoot,
            }
        end)

    if not ok or type(widgets) ~= "table" then
        return false, err or "Failed to create widgets"
    end

    _state.widgets.container = widgets.container
    _state.widgets.content = widgets.content
    _state.widgets.panel = widgets.panel
    _state.widgets.label = widgets.label
    _state.widgets.listRoot = widgets.listRoot

    return true, nil
end

local function _resolveVisibleBestEffort(gs, uiId, defaultValue)
    defaultValue = (defaultValue == true)

    if type(gs) ~= "table" then
        return defaultValue
    end

    if type(gs.isVisible) == "function" then
        local okV, v = pcall(gs.isVisible, uiId, defaultValue)
        if okV then return (v == true) end
    end

    if type(gs.getVisible) == "function" then
        local okV, v = pcall(gs.getVisible, uiId, defaultValue)
        if okV then return (v == true) end
    end

    return defaultValue
end

local function _normalizeStateBuckets(state)
    state = (type(state) == "table") and state or {}
    local buckets = {
        players = (type(state.players) == "table") and state.players or {},
        mobs = (type(state.mobs) == "table") and state.mobs or {},
        items = (type(state.items) == "table") and state.items or {},
        unknown = (type(state.unknown) == "table") and state.unknown or {},
    }
    return buckets
end

local function _collectAllNamesFromBuckets(buckets)
    buckets = (type(buckets) == "table") and buckets or {}
    local seen = {}

    local function addSet(t)
        if type(t) ~= "table" then return end
        for k, v in pairs(t) do
            if v == true and type(k) == "string" and k ~= "" then
                seen[k] = true
            end
        end
    end

    addSet(buckets.players)
    addSet(buckets.mobs)
    addSet(buckets.items)
    addSet(buckets.unknown)

    return seen
end

local function _baseTypeForName(name, buckets)
    if type(buckets.players) == "table" and buckets.players[name] == true then return "players" end
    if type(buckets.mobs) == "table" and buckets.mobs[name] == true then return "mobs" end
    if type(buckets.items) == "table" and buckets.items[name] == true then return "items" end
    if type(buckets.unknown) == "table" and buckets.unknown[name] == true then return "unknown" end
    return "unknown"
end

local function _whoGetEntry(whoService, name)
    if type(whoService) ~= "table" or type(name) ~= "string" or name == "" then
        return nil
    end

    if type(whoService.getEntry) == "function" then
        local ok, e = pcall(whoService.getEntry, name)
        if ok and e ~= nil then
            return e
        end
    end

    return nil
end

local function _whoHasExactName(whoService, name)
    local e = _whoGetEntry(whoService, name)
    if type(e) ~= "table" then
        return false
    end

    if type(e.name) == "string" and e.name ~= "" then
        return (e.name == name)
    end

    return false
end

local function _ensureOverridesLoadedBestEffort()
    if _state.overridesLoaded == true then
        return true
    end

    if type(_state.overrideStore) ~= "table" then
        _state.overrideStore = _getOverrideStoreBestEffort()
    end

    if type(_state.overrideStore) ~= "table" then
        if _state.warnedNoOverrideStore ~= true then
            _state.warnedNoOverrideStore = true
            _out(
                "[DWKit UI] roomentities_ui WARN: override store not available; overrides will not persist across restart",
                nil)
        end
        -- IMPORTANT: do NOT set overridesLoaded=true; we will retry later
        return false
    end

    if type(_state.overrideStore.getAll) ~= "function" then
        _out("[DWKit UI] roomentities_ui WARN: override store missing getAll(); persistence disabled", nil)
        return false
    end

    local ok, loaded = pcall(_state.overrideStore.getAll)
    if not ok or type(loaded) ~= "table" then
        return false
    end

    -- Load ALL persisted overrides into memory. Do not filter by current snapshot.
    for key, entry in pairs(loaded) do
        if type(key) == "string" and key ~= "" and type(entry) == "table" then
            local t = tostring(entry.type or "")
            if t == "mob" or t == "item" or t == "ignore" then
                _state.overrides[key] = t
            end
        end
    end

    _state.overridesLoaded = true
    return true
end

local function _effectiveTypeForName(name, buckets, whoService)
    local key = _keyForName(name)
    local overrideMode = (key ~= "" and _state.overrides[key]) or nil
    if overrideMode and overrideMode ~= "" then
        if overrideMode == "mob" then return "mobs", false end
        if overrideMode == "item" then return "items", false end
        if overrideMode == "ignore" then return "unknown", false end -- IGN means pinned Unknown
    end

    if type(whoService) == "table" and type(name) == "string" and name ~= "" then
        if _whoHasExactName(whoService, name) then
            return "players", true
        end
    end

    return _baseTypeForName(name, buckets), false
end

-- v2026-02-10G: SAFE persist wrapper (never let a click callback hard-error)
local function _persistOverrideBestEffort(key, typeStrOrNil)
    key = tostring(key or "")
    if key == "" then return false end

    if type(_state.overrideStore) ~= "table" then
        _state.overrideStore = _getOverrideStoreBestEffort()
    end
    local OS = _state.overrideStore
    if type(OS) ~= "table" then
        return false
    end

    local t = tostring(typeStrOrNil or "")

    if t == "" then
        if type(OS.clear) == "function" then
            local okCall, okRes, errRes = pcall(OS.clear, key)
            if not okCall then
                _out("[DWKit UI] roomentities_ui WARN: OS.clear threw key=" .. key .. " err=" .. tostring(okRes), nil)
                return false
            end
            if not okRes then
                _out("[DWKit UI] roomentities_ui WARN: OS.clear failed key=" .. key .. " err=" .. tostring(errRes), nil)
            end
            return okRes == true
        end
        return false
    end

    if t ~= "mob" and t ~= "item" and t ~= "ignore" then
        return false
    end

    if type(OS.set) == "function" then
        local okCall, okRes, errRes = pcall(OS.set, key, t)
        if not okCall then
            _out(
                "[DWKit UI] roomentities_ui WARN: OS.set threw key=" ..
                key .. " type=" .. t .. " err=" .. tostring(okRes),
                nil)
            return false
        end
        if not okRes then
            _out(
                "[DWKit UI] roomentities_ui WARN: OS.set failed key=" ..
                key .. " type=" .. t .. " err=" .. tostring(errRes),
                nil)
        end
        return okRes == true
    end

    return false
end

local function _computeEffectiveLists(state)
    local buckets = _normalizeStateBuckets(state)
    local whoService = _getWhoStoreServiceBestEffort()

    -- Ensure overrides are loaded (best-effort). If store isn't ready yet, we'll retry later.
    _ensureOverridesLoadedBestEffort()

    local allNamesSet = _collectAllNamesFromBuckets(buckets)

    local outLists = {
        players = {},
        mobs = {},
        items = {},
        unknown = {},
    }

    local usedWhoBoost = false

    for name, _ in pairs(allNamesSet) do
        local effType, didBoost = _effectiveTypeForName(name, buckets, whoService)
        usedWhoBoost = usedWhoBoost or (didBoost == true)

        if effType == "players" then
            outLists.players[#outLists.players + 1] = name
        elseif effType == "mobs" then
            outLists.mobs[#outLists.mobs + 1] = name
        elseif effType == "items" then
            outLists.items[#outLists.items + 1] = name
        else
            outLists.unknown[#outLists.unknown + 1] = name
        end
    end

    local function sortList(t2)
        table.sort(t2, function(a, b)
            return tostring(a):lower() < tostring(b):lower()
        end)
    end

    sortList(outLists.players)
    sortList(outLists.mobs)
    sortList(outLists.items)
    sortList(outLists.unknown)

    local overrideCount = 0
    for _, mode in pairs(_state.overrides) do
        if mode == "mob" or mode == "item" or mode == "ignore" then
            overrideCount = overrideCount + 1
        end
    end

    return outLists, overrideCount, usedWhoBoost
end

local function _applyHeaderStyleBestEffort(labelObj)
    if type(ListKit.applySectionHeaderStyle) == "function" then
        pcall(function() ListKit.applySectionHeaderStyle(labelObj) end)
        return
    end

    if type(labelObj) == "table" and type(labelObj.setStyleSheet) == "function" then
        pcall(function()
            labelObj:setStyleSheet([[
                QLabel {
                    font-weight: bold;
                    padding: 4px;
                    margin: 0px;
                    border: 1px solid rgba(255,255,255,0.10);
                    background: rgba(255,255,255,0.05);
                }
            ]])
        end)
    end
end

local function _applyRowNameStyleBestEffort(labelObj)
    if type(ListKit.applyRowTextStyle) == "function" then
        pcall(function() ListKit.applyRowTextStyle(labelObj) end)
        return
    end

    if type(labelObj) == "table" and type(labelObj.setStyleSheet) == "function" then
        pcall(function()
            labelObj:setStyleSheet([[
                QLabel {
                    padding: 3px;
                    margin: 0px;
                }
            ]])
        end)
    end
end

local function _applyOverrideButtonStyleBestEffort(labelObj)
    local okB, BK = _safeRequire("dwkit.ui.ui_button_kit")
    if okB and type(BK) == "table" then
        local candidates = {
            "applySmallButtonStyle",
            "applyRowButtonStyle",
            "applyActionButtonStyle",
            "applyButtonStyle",
        }
        for _, fn in ipairs(candidates) do
            if type(BK[fn]) == "function" then
                local ok = pcall(function() BK[fn](labelObj) end)
                if ok then return end
            end
        end
    end

    if type(labelObj) == "table" and type(labelObj.setStyleSheet) == "function" then
        pcall(function()
            labelObj:setStyleSheet([[
                QLabel {
                    font-weight: bold;
                    padding: 3px 6px;
                    margin: 0px;
                    border: 1px solid rgba(255,255,255,0.15);
                    background: rgba(255,255,255,0.06);
                    qproperty-alignment: 'AlignCenter';
                }
                QLabel:hover {
                    background: rgba(255,255,255,0.10);
                }
            ]])
        end)
    end
end

local function _wireLabelClickBestEffort(labelName, fn)
    if type(labelName) ~= "string" or labelName == "" then return end
    if type(fn) ~= "function" then return end

    if type(_G.setLabelClickCallback) == "function" then
        pcall(function()
            _G.setLabelClickCallback(labelName, fn)
        end)
    end
end

local function _getHeightBestEffort(widget)
    if type(widget) ~= "table" then return nil end

    local candidates = { "get_height", "getHeight", "height" }
    for _, fn in ipairs(candidates) do
        if type(widget[fn]) == "function" then
            local ok, v = pcall(widget[fn], widget)
            if ok and tonumber(v) ~= nil then
                return tonumber(v)
            end
        end
    end

    return nil
end

local function _setOverrideModeForName(name, typeStr)
    name = tostring(name or "")
    if name == "" then return end

    local key = _keyForName(name)
    if key == "" then return end

    typeStr = tostring(typeStr or "")
    if typeStr ~= "mob" and typeStr ~= "item" and typeStr ~= "ignore" then
        typeStr = ""
    end

    local cur = _state.overrides[key] or ""

    -- Toggle: clicking same mode clears back to AUTO
    if cur == typeStr then
        _state.overrides[key] = nil
        _persistOverrideBestEffort(key, nil)
    else
        if typeStr == "" then
            _state.overrides[key] = nil
            _persistOverrideBestEffort(key, nil)
        else
            _state.overrides[key] = typeStr
            _persistOverrideBestEffort(key, typeStr)
        end
    end

    _out(string.format("[DWKit UI] roomentities_ui override key=%s name=%s type=%s",
        tostring(key),
        tostring(name),
        tostring(_state.overrides[key] or "auto")
    ), nil)

    local st = _state.lastDataState
    if type(st) == "table" then
        M._renderNow(st)
    else
        M._renderFromService()
    end
end

local function _renderRowsIntoRoot(root, effectiveLists)
    local G = U.getGeyser()
    if not G or type(root) ~= "table" then
        return false, "Row root not available"
    end

    _clearRenderedWidgets()

    local TOP_PAD = 3
    local BOTTOM_PAD = 2

    local yCursor = TOP_PAD
    local GAP = 3

    local HEADER_H = 30
    local ROW_H = 28

    local availH = _getHeightBestEffort(root)

    local function canPlace(h)
        h = tonumber(h) or 0
        if type(availH) ~= "number" then
            return true
        end
        return (yCursor + h + BOTTOM_PAD) <= availH
    end

    local function placeNext(h)
        yCursor = yCursor + (tonumber(h) or 0) + GAP
    end

    local function addHeader(text)
        if not canPlace(HEADER_H) then
            return nil, "insufficient height (header)"
        end

        local h = G.Label:new({
            name = "__DWKit_roomentities_ui_hdr_" .. tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999)),
            x = 0,
            y = yCursor,
            width = "100%",
            height = HEADER_H,
        }, root)

        _applyHeaderStyleBestEffort(h)
        _setLabelText(h, tostring(text))
        _state.widgets.rendered[#_state.widgets.rendered + 1] = h
        placeNext(HEADER_H)
        return h, nil
    end

    local function addRow(name)
        if not canPlace(ROW_H) then
            return false, "insufficient height (row)"
        end

        name = tostring(name or "")
        local row = G.Container:new({
            name = "__DWKit_roomentities_ui_rowC_" .. tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999)),
            x = 0,
            y = yCursor,
            width = "100%",
            height = ROW_H,
        }, root)

        _state.widgets.rendered[#_state.widgets.rendered + 1] = row

        if type(row) == "table" and type(row.setStyleSheet) == "function" then
            pcall(function()
                row:setStyleSheet([[background-color: rgba(0,0,0,0); border: 0px;]])
            end)
        end

        local nameLabel = G.Label:new({
            name = row.name .. "_name",
            x = 0,
            y = 0,
            width = "60%",
            height = "100%",
        }, row)

        _applyRowNameStyleBestEffort(nameLabel)
        _setLabelText(nameLabel, name)
        _state.widgets.rendered[#_state.widgets.rendered + 1] = nameLabel

        local btnMob = G.Label:new({
            name = row.name .. "_btn_mob",
            x = "60%",
            y = 0,
            width = "13.3333%",
            height = "100%",
        }, row)
        _applyOverrideButtonStyleBestEffort(btnMob)
        _setLabelText(btnMob, "MOB")
        _state.widgets.rendered[#_state.widgets.rendered + 1] = btnMob

        local btnItem = G.Label:new({
            name = row.name .. "_btn_item",
            x = "73.3333%",
            y = 0,
            width = "13.3333%",
            height = "100%",
        }, row)
        _applyOverrideButtonStyleBestEffort(btnItem)
        _setLabelText(btnItem, "ITEM")
        _state.widgets.rendered[#_state.widgets.rendered + 1] = btnItem

        local btnIgn = G.Label:new({
            name = row.name .. "_btn_ign",
            x = "86.6666%",
            y = 0,
            width = "13.3334%",
            height = "100%",
        }, row)
        _applyOverrideButtonStyleBestEffort(btnIgn)
        _setLabelText(btnIgn, "IGN")
        _state.widgets.rendered[#_state.widgets.rendered + 1] = btnIgn

        _wireLabelClickBestEffort(btnMob.name, function()
            if _state.enabled ~= true or _state.visible ~= true then return end
            local ok, errMsg = pcall(function()
                _setOverrideModeForName(name, "mob")
            end)
            if not ok then
                _out("[DWKit UI] roomentities_ui WARN: btn MOB click threw err=" .. tostring(errMsg), nil)
            end
        end)

        _wireLabelClickBestEffEffort = _wireLabelClickBestEffort -- keep local alias stable if tooling inspects
        _wireLabelClickBestEffort(btnItem.name, function()
            if _state.enabled ~= true or _state.visible ~= true then return end
            local ok, errMsg = pcall(function()
                _setOverrideModeForName(name, "item")
            end)
            if not ok then
                _out("[DWKit UI] roomentities_ui WARN: btn ITEM click threw err=" .. tostring(errMsg), nil)
            end
        end)

        _wireLabelClickBestEffort(btnIgn.name, function()
            if _state.enabled ~= true or _state.visible ~= true then return end
            local ok, errMsg = pcall(function()
                _setOverrideModeForName(name, "ignore")
            end)
            if not ok then
                _out("[DWKit UI] roomentities_ui WARN: btn IGN click threw err=" .. tostring(errMsg), nil)
            end
        end)

        placeNext(ROW_H)
        return true, nil
    end

    local function addSection(title, list)
        local n = (type(list) == "table") and #list or 0

        local hdr = string.format("%s (%d)", tostring(title), tonumber(n) or 0)
        if n == 0 then
            hdr = hdr .. " (empty)"
        end

        local okHdr = addHeader(hdr)
        if not okHdr then
            return true, nil
        end

        if n == 0 then
            return true, nil
        end

        for i = 1, n do
            local okRow = addRow(list[i])
            if not okRow then
                return true, nil
            end
        end

        return true, nil
    end

    addSection("Players", effectiveLists.players)
    addSection("Mobs", effectiveLists.mobs)
    addSection("Items-Objects", effectiveLists.items)
    addSection("Unknown", effectiveLists.unknown)

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

    _state.overrideStore = _getOverrideStoreBestEffort()

    -- best-effort preload; if store isn't ready, we'll retry in render
    _ensureOverridesLoadedBestEffort()

    U.safeHide(_state.widgets.container)

    _state.inited = true
    _state.lastError = nil
    return true, nil
end

function M._renderNow(state)
    state = (type(state) == "table") and state or {}

    _state.lastDataState = state

    local effectiveLists, overrideCount, usedWhoBoost = _computeEffectiveLists(state)

    local usedRowUi = false
    local lastErr = nil

    if type(_state.widgets.listRoot) == "table" then
        usedRowUi = true

        U.safeHide(_state.widgets.label)

        local okRows, errRows = _renderRowsIntoRoot(_state.widgets.listRoot, effectiveLists)
        if not okRows then
            usedRowUi = false
            lastErr = tostring(errRows or "row render failed")
            U.safeHide(_state.widgets.listRoot)
        else
            U.safeShow(_state.widgets.listRoot)
        end
    end

    if not usedRowUi then
        if type(_state.widgets.listRoot) == "table" then
            U.safeHide(_state.widgets.listRoot)
        end

        U.safeShow(_state.widgets.label)
        local txt = _formatFallbackText(state, effectiveLists, overrideCount)
        _setLabelText(_state.widgets.label, txt)
    end

    _state.lastRender.counts.players = (type(effectiveLists.players) == "table") and #effectiveLists.players or 0
    _state.lastRender.counts.mobs = (type(effectiveLists.mobs) == "table") and #effectiveLists.mobs or 0
    _state.lastRender.counts.items = (type(effectiveLists.items) == "table") and #effectiveLists.items or 0
    _state.lastRender.counts.unknown = (type(effectiveLists.unknown) == "table") and #effectiveLists.unknown or 0
    _state.lastRender.overrideCount = overrideCount or 0
    _state.lastRender.usedWhoStoreBoost = (usedWhoBoost == true)
    _state.lastRender.usedRowUi = (usedRowUi == true)
    _state.lastRender.lastError = lastErr

    return true
end

function M._renderFromService()
    local state = _getRoomEntitiesStateBestEffort()
    return M._renderNow(state)
end

function M.seedServiceFixture(opts)
    opts = (type(opts) == "table") and opts or {}

    local okS, S = _safeRequire("dwkit.services.roomentities_service")
    if not okS or type(S) ~= "table" then
        return false, "RoomEntitiesService not available"
    end

    if type(S.ingestFixture) ~= "function" then
        return false, "RoomEntitiesService.ingestFixture not available"
    end

    if type(opts.source) ~= "string" or opts.source == "" then
        opts.source = "fixture:roomentities_ui"
    end

    local ok, err = S.ingestFixture(opts)
    if not ok then
        return false, tostring(err)
    end

    if _state.enabled == true and _state.visible == true then
        M._renderFromService()
    end

    return true, nil
end

local function _ensureRoomEntitiesSubscription()
    if type(_state.subscriptionRoomEntities) == "table" and _state.subscriptionRoomEntities.handlerId ~= nil then
        return true, nil
    end

    local okS, S = _safeRequire("dwkit.services.roomentities_service")
    if not okS or type(S) ~= "table" then
        _state.lastError = "RoomEntitiesService not available"
        return false, _state.lastError
    end

    if type(S.onUpdated) ~= "function" then
        _state.lastError = "RoomEntitiesService.onUpdated not available"
        return false, _state.lastError
    end

    local evName = _resolveUpdatedEventName(S)
    if type(evName) ~= "string" or evName == "" then
        _state.lastError = "RoomEntities updated event name not available"
        return false, _state.lastError
    end

    local handlerFn = function(payload)
        if _state.enabled ~= true or _state.visible ~= true then
            return
        end

        payload = (type(payload) == "table") and payload or {}

        if type(payload.state) == "table" then
            M._renderNow(payload.state)
        else
            M._renderFromService()
        end
    end

    local okSub, sub, errSub = U.subscribeServiceUpdates(
        M.UI_ID,
        S.onUpdated,
        handlerFn,
        { eventName = evName, debugPrefix = "[DWKit UI] roomentities_ui" }
    )

    if not okSub then
        _state.lastError = tostring(errSub or "subscribe failed")
        return false, _state.lastError
    end

    _state.subscriptionRoomEntities = sub
    return true, nil
end

local function _ensureWhoStoreSubscription()
    if type(_state.subscriptionWhoStore) == "table" and _state.subscriptionWhoStore.handlerId ~= nil then
        return true, nil
    end

    local okW, WS = _safeRequire("dwkit.services.whostore_service")
    if not okW or type(WS) ~= "table" then
        return true, nil
    end

    if type(WS.onUpdated) ~= "function" then
        return true, nil
    end

    local evName = _resolveUpdatedEventName(WS)
    if type(evName) ~= "string" or evName == "" then
        return true, nil
    end

    local handlerFn = function(_payload)
        if _state.enabled ~= true or _state.visible ~= true then
            return
        end

        M._renderFromService()
    end

    local okSub, sub = U.subscribeServiceUpdates(
        M.UI_ID,
        WS.onUpdated,
        handlerFn,
        { eventName = evName, debugPrefix = "[DWKit UI] roomentities_ui (WhoStore)" }
    )

    if not okSub then
        return true, nil
    end

    _state.subscriptionWhoStore = sub
    return true, nil
end

local function _ensureSubscriptions()
    local ok1, err1 = _ensureRoomEntitiesSubscription()
    if not ok1 then
        return false, err1
    end
    local ok2, err2 = _ensureWhoStoreSubscription()
    if not ok2 then
        return false, err2
    end
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

    visible = _resolveVisibleBestEffort(gs, M.UI_ID, false)

    _state.enabled = enabled
    _state.visible = visible
    _state.lastApply = os.time()
    _state.lastError = nil

    local action = "hide"
    if enabled and visible then
        action = "show"

        local okSub, errSub = _ensureSubscriptions()
        if not okSub then
            _out("[DWKit UI] roomentities_ui WARN: " .. tostring(errSub), opts)
        end

        M._renderFromService()
        U.safeShow(_state.widgets.container)
    else
        U.safeHide(_state.widgets.container)
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
    local subR = (type(_state.subscriptionRoomEntities) == "table") and _state.subscriptionRoomEntities or {}
    local subW = (type(_state.subscriptionWhoStore) == "table") and _state.subscriptionWhoStore or {}

    local hasContainer = (type(_state.widgets.container) == "table")
    local hasLabel = (type(_state.widgets.label) == "table")
    local hasRoot = (type(_state.widgets.listRoot) == "table")

    return {
        uiId = M.UI_ID,
        version = M.VERSION,
        inited = (_state.inited == true),
        enabled = _state.enabled,
        visible = _state.visible,
        requiredProviders = M.REQUIRED_PROVIDERS,
        lastApply = _state.lastApply,
        lastError = _state.lastError,
        subscriptions = {
            roomentities = {
                handlerId = subR.handlerId,
                updatedEventName = subR.updatedEventName,
            },
            whostore = {
                handlerId = subW.handlerId,
                updatedEventName = subW.updatedEventName,
            },
        },
        widgets = {
            hasContainer = hasContainer,
            hasLabel = hasLabel,
            hasListRoot = hasRoot,
        },
        overrides = {
            activeOverrideCount = _state.lastRender.overrideCount,
            persistence = {
                hasOverrideStore = (type(_state.overrideStore) == "table"),
                overridesLoaded = (_state.overridesLoaded == true),
            },
        },
        lastRender = {
            counts = _state.lastRender.counts,
            overrideCount = _state.lastRender.overrideCount,
            usedWhoStoreBoost = _state.lastRender.usedWhoStoreBoost,
            usedRowUi = _state.lastRender.usedRowUi,
            lastError = _state.lastRender.lastError,
        },
    }
end

function M.dispose(opts)
    opts = (type(opts) == "table") and opts or {}

    U.unsubscribeServiceUpdates(_state.subscriptionRoomEntities)
    U.unsubscribeServiceUpdates(_state.subscriptionWhoStore)

    _state.subscriptionRoomEntities = nil
    _state.subscriptionWhoStore = nil

    -- IMPORTANT (rtvis2 alignment): after dispose we must not claim enabled/visible.
    _state.enabled = false
    _state.visible = false
    _state.lastApply = os.time()

    -- Best-effort: mark ui_store state visible=false if helper exists.
    if type(U.setUiStateVisibleBestEffort) == "function" then
        pcall(function() U.setUiStateVisibleBestEffort(M.UI_ID, false) end)
    end

    _clearRenderedWidgets()

    U.safeDelete(_state.widgets.listRoot)
    U.safeDelete(_state.widgets.label)
    U.safeDelete(_state.widgets.container)

    _state.widgets.listRoot = nil
    _state.widgets.label = nil
    _state.widgets.container = nil
    _state.widgets.panel = nil
    _state.widgets.content = nil
    _state.widgets.rendered = {}

    _state.inited = false
    _state.lastError = nil
    return true, nil
end

return M
