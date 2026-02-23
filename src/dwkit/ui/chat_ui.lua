-- FILE: src/dwkit/ui/chat_ui.lua
-- #########################################################################
-- Module Name : dwkit.ui.chat_ui
-- Owner       : UI
-- Version     : v2026-02-23B
-- Purpose     :
--   - SAFE Chat UI (consumer-only) displaying ChatLogService buffer.
--   - Renders a DWKit-themed container with a tab row:
--       All | SAY | PRIVATE | PUBLIC | GRATS | Other
--   - Event-driven refresh on DWKit:Service:ChatLog:Updated while visible.
--   - Unread counts on non-All tabs by default; clears when user views that tab.
--   - Bottom input line (EMCO-like typing area):
--       * DEFAULT ON (still SAFE: local-only unless sendToMud=true).
--       * When enabled, submitting text is an explicit user action (Enter).
--       * By default, submission is LOCAL-ONLY: appends to ChatLogService (no send()).
--       * Optional sendToMud=true will call send(text) ONLY on user submit (still manual).
--   - No timers, no GMCP.
--
-- Phase 2 (v2026-02-23B):
--   - Feature effects are implemented (not just stored):
--       * all_unread_badge (default OFF)
--       * auto_scroll_follow (default OFF)
--       * per_tab_line_limit (default OFF) + per_tab_line_limit_n (default 500)
--       * timestamp_prefix (default OFF)
--       * debug_overlay (default OFF)  -> ALSO affects layout (no extra gap when OFF)
--   - Adds renderDebug instrumentation for deterministic dwverify assertions.
--
-- Public API:
--   - getVersion() -> string
--   - getState() -> table { visible=bool, activeTab=string, unread=table, enableInput=bool, sendToMud=bool }
--   - show(opts?) / hide(opts?) / toggle(opts?)
--   - refresh(opts?) -> boolean ok
--   - dispose() -> boolean ok
--   - getLayoutDebug() -> table (sizes, best-effort)
--
-- Phase 1 Control Surface:
--   - getTabs() -> string[] (TAB_ORDER copy)
--   - setActiveTab(tab, opts?) -> boolean ok, string|nil err
--   - clear(opts?) -> boolean ok, string|nil err      (clears ChatLogService)
--   - setSendToMud(on, opts?) -> boolean ok
--   - setInputEnabled(on, opts?) -> boolean ok, string|nil err (best-effort)
--
-- Phase 2 Control Surface:
--   - setFeatureConfig(cfg, opts?) -> boolean ok (best-effort)
--   - getFeatureConfig() -> table { features = {...} } (best-effort)
--
-- Notes:
--   - Tab definitions are LOCKED by agreement v2026-02-10C.
--   - chat_ui is a DIRECT-CONTROL UI (see UI Manager direct-control rule).
--   - Provider lifecycle is ENABLED-based (Model A) and is owned by ui_manager + ui_dependency_service.
--     Therefore chat_ui MUST NOT ensure/release providers on show/hide/dispose.
-- #########################################################################

local M                         = {}

M.VERSION                       = "v2026-02-23B"

local PREFIX                    = (DWKit and DWKit.getEventPrefix and DWKit.getEventPrefix()) or "DWKit:"
local LogSvc                    = require("dwkit.services.chat_log_service")
local UIW                       = require("dwkit.ui.ui_window")
local U                         = require("dwkit.ui.ui_base")

local EV_SVC_CHATLOG_UPDATED    = PREFIX .. "Service:ChatLog:Updated"

local EV_SYS_WINDOW_RESIZE      = "sysWindowResizeEvent"

local EV_USER_RESIZE_CANDIDATES = {
    "sysUserWindowResizeEvent",
    "sysUserWindowResizedEvent",
    "sysWindowResizedEvent",
    "sysContainerResizeEvent",
    "sysAdjustableContainerResizeEvent",
}

local UI_ID                     = "chat_ui"
local TITLE                     = "Chat"

local TAB_ORDER                 = { "All", "SAY", "PRIVATE", "PUBLIC", "GRATS", "Other" }

local PRIVATE_CH                = { TELL = true, ASK = true, WHISPER = true }
local PUBLIC_CH                 = { SHOUT = true, YELL = true, GOSSIP = true }

local st                        = {
    visible = false,
    bundle = nil,

    bodyFill = nil,

    tabBar = nil,
    tabButtons = {},

    consoleHost = nil,
    console = nil,

    inputHost = nil,
    input = nil,
    enableInput = true,
    sendToMud = false,

    -- debug label (slot; height collapses to 0 when feature OFF)
    debugLabel = nil,

    -- Feature config (defaults preserve v1)
    featureCfg = {
        features = {
            all_unread_badge = false,
            auto_scroll_follow = false,
            per_tab_line_limit = false,
            per_tab_line_limit_n = 500,
            timestamp_prefix = false,
            debug_overlay = false,
        },
    },

    -- Render instrumentation for deterministic dwverify
    renderDebug = {
        lastActiveTab = "All",
        lastTabCount = 0,   -- count of items matching active tab (before slicing)
        lastShownCount = 0, -- rendered lines count (after slicing)
        lastLimitOn = false,
        lastLimitN = nil,
        lastTimestampOn = false,
        lastDebugOverlayOn = false,
        lastConsoleY = nil,
        lastContentY = nil,
        lastFirstLine = "",
        lastLastLine = "",
    },

    layout = {
        tabH = 24,
        insetY = 0,
        gapY = 2,
        yContent = 0,
        usedHostFill = true,

        debugH = 16,  -- reserved height when debug overlay ON
        yDebug = 0,   -- computed
        yConsole = 0, -- computed

        inputH = 26,
        inputGapY = 0,
        usedInput = true,
        inputKind = "none",

        bottomFudge = 22,

        measured = {
            contentW = nil,
            contentH = nil,
            targetH = nil,
            bodyW = nil,
            bodyH = nil,
            consoleH = nil,
            inputY = nil,
            inputInnerY = nil,
            inputInnerH = nil,
        },
    },

    handler = nil,
    handlerKind = nil,
    handlerKey = nil,

    resizeHandlers = nil,

    activeTab = "All",
    unread = {},
    lastSeenId = {},
    lastRenderedId = 0,
}

