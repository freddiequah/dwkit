-- #########################################################################
-- Module Name : dwkit.config.gui_settings
-- Owner       : Config
-- Version     : v2026-02-03D
-- Purpose     :
--   - Provide per-profile GUI settings storage for DWKit UI modules.
--   - Owns "enabled" (mandatory) and "visible" (optional) flags per UI id.
--   - SAFE module: no events, no automation, no gameplay commands.
--   - Read-only load by default; writes only when save()/set*()/enableVisiblePersistence() is called.
--   - Supports UI module seeding via register() (SAFE; in-memory only unless opts.save=true).
--
-- Public API  :
--   - getModuleVersion() -> string
--   - getSchemaVersion() -> string
--   - getDefaultRelPath() -> string
--   - load(opts?) -> boolean ok, string|nil err
--   - save(opts?) -> boolean ok, string|nil err
--   - isLoaded() -> boolean
--   - register(uiId, defaults?, opts?) -> boolean ok, string|nil err
--   - isEnabled(uiId, default?) -> boolean
--   - setEnabled(uiId, enabled, opts?) -> boolean ok, string|nil err
--   - getVisible(uiId, default?) -> boolean
--   - setVisible(uiId, visible, opts?) -> boolean ok, string|nil err
--   - enableVisiblePersistence(opts?) -> boolean ok, string|nil err
--   - list() -> table (copy) of uiId -> {enabled=?, visible=?}
--   - status() -> table (copy) summary
--   - selfTestPersistenceSmoke(opts?) -> boolean ok, string|nil err
--
-- Persistence      :
--   - Uses dwkit.persist.store envelope at relPath:
--       default: "config/gui_settings.tbl"
--     SchemaVersion:
--       "v0.1"
--
-- IMPORTANT SEMANTICS (session):
--   - If enableVisiblePersistence({noSave=true}) is called, visible persistence and any in-memory
--     per-ui visible flags must remain effective for this Mudlet session even if some code calls load() again.
--
-- IMPORTANT SEMANTICS (visible defaults):
--   - When visible persistence is enabled, "visible" should behave as a boolean at read/list time:
--       * if a record has explicit visible=true/false, use it
--       * if a record has visible=nil (unset), return options.visibleDefault (default false)
--     This avoids "third state" nil surprises (e.g., disable expects visible=OFF).
-- #########################################################################

local M = {}

M.VERSION = "v2026-02-03D"
M.SCHEMA_VERSION = "v0.1"

local ID = require("dwkit.core.identity")

local DEFAULT_REL_PATH = "config/gui_settings.tbl"

local _state = {
    loaded = false,
    relPath = DEFAULT_REL_PATH,
    schemaVersion = M.SCHEMA_VERSION,

    -- Sticky runtime flag: once enableVisiblePersistence() is invoked, load() must keep it ON for session.
    sessionVisiblePersistenceEnabled = false,

    data = {
        ui = {}, -- uiId -> { enabled=bool, visible=bool|nil }
        options = {
            visiblePersistenceEnabled = false,
            enabledDefault = false,
            visibleDefault = false,
        },
    },
    lastLoadAt = nil,
    lastSaveAt = nil,
    lastError = nil,
}

local function _isNonEmptyString(s) return type(s) == "string" and s ~= "" end

local function _copyTableShallow(t)
    if type(t) ~= "table" then return {} end
    local out = {}
    for k, v in pairs(t) do out[k] = v end
    return out
end

local function _deepCopyUi(ui)
    local out = {}
    if type(ui) ~= "table" then return out end
    for uiId, rec in pairs(ui) do
        if type(uiId) == "string" and type(rec) == "table" then
            out[uiId] = {
                enabled = (rec.enabled == true),
                visible = (rec.visible == true) and true or ((rec.visible == false) and false or nil),
            }
        end
    end
    return out
end

local function _getStoreBestEffort()
    local DW = (type(_G.DWKit) == "table") and _G.DWKit or nil
    local s = (DW and type(DW.persist) == "table") and DW.persist.store or nil
    if type(s) == "table"
        and type(s.saveEnvelope) == "function"
        and type(s.loadEnvelope) == "function"
        and type(s.delete) == "function"
    then
        return true, s, nil
    end

    local ok, modOrErr = pcall(require, "dwkit.persist.store")
    if ok and type(modOrErr) == "table"
        and type(modOrErr.saveEnvelope) == "function"
        and type(modOrErr.loadEnvelope) == "function"
        and type(modOrErr.delete) == "function"
    then
        return true, modOrErr, nil
    end

    return false, nil, "persist store not available"
end

local function _resolveRelPath(opts)
    opts = opts or {}
    if type(opts) == "table" and _isNonEmptyString(opts.relPath) then
        return tostring(opts.relPath)
    end
    return _state.relPath or DEFAULT_REL_PATH
