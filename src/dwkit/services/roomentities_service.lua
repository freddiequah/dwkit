-- #########################################################################
-- Module Name : dwkit.services.roomentities_service
-- Owner       : Services
-- Version     : v2026-01-16C
-- Purpose     :
--   - SAFE, profile-portable RoomEntitiesService (data only).
--   - No GMCP dependency, no Mudlet events, no timers, no send().
--   - Emits a registered internal event when state changes.
--   - Provides manual ingestion helpers for "look" output parsing.
--
-- Public API  :
--   - getVersion() -> string
--   - getState() -> table copy
--   - setState(newState, opts?) -> boolean ok, string|nil err
--   - update(delta, opts?) -> boolean ok, string|nil err
--   - clear(opts?) -> boolean ok, string|nil err
--   - onUpdated(handlerFn) -> boolean ok, number|nil token, string|nil err
--   - getStats() -> table
--   - getUpdatedEventName() -> string
--   - ingestLookLines(lines, opts?) -> boolean ok, string|nil err
--   - ingestLookText(text, opts?) -> boolean ok, string|nil err
--
-- Events Emitted:
--   - DWKit:Service:RoomEntities:Updated
-- Automation Policy: Manual only
-- Dependencies     : dwkit.core.identity, dwkit.bus.event_bus
-- #########################################################################

local M = {}

M.VERSION = "v2026-01-16C"

local ID = require("dwkit.core.identity")
local BUS = require("dwkit.bus.event_bus")

local EV_UPDATED = tostring(ID.eventPrefix or "DWKit:") .. "Service:RoomEntities:Updated"

-- Expose event name for UIs and consumers (contract)
M.EV_UPDATED = EV_UPDATED

local STATE = {
    state = {},
    lastTs = nil,
    updates = 0,
}

