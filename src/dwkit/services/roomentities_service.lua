-- #########################################################################
-- Module Name : dwkit.services.roomentities_service
-- Owner       : Services
-- Version     : v2026-01-16E
-- Purpose     :
--   - SAFE, profile-portable RoomEntitiesService (data only).
--   - No GMCP dependency, no Mudlet events, no timers, no send().
--   - Emits a registered internal event when state changes.
--
-- Public API  :
--   - getVersion() -> string
--   - getState() -> table copy
--   - setState(newState, opts?) -> boolean ok, string|nil err
--   - update(delta, opts?) -> boolean ok, string|nil err
--   - clear(opts?) -> boolean ok, string|nil err
--   - onUpdated(handlerFn) -> boolean ok, number|nil token, string|nil err
--   - getStats() -> table
--
-- NEW (Manual ingest helpers):
--   - ingestLookText(text, opts?) -> boolean ok, string|nil err
--   - ingestLookLines(lines, opts?) -> boolean ok, string|nil err
--
-- NEW (Discovery helpers):
--   - getUpdatedEventName() -> string
--
-- Ingest opts (optional):
--   - source: string
--   - maxKeep: number
--   - knownPlayersSet: table<string,bool> (highest priority for player detection)
--   - includeSelf: boolean (used only if PresenceService is available)
--   - assumeCapitalizedAsPlayer: boolean (opt-in; if true, capitalized single-word names become players)
--
-- Events Emitted:
--   - DWKit:Service:RoomEntities:Updated
-- Automation Policy: Manual only
-- Dependencies     : dwkit.core.identity, dwkit.bus.event_bus
-- Optional         : dwkit.services.presence_service (for known players list)
-- #########################################################################

local M = {}

M.VERSION = "v2026-01-16E"

local ID = require("dwkit.core.identity")
local BUS = require("dwkit.bus.event_bus")

local EV_UPDATED = tostring(ID.eventPrefix or "DWKit:") .. "Service:RoomEntities:Updated"

-- Expose canonical event name for other modules (SAFE; discovery only)
M.EV_UPDATED = EV_UPDATED

local STATE = {
    state = {},
    lastTs = nil,
    updates = 0,

    -- ingest stats (best-effort)
    lastIngest = {
        ts = nil,
        lineCount = 0,
        source = nil,
    },
}

local function _isNonEmptyString(s) return type(s) == "string" and s ~= "" end

local function _shallowCopy(t)
    local out = {}
    if type(t) ~= "table" then return out end
    for k, v in pairs(t) do out[k] = v end
    return out
end

local function _copyBoolMap(m)
    local out = {}
    if type(m) ~= "table" then return out end
    for k, v in pairs(m) do
        if v == true then out[k] = true end
    end
    return out
end

local function _copyState(st)
    st = (type(st) == "table") and st or {}
    return {
        players = _copyBoolMap(st.players),
        mobs = _copyBoolMap(st.mobs),
        items = _copyBoolMap(st.items),
        unknown = _copyBoolMap(st.unknown),

        -- optional metadata
        meta = _shallowCopy(st.meta),
    }
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

local function _safeRequire(modName)
    local ok, mod = pcall(require, modName)
    if ok then return true, mod end
    return false, mod
end

local function _stripAnsi(s)
    if type(s) ~= "string" then return "" end
    -- basic ANSI color strip
    s = s:gsub("\27%[[0-9;]*m", "")
    return s
end

local function _trim(s)
    if type(s) ~= "string" then return "" end
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    return s
end

local function _splitLines(text)
    if type(text) ~= "string" then return {} end
    local out = {}
    text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
    for line in text:gmatch("([^\n]+)") do
        out[#out + 1] = line
    end
    return out
end

local function _normalizeEntityLine(line)
    line = _stripAnsi(line)
    line = _trim(line)
    if line == "" then return "" end

    -- Common suffix patterns in MUD "look" lists
    local suffixes = {
        " is here%.?$",
        " is standing here%.?$",
        " is sitting here%.?$",
        " is resting here%.?$",
        " is sleeping here%.?$",
        " is floating here%.?$",
        " is lying here%.?$",
        " is kneeling here%.?$",
    }

    for _, pat in ipairs(suffixes) do
        line = line:gsub(pat, "")
    end

    line = _trim(line)

    -- Remove leading bullets / markers
    line = line:gsub("^%*", "")
    line = line:gsub("^%-", "")
    line = _trim(line)

    return line
end

local function _lower(s)
    if type(s) ~= "string" then return "" end
    return string.lower(s)
end

local function _classify(lineNorm, knownPlayersSet, opts)
    opts = (type(opts) == "table") and opts or {}
    knownPlayersSet = (type(knownPlayersSet) == "table") and knownPlayersSet or {}

    if lineNorm == "" then
        return nil
    end

    -- 1) Known players (strongest signal)
    if knownPlayersSet[lineNorm] == true then
        return "players"
    end

    local l = _lower(lineNorm)

    -- 2) Items (very rough)
    if l:find("corpse", 1, true) or l:find("remains", 1, true) or l:find("bone", 1, true) then
        return "items"
    end
    if l:find("sword", 1, true) or l:find("dagger", 1, true) or l:find("potion", 1, true) then
        return "items"
    end

    -- 3) Mob-ish heuristics (very rough)
    -- Many mobs begin with articles: "a", "an", "the"
    if l:match("^a%s+") or l:match("^an%s+") or l:match("^the%s+") then
        return "mobs"
    end

    -- 4) Optional: treat capitalized single-word names as players (opt-in)
    -- SAFE default is OFF to avoid false positives.
    if opts.assumeCapitalizedAsPlayer == true then
        -- Require no spaces, starts with A-Z, and only letters/apostrophes afterwards.
        if lineNorm:match("^[A-Z][A-Za-z']+$") and not lineNorm:find("%s") then
            return "players"
        end
    end

    -- Default -> unknown
    return "unknown"
