-- FILE: src/dwkit/services/roomentities_override_store.lua
-- #########################################################################
-- Module Name : dwkit.services.roomentities_override_store
-- Owner       : Services
-- Version     : v2026-02-10G
-- Purpose     :
--   - SAFE per-profile override persistence for RoomEntities Unknown tagging.
--   - No GMCP, no timers, no send(), no Mudlet events required.
--   - Stores overrides keyed by a normalized entity key (string).
--
-- Override types: mob | item | ignore
-- Stored per-profile under DWKit data folder using dwkit.persist.store envelope.
--
-- Public API:
--   - getVersion(), getAll(), get(), set(), clear(), clearAll()
--   - setType(), getType(), clearType() (compat)
--   - getDebugState(), forceReload() (debug)
--
-- Key Fix (v2026-02-10G):
--   - Align to actual dwkit.persist.store API:
--       saveEnvelope(relPath, schemaVersion, data, meta)
--       loadEnvelope(relPath)
--   - Payload is stored under env.data (NOT schemaVersion).
--   - Load parsing supports legacy/bad files (where payload ended up under schemaVersion.data).
--   - Load failures do NOT permanently freeze "empty"; retry with cooldown.
-- #########################################################################

local M = {}

M.VERSION = "v2026-02-10G"

local Store = require("dwkit.persist.store")

local RELPATH = "roomentities_overrides.tbl"

local _cache = {
    loaded = false,
    overrides = {},
    lastErr = nil,

    -- retry gate (prevents hammering during startup)
    nextRetryTs = 0,
    retryCooldownSec = 2,

    -- debug flags
    lastLoadOk = nil,
    lastSaveOk = nil,
}

local function _copyOneLevel(t)
    local out = {}
    if type(t) ~= "table" then return out end
    for k, v in pairs(t) do
        if type(v) == "table" then
            local inner = {}
            for kk, vv in pairs(v) do inner[kk] = vv end
            out[k] = inner
        else
            out[k] = v
        end
    end
    return out
end