local function _trim(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function _shallowCopy(t)
    local out = {}
    if type(t) ~= "table" then return out end
    for k, v in pairs(t) do out[k] = v end
    return out
end

-- shallow copy with 1-level copy for nested tables (good enough for buckets)
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

local function _merge(dst, src)
    if type(dst) ~= "table" or type(src) ~= "table" then return end
    for k, v in pairs(src) do
        dst[k] = v
    end
end

local function _emit(stateCopy, deltaCopy, source)
    local payload = {
        ts = os.time(),
        state = stateCopy,
    }
    if type(deltaCopy) == "table" then payload.delta = deltaCopy end
    if type(source) == "string" and source ~= "" then payload.source = source end

    local ok, delivered, errs = BUS.emit(EV_UPDATED, payload)
    if not ok then
        local first = (type(errs) == "table" and errs[1]) and tostring(errs[1]) or "emit failed"
        return false, first
    end
    return true, nil
end

local function _newBuckets()
    return {
        players = {},
        mobs = {},
        items = {},
        unknown = {},
    }
end

local function _asKey(s)
    s = _trim(s or "")
    if s == "" then return nil end
    return s
end

local function _addBucket(bucket, key)
    if type(bucket) ~= "table" then return end
    if type(key) ~= "string" or key == "" then return end
    bucket[key] = true
end

-- Very light, SAFE heuristics for look-line classification.
-- This is intentionally conservative; we will improve later using PresenceService / WhoStore.
local function _classifyLookLine(line, opts)
    opts = (type(opts) == "table") and opts or {}
    line = _trim(line or "")
    if line == "" then return nil, nil end

    -- ignore common non-entity look lines
    local lower = line:lower()
    if lower == "you see nothing special." then return nil, nil end
    if lower:find("^exits:") then return nil, nil end

    -- pattern: "<Name> is standing here."
    do
        local name = line:match("^(.-)%s+is%s+standing%s+here%.$")
        if type(name) == "string" then
            name = _trim(name)
            if name ~= "" then
                -- default assumption: capitalized -> player (opt-in)
                if opts.assumeCapitalizedAsPlayer == true then
                    local first = name:sub(1, 1)
                    if first:match("%u") then
                        return "players", _asKey(name)
                    end
                end
                -- otherwise unknown until Presence/Who is integrated
                return "unknown", _asKey(name)
            end
        end
    end

    -- pattern: "<something> is here."
    do
        local thing = line:match("^(.-)%s+is%s+here%.$")
        if type(thing) == "string" then
            thing = _trim(thing)
            if thing ~= "" then
                -- corpses/items are usually not mobs
                if lower:find("corpse") then
                    return "items", _asKey(thing)
                end

                -- crude: "a/an/the ..." tends to be NPC/mob, but can be items too.
                if thing:lower():match("^(a%s+)") or thing:lower():match("^(an%s+)") or thing:lower():match("^(the%s+)") then
                    -- if it looks like an object keyword, push to items (very light)
                    if lower:find("sword") or lower:find("shield") or lower:find("scroll") or lower:find("potion") then
                        return "items", _asKey(thing)
                    end
                    return "mobs", _asKey(thing)
                end

                return "unknown", _asKey(thing)
            end
        end
    end

    -- fallback rules
    if lower:find("corpse") then
        return "items", _asKey(line)
    end

    return "unknown", _asKey(line)
end

function M.getVersion()
    return tostring(M.VERSION)
end

function M.getUpdatedEventName()
    return tostring(EV_UPDATED)
end

function M.getState()
    return _copyOneLevel(STATE.state)
end

function M.setState(newState, opts)
    opts = opts or {}
    if type(newState) ~= "table" then
        return false, "setState(newState): newState must be a table"
    end

    STATE.state = _copyOneLevel(newState)
    STATE.lastTs = os.time()
    STATE.updates = STATE.updates + 1

    local okEmit, errEmit = _emit(_copyOneLevel(STATE.state), nil, opts.source)
    if not okEmit then
        return false, errEmit
    end

    return true, nil
end

function M.update(delta, opts)
    opts = opts or {}
    if type(delta) ~= "table" then
        return false, "update(delta): delta must be a table"
    end

    _merge(STATE.state, delta)
    STATE.lastTs = os.time()
    STATE.updates = STATE.updates + 1

    local okEmit, errEmit = _emit(_copyOneLevel(STATE.state), _copyOneLevel(delta), opts.source)
    if not okEmit then
        return false, errEmit
    end

    return true, nil
end

function M.clear(opts)
    opts = opts or {}
    STATE.state = {}
    STATE.lastTs = os.time()
    STATE.updates = STATE.updates + 1

    local okEmit, errEmit = _emit(_copyOneLevel(STATE.state), { cleared = true }, opts.source)
    if not okEmit then
        return false, errEmit
    end

    return true, nil
end

function M.onUpdated(handlerFn)
    return BUS.on(EV_UPDATED, handlerFn)
end

-- Manual ingest helper: takes array of look lines
-- opts:
--   - source: string
--   - assumeCapitalizedAsPlayer: boolean
function M.ingestLookLines(lines, opts)
    opts = (type(opts) == "table") and opts or {}
    if type(lines) ~= "table" then
        return false, "ingestLookLines(lines): lines must be a table"
    end

    local buckets = _newBuckets()

    for _, raw in ipairs(lines) do
        local bucketName, key = _classifyLookLine(raw, opts)
        if bucketName and key then
            _addBucket(buckets[bucketName], key)
        end
    end

    return M.setState(buckets, { source = opts.source or "ingestLookLines" })
end

-- Manual ingest helper: takes full look text, splits into lines
-- opts: same as ingestLookLines
function M.ingestLookText(text, opts)
    opts = (type(opts) == "table") and opts or {}
    if type(text) ~= "string" then
        return false, "ingestLookText(text): text must be a string"
    end

    local lines = {}
    for line in tostring(text):gmatch("[^\r\n]+") do
        lines[#lines + 1] = line
    end

    return M.ingestLookLines(lines, opts)
end

function M.getStats()
    return {
        version = M.VERSION,
        lastTs = STATE.lastTs,
        updates = STATE.updates,
        keys = (function()
            local n = 0
            for _ in pairs(STATE.state) do n = n + 1 end
            return n
        end)(),
    }
end

return M
