-- FILE: src/dwkit/ui/chat_manager_ui.lua
-- #########################################################################
-- Module Name : dwkit.ui.chat_manager_ui
-- Owner       : UI
-- Version     : v2026-02-23A
-- Purpose     :
--   - DWKit-native Chat Manager UI (consumer-only).
--   - Provides a visible control surface for chat feature toggles (Phase 2).
--   - Direct-control UI in this delivery (opened via dwchat manager).
--   - No timers, no polling, no gameplay sends.
--
-- Public API:
--   - getVersion() -> string
--   - getState() -> table { visible=bool, activeFeatureKey=string|nil }
--   - show(opts?) / hide(opts?) / toggle(opts?)
--   - refresh(opts?) -> boolean ok
--   - dispose() -> boolean ok
--
-- Notes:
--   - Integration into UI Manager/LaunchPad is intentionally NOT done here
--     (missing raw files). This module is still compliant as a consumer UI.
-- #########################################################################

local M = {}

M.VERSION = "v2026-02-23A"

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
    label = nil,

    btnRow = nil,
    btnApply = nil,
    btnDefaults = nil,
    btnOpenChat = nil,
    btnHideChat = nil,

    featureRows = {},
    lastRendered = "",
}

local function _isNonEmptyString(s) return type(s) == "string" and s ~= "" end

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

local function _fmtBool(v)
    return (v == true) and "ON" or "OFF"
end

local function _safeCeWrite(label, txt)
    if type(label) ~= "table" then return end
    if type(label.echo) == "function" then
        pcall(function() label:echo(txt) end)
    end
end

local function _buildText()
    local cfg = ChatMgr.getConfig()
    local feats = cfg.features or {}
    local lines = {}

    table.insert(lines, "DWKit Chat Manager (SAFE)")
    table.insert(lines, "----------------------------------------")
    table.insert(lines, "Defaults: all features OFF (toggle-first)")
    table.insert(lines, "")
    table.insert(lines, "Features:")

    local list = ChatMgr.listFeatures()
    for _, f in ipairs(list) do
        local key = tostring(f.key)
        local kind = tostring(f.kind or "")
        local val = feats[key]
        local shown = ""

        if kind == "bool" then
            shown = _fmtBool(val == true)
        elseif kind == "number" then
            shown = tostring(val)
        else
            shown = tostring(val)
        end

        table.insert(lines, string.format("- %s = %s", key, shown))
        if _isNonEmptyString(f.description) then
            table.insert(lines, "    " .. tostring(f.description))
        end
    end

    table.insert(lines, "")
    table.insert(lines, "Controls:")
    table.insert(lines, "- Click feature row to toggle (bool) or adjust (number via dwchat feature <key> <value>)")
    table.insert(lines, "- Apply forces a best-effort chat_ui redraw")
    table.insert(lines, "- Defaults resets to manager defaults (all OFF; limit N=500)")

    return ListKit.toPreHtml(table.concat(lines, "\n"))
end

