-- FILE: src/dwkit/ui/actionpad_ui.lua
-- #########################################################################
-- Module Name : dwkit.ui.actionpad_ui
-- Owner       : UI
-- Version     : v2026-03-09B
-- Purpose     :
--   - ActionPad UI (Bucket A): online-only owned roster view with real button groups.
--   - Consumes ActionPadService rowsOnlineOnly.
--   - Bucket B: wires deterministic enable/disable gating (Practice/Score/Registry) + disabled reasons.
--   - Bucket C: assistBy/healer selection rule (session-only) wired to ActionPadService.
--   - Bucket D: dispatches owned-only RemoteExec for real non-placeholder commands, while
--     placeholder actions remain PLAN-only.
--   - Bucket F: corrects cleric service row wiring so ActionPad service buttons align with
--     the agreed service set (Buff / Feed / Heal / PHeal / Rst / Rej).
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

M.VERSION = "v2026-03-09B"
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
        global = {
            feastBtn = nil,
            healerAutoBtn = nil,
            healerNextBtn = nil,
        },
        rows = {},
    },
}

local _render

local function _safeDelete(w)
    pcall(function() U.safeDelete(w) end)
end

local function _clearRows()
    local rows = _state.widgets.rows or {}
    for i = 1, #rows do
        local block = rows[i]
        local ws = (type(block) == "table") and block.widgets or nil
        if type(ws) == "table" then
            _safeDelete(ws.nameLabel)

            if type(ws.ctrlBtns) == "table" then
                for j = 1, #ws.ctrlBtns do _safeDelete(ws.ctrlBtns[j]) end
            end
            if type(ws.serviceBtns) == "table" then
                for j = 1, #ws.serviceBtns do _safeDelete(ws.serviceBtns[j]) end
            end
            if type(ws.moveBtns) == "table" then
                for j = 1, #ws.moveBtns do _safeDelete(ws.moveBtns[j]) end
            end
            if type(ws.combatBtns) == "table" then
                for j = 1, #ws.combatBtns do _safeDelete(ws.combatBtns[j]) end
            end
        end
    end
    _state.widgets.rows = {}
end

local function _clearGlobal()
    local g = _state.widgets.global or {}
    _safeDelete(g.feastBtn)
    _safeDelete(g.healerAutoBtn)
    _safeDelete(g.healerNextBtn)
    _state.widgets.global = { feastBtn = nil, healerAutoBtn = nil, healerNextBtn = nil }
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
        width = 520,
        height = 360,
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
        pcall(function()
            header:echo(ListKit.toPreHtml(
                "ActionPad - online-only roster (Bucket D dispatch + plan-only placeholders)"))
        end)
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

local function _planLocal(cmd, metaLabel)
    local line = string.format("[ActionPad] PLAN LOCAL (%s) execProfile=<current> cmd=%s",
        tostring(metaLabel or "local"),
        tostring(cmd or ""))
    print(line)
    _setStatusLine(line)
    return true, nil
end

local function _safeSetTooltip(btn, text)
    if type(btn) ~= "table" then return end
    if type(text) ~= "string" or text == "" then return end
    if type(btn.setToolTip) == "function" then
        pcall(function() btn:setToolTip(text) end)
        return
    end
    if type(btn.setTooltip) == "function" then
        pcall(function() btn:setTooltip(text) end)
        return
    end
end

local function _mkTip(labelShort, fullName, gate)
    fullName = tostring(fullName or "")
    labelShort = tostring(labelShort or "")
    gate = (type(gate) == "table") and gate or {}

    local reason = tostring(gate.reason or "")
    local detail = tostring(gate.detail or "")

    if reason == "" then reason = "unknown" end
    if detail == "" then detail = reason end

    return string.format("ActionPad: %s (%s)\nstate=%s\nreason=%s\ndetail=%s",
        fullName, labelShort,
        tostring(gate.enabled == true and "ENABLED" or "DISABLED"),
        reason, detail)
