-- FILE: src/dwkit/ui/ui_window.lua
-- #########################################################################
-- Module Name : dwkit.ui.ui_window
-- Owner       : UI
-- Version     : v2026-02-11E
-- Purpose     :
--   - Shared DWKit "frame" creator:
--       * Prefer Adjustable.Container (movable/resizable + autoSave/autoLoad)
--       * Fallback to plain Geyser.Container when Adjustable is unavailable
--   - Applies centralized theme for header/close and frame border.
--   - Returns { frame, content, closeLabel, meta } for UI modules to build into.
--
-- Key Fixes:
--   (history preserved; see prior versions)
--
--   v2026-02-11C:
--     - HARDEN: resolve real Adjustable "Inside" area more defensively.
--     - ADD: if Inside cannot be resolved, create an insideShim container below header to prevent overlap.
--
--   v2026-02-11D:
--     - FIX: shim header height is now guessed from actual titlebar widgets (closeLabel/title/etc),
--       instead of a fixed 24px default. Prevents title overlap AND reduces bottom gap on profiles
--       where Adjustable does not expose a usable Inside.
--     - HARDEN: resolveInside now prefers explicit Inside keys first and avoids grabbing "content"
--       style widgets that may still include titlebar chrome.
--
--   v2026-02-11E:
--     - FIX: register bundle.content into Geyser maps by nameContent (discoverable across profiles).
--     - ADD: store entry now includes content handle (ui_base.setUiRuntime content=?).
-- #########################################################################

local Theme = require("dwkit.ui.ui_theme")

local M = {}

M.VERSION = "v2026-02-11E"

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

-- Deterministic runtime signal for UI Manager UI:
-- StoreEntry.state.visible is easy to read and does not depend on Adjustable/Geyser isVisible quirks.
local function _setUiBaseRuntimeVisibleBestEffort(uiId, visible)
    uiId = tostring(uiId or "")
    if uiId == "" then return end

    local okB, U = pcall(require, "dwkit.ui.ui_base")
    if not okB or type(U) ~= "table" then return end
    if type(U.getUiStoreEntry) ~= "function" then return end

    local okE, e = pcall(U.getUiStoreEntry, uiId)

    -- If runtime entry was removed during close/dispose, recreate minimal entry (state-only) so rtVisible is deterministic.
    if (not okE) or type(e) ~= "table" then
        if type(U.setUiRuntime) == "function" then
            pcall(function()
                U.setUiRuntime(uiId, {
                    state = { visible = (visible == true) },
                    meta = { uiId = uiId, source = "ui_window:runtime_upsert" },
                })
            end)
        end
        return
    end

    e.state = (type(e.state) == "table") and e.state or {}
    e.state.visible = (visible == true)
end

local function _syncVisibleOffSessionBestEffort(uiId)
    uiId = tostring(uiId or "")
    if uiId == "" then return end

    -- Prefer ui_manager safe helper if present (no recursion, no apply).
    local okUM, UM = pcall(require, "dwkit.ui.ui_manager")
    if okUM and type(UM) == "table" and type(UM.syncVisibleSession) == "function" then
        pcall(function()
            UM.syncVisibleSession(uiId, false, { source = "ui_window:syncVisibleOff", quiet = true })
        end)
        return
    end

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
        -- Direct: method
        if type(c.isVisible) == "function" then
            return c:isVisible()
        end
        -- Direct: flag
        if c.hidden ~= nil then
            return not c.hidden
        end

        -- Adjustable.Container often has a nested window object that tracks visibility:
        if type(c.window) == "table" then
            local w = c.window
            if type(w.isVisible) == "function" then
                return w:isVisible()
            end
            if w.hidden ~= nil then
                return not w.hidden
            end
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

-- Best-effort: register runtime frame+content in Geyser maps + store into ui_base
local function _registerRuntimeBestEffort(bundle)
    if type(bundle) ~= "table" or type(bundle.meta) ~= "table" then return end
    local uiId = tostring(bundle.meta.uiId or "")
    local nameFrame = tostring(bundle.meta.nameFrame or "")
    local nameContent = tostring(bundle.meta.nameContent or "")
    local frame = bundle.frame
    local content = bundle.content

    -- 1) Geyser maps for discoverability (best-effort only)
    local G = _G.Geyser
    if type(G) == "table" then
        if nameFrame ~= "" and type(frame) == "table" then
            if type(G.windows) == "table" then
                pcall(function() G.windows[nameFrame] = frame end)
            end
            if type(G.containers) == "table" then
                pcall(function() G.containers[nameFrame] = frame end)
            end
        end

        -- IMPORTANT: register content by nameContent too (fixes profile-dependent nil lookups)
        if nameContent ~= "" and type(content) == "table" then
            if type(G.windows) == "table" then
                pcall(function() G.windows[nameContent] = content end)
            end
            if type(G.containers) == "table" then
                pcall(function() G.containers[nameContent] = content end)
            end
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
                    content = content,
                    nameFrame = (nameFrame ~= "" and nameFrame) or nil,
                    nameContent = (nameContent ~= "" and nameContent) or nil,
                    meta = bundle.meta,
                    state = { visible = true }, -- deterministic runtime signal
                })
            end)
        end

        -- Also mutate store entry state if already exists (covers implementations that ignore passed state).
        _setUiBaseRuntimeVisibleBestEffort(uiId, true)
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

