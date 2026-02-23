-- FILE: src/dwkit/ui/chat_manager_ui.lua
-- #########################################################################
-- Module Name : dwkit.ui.chat_manager_ui
-- Owner       : UI
-- Version     : v2026-02-23H
-- Purpose     :
--   - DWKit-native Chat Manager UI (consumer-only).
--   - Provides a visible control surface for chat feature toggles (Phase 2).
--   - Direct-control UI (opened via dwchat manager) BUT now also supports UI Manager/LaunchPad
--     by implementing apply() which follows gui_settings enabled/visible.
--   - No timers, no polling, no gameplay sends.
--
-- Public API:
--   - getVersion() -> string
--   - getState() -> table { visible=bool }
--   - show(opts?) / hide(opts?) / toggle(opts?)
--   - apply(opts?) -> boolean ok, string|nil err   (UI Manager / LaunchPad contract)
--   - refresh(opts?) -> boolean ok
--   - dispose() -> boolean ok
--   - getLayoutDebug() -> table (best-effort)
--   - nudge(opts?) -> boolean ok     (best-effort)
--
-- Notes:
--   - Recovery: show({ forcePosition=true }) attempts to move/resize the frame into
--     a known safe on-screen geometry (best-effort).
--   - IMPORTANT: clicking X (window close) best-effort syncs gui_settings.visible=false
--     in-session (noSave) so UI Manager + LaunchPad can re-open deterministically.
--   - NEW v2026-02-23E:
--       * Row-click ergonomics: clicking feature title/desc also triggers toggle (bool) / step (number)
--       * getLayoutDebug() exposes per-row widget presence for deterministic dwverify
--   - NEW v2026-02-23F:
--       * Live readback: refresh always re-reads ChatMgr feature values and updates row widget text
--         even when render signature unchanged (supports external changes via dwchat feature).
--       * Status line: Apply/Defaults feedback with last action + timestamp (SAFE; no timers).
--       * Defaults now applies to chat_ui (apply=true) so user sees effect immediately.
--   - NEW v2026-02-23G:
--       * Deterministic readback: getLayoutDebug() includes per-row last rendered texts
--         (toggleText/valueText) so dwverify can assert live readback without Geyser introspection.
--   - NEW v2026-02-23H:
--       * Bool toggle button text now uses ACTION label semantics (UI Manager style):
--         shows "Enable" when currently OFF, and "Disable" when currently ON.
-- #########################################################################

local M = {}

M.VERSION = "v2026-02-23H"

local UIW = require("dwkit.ui.ui_window")
local U = require("dwkit.ui.ui_base")
local ListKit = require("dwkit.ui.ui_list_kit")
local BtnKit = require("dwkit.ui.ui_button_kit")

local ChatMgr = require("dwkit.services.chat_manager")

local UI_ID = "chat_manager_ui"
local TITLE = "Chat Manager"

local st = {
    visible = false,
    bundle = nil,

    panel = nil,

    btnRow = nil,
    btnApply = nil,
    btnDefaults = nil,
    btnOpenChat = nil,
    btnHideChat = nil,

    statusLabel = nil,
    lastStatusTs = nil,
    lastStatusMsg = "",

    listRoot = nil,
    rows = {},

    helpLabel = nil,

    lastRenderedSig = "",
    lastShowAt = nil,
    lastShowOpts = nil,
    lastEnsureOpts = nil,
    lastNudgeAt = nil,
}

local function _nowTs()
    return (type(os) == "table" and type(os.time) == "function") and os.time() or 0
end

local function _fmtHMS(ts)
    ts = tonumber(ts)
    if not ts or ts <= 0 then return nil end
    if type(os) ~= "table" or type(os.date) ~= "function" then return nil end
    local ok, s = pcall(os.date, "%H:%M:%S", ts)
    if ok and type(s) == "string" then return s end
    return nil
end

local function _num(v)
    v = tonumber(v)
    return (v and v > 0) and v or nil
end

local function _getGuiSettingsBestEffort()
    if type(_G.DWKit) == "table"
        and type(_G.DWKit.config) == "table"
        and type(_G.DWKit.config.guiSettings) == "table"
    then
        return _G.DWKit.config.guiSettings
    end
    local ok, GS = pcall(require, "dwkit.config.gui_settings")
    if ok and type(GS) == "table" then return GS end
    return nil
