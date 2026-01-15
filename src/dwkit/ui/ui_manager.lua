-- #########################################################################
-- Module Name : dwkit.ui.ui_manager
-- Owner       : UI
-- Version     : v2026-01-15B
-- Purpose     :
--   - SAFE dispatcher for applying UI modules registered in gui_settings.
--   - Provides manual-only "apply all" and "apply one" capability.
--   - Best-effort require() of dwkit.ui.<uiId> with safe skipping when missing.
--   - Does NOT send gameplay commands.
--   - Does NOT start timers or automation.
--
-- Public API  :
--   - getModuleVersion() -> string
--   - applyAll(opts?) -> boolean ok, string|nil err
--   - applyOne(uiId, opts?) -> boolean ok, string|nil err
--
-- Notes:
--   - Gating:
--       * Skips uiId when gui_settings says enabled=false
--       * UI module itself decides visible/show/hide behaviour
--   - UI module contract (best-effort):
--       * init(opts?) optional
--       * apply(opts?) optional but recommended
-- #########################################################################

local M = {}

M.VERSION = "v2026-01-15B"

local function _out(line)
    line = tostring(line or "")
    if type(cecho) == "function" then
        cecho(line .. "\n")
    elseif type(echo) == "function" then
        echo(line .. "\n")
    else
        print(line)
    end
end

local function _err(msg)
    _out("[DWKit UI] ERROR: " .. tostring(msg))
end

local function _sortedKeys(t)
    local keys = {}
    if type(t) ~= "table" then return keys end
    for k, _ in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    return keys
end

local function _safeRequire(modName)
    local ok, mod = pcall(require, modName)
    if ok then return true, mod end
    return false, mod
end

-- robust caller: tries fn(obj, ...) then fn(...)
local function _callBestEffort(obj, fnName, ...)
    if type(obj) ~= "table" then
        return false, nil, "obj not table"
    end
    local fn = obj[fnName]
    if type(fn) ~= "function" then
        return false, nil, "missing function: " .. tostring(fnName)
    end

    local ok1, a1 = pcall(fn, obj, ...)
    if ok1 then return true, a1, nil end

    local ok2, a2 = pcall(fn, ...)
    if ok2 then return true, a2, nil end

    return false, nil, "call failed"
end

local function _getGuiSettingsBestEffort()
    if type(_G.DWKit) == "table"
        and type(_G.DWKit.config) == "table"
        and type(_G.DWKit.config.guiSettings) == "table"
    then
        return _G.DWKit.config.guiSettings
    end

    local ok, mod = _safeRequire("dwkit.config.gui_settings")
    if ok and type(mod) == "table" then return mod end
    return nil
end

local function _ensureLoaded(gs)
    if type(gs) ~= "table" then
        return false, "guiSettings missing"
    end

    local alreadyLoaded = false
    if type(gs.isLoaded) == "function" then
        local okLoaded, v = pcall(gs.isLoaded)
        alreadyLoaded = (okLoaded and v == true)
    end

    if (not alreadyLoaded) and type(gs.load) == "function" then
        pcall(gs.load, { quiet = true })
    end

    return true, nil
end

function M.getModuleVersion()
    return M.VERSION
end

function M.applyOne(uiId, opts)
    opts = (type(opts) == "table") and opts or {}

    if type(uiId) ~= "string" or uiId == "" then
        return false, "uiId invalid"
    end

    local gs = _getGuiSettingsBestEffort()
    if type(gs) ~= "table" then
        return false, "DWKit.config.guiSettings not available"
    end

    local okLoad, loadErr = _ensureLoaded(gs)
    if not okLoad then
        return false, tostring(loadErr)
    end

    local enabled = true
    if type(gs.isEnabled) == "function" then
        local okE, v = pcall(gs.isEnabled, uiId, true)
        if okE then enabled = (v == true) end
    end

    if not enabled then
        _out("[DWKit UI] SKIP uiId=" .. tostring(uiId) .. " (disabled)")
        return true, nil
    end

    local modName = "dwkit.ui." .. tostring(uiId)
    local okR, modOrErr = _safeRequire(modName)
    if not okR or type(modOrErr) ~= "table" then
        _out("[DWKit UI] SKIP uiId=" .. tostring(uiId) .. " (no module yet)")
        return true, nil
    end

    local ui = modOrErr

    if type(ui.init) == "function" then
        pcall(ui.init, opts)
        -- best-effort also try init(self, opts) if module uses colon style
        pcall(ui.init, ui, opts)
    end

    if type(ui.apply) == "function" then
        pcall(ui.apply, opts)
        -- best-effort also try apply(self, opts)
        pcall(ui.apply, ui, opts)
        return true, nil
    end

    _out("[DWKit UI] SKIP uiId=" .. tostring(uiId) .. " (no apply() function)")
    return true, nil
end

function M.applyAll(opts)
    opts = (type(opts) == "table") and opts or {}

    local gs = _getGuiSettingsBestEffort()
    if type(gs) ~= "table" then
        return false, "DWKit.config.guiSettings not available"
    end

    local okLoad, loadErr = _ensureLoaded(gs)
    if not okLoad then
        return false, tostring(loadErr)
    end

    local okL, uiMap = pcall(gs.list)
    if not okL or type(uiMap) ~= "table" then
        return false, "guiSettings.list failed"
    end

    local keys = _sortedKeys(uiMap)

    _out("[DWKit UI] applyAll (dwgui apply)")
    if #keys == 0 then
        _out("  (no registered UI)")
        return true, nil
    end

    local attempted = 0
    local errors = 0

    for _, uiId in ipairs(keys) do
        attempted = attempted + 1
        local okOne, errOne = M.applyOne(uiId, opts)
        if not okOne then
            errors = errors + 1
            _err("applyOne failed uiId=" .. tostring(uiId) .. " err=" .. tostring(errOne))
        end
    end

    _out("")
    _out("[DWKit UI] applyAll summary")
    _out("  total=" .. tostring(#keys))
    _out("  attempted=" .. tostring(attempted))
    _out("  errors=" .. tostring(errors))
    _out("  note=SKIP lines are normal when modules not implemented")

    return true, nil
end

return M
