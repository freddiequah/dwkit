-- #########################################################################
-- Module Name : dwkit.ui.ui_window
-- Owner       : UI
-- Version     : v2026-02-05D
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

M.VERSION = "v2026-02-05D"

local function _pcall(fn, ...)
    local ok, res = pcall(fn, ...)
    if ok then return true, res end
    return false, res
end

-- -------------------------------------------------------------------------
-- X button semantics:
--   Clicking X is a "Hide" action (session-only), NOT "Disable".
--   We (1) set gui_settings.visible=false with noSave, then (2) best-effort
--   route the hide through ui_manager.applyOne(uiId) so module runtime state
--   and UI Manager rows stay consistent immediately.
-- -------------------------------------------------------------------------

local function _getGuiSettingsSingletonBestEffort()
    if type(_G.DWKit) == "table"
        and type(_G.DWKit.config) == "table"
        and type(_G.DWKit.config.guiSettings) == "table"
    then
        return _G.DWKit.config.guiSettings
    end
    local okGS, gsOrErr = pcall(require, "dwkit.config.gui_settings")
    if okGS and type(gsOrErr) == "table" then
        return gsOrErr
    end
    return nil
end

local function _syncVisibleOffSessionBestEffort(uiId)
    uiId = tostring(uiId or "")
    if uiId == "" then return end

    local gs = _getGuiSettingsSingletonBestEffort()
    if type(gs) ~= "table" then return end

    if type(gs.enableVisiblePersistence) == "function" then
        pcall(gs.enableVisiblePersistence, { noSave = true })
    end

    if type(gs.setVisible) == "function" then
        pcall(gs.setVisible, uiId, false, { noSave = true })
    end
end

local function _applyHideViaUiManagerBestEffort(uiId)
    uiId = tostring(uiId or "")
    if uiId == "" then return end

    local okUM, UM = pcall(require, "dwkit.ui.ui_manager")
    if okUM and type(UM) == "table" and type(UM.applyOne) == "function" then
        pcall(function()
            UM.applyOne(uiId, { source = "ui_window:x", quiet = true })
        end)
    end
end

function M.getProfileTagBestEffort()
    if type(_G.getProfileName) == "function" then
        local ok, v = _pcall(_G.getProfileName)
        if ok and type(v) == "string" and v ~= "" then
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
    if type(_G.Adjustable) == "table" and type(_G.Adjustable.Container) == "table" then
        return _G.Adjustable
    end

    if type(_G.require) == "function" then
        local ok, mod = pcall(require, "Adjustable.Container")
        if ok and mod then
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

local function _wireClickBestEffort(labelObj, fn)
    if type(labelObj) ~= "table" or type(fn) ~= "function" then return false end

    local wired = false

    if type(labelObj.setClickCallback) == "function" then
        local ok = pcall(function()
            labelObj:setClickCallback(fn)
        end)
        wired = wired or (ok == true)
    end

    if not wired then
        local name = tostring(labelObj.name or "")
        if name ~= "" and type(_G.setLabelClickCallback) == "function" then
            local ok = pcall(function()
                _G.setLabelClickCallback(name, fn)
            end)
            wired = wired or (ok == true)
        end
    end

    return wired
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
            if type(bundle.closeLabel) ~= "table" and type(frame.window) == "table" then
                bundle.closeLabel = frame.window.closeLabel
            end
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

    local onClose = opts.onClose
    if type(onClose) ~= "function" then
        onClose = function(b)
            if type(b) == "table" and type(b.frame) == "table" and type(b.frame.hide) == "function" then
                pcall(function() b.frame:hide() end)
            end
        end
    end

    local function _onXClicked()
        local id = (bundle.meta and bundle.meta.uiId) or uiId
        _syncVisibleOffSessionBestEffort(id)
        _applyHideViaUiManagerBestEffort(id)
        onClose(bundle)
    end

    if type(bundle.closeLabel) == "table" then
        _wireClickBestEffort(bundle.closeLabel, _onXClicked)
    end

    return bundle
end

return M
