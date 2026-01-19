-- #########################################################################
-- Module Name : dwkit.ui.ui_manager
-- Owner       : UI
-- Version     : v2026-01-19A
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
--   - disposeOne(uiId, opts?) -> boolean ok, string|nil err
--   - reloadOne(uiId, opts?) -> boolean ok, string|nil err
--   - reloadAll(opts?) -> boolean ok, string|nil err
--   - stateOne(uiId, opts?) -> boolean ok, string|nil err     (SAFE state snapshot)
--
-- Notes:
--   - Gating:
--       * Skips uiId when gui_settings says enabled=false
--       * UI module itself decides visible/show/hide behaviour
--   - UI module contract (best-effort):
--       * init(opts?) optional
--       * apply(opts?) optional but recommended
--       * dispose(opts?) optional but recommended
--       * getState() optional (recommended for diagnostics)
-- #########################################################################

local M = {}

M.VERSION = "v2026-01-19A"

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

-- Robust module method call WITHOUT double side-effects.
-- Tries dot-call first: fn(...)
-- Only if that fails, tries colon-call: fn(self, ...)
-- Returns: ok, result, err
local function _callModuleBestEffort(mod, fnName, ...)
    if type(mod) ~= "table" then
        return false, nil, "module not table"
    end
    local fn = mod[fnName]
    if type(fn) ~= "function" then
        return false, nil, "missing function: " .. tostring(fnName)
    end

    local ok1, res1 = pcall(fn, ...)
    if ok1 then
        return true, res1, nil
    end

    local ok2, res2 = pcall(fn, mod, ...)
    if ok2 then
        return true, res2, nil
    end

    return false, nil, "call failed: " .. tostring(res1)
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

local function _isEnabled(gs, uiId)
    local enabled = true
    if type(gs.isEnabled) == "function" then
        local okE, v = pcall(gs.isEnabled, uiId, true)
        if okE then enabled = (v == true) end
    end
    return enabled
end

local function _isVisibleBestEffort(gs, uiId)
    if type(gs) ~= "table" then return nil end
    if type(gs.isVisible) == "function" then
        local okV, v = pcall(gs.isVisible, uiId, nil)
        if okV then return v end
    end
    return nil
end

local function _clearModuleCache(modName)
    if type(modName) ~= "string" or modName == "" then
        return false, "module name invalid"
    end
    if type(package) ~= "table" or type(package.loaded) ~= "table" then
        return false, "package.loaded not available"
    end
    package.loaded[modName] = nil
    return true, nil
end

-- Simple SAFE pretty printer (bounded) for state snapshots.
-- No colors, no fancy formatting, and bounded depth/items to avoid spam.
local function _ppValue(v)
    local tv = type(v)
    if tv == "string" then
        return string.format("%q", v)
    elseif tv == "number" or tv == "boolean" or tv == "nil" then
        return tostring(v)
    elseif tv == "function" then
        return "<function>"
    elseif tv == "userdata" then
        return "<userdata>"
    elseif tv == "thread" then
        return "<thread>"
    elseif tv == "table" then
        return "<table>"
    end
    return "<" .. tv .. ">"
end

local function _ppTable(t, opts, depth, path, visited, itemCounter)
    opts = (type(opts) == "table") and opts or {}
    depth = depth or 0
    path = path or ""
    visited = visited or {}
    itemCounter = itemCounter or { n = 0 }

    local maxDepth = tonumber(opts.maxDepth or 4) or 4
    local maxItems = tonumber(opts.maxItems or 80) or 80

    if type(t) ~= "table" then
        _out(path .. " = " .. _ppValue(t))
        return
    end

    if visited[t] then
        _out(path .. " = <table:cycle>")
        return
    end
    visited[t] = true

    if depth >= maxDepth then
        _out(path .. " = <table:maxDepth>")
        return
    end

    local keys = _sortedKeys(t)
    for _, k in ipairs(keys) do
        if itemCounter.n >= maxItems then
            _out(path .. "  ... <maxItems reached>")
            return
        end

        itemCounter.n = itemCounter.n + 1

        local v = t[k]
        local linePrefix = string.rep("  ", depth)
        local keyStr = tostring(k)
        local nextPath = (path == "") and keyStr or (path .. "." .. keyStr)

        if type(v) == "table" then
            _out(linePrefix .. keyStr .. " = {")
            _ppTable(v, opts, depth + 1, nextPath, visited, itemCounter)
            _out(linePrefix .. "}")
        else
            _out(linePrefix .. keyStr .. " = " .. _ppValue(v))
        end
    end
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

    if not _isEnabled(gs, uiId) then
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
        -- IMPORTANT: do NOT call init twice; only retry with colon-style if needed.
        _callModuleBestEffort(ui, "init", opts)
    end

    if type(ui.apply) == "function" then
        local okApply, _, errApply = _callModuleBestEffort(ui, "apply", opts)
        if not okApply then
            return false, tostring(errApply)
        end
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

