-- #########################################################################
-- Module Name : dwkit.ui.ui_list_kit
-- Owner       : UI
-- Version     : v2026-01-28A
-- Purpose     :
--   - Reusable styles/helpers for "data panel" UIs (Presence_UI style).
--   - Standardizes:
--       * background panel look
--       * label text rendering (preformatted HTML)
--
-- Public API  :
--   - applyPanelStyle(container)
--   - applyTextLabelStyle(label)
--   - toPreHtml(text) -> string
--
-- Events Emitted   : None
-- Events Consumed  : None
-- Automation Policy: Manual only
-- Dependencies     : dwkit.ui.ui_theme
-- #########################################################################

local Theme = require("dwkit.ui.ui_theme")

local M = {}

M.VERSION = "v2026-01-28A"

function M.applyPanelStyle(container)
    if type(container) ~= "table" or type(container.setStyleSheet) ~= "function" then
        return false
    end

    pcall(function()
        container:setStyleSheet(Theme.bodyStyle())
    end)

    return true
end

function M.applyTextLabelStyle(label)
    if type(label) ~= "table" or type(label.setStyleSheet) ~= "function" then
        return false
    end

    -- Slightly more readable list panel default
    local css = [[
        background-color: rgba(0,0,0,0);
        border: 0px;
        color: #e5e9f0;
        padding: 8px;
        font-size: 10pt;
        qproperty-alignment: 'AlignTop | AlignLeft';
    ]]

    pcall(function()
        label:setStyleSheet(css)
    end)

    return true
end

function M.toPreHtml(text)
    text = tostring(text or "")
    -- Escape minimal HTML entities
    text = text:gsub("&", "&amp;")
    text = text:gsub("<", "&lt;")
    text = text:gsub(">", "&gt;")
    -- Preserve whitespace/newlines
    return "<pre style='margin:0; padding:0;'>" .. text .. "</pre>"
end

return M
