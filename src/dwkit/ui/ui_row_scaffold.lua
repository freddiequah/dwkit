-- FILE: src/dwkit/ui/ui_row_scaffold.lua
-- #########################################################################
-- BEGIN FILE: src/dwkit/ui/ui_row_scaffold.lua
-- #########################################################################
-- Module Name : dwkit.ui.ui_row_scaffold
-- Owner       : UI
-- Version     : v2026-02-25D
-- Purpose     :
--   - Shared "row UI scaffold" for DWKit list-style UIs.
--   - Standardizes:
--       * listRoot creation under a styled panel
--       * rendered-widget lifecycle (clear + rebuild)
--       * bounded vertical layout (yCursor/canPlace/placeNext)
--       * header/row/meta label rendering with ListKit styles
--       * overflow reporting
--   - SAFE: no timers, no sends, no gameplay commands.
--
-- Public API:
--   - createListRoot(parent, name) -> ok, root|nil, err|nil
--   - clearRendered(renderedArray, U) -> none
--   - getHeightBestEffort(widget) -> number|nil
--   - render(opts) -> ok, result|nil, err|nil
--       (simple headers + text rows; used by Presence UI)
--
-- NEW (v2026-02-25D):
--   - createLayout(opts) -> ok, ctx|nil, err|nil
--       (layout context for custom row widgets, eg RoomEntities buttons)
--     ctx API:
--       * ctx.canPlace(h) -> bool
--       * ctx.getCursorY() -> number
--       * ctx.placeNext(h)
--       * ctx.addMetaLine(text) -> bool
--       * ctx.addHeader(text) -> bool
--       * ctx.addTextRow(text) -> bool
--       * ctx.addCustom(h, fnCreateAtY) -> bool
--           fnCreateAtY(yCursor) must create widget(s) at that y. Return true/false.
--       * ctx.getStats() -> { rowCount, overflow, overflowMore }
--       * ctx.addOverflowNote(text) -> bool (best-effort)
-- #########################################################################

local M = {}

M.VERSION = "v2026-02-25D"

local function _n(v, d)
    v = tonumber(v)
    if v == nil then return d end
    return v
end

function M.getHeightBestEffort(widget)
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

    if tonumber(widget.height) ~= nil then
        local h = tonumber(widget.height)
        if h and h > 0 then return h end
    end

    return nil
end

function M.createListRoot(parent, name)
    local okU, U = pcall(require, "dwkit.ui.ui_base")
    if not okU or type(U) ~= "table" then
        return false, nil, "ui_base not available"
    end

    local G = U.getGeyser and U.getGeyser() or nil
    if not G or type(parent) ~= "table" then
        return false, nil, "Geyser not available"
    end

    local root = nil
    local ok = pcall(function()
        root = G.Container:new({
            name = tostring(name or "__DWKit_row_ui_listRoot"),
            x = 0,
            y = 0,
            width = "100%",
            height = "100%",
        }, parent)
    end)

    if not ok or type(root) ~= "table" then
        return false, nil, "Failed to create list root"
    end

    return true, root, nil
end

function M.clearRendered(renderedArray, U)
    U = (type(U) == "table") and U or nil
    renderedArray = (type(renderedArray) == "table") and renderedArray or {}

    for i = #renderedArray, 1, -1 do
        local w = renderedArray[i]
        if type(w) == "table" then
            if U and type(U.safeDelete) == "function" then
                U.safeDelete(w)
            else
                pcall(function()
                    if type(w.delete) == "function" then w:delete() end
                end)
            end
        end
        renderedArray[i] = nil
    end
end

local function _safeSetLabelText(labelObj, ListKit, U, text)
    if type(labelObj) == "table" and type(labelObj.setText) == "function"
        and type(ListKit) == "table" and type(ListKit.toPreHtml) == "function"
    then
        pcall(function()
            labelObj:setText(ListKit.toPreHtml(tostring(text or "")))
        end)
        return true
    end
    if type(U) == "table" and type(U.safeSetLabelText) == "function" then
        U.safeSetLabelText(labelObj, tostring(text or ""))
        return true
    end
    return false
