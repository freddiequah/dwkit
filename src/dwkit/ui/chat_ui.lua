-- FILE: src/dwkit/ui/chat_ui.lua
-- #########################################################################
-- Module Name : dwkit.ui.chat_ui
-- Owner       : UI
-- Version     : v2026-02-15A
-- Purpose     :
--   - SAFE Chat UI (consumer-only) displaying ChatLogService buffer.
--   - Renders a DWKit-themed container with a tab row:
--       All | SAY | PRIVATE | PUBLIC | GRATS | Other
--   - Event-driven refresh on DWKit:Service:ChatLog:Updated while visible.
--   - Unread counts on non-All tabs; clears when user views that tab.
--   - Bottom input line (EMCO-like typing area):
--       * DEFAULT ON (still SAFE: local-only unless sendToMud=true).
--       * When enabled, submitting text is an explicit user action (Enter).
--       * By default, submission is LOCAL-ONLY: appends to ChatLogService (no send()).
--       * Optional sendToMud=true will call send(text) ONLY on user submit (still manual).
--   - No timers, no GMCP.
--
-- Public API:
--   - getVersion() -> string
--   - getState() -> table { visible=bool, activeTab=string, unread=table, enableInput=bool, sendToMud=bool }
--   - show(opts?) / hide(opts?) / toggle(opts?)
--   - refresh(opts?) -> boolean ok
--   - dispose() -> boolean ok
--   - getLayoutDebug() -> table (sizes, best-effort)
--
-- Notes:
--   - Tab definitions are LOCKED by agreement v2026-02-10C.
--   - chat_ui is a DIRECT-CONTROL UI (see UI Manager direct-control rule).
--
-- Key Fixes:
--   v2026-02-12C:
--     - NEW: render first-class message target (item.target) for PRIVATE channels.
--   v2026-02-15A:
--     - NEW: wire real capture via ui_dependency_service provider "chat_watch" (dwkit.capture.chat_capture).
-- #########################################################################

local M                         = {}

M.VERSION                       = "v2026-02-15A"

local PREFIX                    = (DWKit and DWKit.getEventPrefix and DWKit.getEventPrefix()) or "DWKit:"
local LogSvc                    = require("dwkit.services.chat_log_service")
local UIW                       = require("dwkit.ui.ui_window")
local U                         = require("dwkit.ui.ui_base")
local Dep                       = require("dwkit.services.ui_dependency_service")

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

    layout = {
        tabH = 24,
        insetY = 0,
        gapY = 2,
        yContent = 0,
        usedHostFill = true,

        inputH = 26,
        inputGapY = 0,
        yConsole = 0,
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

local function _mkLine(item)
    local speaker = _isNonEmptyString(item.speaker) and item.speaker or nil
    local target  = _isNonEmptyString(item.target) and item.target or nil

    local chRaw   = _isNonEmptyString(item.channel) and item.channel or ""
    local chan    = (chRaw ~= "" and ("[" .. chRaw .. "] ") or "")

    if speaker and target then
        return string.format("%s%s -> %s: %s", chan, speaker, target, tostring(item.text))
    end

    if speaker then
        return string.format("%s%s: %s", chan, speaker, tostring(item.text))
    end

    return string.format("%s%s", chan, tostring(item.text))
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

local function _tabLabelText(tab)
    tab = tostring(tab or "")
    local n = tonumber(st.unread[tab] or 0) or 0
    if tab ~= "All" and n > 0 and tab ~= st.activeTab then
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
    local hasUnread = (tab ~= "All" and unread > 0 and (not active))
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
end

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
    _renderTabButtons()

    M.refresh({ source = "tab_switch", force = true })
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

local function _reflowLayoutBestEffort()
    if type(st.bundle) ~= "table" or type(st.bundle.content) ~= "table" then return false end
    if type(st.bodyFill) ~= "table" then return false end
    if type(st.consoleHost) ~= "table" then return false end

    local contentW, contentH = _getWHBestEffort(st.bundle.content)
    if not contentW or not contentH then
        return false
    end

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
            -- Best-effort: release capture provider on close (direct-control UI)
            pcall(function()
                if type(Dep) == "table" and type(Dep.releaseUi) == "function" then
                    Dep.releaseUi(UI_ID, { source = "chat_ui:onClose", quiet = true })
                end
            end)

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

    local yConsole = yContent
    st.layout.yConsole = yConsole

    st.consoleHost = G.Container:new({
        name = tostring(st.bundle.meta.nameContent or "__DWKit_chat") .. "__consoleHost",
        x = 0,
        y = yConsole,
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

local function _depEnsureChatWatchBestEffort(source)
    if type(Dep) == "table" and type(Dep.ensureUi) == "function" then
        pcall(function()
            Dep.ensureUi(UI_ID, { "chat_watch" }, { source = source or "chat_ui:dep:ensure", quiet = true })
        end)
    end
end

local function _depReleaseChatWatchBestEffort(source)
    if type(Dep) == "table" and type(Dep.releaseUi) == "function" then
        pcall(function()
            Dep.releaseUi(UI_ID, { source = source or "chat_ui:dep:release", quiet = true })
        end)
    end
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
    }
end

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

    -- NEW: claim chat_watch provider while visible (best-effort gate for real capture -> router)
    _depEnsureChatWatchBestEffort("chat_ui:show")

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

    -- NEW: release chat_watch provider when hidden (best-effort)
    _depReleaseChatWatchBestEffort("chat_ui:hide")

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
    end

    _renderTabButtons()

    _clearConsole()
    for _, it in ipairs(items) do
        if _passesTab(it, st.activeTab) then
            _appendConsoleLine(_mkLine(it))
        end
    end

    st.lastRenderedId = latestId
    return true
end

function M.dispose()
    _unregisterHandlerBestEffort()
    _unregisterResizeHandlersBestEffort()

    -- NEW: release provider on dispose (best-effort)
    _depReleaseChatWatchBestEffort("chat_ui:dispose")

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

    st.enableInput = true
    st.sendToMud = false

    st.visible = false
    pcall(U.setUiStateVisibleBestEffort, UI_ID, false)

    return true
end

return M
