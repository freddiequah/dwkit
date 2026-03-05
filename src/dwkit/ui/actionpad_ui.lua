-- FILE: src/dwkit/ui/actionpad_ui.lua
-- #########################################################################
-- Module Name : dwkit.ui.actionpad_ui
-- Owner       : UI
-- Version     : v2026-03-05A
-- Purpose     :
--   - ActionPad UI (Bucket A): online-only owned roster view with real button groups (PLAN-only).
--   - Consumes ActionPadService rowsOnlineOnly.
--   - Bucket B: wires deterministic enable/disable gating (Practice/Score/Registry) + disabled reasons.
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

M.VERSION = "v2026-03-05A"
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
        },
        rows = {}, -- array of row blocks { widgets = { ... } }
    },
}

local function _safeDelete(w)
    pcall(function() U.safeDelete(w) end)
end

local function _safeEcho(label, text)
    if type(label) == "table" and type(label.echo) == "function" then
        pcall(function() label:echo(tostring(text or "")) end)
    end
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
    _state.widgets.global = { feastBtn = nil }
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
        pcall(function() header:echo(ListKit.toPreHtml("ActionPad (Bucket A) - online-only roster (PLAN only)")) end)
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

local function _hasOnlineName(rows, name)
    name = tostring(name or "")
    if name == "" then return false end
    for i = 1, #rows do
        local r = rows[i] or {}
        if tostring(r.name or "") == name then
            return true
        end
    end
    return false
end

local function _planSelfExec(rowName, cmd, metaLabel)
    local okA, A = pcall(require, "dwkit.services.actionpad_service")
    if not okA or type(A) ~= "table" then
        return false, "ActionPadService missing"
    end

    local plan, err = A.planSelfExec(tostring(rowName or ""), tostring(cmd or ""),
        { source = "actionpad_ui:" .. tostring(metaLabel or "planSelf") })
    if not plan then
        return false, tostring(err or "planSelfExec failed")
    end

    local line = string.format("[ActionPad] PLAN SELF-EXEC (%s) row=%s execProfile=%s cmd=%s",
        tostring(metaLabel or "self"),
        tostring(rowName),
        tostring(plan.targetProfile),
        tostring(plan.cmd))

    print(line)
    _setStatusLine(line)
    return true, nil
end

local function _planAssistExec(healerName, targetName, cmdTemplate, metaLabel)
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

    local plan, err = A.planAssistExec(healerName, targetName, tostring(cmdTemplate or ""),
        { source = "actionpad_ui:" .. tostring(metaLabel or "planAssist") })
    if not plan then
        return false, tostring(err or "planAssistExec failed")
    end

    local line = string.format("[ActionPad] PLAN ASSIST-EXEC (%s) healer=%s target=%s execProfile=%s cmd=%s",
        tostring(metaLabel or "assist"),
        tostring(healerName),
        tostring(targetName),
        tostring(plan.targetProfile),
        tostring(plan.cmd))

    print(line)
    _setStatusLine(line)
    return true, nil
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

local function _renderGlobal(topY, rowH, gap, btnW)
    _clearGlobal()

    -- Global action: Feast (LOCAL plan only)
    local specs = {
        {
            label = "FE",
            enabled = true,
            tooltip = "ActionPad: Feast (FE)\nstate=ENABLED\nreason=ok\ndetail=LOCAL plan only",
            onClick = function()
                _planLocal("yamcha", "Feast")
            end,
        },
    }

    local btns = _layoutRightButtons(_state.widgets.listRoot, topY, rowH, btnW, gap, specs, "DWKit_ActionPad_Global")
    _state.widgets.global.feastBtn = btns[1]
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

