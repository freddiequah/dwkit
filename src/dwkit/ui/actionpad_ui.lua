-- FILE: src/dwkit/ui/actionpad_ui.lua
-- #########################################################################
-- Module Name : dwkit.ui.actionpad_ui
-- Owner       : UI
-- Version     : v2026-03-04F
-- Purpose     :
--   - ActionPad UI (MVP): online-only owned roster view with PLAN-only test buttons.
--   - Consumes ActionPadService rowsOnlineOnly.
--   - SAFE: does NOT send gameplay commands. Buttons only print computed plans.
--   - Follows UI contracts: shared frame (ui_window + ui_theme) + content kits.
--
-- Public API  :
--   - apply(opts?) -> boolean ok, string|nil err
--   - getState() -> table (diagnostics)
--
-- Events Emitted   : None (UI consumer only)
-- Events Consumed  :
--   - DWKit:Service:ActionPad:Updated (via ActionPadService.onUpdated)
-- Persistence     : UI geometry only (handled by ui_window Adjustable autosave)
-- Automation Policy: Manual only
-- Dependencies     :
--   - dwkit.ui.ui_base, dwkit.ui.ui_window, dwkit.ui.ui_list_kit, dwkit.ui.ui_button_kit
--   - dwkit.services.actionpad_service
-- #########################################################################

local M = {}

M.VERSION = "v2026-03-04F"
M.UI_ID = "actionpad_ui"

local U = require("dwkit.ui.ui_base")
local W = require("dwkit.ui.ui_window")
local ListKit = require("dwkit.ui.ui_list_kit")
local ButtonKit = require("dwkit.ui.ui_button_kit")

local okG, G = pcall(rawget, _G, "Geyser")
if not okG then G = nil end

local _state = {
    enabled = true,
    visible = false,
    runtimeVisible = false,
    inited = false,
    lastError = nil,
    lastApplySource = nil,
    lastRender = nil,
    sub = nil,
    widgets = {
        bundle = nil,
        listRoot = nil,
        header = nil,
        status = nil,
        rows = {},
    },
}

local function _safeDelete(w)
    pcall(function() U.safeDelete(w) end)
end

local function _clearRows()
    local rows = _state.widgets.rows or {}
    for i = 1, #rows do
        local r = rows[i]
        if type(r) == "table" then
            _safeDelete(r.nameLabel)
            _safeDelete(r.btnSay)
            _safeDelete(r.btnHeal)
        end
    end
    _state.widgets.rows = {}
end

local function _ensureCreated()
    if _state.widgets.bundle and type(_state.widgets.bundle.frame) == "table" then
        return true, nil
    end

    if type(G) ~= "table" then
        return false, "Geyser not available"
    end

    local bundle = W.create({
        uiId = M.UI_ID,
        title = "ActionPad",
        x = 450,
        y = 60,
        width = 420,
        height = 320,
        padding = 6,
        onClose = function(b)
            if type(b) == "table" and type(b.frame) == "table" then
                U.safeHide(b.frame)
            end
        end,
    })

    if type(bundle) ~= "table" or type(bundle.frame) ~= "table" or type(bundle.content) ~= "table" then
        return false, "ui_window.create returned invalid bundle"
    end

    -- Panel style
    pcall(ListKit.applyPanelStyle, bundle.content)

    local listRoot = G.Container:new({
        name = "DWKit_ActionPad_ListRoot",
        x = "0px",
        y = "0px",
        width = "100%",
        height = "100%",
    }, bundle.content)

    if type(listRoot) ~= "table" then
        return false, "failed to create listRoot"
    end

    pcall(ListKit.applyListRootStyle, listRoot)

    local header = G.Label:new({
        name = "DWKit_ActionPad_Header",
        x = "0px",
        y = "0px",
        width = "100%",
        height = "24px",
    }, listRoot)

    if type(header) == "table" then
        pcall(function() header:echo(ListKit.toPreHtml("ActionPad (MVP) — online-only roster (PLAN only)")) end)
        pcall(ListKit.applySectionHeaderStyle, header)
    end

    local status = G.Label:new({
        name = "DWKit_ActionPad_Status",
        x = "0px",
        y = "-26px",
        width = "100%",
        height = "26px",
    }, listRoot)

    if type(status) == "table" then
        pcall(function() status:echo(ListKit.toPreHtml("Ready.")) end)
        pcall(ListKit.applyRowTextStyle, status)
    end

    _state.widgets.bundle = bundle
    _state.widgets.listRoot = listRoot
    _state.widgets.header = header
    _state.widgets.status = status
    _state.inited = true

    return true, nil
end

local function _setStatusLine(text)
    local s = _state.widgets.status
    if type(s) == "table" and type(s.echo) == "function" then
        pcall(function() s:echo(ListKit.toPreHtml(tostring(text or ""))) end)
    end
end

