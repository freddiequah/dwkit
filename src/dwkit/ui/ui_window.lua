-- #########################################################################
-- Module Name : dwkit.ui.ui_window
-- Owner       : UI
-- Version     : v2026-01-28A
-- Purpose     :
--   - Shared DWKit "frame" creator:
--       * Prefer Adjustable.Container (movable/resizable + autoSave/autoLoad)
--       * Fallback to plain Geyser.Container when Adjustable is unavailable
--   - Applies centralized theme for header/close and frame border.
--   - Returns { frame, content, closeLabel, meta } for UI modules to build into.
--
-- Public API  :
--   - create(opts) -> table|nil frameBundle
--       opts = {
--           uiId        = string (required)
--           title       = string (required)
--           x,y,width,height = number|string (optional; defaults provided by caller)
--           padding     = number (optional; default 6)
--           buttonSize  = number (optional; default 18)
--           buttonFontSize = number (optional; default 9)
--           profileTag  = string (optional)
--           onClose     = function(bundle) (optional)
--       }
--   - getProfileTagBestEffort() -> string
--   - hideMinimizeChromeBestEffort(container)
--
-- Events Emitted   : None
-- Events Consumed  : None
-- Automation Policy: Manual only
-- Dependencies     :
--   - Geyser (Mudlet)
--   - Optional: Adjustable.Container (Mudlet package)
-- #########################################################################

local Theme = require("dwkit.ui.ui_theme")

local M = {}

M.VERSION = "v2026-01-28A"

local function _pcall(fn, ...)
    local ok, res = pcall(fn, ...)
    if ok then return true, res end
    return false, res
end

function M.getProfileTagBestEffort()
    -- Prefer Mudlet profile name if available
    if type(_G.getProfileName) == "function" then
        local ok, v = _pcall(_G.getProfileName)
        if ok and type(v) == "string" and v ~= "" then
            -- Normalize to something filename-ish / widget-name-safe
            v = v:gsub("%s+", "_")
            v = v:gsub("[^%w_%-]", "")
            if v ~= "" then return v end
        end
    end
    return "default"
end

function M.hideMinimizeChromeBestEffort(container)
    if type(container) ~= "table" then return end

    local function _hide(obj)
        if type(obj) == "table" and type(obj.hide) == "function" then
            pcall(function() obj:hide() end)
        end
    end

    for _, k in ipairs({ "minLabel", "minimizeLabel", "minButton", "minimizeButton" }) do
        _hide(container[k])
    end

    if type(container.window) == "table" then
        for _, k in ipairs({ "minLabel", "minimizeLabel", "minButton", "minimizeButton" }) do
            _hide(container.window[k])
        end
    end
end

local function _getAdjustableBestEffort()
    -- Most Mudlet installs expose Adjustable as a global when installed.
    if type(_G.Adjustable) == "table" and type(_G.Adjustable.Container) == "table" then
        return _G.Adjustable
    end

    -- Best-effort require
    if type(_G.require) == "function" then
        local ok, mod = pcall(require, "Adjustable.Container")
        if ok and mod then
            -- Some versions return the module directly; some return a table with .Container
            if type(mod) == "table" and type(mod.Container) == "table" then
                return mod
            end
            if type(mod) == "table" and type(mod.new) == "function" then
                return { Container = mod }
            end
        end
    end

    return nil
end

local function _resolveInsideParent(frame)
    -- dwkit.txt pattern:
    --   parentForContent =
    --     (frame.window and (frame.window.Inside or frame.window.inside or frame.window))
    --     or frame.Inside or frame.inside or frame
    if type(frame) ~= "table" then return frame end

    if type(frame.window) == "table" then
        return frame.window.Inside or frame.window.inside or frame.window
    end

    return frame.Inside or frame.inside or frame
end

local function _applyFrameStyleBestEffort(frame)
    if type(frame) ~= "table" then return end

    if type(frame.setStyleSheet) == "function" then
        pcall(function() frame:setStyleSheet(Theme.frameStyle()) end)
        return
    end

    if type(frame.window) == "table" and type(frame.window.setStyleSheet) == "function" then
        pcall(function() frame.window:setStyleSheet(Theme.frameStyle()) end)
    end