local function _trim(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function _validType(t)
    t = tostring(t or "")
    return (t == "mob" or t == "item" or t == "ignore")
end

local function _now()
    return os.time()
end

local function _shouldRetryNow()
    local t = _now()
    return (t >= (tonumber(_cache.nextRetryTs) or 0))
end

local function _markRetryLater(errMsg)
    _cache.lastErr = tostring(errMsg or "load failed")
    _cache.loaded = false
    _cache.lastLoadOk = false
    _cache.nextRetryTs = _now() + (tonumber(_cache.retryCooldownSec) or 2)
end

-- -----------------------------
-- Load parsing helpers
-- -----------------------------

local function _extractOverridesFromEnvelope(env)
    if type(env) ~= "table" then return nil end

    -- Normal/correct shape: env.data.overrides
    if type(env.data) == "table" and type(env.data.overrides) == "table" then
        return env.data.overrides
    end

    -- Some callers may store directly: env.overrides
    if type(env.overrides) == "table" then
        return env.overrides
    end

    -- Legacy/double-wrap: env.data.data.overrides
    if type(env.data) == "table" and type(env.data.data) == "table" and type(env.data.data.overrides) == "table" then
        return env.data.data.overrides
    end

    -- Alternate naming: env.payload.overrides / env.payload.data.overrides
    if type(env.payload) == "table" then
        if type(env.payload.overrides) == "table" then
            return env.payload.overrides
        end
        if type(env.payload.data) == "table" and type(env.payload.data.overrides) == "table" then
            return env.payload.data.overrides
        end
    end

    -- IMPORTANT: support "bad file" created by earlier mismatch:
    -- payload ended up under env.schemaVersion.data.overrides
    if type(env.schemaVersion) == "table" and type(env.schemaVersion.data) == "table" then
        if type(env.schemaVersion.data.overrides) == "table" then
            return env.schemaVersion.data.overrides
        end
        if type(env.schemaVersion.data.data) == "table" and type(env.schemaVersion.data.data.overrides) == "table" then
            return env.schemaVersion.data.data.overrides
        end
    end

    return nil
end

-- -----------------------------
-- Load / Save
-- -----------------------------

local function _loadBestEffort()
    if _cache.loaded == true then
        return true, nil
    end

    if not _shouldRetryNow() then
        return true, nil
    end

    if type(Store) ~= "table" or type(Store.loadEnvelope) ~= "function" then
        _markRetryLater("persist store missing loadEnvelope()")
        return true, nil
    end

    local okCall, ok, env, err = pcall(Store.loadEnvelope, RELPATH)
    if not okCall then
        _markRetryLater(ok)
        return true, nil
    end

    -- Store.loadEnvelope returns (ok:boolean, env:table|nil, err:string|nil)
    if ok == true and type(env) == "table" then
        local ov = _extractOverridesFromEnvelope(env)
        if type(ov) == "table" then
            _cache.overrides = _copyOneLevel(ov)
        else
            _cache.overrides = {}
        end

        _cache.loaded = true
        _cache.lastErr = nil
        _cache.lastLoadOk = true
        _cache.nextRetryTs = 0
        return true, nil
    end

    -- If file not found, treat as empty but loaded (no need to retry)
    local errStr = tostring(err or "load failed")
    if errStr:lower():find("file not found", 1, true) then
        _cache.overrides = {}
        _cache.loaded = true
        _cache.lastErr = nil
        _cache.lastLoadOk = true
        _cache.nextRetryTs = 0
        return true, nil
    end

    -- Otherwise: retry later
    _cache.overrides = _cache.overrides or {}
    _markRetryLater(errStr)
    return true, nil
end

local function _saveBestEffort()
    if type(Store) ~= "table" or type(Store.saveEnvelope) ~= "function" then
        _cache.lastErr = "persist store missing saveEnvelope()"
        _cache.lastSaveOk = false
        return false, _cache.lastErr
    end

    local payload = {
        version = M.VERSION,
        updatedTs = _now(),
        overrides = _copyOneLevel(_cache.overrides),
    }

    -- Correct Store API:
    -- saveEnvelope(relPath, schemaVersion, data, meta)
    local okCall, ok, err = pcall(Store.saveEnvelope, RELPATH, M.VERSION, payload,
        { module = "roomentities_override_store" })
    if not okCall then
        _cache.lastErr = tostring(ok)
        _cache.lastSaveOk = false
        return false, _cache.lastErr
    end

    if ok == true then
        _cache.lastErr = nil
        _cache.lastSaveOk = true
        return true, nil
    end

    _cache.lastErr = tostring(err or "save failed")
    _cache.lastSaveOk = false
    return false, _cache.lastErr
end

-- -----------------------------
-- Debug helpers
-- -----------------------------

local function _bestEffortResolvedPath()
    if type(Store) ~= "table" then return nil end
    if type(Store.resolvePathBestEffort) == "function" then
        local ok, v = pcall(Store.resolvePathBestEffort, RELPATH)
        if ok and type(v) == "string" and v ~= "" then return v end
    end
    if type(Store.resolve) == "function" then
        local ok, ok2, fullPath = pcall(Store.resolve, RELPATH)
        if ok and ok2 == true and type(fullPath) == "string" and fullPath ~= "" then return fullPath end
    end
    return nil
end

local function _bestEffortBaseDir()
    if type(Store) ~= "table" then return nil end
    if type(Store.getBaseDirBestEffort) == "function" then
        local ok, v = pcall(Store.getBaseDirBestEffort)
        if ok and type(v) == "string" and v ~= "" then return v end
    end
    return nil
end

-- -----------------------------
-- Public API
-- -----------------------------

function M.getVersion()
    return tostring(M.VERSION)
end

function M.getDebugState()
    local n = 0
    if type(_cache.overrides) == "table" then
        for _ in pairs(_cache.overrides) do n = n + 1 end
    end

    return {
        version = M.VERSION,
        relpath = RELPATH,
        resolvedPath = _bestEffortResolvedPath(),
        baseDir = _bestEffortBaseDir(),
        loaded = (_cache.loaded == true),
        lastLoadOk = _cache.lastLoadOk,
        lastSaveOk = _cache.lastSaveOk,
        lastErr = _cache.lastErr,
        nextRetryTs = tonumber(_cache.nextRetryTs) or 0,
        retryCooldownSec = tonumber(_cache.retryCooldownSec) or 0,
        overrideCount = n,
        storeApi = {
            detected = true,
            loadFn = "loadEnvelope",
            saveFn = "saveEnvelope"
        }
    }
end

function M.forceReload()
    _cache.loaded = false
    _cache.nextRetryTs = 0
    return _loadBestEffort()
end

function M.getAll()
    _loadBestEffort()
    return _copyOneLevel(_cache.overrides)
end

function M.get(key)
    _loadBestEffort()
    key = _trim(key or "")
    if key == "" then return nil end
    local v = _cache.overrides[key]
    if type(v) == "table" then
        return _copyOneLevel(v)
    end
    return nil
end

function M.set(key, typeStr)
    _loadBestEffort()

    key = _trim(key or "")
    if key == "" then
        return false, "set(key,type): key must be non-empty"
    end

    typeStr = tostring(typeStr or "")
    if not _validType(typeStr) then
        return false, "set(key,type): type must be mob|item|ignore"
    end

    _cache.overrides[key] = { type = typeStr, ts = _now() }
    return _saveBestEffort()
end

function M.clear(key)
    _loadBestEffort()

    key = _trim(key or "")
    if key == "" then
        return false, "clear(key): key must be non-empty"
    end

    _cache.overrides[key] = nil
    return _saveBestEffort()
end

function M.clearAll()
    _loadBestEffort()
    _cache.overrides = {}
    return _saveBestEffort()
end

-- Compatibility wrappers
function M.setType(key, typeStr) return M.set(key, typeStr) end

function M.getType(key)
    local e = M.get(key)
    if type(e) == "table" and type(e.type) == "string" and e.type ~= "" then
        return e.type
    end
    return nil
end

function M.clearType(key) return M.clear(key) end

return M

-- END FILE: src/dwkit/services/roomentities_override_store.lua
