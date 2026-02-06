-- #########################################################################
-- Module Name : dwkit.ui.ui_window
-- Owner       : UI
-- Version     : v2026-02-06J
-- Purpose     :
--   - Shared DWKit "frame" creator:
--       * Prefer Adjustable.Container (movable/resizable + autoSave/autoLoad)
--       * Fallback to plain Geyser.Container when Adjustable is unavailable
--   - Applies centralized theme for header/close and frame border.
--   - Returns { frame, content, closeLabel, meta } for UI modules to build into.
--
-- Key Fixes:
--   v2026-02-06D:
--     - Wrapped frame:hide() to sync visible=false and call ui_manager.applyOne().
--       (This introduced recursion: ui_manager.applyOne -> presence_ui.apply -> safeHide -> frame:hide -> loop.)
--   v2026-02-06E:
--     - FIX: hide-hook no longer calls ui_manager.applyOne() or ui_manager_ui.apply().
--       It ONLY syncs gui_settings.visible=false (noSave best-effort) to avoid recursion and login spam.
--   v2026-02-06F:
--     - FIX: hide-hook respects internal hides via _dwkitSuppressHideHook (set by ui_base.safeHide).
--   v2026-02-06H:
--     - FIX: UI Manager refresh must occur AFTER hide/close runs.
--   v2026-02-06I:
--     - Attempted: keep UI Manager visible by forcing cfg visible=true then calling apply().
--       This is NOT safe because apply() enforces cfg and can still close UI Manager.
--   v2026-02-06J:
--     - FIX: ui_window MUST NEVER call ui_manager_ui.apply() as a "refresh".
--       apply() enforces gui_settings.visible(ui_manager_ui) and can hide/close UI Manager.
--       Now: refresh path calls ui_manager_ui.refresh() (rows-only) if available; otherwise no-op.
-- #########################################################################

local Theme = require("dwkit.ui.ui_theme")

local M = {}

M.VERSION = "v2026-02-06J"

local function _pcall(fn, ...)
    local ok, res = pcall(fn, ...)
    if ok then return true, res end
    return false, res
end

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

local function _tryContainerVisibleBestEffort(c)
    if type(c) ~= "table" then return nil end
    local ok, v = pcall(function()
        if type(c.isVisible) == "function" then
            return c:isVisible()
        end
        if c.hidden ~= nil then
            return not c.hidden
        end
        return nil
    end)
    if ok then return v end
    return nil
end

local function _getUiManagerRuntimeVisibleBestEffort()
    -- Prefer ui_manager_ui.getState() if available
    local okU, uiMgrUi = pcall(require, "dwkit.ui.ui_manager_ui")
    if okU and type(uiMgrUi) == "table" then
        if type(uiMgrUi.getState) == "function" then
            local okS, st = pcall(uiMgrUi.getState)
            if okS and type(st) == "table" and st.visible ~= nil then
                return st.visible == true
            end
        end
    end

    -- Fallback: check ui_base store entry
    local okB, U = pcall(require, "dwkit.ui.ui_base")
    if okB and type(U) == "table" and type(U.getUiStoreEntry) == "function" then
        local okE, e = pcall(U.getUiStoreEntry, "ui_manager_ui")
        if okE and type(e) == "table" then
            local c = e.container or e.frame
            local cv = _tryContainerVisibleBestEffort(c)
            if cv ~= nil then return cv end
        end
    end

    return nil
end

local function _refreshUiManagerUiBestEffort(source, targetUiId)
    targetUiId = tostring(targetUiId or "")
    if targetUiId == "ui_manager_ui" then
        return
    end

    -- Only refresh if UI Manager is already open (runtime-visible best-effort).
    local isOpen = _getUiManagerRuntimeVisibleBestEffort()
    if isOpen ~= true then
        return
    end

    -- CRITICAL:
    -- ui_window must NEVER call ui_manager_ui.apply() as a refresh.
    -- apply() enforces gui_settings.visible(ui_manager_ui) and can hide/close UI Manager.
    -- Refresh should ONLY redraw rows while it is already open.
    local okU, uiMgrUi = pcall(require, "dwkit.ui.ui_manager_ui")
    if okU and type(uiMgrUi) == "table" then
        if type(uiMgrUi.refresh) == "function" then
            pcall(function()
                uiMgrUi.refresh({ source = source or "ui_window", quiet = true })
            end)
        end
    end
end

