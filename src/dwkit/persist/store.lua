-- FILE: src/dwkit/persist/store.lua
-- #########################################################################
-- Module Name : dwkit.persist.store
-- Owner       : Persist
-- Version     : v2026-02-10C
-- Purpose     :
--   - Provide SAFE, per-profile persistence helpers backed by Mudlet's table.save/table.load.
--   - Enforces package-owned data directory (dwkit) via dwkit.persist.paths.
--   - Stores an envelope that includes schemaVersion + timestamp + data.
--   - No automation; callers decide when to write.
--
-- Public API  :
--   - wrap(schemaVersion, data, meta?) -> table envelope
--   - resolve(relPath) -> (ok:boolean, fullPath:string|nil, err:string|nil)
--   - saveEnvelope(relPath, schemaVersion, data, meta?) -> (ok:boolean, err:string|nil)
--   - loadEnvelope(relPath) -> (ok:boolean, envelope:table|nil, err:string|nil)
--   - delete(relPath) -> (ok:boolean, err:string|nil)
--
-- Added Debug Helpers (v2026-02-10C):
--   - resolvePathBestEffort(relPath) -> fullPath|nil
--   - getBaseDirBestEffort() -> baseDir|nil
--
-- Events Emitted   : None
-- Events Consumed  : None
-- Persistence      : Writes under: <getMudletHomeDir()>/<identity.dataFolderName>/
-- Automation Policy: Manual only
-- Dependencies     : dwkit.persist.paths, dwkit.core.identity
-- Invariants       :
--   - relPath MUST be relative (no absolute paths, no '..' traversal).
--   - envelope MUST contain schemaVersion:number|string, ts:number, data:table.
-- #########################################################################

local M = {}

M.VERSION = "v2026-02-10C"

local ID = require("dwkit.core.identity")
local Paths = require("dwkit.persist.paths")

local function _isNonEmptyString(s) return type(s) == "string" and s ~= "" end

local function _dirSep()
    if type(package) == "table" and type(package.config) == "string" and package.config ~= "" then
        return string.sub(package.config, 1, 1)
    end
    return "/"
end

local function _normalizeSeps(s)
    local sep = _dirSep()
    s = tostring(s or "")
    s = s:gsub("\\\\", sep)
    s = s:gsub("/", sep)
    return s
end

local function _isAbsolutePath(p)
    p = tostring(p or "")
    if p == "" then return false end
    if string.match(p, "^[A-Za-z]:") then return true end
    local c1 = string.sub(p, 1, 1)
    if c1 == "/" or c1 == "\\" then return true end
    return false
end

local function _hasTraversal(p)
    p = tostring(p or "")
    if p:find("..", 1, true) == nil then
        return false
    end

    local norm = p:gsub("\\", "/")
    if norm:find("/../", 1, true) then return true end
    if norm:find("^../", 1, true) then return true end
    if norm:find("/..$", 1, true) then return true end
    if norm == ".." then return true end

    return false
end

local function _validateRelPath(relPath)
    if not _isNonEmptyString(relPath) then
        return false, "relPath empty"
    end
    if _isAbsolutePath(relPath) then
        return false, "relPath must be relative"
    end
    if relPath:find(":", 1, true) then
        return false, "relPath must not contain ':'"
    end
    if _hasTraversal(relPath) then
        return false, "relPath must not contain '..' traversal"
    end
    return true, nil
end

local function _mkdir_p(path)
    path = tostring(path or "")
    if path == "" then return false, "path invalid" end

    local okLfs, lfs = pcall(require, "lfs")
    if okLfs and type(lfs) == "table" and type(lfs.mkdir) == "function" then
        local sep = _dirSep()
        local cleaned = _normalizeSeps(path)

        local parts = {}
        for part in string.gmatch(cleaned, "[^" .. sep .. "]+") do
            table.insert(parts, part)
        end

        local acc = ""
        if string.match(cleaned, "^[A-Za-z]:") then
            acc = parts[1]
            table.remove(parts, 1)
        elseif string.sub(cleaned, 1, 1) == sep then
            acc = sep
        end

        for _, p in ipairs(parts) do
            if acc == "" or acc == sep then
                acc = acc .. p
            else
                acc = acc .. sep .. p
            end
            local okCall, err = pcall(lfs.mkdir, acc)
            if not okCall then
                return false, tostring(err)
            end
        end

        return true, nil
    end

    if type(mkdir) == "function" then
        local okCall, err = pcall(mkdir, path)
        if okCall then
            return true, nil
        end
        return false, tostring(err)
    end

    return false, "no mkdir available (lfs.mkdir/mkdir)"