end

local function _buildKnownPlayersSet(opts)
    opts = (type(opts) == "table") and opts or {}

    -- priority:
    --   1) opts.knownPlayersSet (explicit)
    --   2) PresenceService.getKnownPlayersSet()
    if type(opts.knownPlayersSet) == "table" then
        return opts.knownPlayersSet
    end

    local okP, P = _safeRequire("dwkit.services.presence_service")
    if okP and type(P) == "table" and type(P.getKnownPlayersSet) == "function" then
        local okSet, setOrErr = pcall(P.getKnownPlayersSet, { includeSelf = (opts.includeSelf == true) })
        if okSet and type(setOrErr) == "table" then
            return setOrErr
        end
    end

    return {}
end

local function _ingestLinesToState(lines, opts)
    opts = (type(opts) == "table") and opts or {}
    lines = (type(lines) == "table") and lines or {}

    local knownPlayersSet = _buildKnownPlayersSet(opts)

    local players = {}
    local mobs = {}
    local items = {}
    local unknown = {}

    local kept = 0
    local maxKeep = tonumber(opts.maxKeep or 200) or 200
    if maxKeep < 10 then maxKeep = 10 end
    if maxKeep > 1000 then maxKeep = 1000 end

    for _, raw in ipairs(lines) do
        if kept >= maxKeep then break end

        local lineNorm = _normalizeEntityLine(raw)
        if lineNorm ~= "" then
            kept = kept + 1

            local bucket = _classify(lineNorm, knownPlayersSet, opts)
            if bucket == "players" then
                players[lineNorm] = true
            elseif bucket == "mobs" then
                mobs[lineNorm] = true
            elseif bucket == "items" then
                items[lineNorm] = true
            elseif bucket == "unknown" then
                unknown[lineNorm] = true
            end
        end
    end

    local newState = {
        players = players,
        mobs = mobs,
        items = items,
        unknown = unknown,
        meta = {
            ingestTs = os.time(),
            ingestLineCount = kept,
            source = (type(opts.source) == "string" and opts.source ~= "") and opts.source or "manual",
        },
    }

    return newState
end

function M.getVersion()
    return tostring(M.VERSION)
end

function M.getUpdatedEventName()
    return tostring(EV_UPDATED)
end

function M.getState()
    -- return a safer copy (bounded)
    return _copyState(STATE.state)
end

function M.setState(newState, opts)
    opts = opts or {}
    if type(newState) ~= "table" then
        return false, "setState(newState): newState must be a table"
    end

    -- keep it structured (players/mobs/items/unknown/meta)
    STATE.state = _copyState(newState)
    STATE.lastTs = os.time()
    STATE.updates = STATE.updates + 1

    local okEmit, errEmit = _emit(_copyState(STATE.state), nil, opts.source)
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

    -- update is shallow-merge at top-level fields (players/mobs/items/unknown/meta)
    -- NOTE: if caller updates nested maps, they should set the whole map.
    _merge(STATE.state, delta)
    STATE.lastTs = os.time()
    STATE.updates = STATE.updates + 1

    local okEmit, errEmit = _emit(_copyState(STATE.state), _shallowCopy(delta), opts.source)
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

    local okEmit, errEmit = _emit(_copyState(STATE.state), { cleared = true }, opts.source)
    if not okEmit then
        return false, errEmit
    end

    return true, nil
end

function M.onUpdated(handlerFn)
    return BUS.on(EV_UPDATED, handlerFn)
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
        lastIngest = _shallowCopy(STATE.lastIngest),
    }
end

-- #########################################################################
-- NEW: Manual ingest entrypoints
-- #########################################################################

function M.ingestLookText(text, opts)
    opts = (type(opts) == "table") and opts or {}
    if type(text) ~= "string" then
        return false, "ingestLookText(text): text must be a string"
    end

    local lines = _splitLines(text)
    return M.ingestLookLines(lines, opts)
end

function M.ingestLookLines(lines, opts)
    opts = (type(opts) == "table") and opts or {}
    if type(lines) ~= "table" then
        return false, "ingestLookLines(lines): lines must be a table"
    end

    local newState = _ingestLinesToState(lines, opts)

    STATE.lastIngest.ts = os.time()
    STATE.lastIngest.lineCount = tonumber(newState.meta and newState.meta.ingestLineCount) or 0
    STATE.lastIngest.source = tostring(newState.meta and newState.meta.source or "manual")

    -- Replace current entity sets with freshly ingested results.
    return M.setState(newState, { source = (opts.source or "ingest") })
end

return M
