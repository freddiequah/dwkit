-- FILE: src/dwkit/ui/ui_manager.lua
-- #########################################################################
-- Module Name : dwkit.ui.ui_manager
-- Owner       : UI
-- Version     : v2026-02-09B
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
-- Key Fixes:
--   v2026-02-07C:
--     - Dispatcher now enforces deterministic runtime-visible signal (ui_base storeEntry.state.visible)
--       after successful applyOne stand-up when cfgVisible is ON.
--       This fixes cases where UI modules reuse existing widgets and show() a container without
--       updating storeEntry.state.visible back to true (rtState drift).
--   v2026-02-09A:
--     - Extend enforcement BOTH ways:
--         * cfgVisible=true  => rt state.visible MUST be true after apply()
--         * cfgVisible=false => rt state.visible MUST be false after apply()
--       This fixes modules that hide widgets without updating storeEntry.state.visible back to false.
--   v2026-02-09B:
--     - Cross-surface sync: UI Manager changes now best-effort refresh LaunchPad after applyOne/applyAll.
--       This ensures LaunchPad list + shown-state reflects enable/disable/show/hide actions done in
--       UI Manager UI (and any other callers of ui_manager.applyOne/applyAll).
-- #########################################################################

local M = {}

M.VERSION = "v2026-02-09B"

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

-- IMPORTANT: gui_settings.isVisible/getVisible often take a default value param.
-- Passing nil can yield nil even when a value exists in defaults/records.
-- Use a default that returns a stable boolean if a record is missing.
local function _isVisibleBestEffort(gs, uiId)
    if type(gs) ~= "table" then return nil end

    if type(gs.isVisible) == "function" then
        local okV, v = pcall(gs.isVisible, uiId, true)
        if okV then return v end
    end
    if type(gs.getVisible) == "function" then
        local okV, v = pcall(gs.getVisible, uiId, true)
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
-- Deterministic runtime-visible signal (ui_base storeEntry.state.visible)
-- -------------------------------------------------------------------------

local function _setRuntimeVisibleBestEffort(uiId, visible, source)
    uiId = tostring(uiId or "")
    if uiId == "" then return false end

    local okU, U = pcall(require, "dwkit.ui.ui_base")
    if not okU or type(U) ~= "table" then
        return false
    end

    -- Preferred: dedicated helper
    if type(U.setUiStateVisibleBestEffort) == "function" then
        pcall(function()
            U.setUiStateVisibleBestEffort(uiId, (visible == true))
        end)
        return true
    end

    -- Fallback: setUiRuntime state merge
    if type(U.setUiRuntime) == "function" then
        pcall(function()
            U.setUiRuntime(uiId, {
                state = { visible = (visible == true) },
                meta = { uiId = uiId, source = tostring(source or "ui_manager:runtime") },
            })
        end)
        return true
    end

    return false
end

-- -------------------------------------------------------------------------
-- Cross-surface sync (LaunchPad refresh best-effort)
-- -------------------------------------------------------------------------

local function _sourceLooksLikeLaunchpadSync(opts)
    if type(opts) ~= "table" then return false end
    local s = tostring(opts.source or "")
    if s == "" then return false end
    return (s:find("ui_manager:sync_launchpad", 1, true) ~= nil)
end

local function _refreshLaunchpadBestEffort(changedUiId, opts)
    changedUiId = tostring(changedUiId or "")
    if changedUiId == "" then return false end

    -- Guard: don't self-refresh when applying LaunchPad itself
    if changedUiId == "launchpad_ui" then
        return false
    end

    -- Guard: prevent simple sync loops
    if _sourceLooksLikeLaunchpadSync(opts) then
        return false
    end

    local okL, L = pcall(require, "dwkit.ui.launchpad_ui")
    if not okL or type(L) ~= "table" then
        return false
    end

    -- Prefer refresh() if present, else apply()
    if type(L.refresh) == "function" then
        pcall(L.refresh, { source = "ui_manager:sync_launchpad", quiet = true })
        return true
    end
    if type(L.apply) == "function" then
        pcall(L.apply, { source = "ui_manager:sync_launchpad", quiet = true })
        return true
    end

    return false
end

-- -------------------------------------------------------------------------
-- Dependency wiring (enabled-based)
-- -------------------------------------------------------------------------

local UI_PROVIDER_DEPS = {
    roomentities_ui = { "roomfeed_watch" },
}

local function _getProvidersForUi(uiId, uiMod)
    uiId = tostring(uiId or "")
    local list = UI_PROVIDER_DEPS[uiId]

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
        return true, nil
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
        return true, nil
    end

    local ok, err = dep.releaseUi(uiId, { source = (opts and opts.source) or "ui_manager:deps:release", quiet = true })
    if not ok then
        return false, tostring(err)
    end
    return true, nil
end

-- -------------------------------------------------------------------------

function M.getModuleVersion()
    return M.VERSION
end

-- Safe helper: session-only visible sync.
-- Does NOT call apply/dispose; intended for UI chrome interactions.
function M.syncVisibleSession(uiId, visible, opts)
    opts = (type(opts) == "table") and opts or {}
    uiId = tostring(uiId or "")
    if uiId == "" then return false, "uiId invalid" end

    local gs = _getGuiSettingsBestEffort()
    if type(gs) ~= "table" then
        return false, "DWKit.config.guiSettings not available"
    end

    local okLoad, loadErr = _ensureLoaded(gs)
    if not okLoad then
        return false, tostring(loadErr)
    end

    if type(gs.enableVisiblePersistence) == "function" then
        pcall(gs.enableVisiblePersistence, { noSave = true })
    end
    if type(gs.setVisible) == "function" then
        pcall(gs.setVisible, uiId, (visible == true), { noSave = true })
    end

    return true, nil
end