local function _isNonEmptyString(s) return type(s) == "string" and s ~= "" end

local function _normChannel(ch)
    if type(ch) ~= "string" then return "" end
    return (ch:gsub("^%s+", ""):gsub("%s+$", "")):upper()
end

local function _tabForChannel(channel)
    local ch = _normChannel(channel)
    if ch == "SAY" then return "SAY" end
    if ch == "GRATS" then return "GRATS" end
    if PRIVATE_CH[ch] then return "PRIVATE" end
    if PUBLIC_CH[ch] then return "PUBLIC" end
    if ch == "" then return "Other" end
    return "Other"
end

local function _passesTab(item, tab)
    if tab == "All" then return true end

    local ch = _normChannel(item and item.channel)
    if tab == "SAY" then return ch == "SAY" end
    if tab == "GRATS" then return ch == "GRATS" end
    if tab == "PRIVATE" then return PRIVATE_CH[ch] == true end
    if tab == "PUBLIC" then return PUBLIC_CH[ch] == true end

    if tab == "Other" then
        local mapped = (ch == "SAY") or (ch == "GRATS") or (PRIVATE_CH[ch] == true) or (PUBLIC_CH[ch] == true)
        return not mapped
    end

    return false
end

local function _fmtHMS(ts)
    ts = tonumber(ts)
    if not ts or ts <= 0 then return nil end
    if type(os) ~= "table" or type(os.date) ~= "function" then return nil end
    local ok, s = pcall(os.date, "%H:%M:%S", ts)
    if ok and type(s) == "string" then return s end
    return nil
end

local function _mkLine(item)
    local feats    = (st.featureCfg and st.featureCfg.features) or {}
    local wantTs   = (feats.timestamp_prefix == true)

    local speaker  = _isNonEmptyString(item.speaker) and item.speaker or nil
    local target   = _isNonEmptyString(item.target) and item.target or nil

    local chRaw    = _isNonEmptyString(item.channel) and item.channel or ""
    local chan     = (chRaw ~= "" and ("[" .. chRaw .. "] ") or "")

    local tsPrefix = ""
    if wantTs then
        local t = _fmtHMS(item and item.ts)
        if t then
            tsPrefix = "[" .. t .. "] "
        end
    end

    if speaker and target then
        return string.format("%s%s%s -> %s: %s", tsPrefix, chan, speaker, target, tostring(item.text))
    end

    if speaker then
        return string.format("%s%s%s: %s", tsPrefix, chan, speaker, tostring(item.text))
    end

    return string.format("%s%s%s", tsPrefix, chan, tostring(item.text))
end

local function _clearConsole()
    if type(st.console) == "table" and type(st.console.clear) == "function" then
        pcall(function() st.console:clear() end)
    end
end

local function _appendConsoleLine(line)
    if type(st.console) == "table" and type(st.console.cecho) == "function" then
        pcall(function() st.console:cecho(tostring(line) .. "\n") end)
        return
    end
    if type(st.console) == "table" and type(st.console.echo) == "function" then
        pcall(function() st.console:echo(tostring(line) .. "\n") end)
    end
end

local function _scrollToBottomBestEffort()
    local feats = (st.featureCfg and st.featureCfg.features) or {}
    if feats.auto_scroll_follow ~= true then return end
    if type(st.console) ~= "table" then return end

    for _, fn in ipairs({ "scrollToEnd", "scrollToBottom", "scrollToBottomLine", "scrollEnd" }) do
        if type(st.console[fn]) == "function" then
            pcall(function() st.console[fn](st.console) end)
            return
        end
    end
end

local function _debugLine()
    local feats = (st.featureCfg and st.featureCfg.features) or {}
    if feats.debug_overlay ~= true then
        return ""
    end

    local u = st.unread or {}
    local function n(k) return tostring(tonumber(u[k] or 0) or 0) end
    return string.format(
        "debug: active=%s lastRenderedId=%s unread(SAY=%s PRIVATE=%s PUBLIC=%s GRATS=%s Other=%s)",
        tostring(st.activeTab),
        tostring(st.lastRenderedId),
        n("SAY"), n("PRIVATE"), n("PUBLIC"), n("GRATS"), n("Other")
    )
end

local function _applyDebugLabelBestEffort()
    if type(st.debugLabel) ~= "table" then return end
    local txt = _debugLine()
    if type(st.debugLabel.echo) == "function" then
        pcall(function()
            st.debugLabel:echo(txt == "" and "" or (" " .. txt .. " "))
        end)
    end
    if type(st.debugLabel.setStyleSheet) == "function" then
        local feats = (st.featureCfg and st.featureCfg.features) or {}
        if feats.debug_overlay == true then
            pcall(function()
                st.debugLabel:setStyleSheet([[
                    background-color: rgba(0,0,0,0);
                    border: 0px;
                    color: #8b93a6;
                    font-size: 8pt;
                    qproperty-alignment: 'AlignVCenter | AlignLeft';
                ]])
            end)
        else
            pcall(function()
                st.debugLabel:setStyleSheet([[
                    background-color: rgba(0,0,0,0);
                    border: 0px;
                    color: rgba(0,0,0,0);
                    font-size: 1pt;
                ]])
            end)
        end
    end
end

local function _tabLabelText(tab)
    tab = tostring(tab or "")
    local feats = (st.featureCfg and st.featureCfg.features) or {}
    local showAllUnread = (feats.all_unread_badge == true)

    local n = tonumber(st.unread[tab] or 0) or 0

    if tab == "All" then
        if showAllUnread and n > 0 and tab ~= st.activeTab then
            return string.format("%s (%d)", tab, n)
        end
        return tab
    end

    if n > 0 and tab ~= st.activeTab then
        return string.format("%s (%d)", tab, n)
    end
    return tab
end