end

-- -------------------------------------------------------------------------
-- NEW: layout context for UIs with custom row widgets
-- -------------------------------------------------------------------------
function M.createLayout(opts)
    opts = (type(opts) == "table") and opts or {}

    local root = opts.root
    local rendered = opts.rendered
    local ListKit = opts.ListKit
    local U = opts.U

    if type(root) ~= "table" then
        return false, nil, "root not available"
    end
    if type(rendered) ~= "table" then
        return false, nil, "rendered store not available"
    end
    if type(ListKit) ~= "table" then
        return false, nil, "ListKit not available"
    end
    if type(U) ~= "table" then
        return false, nil, "ui_base not available"
    end

    local G = U.getGeyser and U.getGeyser() or nil
    if not G then
        return false, nil, "Geyser not available"
    end

    local layout = (type(opts.layout) == "table") and opts.layout or {}
    local TOP_PAD = _n(layout.topPad, 3)
    local BOTTOM_PAD = _n(layout.bottomPad, 2)
    local GAP = _n(layout.gap, 3)
    local HEADER_H = _n(layout.headerH, 30)
    local ROW_H = _n(layout.rowH, 28)
    local META_H = _n(layout.metaH, 26)

    local availH = M.getHeightBestEffort(root)
    local yCursor = TOP_PAD

    local rowCount = 0
    local overflow = false
    local overflowMore = 0

    local function canPlace(h)
        h = _n(h, 0)
        if type(availH) ~= "number" then
            return true
        end
        return (yCursor + h + BOTTOM_PAD) <= availH
    end

    local function placeNext(h)
        yCursor = yCursor + _n(h, 0) + GAP
    end

    local function markOverflow(moreN)
        overflow = true
        overflowMore = overflowMore + (_n(moreN, 0))
    end

    local function addMetaLine(text)
        text = tostring(text or "")
        if text == "" then
            return true
        end
        if not canPlace(META_H) then
            markOverflow(1)
            return false
        end

        local lbl = G.Label:new({
            name = "__DWKit_rowui_meta_" .. tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999)),
            x = 0,
            y = yCursor,
            width = "100%",
            height = META_H,
        }, root)

        if type(ListKit.applyRowTextStyle) == "function" then
            pcall(function() ListKit.applyRowTextStyle(lbl) end)
        end

        _safeSetLabelText(lbl, ListKit, U, text)
        rendered[#rendered + 1] = lbl
        placeNext(META_H)
        rowCount = rowCount + 1
        return true
    end

    local function addHeader(text)
        text = tostring(text or "")
        if not canPlace(HEADER_H) then
            markOverflow(1)
            return false
        end

        local hdr = G.Label:new({
            name = "__DWKit_rowui_hdr_" .. tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999)),
            x = 0,
            y = yCursor,
            width = "100%",
            height = HEADER_H,
        }, root)

        if type(ListKit.applySectionHeaderStyle) == "function" then
            pcall(function() ListKit.applySectionHeaderStyle(hdr) end)
        end

        _safeSetLabelText(hdr, ListKit, U, text)
        rendered[#rendered + 1] = hdr
        placeNext(HEADER_H)
        rowCount = rowCount + 1
        return true
    end

    local function addTextRow(text)
        text = tostring(text or "")
        if not canPlace(ROW_H) then
            markOverflow(1)
            return false
        end

        local lbl = G.Label:new({
            name = "__DWKit_rowui_row_" .. tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999)),
            x = 0,
            y = yCursor,
            width = "100%",
            height = ROW_H,
        }, root)

        if type(ListKit.applyRowTextStyle) == "function" then
            pcall(function() ListKit.applyRowTextStyle(lbl) end)
        end

        _safeSetLabelText(lbl, ListKit, U, text)
        rendered[#rendered + 1] = lbl
        placeNext(ROW_H)
        rowCount = rowCount + 1
        return true
    end

    local function addCustom(h, fnCreateAtY)
        h = _n(h, ROW_H)
        if type(fnCreateAtY) ~= "function" then
            return false
        end

        if not canPlace(h) then
            markOverflow(1)
            return false
        end

        local y = yCursor
        local ok, res = pcall(fnCreateAtY, y)
        if not ok or res == false then
            -- If creator failed, do not advance cursor (caller can decide fallback)
            return false
        end

        placeNext(h)
        rowCount = rowCount + 1
        return true
    end

    local function addOverflowNote(text)
        text = tostring(text or "")
        if text == "" then
            return false
        end
        if not canPlace(ROW_H) then
            return false
        end
        return addTextRow(text)
    end

    local ctx = {
        canPlace = canPlace,
        placeNext = placeNext,
        getCursorY = function() return yCursor end,

        addMetaLine = addMetaLine,
        addHeader = addHeader,
        addTextRow = addTextRow,
        addCustom = addCustom,
        addOverflowNote = addOverflowNote,

        markOverflow = markOverflow,
        getStats = function()
            return {
                rowCount = rowCount,
                overflow = (overflow == true),
                overflowMore = tonumber(overflowMore) or 0,
            }
        end,

        constants = {
            TOP_PAD = TOP_PAD,
            BOTTOM_PAD = BOTTOM_PAD,
            GAP = GAP,
            HEADER_H = HEADER_H,
            ROW_H = ROW_H,
            META_H = META_H,
        },
    }

    return true, ctx, nil
end

-- -------------------------------------------------------------------------
-- Simple render() kept for Presence UI (headers + text rows)
-- -------------------------------------------------------------------------
function M.render(opts)
    opts = (type(opts) == "table") and opts or {}

    local root = opts.root
    local rendered = opts.rendered
    local ListKit = opts.ListKit
    local U = opts.U

    if type(root) ~= "table" then
        return false, nil, "root not available"
    end
    if type(rendered) ~= "table" then
        return false, nil, "rendered store not available"
    end
    if type(ListKit) ~= "table" then
        return false, nil, "ListKit not available"
    end
    if type(U) ~= "table" then
        return false, nil, "ui_base not available"
    end

    local okL, ctx, errL = M.createLayout({
        root = root,
        rendered = rendered,
        ListKit = ListKit,
        U = U,
        layout = opts.layout,
    })
    if not okL then
        return false, nil, errL
    end

    -- Start fresh
    M.clearRendered(rendered, U)

    -- Meta line (optional)
    if tostring(opts.metaLine or "") ~= "" then
        ctx.addMetaLine(opts.metaLine)
    end

    local sections = (type(opts.sections) == "table") and opts.sections or {}

    for si = 1, #sections do
        local s = (type(sections[si]) == "table") and sections[si] or {}
        local items = (type(s.items) == "table") and s.items or {}
        local n = #items

        local hdr = string.format("%s (%d)", tostring(s.title or ""), tonumber(n) or 0)
        if n == 0 then
            local suffix = tostring(s.emptySuffix or "(empty)")
            if suffix ~= "" then
                hdr = hdr .. " " .. suffix
            end
        end

        if not ctx.addHeader(hdr) then
            ctx.markOverflow(n)
            break
        end

        local prefix = tostring(s.itemPrefix or "")
        for i = 1, n do
            if not ctx.addTextRow(prefix .. tostring(items[i] or "")) then
                ctx.markOverflow(n - i + 1)
                break
            end
        end

        local st = ctx.getStats()
        if st.overflow == true then
            break
        end
    end

    local st = ctx.getStats()
    if st.overflow == true then
        local moreN = tonumber(st.overflowMore) or 0
        local txt = ""
        if type(opts.overflowRowTextFn) == "function" then
            local ok, v = pcall(opts.overflowRowTextFn, moreN)
            txt = ok and tostring(v or "") or ""
        end
        if txt == "" then
            txt = string.format("... (more rows not shown: +%d)", moreN)
        end
        ctx.addOverflowNote(txt)
    end

    return true, ctx.getStats(), nil
end

return M

-- #########################################################################
-- END FILE: src/dwkit/ui/ui_row_scaffold.lua
-- #########################################################################