function M.disposeOne(uiId, opts)
    opts = (type(opts) == "table") and opts or {}

    if type(uiId) ~= "string" or uiId == "" then
        return false, "uiId invalid"
    end

    local modName = "dwkit.ui." .. tostring(uiId)
    local okR, modOrErr = _safeRequire(modName)
    if not okR or type(modOrErr) ~= "table" then
        _out("[DWKit UI] dispose uiId=" .. tostring(uiId) .. " (no module yet)")
        return true, nil
    end

    local ui = modOrErr

    if type(ui.dispose) == "function" then
        local okD, _, errD = _callModuleBestEffort(ui, "dispose", opts)
        if not okD then
            return false, tostring(errD)
        end
        _out("[DWKit UI] dispose uiId=" .. tostring(uiId) .. " ok=true")
        return true, nil
    end

    _out("[DWKit UI] dispose uiId=" .. tostring(uiId) .. " (no dispose() function)")
    return true, nil
end

function M.reloadOne(uiId, opts)
    opts = (type(opts) == "table") and opts or {}

    if type(uiId) ~= "string" or uiId == "" then
        return false, "uiId invalid"
    end

    -- GATING: reload should also skip disabled UI (do not dispose/clear cache/apply)
    local gs = _getGuiSettingsBestEffort()
    if type(gs) ~= "table" then
        return false, "DWKit.config.guiSettings not available"
    end

    local okLoad, loadErr = _ensureLoaded(gs)
    if not okLoad then
        return false, tostring(loadErr)
    end

    if not _isEnabled(gs, uiId) then
        _out("[DWKit UI] SKIP reload uiId=" .. tostring(uiId) .. " (disabled)")
        return true, nil
    end

    _out("[DWKit UI] reload uiId=" .. tostring(uiId))

    local okD, errD = M.disposeOne(uiId, opts)
    if not okD then
        return false, "dispose failed: " .. tostring(errD)
    end

    -- IMPORTANT: true reload must clear require() cache
    local modName = "dwkit.ui." .. tostring(uiId)
    local okClr, errClr = _clearModuleCache(modName)
    if not okClr then
        return false, "reload cache clear failed: " .. tostring(errClr)
    end

    local okA, errA = M.applyOne(uiId, opts)
    if not okA then
        return false, "apply failed: " .. tostring(errA)
    end

    return true, nil
end

-- NEW: reloadAll (enabled UI only)
function M.reloadAll(opts)
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

    _out("[DWKit UI] reloadAll (dwgui reload)")
    if #keys == 0 then
        _out("  (no registered UI)")
        return true, nil
    end

    local enabledIds = {}
    for _, uiId in ipairs(keys) do
        if _isEnabled(gs, uiId) then
            enabledIds[#enabledIds + 1] = uiId
        end
    end

    if #enabledIds == 0 then
        _out("  (no enabled UI)")
        return true, nil
    end

    local attempted = 0
    local okCount = 0
    local failed = 0

    for _, uiId in ipairs(enabledIds) do
        attempted = attempted + 1
        local okOne, errOne = M.reloadOne(uiId, opts)
        if okOne then
            okCount = okCount + 1
        else
            failed = failed + 1
            _err("reloadOne failed uiId=" .. tostring(uiId) .. " err=" .. tostring(errOne))
        end
    end

    _out("[DWKit UI] reloadAll done enabledCount=" ..
        tostring(#enabledIds) ..
        " attempted=" .. tostring(attempted) ..
        " ok=" .. tostring(okCount) ..
        " failed=" .. tostring(failed))

    return true, nil
end

-- NEW: stateOne (SAFE diagnostics)
-- Best-effort:
--  - shows enabled/visible flags (if gui_settings supports isVisible)
--  - calls ui.getState() if present
--  - prints bounded table snapshot
function M.stateOne(uiId, opts)
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

    local enabled = _isEnabled(gs, uiId)
    local visible = _isVisibleBestEffort(gs, uiId)

    _out("[DWKit UI] state uiId=" .. tostring(uiId))
    _out("  moduleVersion=" .. tostring(M.VERSION))
    _out("  enabled=" .. tostring(enabled))
    if visible ~= nil then
        _out("  visible=" .. tostring(visible))
    end

    local modName = "dwkit.ui." .. tostring(uiId)
    local okR, modOrErr = _safeRequire(modName)
    if not okR or type(modOrErr) ~= "table" then
        _out("  module=" .. tostring(modName))
        _out("  note=no module yet")
        return true, nil
    end

    local ui = modOrErr
    _out("  module=" .. tostring(modName))
    _out("  hasInit=" .. tostring(type(ui.init) == "function"))
    _out("  hasApply=" .. tostring(type(ui.apply) == "function"))
    _out("  hasDispose=" .. tostring(type(ui.dispose) == "function"))
    _out("  hasGetState=" .. tostring(type(ui.getState) == "function"))

    if type(ui.getState) ~= "function" then
        _out("  note=getState() not implemented by UI module")
        return true, nil
    end

    local okS, stateOrErr = pcall(ui.getState)
    if not okS then
        _err("ui.getState failed err=" .. tostring(stateOrErr))
        return false, tostring(stateOrErr)
    end

    if type(stateOrErr) ~= "table" then
        _out("  getState() returned non-table: " .. _ppValue(stateOrErr))
        return true, nil
    end

    _out("{")
    _ppTable(stateOrErr, { maxDepth = opts.maxDepth or 4, maxItems = opts.maxItems or 80 })
    _out("}")

    return true, nil
end

-- Compatibility shims (in case dwgui handler expects other names)
function M.printState(uiId, opts)
    return M.stateOne(uiId, opts)
end

function M.state(uiId, opts)
    return M.stateOne(uiId, opts)
end

return M