local function _standDownIfDisabled(uiId, opts)
    opts = (type(opts) == "table") and opts or {}

    -- deterministic runtime signal: disabled implies not running/visible
    _setRuntimeVisibleBestEffort(uiId, false, "ui_manager:standDownIfDisabled")

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
    local cfgVisible = _isVisibleBestEffort(gs, uiId)

    if not enabled then
        _out("[DWKit UI] SKIP uiId=" .. tostring(uiId) .. " (disabled)", opts)

        local okRel, errRel = _releaseDepsIfAny(uiId, { source = opts.source or "ui_manager:disabled", quiet = true })
        if not okRel then
            _err("dependency release failed uiId=" .. tostring(uiId) .. " err=" .. tostring(errRel), opts)
        end

        _standDownIfDisabled(uiId, opts)

        -- v2026-02-09B: refresh LaunchPad after dispatcher change
        _refreshLaunchpadBestEffort(uiId, opts)

        return true, nil
    end

    local modName = "dwkit.ui." .. tostring(uiId)
    local okR, modOrErr = _safeRequire(modName)
    local ui = (okR and type(modOrErr) == "table") and modOrErr or nil

    local okDep, errDep = _ensureDepsIfAny(uiId, ui, { source = opts.source or "ui_manager:applyOne", quiet = true })
    if not okDep then
        return false, "dependency ensure failed: " .. tostring(errDep)
    end

    if type(ui) ~= "table" then
        _out("[DWKit UI] SKIP uiId=" .. tostring(uiId) .. " (no module yet)", opts)

        -- v2026-02-09B: refresh LaunchPad after dispatcher change (even if module missing)
        _refreshLaunchpadBestEffort(uiId, opts)

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

        -- v2026-02-09A:
        -- Enforce deterministic runtime-visible signal to match cfgVisible when cfgVisible is a real boolean.
        -- This fixes modules that show/hide containers without updating ui_base storeEntry.state.visible.
        if cfgVisible == true then
            _setRuntimeVisibleBestEffort(uiId, true, "ui_manager:post_apply:cfgVisibleOn")
        elseif cfgVisible == false then
            _setRuntimeVisibleBestEffort(uiId, false, "ui_manager:post_apply:cfgVisibleOff")
        end

        -- v2026-02-09B: refresh LaunchPad after dispatcher change
        _refreshLaunchpadBestEffort(uiId, opts)

        return true, nil
    end

    _out("[DWKit UI] SKIP uiId=" .. tostring(uiId) .. " (no apply() function)", opts)

    -- v2026-02-09B: refresh LaunchPad after dispatcher change
    _refreshLaunchpadBestEffort(uiId, opts)

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

    -- v2026-02-09B: refresh LaunchPad once after applyAll (covers bulk changes)
    _refreshLaunchpadBestEffort("applyAll", opts)

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

    local modName = "dwkit.ui." .. tostring(uiId)
    local okR, modOrErr = _safeRequire(modName)
    if not okR or type(modOrErr) ~= "table" then
        _out("[DWKit UI] dispose uiId=" .. tostring(uiId) .. " (no module yet)", opts)
        -- deterministic runtime signal: disposed implies not visible
        _setRuntimeVisibleBestEffort(uiId, false, "ui_manager:dispose:no_module")
        return true, nil
    end

    local ui = modOrErr

    if type(ui.dispose) == "function" then
        local okD, _, errD = _callModuleBestEffort(ui, "dispose", opts)
        if not okD then
            return false, tostring(errD)
        end
        -- deterministic runtime signal: disposed implies not visible
        _setRuntimeVisibleBestEffort(uiId, false, "ui_manager:dispose:ok")
        _out("[DWKit UI] dispose uiId=" .. tostring(uiId) .. " ok=true", opts)
        return true, nil
    end

    _out("[DWKit UI] dispose uiId=" .. tostring(uiId) .. " (no dispose() function)", opts)
    -- best-effort: even without dispose(), consider it stood down from dispatcher POV
    _setRuntimeVisibleBestEffort(uiId, false, "ui_manager:dispose:no_fn")
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
        visible = visible,
        module = modName,
        hasModule = (type(ui) == "table"),
        hasInit = (type(ui) == "table" and type(ui.init) == "function") or false,
        hasApply = (type(ui) == "table" and type(ui.apply) == "function") or false,
        hasDispose = (type(ui) == "table" and type(ui.dispose) == "function") or false,
        hasGetState = (type(ui) == "table" and type(ui.getState) == "function") or false,
        hasGetRequiredProviders = (type(ui) == "table" and type(ui.getRequiredProviders) == "function") or false,
        requiredProviders = requiredProviders,
        uiState = uiState,
    }

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

    return {
        moduleVersion = M.VERSION,
        uiCount = #records,
        uis = uis,
        dependencyState = depState,
    }, nil
end

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

M.KNOWN_UI_DEFAULTS = {
    presence_ui = { enabled = true, visible = true },
    roomentities_ui = { enabled = true, visible = true },
    launchpad_ui = { enabled = true, visible = false },
    ui_manager_ui = { enabled = true, visible = false },
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
    return s:match("^[%w_]+_ui$") ~= nil
end

local function _normalizeExcludeSet(opts)
    opts = (type(opts) == "table") and opts or {}

    local exclude = {}

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

    if opts.includeSelf == false then
        local selfUiId = opts.selfUiId or opts.selfUi or opts.uiId or opts.callerUiId
        if (type(selfUiId) ~= "string" or selfUiId == "") and _looksLikeUiId(opts.source) then
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
        uis = uis,
        ui = records,
        guiSettingsStatus = gsStatus,
        dependencyState = depState,
        note = "ui_manager is a dispatcher; dwkit.ui.ui_manager_ui is the UI surface",
    }
end

return M