end

local function _ensureParentDirs(fullPath)
    local sep = _dirSep()
    fullPath = _normalizeSeps(fullPath)

    local dir = fullPath:match("^(.*)" .. sep)
    if not dir or dir == "" then
        return true, nil
    end

    return _mkdir_p(dir)
end

function M.wrap(schemaVersion, data, meta)
    return {
        schemaVersion = schemaVersion,
        ts = os.time(),
        data = data,
        meta = meta,
    }
end

function M.resolve(relPath)
    local okRel, errRel = _validateRelPath(relPath)
    if not okRel then
        return false, nil, errRel
    end

    local okDir, dataDir, err = Paths.getDataDir()
    if not okDir then
        return false, nil, err
    end

    return true, Paths.join(dataDir, _normalizeSeps(relPath)), nil
end

-- Added (debug): returns fullPath or nil
function M.resolvePathBestEffort(relPath)
    local ok, fullPath = M.resolve(relPath)
    if ok and type(fullPath) == "string" and fullPath ~= "" then
        return fullPath
    end
    return nil
end

-- Added (debug): returns base data dir or nil
function M.getBaseDirBestEffort()
    local okDir, dataDir = Paths.getDataDir()
    if okDir and type(dataDir) == "string" and dataDir ~= "" then
        return dataDir
    end
    return nil
end

function M.saveEnvelope(relPath, schemaVersion, data, meta)
    if type(data) ~= "table" then
        return false, "data must be table"
    end

    local okBase, baseDir, baseErr = Paths.ensureDataDir()
    if not okBase then
        if not baseDir then
            return false, tostring(baseErr)
        end
    end

    local okPath, fullPath, err = M.resolve(relPath)
    if not okPath then
        return false, err
    end

    local okParents, pErr = _ensureParentDirs(fullPath)
    if not okParents then
        return false, "ensure parent dirs failed: " .. tostring(pErr)
    end

    if type(table) ~= "table" or type(table.save) ~= "function" then
        return false, "table.save not available"
    end

    local envelope = M.wrap(schemaVersion, data, meta)

    local okCall, errSave = pcall(table.save, fullPath, envelope)
    if okCall then
        return true, nil
    end
    return false, tostring(errSave)
end

function M.loadEnvelope(relPath)
    local okPath, fullPath, err = M.resolve(relPath)
    if not okPath then
        return false, nil, err
    end

    if type(table) ~= "table" or type(table.load) ~= "function" then
        return false, nil, "table.load not available"
    end

    -- Best-effort existence check (Mudlet exposes io.exists in examples).
    if type(io) == "table" and type(io.exists) == "function" then
        local okExists, existsOrErr = pcall(io.exists, fullPath)
        if okExists and not existsOrErr then
            return false, nil, "file not found"
        end
    end

    -- IMPORTANT: Mudlet table.load loads INTO a table you provide (it does not return it).
    local env = {}

    local okCall, errLoad = pcall(table.load, fullPath, env)
    if not okCall then
        return false, nil, tostring(errLoad)
    end

    if type(env) ~= "table" then
        return false, nil, "loaded object not table"
    end

    -- If file exists but nothing loaded, treat as invalid/empty.
    if next(env) == nil then
        return false, nil, "no data loaded (empty or incompatible file)"
    end

    if env.schemaVersion == nil then
        return false, nil, "missing schemaVersion"
    end
    if type(env.ts) ~= "number" then
        return false, nil, "missing/invalid ts"
    end
    if type(env.data) ~= "table" then
        return false, nil, "missing/invalid data"
    end

    return true, env, nil
end

function M.delete(relPath)
    local okPath, fullPath, err = M.resolve(relPath)
    if not okPath then
        return false, err
    end

    if type(os) ~= "table" or type(os.remove) ~= "function" then
        return false, "os.remove not available"
    end

    local okCall, res = pcall(os.remove, fullPath)
    if okCall and res then
        return true, nil
    end

    -- If file doesn't exist, treat as OK.
    return true, nil
end

return M
