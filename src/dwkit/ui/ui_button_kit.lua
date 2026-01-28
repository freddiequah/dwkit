-- #########################################################################
-- Module Name : dwkit.ui.ui_button_kit
-- Owner       : UI
-- Version     : v2026-01-28A
-- Purpose     :
--   - Reusable "button label" helpers matching the dwkit.txt ActionPad feel.
--   - This kit standardizes:
--       * stylesheet (enabled/disabled)
--       * font + padding defaults
--       * click callback wiring (label:setClickCallback)
--
-- Public API  :
--   - applyButtonStyle(label, opts?)
--   - wireClick(label, fn)
--
-- Events Emitted   : None
-- Events Consumed  : None
-- Automation Policy: Manual only
-- Dependencies     : dwkit.ui.ui_theme
-- #########################################################################

local Theme = require("dwkit.ui.ui_theme")

local M = {}

M.VERSION = "v2026-01-28A"

local function _appendFont(css, px)
    px = tonumber(px or 0) or 0
    if px > 0 then
        return css .. string.format(" font-size: %dpx;", px)
    end
    return css
end

function M.applyButtonStyle(label, opts)
    opts = (type(opts) == "table") and opts or {}

    if type(label) ~= "table" or type(label.setStyleSheet) ~= "function" then
        return false
    end

    local enabled = (opts.enabled ~= false)
    local css = Theme.buttonStyle(enabled)

    css = _appendFont(css, opts.fontPx)

    local padX = tonumber(opts.padX or 6) or 6
    local padY = tonumber(opts.padY or 0) or 0
    local minH = tonumber(opts.minHeightPx or 0) or 0

    css = css .. string.format(
        " qproperty-alignment: 'AlignCenter'; text-align: center; padding: %dpx %dpx; margin: 0px;",
        padY, padX
    )

    if minH > 0 then
        css = css .. string.format(" min-height: %dpx; max-height: %dpx; line-height: %dpx;", minH, minH, minH)
    end

    pcall(function()
        label:setStyleSheet(css)
    end)

    return true
end

function M.wireClick(label, fn)
    if type(label) ~= "table" then return false end
    if type(label.setClickCallback) ~= "function" then return false end
    if type(fn) ~= "function" then return false end

    pcall(function()
        label:setClickCallback(fn)
    end)

    return true
end

return M