local function _ensureUi(opts)
    if type(st.bundle) == "table" and type(st.bundle.frame) == "table" then
        return true
    end

    opts = (type(opts) == "table") and opts or {}

    st.bundle = UIW.create({
        uiId = UI_ID,
        title = TITLE,
        x = opts.x or 40,
        y = opts.y or 260,
        width = opts.width or 520,
        height = opts.height or 380,
        fixed = (opts.fixed == true),
        noClose = (opts.noClose == true),
        noInsetInside = true,
        padding = 6,
        onClose = function(bundle)
            st.visible = false
            if type(bundle) == "table" and type(bundle.frame) == "table" then
                pcall(function() U.safeHide(bundle.frame, UI_ID, { source = "chat_manager_ui:onClose" }) end)
            end
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

    local function _mkBtn(nameSuffix, x, w, text)
        local btn = G.Label:new({
            name = tostring(st.bundle.meta.nameContent or "__DWKit_chatmgr") .. "__btn__" .. nameSuffix,
            x = x,
            y = 0,
            width = w,
            height = "100%",
        }, st.btnRow)
        BtnKit.applyButtonStyle(btn, { enabled = true, fontPx = 10, padX = 8, padY = 0, minHeightPx = 20 })
        if type(btn.echo) == "function" then pcall(function() btn:echo(text) end) end
        return btn
    end

    st.btnApply = _mkBtn("apply", "0%", "18%", "Apply")
    st.btnDefaults = _mkBtn("defaults", "19%", "18%", "Defaults")
    st.btnOpenChat = _mkBtn("openchat", "38%", "20%", "Open Chat")
    st.btnHideChat = _mkBtn("hidechat", "59%", "20%", "Hide Chat")

    _wireClickBestEffort(st.btnApply, function()
        ChatMgr.applyBestEffort({ source = "chat_manager_ui:apply" })
        M.refresh({ source = "apply_click", force = true })
    end)

    _wireClickBestEffort(st.btnDefaults, function()
        ChatMgr.resetDefaults({ source = "chat_manager_ui:defaults" })
        M.refresh({ source = "defaults_click", force = true })
    end)

    _wireClickBestEffort(st.btnOpenChat, function()
        -- Delegate to dwchat open path (best-effort require of handler module not used here).
        local ok, Cmd = pcall(require, "dwkit.commands.dwchat")
        if ok and type(Cmd) == "table" and type(Cmd.dispatch) == "function" then
            pcall(Cmd.dispatch, { out = function() end }, { "dwchat", "open" })
        else
            local okUI, UI = pcall(require, "dwkit.ui.chat_ui")
            if okUI and type(UI) == "table" and type(UI.show) == "function" then
                pcall(UI.show, { source = "chat_manager_ui:openchat" })
            end
        end
    end)

    _wireClickBestEffort(st.btnHideChat, function()
        local ok, Cmd = pcall(require, "dwkit.commands.dwchat")
        if ok and type(Cmd) == "table" and type(Cmd.dispatch) == "function" then
            pcall(Cmd.dispatch, { out = function() end }, { "dwchat", "hide" })
        else
            local okUI, UI = pcall(require, "dwkit.ui.chat_ui")
            if okUI and type(UI) == "table" and type(UI.hide) == "function" then
                pcall(UI.hide, { source = "chat_manager_ui:hidechat" })
            end
        end
    end)

    st.label = G.Label:new({
        name = tostring(st.bundle.meta.nameContent or "__DWKit_chatmgr") .. "__label",
        x = 6,
        y = 36,
        width = "-12px",
        height = "-42px",
    }, st.panel)

    ListKit.applyTextLabelStyle(st.label)

    return true
end

function M.getVersion()
    return M.VERSION
end

function M.getState()
    return {
        visible = (st.visible == true),
    }
end

function M.show(opts)
    opts = (type(opts) == "table") and opts or {}
    if not _ensureUi(opts) then
        return false, "chat_manager_ui: failed to ensure UI"
    end

    if type(st.bundle) == "table" and type(st.bundle.frame) == "table" then
        pcall(function() U.safeShow(st.bundle.frame, UI_ID, { source = "chat_manager_ui:show" }) end)
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

function M.refresh(opts)
    opts = (type(opts) == "table") and opts or {}
    if st.visible ~= true then return true end

    local html = _buildText()
    if opts.force ~= true and html == st.lastRendered then
        return true
    end
    st.lastRendered = html
    _safeCeWrite(st.label, html)
    return true
end

function M.dispose()
    if type(st.bundle) == "table" and type(st.bundle.frame) == "table" then
        pcall(function() U.safeHide(st.bundle.frame, UI_ID, { source = "chat_manager_ui:dispose" }) end)
        pcall(function() U.safeDelete(st.bundle.frame) end)
    end

    st.bundle = nil
    st.panel = nil
    st.label = nil
    st.btnRow = nil
    st.btnApply = nil
    st.btnDefaults = nil
    st.btnOpenChat = nil
    st.btnHideChat = nil
    st.visible = false

    pcall(U.setUiStateVisibleBestEffort, UI_ID, false)
    return true
end

return M
