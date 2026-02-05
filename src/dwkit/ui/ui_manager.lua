-- #########################################################################
-- Module Name : dwkit.ui.ui_manager
-- Owner       : UI
-- Version     : v2026-02-05A
-- Purpose     :
--   - SAFE dispatcher for applying UI modules registered in gui_settings.
--   - Provides manual-only "apply all" and "apply one" capability.
--   - Best-effort require() of dwkit.ui.<uiId> with safe skipping when missing.
--   - Does NOT send gameplay commands.
--   - Does NOT start timers or automation.
--
--   - Dependency-safe lifecycle wiring (enabled-based, not visible-based):
--       * When a UI is enabled, claim required providers via ui_dependency_service.ensureUi().
--       * When a UI is disabled, release claims via ui_dependency_service.releaseUi().
--     NOTE: Provider lifecycle is tied to "enabled", not "visible".
--
-- Public API  :
--   - getModuleVersion() -> string
--   - getState(opts?) -> table (manager summary; compat)
--   - listUiIds(opts?) -> {string} (compat)
--   - applyAll(opts?) -> boolean ok, string|nil err
--   - applyOne(uiId, opts?) -> boolean ok, string|nil err
--   - disposeOne(uiId, opts?) -> boolean ok, string|nil err
--   - reloadOne(uiId, opts?) -> boolean ok, string|nil err
--   - reloadAll(opts?) -> boolean ok, string|nil err
--
--   - state(opts?) -> table|nil, string|nil err
--   - stateOne(uiId, opts?) -> table|nil, string|nil err
--   - printState(opts?) -> boolean ok, string|nil err
--   - printStateOne(uiId, opts?) -> boolean ok, string|nil err
--
--   - listAll(opts?) -> {uiId}|{records}
--   - listEnabled(opts?) -> {uiId}|{records}
--   - seedRegisteredDefaults(opts?) -> boolean ok, string|nil err
--
-- Notes:
--   - Gating:
--       * If gui_settings says enabled=false, applyOne MUST best-effort stand-down
--         (dispose/hide) if the UI is already instantiated/visible.
--       * UI module itself decides visible/show/hide behaviour when enabled=true.
-- #########################################################################

local M = {}

M.VERSION = "v2026-02-05A"

local function _rawOut(line)
    line = tostring(line or "")
    if type(cecho) == "function" then
        cecho(line .. "\n")
    elseif type(echo) == "function" then
        echo(line .. "\n")
    else
        print(line)
    end
end

local function _isQuiet(opts)
    return type(opts) == "table" and opts.quiet == true
end

local function _out(line, opts)
    if _isQuiet(opts) then return end
    _rawOut(line)
end

local function _err(msg, opts)
    -- errors should still print even when quiet
    _rawOut("[DWKit UI] ERROR: " .. tostring(msg))
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
    if type(gs.getVisible) == "function" then
        local okV, v = pcall(gs.getVisible, uiId, nil)
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

-- -------------------------------------------------------------------------
-- Dependency wiring (enabled-based)
-- -------------------------------------------------------------------------

-- Model A: enabled UI -> requires passive provider(s).
-- NOTE: Dependencies are tied to enabled, not visible.
local UI_PROVIDER_DEPS = {
    roomentities_ui = { "roomfeed_watch" },
}

local function _getProvidersForUi(uiId, uiMod)
    uiId = tostring(uiId or "")
    local list = UI_PROVIDER_DEPS[uiId]

    -- Optional UI module override/extension: getRequiredProviders() -> {string}
    if type(uiMod) == "table" and type(uiMod.getRequiredProviders) == "function" then
        local ok, v = pcall(uiMod.getRequiredProviders)
        if ok and type(v) == "table" then
            list = v
        end
    end

    if type(list) ~= "table" then
        return {}
    end
    return list
end