-- Best-effort: register runtime frame in Geyser maps + store into ui_base
local function _registerRuntimeBestEffort(bundle)
    if type(bundle) ~= "table" or type(bundle.meta) ~= "table" then return end
    local uiId = tostring(bundle.meta.uiId or "")
    local nameFrame = tostring(bundle.meta.nameFrame or "")
    local nameContent = tostring(bundle.meta.nameContent or "")
    local frame = bundle.frame

    -- 1) Geyser maps for discoverability (best-effort only)
    local G = _G.Geyser
    if type(G) == "table" and nameFrame ~= "" and type(frame) == "table" then
        if type(G.windows) == "table" then
            pcall(function() G.windows[nameFrame] = frame end)
        end
        if type(G.containers) == "table" then
            pcall(function() G.containers[nameFrame] = frame end)
        end
    end

    -- 2) Deterministic store entry (best-effort only)
    if uiId ~= "" then
        local okU, U = pcall(require, "dwkit.ui.ui_base")
        if okU and type(U) == "table" and type(U.setUiRuntime) == "function" then
            pcall(function()
                U.setUiRuntime(uiId, {
                    frame = frame,
                    container = frame,
                    nameFrame = (nameFrame ~= "" and nameFrame) or nil,
                    nameContent = (nameContent ~= "" and nameContent) or nil,
                    meta = bundle.meta,
                })
            end)
        end
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

local function _safeEchoX(lbl)
    if type(lbl) ~= "table" then return end
    pcall(function()
        if type(lbl.setStyleSheet) == "function" then
            lbl:setStyleSheet(Theme.closeStyle())
        end
        if type(lbl.echo) == "function" then
            lbl:echo("X")
        end
    end)
end

local function _createFallbackCloseLabel(G, parent, name, headerH)
    if type(G) ~= "table" or type(parent) ~= "table" then return nil end
    local h = tonumber(headerH or 24) or 24

    local close = G.Label:new({
        name = name,
        x = "-28px",
        y = 0,
        width = "28px",
        height = h,
    }, parent)

    _safeEchoX(close)
    return close
end

local function _callOrigBestEffort(fn, selfObj, ...)
    if type(fn) ~= "function" then return nil end
    local ok, r1, r2, r3, r4 = pcall(fn, selfObj, ...)
    if ok then
        return r1, r2, r3, r4
    end
    return nil
end

