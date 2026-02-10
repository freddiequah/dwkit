-- FILE: src/dwkit/services/chat_store.lua
-- #########################################################################
-- Module Name : dwkit.services.chat_store
-- Owner       : Services
-- Version     : v2026-02-10A
-- Purpose     :
--   - SAFE in-memory chat store (ring buffer).
--   - Profile-portable: segmented by profileTag.
--   - No persistence (runtime only).
--   - No timers, no send(), no GMCP.
--
-- Public API:
--   - getVersion() -> string
--   - getProfileTagBestEffort() -> string
--   - ensure(profileTag?) -> table bucket
--   - setMax(profileTag?, maxN) -> boolean ok
--   - append(msg, profileTag?) -> boolean ok, string|nil err
--   - listRecent(n?, profileTag?) -> table list (oldest->newest)
--   - clear(profileTag?) -> boolean ok
--   - getStats(profileTag?) -> table stats
--
-- Persistence      : None
-- Automation Policy: Manual only
-- Dependencies     : None
-- #########################################################################

local M = {}

M.VERSION = "v2026-02-10A"

local DEFAULT_MAX = 200

-- state[profileTag] = { max=number, nextId=number, items=array }
local STATE = {}

local function _pcall(fn, ...)
    local ok, res = pcall(fn, ...)
    if ok then return true, res end
    return false, res
end

function M.getVersion()
    return tostring(M.VERSION or "unknown")
end

function M.getProfileTagBestEffort()
    if type(_G.getProfileName) == "function" then
        local ok, v = _pcall(_G.getProfileName)
        if ok and type(v) == "string" and v ~= "" then
            v = v:gsub("%s+", "_")
            v = v:gsub("[^%w_%-]", "")
            if v ~= "" then return v end
        end
    end
    return "default"
end

local function _normTag(profileTag)
    profileTag = tostring(profileTag or "")
    if profileTag == "" then profileTag = M.getProfileTagBestEffort() end
    if profileTag == "" then profileTag = "default" end
    return profileTag
end

function M.ensure(profileTag)
    profileTag = _normTag(profileTag)
    if type(STATE[profileTag]) ~= "table" then
        STATE[profileTag] = {
            max = DEFAULT_MAX,
            nextId = 1,
            items = {},
        }
    end
    return STATE[profileTag]
end

function M.setMax(profileTag, maxN)
    profileTag = _normTag(profileTag)
    local b = M.ensure(profileTag)
    local n = tonumber(maxN or 0) or 0
    if n < 20 then n = 20 end
    if n > 2000 then n = 2000 end
    b.max = n

    -- trim if needed
    local items = b.items
    while #items > b.max do
        table.remove(items, 1)
    end
    return true
end

local function _isNonEmptyString(s) return type(s) == "string" and s ~= "" end

function M.append(msg, profileTag)
    profileTag = _normTag(profileTag)
    local b = M.ensure(profileTag)

    if type(msg) ~= "table" then
        return false, "append(msg): msg must be a table"
    end

    local text = msg.text
    if not _isNonEmptyString(text) then
        return false, "append(msg): msg.text must be a non-empty string"
    end

    local item = {
        id = b.nextId,
        ts = tonumber(msg.ts) or os.time(),
        source = _isNonEmptyString(msg.source) and msg.source or nil,
        channel = _isNonEmptyString(msg.channel) and msg.channel or nil,
        speaker = _isNonEmptyString(msg.speaker) and msg.speaker or nil,
        text = text,
        raw = msg.raw, -- optional
    }

    b.nextId = b.nextId + 1
    table.insert(b.items, item)

    -- ring trim
    while #b.items > (tonumber(b.max) or DEFAULT_MAX) do
        table.remove(b.items, 1)
    end

    return true, nil
end

function M.listRecent(n, profileTag)
    profileTag = _normTag(profileTag)
    local b = M.ensure(profileTag)
    local items = b.items

    local want = tonumber(n or #items) or #items
    if want < 0 then want = 0 end
    if want > #items then want = #items end

    local startIdx = (#items - want) + 1
    if startIdx < 1 then startIdx = 1 end

    local out = {}
    for i = startIdx, #items do
        out[#out + 1] = items[i]
    end
    return out
end

function M.clear(profileTag)
    profileTag = _normTag(profileTag)
    local b = M.ensure(profileTag)
    b.items = {}
    b.nextId = 1
    return true
end

function M.getStats(profileTag)
    profileTag = _normTag(profileTag)
    local b = M.ensure(profileTag)
    return {
        profileTag = profileTag,
        max = b.max,
        count = #(b.items or {}),
        nextId = b.nextId,
    }
end

return M
