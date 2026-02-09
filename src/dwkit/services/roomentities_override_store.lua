-- FILE: src/dwkit/services/roomentities_override_store.lua
-- #########################################################################
-- Module Name : dwkit.services.roomentities_override_store
-- Owner       : Services
-- Version     : v2026-02-09B
-- Purpose     :
--   - SAFE per-profile override persistence for RoomEntities Unknown tagging.
--   - No GMCP, no timers, no send(), no Mudlet events required.
--   - Stores overrides keyed by a normalized entity key (string).
--
-- Policy (RoomEntities Capture & Unknown Tagging Agreement):
--   - Unknown-first: non-players are Unknown until user tags.
--   - User overrides are canonical authority for non-players.
--   - Override types: mob | item | ignore
--   - Per-profile: stored inside DWKit data folder (Mudlet profile-local).
--
-- Public API:
--   - getVersion() -> string
--   - getAll() -> table (copy) of overrides: { [key] = { type="mob|item|ignore", ts=number } }
--   - get(key) -> table|nil
--   - set(key, typeStr) -> boolean ok, string|nil err
--   - clear(key) -> boolean ok, string|nil err
--   - clearAll() -> boolean ok, string|nil err
--
-- Compatibility helpers (older UI callers):
--   - setType(key, typeStr) -> boolean ok, string|nil err
--   - getType(key) -> string|nil
--   - clearType(key) -> boolean ok, string|nil err
-- #########################################################################

local M = {}

M.VERSION = "v2026-02-09B"

local Store = require("dwkit.persist.store")

local RELPATH = "roomentities_overrides.tbl"

local _cache = {
    loaded = false,
    overrides = {},
    lastErr = nil,
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
    if t == "mob" or t == "item" or t == "ignore" then
        return true
    end
    return false
end

local function _loadBestEffort()
    if _cache.loaded == true then
        return true, nil
    end

    local ok, envOrErr = Store.loadEnvelopeBestEffort(RELPATH, { quiet = true })
    if ok and type(envOrErr) == "table" then
        local data = envOrErr.data
        if type(data) == "table" and type(data.overrides) == "table" then
            _cache.overrides = _copyOneLevel(data.overrides)
        else
            _cache.overrides = {}
        end
        _cache.loaded = true
        _cache.lastErr = nil
        return true, nil
    end

    _cache.overrides = {}
    _cache.loaded = true
    _cache.lastErr = tostring(envOrErr or "load failed")
    return true, nil
end

local function _saveBestEffort()
    local payload = {
        version = M.VERSION,
        updatedTs = os.time(),
        overrides = _copyOneLevel(_cache.overrides),
    }

    local ok, err = Store.saveEnvelopeBestEffort(RELPATH, payload, { quiet = true })
    if ok then
        _cache.lastErr = nil
        return true, nil
    end
    _cache.lastErr = tostring(err or "save failed")
    return false, _cache.lastErr
end

function M.getVersion()
    return tostring(M.VERSION)
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

    _cache.overrides[key] = { type = typeStr, ts = os.time() }
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

-- ############################################################
-- Compatibility wrappers (older UI callers)
-- ############################################################

function M.setType(key, typeStr)
    return M.set(key, typeStr)
end

function M.getType(key)
    local e = M.get(key)
    if type(e) == "table" and type(e.type) == "string" and e.type ~= "" then
        return e.type
    end
    return nil
end

function M.clearType(key)
    return M.clear(key)
end

return M

-- END FILE: src/dwkit/services/roomentities_override_store.lua
