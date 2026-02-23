-- #########################################################################
-- Module Name : dwkit.commands.dwchat
-- Owner       : Commands
-- Version     : v2026-02-23C
-- Purpose     :
--   - Command handler for "dwchat" (SAFE)
--   - Phase 1 objective: provide a deterministic command surface to control chat_ui:
--       * open/show (default)
--       * hide/close
--       * toggle
--       * status (prints state)
--       * enable/disable (persist enabled flag; does NOT auto-show unless requested)
--       * tabs (prints available tabs)
--       * tab <name> (switch active tab)
--       * clear (clears chat log)
--       * send on|off (controls chat_ui sendToMud flag; still manual-on-enter only)
--       * input on|off (best-effort input enable; may require chat_ui already created)
--       * diag (prints a SAFE diagnostic snapshot)
--
--   - Phase 2 (NEW v2026-02-23C): Chat Manager feature toggles (SAFE):
--       * manager open|show|hide|toggle|status
--       * features (prints feature list + current values)
--       * feature <key> <on|off|value>
--       * defaults (reset manager defaults)
--
-- Design notes:
--   - Direct-control UI: chat_ui is applied via dwkit.ui.ui_manager.applyOne("chat_ui")
--     so dependency claims are handled centrally (ui_dependency_service via ui_manager).
--   - Visible is session-only by default (noSave=true).
--   - SAFE: no gameplay commands, no timers, no hidden automation.
--
-- Status semantics:
--   - "enabled" must be sourced from gui_settings (authoritative), not chat_ui.getState().
--   - "visible" prefers chat_ui.getState().visible; fallback to ui_base runtime store state.visible.
--
-- Sync semantics:
--   - hide/close/disable/toggle must go through ui_manager.applyOne("chat_ui")
--     so LaunchPad + runtime-visible stay in sync (applyOne triggers launchpad refresh).
--   - ui_manager_ui row refresh is best-effort (only if module is present/open).
--
-- Public API:
--   - dispatch(ctx, tokens)
--   - dispatch(tokens)   (best-effort)
-- #########################################################################

local M = {}

M.VERSION = "v2026-02-23C"

local function _out(ctx, line)
    if type(ctx) == "table" and type(ctx.out) == "function" then
        ctx.out(line)
        return
    end
    if type(cecho) == "function" then
        cecho(tostring(line or "") .. "\n")
    elseif type(echo) == "function" then
        echo(tostring(line or "") .. "\n")
    else
        print(tostring(line or ""))
    end
end

local function _err(ctx, msg)
    _out(ctx, "[DWKit Chat] ERROR: " .. tostring(msg))
end

local function _isArrayLike(t)
    if type(t) ~= "table" then return false end
    local n = #t
    if n == 0 then return false end
    for i = 1, n do
        if t[i] == nil then return false end
    end
    return true
end

local function _parseTokens(tokens)
    if not (_isArrayLike(tokens) and tostring(tokens[1] or "") == "dwchat") then
        return "", "", ""
    end
    local sub = tostring(tokens[2] or "")
    local uiId = tostring(tokens[3] or "")
    local arg3 = tostring(tokens[4] or "")
    return sub, uiId, arg3
end

local function _safeRequire(ctx, modName)
    if type(ctx) == "table" and type(ctx.safeRequire) == "function" then
        local ok, modOrErr = ctx.safeRequire(modName)
        if ok and type(modOrErr) == "table" then
            return true, modOrErr, nil
        end
        return false, nil, tostring(modOrErr)
    end
    local ok, modOrErr = pcall(require, modName)
    if ok and type(modOrErr) == "table" then
        return true, modOrErr, nil
    end
    return false, nil, tostring(modOrErr)
end

local function _getGuiSettingsFromCtx(ctx)
    if type(ctx) == "table" and type(ctx.getGuiSettings) == "function" then
        local ok, gs = pcall(ctx.getGuiSettings)
        if ok and type(gs) == "table" then
            return gs
        end
    end
    return nil
end

local function _ensureVisiblePersistenceSession(gs)
    if type(gs) ~= "table" or type(gs.enableVisiblePersistence) ~= "function" then
        return true
    end
    pcall(gs.enableVisiblePersistence, { noSave = true })
    return true
end

