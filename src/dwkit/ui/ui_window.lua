-- #########################################################################
-- Module Name : dwkit.ui.ui_window
-- Owner       : UI
-- Version     : v2026-01-28A
-- Purpose     :
--   - Standard UI window wrapper (Frame + Title + Close)
--   - Supports Adjustable container when available, otherwise falls back to Geyser
-- #########################################################################

local M = {}

M.VERSION = "v2026-01-28A"

local U = require("dwkit.ui.ui_utils")
local Theme = require("dwkit.ui.ui_theme")

local function _safeRequire(moduleName)
    local ok, modOrErr = pcall(require, moduleName)
    if ok then
        return true, modOrErr
    end
    return false, nil
end

local function _mkId(prefix)
    prefix = tostring(prefix or "DWKitWin")
    local s = tostring(os.time()) .. tostring(math.random(1000, 9999))
    s = s:gsub("%W", "")
    return prefix .. "_" .. s
end

function M.getVersion()
    return tostring(M.VERSION)
end

function M.getProfileTagBestEffort()
    local ok, profileName = pcall(function()
        if type(getProfileName) == "function" then
            return getProfileName()
        end
        return nil
    end)
    if ok and type(profileName) == "string" and profileName ~= "" then
        return profileName:gsub("%W+", "_")
    end
    return nil
end

function M.create(opts)
    opts = (type(opts) == "table") and opts or {}

    local title = tostring(opts.title or "Window")
    local id = tostring(opts.id or _mkId("DWKitWin"))

    local parent = opts.parent
    local x = opts.x or "0%"
    local y = opts.y or "0%"
    local w = opts.width or "30%"
    local h = opts.height or "30%"

    local onClose = opts.onClose

    local bundle = {
        frame = nil,
        content = nil,
        closeLabel = nil,
        headerLabel = nil,
        setTitle = nil,
        meta = {
            id = id,
            title = title,
            adjustable = false,
        }
    }

    -- Adjustable container path (preferred)
    local okA, Adjustable = _safeRequire("Adjustable")
    if okA and type(Adjustable) == "table" and type(Adjustable.Container) == "function" then
        local frame = Adjustable.Container({
            name = id,
            x = x,
            y = y,
            width = w,
            height = h,
            fixed = false,
        })

        if parent then
            pcall(function()
                frame:setParent(parent)
            end)
        end

        -- Hide minimizer, keep close
        pcall(function()
            if type(frame.minimizeLabel) == "table" then
                frame.minimizeLabel:hide()
            end
        end)

        local okInside = false
        local content = nil
        if type(frame.window) == "table" then
            local inside = frame.window.Inside
            if type(inside) == "table" then
                content = inside
                okInside = true
            end
        end

        bundle.frame = frame
        bundle.content = content
        bundle.closeLabel = (type(frame.closeLabel) == "table") and frame.closeLabel or nil
        bundle.meta.adjustable = true

        if okInside ~= true then
            -- fallback for content: use frame itself
            bundle.content = frame
        end

        return bundle
    end

    -- Fallback Geyser frame path
    local G = U.getGeyser()
    if not G then
        return bundle
    end

    local outer = G.Container:new({
        name = id,
        x = x,
        y = y,
        width = w,
        height = h,
    }, parent)

    local headerH = 22

    local header = G.Label:new({
        name = id .. "_header",
        x = 0,
        y = 0,
        width = "100%",
        height = headerH,
    }, outer)

    local close = G.Label:new({
        name = id .. "_close",
        x = "100%-30",
        y = 0,
        width = 30,
        height = headerH,
    }, outer)

    local content = G.Container:new({
        name = id .. "_content",
        x = 0,
        y = headerH,
        width = "100%",
        height = "100%-" .. tostring(headerH),
    }, outer)

    pcall(function()
        header:setStyleSheet(Theme.headerStyle())
        header:echo(" " .. title)
    end)

    bundle.headerLabel = header

    pcall(function()
        close:setStyleSheet(Theme.closeStyle())
        close:echo("<center>x</center>")
    end)

    bundle.frame = outer
    bundle.content = content
    bundle.closeLabel = close
    bundle.meta.adjustable = false

    -- Best-effort: allow callers to update title (used for status badges).
    bundle.setTitle = function(newTitle)
        newTitle = tostring(newTitle or "")
        if newTitle == "" then return end
        bundle.meta.title = newTitle

        local frame = bundle.frame
        local ok = false

        if type(frame) == "table" then
            local candidates = { "setTitle", "setWindowTitle", "setName", "setText" }
            for _, fn in ipairs(candidates) do
                if type(frame[fn]) == "function" then
                    ok = pcall(function() frame[fn](frame, newTitle) end)
                    if ok then break end
                end
            end
        end

        if not ok and type(bundle.headerLabel) == "table" and type(bundle.headerLabel.echo) == "function" then
            pcall(function() bundle.headerLabel:echo(" " .. newTitle) end)
        end
    end

    if type(onClose) == "function" then
        if type(close) == "table" then
            if type(_G.setLabelClickCallback) == "function" then
                pcall(function()
                    setLabelClickCallback(close.name, function()
                        onClose(bundle)
                    end)
                end)
            end
        end
    end

    return bundle
end

return M