end

local function _truthy(x) return x == true end

local function _normalizeLoadedData(envData, forceVisiblePersistence)
    local out = {
        ui = {},
        options = {
            visiblePersistenceEnabled = false,
            enabledDefault = false,
            visibleDefault = false,
        },
    }

    local force = _truthy(forceVisiblePersistence)

    if type(envData) ~= "table" then
        if force then
            out.options.visiblePersistenceEnabled = true
        end
        return out
    end

    if type(envData.options) == "table" then
        if envData.options.visiblePersistenceEnabled == true then
            out.options.visiblePersistenceEnabled = true
        end
        if envData.options.enabledDefault == true then
            out.options.enabledDefault = true
        end
        if envData.options.visibleDefault == true then
            out.options.visibleDefault = true
        end
    end

    if force then
        out.options.visiblePersistenceEnabled = true
    end

    if type(envData.ui) == "table" then
        for uiId, rec in pairs(envData.ui) do
            if type(uiId) == "string" and type(rec) == "table" then
                local enabled = (rec.enabled == true)

                local visible = nil
                if out.options.visiblePersistenceEnabled then
                    if rec.visible == true then visible = true end
                    if rec.visible == false then visible = false end
                end

                out.ui[uiId] = { enabled = enabled, visible = visible }
            end
        end
    end

    return out
end

local function _ensureStructures()
    if type(_state.data) ~= "table" then
        _state.data = _normalizeLoadedData(nil, false)
    end
    if type(_state.data.ui) ~= "table" then _state.data.ui = {} end
    if type(_state.data.options) ~= "table" then
        _state.data.options = {
            visiblePersistenceEnabled = false,
            enabledDefault = false,
            visibleDefault = false,
        }
    end
end

local function _ensureRec(uiId)
    _ensureStructures()

    local rec = _state.data.ui[uiId]
    if type(rec) ~= "table" then
        rec = { enabled = false, visible = nil }
        _state.data.ui[uiId] = rec
    end
    return rec
end

local function _getVisiblePersistenceEnabledNow()
    if type(_state.data) == "table"
        and type(_state.data.options) == "table"
        and _state.data.options.visiblePersistenceEnabled == true
    then
        return true
    end
    return false
end

local function _mergeSessionVisible(oldData, newData, forceVisible)
    if not forceVisible then return end
    if type(oldData) ~= "table" or type(newData) ~= "table" then return end
    if type(oldData.ui) ~= "table" or type(newData.ui) ~= "table" then return end

    -- Preserve per-ui visible flags that existed in-memory (noSave) if newly loaded rec has nil visible.
    for uiId, oldRec in pairs(oldData.ui) do
        if type(uiId) == "string" and type(oldRec) == "table" then
            local newRec = newData.ui[uiId]
            if type(newRec) == "table" then
                if newRec.visible == nil and (oldRec.visible == true or oldRec.visible == false) then
                    newRec.visible = oldRec.visible
                end
            end
        end
    end
end

function M.getModuleVersion() return M.VERSION end

function M.getSchemaVersion() return M.SCHEMA_VERSION end

function M.getDefaultRelPath() return DEFAULT_REL_PATH end

function M.isLoaded() return _state.loaded == true end

function M.load(opts)
    opts = opts or {}
    local relPath = _resolveRelPath(opts)

    -- Force visible persistence if:
    -- 1) caller explicitly asks, OR
    -- 2) session flag already enabled, OR
    -- 3) current in-memory options already has it enabled
    local forceVisible = (
        (type(opts) == "table" and opts.visiblePersistenceEnabled == true) or
        (_state.sessionVisiblePersistenceEnabled == true) or
        (_getVisiblePersistenceEnabledNow() == true)
    ) and true or false

    -- Keep a copy of previous in-memory state to preserve noSave visible flags across reloads.
    local oldData = _state.data

    local okStore, store, storeErr = _getStoreBestEffort()
    if not okStore then
        _state.lastError = tostring(storeErr)
        return false, _state.lastError
    end

    local okP, okFlag, envOrNil, errMaybe = pcall(store.loadEnvelope, relPath)
    if not okP then
        _state.lastError = tostring(okFlag)
        return false, _state.lastError
    end

    if okFlag ~= true then
        _state.loaded = true
        _state.relPath = relPath
        _state.data = _normalizeLoadedData(nil, forceVisible)
        _mergeSessionVisible(oldData, _state.data, forceVisible)
        _state.lastLoadAt = os.time()
        _state.lastError = nil
        return true, nil
    end

    local env = envOrNil
    local envData = (type(env) == "table") and env.data or nil

    _state.loaded = true
    _state.relPath = relPath
    _state.data = _normalizeLoadedData(envData, forceVisible)
    _mergeSessionVisible(oldData, _state.data, forceVisible)
    _state.lastLoadAt = os.time()
    _state.lastError = nil

    return true, nil