local function _setEnabled(gs, on)
    if type(gs) ~= "table" or type(gs.setEnabled) ~= "function" then
        return false, "guiSettings.setEnabled not available"
    end
    local ok, err = gs.setEnabled("chat_ui", (on == true), nil)
    if ok ~= true then
        return false, tostring(err or "setEnabled failed")
    end
    return true, nil
end

local function _setVisibleSession(gs, on)
    if type(gs) ~= "table" or type(gs.setVisible) ~= "function" then
        return false, "guiSettings.setVisible not available"
    end
    local ok, err = gs.setVisible("chat_ui", (on == true), { noSave = true })
    if ok ~= true then
        return false, tostring(err or "setVisible failed")
    end
    return true, nil
end

local function _getCfgVisibleBestEffort(gs)
    if type(gs) ~= "table" then return nil end

    if type(gs.getVisible) == "function" then
        local ok, v = pcall(gs.getVisible, "chat_ui", false)
        if ok then return (v == true) end
    end
    if type(gs.isVisible) == "function" then
        local ok, v = pcall(gs.isVisible, "chat_ui", false)
        if ok then return (v == true) end
    end
    return nil
end

local function _refreshUiManagerUiBestEffort()
    local ok, UI = pcall(require, "dwkit.ui.ui_manager_ui")
    if not ok or type(UI) ~= "table" then return false end

    if type(UI.refresh) == "function" then
        pcall(UI.refresh, { source = "dwchat:sync", quiet = true })
        return true
    end

    if type(UI.apply) == "function" then
        pcall(UI.apply, { source = "dwchat:sync", quiet = true })
        return true
    end

    return false
end

local function _applyChatViaUiManager(ctx, source)
    local okUM, UM = _safeRequire(ctx, "dwkit.ui.ui_manager")
    if okUM and type(UM.applyOne) == "function" then
        local okCall, okFlag, errOrNil = pcall(UM.applyOne, "chat_ui", { source = source or "dwchat", quiet = true })
        if okCall and okFlag ~= false then
            pcall(_refreshUiManagerUiBestEffort)
            return true, nil
        end
        return false, tostring(errOrNil or "ui_manager.applyOne(chat_ui) failed")
    end

    local okUI, UI = _safeRequire(ctx, "dwkit.ui.chat_ui")
    if okUI and type(UI.show) == "function" then
        local okCall, errOrNil = pcall(UI.show, { source = source or "dwchat", fixed = false, noClose = false })
        if okCall then
            pcall(_refreshUiManagerUiBestEffort)
            return true, nil
        end
        return false, tostring(errOrNil or "chat_ui.show failed")
    end

    return false, "ui_manager/chat_ui not available"
end

local function _hideChatViaUiManagerBestEffort(ctx, source)
    local okUM, UM = _safeRequire(ctx, "dwkit.ui.ui_manager")
    if okUM and type(UM.applyOne) == "function" then
        pcall(UM.applyOne, "chat_ui", { source = source or "dwchat:hide", quiet = true })
        pcall(_refreshUiManagerUiBestEffort)
        return true
    end

    local okUI, UI = _safeRequire(ctx, "dwkit.ui.chat_ui")
    if okUI and type(UI.hide) == "function" then
        pcall(UI.hide, { source = source or "dwchat:hide" })
        pcall(_refreshUiManagerUiBestEffort)
        return true
    end

    return true
end

local function _toggleViaUiManagerBestEffort(ctx, gs, source)
    local cur = _getCfgVisibleBestEffort(gs)
    if cur == nil then cur = false end

    _ensureVisiblePersistenceSession(gs)
    pcall(_setVisibleSession, gs, (cur ~= true))

    return _applyChatViaUiManager(ctx, source or "dwchat:toggle")
end

local function _getRuntimeVisibleFallback()
    local okB, U = pcall(require, "dwkit.ui.ui_base")
    if not okB or type(U) ~= "table" or type(U.getUiStoreEntry) ~= "function" then
        return nil
    end
    local okE, e = pcall(U.getUiStoreEntry, "chat_ui")
    if not okE or type(e) ~= "table" or type(e.state) ~= "table" then
        return nil
    end
    if e.state.visible == true then return true end
    if e.state.visible == false then return false end
    return nil
end

