-- FILE: src/dwkit/services/chat_log_service.lua
-- #########################################################################
-- Module Name : dwkit.services.chat_log_service
-- Owner       : Services
-- Version     : v2026-02-12A
-- Purpose     :
--   - SAFE chat log service (data only) backed by chat_store.
--   - Emits internal DWKit event on append/clear.
--   - No timers, no send(), no GMCP.
--
-- Public API:
--   - getVersion() -> string
--   - getEventName() -> string
--   - append(msg, opts?) -> boolean ok, string|nil err
--   - addLine(text, opts?) -> boolean ok, string|nil err
--   - listRecent(n?, opts?) -> table list
--   - clear(opts?) -> boolean ok
--   - getStats(opts?) -> table stats
--
-- Read API (for UI consumers):
--   - getItems(n?, opts?) -> (items, meta)
--     meta: { latestId, count, profileTag }
--   - getState(opts?) -> table { items, latestId, count, profileTag }
--
-- Event:
--   - DWKit:Service:ChatLog:Updated
--     payload: { ts, state, delta?, source? }
--
-- Persistence      : None (store may be runtime-only; ok for v1 rendering)
-- Automation Policy: Manual only
-- Dependencies     : dwkit.core.identity, dwkit.services.chat_store
-- #########################################################################

local M = {}

M.VERSION = "v2026-02-12A"

local ID = require("dwkit.core.identity")
local PREFIX = tostring(ID.eventPrefix or "DWKit:")

local EV_SVC_CHATLOG_UPDATED = PREFIX .. "Service:ChatLog:Updated"

local Store = require("dwkit.services.chat_store")

local function _emitBestEffort(eventName, payload)
    if type(_G.raiseEvent) == "function" then
        pcall(function() _G.raiseEvent(eventName, payload) end)
        return true
    end
    return false
end

local function _isNonEmptyString(s) return type(s) == "string" and s ~= "" end

function M.getVersion()
    return tostring(M.VERSION or "unknown")
end

function M.getEventName()
    return EV_SVC_CHATLOG_UPDATED
end

local function _normProfile(opts)
    opts = (type(opts) == "table") and opts or {}
    local profileTag = opts.profileTag
    if not _isNonEmptyString(profileTag) then
        profileTag = Store.getProfileTagBestEffort()
    end
    return profileTag
end

local function _snapshotState(profileTag)
    local stats = Store.getStats(profileTag)
    return {
        profileTag = stats.profileTag,
        max = stats.max,
        count = stats.count,
        nextId = stats.nextId,
    }
end

function M.append(msg, opts)
    opts = (type(opts) == "table") and opts or {}
    local profileTag = _normProfile(opts)

    if type(msg) ~= "table" then
        return false, "append(msg): msg must be a table"
    end

    msg.ts = tonumber(msg.ts) or os.time()
    if not _isNonEmptyString(msg.source) then
        msg.source = opts.source
    end

    local ok, err = Store.append(msg, profileTag)
    if not ok then
        return false, err
    end

    local payload = {
        ts = os.time(),
        state = _snapshotState(profileTag),
        delta = {
            op = "append",
            last = msg,
        },
        source = _isNonEmptyString(opts.source) and opts.source or "chat_log_service",
    }
    _emitBestEffort(EV_SVC_CHATLOG_UPDATED, payload)

    return true, nil
end

function M.addLine(text, opts)
    opts = (type(opts) == "table") and opts or {}
    if not _isNonEmptyString(text) then
        return false, "addLine(text): text must be a non-empty string"
    end

    local msg = {
        text = text,
        channel = opts.channel,
        speaker = opts.speaker,
        target = opts.target, -- NEW: first-class target carried to store/UI
        raw = opts.raw,
        source = opts.source or "manual",
        ts = opts.ts,
    }
    return M.append(msg, opts)
end

function M.listRecent(n, opts)
    opts = (type(opts) == "table") and opts or {}
    local profileTag = _normProfile(opts)
    return Store.listRecent(n, profileTag)
end

-- UI consumer-friendly read surface
function M.getItems(n, opts)
    opts = (type(opts) == "table") and opts or {}
    local profileTag = _normProfile(opts)

    local items = Store.listRecent(n, profileTag)
    local stats = Store.getStats(profileTag)

    local latestId = 0
    if type(items) == "table" and #items > 0 then
        local last = items[#items]
        latestId = tonumber(last and last.id or 0) or 0
    end

    local meta = {
        latestId = latestId,
        count = tonumber(stats.count or 0) or 0,
        profileTag = profileTag,
    }

    return (type(items) == "table" and items or {}), meta
end

function M.getState(opts)
    opts = (type(opts) == "table") and opts or {}
    local items, meta = M.getItems(nil, opts)
    return {
        items = items,
        latestId = tonumber(meta.latestId or 0) or 0,
        count = tonumber(meta.count or 0) or 0,
        profileTag = meta.profileTag,
    }
end

function M.clear(opts)
    opts = (type(opts) == "table") and opts or {}
    local profileTag = _normProfile(opts)

    Store.clear(profileTag)

    local payload = {
        ts = os.time(),
        state = _snapshotState(profileTag),
        delta = { op = "clear" },
        source = _isNonEmptyString(opts.source) and opts.source or "chat_log_service",
    }
    _emitBestEffort(EV_SVC_CHATLOG_UPDATED, payload)

    return true
end

function M.getStats(opts)
    opts = (type(opts) == "table") and opts or {}
    local profileTag = _normProfile(opts)
    return Store.getStats(profileTag)
end

return M