local function _tabStyle(active, hasUnread)
    local bg = active and "rgba(30,59,90,200)" or "#14181f"
    local border = active and "#4a6fa5" or "#2a2f3a"
    local fg = "#e5e9f0"
    if (not active) and hasUnread then fg = "#ffd166" end

    return table.concat({
        "background-color: ", bg, ";",
        "border: 1px solid ", border, ";",
        "border-radius: 6px;",
        "color: ", fg, ";",
        "padding-left: 6px;",
        "padding-right: 6px;",
        "font-size: 8pt;",
        "qproperty-alignment: 'AlignVCenter | AlignHCenter';",
    }, "")
end

local function _applyTabStyleBestEffort(tab)
    local btn = st.tabButtons[tab]
    if type(btn) ~= "table" then return end
    local active = (tab == st.activeTab)
    local unread = tonumber(st.unread[tab] or 0) or 0
    local feats = (st.featureCfg and st.featureCfg.features) or {}
    local showAllUnread = (feats.all_unread_badge == true)

    local hasUnread = false
    if tab == "All" then
        hasUnread = (showAllUnread and unread > 0 and (not active))
    else
        hasUnread = (unread > 0 and (not active))
    end

    if type(btn.setStyleSheet) == "function" then
        pcall(function() btn:setStyleSheet(_tabStyle(active, hasUnread)) end)
    end
end

local function _applyTabBarStyleBestEffort()
    if type(st.tabBar) ~= "table" then return end
    if type(st.tabBar.setStyleSheet) == "function" then
        pcall(function()
            st.tabBar:setStyleSheet([[
                background-color: rgba(0,0,0,0);
                border: 0px;
                border-bottom: 1px solid #2a2f3a;
                margin: 0px;
                padding: 0px;
            ]])
        end)
    end
end

local function _renderTabButtons()
    for _, tab in ipairs(TAB_ORDER) do
        local btn = st.tabButtons[tab]
        if type(btn) == "table" and type(btn.echo) == "function" then
            pcall(function() btn:echo(" " .. _tabLabelText(tab) .. " ") end)
        end
        _applyTabStyleBestEffort(tab)
    end
    _applyDebugLabelBestEffort()
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

local function _applyBundleContentNoInsetBestEffort()
    if type(st.bundle) ~= "table" or type(st.bundle.content) ~= "table" then return end
    if type(st.bundle.content.setStyleSheet) == "function" then
        pcall(function()
            st.bundle.content:setStyleSheet([[
                background-color: rgba(0,0,0,0);
                border: 0px;
                border-radius: 0px;
                margin: 0px;
                padding: 0px;
            ]])
        end)
    end
end

local function _applyBodyFillStyleBestEffort()
    if type(st.bodyFill) ~= "table" then return end
    if type(st.bodyFill.setStyleSheet) == "function" then
        pcall(function()
            st.bodyFill:setStyleSheet([[
                background-color: rgba(0,0,0,130);
                border: 0px;
                border-radius: 0px;
                margin: 0px;
                padding: 0px;
            ]])
        end)
    end
end

local function _applyConsoleTransparentBestEffort()
    if type(st.console) ~= "table" then return end

    if type(st.console.setStyleSheet) == "function" then
        pcall(function()
            st.console:setStyleSheet([[
                background-color: rgba(0,0,0,0);
                border: 0px;
                border-radius: 0px;
                margin: 0px;
                padding: 0px;
            ]])
        end)
    end

    if type(st.console.setColor) == "function" then
        pcall(function() st.console:setColor(0, 0, 0, 0) end)
    end
end

local function _applyCommandLineStyleBestEffort(cmdName)
    cmdName = tostring(cmdName or "")
    if cmdName == "" then return end

    local css = [[
        QLineEdit {
            background-color: rgba(10,12,16,210);
            color: #e5e9f0;
            border: 1px solid #2a2f3a;
            border-radius: 6px;
            padding: 2px;
        }
        QLineEdit:focus {
            border: 1px solid #4a6fa5;
        }
    ]]

    if type(_G.setCommandLineStyleSheet) == "function" then
        pcall(function() _G.setCommandLineStyleSheet(cmdName, css) end)
        return
    end

    if type(st.input) == "table" and type(st.input.setStyleSheet) == "function" then
        pcall(function() st.input:setStyleSheet(css) end)
    end
end

local function _focusInputBestEffort()
    if type(st.input) ~= "table" then return end
    if type(st.input.setFocus) == "function" then
        pcall(function() st.input:setFocus() end)
        return
    end
    if type(st.input.focus) == "function" then
        pcall(function() st.input:focus() end)
    end
end

local function _num(v)
    v = tonumber(v)
    return (v and v > 0) and v or nil
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

local function _computeYConsoleBestEffort()
    local feats = (st.featureCfg and st.featureCfg.features) or {}
    local debugOn = (feats.debug_overlay == true)

    local yContent = tonumber(st.layout.yContent or 0) or 0
    local debugH = tonumber(st.layout.debugH or 0) or 0
    if debugH < 0 then debugH = 0 end

    st.layout.yDebug = yContent
    st.layout.yConsole = yContent + (debugOn and debugH or 0)

    st.renderDebug.lastDebugOverlayOn = debugOn
    st.renderDebug.lastConsoleY = st.layout.yConsole
    st.renderDebug.lastContentY = yContent

    -- Best-effort: collapse debug label height when OFF
    if type(st.debugLabel) == "table" then
        if debugOn then
            _moveResizeBestEffort(st.debugLabel, 0, yContent, "100%", debugH)
        else
            _moveResizeBestEffort(st.debugLabel, 0, yContent, "100%", 0)
        end
    end

    -- Best-effort: move consoleHost to computed yConsole (height will be finalized in reflow)
    if type(st.consoleHost) == "table" then
        _moveResizeBestEffort(st.consoleHost, 0, st.layout.yConsole, "100%", "100%")
    end
end