local function _pickFirstWidget(tbl, keys)
    if type(tbl) ~= "table" then return nil end
    if type(keys) ~= "table" then return nil end
    for _, k in ipairs(keys) do
        local v = tbl[k]
        if type(v) == "table" then
            return v
        end
    end
    return nil
end

local function _parsePxBestEffort(v)
    if type(v) == "number" then
        if v > 0 then return math.floor(v) end
        return nil
    end
    if type(v) == "string" then
        local n = tonumber(v:match("(%d+)"))
        if n and n > 0 then return math.floor(n) end
    end
    return nil
end

local function _getHeightBestEffort(obj)
    if type(obj) ~= "table" then return nil end
    if type(obj.get_height) == "function" then
        local ok, h = pcall(function() return obj:get_height() end)
        if ok then
            h = _parsePxBestEffort(h)
            if h then return h end
        end
    end
    return _parsePxBestEffort(obj.height)
end

-- Try to guess header/titlebar height from actual widgets (best-effort).
local function _guessHeaderHeightBestEffort(frame, bundle, fallback)
    fallback = tonumber(fallback or 24) or 24
    local candidates = {}

    local function _push(obj)
        if type(obj) ~= "table" then return end
        local h = _getHeightBestEffort(obj)
        if h and h > 0 then table.insert(candidates, h) end
    end

    if type(bundle) == "table" then
        _push(bundle.closeLabel)
    end

    if type(frame) == "table" then
        _push(frame.closeLabel)
        _push(frame.minLabel)
        _push(frame.titleLabel)
        if type(frame.window) == "table" then
            local w = frame.window
            _push(w.closeLabel)
            _push(w.minLabel)
            _push(w.titleLabel)
            _push(w.header)
            _push(w.headerLabel)
        end
    end

    local best = nil
    for _, h in ipairs(candidates) do
        if (not best) or h > best then best = h end
    end

    -- Clamp to a sane range
    if type(best) == "number" then
        if best < 18 then best = 18 end
        if best > 60 then best = 60 end
        return best
    end

    return fallback
end

-- Returns:
--  insideParent (table), usedShim(bool), gotExplicitInside(bool)
local function _resolveInsideParent(frame)
    if type(frame) ~= "table" then return frame, false, false end

    -- Adjustable commonly: frame.window.Inside exists
    if type(frame.window) == "table" then
        local w = frame.window

        -- Prefer explicit Inside variants FIRST (this is the safe path)
        local inside = _pickFirstWidget(w, {
            "Inside", "inside", "InsideContainer", "insideContainer", "insideFrame",
        })
        if type(inside) == "table" then
            return inside, false, true
        end

        -- Some builds expose a getter
        if type(w.getInside) == "function" then
            local ok, v = pcall(function() return w:getInside() end)
            if ok and type(v) == "table" then
                return v, false, true
            end
        end

        -- As a last resort, use window itself (caller may shim it)
        return w, false, false
    end

    local inside2 = _pickFirstWidget(frame, { "Inside", "inside", "InsideContainer", "insideContainer", "insideFrame" })
    if type(inside2) == "table" then
        return inside2, false, true
    end

    if type(frame.getInside) == "function" then
        local ok, v = pcall(function() return frame:getInside() end)
        if ok and type(v) == "table" then
            return v, false, true
        end
    end

    return frame, false, false
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

local function _hideCloseChromeBestEffort(bundle)
    if type(bundle) ~= "table" then return end
    local f = bundle.frame
    if type(f) == "table" then
        for _, obj in ipairs({
            bundle.closeLabel,
            f.closeLabel,
            (type(f.window) == "table") and f.window.closeLabel or nil,
        }) do
            if type(obj) == "table" and type(obj.hide) == "function" then
                pcall(function() obj:hide() end)
            end
        end
    end
end

local function _applyFixedBestEffort(bundle)
    if type(bundle) ~= "table" or type(bundle.frame) ~= "table" then return end
    local f = bundle.frame

    -- Best-effort: disable "raiseOnClick" style features (only if API exists)
    if type(f.setRaiseOnClick) == "function" then
        pcall(function() f:setRaiseOnClick(false) end)
    end
    if type(f.raiseOnClick) == "boolean" then
        pcall(function() f.raiseOnClick = false end)
    end

    -- Best-effort: lock / disable move+resize if supported by Adjustable
    for _, fnName in ipairs({
        "lock", "setLocked", "setLock", "setMovable", "setResizable",
        "setMoveable", -- some libs spell it this way
    }) do
        if type(f[fnName]) == "function" then
            pcall(function()
                if fnName == "setMovable" or fnName == "setMoveable" then
                    f[fnName](f, false)
                elseif fnName == "setResizable" then
                    f[fnName](f, false)
                else
                    f[fnName](f, true)
                end
            end)
        end
    end

    if type(f.window) == "table" then
        local w = f.window
        for _, fnName in ipairs({ "lock", "setLocked", "setMovable", "setResizable", "setMoveable" }) do
            if type(w[fnName]) == "function" then
                pcall(function()
                    if fnName == "setMovable" or fnName == "setMoveable" then
                        w[fnName](w, false)
                    elseif fnName == "setResizable" then
                        w[fnName](w, false)
                    else
                        w[fnName](w, true)
                    end
                end)
            end
        end
    end
