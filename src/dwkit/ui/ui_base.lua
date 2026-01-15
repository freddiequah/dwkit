-- #########################################################################
-- Module Name : dwkit.ui.ui_base
-- Owner       : UI
-- Version     : v2026-01-15A
-- Purpose     :
--   - Shared SAFE helper utilities for DWKit UI modules.
--   - Avoids copy/paste across UI modules (store, widgets, show/hide/delete, etc).
--   - Provides best-effort access to guiSettings and Geyser.
--
-- Public API  :
--   - getModuleVersion() -> string
--   - out(line)
--   - getGuiSettingsBestEffort() -> table|nil
--   - getGeyser() -> table|nil
--   - getUiStore() -> table|nil
--   - safeHide(widget)
--   - safeShow(widget)
--   - safeDelete(widget)
--   - safeSetLabelText(label, text)
--   - ensureWidgets(uiId, requiredKeys, createFn) -> boolean ok, table|nil widgets, string|nil err
--   - clearUiStoreEntry(uiId)
--
-- SAFE Constraints:
--   - No gameplay commands
--   - No timers
--   - No automation
--   - No event emits/consumes
-- #########################################################################

local M = {}

M.VERSION = "v2026-01-15A"

local function _isNonEmptyString(s)
    return type(s) == "string" and s ~= ""
end

function M.getModuleVersion()
    return M.VERSION
end

function M.out(line)
    line = tostring(line or "")
    if type(cecho) == "function" then
        cecho(line .. "\n")
    elseif type(echo) == "function" then
        echo(line .. "\n")
    else
        print(line)
    end
end

function M.getGuiSettingsBestEffort()
    if type(_G.DWKit) == "table"
        and type(_G.DWKit.config) == "table"
        and type(_G.DWKit.config.guiSettings) == "table"
    then
        return _G.DWKit.config.guiSettings
    end

    local ok, mod = pcall(require, "dwkit.config.gui_settings")
    if ok and type(mod) == "table" then
        return mod
    end

    return nil
end

function M.getGeyser()
    local G = _G.Geyser
    if type(G) == "table" then return G end
    return nil
end

-- Global UI store to prevent duplicate windows across module reloads
function M.getUiStore()
    if type(_G.DWKit) ~= "table" then return nil end
    if type(_G.DWKit._uiStore) ~= "table" then
        _G.DWKit._uiStore = {}
    end
    return _G.DWKit._uiStore
end

function M.clearUiStoreEntry(uiId)
    if not _isNonEmptyString(uiId) then return end
    local store = M.getUiStore()
    if type(store) ~= "table" then return end
    store[uiId] = nil
end

function M.safeHide(w)
    if type(w) ~= "table" then return end
    if type(w.hide) == "function" then
        pcall(w.hide, w)
    end
end

function M.safeShow(w)
    if type(w) ~= "table" then return end
    if type(w.show) == "function" then
        pcall(w.show, w)
    end
end

function M.safeDelete(w)
    if type(w) ~= "table" then return end
    -- Geyser supports :delete() on many widgets
    if type(w.delete) == "function" then
        pcall(w.delete, w)
        return
    end
    -- fallback: hide only
    M.safeHide(w)
end

function M.safeSetLabelText(label, txt)
    if type(label) ~= "table" then return end
    if type(label.echo) == "function" then
        pcall(label.echo, label, tostring(txt or ""))
    end
end

local function _hasRequiredKeys(t, requiredKeys)
    if type(t) ~= "table" then return false end
    if type(requiredKeys) ~= "table" or #requiredKeys == 0 then
        return true
    end
    for _, k in ipairs(requiredKeys) do
        if t[k] == nil then
            return false
        end
    end
    return true
end

-- ensureWidgets
-- - Reuses widgets from global store if present and valid
-- - Otherwise creates new via createFn()
-- Returns: ok, widgets, err
function M.ensureWidgets(uiId, requiredKeys, createFn)
    if not _isNonEmptyString(uiId) then
        return false, nil, "uiId invalid"
    end
    if type(createFn) ~= "function" then
        return false, nil, "createFn invalid"
    end

    local store = M.getUiStore()
    if type(store) == "table" and type(store[uiId]) == "table" then
        local cached = store[uiId]
        if _hasRequiredKeys(cached, requiredKeys) then
            return true, cached, nil
        end
    end

    local okCreate, widgetsOrErr = pcall(createFn)
    if not okCreate or type(widgetsOrErr) ~= "table" then
        return false, nil, "createFn failed"
    end

    if not _hasRequiredKeys(widgetsOrErr, requiredKeys) then
        return false, nil, "createFn returned incomplete widgets"
    end

    if type(store) == "table" then
        store[uiId] = widgetsOrErr
    end

    return true, widgetsOrErr, nil
end

return M