local function _reflowLayoutBestEffort()
    if type(st.bundle) ~= "table" or type(st.bundle.content) ~= "table" then return false end
    if type(st.bodyFill) ~= "table" then return false end
    if type(st.consoleHost) ~= "table" then return false end

    local contentW, contentH = _getWHBestEffort(st.bundle.content)
    if not contentW or not contentH then
        return false
    end

    -- recompute yConsole based on debug overlay flag (real feature effect)
    pcall(_computeYConsoleBestEffort)

    local fudge = tonumber(st.layout.bottomFudge or 0) or 0
    local targetH = math.max(0, contentH + fudge)

    _moveResizeBestEffort(st.bodyFill, 0, 0, contentW, targetH)

    local bodyW, bodyH = _getWHBestEffort(st.bodyFill)
    bodyW = bodyW or contentW
    bodyH = bodyH or targetH

    local yConsole = tonumber(st.layout.yConsole or 0) or 0
    local inputH = (st.enableInput == true) and (tonumber(st.layout.inputH or 0) or 0) or 0

    local consoleH = math.max(0, bodyH - yConsole - inputH)
    local ok = true

    ok = _moveResizeBestEffort(st.consoleHost, 0, yConsole, bodyW, consoleH) and ok
    if type(st.console) == "table" then
        _moveResizeBestEffort(st.console, 0, 0, bodyW, consoleH)
    end

    if st.enableInput == true and type(st.inputHost) == "table" then
        local inputY = math.max(0, bodyH - inputH)
        ok = _moveResizeBestEffort(st.inputHost, 0, inputY, bodyW, inputH) and ok

        if type(st.input) == "table" and st.layout.inputKind ~= "none" then
            _moveResizeBestEffort(st.input, 0, 0, bodyW, inputH)

            local iw, ih = _getWHBestEffort(st.input)
            st.layout.measured.inputInnerH = ih
            if ih and ih > 0 and ih < inputH then
                local iy = math.max(0, inputH - ih)
                st.layout.measured.inputInnerY = iy
                _moveResizeBestEffort(st.input, 0, iy, bodyW, ih)
            else
                st.layout.measured.inputInnerY = 0
            end
        end

        st.layout.measured.inputY = inputY
    end

    st.layout.measured.contentW = contentW
    st.layout.measured.contentH = contentH
    st.layout.measured.targetH = targetH
    st.layout.measured.bodyW = bodyW
    st.layout.measured.bodyH = bodyH
    st.layout.measured.consoleH = consoleH

    return ok
end

local function _unregisterHandlerBestEffort()
    if not st.handler then return end

    if st.handlerKind == "anon" then
        if type(killAnonymousEventHandler) == "function" then
            pcall(function() killAnonymousEventHandler(st.handler) end)
        end
    elseif st.handlerKind == "named4" then
        if type(killNamedEventHandler) == "function" and type(st.handlerKey) == "table" then
            local k = st.handlerKey
            pcall(function() killNamedEventHandler(k.group, k.name, k.event) end)
        elseif type(killAnonymousEventHandler) == "function" then
            pcall(function() killAnonymousEventHandler(st.handler) end)
        end
    else
        if type(killAnonymousEventHandler) == "function" then
            pcall(function() killAnonymousEventHandler(st.handler) end)
        end
    end

    st.handler = nil
    st.handlerKind = nil
    st.handlerKey = nil
end

local function _unregisterResizeHandlersBestEffort()
    if type(st.resizeHandlers) ~= "table" then
        st.resizeHandlers = nil
        return
    end

    for _, h in ipairs(st.resizeHandlers) do
        if type(h) == "table" then
            if h.kind == "anon" then
                if type(killAnonymousEventHandler) == "function" and h.id ~= nil then
                    pcall(function() killAnonymousEventHandler(h.id) end)
                end
            elseif h.kind == "named4" then
                if type(killNamedEventHandler) == "function" and type(h.key) == "table" then
                    local k = h.key
                    pcall(function() killNamedEventHandler(k.group, k.name, k.event) end)
                elseif type(killAnonymousEventHandler) == "function" and h.id ~= nil then
                    pcall(function() killAnonymousEventHandler(h.id) end)
                end
            else
                if type(killAnonymousEventHandler) == "function" and h.id ~= nil then
                    pcall(function() killAnonymousEventHandler(h.id) end)
                end
            end
        end
    end

    st.resizeHandlers = nil
end

local function _appendLocalInputLine(text, opts)
    opts = (type(opts) == "table") and opts or {}
    text = tostring(text or "")
    if text == "" then return false end

    local ok, err = LogSvc.addLine(text, {
        channel = opts.channel or "SAY",
        speaker = opts.speaker or "You",
        source = opts.source or "chat_ui:input",
    })
    if not ok then
        return false, err
    end
    return true
end

local function _sendToMudBestEffort(text)
    text = tostring(text or "")
    if text == "" then return false end
    if type(_G.send) ~= "function" then
        return false, "send() is not available"
    end
    pcall(function() _G.send(text) end)
    return true
end

local function _getCommandLineTextBestEffort(cmd)
    if type(cmd) ~= "table" then return "" end

    local candidates = { "getText", "getLine", "text", "getCommand" }
    for _, fnName in ipairs(candidates) do
        if type(cmd[fnName]) == "function" then
            local ok, v = pcall(function() return cmd[fnName](cmd) end)
            if ok and type(v) == "string" then return v end
        end
    end

    for _, k in ipairs({ "cmdLine", "command", "line", "text" }) do
        if type(cmd[k]) == "string" then return cmd[k] end
    end

    return ""
end

local function _clearCommandLineTextBestEffort(cmd)
    if type(cmd) ~= "table" then return end

    local candidates = { "clear", "clearLine", "setText", "setCommand", "setLine" }
    for _, fnName in ipairs(candidates) do
        if type(cmd[fnName]) == "function" then
            pcall(function()
                if fnName == "setText" or fnName == "setCommand" or fnName == "setLine" then
                    cmd[fnName](cmd, "")
                else
                    cmd[fnName](cmd)
                end
            end)
            return
        end
    end
end

