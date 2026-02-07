-- FILE: src/dwkit/ui/roomentities_ui.lua
-- #########################################################################
-- Module Name : dwkit.ui.roomentities_ui
-- Owner       : UI
-- Version     : v2026-02-07B
-- Purpose     :
--   - SAFE RoomEntities UI (consumer-only) that renders a per-entity ROW LIST with
--     sections: Players / Mobs / Items-Objects / Unknown.
--   - Supports per-entity manual override cycle:
--       auto -> player -> mob -> item -> unknown -> auto
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
--   - RECOMMENDED TEST PIPELINE SUPPORT (NEW v2026-01-29A):
--       * seedServiceFixture(opts) helper: seeds RoomEntitiesService via ingestFixture()
--         (instead of calling UI._renderNow directly), so UI stays a pure consumer.
--
--   - FIX (v2026-01-29B):
--       * WhoStore boost now supports case-insensitive lookup.
--       * WhoStore boost now supports prefix phrases ("Scynox the adventurer" -> "Scynox")
--         without refactoring service logic (best-effort, UI-only).
--       * Prune orphaned overrides on each compute pass (keeps overrides in sync with data).
--
--   - FIX (v2026-01-29D):
--       * WhoStore boost now uses WhoStoreService.getEntry(name) (case-insensitive),
--         and no longer reads snapshot.byName directly (consumer hardening).
--
--   - FIX (v2026-01-29E):
--       * When falling back to text view (or row render fails), hide listRoot to avoid
--         overlapping/ghost UI elements.
--
--   - NEW (v2026-02-01A):
--       * Confidence gate: stop promoting "player" solely from case-insensitive matches
--         or prefix matches. Exact display-name match only (or explicit override).
--
--   - FIX (v2026-02-02B):
--       * Readability: ensure listRoot and row containers are transparent, and row/header
--         label styles force readable text colors (prevents white-on-white or pale palettes).
--
--   - NEW (v2026-02-03A):
--       * Quiet-aware logging: apply() output respects opts.quiet (for ui_manager applyAll/applyOne).
--
--   - NEW (v2026-02-04D):
--       * Declare required passive providers for enabled-mode dependency management.
--         NOTE: Actual provider lifecycle is managed by ui_manager + ui_dependency_service.
--
--   - FIX (v2026-02-07A):
--       * dispose() must NOT clear ui_store entry; keep deterministic state.visible boolean
--         for ui_manager runtime visibility checks. Clear runtime handles + delete widgets instead.
-- #########################################################################

local M = {}

M.VERSION = "v2026-02-07B"
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

local function _countAny(x)
    if type(x) ~= "table" then return 0 end
    local n = 0
    for _ in pairs(x) do n = n + 1 end
    return n
end