end

local function _ensureVisiblePersistenceSession(gs)
    if type(gs) ~= "table" or type(gs.enableVisiblePersistence) ~= "function" then
        return true
    end
    pcall(gs.enableVisiblePersistence, { noSave = true })
    return true
end

local function _wireClickBestEffort(labelObj, fn)
    if type(labelObj) ~= "table" or type(fn) ~= "function" then return false end
    local wired = false
    if type(labelObj.setClickCallback) == "function" then
        local ok = pcall(function() labelObj:setClickCallback(fn) end)
        wired = wired or (ok == true)
    end
    if not wired then
        local name = tostring(labelObj.name or "")
        if name ~= "" and type(_G.setLabelClickCallback) == "function" then
            local ok = pcall(function() _G.setLabelClickCallback(name, fn) end)
            wired = wired or (ok == true)
        end
    end
    return wired
end

-- ACTION label semantics (UI Manager style): show what clicking will do.
local function _fmtToggleAction(curEnabled)
    return (curEnabled == true) and "Disable" or "Enable"
end

local function _safeEcho(label, txt)
    if type(label) ~= "table" then return false end
    if type(label.echo) ~= "function" then return false end
    local ok = pcall(function() label:echo(tostring(txt or "")) end)
    return ok == true
end

local function _safeDelete(obj)
    if type(obj) ~= "table" then return false end
    if type(obj.delete) == "function" then
        pcall(function() obj:delete() end)
        return true
    end
    return false
end

local function _getWHBestEffort(obj)
    if type(obj) ~= "table" then return nil, nil end
    local w, h

    for _, fn in ipairs({ "get_width", "getWidth", "width" }) do
        if type(obj[fn]) == "function" then
            local ok, v = pcall(function() return obj[fn](obj) end)
            if ok then
                w = _num(v)
                break
            end
        end
    end

    for _, fn in ipairs({ "get_height", "getHeight", "height" }) do
        if type(obj[fn]) == "function" then
            local ok, v = pcall(function() return obj[fn](obj) end)
            if ok then
                h = _num(v)
                break
            end
        end
    end

    return w, h
end

local function _moveResizeBestEffort(obj, x, y, w, h)
    if type(obj) ~= "table" then return false end
    local okAny = false

    if type(obj.move) == "function" then
        local ok = pcall(function() obj:move(tonumber(x) or 0, tonumber(y) or 0) end)
        okAny = okAny or ok
    elseif type(obj.setPosition) == "function" then
        local ok = pcall(function() obj:setPosition(tonumber(x) or 0, tonumber(y) or 0) end)
        okAny = okAny or ok
    end

    if type(obj.resize) == "function" then
        local ok = pcall(function() obj:resize(tonumber(w) or 0, tonumber(h) or 0) end)
        okAny = okAny or ok
    elseif type(obj.setSize) == "function" then
        local ok = pcall(function() obj:setSize(tonumber(w) or 0, tonumber(h) or 0) end)
        okAny = okAny or ok
    end

    return okAny
end

local function _bringToFrontBestEffort(obj)
    if type(obj) ~= "table" then return false end
    for _, fn in ipairs({ "raise", "raise_", "bringToFront", "activateWindow", "setFocus", "show" }) do
        if type(obj[fn]) == "function" then
            pcall(function() obj[fn](obj) end)
        end
    end
    return true
end

local function _nudgeToSafeGeometryBestEffort(opts)
    opts = (type(opts) == "table") and opts or {}
    if type(st.bundle) ~= "table" or type(st.bundle.frame) ~= "table" then return false end

    local x = tonumber(opts.x) or 40
    local y = tonumber(opts.y) or 40
    local w = tonumber(opts.width) or 560
    local h = tonumber(opts.height) or 420

    if w < 320 then w = 320 end
    if h < 240 then h = 240 end
    if w > 1400 then w = 1400 end
    if h > 1000 then h = 1000 end

    st.lastNudgeAt = _nowTs()

    local ok = _moveResizeBestEffort(st.bundle.frame, x, y, w, h)
    _bringToFrontBestEffort(st.bundle.frame)
    return ok
end