local function _wireInputSubmitBestEffort(cmd, handlerFn)
    if type(cmd) ~= "table" or type(handlerFn) ~= "function" then return false end
    local wired = false

    for _, fnName in ipairs({
        "setOnEnter", "setOnSubmit", "setEnterCallback", "setSubmitCallback", "setCallback",
        "setCommandCallback", "setReturnCallback",
    }) do
        if type(cmd[fnName]) == "function" then
            local ok = pcall(function() cmd[fnName](cmd, handlerFn) end)
            if ok then
                wired = true
                break
            end
        end
    end

    if not wired then
        if cmd.onEnter ~= nil then
            local ok = pcall(function() cmd.onEnter = handlerFn end)
            wired = wired or (ok == true)
        end
        if cmd.onSubmit ~= nil then
            local ok = pcall(function() cmd.onSubmit = handlerFn end)
            wired = wired or (ok == true)
        end
    end

    return wired
end

local function _eventMentionsThisFrameBestEffort(...)
    local frameName = (st.bundle and st.bundle.meta and st.bundle.meta.nameFrame) and tostring(st.bundle.meta.nameFrame) or
        ""
    local contentName = (st.bundle and st.bundle.meta and st.bundle.meta.nameContent) and
        tostring(st.bundle.meta.nameContent) or ""

    if frameName == "" and contentName == "" then
        return true
    end

    for i = 1, select("#", ...) do
        local v = select(i, ...)
        if type(v) == "string" then
            if frameName ~= "" and v:find(frameName, 1, true) then return true end
            if contentName ~= "" and v:find(contentName, 1, true) then return true end
        elseif type(v) == "table" then
            local n = tostring(v.name or v.windowName or v.containerName or "")
            if n ~= "" then
                if frameName ~= "" and n:find(frameName, 1, true) then return true end
                if contentName ~= "" and n:find(contentName, 1, true) then return true end
            end
        end
    end

    return false
end