local function _getUiDepServiceBestEffort()
    local ok, dep = _safeRequire("dwkit.services.ui_dependency_service")
    if ok and type(dep) == "table"
        and type(dep.ensureUi) == "function"
        and type(dep.releaseUi) == "function"
    then
        return dep
    end
    return nil
end

local function _ensureDepsIfAny(uiId, uiMod, opts)
    local dep = _getUiDepServiceBestEffort()
    if type(dep) ~= "table" then
        return true, nil -- dependency service optional (safe skip)
    end

    local providers = _getProvidersForUi(uiId, uiMod)
    if type(providers) ~= "table" or #providers == 0 then
        return true, nil
    end

    local ok, err = dep.ensureUi(uiId, providers,
        { source = (opts and opts.source) or "ui_manager:deps:ensure", quiet = true })
    if not ok then
        return false, tostring(err)
    end
    return true, nil
end

local function _releaseDepsIfAny(uiId, opts)
    local dep = _getUiDepServiceBestEffort()
    if type(dep) ~= "table" then
        return true, nil -- dependency service optional (safe skip)
    end

    local ok, err = dep.releaseUi(uiId, { source = (opts and opts.source) or "ui_manager:deps:release", quiet = true })
    if not ok then
        return false, tostring(err)
    end
    return true, nil
end

-- -------------------------------------------------------------------------

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
        _out(path .. " = " .. _ppValue(t), opts)
        return
    end

    if visited[t] then
        _out(path .. " = <table:cycle>", opts)
        return
    end
    visited[t] = true

    if depth >= maxDepth then
        _out(path .. " = <table:maxDepth>", opts)
        return
    end

    local keys = _sortedKeys(t)
    for _, k in ipairs(keys) do
        if itemCounter.n >= maxItems then
            _out(path .. "  ... <maxItems reached>", opts)
            return
        end

        itemCounter.n = itemCounter.n + 1

        local v = t[k]
        local linePrefix = string.rep("  ", depth)
        local keyStr = tostring(k)

        if type(v) == "table" then
            _out(linePrefix .. keyStr .. " = {", opts)
            _ppTable(v, opts, depth + 1, keyStr, visited, itemCounter)
            _out(linePrefix .. "}", opts)
        else
            _out(linePrefix .. keyStr .. " = " .. _ppValue(v), opts)
        end
    end
end

function M.getModuleVersion()
    return M.VERSION
end