end

function M.create(opts)
    opts = (type(opts) == "table") and opts or {}
    local uiId = tostring(opts.uiId or "")
    local title = tostring(opts.title or "")

    if uiId == "" or title == "" then
        return nil
    end

    local tag = tostring(opts.profileTag or M.getProfileTagBestEffort())
    if tag == "" then tag = "default" end

    local G = _G.Geyser
    if type(G) ~= "table" then
        return nil
    end

    local pad = tonumber(opts.padding or 6) or 6
    local btnSz = tonumber(opts.buttonSize or 18) or 18
    local btnFont = tonumber(opts.buttonFontSize or 9) or 9

    local nameFrame = string.format("__DWKit_%s_frame_%s", uiId, tag)
    local nameContent = string.format("__DWKit_%s_content_%s", uiId, tag)

    local bundle = {
        frame = nil,
        content = nil,
        closeLabel = nil,
        meta = {
            uiId = uiId,
            title = title,
            profileTag = tag,
            adjustable = false,
            nameFrame = nameFrame,
            nameContent = nameContent,
        },
    }

    local Adjustable = _getAdjustableBestEffort()
    if type(Adjustable) == "table" and type(Adjustable.Container) == "table" and type(Adjustable.Container.new) == "function" then
        -- Use Adjustable.Container (movable/resizable)
        local frame = Adjustable.Container:new({
            name = nameFrame,
            x = opts.x or 30,
            y = opts.y or 220,
            width = opts.width or 280,
            height = opts.height or 120,
            titleText = title,
            titleTxtColor = "white",
            titleFormat = "l##9",
            padding = pad,
            buttonsize = btnSz,
            buttonFontSize = btnFont,
            adjLabelstyle = Theme.headerStyle(),
            buttonstyle = Theme.closeStyle(),
            autoSave = true,
            autoLoad = true,
            raiseOnClick = true,
            lockStyle = "standard",
        })

        bundle.frame = frame
        bundle.meta.adjustable = true

        M.hideMinimizeChromeBestEffort(frame)

        if type(frame) == "table" then
            bundle.closeLabel = frame.closeLabel
        end

        _applyFrameStyleBestEffort(frame)

        local insideParent = _resolveInsideParent(frame)

        local content = G.Container:new({
            name = nameContent,
            x = 0,
            y = 0,
            width = "100%",
            height = "100%",
        }, insideParent)

        bundle.content = content
    else
        -- Fallback: plain container (still themed)
        local frame = G.Container:new({
            name = nameFrame,
            x = opts.x or 30,
            y = opts.y or 220,
            width = opts.width or 280,
            height = opts.height or 120,
        })

        _applyFrameStyleBestEffort(frame)

        local headerH = 24
        local header = G.Label:new({
            name = nameFrame .. "__hdr",
            x = 0,
            y = 0,
            width = "100%",
            height = headerH,
        }, frame)
        pcall(function()
            header:setStyleSheet(Theme.headerStyle())
            header:echo(" " .. title)
        end)

        local close = G.Label:new({
            name = nameFrame .. "__close",
            x = "-28px",
            y = 0,
            width = "28px",
            height = headerH,
        }, frame)
        pcall(function()
            close:setStyleSheet(Theme.closeStyle())
            close:echo("X")
        end)

        local content = G.Container:new({
            name = nameContent,
            x = 0,
            y = headerH,
            width = "100%",
            height = "-" .. tostring(headerH) .. "px",
        }, frame)

        bundle.frame = frame
        bundle.content = content
        bundle.closeLabel = close
        bundle.meta.adjustable = false
    end

    -- Wire close action
    local onClose = opts.onClose
    if type(onClose) ~= "function" then
        onClose = function(b)
            if type(b) == "table" and type(b.frame) == "table" and type(b.frame.hide) == "function" then
                pcall(function() b.frame:hide() end)
            end
        end
    end

    if type(bundle.closeLabel) == "table" and type(bundle.closeLabel.setClickCallback) == "function" then
        pcall(function()
            bundle.closeLabel:setClickCallback(function()
                onClose(bundle)
            end)
        end)
    end

    return bundle
end

return M