local function _planSay(rowName)
    local okA, A = pcall(require, "dwkit.services.actionpad_service")
    if not okA or type(A) ~= "table" then
        return false, "ActionPadService missing"
    end

    local plan, err = A.planSelfExec(tostring(rowName or ""), "say [DWKit] ActionPad test",
        { source = "actionpad_ui:planSay" })
    if not plan then
        return false, tostring(err or "planSelfExec failed")
    end

    local line = string.format("[ActionPad] PLAN selfExec targetProfile=%s cmd=%s",
        tostring(plan.targetProfile), tostring(plan.cmd))
    print(line)
    _setStatusLine(line)
    return true, nil
end

local function _planHeal(healerName, targetName)
    local okA, A = pcall(require, "dwkit.services.actionpad_service")
    if not okA or type(A) ~= "table" then
        return false, "ActionPadService missing"
    end

    healerName = tostring(healerName or "")
    targetName = tostring(targetName or "")

    if healerName == "" then
        return false, "healerName missing"
    end
    if targetName == "" then
        return false, "targetName missing"
    end

    local plan, err = A.planAssistExec(healerName, targetName, "cast heal {target}", { source = "actionpad_ui:planHeal" })
    if not plan then
        return false, tostring(err or "planAssistExec failed")
    end

    local line = string.format("[ActionPad] PLAN assistExec targetProfile=%s cmd=%s",
        tostring(plan.targetProfile), tostring(plan.cmd))
    print(line)
    _setStatusLine(line)
    return true, nil
end