local function _printStatus(ctx, gs)
    local enabled = nil
    if type(gs) == "table" and type(gs.isEnabled) == "function" then
        local okE, v = pcall(gs.isEnabled, "chat_ui", false)
        if okE then enabled = (v == true) end
    end
    if enabled == nil then enabled = false end

    local okUI, UI = _safeRequire(ctx, "dwkit.ui.chat_ui")

    local visible = nil
    local activeTab = "?"
    local unreadOther = 0

    if okUI and type(UI) == "table" and type(UI.getState) == "function" then
        local okS, s = pcall(UI.getState)
        if okS and type(s) == "table" then
            if s.visible == true then visible = true end
            if s.visible == false then visible = false end
            if type(s.activeTab) == "string" then activeTab = s.activeTab end
            unreadOther = (s.unread and s.unread.Other) or 0
        end
    end

    if visible == nil then
        local rt = _getRuntimeVisibleFallback()
        if rt ~= nil then visible = rt end
    end

    if visible == nil then visible = false end

    _out(ctx, string.format(
        "[DWKit Chat] status visible=%s enabled=%s activeTab=%s unreadOther=%s",
        tostring(visible),
        tostring(enabled),
        tostring(activeTab),
        tostring(unreadOther)
    ))
    return true
end

local function _usage(ctx)
    _out(ctx, "[DWKit Chat] Usage:")
    _out(ctx, "  dwchat")
    _out(ctx, "  dwchat open|show")
    _out(ctx, "  dwchat hide|close")
    _out(ctx, "  dwchat toggle")
    _out(ctx, "  dwchat status")
    _out(ctx, "  dwchat diag")
    _out(ctx, "  dwchat enable")
    _out(ctx, "  dwchat disable")
    _out(ctx, "  dwchat tabs")
    _out(ctx, "  dwchat tab <All|SAY|PRIVATE|PUBLIC|GRATS|Other>")
    _out(ctx, "  dwchat clear")
    _out(ctx, "  dwchat send on|off")
    _out(ctx, "  dwchat input on|off")
    _out(ctx, "")
    _out(ctx, "  dwchat manager open|show|hide|toggle|status")
    _out(ctx, "  dwchat features")
    _out(ctx, "  dwchat feature <key> <on|off|value>")
    _out(ctx, "  dwchat defaults")
end