local function _standDownIfDisabled(uiId, opts)
    opts = (type(opts) == "table") and opts or {}
    local ok, err = M.disposeOne(uiId, { source = opts.source or "ui_manager:standdown", quiet = opts.quiet })
    if not ok then
        _err("standDown dispose failed uiId=" .. tostring(uiId) .. " err=" .. tostring(err), opts)
    end
    return true
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

    local enabled = _isEnabled(gs, uiId)

    -- If disabled: release deps (enabled-based), then stand down best-effort.
    if not enabled then
        _out("[DWKit UI] SKIP uiId=" .. tostring(uiId) .. " (disabled)", opts)

        local okRel, errRel = _releaseDepsIfAny(uiId, { source = opts.source or "ui_manager:disabled", quiet = true })
        if not okRel then
            _err("dependency release failed uiId=" .. tostring(uiId) .. " err=" .. tostring(errRel), opts)
        end

        _standDownIfDisabled(uiId, opts)
        return true, nil
    end

    -- Enabled: best-effort require module (may not exist yet).
    local modName = "dwkit.ui." .. tostring(uiId)
    local okR, modOrErr = _safeRequire(modName)
    local ui = (okR and type(modOrErr) == "table") and modOrErr or nil

    -- Ensure dependencies for enabled UI even if module isn't implemented yet.
    local okDep, errDep = _ensureDepsIfAny(uiId, ui, { source = opts.source or "ui_manager:applyOne", quiet = true })
    if not okDep then
        return false, "dependency ensure failed: " .. tostring(errDep)
    end

    if type(ui) ~= "table" then
        _out("[DWKit UI] SKIP uiId=" .. tostring(uiId) .. " (no module yet)", opts)
        return true, nil
    end

    if type(ui.init) == "function" then
        _callModuleBestEffort(ui, "init", opts)
    end

    if type(ui.apply) == "function" then
        local okApply, _, errApply = _callModuleBestEffort(ui, "apply", opts)
        if not okApply then
            return false, tostring(errApply)
        end
        return true, nil
    end

    _out("[DWKit UI] SKIP uiId=" .. tostring(uiId) .. " (no apply() function)", opts)
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

    _out("[DWKit UI] applyAll (dwgui apply)", opts)
    if #keys == 0 then
        _out("  (no registered UI)", opts)
        return true, nil
    end

    local attempted = 0
    local errors = 0

    for _, id in ipairs(keys) do
        attempted = attempted + 1
        local okOne, errOne = M.applyOne(id, opts)
        if not okOne then
            errors = errors + 1
            _err("applyOne failed uiId=" .. tostring(id) .. " err=" .. tostring(errOne), opts)
        end
    end

    _out("", opts)
    _out("[DWKit UI] applyAll summary", opts)
    _out("  total=" .. tostring(#keys), opts)
    _out("  attempted=" .. tostring(attempted), opts)
    _out("  errors=" .. tostring(errors), opts)
    _out("  note=SKIP lines are normal when modules not implemented", opts)

    return true, nil
end

function M.disposeOne(uiId, opts)
    opts = (type(opts) == "table") and opts or {}

    if type(uiId) ~= "string" or uiId == "" then
        return false, "uiId invalid"
    end

    -- NOTE: dispose does NOT change dependency refs here.
    -- Dependency lifecycle is tied to enabled/disabled (applyOne when disabled releases).
    local modName = "dwkit.ui." .. tostring(uiId)
    local okR, modOrErr = _safeRequire(modName)
    if not okR or type(modOrErr) ~= "table" then
        _out("[DWKit UI] dispose uiId=" .. tostring(uiId) .. " (no module yet)", opts)
        return true, nil
    end

    local ui = modOrErr

    if type(ui.dispose) == "function" then
        local okD, _, errD = _callModuleBestEffort(ui, "dispose", opts)
        if not okD then
            return false, tostring(errD)
        end
        _out("[DWKit UI] dispose uiId=" .. tostring(uiId) .. " ok=true", opts)
        return true, nil
    end

    _out("[DWKit UI] dispose uiId=" .. tostring(uiId) .. " (no dispose() function)", opts)
    return true, nil
end

function M.reloadOne(uiId, opts)
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
        _out("[DWKit UI] SKIP reload uiId=" .. tostring(uiId) .. " (disabled)", opts)
        return true, nil
    end

    _out("[DWKit UI] reload uiId=" .. tostring(uiId), opts)

    local okD, errD = M.disposeOne(uiId, opts)
    if not okD then
        return false, "dispose failed: " .. tostring(errD)
    end

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

    _out("[DWKit UI] reloadAll (dwgui reload)", opts)
    if #keys == 0 then
        _out("  (no registered UI)", opts)
        return true, nil
    end

    local enabledIds = {}
    for _, id in ipairs(keys) do
        if _isEnabled(gs, id) then
            enabledIds[#enabledIds + 1] = id
        end
    end

    if #enabledIds == 0 then
        _out("  (no enabled UI)", opts)
        return true, nil
    end

    local attempted = 0
    local okCount = 0
    local failed = 0

    for _, id in ipairs(enabledIds) do
        attempted = attempted + 1
        local okOne, errOne = M.reloadOne(id, opts)
        if okOne then
            okCount = okCount + 1
        else
            failed = failed + 1
            _err("reloadOne failed uiId=" .. tostring(id) .. " err=" .. tostring(errOne), opts)
        end
    end

    _out("[DWKit UI] reloadAll done enabledCount=" ..
        tostring(#enabledIds) ..
        " attempted=" .. tostring(attempted) ..
        " ok=" .. tostring(okCount) ..
        " failed=" .. tostring(failed), opts)

    return true, nil
end

-- -------------------------------------------------------------------------
-- State (programmatic, returns tables)
-- -------------------------------------------------------------------------

local function _getUiModuleStateBestEffort(ui)
    if type(ui) ~= "table" then return nil end
    if type(ui.getState) ~= "function" then return nil end
    local ok, st = pcall(ui.getState)
    if ok and type(st) == "table" then return st end
    return nil
end

function M.stateOne(uiId, opts)
    opts = (type(opts) == "table") and opts or {}

    if type(uiId) ~= "string" or uiId == "" then
        return nil, "uiId invalid"
    end

    local gs = _getGuiSettingsBestEffort()
    if type(gs) ~= "table" then
        return nil, "DWKit.config.guiSettings not available"
    end

    local okLoad, loadErr = _ensureLoaded(gs)
    if not okLoad then
        return nil, tostring(loadErr)
    end

    local enabled = _isEnabled(gs, uiId)
    local visible = _isVisibleBestEffort(gs, uiId)

    local modName = "dwkit.ui." .. tostring(uiId)
    local okR, modOrErr = _safeRequire(modName)
    local ui = (okR and type(modOrErr) == "table") and modOrErr or nil

    local uiState = _getUiModuleStateBestEffort(ui)

    local requiredProviders = nil
    if type(ui) == "table" then
        requiredProviders = _getProvidersForUi(uiId, ui)
    else
        requiredProviders = _getProvidersForUi(uiId, nil)
    end

    local rec = {
        uiId = uiId,
        moduleVersion = M.VERSION,
        enabled = (enabled == true),
        visible = visible, -- may be nil if gui_settings doesn't track it
        module = modName,
        hasModule = (type(ui) == "table"),
        hasInit = (type(ui) == "table" and type(ui.init) == "function") or false,
        hasApply = (type(ui) == "table" and type(ui.apply) == "function") or false,
        hasDispose = (type(ui) == "table" and type(ui.dispose) == "function") or false,
        hasGetState = (type(ui) == "table" and type(ui.getState) == "function") or false,
        hasGetRequiredProviders = (type(ui) == "table" and type(ui.getRequiredProviders) == "function") or false,
        requiredProviders = requiredProviders,
        uiState = uiState, -- best-effort, may be nil
    }

    -- Optional pretty-print when not quiet (keeps your existing UX)
    if not _isQuiet(opts) then
        _out("[DWKit UI] state uiId=" .. tostring(uiId), opts)
        _out("  moduleVersion=" .. tostring(M.VERSION), opts)
        _out("  enabled=" .. tostring(rec.enabled), opts)
        if visible ~= nil then
            _out("  visible=" .. tostring(visible), opts)
        end
        _out("  module=" .. tostring(modName), opts)
        if not rec.hasModule then
            _out("  note=no module yet", opts)
        else
            _out("  hasInit=" .. tostring(rec.hasInit), opts)
            _out("  hasApply=" .. tostring(rec.hasApply), opts)
            _out("  hasDispose=" .. tostring(rec.hasDispose), opts)
            _out("  hasGetState=" .. tostring(rec.hasGetState), opts)
            _out("  hasGetRequiredProviders=" .. tostring(rec.hasGetRequiredProviders), opts)
        end
        if type(uiState) == "table" then
            _out("{", opts)
            _ppTable(uiState, { maxDepth = opts.maxDepth or 4, maxItems = opts.maxItems or 80, quiet = opts.quiet }, 0,
                "", nil, nil)
            _out("}", opts)
        end
    end

    return rec, nil
end

function M.state(opts)
    opts = (type(opts) == "table") and opts or {}

    local gs = _getGuiSettingsBestEffort()
    if type(gs) ~= "table" then
        return nil, "DWKit.config.guiSettings not available"
    end

    local okLoad, loadErr = _ensureLoaded(gs)
    if not okLoad then
        return nil, tostring(loadErr)
    end

    local records = M.listAll({ records = true })
    local uis = {}
    for _, rec in ipairs(records) do
        -- enrich with requiredProviders + module state best-effort
        local one, _ = M.stateOne(rec.uiId, { quiet = true })
        if type(one) == "table" then
            uis[rec.uiId] = one
        else
            uis[rec.uiId] = {
                uiId = rec.uiId,
                moduleVersion = M.VERSION,
                enabled = rec.enabled,
                visible = rec.visible,
            }
        end
    end

    local depState = nil
    local dep = _getUiDepServiceBestEffort()
    if type(dep) == "table" and type(dep.getState) == "function" then
        local ok, st = pcall(dep.getState)
        if ok and type(st) == "table" then
            depState = st
        end
    end

    local st = {
        moduleVersion = M.VERSION,
        uiCount = #records,
        uis = uis,
        dependencyState = depState,
    }

    if not _isQuiet(opts) then
        _out("[DWKit UI] state (manager)", opts)
        _out("  moduleVersion=" .. tostring(M.VERSION), opts)
        _out("  uiCount=" .. tostring(st.uiCount), opts)
        if type(depState) == "table" and type(depState.refs) == "table" then
            local refsKeys = _sortedKeys(depState.refs)
            _out("  dep.refs:", opts)
            for _, k in ipairs(refsKeys) do
                _out("   - " .. tostring(k) .. "=" .. tostring(depState.refs[k]), opts)
            end
        end
    end

    return st, nil
end

-- Print-only helpers (return boolean ok, err)
function M.printStateOne(uiId, opts)
    local st, err = M.stateOne(uiId, opts)
    if not st then return false, err end
    return true, nil
end

function M.printState(opts)
    local st, err = M.state(opts)
    if not st then return false, err end
    return true, nil
end

-- Backwards-compat aliases:
-- - previously state()/stateOne() were print-oriented and returned boolean
-- - now: state()/stateOne() return tables; printState*/printStateOne* are print-only
-- Keep old exported names but with correct semantics already above.
-- -------------------------------------------------------------------------

-- Defaults for registered UI ids (seed only; does not overwrite existing records)
M.KNOWN_UI_DEFAULTS = {
    presence_ui = { enabled = true, visible = true },
    roomentities_ui = { enabled = true, visible = true },
    launchpad_ui = { enabled = true, visible = false },
    ui_manager_ui = { enabled = true, visible = false }, -- UI Manager UI (enable/disable surface)
}

function M.seedRegisteredDefaults(opts)
    opts = (type(opts) == "table") and opts or {}
    local gs = _getGuiSettingsBestEffort()
    if type(gs) ~= "table" then
        return false, "DWKit.config.guiSettings not available"
    end

    local okLoad, loadErr = _ensureLoaded(gs)
    if not okLoad then
        return false, tostring(loadErr)
    end

    if type(gs.register) ~= "function" then
        return true, nil
    end

    local keys = _sortedKeys(M.KNOWN_UI_DEFAULTS)
    for _, uiId in ipairs(keys) do
        local def = M.KNOWN_UI_DEFAULTS[uiId] or { enabled = false, visible = false }
        pcall(gs.register, uiId, { enabled = def.enabled, visible = def.visible }, { save = (opts.save == true) })
    end

    return true, nil
end

function M.listAll(opts)
    opts = (type(opts) == "table") and opts or {}

    local gs = _getGuiSettingsBestEffort()
    if type(gs) ~= "table" then return {} end
    local okLoad = _ensureLoaded(gs)
    if not okLoad then return {} end

    local okL, uiMap = pcall(gs.list)
    if not okL or type(uiMap) ~= "table" then return {} end

    local keys = _sortedKeys(uiMap)
    local out = {}

    for _, uiId in ipairs(keys) do
        if opts.records == true then
            out[#out + 1] = {
                uiId = uiId,
                enabled = _isEnabled(gs, uiId),
                visible = _isVisibleBestEffort(gs, uiId),
            }
        else
            out[#out + 1] = uiId
        end
    end

    return out
end

local function _looksLikeUiId(s)
    if type(s) ~= "string" then return false end
    -- simple, permissive heuristic: letters/numbers/_ and ends with "_ui"
    return s:match("^[%w_]+_ui$") ~= nil
end

local function _normalizeExcludeSet(opts)
    opts = (type(opts) == "table") and opts or {}

    local exclude = {}

    -- excludeUiIds can be:
    -- 1) array: {"launchpad_ui","presence_ui"}
    -- 2) map: { launchpad_ui=true, presence_ui=true }
    if type(opts.excludeUiIds) == "table" then
        local isArray = (#opts.excludeUiIds > 0)
        if isArray then
            for _, v in ipairs(opts.excludeUiIds) do
                if type(v) == "string" and v ~= "" then exclude[v] = true end
            end
        else
            for k, v in pairs(opts.excludeUiIds) do
                if v == true and type(k) == "string" and k ~= "" then exclude[k] = true end
            end
        end
    end

    -- includeSelf=false means "exclude the caller ui id" (generic)
    if opts.includeSelf == false then
        local selfUiId = opts.selfUiId or opts.selfUi or opts.uiId or opts.callerUiId
        if (type(selfUiId) ~= "string" or selfUiId == "") and _looksLikeUiId(opts.source) then
            -- generic inference: if source looks like a ui id, treat it as self
            selfUiId = opts.source
        end
        if type(selfUiId) == "string" and selfUiId ~= "" then
            exclude[selfUiId] = true
        end
    end

    return exclude
end

function M.listEnabled(opts)
    opts = (type(opts) == "table") and opts or {}

    local ids = M.listAll({ records = true })
    local exclude = _normalizeExcludeSet(opts)

    local out = {}
    for _, rec in ipairs(ids) do
        if rec.enabled == true and exclude[rec.uiId] ~= true then
            if opts.records == true then
                out[#out + 1] = rec
            else
                out[#out + 1] = rec.uiId
            end
        end
    end

    return out
end

-- -------------------------------------------------------------------------
-- Compat helpers (your Mudlet calls expected these names)
-- -------------------------------------------------------------------------

function M.listUiIds(opts)
    return M.listAll(opts)
end

function M.getState(opts)
    opts = (type(opts) == "table") and opts or {}
    local gs = _getGuiSettingsBestEffort()

    local gsStatus = nil
    if type(gs) == "table" and type(gs.status) == "function" then
        local ok, v = pcall(gs.status)
        if ok and type(v) == "table" then
            gsStatus = v
        end
    end

    local depState = nil
    local dep = _getUiDepServiceBestEffort()
    if type(dep) == "table" and type(dep.getState) == "function" then
        local ok, st = pcall(dep.getState)
        if ok and type(st) == "table" then
            depState = st
        end
    end

    local records = M.listAll({ records = true })

    -- Build uis map (what your debugging expected as st.uis)
    local uis = {}
    for _, rec in ipairs(records) do
        uis[rec.uiId] = {
            uiId = rec.uiId,
            enabled = rec.enabled,
            visible = rec.visible,
        }
    end

    return {
        moduleVersion = M.VERSION,
        uiCount = #records,
        uis = uis,    -- ✅ map keyed by uiId
        ui = records, -- keep old field for any existing consumers
        guiSettingsStatus = gsStatus,
        dependencyState = depState,
        note = "ui_manager is a dispatcher; dwkit.ui.ui_manager_ui is the UI surface",
    }
end

return M
