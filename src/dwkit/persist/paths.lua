-- #########################################################################
-- Module Name : dwkit.persist.paths
-- Owner       : Persist
-- Version     : v2026-01-12A
-- Purpose     :
--   - Provide per-profile, package-owned filesystem paths for DWKit persistence.
--   - Computes the package data directory under Mudlet home dir.
--   - Best-effort directory creation (no writes unless explicitly requested).
--
-- Public API  :
--   - getHomeDir() -> (ok:boolean, homeDir:string|nil, err:string|nil)
--   - getDataDir() -> (ok:boolean, dataDir:string|nil, err:string|nil)
--   - ensureDataDir() -> (ok:boolean, dataDir:string|nil, err:string|nil)
--   - join(a,b,...) -> string
--
-- Events Emitted   : None
-- Events Consumed  : None
-- Persistence      : Provides path rules only (does not write data itself)
-- Automation Policy: Manual only
-- Dependencies     : dwkit.core.identity
-- Invariants       :
--   - Data dir MUST be under getMudletHomeDir() and use identity.dataFolderName.
-- #########################################################################

local M = {}

M.VERSION = "v2026-01-12A"

local ID = require("dwkit.core.identity")

local function _dirSep()
    -- package.config is standard in Lua 5.1+; first char is dir separator.
    if type(package) == "table" and type(package.config) == "string" and package.config ~= "" then
        return string.sub(package.config, 1, 1)
    end
    return "/"
end

local function _trimTrailingSeps(s)
    if type(s) ~= "string" then return "" end
    local sep = _dirSep()
    -- Also trim the opposite slash to be tolerant of mixed separators.
    while #s > 1 do
        local last = string.sub(s, -1)
        if last == sep or last == "/" or last == "\\" then
            s = string.sub(s, 1, -2)
        else
            break
        end
    end
    return s
end

function M.join(...)
    local sep = _dirSep()
    local out = nil

    for i = 1, select("#", ...) do
        local part = tostring(select(i, ...) or "")
        if part ~= "" then
            part = _trimTrailingSeps(part)
            if out == nil or out == "" then
                out = part
            else
                -- Avoid duplicate separators.
                local needsSep = true
                local last = string.sub(out, -1)
                if last == sep or last == "/" or last == "\\" then
                    needsSep = false
                end
                local first = string.sub(part, 1, 1)
                if first == sep or first == "/" or first == "\\" then
                    part = string.sub(part, 2)
                end

                out = out .. (needsSep and sep or "") .. part
            end
        end
    end

    return out or ""
end

function M.getHomeDir()
    if type(getMudletHomeDir) ~= "function" then
        return false, nil, "getMudletHomeDir() not available"
    end

    local ok, home = pcall(getMudletHomeDir)
    if not ok then
        return false, nil, "getMudletHomeDir() error: " .. tostring(home)
    end

    home = tostring(home or "")
    if home == "" then
        return false, nil, "getMudletHomeDir() returned empty"
    end

    return true, _trimTrailingSeps(home), nil
end

function M.getDataDir()
    local okHome, home, err = M.getHomeDir()
    if not okHome then
        return false, nil, err
    end

    local folder = tostring(ID.dataFolderName or "dwkit")
    if folder == "" then folder = "dwkit" end

    return true, M.join(home, folder), nil
end

local function _mkdir_p(path)
    if type(path) ~= "string" or path == "" then
        return false, "path invalid"
    end

    -- Prefer lfs if available (common in Mudlet)
    local okLfs, lfs = pcall(require, "lfs")
    if not okLfs or type(lfs) ~= "table" or type(lfs.mkdir) ~= "function" then
        -- Fallback: some Mudlet builds expose mkdir(path).
        if type(mkdir) == "function" then
            local okCall, err = pcall(mkdir, path)
            if okCall then
                return true, nil
            end
            return false, tostring(err)
        end
        return false, "no mkdir available (lfs.mkdir/mkdir)"
    end

    local sep = _dirSep()
    local cleaned = path
    cleaned = cleaned:gsub("\\\\", sep)
    cleaned = cleaned:gsub("/", sep)

    -- Split into components.
    local parts = {}
    for part in string.gmatch(cleaned, "[^" .. sep .. "]+") do
        table.insert(parts, part)
    end

    -- Windows drive prefix support: "C:" stays as first segment.
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

        local ok, err = pcall(lfs.mkdir, acc)
        -- mkdir returns true on created, nil+err on failure, or nil if exists on some builds.
        -- If exists, we treat as OK.
        if not ok then
            return false, tostring(err)
        end
    end

    return true, nil
end

function M.ensureDataDir()
    local okDir, dataDir, err = M.getDataDir()
    if not okDir then
        return false, nil, err
    end

    local okMk, mkErr = _mkdir_p(dataDir)
    if okMk then
        return true, dataDir, nil
    end

    -- If mkdir isn't available, we still return the computed dir, but mark as failure.
    return false, dataDir, "ensureDataDir failed: " .. tostring(mkErr)
end

return M