end

-- OPT-IN: remove inset painting/padding on Adjustable "Inside" widget.
local function _applyAdjustableInsideNoInsetBestEffort(insideParent)
    if type(insideParent) ~= "table" then return end

    -- Apply to Inside itself
    if type(insideParent.setStyleSheet) == "function" then
        pcall(function()
            insideParent:setStyleSheet([[
                background-color: rgba(0,0,0,0);
                border: 0px;
                border-radius: 0px;
                margin: 0px;
                padding: 0px;
            ]])
        end)
    end

    -- Some Adjustable versions nest widgets differently; try window too (best-effort).
    if type(insideParent.window) == "table" and type(insideParent.window.setStyleSheet) == "function" then
        pcall(function()
            insideParent.window:setStyleSheet([[
                background-color: rgba(0,0,0,0);
                border: 0px;
                border-radius: 0px;
                margin: 0px;
                padding: 0px;
            ]])
        end)
    end
end

-- -------------------------------------------------------------------------
-- Adjustable close/hide hook
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

        _setUiBaseRuntimeVisibleBestEffort(uiId, false)
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

    -- DEFAULT BEHAVIOR UNCHANGED: pad=6 unless caller explicitly passes opts.padding.
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
            noClose = (opts.noClose == true),
            fixed = (opts.fixed == true),
        },
    }

    local Adjustable = _getAdjustableBestEffort()
    if type(Adjustable) == "table"
        and type(Adjustable.Container) == "table"
        and type(Adjustable.Container.new) == "function"
    then
        local tf = opts.titleFormat
        if type(tf) ~= "string" or tf == "" then
            tf = "l"
        end

        local frame = Adjustable.Container:new({
            name = nameFrame,
            x = opts.x or 30,
            y = opts.y or 220,
            width = opts.width or 280,
            height = opts.height or 120,
            titleText = title,
            titleTxtColor = "white",
            titleFormat = tf,
            padding = pad,
            buttonsize = btnSz,
            buttonFontSize = btnFont,
            adjLabelstyle = Theme.headerStyle(),
            buttonstyle = Theme.closeStyle(),
            autoSave = true,
            autoLoad = true,
            raiseOnClick = (opts.fixed == true) and false or true,
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

        local insideParent, usedShim, gotExplicitInside = _resolveInsideParent(frame)

        -- If we did NOT get an explicit Inside widget and we're effectively using the window itself,
        -- create a shim below the true header height so content can never overlap titlebar.
        if type(frame.window) == "table" and insideParent == frame.window and gotExplicitInside ~= true then
            local headerH = _guessHeaderHeightBestEffort(frame, bundle, tonumber(opts.headerHeight or 24) or 24)
            local shimName = tostring(nameFrame) .. "__insideShim"
            local shim = G.Container:new({
                name = shimName,
                x = 0,
                y = headerH,
                width = "100%",
                height = "-" .. tostring(headerH) .. "px",
            }, frame.window)
            if type(shim.setStyleSheet) == "function" then
                pcall(function()
                    shim:setStyleSheet([[
                        background-color: rgba(0,0,0,0);
                        border: 0px;
                        margin: 0px;
                        padding: 0px;
                    ]])
                end)
            end
            insideParent = shim
            usedShim = true
        end

        bundle.meta.insideShim = (usedShim == true)

        -- OPT-IN only.
        if opts.noInsetInside == true then
            _applyAdjustableInsideNoInsetBestEffort(insideParent)
        end

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

    -- Apply "fixed" + "noClose" chrome behavior after runtime registration so state exists either way.
    if bundle.meta.fixed == true then
        _applyFixedBestEffort(bundle)
    end
    if bundle.meta.noClose == true then
        _hideCloseChromeBestEffort(bundle)
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
        -- If noClose is enabled, ignore user close attempts (best-effort).
        if bundle.meta and bundle.meta.noClose == true then
            return
        end

        local id = (bundle.meta and bundle.meta.uiId) or uiId

        _setUiBaseRuntimeVisibleBestEffort(id, false)
        _syncVisibleOffSessionBestEffort(id)
        onClose(bundle)
        _refreshUiManagerUiBestEffort("ui_window:xclick", id)
    end

    -- Wire X click callbacks only if close is allowed.
    if bundle.meta.noClose ~= true then
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
    end

    return bundle
end

return M