local function _sortedKeysFromSet(t)
    if type(t) ~= "table" then return {} end
    local keys = {}
    for k, v in pairs(t) do
        if v == true and type(k) == "string" and k ~= "" then
            keys[#keys + 1] = k
        end
    end
    table.sort(keys, function(a, b)
        return tostring(a):lower() < tostring(b):lower()
    end)
    return keys
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

-- Override modes (LOCKED cycle order)
local OVERRIDE_ORDER = { "auto", "player", "mob", "item", "unknown" }

local function _nextOverrideMode(cur)
    cur = tostring(cur or "auto")
    for i = 1, #OVERRIDE_ORDER do
        if OVERRIDE_ORDER[i] == cur then
            local ni = i + 1
            if ni > #OVERRIDE_ORDER then ni = 1 end
            return OVERRIDE_ORDER[ni]
        end
    end
    return "auto"
end

local function _overrideLabel(mode)
    mode = tostring(mode or "auto")
    if mode == "auto" then return "AUTO" end
    if mode == "player" then return "PLAYER" end
    if mode == "mob" then return "MOB" end
    if mode == "item" then return "ITEM" end
    if mode == "unknown" then return "UNKNOWN" end
    return "AUTO"
end

local function _bucketKeyForMode(mode)
    mode = tostring(mode or "auto")
    if mode == "player" then return "players" end
    if mode == "mob" then return "mobs" end
    if mode == "item" then return "items" end
    if mode == "unknown" then return "unknown" end
    return nil
end

local function _trim(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function _firstWord(s)
    s = _trim(s or "")
    if s == "" then return "" end
    local w = s:match("^([^%s]+)")
    return tostring(w or "")
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

    overrides = {},

    -- Cache last data state rendered (service or injected) so override clicks can re-render
    -- without depending on RoomEntitiesService being populated.
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

            -- Readability: ensure listRoot never paints an opaque light background.
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

    -- Confidence gate: exact display-name match only.
    if type(e.name) == "string" and e.name ~= "" then
        return (e.name == name)
    end

    return false
end

local function _whoHasPrefixExact(whoService, phrase)
    -- Policy: prefix-only is a candidate signal, not enough to auto-promote to player.
    -- Keep the helper for compatibility, but do not return true unless phrase itself is exact.
    if type(whoService) ~= "table" or type(phrase) ~= "string" or phrase == "" then
        return false
    end

    -- If phrase is exactly a known display-name, _whoHasExactName will handle it.
    -- Therefore: return false here.
    return false
end

local function _effectiveTypeForName(name, buckets, whoService)
    local overrideMode = _state.overrides[name]
    if overrideMode and overrideMode ~= "auto" then
        local forced = _bucketKeyForMode(overrideMode)
        if forced then return forced, false end
    end

    if type(whoService) == "table" and type(name) == "string" and name ~= "" then
        if _whoHasExactName(whoService, name) then
            return "players", true
        end
        if _whoHasPrefixExact(whoService, name) then
            return "players", true
        end
    end

    return _baseTypeForName(name, buckets), false
end

local function _pruneOrphanedOverrides(allNamesSet)
    if type(_state.overrides) ~= "table" then
        _state.overrides = {}
        return
    end
    allNamesSet = (type(allNamesSet) == "table") and allNamesSet or {}

    for name, mode in pairs(_state.overrides) do
        if allNamesSet[name] ~= true then
            _state.overrides[name] = nil
        elseif mode == "auto" then
            _state.overrides[name] = nil
        end
    end
end

local function _computeEffectiveLists(state)
    local buckets = _normalizeStateBuckets(state)
    local whoService = _getWhoStoreServiceBestEffort()

    local all = _collectAllNamesFromBuckets(buckets)

    -- Keep overrides aligned with the current dataset (prevents orphaned overrides after canonicalization).
    _pruneOrphanedOverrides(all)

    local outLists = {
        players = {},
        mobs = {},
        items = {},
        unknown = {},
    }

    local usedWhoBoost = false

    for name, _ in pairs(all) do
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

    local function sortList(t)
        table.sort(t, function(a, b)
            return tostring(a):lower() < tostring(b):lower()
        end)
    end

    sortList(outLists.players)
    sortList(outLists.mobs)
    sortList(outLists.items)
    sortList(outLists.unknown)

    local overrideCount = 0
    for _, mode in pairs(_state.overrides) do
        if mode and mode ~= "auto" then
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
        local row = nil

        pcall(function()
            if type(G.HBox) == "table" and type(G.HBox.new) == "function" then
                row = G.HBox:new({
                    name = "__DWKit_roomentities_ui_row_" ..
                        tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999)),
                    x = 0,
                    y = yCursor,
                    width = "100%",
                    height = ROW_H,
                }, root)
            end
        end)

        if type(row) ~= "table" then
            row = G.Container:new({
                name = "__DWKit_roomentities_ui_rowC_" .. tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999)),
                x = 0,
                y = yCursor,
                width = "100%",
                height = ROW_H,
            }, root)
        end

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
            width = "72%",
            height = "100%",
        }, row)

        _applyRowNameStyleBestEffort(nameLabel)
        _setLabelText(nameLabel, name)
        _state.widgets.rendered[#_state.widgets.rendered + 1] = nameLabel

        local btnLabel = G.Label:new({
            name = row.name .. "_ovr",
            x = "72%",
            y = 0,
            width = "28%",
            height = "100%",
        }, row)

        _applyOverrideButtonStyleBestEffort(btnLabel)

        local mode = _state.overrides[name] or "auto"
        _setLabelText(btnLabel, _overrideLabel(mode))
        _state.widgets.rendered[#_state.widgets.rendered + 1] = btnLabel

        _wireLabelClickBestEffort(btnLabel.name, function()
            if _state.enabled ~= true or _state.visible ~= true then
                return
            end

            local cur = _state.overrides[name] or "auto"
            local nxt = _nextOverrideMode(cur)
            _state.overrides[name] = nxt
            if nxt == "auto" then
                _state.overrides[name] = nil
            end

            -- Interactive action: keep this log (not part of quiet applyAll/applyOne)
            _out(string.format("[DWKit UI] roomentities_ui override name=%s mode=%s",
                tostring(name),
                tostring(_state.overrides[name] or "auto")
            ), nil)

            local st = _state.lastDataState
            if type(st) == "table" then
                M._renderNow(st)
            else
                M._renderFromService()
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

        local okHdr, errHdr = addHeader(hdr)
        if not okHdr then
            return false, errHdr or "header failed"
        end

        if n == 0 then
            return true, nil
        end

        for i = 1, n do
            local okRow, _errRow = addRow(list[i])
            if not okRow then
                return true, nil
            end
        end

        return true, nil
    end

    local okA = addSection("Players", effectiveLists.players)
    local okB = addSection("Mobs", effectiveLists.mobs)
    local okC = addSection("Items-Objects", effectiveLists.items)
    local okD = addSection("Unknown", effectiveLists.unknown)

    if not okA or not okB or not okC or not okD then
        return true, nil
    end

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

    local okSub, sub, _errSub = U.subscribeServiceUpdates(
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

    -- Keep runtime visible signal in sync for UI Manager UI / drift probes
    U.setUiStateVisibleBestEffort(M.UI_ID, (visible == true))
    _state.lastApply = os.time()
    _state.lastError = nil

    local action = "hide"
    if enabled and visible then
        action = "show"

        local okSub, errSub = _ensureSubscriptions()
        if not okSub then
            -- Respect quiet; caller can still inspect getState().lastError
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

    -- Unsubscribe first (safe even if nil)
    U.unsubscribeServiceUpdates(_state.subscriptionRoomEntities)
    U.unsubscribeServiceUpdates(_state.subscriptionWhoStore)

    _state.subscriptionRoomEntities = nil
    _state.subscriptionWhoStore = nil

    -- IMPORTANT: Do NOT clear the ui_store entry.
    -- UI Manager expects entry.state.visible to be deterministic (never nil).
    if type(U.setUiStateVisibleBestEffort) == "function" then
        pcall(U.setUiStateVisibleBestEffort, M.UI_ID, false)
    else
        pcall(U.setUiRuntime, M.UI_ID, { state = { visible = false } })
    end

    -- Keep entry, clear runtime handles
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
        entry.listRoot = nil
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
    _state.enabled = nil
    _state.visible = nil
    _state.lastError = nil
    return true, nil
end

return M