local function _parseOnOff(s)
    s = tostring(s or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if s == "on" or s == "true" or s == "1" then return true end
    if s == "off" or s == "false" or s == "0" then return false end
    return nil
end

local function _printTabs(ctx)
    local okUI, UI, e = _safeRequire(ctx, "dwkit.ui.chat_ui")
    if not okUI then
        return false, "chat_ui not available: " .. tostring(e)
    end

    local tabs = nil
    if type(UI.getTabs) == "function" then
        local ok, t = pcall(UI.getTabs)
        if ok and type(t) == "table" then tabs = t end
    end

    if type(tabs) ~= "table" then
        tabs = { "All", "SAY", "PRIVATE", "PUBLIC", "GRATS", "Other" }
    end

    _out(ctx, "[DWKit Chat] tabs: " .. tostring(table.concat(tabs, ", ")))
    return true, nil
end

local function _setTab(ctx, tab)
    tab = tostring(tab or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if tab == "" then
        return false, "tab required"
    end

    local okUI, UI, e = _safeRequire(ctx, "dwkit.ui.chat_ui")
    if not okUI then
        return false, "chat_ui not available: " .. tostring(e)
    end

    if type(UI.setActiveTab) == "function" then
        local ok, okFlag, errOrNil = pcall(UI.setActiveTab, tab, { source = "dwchat:tab" })
        if ok and okFlag ~= false then
            pcall(_refreshUiManagerUiBestEffort)
            return true, nil
        end
        return false, tostring(errOrNil or "chat_ui.setActiveTab failed")
    end

    if type(UI.getTabs) == "function" then
        return false, "chat_ui.setActiveTab not available"
    end

    return false, "chat_ui control API not available (missing setActiveTab)"
end

local function _clearChat(ctx)
    local okUI, UI = _safeRequire(ctx, "dwkit.ui.chat_ui")
    if okUI and type(UI.clear) == "function" then
        local ok, okFlag, errOrNil = pcall(UI.clear, { source = "dwchat:clear" })
        if ok and okFlag ~= false then
            return true, nil
        end
        return false, tostring(errOrNil or "chat_ui.clear failed")
    end

    local okS, SvcOrErr = pcall(require, "dwkit.services.chat_log_service")
    if okS and type(SvcOrErr) == "table" and type(SvcOrErr.clear) == "function" then
        local ok2 = pcall(SvcOrErr.clear, { source = "dwchat:clear" })
        if ok2 then
            _out(ctx, "[DWKit Chat] cleared (chat_log_service)")
            return true, nil
        end
        return false, "chat_log_service.clear failed"
    end

    return false, "clear not available (chat_ui.clear + chat_log_service.clear missing)"
end

local function _setSendToMud(ctx, on)
    local okUI, UI, e = _safeRequire(ctx, "dwkit.ui.chat_ui")
    if not okUI then
        return false, "chat_ui not available: " .. tostring(e)
    end
    if type(UI.setSendToMud) ~= "function" then
        return false, "chat_ui.setSendToMud not available"
    end
    local ok, okFlag, errOrNil = pcall(UI.setSendToMud, (on == true), { source = "dwchat:send" })
    if ok and okFlag ~= false then
        pcall(_refreshUiManagerUiBestEffort)
        return true, nil
    end
    return false, tostring(errOrNil or "chat_ui.setSendToMud failed")
end

local function _setInputEnabled(ctx, on)
    local okUI, UI, e = _safeRequire(ctx, "dwkit.ui.chat_ui")
    if not okUI then
        return false, "chat_ui not available: " .. tostring(e)
    end
    if type(UI.setInputEnabled) ~= "function" then
        return false, "chat_ui.setInputEnabled not available"
    end
    local ok, okFlag, errOrNil = pcall(UI.setInputEnabled, (on == true), { source = "dwchat:input" })
    if ok and okFlag ~= false then
        pcall(_refreshUiManagerUiBestEffort)
        return true, nil
    end
    return false, tostring(errOrNil or "chat_ui.setInputEnabled failed")
end

-- -------------------------------------------------------------------------
-- SAFE diagnostic snapshot (existing)
-- -------------------------------------------------------------------------

local function _getNowTs()
    if type(os) == "table" and type(os.time) == "function" then
        return os.time()
    end
    return 0
end

local function _getEnabledBestEffort(gs)
    if type(gs) == "table" and type(gs.isEnabled) == "function" then
        local ok, v = pcall(gs.isEnabled, "chat_ui", false)
        if ok then return (v == true) end
    end
    return false
end

local function _getCfgVisibleSessionBestEffort(gs)
    local v = _getCfgVisibleBestEffort(gs)
    if v == nil then return false end
    return (v == true)
end

local function _getChatUiStateBestEffort(ctx)
    local okUI, UI = _safeRequire(ctx, "dwkit.ui.chat_ui")
    if not okUI or type(UI) ~= "table" or type(UI.getState) ~= "function" then
        return nil, nil
    end
    local okS, s = pcall(UI.getState)
    if not okS or type(s) ~= "table" then
        return nil, nil
    end
    local unread = s.unread or {}
    return {
        visible = (s.visible == true),
        activeTab = tostring(s.activeTab or "?"),
        enableInput = (s.enableInput == true),
        sendToMud = (s.sendToMud == true),
        unread = {
            SAY = tonumber(unread.SAY or 0) or 0,
            PRIVATE = tonumber(unread.PRIVATE or 0) or 0,
            PUBLIC = tonumber(unread.PUBLIC or 0) or 0,
            GRATS = tonumber(unread.GRATS or 0) or 0,
            Other = tonumber(unread.Other or 0) or 0,
            All = tonumber(unread.All or 0) or 0,
        },
    }, nil
end

local function _getLogMetaBestEffort(ctx)
    local okL, LogOrErr = pcall(require, "dwkit.services.chat_log_service")
    if not okL or type(LogOrErr) ~= "table" then
        return nil, "chat_log_service not available: " .. tostring(LogOrErr)
    end
    local Log = LogOrErr

    local meta = { count = 0, latestId = 0, profileTag = "?" }

    if type(Log.getState) == "function" then
        local okS, st = pcall(Log.getState, {})
        if okS and type(st) == "table" then
            meta.count = tonumber(st.count or 0) or 0
            meta.latestId = tonumber(st.latestId or 0) or 0
            meta.profileTag = tostring(st.profileTag or meta.profileTag)
            return meta, nil
        end
    end

    if type(Log.getItems) == "function" then
        local okI, _, m = pcall(Log.getItems, nil, {})
        if okI and type(m) == "table" then
            meta.latestId = tonumber(m.latestId or 0) or 0
            meta.count = tonumber(m.count or 0) or 0
            meta.profileTag = tostring(m.profileTag or meta.profileTag)
            return meta, nil
        end
    end

    return meta, nil
end

local function _getRouterVersionBestEffort(ctx)
    local okR, R = _safeRequire(ctx, "dwkit.services.chat_router_service")
    if not okR or type(R) ~= "table" then return nil end
    if type(R.getVersion) == "function" then
        local ok, v = pcall(R.getVersion)
        if ok and type(v) == "string" then return v end
    end
    return (type(R.VERSION) == "string" and R.VERSION) or nil
end

local function _getCaptureDebugBestEffort(ctx)
    local okC, C = _safeRequire(ctx, "dwkit.capture.chat_capture")
    if not okC or type(C) ~= "table" then return nil end

    local dbg = nil
    if type(C.getDebugState) == "function" then
        local ok, v = pcall(C.getDebugState)
        if ok and type(v) == "table" then dbg = v end
    end

    local installed = nil
    if type(C.isInstalled) == "function" then
        local ok, v = pcall(C.isInstalled)
        if ok then installed = (v == true) end
    elseif type(dbg) == "table" and dbg.installed ~= nil then
        installed = (dbg.installed == true)
    end

    return {
        installed = (installed == true),
        debug = dbg,
    }
end

local function _getManagerCfgBestEffort()
    local ok, Mgr = pcall(require, "dwkit.services.chat_manager")
    if not ok or type(Mgr) ~= "table" then return nil end
    if type(Mgr.getConfig) ~= "function" then return nil end
    local ok2, cfg = pcall(Mgr.getConfig)
    if ok2 and type(cfg) == "table" then
        return cfg
    end
    return nil
end

local function _printDiag(ctx, gs)
    local now = _getNowTs()

    local enabled = _getEnabledBestEffort(gs)
    local cfgVisible = _getCfgVisibleSessionBestEffort(gs)

    local uiState, uiErr = _getChatUiStateBestEffort(ctx)
    local rtVisible = _getRuntimeVisibleFallback()

    local logMeta, logErr = _getLogMetaBestEffort(ctx)
    local routerVer = _getRouterVersionBestEffort(ctx)
    local cap = _getCaptureDebugBestEffort(ctx)
    local mgrCfg = _getManagerCfgBestEffort()

    _out(ctx, "============================================================")
    _out(ctx, "[DWKit Chat] diag (SAFE)")
    _out(ctx, string.format("[diag] ts=%s", tostring(now)))
    _out(ctx, string.format("[diag] dwchat.version=%s", tostring(M.VERSION)))
    _out(ctx, string.format("[diag] enabled=%s cfgVisible(session)=%s rtVisible=%s",
        tostring(enabled), tostring(cfgVisible), tostring(rtVisible)))

    if type(uiState) == "table" then
        local u = uiState.unread or {}
        _out(ctx, string.format("[diag] chat_ui visible=%s activeTab=%s input=%s sendToMud=%s",
            tostring(uiState.visible), tostring(uiState.activeTab), tostring(uiState.enableInput),
            tostring(uiState.sendToMud)))
        _out(ctx, string.format("[diag] unread SAY=%s PRIVATE=%s PUBLIC=%s GRATS=%s Other=%s All=%s",
            tostring(u.SAY or 0), tostring(u.PRIVATE or 0), tostring(u.PUBLIC or 0), tostring(u.GRATS or 0),
            tostring(u.Other or 0), tostring(u.All or 0)))
    else
        _out(ctx, string.format("[diag] chat_ui state unavailable (%s)", tostring(uiErr or "no getState")))
    end

    if type(logMeta) == "table" then
        _out(ctx, string.format("[diag] chat_log meta.count=%s meta.latestId=%s meta.profileTag=%s",
            tostring(logMeta.count), tostring(logMeta.latestId), tostring(logMeta.profileTag)))
    else
        _out(ctx, string.format("[diag] chat_log unavailable (%s)", tostring(logErr or "unknown")))
    end

    _out(ctx, string.format("[diag] chat_router version=%s", tostring(routerVer or "?")))

    if type(cap) == "table" then
        _out(ctx, string.format("[diag] chat_capture installed=%s", tostring(cap.installed)))
        local d = cap.debug or {}
        if type(d) == "table" then
            _out(ctx,
                string.format(
                    "[diag] chat_capture seen=%s forwarded=%s ignoredPrompt=%s ignoredEmpty=%s lastOkTs=%s lastErr=%s",
                    tostring(d.seenCount), tostring(d.forwardedCount), tostring(d.ignoredPromptCount),
                    tostring(d.ignoredEmptyCount),
                    tostring(d.lastOkTs), tostring(d.lastErr)))
        end
    else
        _out(ctx, "[diag] chat_capture not available")
    end

    if type(mgrCfg) == "table" and type(mgrCfg.features) == "table" then
        local f = mgrCfg.features
        _out(ctx,
            string.format(
                "[diag] chat_manager all_unread_badge=%s auto_scroll_follow=%s per_tab_line_limit=%s per_tab_line_limit_n=%s timestamp_prefix=%s debug_overlay=%s",
                tostring(f.all_unread_badge), tostring(f.auto_scroll_follow), tostring(f.per_tab_line_limit),
                tostring(f.per_tab_line_limit_n), tostring(f.timestamp_prefix), tostring(f.debug_overlay)))
    else
        _out(ctx, "[diag] chat_manager unavailable")
    end

    _out(ctx, "============================================================")
    return true, nil
end

-- -------------------------------------------------------------------------
-- Phase 2 manager helpers
-- -------------------------------------------------------------------------

local function _mgr()
    local ok, Mgr = pcall(require, "dwkit.services.chat_manager")
    if ok and type(Mgr) == "table" then return Mgr end
    return nil
end

local function _mgrUi()
    local ok, UI = pcall(require, "dwkit.ui.chat_manager_ui")
    if ok and type(UI) == "table" then return UI end
    return nil
end

local function _printFeatures(ctx)
    local Mgr = _mgr()
    if not Mgr then
        return false, "chat_manager not available"
    end
    local cfg = Mgr.getConfig()
    local feats = cfg.features or {}
    _out(ctx, "[DWKit Chat] features:")
    local list = Mgr.listFeatures()
    for _, f in ipairs(list) do
        local key = tostring(f.key)
        local val = feats[key]
        _out(ctx, string.format("  - %s = %s", key, tostring(val)))
    end
    return true, nil
end

local function _setFeature(ctx, key, value)
    local Mgr = _mgr()
    if not Mgr then
        return false, "chat_manager not available"
    end
    key = tostring(key or "")
    if key == "" then return false, "feature key required" end
    local ok, err = Mgr.setFeature(key, value, { source = "dwchat:feature", apply = true })
    if not ok then
        return false, err
    end
    _out(ctx, "[DWKit Chat] feature set: " .. tostring(key) .. "=" .. tostring(Mgr.getFeature(key)))
    return true, nil
end

local function _mgrDefaults(ctx)
    local Mgr = _mgr()
    if not Mgr then
        return false, "chat_manager not available"
    end
    local ok, err = Mgr.resetDefaults({ source = "dwchat:defaults", apply = true })
    if not ok then return false, err end
    _out(ctx, "[DWKit Chat] chat_manager defaults restored")
    return true, nil
end

local function _mgrStatus(ctx)
    local Mgr = _mgr()
    if not Mgr then
        _out(ctx, "[DWKit Chat] manager status: unavailable")
        return true, nil
    end
    local cfg = Mgr.getConfig()
    local f = cfg.features or {}
    _out(ctx,
        string.format(
            "[DWKit Chat] manager status all_unread_badge=%s auto_scroll_follow=%s per_tab_line_limit=%s per_tab_line_limit_n=%s timestamp_prefix=%s debug_overlay=%s",
            tostring(f.all_unread_badge), tostring(f.auto_scroll_follow), tostring(f.per_tab_line_limit),
            tostring(f.per_tab_line_limit_n), tostring(f.timestamp_prefix), tostring(f.debug_overlay)))
    return true, nil
end

local function _mgrOpen(ctx)
    local UI = _mgrUi()
    if not UI then
        return false, "chat_manager_ui not available"
    end
    local ok, err = UI.show({ source = "dwchat:manager" })
    if not ok then return false, err end
    _out(ctx, "[DWKit Chat] manager shown")
    return true, nil
end

local function _mgrHide(ctx)
    local UI = _mgrUi()
    if not UI then
        return false, "chat_manager_ui not available"
    end
    UI.hide({ source = "dwchat:manager" })
    _out(ctx, "[DWKit Chat] manager hidden")
    return true, nil
end

local function _mgrToggle(ctx)
    local UI = _mgrUi()
    if not UI then
        return false, "chat_manager_ui not available"
    end
    UI.toggle({ source = "dwchat:manager" })
    _out(ctx, "[DWKit Chat] manager toggled")
    return true, nil
end

-- -------------------------------------------------------------------------
-- Dispatch
-- -------------------------------------------------------------------------

function M.dispatch(...)
    local a1, a2 = ...
    local ctx = nil
    local tokens = nil

    if type(a1) == "table" and _isArrayLike(a2) then
        ctx = a1
        tokens = a2
    elseif _isArrayLike(a1) then
        tokens = a1
    else
        return false, "invalid args"
    end

    local sub, arg2, arg3 = _parseTokens(tokens)
    sub = tostring(sub or "")

    if sub == "" then sub = "open" end

    local gs = _getGuiSettingsFromCtx(ctx)
    if type(gs) ~= "table" then
        local okGS, gs2 = pcall(require, "dwkit.config.gui_settings")
        if okGS and type(gs2) == "table" then gs = gs2 end
    end
    if type(gs) ~= "table" then
        _err(ctx, "guiSettings not available")
        return false, "guiSettings not available"
    end

    do
        local okUM, UM = _safeRequire(ctx, "dwkit.ui.ui_manager")
        if okUM and type(UM.seedRegisteredDefaults) == "function" then
            pcall(UM.seedRegisteredDefaults, { save = false })
        end
    end

    -- Phase 2 manager namespace (dwchat manager ...)
    if sub == "manager" then
        local action = tostring(arg2 or "")
        if action == "" or action == "open" or action == "show" then
            local ok, err = _mgrOpen(ctx)
            if not ok then
                _err(ctx, tostring(err))
                return false, err
            end
            return true, nil
        end
        if action == "hide" or action == "close" then
            local ok, err = _mgrHide(ctx)
            if not ok then
                _err(ctx, tostring(err))
                return false, err
            end
            return true, nil
        end
        if action == "toggle" then
            local ok, err = _mgrToggle(ctx)
            if not ok then
                _err(ctx, tostring(err))
                return false, err
            end
            return true, nil
        end
        if action == "status" then
            _mgrStatus(ctx)
            return true, nil
        end

        _usage(ctx)
        return true, nil
    end

    if sub == "features" then
        local ok, err = _printFeatures(ctx)
        if not ok then
            _err(ctx, tostring(err))
            return false, err
        end
        return true, nil
    end

    if sub == "feature" then
        local key = tostring(arg2 or "")
        local val = arg3

        if key == "" then
            _usage(ctx)
            return true, nil
        end

        local parsed = _parseOnOff(val)
        if parsed ~= nil then
            local ok, err = _setFeature(ctx, key, parsed)
            if not ok then
                _err(ctx, tostring(err))
                return false, err
            end
            return true, nil
        end

        -- allow numeric value (e.g., per_tab_line_limit_n 800)
        local n = tonumber(val)
        if n ~= nil then
            local ok, err = _setFeature(ctx, key, n)
            if not ok then
                _err(ctx, tostring(err))
                return false, err
            end
            return true, nil
        end

        _usage(ctx)
        return true, nil
    end

    if sub == "defaults" then
        local ok, err = _mgrDefaults(ctx)
        if not ok then
            _err(ctx, tostring(err))
            return false, err
        end
        return true, nil
    end

    if sub == "status" then
        _printStatus(ctx, gs)
        return true, nil
    end

    if sub == "diag" then
        local ok, err = _printDiag(ctx, gs)
        if not ok then
            _err(ctx, tostring(err))
            return false, err
        end
        return true, nil
    end

    if sub == "tabs" then
        local ok, err = _printTabs(ctx)
        if not ok then
            _err(ctx, tostring(err))
            return false, err
        end
        return true, nil
    end

    if sub == "tab" then
        local tabName = tostring(arg2 or "")
        if tabName == "" then
            _usage(ctx)
            return true, nil
        end
        local ok, err = _setTab(ctx, tabName)
        if not ok then
            _err(ctx, tostring(err))
            return false, err
        end
        _out(ctx, "[DWKit Chat] tab set: " .. tostring(tabName))
        return true, nil
    end

    if sub == "clear" then
        local ok, err = _clearChat(ctx)
        if not ok then
            _err(ctx, tostring(err))
            return false, err
        end
        _out(ctx, "[DWKit Chat] cleared")
        return true, nil
    end

    if sub == "send" then
        local v = _parseOnOff(arg2)
        if v == nil then
            _usage(ctx)
            return true, nil
        end
        local ok, err = _setSendToMud(ctx, v)
        if not ok then
            _err(ctx, tostring(err))
            return false, err
        end
        _out(ctx, "[DWKit Chat] sendToMud=" .. (v and "ON" or "OFF") .. " (manual on Enter)")
        return true, nil
    end

    if sub == "input" then
        local v = _parseOnOff(arg2)
        if v == nil then
            _usage(ctx)
            return true, nil
        end
        local ok, err = _setInputEnabled(ctx, v)
        if not ok then
            _err(ctx, tostring(err))
            return false, err
        end
        _out(ctx, "[DWKit Chat] input=" .. (v and "ON" or "OFF"))
        return true, nil
    end

    if sub == "enable" then
        local ok, err = _setEnabled(gs, true)
        if not ok then
            _err(ctx, "enable failed: " .. tostring(err))
            return false, err
        end
        pcall(_refreshUiManagerUiBestEffort)
        _out(ctx, "[DWKit Chat] enabled=ON (chat_ui)")
        return true, nil
    end

    if sub == "disable" then
        local ok, err = _setEnabled(gs, false)
        if not ok then
            _err(ctx, "disable failed: " .. tostring(err))
            return false, err
        end

        _ensureVisiblePersistenceSession(gs)
        pcall(_setVisibleSession, gs, false)

        pcall(_applyChatViaUiManager, ctx, "dwchat:disable")

        _out(ctx, "[DWKit Chat] enabled=OFF (chat_ui)")
        return true, nil
    end

    if sub == "hide" or sub == "close" then
        _ensureVisiblePersistenceSession(gs)
        local okV, errV = _setVisibleSession(gs, false)
        if not okV then
            _err(ctx, "setVisible OFF failed: " .. tostring(errV))
        end

        _hideChatViaUiManagerBestEffort(ctx, "dwchat:hide")

        _out(ctx, "[DWKit Chat] hidden (chat_ui)")
        return true, nil
    end

    if sub == "toggle" then
        local okT, errT = _toggleViaUiManagerBestEffort(ctx, gs, "dwchat:toggle")
        if not okT and errT then
            _err(ctx, "toggle failed: " .. tostring(errT))
            return false, errT
        end
        _out(ctx, "[DWKit Chat] toggled (chat_ui)")
        return true, nil
    end

    if sub == "open" or sub == "show" then
        _ensureVisiblePersistenceSession(gs)

        local okEn, errEn = _setEnabled(gs, true)
        if not okEn then
            _err(ctx, "enable failed: " .. tostring(errEn))
            return false, errEn
        end

        local okVis, errVis = _setVisibleSession(gs, true)
        if not okVis then
            _err(ctx, "setVisible ON failed: " .. tostring(errVis))
            return false, errVis
        end

        local okApply, errApply = _applyChatViaUiManager(ctx, "dwchat")
        if not okApply then
            _err(ctx, "apply failed: " .. tostring(errApply))
            return false, errApply
        end

        _out(ctx, "[DWKit Chat] shown (dwchat)")
        return true, nil
    end

    _usage(ctx)
    return true, nil
end

return M
