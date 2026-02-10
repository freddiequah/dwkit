-- FILE: src/dwkit/ui/chat_ui.lua
-- #########################################################################
-- Module Name : dwkit.ui.chat_ui
-- Owner       : UI
-- Version     : v2026-02-10A
-- Purpose     :
--   - SAFE Chat UI (consumer-only) displaying ChatLogService buffer.
--   - Event-driven refresh on DWKit:Service:ChatLog:Updated while visible.
--   - No timers, no send(), no GMCP.
--
-- Public API:
--   - getVersion() -> string
--   - getState() -> table { visible=bool }
--   - show(opts?) / hide(opts?) / toggle(opts?)
--   - refresh(opts?) -> boolean ok
--   - dispose() -> boolean ok
--
-- Dependencies     :
--   - dwkit.ui.ui_window
--   - dwkit.core.identity
--   - dwkit.services.chat_log_service
-- #########################################################################

local M = {}

M.VERSION = "v2026-02-10A"

local ID = require("dwkit.core.identity")
local PREFIX = tostring(ID.eventPrefix or "DWKit:")

local UIW = require("dwkit.ui.ui_window")
local Log = require("dwkit.services.chat_log_service")

local EV_SVC_CHATLOG_UPDATED = PREFIX .. "Service:ChatLog:Updated"

local UI_ID = "chat_ui"
local TITLE = "Chat"

local st = {
    visible = false,
    bundle = nil,
    console = nil,
    handler = nil,
    lastRenderedId = 0,
}

local function _isNonEmptyString(s) return type(s) == "string" and s ~= "" end

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
        pcall(function()
            st.console:cecho(tostring(line) .. "\n")
        end)
        return
    end
    if type(st.console) == "table" and type(st.console.echo) == "function" then
        pcall(function()
            st.console:echo(tostring(line) .. "\n")
        end)
    end
end

local function _ensureUi(opts)
    if type(st.bundle) == "table" and type(st.bundle.frame) == "table" then
        return true
    end

    opts = (type(opts) == "table") and opts or {}

    st.bundle = UIW.create({
        uiId = UI_ID,
        title = TITLE,
        x = opts.x or 30,
        y = opts.y or 360,
        width = opts.width or 420,
        height = opts.height or 220,

        -- safe defaults: allow close unless caller wants LaunchPad-style fixed/noClose
        fixed = (opts.fixed == true),
        noClose = (opts.noClose == true),
    })

    if type(st.bundle) ~= "table" or type(st.bundle.content) ~= "table" then
        st.bundle = nil
        return false
    end

    local G = _G.Geyser
    if type(G) == "table" and type(G.MiniConsole) == "table" and type(G.MiniConsole.new) == "function" then
        st.console = G.MiniConsole:new({
            name = tostring(st.bundle.meta.nameContent or "__DWKit_chat_console"),
            x = 0,
            y = 0,
            width = "100%",
            height = "100%",
            fontSize = 9,
        }, st.bundle.content)

        pcall(function()
            if type(st.console.setWrap) == "function" then st.console:setWrap(true) end
            if type(st.console.setColor) == "function" then st.console:setColor("white") end
        end)
    else
        -- fallback: no console available; use content as-is (still functional via echo into it if possible)
        st.console = st.bundle.content
    end

    return true
end

local function _wireEventHandler()
    if st.handler ~= nil then return end
    if type(_G.registerAnonymousEventHandler) ~= "function" then return end

    local ok, h = pcall(function()
        return _G.registerAnonymousEventHandler(EV_SVC_CHATLOG_UPDATED, function(_, payload)
            -- Only refresh if visible to avoid unnecessary work.
            if st.visible == true then
                M.refresh({ source = "event", payload = payload })
            end
        end)
    end)

    if ok then
        st.handler = h
    end
end

local function _unwireEventHandler()
    if st.handler == nil then return end
    if type(_G.killAnonymousEventHandler) == "function" then
        pcall(function() _G.killAnonymousEventHandler(st.handler) end)
    end
    st.handler = nil
end

function M.getVersion()
    return tostring(M.VERSION or "unknown")
end

function M.getState()
    return { visible = (st.visible == true) }
end

function M.show(opts)
    opts = (type(opts) == "table") and opts or {}

    if not _ensureUi(opts) then
        return false
    end

    st.visible = true

    if type(st.bundle.frame) == "table" and type(st.bundle.frame.show) == "function" then
        pcall(function() st.bundle.frame:show() end)
    end

    _wireEventHandler()
    M.refresh({ source = "show" })

    return true
end

function M.hide(opts)
    opts = (type(opts) == "table") and opts or {}

    st.visible = false

    if type(st.bundle) == "table" and type(st.bundle.frame) == "table" and type(st.bundle.frame.hide) == "function" then
        pcall(function() st.bundle.frame:hide() end)
    end

    -- Keep handler installed or remove? Safer to remove to reduce background work.
    _unwireEventHandler()

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

    if st.visible ~= true then
        return true
    end
    if not _ensureUi(opts) then
        return false
    end

    local list = Log.listRecent(opts.n or 200, { profileTag = opts.profileTag })
    _clearConsole()

    local lastId = 0
    for _, item in ipairs(list) do
        lastId = tonumber(item.id) or lastId
        _appendConsoleLine(_mkLine(item))
    end
    st.lastRenderedId = lastId

    return true
end

function M.dispose()
    st.visible = false
    _unwireEventHandler()

    -- best-effort delete widgets
    if type(st.console) == "table" and type(st.console.delete) == "function" then
        pcall(function() st.console:delete() end)
    end
    st.console = nil

    if type(st.bundle) == "table" and type(st.bundle.frame) == "table" and type(st.bundle.frame.delete) == "function" then
        pcall(function() st.bundle.frame:delete() end)
    end
    st.bundle = nil

    return true
end

return M
