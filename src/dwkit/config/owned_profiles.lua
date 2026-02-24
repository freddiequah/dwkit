-- FILE: src/dwkit/config/owned_profiles.lua
-- #########################################################################
-- Module Name : dwkit.config.owned_profiles
-- Owner       : Config
-- Version     : v2026-02-24A
-- Purpose     :
--   - Deterministic mapping of "my profiles" for Presence_UI classification.
--   - Stores an explicit mapping: characterName -> profileLabel (Mudlet profile tab name).
--   - SAFE: no events, no automation, no gameplay commands.
--
-- Public API  :
--   - getModuleVersion() -> string
--   - getSchemaVersion() -> string
--   - getDefaultRelPath() -> string
--   - load(opts?) -> boolean ok, string|nil err
--   - save(opts?) -> boolean ok, string|nil err
--   - isLoaded() -> boolean
--   - getMap() -> table copy (characterName -> profileLabel)
--   - setMap(map, opts?) -> boolean ok, string|nil err
--   - set(characterName, profileLabel, opts?) -> boolean ok, string|nil err
--   - clear(opts?) -> boolean ok, string|nil err
--   - status() -> table copy
--
-- Persistence      :
--   - Uses dwkit.persist.store envelope at relPath:
--       default: "config/owned_profiles.tbl"
--     SchemaVersion:
--       "v0.1"
--
-- Notes:
--   - This module is the authoritative source for "my profiles" classification.
--   - No guessing is allowed. If mapping is empty/missing, PresenceService must
--     treat all room players as "Other players" and surface a hint.
-- #########################################################################

-- -------------------------------------------------------------------------
-- Singleton guard: if a canonical instance exists, always return it.
-- -------------------------------------------------------------------------
do
    local DW = (type(_G.DWKit) == "table") and _G.DWKit or nil
    local cfg = (DW and type(DW.config) == "table") and DW.config or nil
    local existing = (cfg and type(cfg.ownedProfiles) == "table") and cfg.ownedProfiles or nil
    if type(existing) == "table"
        and type(existing.getModuleVersion) == "function"
        and type(existing.load) == "function"
        and type(existing.getMap) == "function"
        and type(existing.set) == "function"
    then
        return existing
    end
end

local M = {}

M.VERSION = "v2026-02-24A"
M.SCHEMA_VERSION = "v0.1"

local ID = require("dwkit.core.identity")

local DEFAULT_REL_PATH = "config/owned_profiles.tbl"

local _state = {
    loaded = false,
    relPath = DEFAULT_REL_PATH,
    schemaVersion = M.SCHEMA_VERSION,
    map = {}, -- characterName -> profileLabel
    lastLoadAt = nil,
    lastSaveAt = nil,
    lastError = nil,
}

local function _optsTable(opts)
    return (type(opts) == "table") and opts or {}
end

local function _isNonEmptyString(s)
    return type(s) == "string" and s ~= ""
end

local function _trim(s)
    s = tostring(s or "")
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function _copyMap(t)
    local out = {}
    if type(t) ~= "table" then return out end
    for k, v in pairs(t) do
        if type(k) == "string" and k ~= "" and type(v) == "string" and v ~= "" then
            out[k] = v
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
    opts = _optsTable(opts)
    if _isNonEmptyString(opts.relPath) then
        return tostring(opts.relPath)
    end
    return _state.relPath or DEFAULT_REL_PATH
end

function M.getModuleVersion() return M.VERSION end

function M.getSchemaVersion() return M.SCHEMA_VERSION end

function M.getDefaultRelPath() return DEFAULT_REL_PATH end

function M.isLoaded() return (_state.loaded == true) end

function M.load(opts)
    opts = _optsTable(opts)
    local relPath = _resolveRelPath(opts)

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

    _state.loaded = true
    _state.relPath = relPath
    _state.lastLoadAt = os.time()
    _state.lastError = nil

    if okFlag ~= true then
        _state.map = {}
        return true, nil
    end

    local env = envOrNil
    local data = (type(env) == "table") and env.data or nil
    if type(data) == "table" and type(data.map) == "table" then
        _state.map = _copyMap(data.map)
    else
        _state.map = {}
    end

    return true, nil
end

function M.save(opts)
    opts = _optsTable(opts)
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
    local data = { map = _copyMap(_state.map) }
    local meta = {
        source = "dwkit.config.owned_profiles",
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

function M.getMap()
    if _state.loaded ~= true then
        pcall(M.load, { quiet = true })
    end
    return _copyMap(_state.map)
end

function M.setMap(map, opts)
    opts = _optsTable(opts)
    if type(map) ~= "table" then
        return false, "setMap(map): map must be a table"
    end

    if _state.loaded ~= true then
        local okLoad, err = M.load({ quiet = true })
        if not okLoad then
            return false, "load failed: " .. tostring(err)
        end
    end

    _state.map = _copyMap(map)

    if opts.noSave == true then
        return true, nil
    end
    return M.save(opts)
end

function M.set(characterName, profileLabel, opts)
    opts = _optsTable(opts)

    characterName = _trim(characterName)
    profileLabel = _trim(profileLabel)

    if characterName == "" then
        return false, "set(characterName, profileLabel): characterName invalid"
    end
    if profileLabel == "" then
        return false, "set(characterName, profileLabel): profileLabel invalid"
    end

    if _state.loaded ~= true then
        local okLoad, err = M.load({ quiet = true })
        if not okLoad then
            return false, "load failed: " .. tostring(err)
        end
    end

    _state.map[characterName] = profileLabel

    if opts.noSave == true then
        return true, nil
    end
    return M.save(opts)
end

function M.clear(opts)
    opts = _optsTable(opts)

    if _state.loaded ~= true then
        local okLoad, err = M.load({ quiet = true })
        if not okLoad then
            return false, "load failed: " .. tostring(err)
        end
    end

    _state.map = {}

    if opts.noSave == true then
        return true, nil
    end
    return M.save(opts)
end

function M.status()
    local n = 0
    if type(_state.map) == "table" then
        for _ in pairs(_state.map) do n = n + 1 end
    end

    return {
        moduleVersion = M.VERSION,
        schemaVersion = M.SCHEMA_VERSION,
        loaded = (_state.loaded == true),
        relPath = tostring(_state.relPath or DEFAULT_REL_PATH),
        count = n,
        lastLoadAt = _state.lastLoadAt,
        lastSaveAt = _state.lastSaveAt,
        lastError = _state.lastError,
    }
end

-- -------------------------------------------------------------------------
-- Publish canonical singleton reference
-- -------------------------------------------------------------------------
do
    _G.DWKit = (type(_G.DWKit) == "table") and _G.DWKit or {}
    _G.DWKit.config = (type(_G.DWKit.config) == "table") and _G.DWKit.config or {}
    _G.DWKit.config.ownedProfiles = M
end

return M

-- END FILE: src/dwkit/config/owned_profiles.lua