-- -------------------------------------------------------------------------
-- Adjustable close/hide hook:
-- Wrap frame:hide() (and close if present) so title-bar X updates DWKit
-- visible state (gui_settings.visible=false noSave) even if closeLabel callbacks do not fire.
--
-- Rules:
--   - DO NOT call ui_manager.applyOne() here (no recursion).
--   - DO respect _dwkitSuppressHideHook (internal hides).
--   - DO refresh ui_manager_ui AFTER the hide/close actually ran.
--   - DO NOT call ui_manager_ui.apply() from refresh path (use refresh()).
-- -------------------------------------------------------------------------
local function _installAdjustableHideHookBestEffort(frame, bundle)
    if type(frame) ~= "table" or type(bundle) ~= "table" or type(bundle.meta) ~= "table" then
        return false
    end

    local uiId = tostring(bundle.meta.uiId or "")
    if uiId == "" then return false end

    local origHide = (type(frame.hide) == "function") and frame.hide or nil
    local origClose = (type(frame.close) == "function") and frame.close or nil

    local win = (type(frame.window) == "table") and frame.window or nil
    local origWinHide = (type(win) == "table" and type(win.hide) == "function") and win.hide or nil
    local origWinClose = (type(win) == "table" and type(win.close) == "function") and win.close or nil

    if type(origHide) ~= "function" then
        return false
    end

    if frame._dwkitHideWrapped == true then
        return true
    end
    frame._dwkitHideWrapped = true

    frame._dwkitCloseInFlight = false

    local function _isSuppressed(obj)
        if type(obj) ~= "table" then return false end
        if obj._dwkitSuppressHideHook == true then return true end
        if type(obj.window) == "table" and obj.window._dwkitSuppressHideHook == true then return true end
        return false
    end

    local function _postHideUpdate(source, suppressed)
        if suppressed then
            return
        end
        _syncVisibleOffSessionBestEffort(uiId)
        _refreshUiManagerUiBestEffort("ui_window:hidehook:" .. tostring(source or "hide"), uiId)
    end

    frame.hide = function(self, ...)
        if frame._dwkitCloseInFlight == true then
            return _callOrigBestEffort(origHide, self, ...)
        end
        frame._dwkitCloseInFlight = true

        local suppressed = _isSuppressed(self)
        local r1, r2, r3, r4 = _callOrigBestEffort(origHide, self, ...)

        -- AFTER hide
        _postHideUpdate("frame.hide", suppressed)

        frame._dwkitCloseInFlight = false
        return r1, r2, r3, r4
    end

    if type(origClose) == "function" then
        frame.close = function(self, ...)
            if frame._dwkitCloseInFlight == true then
                return _callOrigBestEffort(origClose, self, ...)
            end
            frame._dwkitCloseInFlight = true

            local suppressed = _isSuppressed(self)
            local r1, r2, r3, r4 = _callOrigBestEffort(origClose, self, ...)

            -- AFTER close
            _postHideUpdate("frame.close", suppressed)

            frame._dwkitCloseInFlight = false
            return r1, r2, r3, r4
        end
    end

    if type(win) == "table" and type(origWinHide) == "function" then
        if win._dwkitHideWrapped ~= true then
            win._dwkitHideWrapped = true

            win.hide = function(self, ...)
                if frame._dwkitCloseInFlight == true then
                    return _callOrigBestEffort(origWinHide, self, ...)
                end
                frame._dwkitCloseInFlight = true

                local suppressed = _isSuppressed(self)
                local r1, r2, r3, r4 = _callOrigBestEffort(origWinHide, self, ...)

                -- AFTER hide
                _postHideUpdate("frame.window.hide", suppressed)

                frame._dwkitCloseInFlight = false
                return r1, r2, r3, r4
            end

            if type(origWinClose) == "function" then
                win.close = function(self, ...)
                    if frame._dwkitCloseInFlight == true then
                        return _callOrigBestEffort(origWinClose, self, ...)
                    end
                    frame._dwkitCloseInFlight = true

                    local suppressed = _isSuppressed(self)
                    local r1, r2, r3, r4 = _callOrigBestEffort(origWinClose, self, ...)

                    -- AFTER close
                    _postHideUpdate("frame.window.close", suppressed)

                    frame._dwkitCloseInFlight = false
                    return r1, r2, r3, r4
                end
            end
        end
    end

    bundle.meta._dwkitOrigHide = origHide
    bundle.meta._dwkitOrigClose = origClose
    bundle.meta._dwkitOrigWinHide = origWinHide
    bundle.meta._dwkitOrigWinClose = origWinClose

    return true
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
    if type(Adjustable) == "table"
        and type(Adjustable.Container) == "table"
        and type(Adjustable.Container.new) == "function"
    then
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
        _applyFrameStyleBestEffort(frame)

        local closeA = nil
        local closeB = nil
        if type(frame) == "table" then
            closeA = frame.closeLabel
            if type(frame.window) == "table" then
                closeB = frame.window.closeLabel
            end
        end

        if type(closeB) == "table" then
            bundle.closeLabel = closeB
        elseif type(closeA) == "table" then
            bundle.closeLabel = closeA
        end

        local insideParent = _resolveInsideParent(frame)

        local content = G.Container:new({
            name = nameContent,
            x = 0,
            y = 0,
            width = "100%",
            height = "100%",
        }, insideParent)

        bundle.content = content

        _installAdjustableHideHookBestEffort(frame, bundle)
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

        local close = _createFallbackCloseLabel(G, frame, nameFrame .. "__close", headerH)

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

    _registerRuntimeBestEffort(bundle)

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

        -- intent: user hide (session-only)
        _syncVisibleOffSessionBestEffort(id)

        -- perform hide
        onClose(bundle)

        -- refresh UI Manager rows (rows-only, safe)
        _refreshUiManagerUiBestEffort("ui_window:xclick", id)
    end

    if bundle.meta.adjustable == true then
        local frame = bundle.frame
        local closeA = (type(frame) == "table") and frame.closeLabel or nil
        local closeB = (type(frame) == "table" and type(frame.window) == "table") and frame.window.closeLabel or nil

        local wired = false
        if type(closeB) == "table" then
            wired = _wireClickBestEffort(closeB, _onXClicked) or wired
        end
        if type(closeA) == "table" and closeA ~= closeB then
            wired = _wireClickBestEffort(closeA, _onXClicked) or wired
        end

        if type(bundle.closeLabel) == "table" and bundle.closeLabel ~= closeA and bundle.closeLabel ~= closeB then
            wired = _wireClickBestEffort(bundle.closeLabel, _onXClicked) or wired
        end

        if not wired and type(bundle.closeLabel) == "table" then
            _wireClickBestEffort(bundle.closeLabel, _onXClicked)
        end
    else
        if type(bundle.closeLabel) == "table" then
            _wireClickBestEffort(bundle.closeLabel, _onXClicked)
        end
    end

    return bundle
end

return M