end

function M.save(opts)
    opts = opts or {}
    local relPath = _resolveRelPath(opts)

    local okStore, store, storeErr = _getStoreBestEffort()
    if not okStore then
        _state.lastError = tostring(storeErr)
        return false, _state.lastError
    end

    if _state.loaded ~= true then
        local okLoad, loadErr = M.load({ relPath = relPath, quiet = true })
        if not okLoad then
            return false, tostring(loadErr)
        end
    end

    local schema = M.SCHEMA_VERSION
    local data = _normalizeLoadedData(_state.data, false)
    local meta = {
        source = "dwkit.config.gui_settings",
        identity = {
            packageId = tostring(ID.packageId or "dwkit"),
            eventPrefix = tostring(ID.eventPrefix or "DWKit:"),
            dataFolderName = tostring(ID.dataFolderName or "dwkit"),
        },
    }

    local okP, okFlag, valueOrErr, errMaybe = pcall(store.saveEnvelope, relPath, schema, data, meta)
    if not okP then
        _state.lastError = tostring(okFlag)
        return false, _state.lastError
    end

    if okFlag == true then
        _state.lastSaveAt = os.time()
        _state.lastError = nil
        return true, nil
    end

    _state.lastError = tostring(errMaybe or valueOrErr or "saveEnvelope failed")
    return false, _state.lastError
end

function M.register(uiId, defaults, opts)
    if type(uiId) ~= "string" or uiId == "" then
        return false, "uiId invalid"
    end

    defaults = (type(defaults) == "table") and defaults or {}
    opts = (type(opts) == "table") and opts or {}

    if _state.loaded ~= true then
        local okLoad, err = M.load({ quiet = true })
        if not okLoad then
            return false, "load failed: " .. tostring(err)
        end
    end

    _ensureStructures()

    local existed = (type(_state.data.ui[uiId]) == "table")
    if existed then
        return true, nil
    end

    local rec = _ensureRec(uiId)

    local en = defaults.enabled
    if en == nil then
        en = (_state.data.options and _state.data.options.enabledDefault == true) or false
    end
    rec.enabled = (en == true)

    if _state.data.options and _state.data.options.visiblePersistenceEnabled == true then
        local vis = defaults.visible
        if vis == nil then
            vis = (_state.data.options.visibleDefault == true)
        end
        rec.visible = (vis == true)
    else
        rec.visible = nil
    end

    if opts.save == true then
        return M.save(opts)
    end

    return true, nil
end

function M.isEnabled(uiId, default)
    if type(uiId) ~= "string" or uiId == "" then
        if default ~= nil then return (default == true) end
        return false
    end

    if type(_state.data) == "table" and type(_state.data.ui) == "table" then
        local rec = _state.data.ui[uiId]
        if type(rec) == "table" and rec.enabled ~= nil then
            return (rec.enabled == true)
        end
    end

    if default ~= nil then
        return (default == true)
    end

    if type(_state.data) == "table"
        and type(_state.data.options) == "table"
        and _state.data.options.enabledDefault ~= nil
    then
        return (_state.data.options.enabledDefault == true)
    end

    return false
end

function M.setEnabled(uiId, enabled, opts)
    if type(uiId) ~= "string" or uiId == "" then
        return false, "uiId invalid"
    end

    if _state.loaded ~= true then
        local okLoad, err = M.load({ quiet = true })
        if not okLoad then
            return false, "load failed: " .. tostring(err)
        end
    end

    local rec = _ensureRec(uiId)
    rec.enabled = (enabled == true)

    if opts and opts.noSave == true then
        return true, nil
    end

    return M.save(opts)
end

function M.getVisible(uiId, default)
    if type(uiId) ~= "string" or uiId == "" then
        return (default == true)
    end

    if type(_state.data) == "table" and type(_state.data.options) == "table" then
        if _state.data.options.visiblePersistenceEnabled == true then
            local rec = (type(_state.data.ui) == "table") and _state.data.ui[uiId] or nil
            if type(rec) == "table" then
                if rec.visible ~= nil then
                    return (rec.visible == true)
                end
                -- Visible persistence ON but value unset: return visibleDefault.
                return (_state.data.options.visibleDefault == true)
            end
            -- No record: return visibleDefault when persistence ON.
            return (_state.data.options.visibleDefault == true)
        end
    end

    return (default == true)
end