end

local function _mkBtn(name, parent, x, y, w, h, label, enabled, onClick, tooltipText, disabledGate, disabledLabel)
    local btn = G.Label:new({
        name = name,
        x = tostring(x) .. "px",
        y = tostring(y) .. "px",
        width = tostring(w) .. "px",
        height = tostring(h) .. "px",
    }, parent)

    if type(btn) ~= "table" then
        return nil
    end

    pcall(function() btn:echo(tostring(label or "")) end)
    pcall(ButtonKit.applyButtonStyle, btn, { enabled = (enabled == true), minHeightPx = h })

    if type(tooltipText) == "string" and tooltipText ~= "" then
        _safeSetTooltip(btn, tooltipText)
    end

    if enabled ~= true then
        local g = (type(disabledGate) == "table") and disabledGate or {}
        local dl = tostring(disabledLabel or tostring(label or ""))
        local function onDisabled()
            local line = string.format("[ActionPad] DISABLED (%s) reason=%s detail=%s",
                dl,
                tostring(g.reason or "unknown"),
                tostring(g.detail or ""))
            print(line)
            _setStatusLine(line)
        end
        pcall(ButtonKit.wireClick, btn, onDisabled)
        return btn
    end

    if type(onClick) == "function" then
        pcall(ButtonKit.wireClick, btn, onClick)
    end

    return btn
end

