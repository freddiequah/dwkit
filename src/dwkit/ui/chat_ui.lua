-- FILE: src/dwkit/ui/chat_ui.lua
-- #########################################################################
-- Module Name : dwkit.ui.chat_ui
-- Owner       : UI
-- Version     : v2026-02-11G
-- Purpose     :
--   - SAFE Chat UI (consumer-only) displaying ChatLogService buffer.
--   - Renders a DWKit-themed container with a tab row:
--       All | SAY | PRIVATE | PUBLIC | GRATS | Other
--   - Event-driven refresh on DWKit:Service:ChatLog:Updated while visible.
--   - Unread counts on non-All tabs; clears when user views that tab.
--   - No timers, no send(), no GMCP.
--
-- Public API:
--   - getVersion() -> string
--   - getState() -> table { visible=bool, activeTab=string, unread=table }
--   - show(opts?) / hide(opts?) / toggle(opts?)
--   - refresh(opts?) -> boolean ok
--   - dispose() -> boolean ok
--   - getLayoutDebug() -> table (sizes, best-effort)
--
-- Notes:
--   - Tab definitions are LOCKED by agreement v2026-02-10C.
--   - chat_ui is a DIRECT-CONTROL UI (see UI Manager direct-control rule).
--   - Layout invariants:
--       * No title/tab overlap: rely on ui_window content being true "Inside" area.
--       * No bottom wasted gap: console fills remaining space via host container (-y px).
-- #########################################################################

local M                      = {}

M.VERSION                    = "v2026-02-11G"

local PREFIX                 = (DWKit and DWKit.getEventPrefix and DWKit.getEventPrefix()) or "DWKit:"
local LogSvc                 = require("dwkit.services.chat_log_service")
local UIW                    = require("dwkit.ui.ui_window")
local U                      = require("dwkit.ui.ui_base")

local EV_SVC_CHATLOG_UPDATED = PREFIX .. "Service:ChatLog:Updated"

local UI_ID                  = "chat_ui"
local TITLE                  = "Chat"

-- Tab definitions (LOCKED by agreement v2026-02-10C)
local TAB_ORDER              = { "All", "SAY", "PRIVATE", "PUBLIC", "GRATS", "Other" }

local PRIVATE_CH             = { TELL = true, ASK = true, WHISPER = true }
local PUBLIC_CH              = { SHOUT = true, YELL = true, GOSSIP = true }

local st                     = {
    visible = false,
    bundle = nil,

    bodyFill = nil,

    tabBar = nil,
    tabButtons = {}, -- map tab -> label obj

    consoleHost = nil,
    console = nil,

    -- Layout computed at create time
    layout = {
        tabH = 24,
        insetY = 0,
        gapY = 2,
        yContent = 0,
        usedHostFill = true,
    },

    -- Event handler wiring
    handler = nil,
    handlerKind = nil, -- "anon" | "named4" | "named3" | nil
    handlerKey = nil,  -- for named: { group=, name=, event= }

    activeTab = "All",
    unread = {},     -- map tab -> count
    lastSeenId = {}, -- map tab -> last seen id
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
    local chan = _isNonEmptyString(item.channel) and ("[" .. item.channel .. "] ") or ""
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

-- Tab styling (local to Chat UI; avoids changing global theme)
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
    elseif st.handlerKind == "named3" then
        if type(killAnonymousEventHandler) == "function" then
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

        onClose = function(bundle)
            st.visible = false
            _unregisterHandlerBestEffort()
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

    -- Layout invariants:
    -- - avoid profile-dependent inner-height math
    -- - tab row + gap is fixed
    local tabH             = tonumber(opts.tabHeight or 24) or 24
    local insetY           = tonumber(opts.insetY or 0) or 0
    local gapY             = tonumber(opts.gapY or 2) or 2

    local yContent         = insetY + tabH + gapY

    st.layout.tabH         = tabH
    st.layout.insetY       = insetY
    st.layout.gapY         = gapY
    st.layout.yContent     = yContent
    st.layout.usedHostFill = true

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

    -- Console host fills remaining space deterministically (no profile-dependent pixel math).
    st.consoleHost = G.Container:new({
        name = tostring(st.bundle.meta.nameContent or "__DWKit_chat") .. "__consoleHost",
        x = 0,
        y = yContent,
        width = "100%",
        height = "-" .. tostring(yContent) .. "px",
    }, st.bodyFill)

    st.console = G.MiniConsole:new({
        name = tostring(st.bundle.meta.nameContent or "__DWKit_chat") .. "__console",
        x = 0,
        y = 0,
        width = "100%",
        height = "100%",
    }, st.consoleHost)

    pcall(function()
        if type(st.console.setFontSize) == "function" then
            st.console:setFontSize(9)
        end
    end)

    _applyBundleContentNoInsetBestEffort()
    _applyBodyFillStyleBestEffort()
    _applyConsoleTransparentBestEffort()

    _renderTabButtons()
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

-- -------------------------------------------------------------------------
-- ChatLogService API hardening
-- -------------------------------------------------------------------------
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
    }
end

function M.getLayoutDebug()
    return {
        uiId = UI_ID,
        version = M.VERSION,
        visible = st.visible == true,
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

    M.refresh({ source = "show", force = true })
    return true
end

function M.hide(opts)
    opts = (type(opts) == "table") and opts or {}

    if type(st.bundle) == "table" and type(st.bundle.frame) == "table" then
        pcall(function() U.safeHide(st.bundle.frame, UI_ID, { source = "chat_ui:hide" }) end)
    end

    st.visible = false
    _unregisterHandlerBestEffort()
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

    local items, meta = _getItemsBestEffort()
    items = (type(items) == "table") and items or {}
    meta = (type(meta) == "table") and meta or {}
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

    st.visible = false
    pcall(U.setUiStateVisibleBestEffort, UI_ID, false)

    return true
end

return M