function M.enableVisiblePersistence(opts)
    opts = opts or {}

    -- Sticky for runtime session even if opts.noSave=true.
    _state.sessionVisiblePersistenceEnabled = true

    if _state.loaded ~= true then
        local okLoad, err = M.load({ quiet = true, visiblePersistenceEnabled = true })
        if not okLoad then
            return false, "load failed: " .. tostring(err)
        end
    end

    _ensureStructures()
    _state.data.options.visiblePersistenceEnabled = true

    if opts.noSave == true then
        return true, nil
    end

    return M.save(opts)
end

function M.setVisible(uiId, visible, opts)
    if type(uiId) ~= "string" or uiId == "" then
        return false, "uiId invalid"
    end

    if _state.loaded ~= true then
        local okLoad, err = M.load({ quiet = true })
        if not okLoad then
            return false, "load failed: " .. tostring(err)
        end
    end

    if type(_state.data) ~= "table" or type(_state.data.options) ~= "table"
        or _state.data.options.visiblePersistenceEnabled ~= true
    then
        return false, "visible persistence is disabled (options.visiblePersistenceEnabled=false)"
    end

    local rec = _ensureRec(uiId)
    rec.visible = (visible == true)

    if opts and opts.noSave == true then
        return true, nil
    end

    return M.save(opts)
end

function M.list()
    if type(_state.data) ~= "table" or type(_state.data.ui) ~= "table" then
        return {}
    end

    local opts = (type(_state.data.options) == "table") and _state.data.options or {}
    local visOn = (opts.visiblePersistenceEnabled == true)
    local visDefault = (opts.visibleDefault == true)

    local out = {}
    for uiId, rec in pairs(_state.data.ui) do
        if type(uiId) == "string" and type(rec) == "table" then
            local v = nil
            if visOn then
                -- When persistence is ON, list() must always show an explicit boolean.
                if rec.visible == true then
                    v = true
                elseif rec.visible == false then
                    v = false
                else
                    v = visDefault
                end
            else
                v = nil
            end

            out[uiId] = {
                enabled = (rec.enabled == true),
                visible = v,
            }
        end
    end

    return out
end

function M.status()
    local uiCount = 0
    if type(_state.data) == "table" and type(_state.data.ui) == "table" then
        for _ in pairs(_state.data.ui) do uiCount = uiCount + 1 end
    end

    return {
        moduleVersion = M.VERSION,
        schemaVersion = M.SCHEMA_VERSION,
        loaded = (_state.loaded == true),
        relPath = tostring(_state.relPath or DEFAULT_REL_PATH),
        uiCount = uiCount,
        options = (type(_state.data) == "table" and type(_state.data.options) == "table") and
            _copyTableShallow(_state.data.options) or {},
        sessionVisiblePersistenceEnabled = (_state.sessionVisiblePersistenceEnabled == true),
        lastLoadAt = _state.lastLoadAt,
        lastSaveAt = _state.lastSaveAt,
        lastError = _state.lastError,
    }
end

function M.selfTestPersistenceSmoke(opts)
    opts = opts or {}
    local relPath = _isNonEmptyString(opts.relPath) and tostring(opts.relPath) or "selftest/gui_settings_smoke.tbl"

    local okStore, store, storeErr = _getStoreBestEffort()
    if not okStore then
        return false, tostring(storeErr)
    end

    pcall(store.delete, relPath)

    local schema = M.SCHEMA_VERSION
    local data = {
        ui = {
            ["_selftest_dummy_ui"] = { enabled = true, visible = nil },
        },
        options = {
            visiblePersistenceEnabled = false,
            enabledDefault = false,
            visibleDefault = false,
        },
    }
    local meta = { source = "dwkit.config.gui_settings.selfTestPersistenceSmoke" }

    local okP, okFlag, valueOrErr, errMaybe = pcall(store.saveEnvelope, relPath, schema, data, meta)
    if not okP then
        return false, "saveEnvelope pcall error: " .. tostring(okFlag)
    end
    if okFlag ~= true then
        return false, "saveEnvelope failed: " .. tostring(errMaybe or valueOrErr)
    end

    local okP2, okFlag2, envOrNil, errMaybe2 = pcall(store.loadEnvelope, relPath)
    if not okP2 then
        return false, "loadEnvelope pcall error: " .. tostring(okFlag2)
    end
    if okFlag2 ~= true or type(envOrNil) ~= "table" or type(envOrNil.data) ~= "table" then
        return false, "loadEnvelope failed: " .. tostring(errMaybe2 or envOrNil)
    end

    local d = envOrNil.data
    local rec = (type(d.ui) == "table") and d.ui["_selftest_dummy_ui"] or nil
    local pass = (type(rec) == "table" and rec.enabled == true)
    if not pass then
        pcall(store.delete, relPath)
        return false, "roundtrip mismatch"
    end

    pcall(store.delete, relPath)
    return true, nil
end

return M