local function _layoutRightButtons(parent, y, rowH, btnW, gap, specs, namePrefix)
    local out = {}
    local n = (type(specs) == "table") and #specs or 0
    if n <= 0 then return out end

    local totalW = (btnW * n) + (gap * (n - 1))
    local startX = -totalW

    for i = 1, n do
        local s = specs[i] or {}
        local x = startX + (i - 1) * (btnW + gap)
        local btn = _mkBtn(
            tostring(namePrefix) .. "_" .. tostring(i),
            parent,
            x,
            y,
            btnW,
            rowH,
            s.label,
            (s.enabled ~= false),
            s.onClick,
            s.tooltip,
            s.disabledGate,
            s.disabledLabel
        )
        out[#out + 1] = btn
    end

    return out
end

local function _gateBestEffort(kind, practiceKey, displayName)
    local okA, A = pcall(require, "dwkit.services.actionpad_service")
    if not okA or type(A) ~= "table" or type(A.resolveActionGate) ~= "function" then
        return { enabled = false, reason = "service_missing", detail = "ActionPadService.resolveActionGate not available" }
    end
    local g = A.resolveActionGate({ kind = kind, practiceKey = practiceKey, displayName = displayName }, {})
    if type(g) ~= "table" then
        return { enabled = false, reason = "gate_error", detail = "resolveActionGate returned invalid gate" }
    end
    return g
end

local function _getAssistBy()
    local okA, A = pcall(require, "dwkit.services.actionpad_service")
    if not okA or type(A) ~= "table" or type(A.getAssistByState) ~= "function" then
        return {
            mode = "auto",
            resolvedName = nil,
            resolvedOnline = false,
            candidates = {},
            lastReason = "service_missing"
        }
    end
    local st = A.getAssistByState()
    if type(st) ~= "table" then
        return {
            mode = "auto",
            resolvedName = nil,
            resolvedOnline = false,
            candidates = {},
            lastReason = "service_missing"
        }
    end
    return st
end

local function _assistGate(g, assistState)
    assistState = (type(assistState) == "table") and assistState or {}
    if assistState.resolvedOnline ~= true or tostring(assistState.resolvedName or "") == "" then
        return {
            enabled = false,
            reason = "no_healer_online",
            detail = "No assistBy online (mode=" .. tostring(assistState.mode or "auto") .. ")",
        }
    end
    return g
end

local function _assistLabel(assistState)
    assistState = (type(assistState) == "table") and assistState or {}
    local mode = tostring(assistState.mode or "auto")
    local sel = tostring(assistState.selectedName or "")
    local res = tostring(assistState.resolvedName or "")
    local online = (assistState.resolvedOnline == true)

    if mode == "manual" then
        if res ~= "" and online then
            return string.format("AssistBy: %s (manual)", res)
        end
        if sel ~= "" then
            return string.format("AssistBy: %s (manual, OFFLINE)", sel)
        end
        return "AssistBy: (manual, none)"
    end

    if res ~= "" and online then
        return string.format("AssistBy: %s (auto)", res)
    end
    return "AssistBy: (auto, none online)"
end

local function _dispatchSelfExec(rowName, cmd, metaLabel)
    local okA, A = pcall(require, "dwkit.services.actionpad_service")
    if not okA or type(A) ~= "table" then
        return false, "ActionPadService missing"
    end
    if type(A.dispatchSelfExec) ~= "function" then
        return false, "ActionPadService.dispatchSelfExec missing"
    end

    local res, err = A.dispatchSelfExec(tostring(rowName or ""), tostring(cmd or ""),
        { source = "actionpad_ui:" .. tostring(metaLabel or "dispatchSelf") })
    if not res then
        return false, tostring(err or "dispatchSelfExec failed")
    end

    local line
    if res.dispatched == true then
        line = string.format("[ActionPad] DISPATCH SELF-EXEC (%s) row=%s execProfile=%s cmd=%s",
            tostring(metaLabel or "self"),
            tostring(rowName),
            tostring(res.targetProfile),
            tostring(res.cmd))
    else
        line = string.format("[ActionPad] PLAN SELF-EXEC (%s) row=%s execProfile=%s cmd=%s reason=%s",
            tostring(metaLabel or "self"),
            tostring(rowName),
            tostring(res.targetProfile),
            tostring(res.cmd),
            tostring(res.reason or "plan_only"))
    end

    print(line)
    _setStatusLine(line)
    return true, nil
end

local function _dispatchAssistExec(healerName, targetName, cmdTemplate, metaLabel)
    local okA, A = pcall(require, "dwkit.services.actionpad_service")
    if not okA or type(A) ~= "table" then
        return false, "ActionPadService missing"
    end
    if type(A.dispatchAssistExec) ~= "function" then
        return false, "ActionPadService.dispatchAssistExec missing"
    end

    healerName = tostring(healerName or "")
    targetName = tostring(targetName or "")

    if healerName == "" then
        return false, "healerName missing"
    end
    if targetName == "" then
        return false, "targetName missing"
    end

    local res, err = A.dispatchAssistExec(healerName, targetName, tostring(cmdTemplate or ""),
        { source = "actionpad_ui:" .. tostring(metaLabel or "dispatchAssist") })
    if not res then
        return false, tostring(err or "dispatchAssistExec failed")
    end

    local line
    if res.dispatched == true then
        line = string.format("[ActionPad] DISPATCH ASSIST-EXEC (%s) healer=%s target=%s execProfile=%s cmd=%s",
            tostring(metaLabel or "assist"),
            tostring(healerName),
            tostring(targetName),
            tostring(res.targetProfile),
            tostring(res.cmd))
    else
        line = string.format("[ActionPad] PLAN ASSIST-EXEC (%s) healer=%s target=%s execProfile=%s cmd=%s reason=%s",
            tostring(metaLabel or "assist"),
            tostring(healerName),
            tostring(targetName),
            tostring(res.targetProfile),
            tostring(res.cmd),
            tostring(res.reason or "plan_only"))
    end

    print(line)
    _setStatusLine(line)
    return true, nil
end

local function _renderGlobal(topY, rowH, gap, btnW)
    _clearGlobal()

    local assist = _getAssistBy()
    local assistLine = _assistLabel(assist)

    local specs = {
        {
            label = "FE",
            enabled = true,
            tooltip = "ActionPad: Feast (FE)\nstate=ENABLED\nreason=ok\ndetail=LOCAL plan only",
            onClick = function()
                _planLocal("yamcha", "Feast")
            end,
        },
        {
            label = "AU",
            enabled = true,
            tooltip = "ActionPad: AssistBy Auto (AU)\nstate=ENABLED\nreason=ok\ndetail=Set assistBy mode to auto",
            onClick = function()
                local okA, A = pcall(require, "dwkit.services.actionpad_service")
                if okA and type(A) == "table" and type(A.setAssistByAuto) == "function" then
                    local ok, err = A.setAssistByAuto({ source = "actionpad_ui:assist_auto" })
                    if ok ~= true then
                        _setStatusLine("[ActionPad] AssistBy Auto failed: " .. tostring(err))
                    else
                        _setStatusLine("[ActionPad] AssistBy set to AUTO. " .. _assistLabel(_getAssistBy()))
                    end
                else
                    _setStatusLine("[ActionPad] AssistBy Auto not available (service missing).")
                end
                if type(_render) == "function" then pcall(_render) end
            end,
        },
        {
            label = "NX",
            enabled = true,
            tooltip = "ActionPad: AssistBy Next (NX)\nstate=ENABLED\nreason=ok\ndetail=Cycle to next online owned",
            onClick = function()
                local okA, A = pcall(require, "dwkit.services.actionpad_service")
                if okA and type(A) == "table" and type(A.cycleAssistBy) == "function" then
                    local name, err = A.cycleAssistBy(1, { source = "actionpad_ui:assist_next" })
                    if not name then
                        _setStatusLine("[ActionPad] AssistBy Next failed: " .. tostring(err))
                    else
                        _setStatusLine("[ActionPad] AssistBy set to: " .. tostring(name))
                    end
                else
                    _setStatusLine("[ActionPad] AssistBy Next not available (service missing).")
                end
                if type(_render) == "function" then pcall(_render) end
            end,
        },
    }

    local btns = _layoutRightButtons(_state.widgets.listRoot, topY, rowH, btnW, gap, specs, "DWKit_ActionPad_Global")
    _state.widgets.global.feastBtn = btns[1]
    _state.widgets.global.healerAutoBtn = btns[2]
    _state.widgets.global.healerNextBtn = btns[3]

    _setStatusLine(assistLine)
end

_render = function()
    local okA, A = pcall(require, "dwkit.services.actionpad_service")
    if not okA or type(A) ~= "table" or type(A.getRowsOnlineOnly) ~= "function" then
        _setStatusLine("ActionPadService not available.")
        return false, "ActionPadService not available"
    end

    local rows = A.getRowsOnlineOnly() or {}
    local assist = _getAssistBy()

    _clearRows()

    local padY = 6
    local gap = 4
    local rowH = 26

    local btnW = 38
    local topY = 24 + padY + 2

    _renderGlobal(topY, rowH, gap, btnW)

    local yCursor = topY + rowH + gap + 2

    local healerName = tostring(assist.resolvedName or "")
    local healerOnline = (assist.resolvedOnline == true and healerName ~= "")

    for i = 1, #rows do
        local r = rows[i] or {}
        local name = tostring(r.name or "?")
        local profileLabel = tostring(r.profileLabel or "?")
        local here = (r.here == true)

        local blockTop = yCursor
        local line1Y = blockTop
        local line2Y = blockTop + (rowH + gap)
        local line3Y = blockTop + (rowH + gap) * 2
        local line4Y = blockTop + (rowH + gap) * 3

        local nameLabel = G.Label:new({
            name = "DWKit_ActionPad_RowName_" .. tostring(i),
            x = "0px",
            y = tostring(line1Y) .. "px",
            width = string.format("-%dpx", (btnW * 4) + (gap * 3)),
            height = tostring(rowH) .. "px",
        }, _state.widgets.listRoot)

        if type(nameLabel) == "table" then
            local txt = string.format("%s  (%s)%s", name, profileLabel, here and "  [HERE]" or "")
            pcall(function() nameLabel:echo(ListKit.toPreHtml(txt)) end)
            pcall(ListKit.applyRowTextStyle, nameLabel)
        end

        local ctrlSpecs = {
            {
                label = "FM",
                enabled = true,
                tooltip = "ActionPad: FMe (FM)\nstate=ENABLED\nreason=ok\ndetail=placeholder remains PLAN-only",
                onClick = function()
                    local ok, err = _dispatchSelfExec(name, "[TODO] follow-me", "FMe")
                    if not ok then _setStatusLine("[ActionPad] FMe failed: " .. tostring(err)) end
                end
            },
            {
                label = "FS",
                enabled = true,
                tooltip = "ActionPad: FSelf (FS)\nstate=ENABLED\nreason=ok\ndetail=placeholder remains PLAN-only",
                onClick = function()
                    local ok, err = _dispatchSelfExec(name, "[TODO] follow-self", "FSelf")
                    if not ok then _setStatusLine("[ActionPad] FSelf failed: " .. tostring(err)) end
                end
            },
            {
                label = "GA",
                enabled = true,
                tooltip = "ActionPad: GrpAll (GA)\nstate=ENABLED\nreason=ok\ndetail=placeholder remains PLAN-only",
                onClick = function()
                    local ok, err = _dispatchSelfExec(name, "[TODO] group-all", "GrpAll")
                    if not ok then _setStatusLine("[ActionPad] GrpAll failed: " .. tostring(err)) end
                end
            },
            {
                label = "FL",
                enabled = true,
                tooltip = "ActionPad: Flee (FL)\nstate=ENABLED\nreason=ok\ndetail=placeholder remains PLAN-only",
                onClick = function()
                    local ok, err = _dispatchSelfExec(name, "[TODO] flee", "Flee")
                    if not ok then _setStatusLine("[ActionPad] Flee failed: " .. tostring(err)) end
                end
            },
        }
        local ctrlBtns = _layoutRightButtons(_state.widgets.listRoot, line1Y, rowH, btnW, gap, ctrlSpecs,
            "DWKit_ActionPad_Ctrl_" .. tostring(i))

        local gBless = _gateBestEffort("spell", "bless", "Bless")
        local gFeed = _gateBestEffort("spell", "feed", "Feed")
        local gHeal = _gateBestEffort("spell", "heal", "Heal")
        local gPHeal = _gateBestEffort("spell", "power heal", "Power Heal")
        local gRestore = _gateBestEffort("spell", "restore", "Restore")
        local gRej = _gateBestEffort("spell", "rejuvenate", "Rejuvenate")

        local gateBuff = _assistGate(gBless, assist)
        local gateFeed = _assistGate(gFeed, assist)
        local gateHeal = _assistGate(gHeal, assist)
        local gatePHeal = _assistGate(gPHeal, assist)
        local gateRestore = _assistGate(gRestore, assist)
        local gateRej = _assistGate(gRej, assist)

        local serviceSpecs = {
            {
                label = "BU",
                disabledLabel = "BU",
                disabledGate = gateBuff,
                tooltip = _mkTip("BU", "Buff (Bless)", gateBuff),
                enabled = (gateBuff.enabled == true),
                onClick = function()
                    local ok, err = _dispatchAssistExec(healerName, name, "cast bless {target}", "Buff")
                    if not ok then _setStatusLine("[ActionPad] Buff failed: " .. tostring(err)) end
                end
            },
            {
                label = "FD",
                disabledLabel = "FD",
                disabledGate = gateFeed,
                tooltip = _mkTip("FD", "Feed", gateFeed),
                enabled = (gateFeed.enabled == true),
                onClick = function()
                    local ok, err = _dispatchAssistExec(healerName, name, "cast feed {target}", "Feed")
                    if not ok then _setStatusLine("[ActionPad] Feed failed: " .. tostring(err)) end
                end
            },
            {
                label = "HL",
                disabledLabel = "HL",
                disabledGate = gateHeal,
                tooltip = _mkTip("HL", "Heal", gateHeal),
                enabled = (gateHeal.enabled == true),
                onClick = function()
                    local ok, err = _dispatchAssistExec(healerName, name, "cast heal {target}", "Heal")
                    if not ok then _setStatusLine("[ActionPad] Heal failed: " .. tostring(err)) end
                end
            },
            {
                label = "PH",
                disabledLabel = "PH",
                disabledGate = gatePHeal,
                tooltip = _mkTip("PH", "Power Heal", gatePHeal),
                enabled = (gatePHeal.enabled == true),
                onClick = function()
                    local ok, err = _dispatchAssistExec(healerName, name, "cast 'power heal' {target}", "PHeal")
                    if not ok then _setStatusLine("[ActionPad] PHeal failed: " .. tostring(err)) end
                end
            },
            {
                label = "RS",
                disabledLabel = "RS",
                disabledGate = gateRestore,
                tooltip = _mkTip("RS", "Restore", gateRestore),
                enabled = (gateRestore.enabled == true),
                onClick = function()
                    local ok, err = _dispatchAssistExec(healerName, name, "cast restore {target}", "Rst")
                    if not ok then _setStatusLine("[ActionPad] Rst failed: " .. tostring(err)) end
                end
            },
            {
                label = "RJ",
                disabledLabel = "RJ",
                disabledGate = gateRej,
                tooltip = _mkTip("RJ", "Rejuvenate", gateRej),
                enabled = (gateRej.enabled == true),
                onClick = function()
                    local ok, err = _dispatchAssistExec(healerName, name, "cast rejuvenate {target}", "Rej")
                    if not ok then _setStatusLine("[ActionPad] Rej failed: " .. tostring(err)) end
                end
            },
        }
        local serviceBtns = _layoutRightButtons(_state.widgets.listRoot, line2Y, rowH, btnW, gap, serviceSpecs,
            "DWKit_ActionPad_Service_" .. tostring(i))

        local moveSpecs = {
            {
                label = "SU",
                enabled = true,
                tooltip = "ActionPad: Summon (SU)\nstate=ENABLED\nreason=ok\ndetail=placeholder remains PLAN-only",
                onClick = function()
                    local ok, err = _dispatchSelfExec(name, "[TODO] summon", "Summon")
                    if not ok then _setStatusLine("[ActionPad] Summon failed: " .. tostring(err)) end
                end
            },
            {
                label = "RE",
                enabled = true,
                tooltip = "ActionPad: Relocate (RE)\nstate=ENABLED\nreason=ok\ndetail=placeholder remains PLAN-only",
                onClick = function()
                    local ok, err = _dispatchSelfExec(name, "[TODO] relocate", "Relocate")
                    if not ok then _setStatusLine("[ActionPad] Relocate failed: " .. tostring(err)) end
                end
            },
        }
        local moveBtns = _layoutRightButtons(_state.widgets.listRoot, line3Y, rowH, btnW, gap, moveSpecs,
            "DWKit_ActionPad_Move_" .. tostring(i))

        local gAssist = _gateBestEffort("skill", "assist", "Assist")
        local gKick = _gateBestEffort("skill", "kick", "Kick")
        local gBash = _gateBestEffort("skill", "bash", "Bash")
        local gPummel = _gateBestEffort("skill", "pummel", "Pummel")
        local gCircle = _gateBestEffort("skill", "circle", "Circle")
        local gGuard = _gateBestEffort("skill", "guard", "Guard")
        local gRescue = _gateBestEffort("skill", "rescue", "Rescue")

        local combatSpecs = {
            {
                label = "AS",
                disabledLabel = "AS",
                disabledGate = gAssist,
                tooltip = _mkTip("AS", "Assist", gAssist),
                enabled = (gAssist.enabled == true),
                onClick = function()
                    local ok, err = _dispatchSelfExec(name, "[TODO] assist", "Assist")
                    if not ok then _setStatusLine("[ActionPad] Assist failed: " .. tostring(err)) end
                end
            },
            {
                label = "KI",
                disabledLabel = "KI",
                disabledGate = gKick,
                tooltip = _mkTip("KI", "Kick", gKick),
                enabled = (gKick.enabled == true),
                onClick = function()
                    local ok, err = _dispatchSelfExec(name, "[TODO] kick", "Kick")
                    if not ok then _setStatusLine("[ActionPad] Kick failed: " .. tostring(err)) end
                end
            },
            {
                label = "BA",
                disabledLabel = "BA",
                disabledGate = gBash,
                tooltip = _mkTip("BA", "Bash", gBash),
                enabled = (gBash.enabled == true),
                onClick = function()
                    local ok, err = _dispatchSelfExec(name, "[TODO] bash", "Bash")
                    if not ok then _setStatusLine("[ActionPad] Bash failed: " .. tostring(err)) end
                end
            },
            {
                label = "PU",
                disabledLabel = "PU",
                disabledGate = gPummel,
                tooltip = _mkTip("PU", "Pummel", gPummel),
                enabled = (gPummel.enabled == true),
                onClick = function()
                    local ok, err = _dispatchSelfExec(name, "[TODO] pummel", "Pummel")
                    if not ok then _setStatusLine("[ActionPad] Pummel failed: " .. tostring(err)) end
                end
            },
            {
                label = "CI",
                disabledLabel = "CI",
                disabledGate = gCircle,
                tooltip = _mkTip("CI", "Circle", gCircle),
                enabled = (gCircle.enabled == true),
                onClick = function()
                    local ok, err = _dispatchSelfExec(name, "[TODO] circle", "Circle")
                    if not ok then _setStatusLine("[ActionPad] Circle failed: " .. tostring(err)) end
                end
            },
            {
                label = "GU",
                disabledLabel = "GU",
                disabledGate = gGuard,
                tooltip = _mkTip("GU", "Guard", gGuard),
                enabled = (gGuard.enabled == true),
                onClick = function()
                    local ok, err = _dispatchSelfExec(name, "[TODO] guard", "Guard")
                    if not ok then _setStatusLine("[ActionPad] Guard failed: " .. tostring(err)) end
                end
            },
            {
                label = "RC",
                disabledLabel = "RC",
                disabledGate = gRescue,
                tooltip = _mkTip("RC", "Rescue", gRescue),
                enabled = (gRescue.enabled == true),
                onClick = function()
                    local ok, err = _dispatchSelfExec(name, "[TODO] rescue", "Rescue")
                    if not ok then _setStatusLine("[ActionPad] Rescue failed: " .. tostring(err)) end
                end
            },
        }
        local combatBtns = _layoutRightButtons(_state.widgets.listRoot, line4Y, rowH, btnW, gap, combatSpecs,
            "DWKit_ActionPad_Combat_" .. tostring(i))

        _state.widgets.rows[#_state.widgets.rows + 1] = {
            name = name,
            widgets = {
                nameLabel = nameLabel,
                ctrlBtns = ctrlBtns,
                serviceBtns = serviceBtns,
                moveBtns = moveBtns,
                combatBtns = combatBtns,
            },
        }

        yCursor = blockTop + (rowH + gap) * 4 + gap + 2
    end

    _state.lastRender = {
        ts = os.time(),
        rowsCount = #rows,
        blocksCount = #rows,
        assistBy = assist,
        healerName = healerName,
        healerOnline = healerOnline,
    }

    local hInfo = _assistLabel(assist)
    _setStatusLine(string.format("Rendered %d online rows. %s. (Bucket D dispatch active; placeholders still PLAN-only)",
        #rows, hInfo))
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
    _clearGlobal()

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

    if _state.enabled ~= true then
        _dispose()
        _state.lastError = nil
        return true, nil
    end

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