local function _ensureResizeReflowWiring()
    if type(st.resizeHandlers) == "table" and #st.resizeHandlers > 0 then
        return true
    end

    st.resizeHandlers = {}

    local function _doReflow()
        if st.visible ~= true then return end
        pcall(_reflowLayoutBestEffort)
    end

    local frame = st.bundle and st.bundle.frame or nil

    if type(frame) == "table" then
        for _, fnName in ipairs({
            "setOnResize", "setResizeCallback", "setOnResizeCallback", "setResizeEvent", "setOnSizeChanged",
        }) do
            if type(frame[fnName]) == "function" then
                pcall(function() frame[fnName](frame, _doReflow) end)
                break
            end
        end
    end

    local function _registerAnon(ev, cb)
        if type(registerAnonymousEventHandler) ~= "function" then return false end
        local ok, id = pcall(registerAnonymousEventHandler, ev, cb)
        if ok and id ~= nil then
            table.insert(st.resizeHandlers, { id = id, kind = "anon", event = ev })
            return true
        end
        return false
    end

    local function _registerNamed(group, name, ev, cb)
        if type(registerNamedEventHandler) ~= "function" then return false end
        local ok, id = pcall(registerNamedEventHandler, group, name, ev, cb)
        if ok and id ~= nil then
            table.insert(st.resizeHandlers,
                { id = id, kind = "named4", key = { group = group, name = name, event = ev }, event = ev })
            return true, nil
        end
        return false
    end

    _registerAnon(EV_SYS_WINDOW_RESIZE, function() _doReflow() end)

    for _, ev in ipairs(EV_USER_RESIZE_CANDIDATES) do
        _registerAnon(ev, function(_, ...)
            local mentioned = _eventMentionsThisFrameBestEffort(...)
            if mentioned or select("#", ...) == 0 then
                _doReflow()
            end
        end)

        _registerNamed("dwkit", "chat_ui_resize_" .. tostring(ev), ev, function(_, ...)
            local mentioned = _eventMentionsThisFrameBestEffort(...)
            if mentioned or select("#", ...) == 0 then
                _doReflow()
            end
        end)
    end

    return (#st.resizeHandlers > 0)
end

local function _ensureUi(opts)
    if type(st.bundle) == "table" and type(st.bundle.frame) == "table" then
        return true
    end

    opts = (type(opts) == "table") and opts or {}

    local wantNoInsetInside = true
    if opts.noInsetInside == false then
        wantNoInsetInside = false
    end

    local pad = 0
    if type(opts.padding) == "number" then
        pad = tonumber(opts.padding) or 0
    end

    st.enableInput = (opts.enableInput ~= false)
    st.sendToMud = (opts.sendToMud == true)

    if type(opts.bottomFudge) == "number" then
        st.layout.bottomFudge = tonumber(opts.bottomFudge) or st.layout.bottomFudge
    end

    st.bundle = UIW.create({
        uiId = UI_ID,
        title = TITLE,
        x = opts.x or 30,
        y = opts.y or 360,
        width = opts.width or 520,
        height = opts.height or 260,

        fixed = (opts.fixed == true),
        noClose = (opts.noClose == true),

        titleFormat = opts.titleFormat,

        noInsetInside = (wantNoInsetInside == true),
        padding = pad,

        onResize = function()
            if st.visible ~= true then return end
            pcall(_reflowLayoutBestEffort)
        end,

        onClose = function(bundle)
            st.visible = false
            _unregisterHandlerBestEffort()
            _unregisterResizeHandlersBestEffort()
            if type(bundle) == "table" and type(bundle.frame) == "table" then
                pcall(function() U.safeHide(bundle.frame, UI_ID, { source = "chat_ui:onClose" }) end)
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

    local tabH             = tonumber(opts.tabHeight or 24) or 24
    local insetY           = tonumber(opts.insetY or 0) or 0
    local gapY             = tonumber(opts.gapY or 2) or 2
    local yContent         = insetY + tabH + gapY

    local inputH           = tonumber(opts.inputHeight or 26) or 26
    local inputGapY        = tonumber(opts.inputGapY or 0) or 0

    st.layout.tabH         = tabH
    st.layout.insetY       = insetY
    st.layout.gapY         = gapY
    st.layout.yContent     = yContent
    st.layout.usedHostFill = true

    st.layout.inputH       = inputH
    st.layout.inputGapY    = inputGapY
    st.layout.usedInput    = (st.enableInput == true)
    st.layout.inputKind    = "none"

    st.bodyFill            = G.Container:new({
        name = tostring(st.bundle.meta.nameContent or "__DWKit_chat") .. "__bodyfill",
        x = 0,
        y = 0,
        width = "100%",
        height = "100%",
    }, st.bundle.content)

    st.tabBar              = G.Container:new({
        name = tostring(st.bundle.meta.nameContent or "__DWKit_chat") .. "__tabbar",
        x = 0,
        y = insetY,
        width = "100%",
        height = tabH,
    }, st.bodyFill)

    _applyTabBarStyleBestEffort()

    st.tabButtons = {}
    local btnW = math.floor(100 / #TAB_ORDER)
    local xPct = 0

    local function _switchTab(tab)
        tab = tostring(tab or "All")
        local okTab = false
        for _, t in ipairs(TAB_ORDER) do
            if t == tab then
                okTab = true
                break
            end
        end
        if not okTab then tab = "All" end

        st.activeTab = tab
        st.unread[tab] = 0

        -- Feature: all_unread_badge uses st.unread["All"] as aggregate; clear when user views All.
        if tab == "All" then
            st.unread["All"] = 0
            local seenAll = tonumber(st.lastSeenId["All"] or 0) or 0
            st.lastSeenId["AllUnread"] = math.max(tonumber(st.lastSeenId["AllUnread"] or 0) or 0, seenAll)
        end

        _renderTabButtons()

        M.refresh({ source = "tab_switch", force = true })
    end

    for _, tab in ipairs(TAB_ORDER) do
        local btn = G.Label:new({
            name = tostring(st.bundle.meta.nameContent or "__DWKit_chat") .. "__tab__" .. tab,
            x = tostring(xPct) .. "%",
            y = 0,
            width = tostring(btnW) .. "%",
            height = "100%",
        }, st.tabBar)

        pcall(function()
            if type(btn.setAlignment) == "function" then btn:setAlignment("center") end
        end)

        _applyTabStyleBestEffort(tab)
        _wireClickBestEffort(btn, function() _switchTab(tab) end)

        st.tabButtons[tab] = btn
        xPct = xPct + btnW
    end

    -- Debug label (height collapses to 0 when feature OFF)
    st.debugLabel = G.Label:new({
        name = tostring(st.bundle.meta.nameContent or "__DWKit_chat") .. "__debugLabel",
        x = 0,
        y = yContent,
        width = "100%",
        height = 0,
    }, st.bodyFill)

    -- consoleHost starts at yConsole (computed dynamically)
    st.consoleHost = G.Container:new({
        name = tostring(st.bundle.meta.nameContent or "__DWKit_chat") .. "__consoleHost",
        x = 0,
        y = yContent,
        width = "100%",
        height = "100%",
    }, st.bodyFill)

    st.console = G.MiniConsole:new({
        name = tostring(st.bundle.meta.nameContent or "__DWKit_chat") .. "__console",
        x = 0,
        y = 0,
        width = "100%",
        height = "100%",
    }, st.consoleHost)

    pcall(function()
        if type(st.console.setFontSize) == "function" then st.console:setFontSize(9) end
    end)

    st.inputHost = nil
    st.input = nil

    if st.enableInput == true then
        st.inputHost = G.Container:new({
            name = tostring(st.bundle.meta.nameContent or "__DWKit_chat") .. "__inputHost",
            x = 0,
            y = 0,
            width = "100%",
            height = tostring(inputH) .. "px",
        }, st.bodyFill)

        pcall(function()
            if type(st.inputHost.setStyleSheet) == "function" then
                st.inputHost:setStyleSheet([[
                    background-color: rgba(0,0,0,0);
                    border-top: 1px solid #2a2f3a;
                    margin: 0px;
                    padding: 0px;
                ]])
            end
        end)

        if type(G.CommandLine) == "table" and type(G.CommandLine.new) == "function" then
            local okCL, cl = pcall(function()
                return G.CommandLine:new({
                    name = tostring(st.bundle.meta.nameContent or "__DWKit_chat") .. "__input",
                    x = 0,
                    y = 0,
                    width = "100%",
                    height = "100%",
                }, st.inputHost)
            end)

            if okCL and type(cl) == "table" then
                st.input = cl
                st.layout.inputKind = "commandline"
            end
        end

        if st.layout.inputKind == "commandline" then
            local inputName = tostring(st.input.name or "")
            _applyCommandLineStyleBestEffort(inputName)

            pcall(function()
                if type(st.input.setFontSize) == "function" then st.input:setFontSize(9) end
            end)

            local function _onSubmit()
                if st.visible ~= true then return end
                if st.enableInput ~= true then return end

                local text = _getCommandLineTextBestEffort(st.input)
                text = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
                if text == "" then
                    _clearCommandLineTextBestEffort(st.input)
                    return
                end

                _appendLocalInputLine(text, { source = "chat_ui:input_submit", channel = "SAY", speaker = "You" })

                if st.sendToMud == true then
                    _sendToMudBestEffort(text)
                end

                _clearCommandLineTextBestEffort(st.input)
            end

            _wireInputSubmitBestEffort(st.input, _onSubmit)
        end
    end

    _applyBundleContentNoInsetBestEffort()
    _applyBodyFillStyleBestEffort()
    _applyConsoleTransparentBestEffort()

    _renderTabButtons()
    _applyDebugLabelBestEffort()

    pcall(_reflowLayoutBestEffort)

    return true
end

local function _ensureHandler()
    if st.handler then return true end

    local function _cb()
        if st.visible then
            M.refresh({ source = "event:" .. EV_SVC_CHATLOG_UPDATED })
        end
    end

    if type(registerAnonymousEventHandler) == "function" then
        local ok, id = pcall(registerAnonymousEventHandler, EV_SVC_CHATLOG_UPDATED, _cb)
        if ok and id ~= nil then
            st.handler = id
            st.handlerKind = "anon"
            return true
        end
    end

    if type(registerNamedEventHandler) == "function" then
        local group = "dwkit"
        local name = "chat_ui"
        local ok4, id4 = pcall(registerNamedEventHandler, group, name, EV_SVC_CHATLOG_UPDATED, _cb)
        if ok4 and id4 ~= nil then
            st.handler = id4
            st.handlerKind = "named4"
            st.handlerKey = { group = group, name = name, event = EV_SVC_CHATLOG_UPDATED }
            return true
        end

        local ok3, id3 = pcall(registerNamedEventHandler, "dwkit.chat_ui", EV_SVC_CHATLOG_UPDATED, _cb)
        if ok3 and id3 ~= nil then
            st.handler = id3
            st.handlerKind = "named3"
            return true
        end
    end

    return false
end

local function _getItemsBestEffort()
    if type(LogSvc) == "table" and type(LogSvc.getItems) == "function" then
        local ok, items, meta = pcall(LogSvc.getItems)
        if ok then
            return (type(items) == "table" and items or {}), (type(meta) == "table" and meta or {})
        end
    end

    if type(LogSvc) == "table" and type(LogSvc.getState) == "function" then
        local ok, st2 = pcall(LogSvc.getState)
        if ok and type(st2) == "table" then
            local items = st2.items or st2.buffer or st2.lines or {}
            local meta = st2.meta
            if type(meta) ~= "table" then
                meta = { latestId = st2.latestId }
            end
            return (type(items) == "table" and items or {}), (type(meta) == "table" and meta or {})
        end
    end

    local candidates = { "getAll", "list", "all" }
    for _, fnName in ipairs(candidates) do
        if type(LogSvc) == "table" and type(LogSvc[fnName]) == "function" then
            local ok, items = pcall(LogSvc[fnName])
            if ok then
                return (type(items) == "table" and items or {}), {}
            end
        end
    end

    return {}, {}
end

function M.getVersion()
    return M.VERSION
end

function M.getState()
    return {
        visible = st.visible == true,
        activeTab = st.activeTab,
        unread = st.unread,
        enableInput = (st.enableInput == true),
        sendToMud = (st.sendToMud == true),
    }
end

function M.getLayoutDebug()
    return {
        uiId = UI_ID,
        version = M.VERSION,
        visible = st.visible == true,
        enableInput = (st.enableInput == true),
        sendToMud = (st.sendToMud == true),
        layout = st.layout,
        featureCfg = st.featureCfg,
        renderDebug = st.renderDebug,
    }
end

-- -------------------------------------------------------------------------
-- Phase 2 feature config surface (best-effort)
-- -------------------------------------------------------------------------

function M.setFeatureConfig(cfg, opts)
    opts = (type(opts) == "table") and opts or {}
    if type(cfg) ~= "table" then return false end
    if type(cfg.features) ~= "table" then return false end

    st.featureCfg = st.featureCfg or { features = {} }
    st.featureCfg.features = st.featureCfg.features or {}

    for k, v in pairs(cfg.features) do
        st.featureCfg.features[k] = v
    end

    -- Feature effects: debug overlay affects layout, tabs may change labels (All unread)
    _renderTabButtons()
    _applyDebugLabelBestEffort()
    if st.visible == true then
        pcall(_reflowLayoutBestEffort)
    end

    if st.visible == true and opts.apply ~= false then
        M.refresh({ source = opts.source or "chat_ui:setFeatureConfig", force = true })
    end

    return true
end

function M.getFeatureConfig()
    return st.featureCfg
end

-- -------------------------------------------------------------------------
-- Phase 1 Control Surface
-- -------------------------------------------------------------------------

function M.getTabs()
    local out = {}
    for i = 1, #TAB_ORDER do out[i] = TAB_ORDER[i] end
    return out
end

function M.setActiveTab(tab, opts)
    opts = (type(opts) == "table") and opts or {}
    tab = tostring(tab or "")
    if tab == "" then return false, "tab required" end

    -- Best-effort: mimic internal tab switching logic without duplicating click handler
    local wanted = tab
    local okTab = false
    for _, t in ipairs(TAB_ORDER) do
        if t == wanted then
            okTab = true
            break
        end
    end
    if not okTab then wanted = "All" end

    st.activeTab = wanted
    st.unread[wanted] = 0
    if wanted == "All" then
        st.unread["All"] = 0
        local seenAll = tonumber(st.lastSeenId["All"] or 0) or 0
        st.lastSeenId["AllUnread"] = math.max(tonumber(st.lastSeenId["AllUnread"] or 0) or 0, seenAll)
    end

    _renderTabButtons()
    if st.visible == true then
        M.refresh({ source = "setActiveTab", force = true })
    end

    return true, nil
end

function M.clear(opts)
    opts = (type(opts) == "table") and opts or {}
    if type(LogSvc) ~= "table" or type(LogSvc.clear) ~= "function" then
        return false, "chat_log_service.clear not available"
    end
    local ok = pcall(LogSvc.clear, { source = opts.source or "chat_ui:clear" })
    if not ok then
        return false, "chat_log_service.clear failed"
    end

    st.unread = {}
    st.lastSeenId = {}
    st.lastRenderedId = 0

    -- render debug reset
    st.renderDebug.lastTabCount = 0
    st.renderDebug.lastShownCount = 0
    st.renderDebug.lastFirstLine = ""
    st.renderDebug.lastLastLine = ""

    _renderTabButtons()
    if st.visible == true then
        M.refresh({ source = "clear", force = true })
    end

    return true, nil
end

function M.setSendToMud(on, opts)
    opts = (type(opts) == "table") and opts or {}
    st.sendToMud = (on == true)
    if st.visible == true and st.enableInput == true and st.layout.inputKind == "commandline" then
        _focusInputBestEffort()
    end
    return true
end

function M.setInputEnabled(on, opts)
    opts = (type(opts) == "table") and opts or {}
    local want = (on == true)

    if want == true and type(st.inputHost) ~= "table" then
        return false, "inputHost not available (chat_ui was created with enableInput=false)"
    end

    st.enableInput = want

    if type(st.inputHost) == "table" then
        if want == true then
            pcall(function()
                if type(st.inputHost.show) == "function" then st.inputHost:show() end
                if type(st.input) == "table" and type(st.input.show) == "function" then st.input:show() end
            end)
        else
            pcall(function()
                if type(st.input) == "table" and type(st.input.hide) == "function" then st.input:hide() end
                if type(st.inputHost.hide) == "function" then st.inputHost:hide() end
            end)
        end
    end

    pcall(_reflowLayoutBestEffort)
    if want == true and st.visible == true then
        _focusInputBestEffort()
    end

    return true, nil
end

-- -------------------------------------------------------------------------
-- Visible controls
-- -------------------------------------------------------------------------

function M.show(opts)
    opts = (type(opts) == "table") and opts or {}

    if not _ensureUi(opts) then
        return false, "chat_ui: failed to ensure UI"
    end

    _ensureHandler()

    if type(st.bundle) == "table" and type(st.bundle.frame) == "table" then
        pcall(function() U.safeShow(st.bundle.frame, UI_ID, { source = "chat_ui:show" }) end)
    end

    st.visible = true
    pcall(U.setUiStateVisibleBestEffort, UI_ID, true)

    pcall(_ensureResizeReflowWiring)
    pcall(_reflowLayoutBestEffort)

    M.refresh({ source = "show", force = true })

    if st.enableInput == true and st.layout.inputKind == "commandline" then
        _focusInputBestEffort()
    end

    return true
end

function M.hide(opts)
    opts = (type(opts) == "table") and opts or {}

    if type(st.bundle) == "table" and type(st.bundle.frame) == "table" then
        pcall(function() U.safeHide(st.bundle.frame, UI_ID, { source = "chat_ui:hide" }) end)
    end

    st.visible = false
    _unregisterHandlerBestEffort()
    _unregisterResizeHandlersBestEffort()
    pcall(U.setUiStateVisibleBestEffort, UI_ID, false)

    return true
end

function M.toggle(opts)
    if st.visible then return M.hide(opts) end
    return M.show(opts)
end

function M.refresh(opts)
    opts = (type(opts) == "table") and opts or {}
    if not st.visible then return true end

    pcall(_reflowLayoutBestEffort)

    local items, meta = _getItemsBestEffort()
    items = (type(items) == "table" and items or {})
    meta = (type(meta) == "table" and meta or {})
    local latestId = tonumber(meta.latestId or 0) or 0

    local force = (opts.force == true)
    if (not force) and latestId <= (tonumber(st.lastRenderedId or 0) or 0) then
        return true
    end

    -- Unread accounting (v1 semantics + All unread badge optional)
    for _, it in ipairs(items) do
        local id = tonumber(it.id or 0) or 0
        local tab = _tabForChannel(it.channel)

        local seenAll = tonumber(st.lastSeenId["All"] or 0) or 0
        if id > seenAll then st.lastSeenId["All"] = id end

        if tab ~= st.activeTab then
            local seen = tonumber(st.lastSeenId[tab] or 0) or 0
            if id > seen then
                st.unread[tab] = (tonumber(st.unread[tab] or 0) or 0) + 1
                st.lastSeenId[tab] = id
            end
        else
            st.lastSeenId[tab] = math.max(tonumber(st.lastSeenId[tab] or 0) or 0, id)
        end

        local feats = (st.featureCfg and st.featureCfg.features) or {}
        if feats.all_unread_badge == true then
            if "All" ~= st.activeTab then
                local seenA = tonumber(st.lastSeenId["AllUnread"] or 0) or 0
                if id > seenA then
                    st.unread["All"] = (tonumber(st.unread["All"] or 0) or 0) + 1
                    st.lastSeenId["AllUnread"] = id
                end
            else
                st.lastSeenId["AllUnread"] = math.max(tonumber(st.lastSeenId["AllUnread"] or 0) or 0, id)
            end
        end
    end

    _renderTabButtons()

    -- Build tab-matching list first (per-tab limit must be per active tab)
    local tabItems = {}
    for _, it in ipairs(items) do
        if _passesTab(it, st.activeTab) then
            tabItems[#tabItems + 1] = it
        end
    end

    local feats = (st.featureCfg and st.featureCfg.features) or {}
    local limitOn = (feats.per_tab_line_limit == true)
    local limitN = tonumber(feats.per_tab_line_limit_n or 500) or 500
    if limitN < 50 then limitN = 50 end
    if limitN > 3000 then limitN = 3000 end

    local renderItems = tabItems
    if limitOn and #tabItems > limitN then
        local start = (#tabItems - limitN) + 1
        local sliced = {}
        for i = start, #tabItems do
            sliced[#sliced + 1] = tabItems[i]
        end
        renderItems = sliced
    end

    -- Render
    _clearConsole()

    local firstLine = ""
    local lastLine = ""

    for i = 1, #renderItems do
        local line = _mkLine(renderItems[i])
        if i == 1 then firstLine = tostring(line or "") end
        lastLine = tostring(line or "")
        _appendConsoleLine(line)
    end

    st.lastRenderedId = latestId

    -- Update debug instrumentation
    st.renderDebug.lastActiveTab = tostring(st.activeTab)
    st.renderDebug.lastTabCount = tonumber(#tabItems) or 0
    st.renderDebug.lastShownCount = tonumber(#renderItems) or 0
    st.renderDebug.lastLimitOn = (limitOn == true)
    st.renderDebug.lastLimitN = (limitOn == true) and limitN or nil
    st.renderDebug.lastTimestampOn = (feats.timestamp_prefix == true)
    st.renderDebug.lastFirstLine = firstLine
    st.renderDebug.lastLastLine = lastLine

    _applyDebugLabelBestEffort()
    _scrollToBottomBestEffort()

    return true
end

function M.dispose()
    _unregisterHandlerBestEffort()
    _unregisterResizeHandlersBestEffort()

    if type(st.bundle) == "table" and type(st.bundle.frame) == "table" then
        pcall(function() U.safeHide(st.bundle.frame, UI_ID, { source = "chat_ui:dispose" }) end)
        pcall(function() U.safeDelete(st.bundle.frame) end)
    end

    st.bundle = nil
    st.bodyFill = nil
    st.tabBar = nil
    st.tabButtons = {}
    st.consoleHost = nil
    st.console = nil
    st.inputHost = nil
    st.input = nil
    st.debugLabel = nil

    st.enableInput = true
    st.sendToMud = false

    st.visible = false
    pcall(U.setUiStateVisibleBestEffort, UI_ID, false)

    return true
end

return M