local function _applyRowContainerStyle(c, alt)
    if type(c) ~= "table" or type(c.setStyleSheet) ~= "function" then return false end
    local css
    if alt == true then
        css = [[
            background-color: rgba(255,255,255,0.04);
            border: 1px solid rgba(255,255,255,0.08);
            border-radius: 6px;
        ]]
    else
        css = [[
            background-color: rgba(255,255,255,0.02);
            border: 1px solid rgba(255,255,255,0.08);
            border-radius: 6px;
        ]]
    end
    pcall(function() c:setStyleSheet(css) end)
    return true
end

local function _clearFeatureRows()
    for _, row in ipairs(st.rows or {}) do
        if type(row) == "table" and row.container then
            _safeDelete(row.container)
        end
    end
    st.rows = {}
end

local function _calcRenderSig(cfg)
    cfg = (type(cfg) == "table") and cfg or {}
    local feats = (type(cfg.features) == "table") and cfg.features or {}
    local parts = {}
    parts[#parts + 1] = tostring(cfg.version or "")
    local keys = {}
    for k, _ in pairs(feats) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    for _, k in ipairs(keys) do
        parts[#parts + 1] = k .. "=" .. tostring(feats[k])
    end
    return table.concat(parts, "|")
end

local function _mkLabel(parent, name, x, y, w, h, styleFn)
    local G = _G.Geyser
    if type(G) ~= "table" then return nil end
    local lbl = G.Label:new({ name = name, x = x, y = y, width = w, height = h }, parent)
    if type(styleFn) == "function" then pcall(styleFn, lbl) end
    return lbl
end

local function _mkBtn(parent, name, x, y, w, h, text, enabled)
    local G = _G.Geyser
    if type(G) ~= "table" then return nil end
    local btn = G.Label:new({ name = name, x = x, y = y, width = w, height = h }, parent)
    BtnKit.applyButtonStyle(btn, { enabled = (enabled ~= false), fontPx = 10, padX = 8, padY = 0, minHeightPx = 22 })
    _safeEcho(btn, tostring(text or ""))
    return btn
end

local function _setStatus(msg)
    msg = tostring(msg or "")
    st.lastStatusTs = _nowTs()
    st.lastStatusMsg = msg

    if type(st.statusLabel) ~= "table" then return end
    local ts = _fmtHMS(st.lastStatusTs) or ""
    local line = msg
    if ts ~= "" then
        line = string.format("%s  [%s]", msg, ts)
    end

    _safeEcho(st.statusLabel, ListKit.toPreHtml(line))
end

local function _renderHelp()
    if type(st.helpLabel) ~= "table" then return end
    local lines = {}
    lines[#lines + 1] = "DWKit Chat Manager (SAFE)"
    lines[#lines + 1] = "----------------------------------------"
    lines[#lines + 1] = "Defaults: all features OFF (toggle-first)"
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Controls:"
    lines[#lines + 1] = "- Bool: click Enable/Disable (or click the feature text)"
    lines[#lines + 1] = "- Number: use - / + (or click the feature text to +step)"
    lines[#lines + 1] = "- Apply: best-effort redraw chat_ui"
    lines[#lines + 1] = "- Defaults: reset to OFF (limit N=500) + apply"
    _safeEcho(st.helpLabel, ListKit.toPreHtml(table.concat(lines, "\n")))
end

local function _echoRemember(row, field, widget, txt)
    txt = tostring(txt or "")
    _safeEcho(widget, txt)
    if type(row) == "table" then
        row[field] = txt
    end
    return true
end

local function _toggleBoolFeature(key)
    key = tostring(key or "")
    if key == "" then return false end
    local cur = (ChatMgr.getFeature(key) == true)
    local after = (not cur) == true
    ChatMgr.setFeature(key, after, { source = "chat_manager_ui:toggle:" .. key, apply = true })
    _setStatus("Set " .. key .. " => " .. (after and "ENABLED" or "DISABLED"))
    M.refresh({ source = "toggle", force = false })
    return true
end

local function _stepNumberFeature(key, delta)
    key = tostring(key or "")
    delta = tonumber(delta) or 0
    if key == "" or delta == 0 then return false end
    local cur = tonumber(ChatMgr.getFeature(key)) or 0
    ChatMgr.setFeature(key, cur + delta, { source = "chat_manager_ui:step:" .. key, apply = true })
    local after = tonumber(ChatMgr.getFeature(key)) or (cur + delta)
    _setStatus("Set " .. key .. " => " .. tostring(after))
    M.refresh({ source = "step", force = false })
    return true
end

-- Live readback: update row widget text from ChatMgr current state even if signature unchanged.
local function _syncRowValuesBestEffort()
    if type(st.rows) ~= "table" then return true end

    for i = 1, #st.rows do
        local r = st.rows[i]
        if type(r) == "table" then
            local key = tostring(r.key or "")
            local kind = tostring(r.kind or "")
            if key ~= "" then
                if kind == "bool" then
                    if type(r.btnToggle) == "table" then
                        local cur = (ChatMgr.getFeature(key) == true)
                        _echoRemember(r, "_lastToggleText", r.btnToggle, _fmtToggleAction(cur))
                    end
                elseif kind == "number" then
                    if type(r.valueLabel) == "table" then
                        local cur = tonumber(ChatMgr.getFeature(key)) or 0
                        _echoRemember(r, "_lastValueText", r.valueLabel, tostring(cur))
                    end
                else
                    if type(r.valueLabel) == "table" then
                        local v = ChatMgr.getFeature(key)
                        if v ~= nil then
                            _echoRemember(r, "_lastValueText", r.valueLabel, tostring(v))
                        end
                    end
                end
            end
        end
    end

    return true
end

local function _renderFeatureRows(force)
    if st.visible ~= true then return true end
    if type(st.listRoot) ~= "table" then return true end

    local cfg = ChatMgr.getConfig()
    local sig = _calcRenderSig(cfg)

    if force ~= true and sig == st.lastRenderedSig then
        -- Signature unchanged: still do live readback so UI reflects external changes.
        _syncRowValuesBestEffort()
        _renderHelp()
        return true
    end

    st.lastRenderedSig = sig

    _clearFeatureRows()

    local feats = cfg.features or {}
    local list = ChatMgr.listFeatures()

    local rowH = 44
    local y = 0

    for i = 1, #list do
        local f = list[i]
        local key = tostring(f.key or "")
        local title = tostring(f.title or key)
        local desc = tostring(f.description or "")
        local kind = tostring(f.kind or "")

        local val = feats[key]
        local alt = ((i % 2) == 0)

        local G = _G.Geyser
        local row = { key = key, kind = kind, _lastToggleText = "", _lastValueText = "" }

        row.container = G.Container:new({
            name = tostring(st.bundle.meta.nameContent or "__DWKit_chatmgr") .. "__row__" .. key,
            x = 0,
            y = y,
            width = "100%",
            height = rowH,
        }, st.listRoot)

        _applyRowContainerStyle(row.container, alt)

        row.titleLabel = _mkLabel(
            row.container,
            tostring(st.bundle.meta.nameContent or "__DWKit_chatmgr") .. "__lbl__title__" .. key,
            10, 4, "-210px", 18,
            function(lbl) ListKit.applyRowTextStyle(lbl) end
        )

        row.descLabel = _mkLabel(
            row.container,
            tostring(st.bundle.meta.nameContent or "__DWKit_chatmgr") .. "__lbl__desc__" .. key,
            10, 22, "-210px", 18,
            function(lbl)
                if type(lbl) == "table" and type(lbl.setStyleSheet) == "function" then
                    local css = [[
                        background-color: rgba(0,0,0,0);
                        border: 0px;
                        color: rgba(229,233,240,0.80);
                        padding: 0px 6px;
                        margin: 0px;
                        font-size: 9pt;
                        qproperty-alignment: 'AlignVCenter | AlignLeft';
                    ]]
                    pcall(function() lbl:setStyleSheet(css) end)
                else
                    pcall(ListKit.applyRowTextStyle, lbl)
                end
            end
        )

        _safeEcho(row.titleLabel, string.format("%s  (%s)", title, key))
        _safeEcho(row.descLabel, desc)

        if kind == "bool" then
            local curEnabled = (val == true)
            row.btnToggle = _mkBtn(
                row.container,
                tostring(st.bundle.meta.nameContent or "__DWKit_chatmgr") .. "__btn__" .. key,
                "-180px", 10, "80px", 24,
                _fmtToggleAction(curEnabled),
                true
            )
            row._lastToggleText = _fmtToggleAction(curEnabled)

            local function _onToggle()
                _toggleBoolFeature(key)
            end

            _wireClickBestEffort(row.btnToggle, _onToggle)
            _wireClickBestEffort(row.titleLabel, _onToggle)
            _wireClickBestEffort(row.descLabel, _onToggle)

            row.valueLabel = _mkLabel(
                row.container,
                tostring(st.bundle.meta.nameContent or "__DWKit_chatmgr") .. "__val__" .. key,
                "-90px", 10, "80px", 24,
                function(lbl)
                    local css = [[
                        background-color: rgba(0,0,0,0);
                        border: 0px;
                        color: rgba(229,233,240,0.90);
                        padding: 0px 6px;
                        margin: 0px;
                        font-size: 10pt;
                        qproperty-alignment: 'AlignVCenter | AlignLeft';
                    ]]
                    pcall(function() lbl:setStyleSheet(css) end)
                end
            )
            _safeEcho(row.valueLabel, "")
        elseif kind == "number" then
            local n = tonumber(val) or 0

            row.btnMinus = _mkBtn(
                row.container,
                tostring(st.bundle.meta.nameContent or "__DWKit_chatmgr") .. "__btn__minus__" .. key,
                "-190px", 10, "40px", 24,
                "-",
                true
            )
            row.btnPlus = _mkBtn(
                row.container,
                tostring(st.bundle.meta.nameContent or "__DWKit_chatmgr") .. "__btn__plus__" .. key,
                "-140px", 10, "40px", 24,
                "+",
                true
            )

            row.valueLabel = _mkLabel(
                row.container,
                tostring(st.bundle.meta.nameContent or "__DWKit_chatmgr") .. "__val__" .. key,
                "-90px", 10, "80px", 24,
                function(lbl)
                    local css = [[
                        background-color: rgba(0,0,0,0);
                        border: 0px;
                        color: rgba(229,233,240,0.90);
                        padding: 0px 6px;
                        margin: 0px;
                        font-size: 10pt;
                        qproperty-alignment: 'AlignVCenter | AlignLeft';
                    ]]
                    pcall(function() lbl:setStyleSheet(css) end)
                end
            )
            _echoRemember(row, "_lastValueText", row.valueLabel, tostring(n))

            local step = 50

            _wireClickBestEffort(row.btnMinus, function() _stepNumberFeature(key, -step) end)
            _wireClickBestEffort(row.btnPlus, function() _stepNumberFeature(key, step) end)

            _wireClickBestEffort(row.titleLabel, function() _stepNumberFeature(key, step) end)
            _wireClickBestEffort(row.descLabel, function() _stepNumberFeature(key, step) end)
        else
            row.valueLabel = _mkLabel(
                row.container,
                tostring(st.bundle.meta.nameContent or "__DWKit_chatmgr") .. "__val__" .. key,
                "-120px", 10, "110px", 24,
                function(lbl) ListKit.applyRowTextStyle(lbl) end
            )
            _echoRemember(row, "_lastValueText", row.valueLabel, tostring(val))
        end

        st.rows[#st.rows + 1] = row
        y = y + rowH + 6
    end

    _renderHelp()
    _syncRowValuesBestEffort()
    return true
end

local function _syncGuiSettingsVisibleOffNoSaveBestEffort()
    local gs = _getGuiSettingsBestEffort()
    if type(gs) ~= "table" or type(gs.setVisible) ~= "function" then
        return false
    end
    _ensureVisiblePersistenceSession(gs)
    pcall(gs.setVisible, UI_ID, false, { noSave = true })
    return true
end

local function _ensureUi(opts)
    if type(st.bundle) == "table" and type(st.bundle.frame) == "table" then
        return true
    end

    opts = (type(opts) == "table") and opts or {}
    st.lastEnsureOpts = opts

    st.bundle = UIW.create({
        uiId = UI_ID,
        title = TITLE,
        x = opts.x or 40,
        y = opts.y or 260,
        width = opts.width or 560,
        height = opts.height or 420,
        fixed = (opts.fixed == true),
        noClose = (opts.noClose == true),
        noInsetInside = true,
        padding = 6,
        onClose = function(bundle)
            st.visible = false
            pcall(_syncGuiSettingsVisibleOffNoSaveBestEffort)
            if type(bundle) == "table" and type(bundle.frame) == "table" then
                pcall(function() U.safeHide(bundle.frame, UI_ID, { source = "chat_manager_ui:onClose" }) end)
            end
            pcall(U.setUiStateVisibleBestEffort, UI_ID, false)
        end,
    })

    if type(st.bundle) ~= "table" or type(st.bundle.content) ~= "table" then
        st.bundle = nil
        return false
    end

    local G = _G.Geyser
    if type(G) ~= "table" then
        st.bundle = nil
        return false
    end

    st.panel = G.Container:new({
        name = tostring(st.bundle.meta.nameContent or "__DWKit_chatmgr") .. "__panel",
        x = 0,
        y = 0,
        width = "100%",
        height = "100%",
    }, st.bundle.content)

    ListKit.applyPanelStyle(st.panel)

    st.btnRow = G.Container:new({
        name = tostring(st.bundle.meta.nameContent or "__DWKit_chatmgr") .. "__btnRow",
        x = 6,
        y = 6,
        width = "-12px",
        height = 24,
    }, st.panel)

    local function _mkTopBtn(nameSuffix, x, w, text)
        local btn = G.Label:new({
            name = tostring(st.bundle.meta.nameContent or "__DWKit_chatmgr") .. "__btn__" .. nameSuffix,
            x = x,
            y = 0,
            width = w,
            height = "100%",
        }, st.btnRow)
        BtnKit.applyButtonStyle(btn, { enabled = true, fontPx = 10, padX = 8, padY = 0, minHeightPx = 20 })
        _safeEcho(btn, text)
        return btn
    end

    st.btnApply = _mkTopBtn("apply", "0%", "18%", "Apply")
    st.btnDefaults = _mkTopBtn("defaults", "19%", "18%", "Defaults")
    st.btnOpenChat = _mkTopBtn("openchat", "38%", "20%", "Open Chat")
    st.btnHideChat = _mkTopBtn("hidechat", "59%", "20%", "Hide Chat")

    -- Status line (below top buttons)
    st.statusLabel = G.Label:new({
        name = tostring(st.bundle.meta.nameContent or "__DWKit_chatmgr") .. "__status",
        x = 6,
        y = 32,
        width = "-12px",
        height = 18,
    }, st.panel)
    ListKit.applyTextLabelStyle(st.statusLabel)
    pcall(function()
        if type(st.statusLabel.setStyleSheet) == "function" then
            st.statusLabel:setStyleSheet([[
                background-color: rgba(0,0,0,0);
                border: 0px;
                color: #8b93a6;
                padding: 0px 8px;
                font-size: 8pt;
                qproperty-alignment: 'AlignVCenter | AlignLeft';
            ]])
        end
    end)
    _setStatus("Ready")

    _wireClickBestEffort(st.btnApply, function()
        local ok = ChatMgr.applyBestEffort({ source = "chat_manager_ui:apply" })
        if ok == false then
            _setStatus("Apply: chat_ui not available")
        else
            _setStatus("Applied to chat_ui")
        end
        M.refresh({ source = "apply_click", force = false })
    end)

    _wireClickBestEffort(st.btnDefaults, function()
        local okD = ChatMgr.resetDefaults({ source = "chat_manager_ui:defaults", apply = true })
        if okD == false then
            _setStatus("Defaults: applied (best-effort)")
        else
            _setStatus("Defaults applied to chat_ui")
        end
        M.refresh({ source = "defaults_click", force = true })
    end)

    _wireClickBestEffort(st.btnOpenChat, function()
        local ok, Cmd = pcall(require, "dwkit.commands.dwchat")
        if ok and type(Cmd) == "table" and type(Cmd.dispatch) == "function" then
            pcall(Cmd.dispatch, { out = function() end }, { "dwchat", "open" })
            _setStatus("Open Chat: requested")
        else
            local okUI, UI = pcall(require, "dwkit.ui.chat_ui")
            if okUI and type(UI) == "table" and type(UI.show) == "function" then
                pcall(UI.show, { source = "chat_manager_ui:openchat" })
                _setStatus("Open Chat: shown")
            else
                _setStatus("Open Chat: chat_ui not available")
            end
        end
    end)

    _wireClickBestEffort(st.btnHideChat, function()
        local ok, Cmd = pcall(require, "dwkit.commands.dwchat")
        if ok and type(Cmd) == "table" and type(Cmd.dispatch) == "function" then
            pcall(Cmd.dispatch, { out = function() end }, { "dwchat", "hide" })
            _setStatus("Hide Chat: requested")
        else
            local okUI, UI = pcall(require, "dwkit.ui.chat_ui")
            if okUI and type(UI) == "table" and type(UI.hide) == "function" then
                pcall(UI.hide, { source = "chat_manager_ui:hidechat" })
                _setStatus("Hide Chat: hidden")
            else
                _setStatus("Hide Chat: chat_ui not available")
            end
        end
    end)

    st.listRoot = G.Container:new({
        name = tostring(st.bundle.meta.nameContent or "__DWKit_chatmgr") .. "__listRoot",
        x = 6,
        y = 54,
        width = "-12px",
        height = "-128px",
    }, st.panel)

    pcall(function() ListKit.applyListRootStyle(st.listRoot) end)

    st.helpLabel = G.Label:new({
        name = tostring(st.bundle.meta.nameContent or "__DWKit_chatmgr") .. "__help",
        x = 6,
        y = "-68px",
        width = "-12px",
        height = "62px",
    }, st.panel)

    ListKit.applyTextLabelStyle(st.helpLabel)

    return true
end

function M.getVersion()
    return M.VERSION
end

function M.getState()
    return { visible = (st.visible == true) }
end

function M.getLayoutDebug()
    local b = st.bundle
    local meta = (type(b) == "table" and type(b.meta) == "table") and b.meta or {}
    local frame = (type(b) == "table") and b.frame or nil
    local content = (type(b) == "table") and b.content or nil

    local fw, fh = _getWHBestEffort(frame)
    local cw, ch = _getWHBestEffort(content)

    local rowKeys = {}
    local rowWidgets = {}
    if type(st.rows) == "table" then
        for i = 1, #st.rows do
            local r = st.rows[i]
            local k = tostring((type(r) == "table" and r.key) or "")
            if k ~= "" then
                rowKeys[#rowKeys + 1] = k
                rowWidgets[k] = {
                    kind = tostring((type(r) == "table" and r.kind) or ""),
                    hasContainer = (type(r) == "table" and type(r.container) == "table") or false,
                    hasTitleLabel = (type(r) == "table" and type(r.titleLabel) == "table") or false,
                    hasDescLabel = (type(r) == "table" and type(r.descLabel) == "table") or false,
                    hasToggle = (type(r) == "table" and type(r.btnToggle) == "table") or false,
                    hasMinus = (type(r) == "table" and type(r.btnMinus) == "table") or false,
                    hasPlus = (type(r) == "table" and type(r.btnPlus) == "table") or false,
                    hasValueLabel = (type(r) == "table" and type(r.valueLabel) == "table") or false,

                    -- Deterministic readback fields:
                    toggleText = tostring((type(r) == "table" and r._lastToggleText) or ""),
                    valueText = tostring((type(r) == "table" and r._lastValueText) or ""),
                }
            end
        end
    end
    table.sort(rowKeys)

    return {
        uiId = UI_ID,
        version = M.VERSION,
        visible = (st.visible == true),

        bundleOk = (type(b) == "table"),
        hasFrame = (type(frame) == "table"),
        hasContent = (type(content) == "table"),
        hasListRoot = (type(st.listRoot) == "table"),
        hasHelpLabel = (type(st.helpLabel) == "table"),
        hasStatusLabel = (type(st.statusLabel) == "table"),

        names = {
            nameFrame = tostring(meta.nameFrame or ""),
            nameContent = tostring(meta.nameContent or ""),
        },

        sizes = {
            frameW = fw,
            frameH = fh,
            contentW = cw,
            contentH = ch,
        },

        rowCount = (type(st.rows) == "table") and #st.rows or 0,
        rowKeys = rowKeys,
        rowWidgets = rowWidgets,

        status = {
            ts = st.lastStatusTs,
            msg = st.lastStatusMsg,
        },

        lastShowAt = st.lastShowAt,
        lastShowOpts = st.lastShowOpts,
        lastEnsureOpts = st.lastEnsureOpts,
        lastNudgeAt = st.lastNudgeAt,
    }
end

function M.nudge(opts)
    return _nudgeToSafeGeometryBestEffort(opts)
end

function M.show(opts)
    opts = (type(opts) == "table") and opts or {}
    st.lastShowAt = _nowTs()
    st.lastShowOpts = opts

    if not _ensureUi(opts) then
        return false, "chat_manager_ui: failed to ensure UI"
    end

    if opts.forcePosition == true or opts.forceReposition == true then
        pcall(_nudgeToSafeGeometryBestEffort, {
            x = opts.x or 40,
            y = opts.y or 40,
            width = opts.width or 560,
            height = opts.height or 420,
        })
    end

    if type(st.bundle) == "table" and type(st.bundle.frame) == "table" then
        pcall(function() U.safeShow(st.bundle.frame, UI_ID, { source = "chat_manager_ui:show" }) end)
        if opts.bringToFront == true then
            pcall(_bringToFrontBestEffort, st.bundle.frame)
        end
    end

    st.visible = true
    pcall(U.setUiStateVisibleBestEffort, UI_ID, true)

    M.refresh({ source = "show", force = true })
    return true
end

function M.hide(opts)
    opts = (type(opts) == "table") and opts or {}
    if type(st.bundle) == "table" and type(st.bundle.frame) == "table" then
        pcall(function() U.safeHide(st.bundle.frame, UI_ID, { source = "chat_manager_ui:hide" }) end)
    end
    st.visible = false
    pcall(U.setUiStateVisibleBestEffort, UI_ID, false)
    return true
end

function M.toggle(opts)
    if st.visible == true then
        return M.hide(opts)
    end
    return M.show(opts)
end

function M.apply(opts)
    opts = (type(opts) == "table") and opts or {}

    local gs = _getGuiSettingsBestEffort()
    if type(gs) ~= "table" then
        local ok, err = M.show({ source = opts.source or "chat_manager_ui:apply_fallback", bringToFront = true })
        if not ok then return false, err end
        return true, nil
    end

    _ensureVisiblePersistenceSession(gs)

    local enabled = false
    if type(gs.isEnabled) == "function" then
        local okE, v = pcall(gs.isEnabled, UI_ID, false)
        if okE then enabled = (v == true) end
    end

    if enabled ~= true then
        pcall(M.hide, { source = opts.source or "chat_manager_ui:apply_disabled" })
        return true, nil
    end

    local visible = false
    if type(gs.getVisible) == "function" then
        local okV, v = pcall(gs.getVisible, UI_ID, false)
        if okV then visible = (v == true) end
    elseif type(gs.isVisible) == "function" then
        local okV, v = pcall(gs.isVisible, UI_ID, false)
        if okV then visible = (v == true) end
    end

    if visible == true then
        local ok, err = M.show({
            source = opts.source or "chat_manager_ui:apply_show",
            bringToFront = true,
        })
        if not ok then return false, err end
        return true, nil
    end

    pcall(M.hide, { source = opts.source or "chat_manager_ui:apply_hide" })
    return true, nil
end

function M.refresh(opts)
    opts = (type(opts) == "table") and opts or {}
    if st.visible ~= true then return true end
    return _renderFeatureRows(opts.force == true)
end

function M.dispose()
    _clearFeatureRows()

    if type(st.bundle) == "table" and type(st.bundle.frame) == "table" then
        pcall(function() U.safeHide(st.bundle.frame, UI_ID, { source = "chat_manager_ui:dispose" }) end)
        pcall(function() U.safeDelete(st.bundle.frame) end)
    end

    st.bundle = nil
    st.panel = nil

    st.btnRow = nil
    st.btnApply = nil
    st.btnDefaults = nil
    st.btnOpenChat = nil
    st.btnHideChat = nil

    st.statusLabel = nil
    st.lastStatusTs = nil
    st.lastStatusMsg = ""

    st.listRoot = nil
    st.helpLabel = nil

    st.visible = false
    st.lastRenderedSig = ""

    pcall(U.setUiStateVisibleBestEffort, UI_ID, false)
    return true
end

return M