local function _render()
    local okA, A = pcall(require, "dwkit.services.actionpad_service")
    if not okA or type(A) ~= "table" or type(A.getRowsOnlineOnly) ~= "function" then
        _setStatusLine("ActionPadService not available.")
        return false, "ActionPadService not available"
    end

    local rows = A.getRowsOnlineOnly() or {}

    _clearRows()

    local padY = 6
    local gap = 4
    local rowH = 26

    local btnW = 38            -- compact
    local topY = 24 + padY + 2 -- below header

    -- Global row (1 line)
    _renderGlobal(topY, rowH, gap, btnW)

    -- Roster blocks start after global row
    local yCursor = topY + rowH + gap + 2

    -- NOTE: Bucket A uses a fixed healer name "Healer" when present.
    -- This is a stub until the pickedHealer/assistBy rule is finalized.
    local healerName = "Healer"
    local healerOnline = _hasOnlineName(rows, healerName)

    for i = 1, #rows do
        local r = rows[i] or {}
        local name = tostring(r.name or "?")
        local profileLabel = tostring(r.profileLabel or "?")
        local here = (r.here == true)

        -- Block has 4 lines: CTRL, SERVICE, MOVE, COMBAT
        local blockTop = yCursor
        local line1Y = blockTop
        local line2Y = blockTop + (rowH + gap)
        local line3Y = blockTop + (rowH + gap) * 2
        local line4Y = blockTop + (rowH + gap) * 3

        -- Name label sits on CTRL line, left side
        local nameLabel = G.Label:new({
            name = "DWKit_ActionPad_RowName_" .. tostring(i),
            x = "0px",
            y = tostring(line1Y) .. "px",
            width = string.format("-%dpx", (btnW * 4) + (gap * 3)), -- leave space, even though we right-align buttons
            height = tostring(rowH) .. "px",
        }, _state.widgets.listRoot)

        if type(nameLabel) == "table" then
            local txt = string.format("%s  (%s)%s", name, profileLabel, here and "  [HERE]" or "")
            pcall(function() nameLabel:echo(ListKit.toPreHtml(txt)) end)
            pcall(ListKit.applyRowTextStyle, nameLabel)
        end

        -- CTRL: FMe / FSelf / GrpAll / Flee (SELF-EXEC plan)
        local ctrlSpecs = {
            {
                label = "FM",
                enabled = true,
                tooltip = "ActionPad: FMe (FM)\nstate=ENABLED\nreason=ok\ndetail=PLAN self-exec only",
                onClick = function()
                    local ok, err = _planSelfExec(name, "[TODO] follow-me", "FMe")
                    if not ok then _setStatusLine("[ActionPad] FMe plan failed: " .. tostring(err)) end
                end
            },
            {
                label = "FS",
                enabled = true,
                tooltip = "ActionPad: FSelf (FS)\nstate=ENABLED\nreason=ok\ndetail=PLAN self-exec only",
                onClick = function()
                    local ok, err = _planSelfExec(name, "[TODO] follow-self", "FSelf")
                    if not ok then _setStatusLine("[ActionPad] FSelf plan failed: " .. tostring(err)) end
                end
            },
            {
                label = "GA",
                enabled = true,
                tooltip = "ActionPad: GrpAll (GA)\nstate=ENABLED\nreason=ok\ndetail=PLAN self-exec only",
                onClick = function()
                    local ok, err = _planSelfExec(name, "[TODO] group-all", "GrpAll")
                    if not ok then _setStatusLine("[ActionPad] GrpAll plan failed: " .. tostring(err)) end
                end
            },
            {
                label = "FL",
                enabled = true,
                tooltip = "ActionPad: Flee (FL)\nstate=ENABLED\nreason=ok\ndetail=PLAN self-exec only",
                onClick = function()
                    local ok, err = _planSelfExec(name, "[TODO] flee", "Flee")
                    if not ok then _setStatusLine("[ActionPad] Flee plan failed: " .. tostring(err)) end
                end
            },
        }
        local ctrlBtns = _layoutRightButtons(_state.widgets.listRoot, line1Y, rowH, btnW, gap, ctrlSpecs,
            "DWKit_ActionPad_Ctrl_" .. tostring(i))

        -- SERVICE: Buff / Feed / Heal / PHeal / Rst / Rej (ASSIST-EXEC plan)
        -- Bucket B: deterministic gating from Practice/Score/Registry.
        -- Note: healer selection is still a stub; we keep healerOnline as an additional gate.
        local gBless = _gateBestEffort("spell", "bless", "Bless")
        local gHeal = _gateBestEffort("spell", "heal", "Heal")
        local gPHeal = _gateBestEffort("spell", "power heal", "Power Heal")
        local gRefresh = _gateBestEffort("spell", "refresh", "Refresh")
        local gFeed = _gateBestEffort("spell", "feed", "Feed")
        local gRej = _gateBestEffort("spell", "rej", "Rej")

        local function _withHealerGate(g, fullName)
            if healerOnline ~= true then
                return {
                    enabled = false,
                    reason = "healer_offline_stub",
                    detail = "Healer stub is offline: " .. tostring(healerName),
                }, tostring(fullName or "")
            end
            return g, tostring(fullName or "")
        end

        local serviceSpecs = {
            {
                label = "BU",
                disabledLabel = "BU",
                disabledGate = _withHealerGate(gBless, "Buff"),
                tooltip = _mkTip("BU", "Buff (Bless)", _withHealerGate(gBless, "Buff")),
                enabled = (_withHealerGate(gBless, "Buff").enabled == true),
                onClick = function()
                    local ok, err = _planAssistExec(healerName, name, "cast bless {target}", "Buff")
                    if not ok then _setStatusLine("[ActionPad] Buff plan failed: " .. tostring(err)) end
                end
            },
            {
                label = "FD",
                disabledLabel = "FD",
                disabledGate = _withHealerGate(gFeed, "Feed"),
                tooltip = _mkTip("FD", "Feed", _withHealerGate(gFeed, "Feed")),
                enabled = (_withHealerGate(gFeed, "Feed").enabled == true),
                onClick = function()
                    local ok, err = _planAssistExec(healerName, name, "[TODO] feed {target}", "Feed")
                    if not ok then _setStatusLine("[ActionPad] Feed plan failed: " .. tostring(err)) end
                end
            },
            {
                label = "HL",
                disabledLabel = "HL",
                disabledGate = _withHealerGate(gHeal, "Heal"),
                tooltip = _mkTip("HL", "Heal", _withHealerGate(gHeal, "Heal")),
                enabled = (_withHealerGate(gHeal, "Heal").enabled == true),
                onClick = function()
                    local ok, err = _planAssistExec(healerName, name, "cast heal {target}", "Heal")
                    if not ok then _setStatusLine("[ActionPad] Heal plan failed: " .. tostring(err)) end
                end
            },
            {
                label = "PH",
                disabledLabel = "PH",
                disabledGate = _withHealerGate(gPHeal, "Power Heal"),
                tooltip = _mkTip("PH", "Power Heal", _withHealerGate(gPHeal, "Power Heal")),
                enabled = (_withHealerGate(gPHeal, "Power Heal").enabled == true),
                onClick = function()
                    local ok, err = _planAssistExec(healerName, name, "cast 'power heal' {target}", "PHeal")
                    if not ok then _setStatusLine("[ActionPad] PHeal plan failed: " .. tostring(err)) end
                end
            },
            {
                label = "RS",
                disabledLabel = "RS",
                disabledGate = _withHealerGate(gRefresh, "Refresh"),
                tooltip = _mkTip("RS", "Refresh", _withHealerGate(gRefresh, "Refresh")),
                enabled = (_withHealerGate(gRefresh, "Refresh").enabled == true),
                onClick = function()
                    local ok, err = _planAssistExec(healerName, name, "cast refresh {target}", "Rst")
                    if not ok then _setStatusLine("[ActionPad] Rst plan failed: " .. tostring(err)) end
                end
            },
            {
                label = "RJ",
                disabledLabel = "RJ",
                disabledGate = _withHealerGate(gRej, "Rej"),
                tooltip = _mkTip("RJ", "Rej", _withHealerGate(gRej, "Rej")),
                enabled = (_withHealerGate(gRej, "Rej").enabled == true),
                onClick = function()
                    local ok, err = _planAssistExec(healerName, name, "[TODO] rej {target}", "Rej")
                    if not ok then _setStatusLine("[ActionPad] Rej plan failed: " .. tostring(err)) end
                end
            },
        }
        local serviceBtns = _layoutRightButtons(_state.widgets.listRoot, line2Y, rowH, btnW, gap, serviceSpecs,
            "DWKit_ActionPad_Service_" .. tostring(i))

        -- MOVE: Summon / Relocate (SELF-EXEC plan)
        local moveSpecs = {
            {
                label = "SU",
                enabled = true,
                tooltip = "ActionPad: Summon (SU)\nstate=ENABLED\nreason=ok\ndetail=PLAN self-exec only",
                onClick = function()
                    local ok, err = _planSelfExec(name, "[TODO] summon", "Summon")
                    if not ok then _setStatusLine("[ActionPad] Summon plan failed: " .. tostring(err)) end
                end
            },
            {
                label = "RE",
                enabled = true,
                tooltip = "ActionPad: Relocate (RE)\nstate=ENABLED\nreason=ok\ndetail=PLAN self-exec only",
                onClick = function()
                    local ok, err = _planSelfExec(name, "[TODO] relocate", "Relocate")
                    if not ok then _setStatusLine("[ActionPad] Relocate plan failed: " .. tostring(err)) end
                end
            },
        }
        local moveBtns = _layoutRightButtons(_state.widgets.listRoot, line3Y, rowH, btnW, gap, moveSpecs,
            "DWKit_ActionPad_Move_" .. tostring(i))

        -- COMBAT: Assist / Kick / Bash / Pummel / Circle / Guard / Rescue (SELF-EXEC plan)
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
                    local ok, err = _planSelfExec(name, "[TODO] assist", "Assist")
                    if not ok then _setStatusLine("[ActionPad] Assist plan failed: " .. tostring(err)) end
                end
            },
            {
                label = "KI",
                disabledLabel = "KI",
                disabledGate = gKick,
                tooltip = _mkTip("KI", "Kick", gKick),
                enabled = (gKick.enabled == true),
                onClick = function()
                    local ok, err = _planSelfExec(name, "[TODO] kick", "Kick")
                    if not ok then _setStatusLine("[ActionPad] Kick plan failed: " .. tostring(err)) end
                end
            },
            {
                label = "BA",
                disabledLabel = "BA",
                disabledGate = gBash,
                tooltip = _mkTip("BA", "Bash", gBash),
                enabled = (gBash.enabled == true),
                onClick = function()
                    local ok, err = _planSelfExec(name, "[TODO] bash", "Bash")
                    if not ok then _setStatusLine("[ActionPad] Bash plan failed: " .. tostring(err)) end
                end
            },
            {
                label = "PU",
                disabledLabel = "PU",
                disabledGate = gPummel,
                tooltip = _mkTip("PU", "Pummel", gPummel),
                enabled = (gPummel.enabled == true),
                onClick = function()
                    local ok, err = _planSelfExec(name, "[TODO] pummel", "Pummel")
                    if not ok then _setStatusLine("[ActionPad] Pummel plan failed: " .. tostring(err)) end
                end
            },
            {
                label = "CI",
                disabledLabel = "CI",
                disabledGate = gCircle,
                tooltip = _mkTip("CI", "Circle", gCircle),
                enabled = (gCircle.enabled == true),
                onClick = function()
                    local ok, err = _planSelfExec(name, "[TODO] circle", "Circle")
                    if not ok then _setStatusLine("[ActionPad] Circle plan failed: " .. tostring(err)) end
                end
            },
            {
                label = "GU",
                disabledLabel = "GU",
                disabledGate = gGuard,
                tooltip = _mkTip("GU", "Guard", gGuard),
                enabled = (gGuard.enabled == true),
                onClick = function()
                    local ok, err = _planSelfExec(name, "[TODO] guard", "Guard")
                    if not ok then _setStatusLine("[ActionPad] Guard plan failed: " .. tostring(err)) end
                end
            },
            {
                label = "RC",
                disabledLabel = "RC",
                disabledGate = gRescue,
                tooltip = _mkTip("RC", "Rescue", gRescue),
                enabled = (gRescue.enabled == true),
                onClick = function()
                    local ok, err = _planSelfExec(name, "[TODO] rescue", "Rescue")
                    if not ok then _setStatusLine("[ActionPad] Rescue plan failed: " .. tostring(err)) end
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
        healerName = healerName,
        healerOnline = healerOnline,
    }

    local hInfo = healerOnline and ("healer=" .. healerName .. " ONLINE") or
        ("healer=" .. healerName .. " OFFLINE (service disabled by stub)")
    _setStatusLine(string.format("Rendered %d online rows. %s. (PLAN only)", #rows, hInfo))
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
