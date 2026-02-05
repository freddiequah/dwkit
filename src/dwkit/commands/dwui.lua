-- #########################################################################
-- Module Name : dwkit.commands.dwui
-- Owner       : Commands
-- Version     : v2026-02-05A
-- Purpose     :
--   - Command handler for "dwui" (SAFE)
--   - Primary behavior: open/show the UI Manager UI surface (ui_manager_ui).
--
-- Notes:
--   - This command is an explicit user action; it may set:
--       * ui_manager_ui enabled = ON (persisted)
--       * ui_manager_ui visible = ON (session-only; noSave) by enabling visible persistence noSave
--   - It then applies the UI via dwkit.ui.ui_manager.applyOne("ui_manager_ui") (preferred).
--   - SAFE: no gameplay commands, no timers, no hidden automation.
--
-- Public API  :
--   - dispatch(ctx, tokens)
--   - dispatch(tokens)   (best-effort)
-- #########################################################################

local M = {}

M.VERSION = "v2026-02-05A"

local function _out(ctx, line)
    if type(ctx) == "table" and type(ctx.out) == "function" then
        ctx.out(line)
        return
    end
    if type(cecho) == "function" then
        cecho(tostring(line or "") .. "\n")
    elseif type(echo) == "function" then
        echo(tostring(line or "") .. "\n")
    else
        print(tostring(line or ""))
    end
end

local function _err(ctx, msg)
    _out(ctx, "[DWKit UI] ERROR: " .. tostring(msg))
end

local function _isArrayLike(t)
    if type(t) ~= "table" then return false end
    local n = #t
    if n == 0 then return false end
    for i = 1, n do
        if t[i] == nil then return false end
    end
    return true
end

local function _parseTokens(tokens)
    if not (_isArrayLike(tokens) and tostring(tokens[1] or "") == "dwui") then
        return ""
    end
    return tostring(tokens[2] or "")
end

local function _getGuiSettingsFromCtx(ctx)
    if type(ctx) == "table" and type(ctx.getGuiSettings) == "function" then
        local ok, gs = pcall(ctx.getGuiSettings)
        if ok and type(gs) == "table" then
            return gs
        end
    end
    return nil
end

local function _safeRequire(ctx, modName)
    if type(ctx) == "table" and type(ctx.safeRequire) == "function" then
        local ok, modOrErr = ctx.safeRequire(modName)
        if ok and type(modOrErr) == "table" then
            return true, modOrErr, nil
        end
        return false, nil, tostring(modOrErr)
    end
    local ok, modOrErr = pcall(require, modName)
    if ok and type(modOrErr) == "table" then
        return true, modOrErr, nil
    end
    return false, nil, tostring(modOrErr)
end

local function _ensureVisiblePersistenceSession(gs)
    if type(gs) ~= "table" or type(gs.enableVisiblePersistence) ~= "function" then
        return true
    end
    -- session-only; avoids persisting visible persistence toggle unless user explicitly chooses later
    pcall(gs.enableVisiblePersistence, { noSave = true })
    return true
end

local function _ensureUiManagerUiEnabled(gs)
    if type(gs) ~= "table" or type(gs.setEnabled) ~= "function" then
        return false, "guiSettings.setEnabled not available"
    end
    local okE, errE = gs.setEnabled("ui_manager_ui", true, nil) -- persisted enabled=ON
    if okE ~= true then
        return false, tostring(errE or "setEnabled failed")
    end
    return true, nil
end

local function _setUiManagerUiVisibleSession(gs)
    if type(gs) ~= "table" or type(gs.setVisible) ~= "function" then
        return false, "guiSettings.setVisible not available"
    end
    local okV, errV = gs.setVisible("ui_manager_ui", true, { noSave = true })
    if okV ~= true then
        return false, tostring(errV or "setVisible failed")
    end
    return true, nil
end

local function _applyUiManagerUi(ctx)
    local okUM, UM = _safeRequire(ctx, "dwkit.ui.ui_manager")
    if okUM and type(UM.applyOne) == "function" then
        local okCall, resOk, errOrNil = pcall(UM.applyOne, "ui_manager_ui", { source = "dwui", quiet = true })
        if okCall and resOk ~= false then
            return true, nil
        end
        return false, tostring(errOrNil or "ui_manager.applyOne failed")
    end

    -- fallback: direct UI apply (relies on visible flag)
    local okUI, UI = _safeRequire(ctx, "dwkit.ui.ui_manager_ui")
    if okUI and type(UI.apply) == "function" then
        local okCall, resOk, errOrNil = pcall(UI.apply, { source = "dwui" })
        if okCall and resOk ~= false then
            return true, nil
        end
        return false, tostring(errOrNil or "ui_manager_ui.apply failed")
    end

    return false, "ui_manager/ui_manager_ui not available"
end

function M.dispatch(...)
    local a1, a2 = ...
    local ctx = nil
    local tokens = nil

    if type(a1) == "table" and _isArrayLike(a2) then
        ctx = a1
        tokens = a2
    elseif _isArrayLike(a1) then
        tokens = a1
    else
        -- tolerant no-op
        return false, "invalid args"
    end

    local sub = _parseTokens(tokens)
    if sub ~= "" and sub ~= "open" and sub ~= "show" then
        _out(ctx, "[DWKit UI] Usage: dwui  (or: dwui open)")
        return true, nil
    end

    local gs = _getGuiSettingsFromCtx(ctx)
    if type(gs) ~= "table" then
        -- fallback best-effort require
        local okGS, gs2 = pcall(require, "dwkit.config.gui_settings")
        if okGS and type(gs2) == "table" then
            gs = gs2
        end
    end
    if type(gs) ~= "table" then
        _err(ctx, "guiSettings not available")
        return false, "guiSettings not available"
    end

    -- ensure manager seeding runs (best-effort; does not overwrite)
    do
        local okUM, UM = _safeRequire(ctx, "dwkit.ui.ui_manager")
        if okUM and type(UM.seedRegisteredDefaults) == "function" then
            pcall(UM.seedRegisteredDefaults, { save = false })
        end
    end

    _ensureVisiblePersistenceSession(gs)

    local okEn, errEn = _ensureUiManagerUiEnabled(gs)
    if not okEn then
        _err(ctx, "enable ui_manager_ui failed: " .. tostring(errEn))
        return false, errEn
    end

    local okVis, errVis = _setUiManagerUiVisibleSession(gs)
    if not okVis then
        _err(ctx, "show ui_manager_ui failed: " .. tostring(errVis))
        return false, errVis
    end

    local okApply, errApply = _applyUiManagerUi(ctx)
    if not okApply then
        _err(ctx, "apply ui_manager_ui failed: " .. tostring(errApply))
        return false, errApply
    end

    _out(ctx, "[DWKit UI] ui_manager_ui shown (dwui)")
    return true, nil
end

return M