local function _render()
    local okA, A = pcall(require, "dwkit.services.actionpad_service")
    if not okA or type(A) ~= "table" or type(A.getRowsOnlineOnly) ~= "function" then
        _setStatusLine("ActionPadService not available.")
        return false, "ActionPadService not available"
    end

    local rows = A.getRowsOnlineOnly() or {}

    _clearRows()

    local padY = 6
    local rowH = 26
    local btnW = 54
    local gap = 4
    local topY = 24 + padY + 2 -- below header

    for i = 1, #rows do
        local r = rows[i] or {}
        local name = tostring(r.name or "?")
        local profileLabel = tostring(r.profileLabel or "?")
        local here = (r.here == true)

        local y = topY + (i - 1) * (rowH + gap)

        local nameLabel = G.Label:new({
            name = "DWKit_ActionPad_RowName_" .. tostring(i),
            x = "0px",
            y = tostring(y) .. "px",
            width = string.format("-%dpx", (btnW * 2) + (gap * 2)),
            height = tostring(rowH) .. "px",
        }, _state.widgets.listRoot)

        if type(nameLabel) == "table" then
            local txt = string.format("%s  (%s)%s", name, profileLabel, here and "  [HERE]" or "")
            pcall(function() nameLabel:echo(ListKit.toPreHtml(txt)) end)
            pcall(ListKit.applyRowTextStyle, nameLabel)
        end

        local btnSay = G.Label:new({
            name = "DWKit_ActionPad_BtnSay_" .. tostring(i),
            x = string.format("-%dpx", (btnW * 2) + gap),
            y = tostring(y) .. "px",
            width = tostring(btnW) .. "px",
            height = tostring(rowH) .. "px",
        }, _state.widgets.listRoot)

        if type(btnSay) == "table" then
            pcall(function() btnSay:echo("SAY") end)
            pcall(ButtonKit.applyButtonStyle, btnSay, { enabled = true, minHeightPx = rowH })
            pcall(ButtonKit.wireClick, btnSay, function()
                local ok, err = _planSay(name)
                if not ok then
                    local line = "[ActionPad] SAY plan failed: " .. tostring(err)
                    print(line)
                    _setStatusLine(line)
                end
            end)
        end

        -- NOTE: MVP uses a fixed healer name "Healer" when present.
        -- This is a stub until the pickedHealer/assistBy rule is finalized.
        local healerName = "Healer"
        local btnHeal = G.Label:new({
            name = "DWKit_ActionPad_BtnHeal_" .. tostring(i),
            x = string.format("-%dpx", btnW),
            y = tostring(y) .. "px",
            width = tostring(btnW) .. "px",
            height = tostring(rowH) .. "px",
        }, _state.widgets.listRoot)

        if type(btnHeal) == "table" then
            pcall(function() btnHeal:echo("HEAL") end)

            local enabled = false
            for j = 1, #rows do
                local rr = rows[j] or {}
                if tostring(rr.name or "") == healerName then
                    enabled = true
                    break
                end
            end

            pcall(ButtonKit.applyButtonStyle, btnHeal, { enabled = enabled, minHeightPx = rowH })
            pcall(ButtonKit.wireClick, btnHeal, function()
                if enabled ~= true then
                    local line = "[ActionPad] HEAL disabled: healer not online (stub)"
                    print(line)
                    _setStatusLine(line)
                    return
                end

                local ok, err = _planHeal(healerName, name)
                if not ok then
                    local line = "[ActionPad] HEAL plan failed: " .. tostring(err)
                    print(line)
                    _setStatusLine(line)
                end
            end)
        end

        _state.widgets.rows[#_state.widgets.rows + 1] = {
            name = name,
            nameLabel = nameLabel,
            btnSay = btnSay,
            btnHeal = btnHeal,
        }
    end

    _state.lastRender = {
        ts = os.time(),
        rowsCount = #rows,
    }

    _setStatusLine(string.format("Rendered %d online rows. (PLAN only)", #rows))
    return true, nil
end

local function _ensureSubscribed()
    if _state.sub then
        return true, nil
    end

    local okA, A = pcall(require, "dwkit.services.actionpad_service")
    if not okA or type(A) ~= "table" or type(A.onUpdated) ~= "function" then
        return false, "ActionPadService.onUpdated not available"
    end

    local function handlerFn(payload, sub)
        if _state.enabled ~= true then return end
        if _state.runtimeVisible ~= true then return end
        pcall(_render)
    end

    local okSub, sub, errSub = U.subscribeServiceUpdates(
        M.UI_ID,
        A.onUpdated,
        handlerFn,
        { eventName = "DWKit:Service:ActionPad:Updated", debugPrefix = "[DWKit UI] actionpad_ui" }
    )

    if not okSub then
        return false, tostring(errSub or "subscribe failed")
    end

    _state.sub = sub
    return true, nil
end

local function _unsubscribe()
    if not _state.sub then return true end
    pcall(U.unsubscribeServiceUpdates, _state.sub)
    _state.sub = nil
    return true
end

local function _dispose()
    _unsubscribe()
    _clearRows()

    if _state.widgets.bundle and type(_state.widgets.bundle.frame) == "table" then
        pcall(function() U.safeHide(_state.widgets.bundle.frame) end)
    end

    _safeDelete(_state.widgets.status)
    _safeDelete(_state.widgets.header)
    _safeDelete(_state.widgets.listRoot)

    _state.widgets.bundle = nil
    _state.widgets.listRoot = nil
    _state.widgets.header = nil
    _state.widgets.status = nil

    _state.runtimeVisible = false
    pcall(U.setUiStateVisibleBestEffort, M.UI_ID, false)
    pcall(U.setUiRuntime, M.UI_ID, { state = { visible = false }, meta = { source = "actionpad_ui:dispose" } })

    return true
end

function M.getState()
    return {
        uiId = M.UI_ID,
        version = M.VERSION,
        enabled = (_state.enabled == true),
        visible = (_state.visible == true),
        runtimeVisible = (_state.runtimeVisible == true),
        inited = (_state.inited == true),
        lastError = _state.lastError,
        lastApplySource = _state.lastApplySource,
        lastRender = _state.lastRender,
    }
end

function M.apply(opts)
    opts = (type(opts) == "table") and opts or {}
    _state.lastApplySource = opts.source or "unknown"

    local gs = U.getGuiSettingsBestEffort()
    if type(gs) == "table" then
        if type(gs.isEnabled) == "function" then
            local okE, vE = pcall(gs.isEnabled, M.UI_ID, false)
            if okE then _state.enabled = (vE == true) end
        end
        if type(gs.isVisible) == "function" then
            local okV, vV = pcall(gs.isVisible, M.UI_ID, false)
            if okV then _state.visible = (vV == true) end
        elseif type(gs.getVisible) == "function" then
            local okV, vV = pcall(gs.getVisible, M.UI_ID, false)
            if okV then _state.visible = (vV == true) end
        end
    end

    -- Disabled -> destroy
    if _state.enabled ~= true then
        _dispose()
        _state.lastError = nil
        return true, nil
    end

    -- Ensure module + subscriptions exist (enabled-based)
    local okC, errC = _ensureCreated()
    if not okC then
        _state.lastError = tostring(errC)
        return false, _state.lastError
    end

    local okS, errS = _ensureSubscribed()
    if not okS then
        _state.lastError = tostring(errS)
        return false, _state.lastError
    end

    -- Visible OFF -> hide only (keep subscription)
    if _state.visible ~= true then
        if _state.widgets.bundle and type(_state.widgets.bundle.frame) == "table" then
            pcall(function() U.safeHide(_state.widgets.bundle.frame) end)
        end
        _state.runtimeVisible = false
        pcall(U.setUiStateVisibleBestEffort, M.UI_ID, false)
        pcall(U.setUiRuntime, M.UI_ID, { state = { visible = false }, meta = { source = "actionpad_ui:apply_hide" } })
        _state.lastError = nil
        return true, nil
    end

    -- Show + render
    if _state.widgets.bundle and type(_state.widgets.bundle.frame) == "table" then
        pcall(function() U.safeShow(_state.widgets.bundle.frame) end)
    end

    _state.runtimeVisible = true
    pcall(U.setUiStateVisibleBestEffort, M.UI_ID, true)
    pcall(U.setUiRuntime, M.UI_ID, { state = { visible = true }, meta = { source = "actionpad_ui:apply_show" } })

    local okR, errR = _render()
    if not okR then
        _state.lastError = tostring(errR)
        return false, _state.lastError
    end

    _state.lastError = nil
    return true, nil
end

return M
