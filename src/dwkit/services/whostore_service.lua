-- #########################################################################
-- Module Name : dwkit.services.whostore_service
-- Owner       : Services
-- Version     : v2026-01-29C
-- Purpose     :
--   - SAFE WhoStore service (manual-only) to cache an authoritative WHO snapshot
--     derived from parsing WHO output (No-GMCP compatible).
--   - Stores:
--       * rawLines (debug / replay)
--       * entries (parsed Entry records)
--       * byName index (name -> Entry)
--   - Provides a known-player set used by other services (e.g. RoomEntities) for
--     best-effort player classification.
--   - Emits Updated event on snapshot changes (SAFE; no gameplay commands; no timers).
--
-- Docs-First Contract:
--   - docs/WhoStore_Service_Contract_v1.0.md (v1.1)
--   - Event: DWKit:Service:WhoStore:Updated
--
-- Public API (v2026-01-29C) :
--   - getVersion() -> string
--   - getUpdatedEventName() -> string
--   - onUpdated(handlerFn) -> boolean ok, any tokenOrNil, string|nil err
--
--   -- Docs-first APIs (v1.1)
--   - getSnapshot() -> Snapshot copy
--   - getEntry(name) -> Entry|nil (copy)
--   - getAllNames() -> array (sorted)
--
--   -- Auto capture gate (v2026-01-29C)
--   - getAutoCaptureEnabled() -> boolean
--   - setAutoCaptureEnabled(flag, opts?) -> boolean ok, string|nil err
--
--   -- Legacy compatibility (kept for now)
--   - getState() -> table copy (includes players map)
--   - setState(newState, opts?) -> boolean ok, string|nil err
--   - update(delta, opts?) -> boolean ok, string|nil err
--   - clear(opts?) -> boolean ok, string|nil err
--   - ingestWhoLines(lines, opts?) -> boolean ok, string|nil err
--   - ingestWhoText(text, opts?) -> boolean ok, string|nil err
--   - hasPlayer(name) -> boolean
--   - getAllPlayers() -> array (sorted)   -- alias of getAllNames()
--
-- ingestWho* behavior:
--   - Default: REPLACE mode (authoritative snapshot) to match real WHO output.
--   - Opt-in MERGE mode: pass opts.merge=true to add/update entries without removing existing.
--
-- SAFE Constraints:
--   - No gameplay commands
--   - No timers
--   - No automation by default
--
-- Fix (v2026-01-18C):
--   - _emitUpdated MUST check BUS.emit() return ok flag.
--     pcall() success only means no error, NOT that emit succeeded.
--
-- Fix (v2026-01-19C):
--   - event_bus.emit() requires 3-arg signature: emit(eventName, payload, meta)
--     Without meta, emit does not deliver (seen in live verification).
--
-- Fix (v2026-01-29C):
--   - Auto-capture gate blocks dwwho:auto ingests when watcher is OFF, preventing
--     orphaned triggers from updating snapshot.
-- #########################################################################

local M = {}

M.VERSION = "v2026-01-29C"

local ID = require("dwkit.core.identity")
local BUS = require("dwkit.bus.event_bus")

M.EV_UPDATED = tostring(ID.eventPrefix or "DWKit:") .. "Service:WhoStore:Updated"

-- ############################################################
-- Internal state
-- ############################################################

local _state = {
    snapshot = {
        ts = nil,      -- os.time()
        source = nil,  -- string|nil
        rawLines = {}, -- array of strings
        entries = {},  -- array of Entry
        byName = {},   -- map: name -> Entry
    },

    -- Legacy compatibility cache (name -> true). Derived from snapshot.byName
    players = {},

    -- Auto-capture gate: blocks dwwho:auto ingests when watcher is OFF
    autoCaptureEnabled = true,

    lastUpdatedTs = nil, -- os.time()
    source = nil,        -- string
    rawCount = 0,        -- count of names parsed from last ingest snapshot (raw parsed names)
    stats = {
        ingests = 0,
        updates = 0,
        emits = 0, -- counts successful emits only
        lastEmitTs = nil,
        lastEmitSource = nil,
        lastEmitErr = nil,
    },
}

-- ############################################################
-- Helpers (copy / collections)
-- ############################################################

local function _copyTable(t)
    local out = {}
    if type(t) ~= "table" then return out end
    for k, v in pairs(t) do
        out[k] = v
    end
    return out
end

local function _copyArray(a)
    local out = {}
    if type(a) ~= "table" then return out end
    for i = 1, #a do
        out[i] = a[i]
    end
    return out
end

local function _copyEntry(e)
    if type(e) ~= "table" then return nil end
    local out = {}
    for k, v in pairs(e) do
        if k == "flags" and type(v) == "table" then
            out.flags = _copyArray(v)
        else
            out[k] = v
        end
    end
    return out
end

local function _copySnapshot(snap)
    snap = (type(snap) == "table") and snap or {}
    local out = {
        ts = snap.ts,
        source = snap.source,
        rawLines = _copyArray(snap.rawLines),
        entries = {},
        byName = {},
    }

    if type(snap.entries) == "table" then
        for i = 1, #snap.entries do
            local e = _copyEntry(snap.entries[i])
            if e then out.entries[#out.entries + 1] = e end
        end
    end

    if type(snap.byName) == "table" then
        for k, v in pairs(snap.byName) do
            local e = _copyEntry(v)
            if e then out.byName[k] = e end
        end
    end

    return out
end

local function _countMap(t)
    if type(t) ~= "table" then return 0 end
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

local function _sortedKeys(t)
    local keys = {}
    if type(t) ~= "table" then return keys end
    for k, _ in pairs(t) do
        keys[#keys + 1] = k
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    return keys
end

local function _normWs(s)
    if type(s) ~= "string" then return "" end
    s = s:gsub("\r", "")
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    -- collapse internal whitespace
    s = s:gsub("%s+", " ")
    return s
end

-- ############################################################
-- Guards (blocked tokens)
-- ############################################################

-- Guard: prevent common DWKit commands / headers from being treated as player names
local _BLOCKED_TOKENS = {
    -- commands / aliases (common)
    ["dwwho"] = true,
    ["dw"] = true,
    ["dwcommands"] = true,
    ["dwhelp"] = true,
    ["dwtest"] = true,
    ["dwinfo"] = true,
    ["dwid"] = true,
    ["dwversion"] = true,
    ["dwdiag"] = true,
    ["dwgui"] = true,
    ["dwevents"] = true,
    ["dwevent"] = true,
    ["dwboot"] = true,
    ["dwservices"] = true,
    ["dwpresence"] = true,
    ["dwroom"] = true,
    ["dwactions"] = true,
    ["dwskills"] = true,
    ["dwscorestore"] = true,
    ["dweventtap"] = true,
    ["dweventsub"] = true,
    ["dweventunsub"] = true,
    ["dweventlog"] = true,
    ["dwrelease"] = true,

    -- common WHO noise / headers
    ["name"] = true,
    ["names"] = true,
    ["player"] = true,
    ["players"] = true,
    ["total"] = true,
    ["characters"] = true,
    ["displayed"] = true,
}

local function _isBlockedToken(name)
    if type(name) ~= "string" then return true end
    local k = name:lower()
    if _BLOCKED_TOKENS[k] then
        return true
    end
    return false
end

-- ############################################################
-- WHO parsing (v1.1)
-- ############################################################

local function _stripMudColorCodes(s)
    if type(s) ~= "string" then return s end
    return s:gsub("\27%[[%d;]*m", "")
end

local function _looksLikeDivider(s)
    if type(s) ~= "string" then return false end
    local t = _normWs(s)
    if t == "" then return true end
    return (t:match("^[-=_%*]+$") ~= nil)
end

local function _looksLikeWhoFooter(s)
    if type(s) ~= "string" then return false end
    local lower = _normWs(s):lower()
    -- e.g. "12 characters displayed."
    if lower:match("^%d+%s+characters%s+displayed%.?$") then
        return true
    end
    return false
end

local function _parseRankTagAndRest(line)
    if type(line) ~= "string" then return nil end
    local s = _stripMudColorCodes(line)
    s = s:gsub("\r", "")

    if _looksLikeDivider(s) or _looksLikeWhoFooter(s) then
        return nil
    end

    local bracket = s:match("^%s*(%b[])")
    if not bracket then
        return nil
    end

    local rankTag = bracket:sub(2, -2)
    rankTag = _normWs(rankTag)
    if rankTag == "" then
        rankTag = nil
    end

    local rest = s:gsub("^%s*%b[]%s*", "")
    rest = _normWs(rest)
    if rest == "" then
        return nil
    end

    return {
        rankTag = rankTag,
        rest = rest,
        rawLine = tostring(line),
    }
end

local function _parseLevelClass(rankTag)
    if type(rankTag) ~= "string" or rankTag == "" then
        return nil, nil
    end

    -- Examples:
    -- "48 War" -> level=48 class="War"
    -- "50 Cle" -> level=50 class="Cle"
    -- "IMPL"   -> level=nil class=nil
    local n, cls = rankTag:match("^(%d+)%s+(%S+)")
    if n then
        local level = tonumber(n)
        local class = (type(cls) == "string" and cls ~= "") and cls or nil
        return level, class
    end

    local nOnly = rankTag:match("^(%d+)$")
    if nOnly then
        return tonumber(nOnly), nil
    end

    return nil, nil
end

local function _parseNameAndExtra(rest)
    if type(rest) ~= "string" then return nil end
    local s = _normWs(rest)
    if s == "" then return nil end

    -- Name token rules: first token after bracket, leading letter, allow digits/' thereafter
    local name = s:match("^([A-Za-z][A-Za-z0-9']*)")
    if not name or name == "" then
        return nil
    end
    if _isBlockedToken(name) then
        return nil
    end

    local extra = s:sub(#name + 1)
    extra = _normWs(extra)
    if extra == "" then extra = "" end

    return name, extra
end

local function _pushFlag(flags, key)
    if type(flags) ~= "table" then return end
    if type(key) ~= "string" or key == "" then return end
    for i = 1, #flags do
        if flags[i] == key then return end
    end
    flags[#flags + 1] = key
end

local function _detectFlags(extraText)
    local flags = {}
    if type(extraText) ~= "string" or extraText == "" then
        return flags
    end

    local s = extraText
    local upper = s:upper()

    -- AFK / NH best-effort
    if upper:match("%(AFK%)") or upper:match("%f[%a]AFK%f[%A]") then
        _pushFlag(flags, "AFK")
    end
    if upper:match("%(NH%)") or upper:match("%f[%a]NH%f[%A]") then
        _pushFlag(flags, "NH")
    end

    -- idle patterns: "(idle:19)" or "idle:19"
    local lower = s:lower()
    if lower:match("%(idle:%d+%)") or lower:match("%f[%a]idle:%d+%f[%A]") then
        _pushFlag(flags, "idle")
    end

    -- down marker: "<-- down" (canonical)
    if lower:find("<-- down", 1, true) ~= nil then
        _pushFlag(flags, "down")
    end

    return flags
end

local function _deriveTitleText(extraText)
    if type(extraText) ~= "string" then return nil end
    local s = _normWs(extraText)
    if s == "" then return nil end

    -- Remove only known flag markers/tokens (best-effort). Preserve other meaning.
    -- Order matters.
    s = s:gsub("<%-%-%s*down", "")
    s = s:gsub("%(AFK%)", "")
    s = s:gsub("%(NH%)", "")
    s = s:gsub("%(idle:%d+%)", "")
    s = _normWs(s)

    if s == "" then
        return nil
    end
    return s
end

local function _parseWhoLineToEntry(line)
    local pre = _parseRankTagAndRest(line)
    if not pre then
        return nil
    end

    local name, extraText = _parseNameAndExtra(pre.rest)
    if not name then
        return nil
    end

    local level, class = _parseLevelClass(pre.rankTag or "")

    local flags = _detectFlags(extraText)
    local titleText = _deriveTitleText(extraText)

    -- Entry schema (v1.1)
    local entry = {
        name = name,
        rankTag = pre.rankTag or "",
        level = level,
        class = class,
        flags = flags,
        extraText = extraText or "",
        titleText = titleText,
        rawLine = tostring(pre.rawLine or line or ""),
    }

    return entry
end

-- ############################################################
-- Legacy helpers (players map input)
-- ############################################################

local function _normalizeNameForLegacy(s)
    if type(s) ~= "string" then return nil end

    -- normalize whitespace
    s = s:gsub("\r", "")
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then return nil end

    -- remove common mudlet/mud color codes (best-effort)
    s = s:gsub("\27%[[%d;]*m", "")

    -- ignore divider-ish lines
    if s:match("^[-=_%*]+$") then
        return nil
    end

    local lower = s:lower()

    -- ignore WHO footer lines
    if lower:match("^%d+%s+characters%s+displayed%.?$") then
        return nil
    end

    -- Capture first plausible name token.
    local name = s:match("([A-Za-z][A-Za-z0-9']*)")
    if not name or name == "" then
        return nil
    end

    if _isBlockedToken(name) then
        return nil
    end

    return name
end

local function _asPlayersMap(players)
    -- Accept either map {Name=true} OR array {"Name", ...}
    local out = {}

    if type(players) ~= "table" then
        return out
    end

    -- array-like
    if #players > 0 then
        for i = 1, #players do
            local n = _normalizeNameForLegacy(tostring(players[i] or ""))
            if n then out[n] = true end
        end
        return out
    end

    -- map-like
    for k, v in pairs(players) do
        if v == true then
            local n = _normalizeNameForLegacy(tostring(k or ""))
            if n then out[n] = true end
        end
    end

    return out
end

-- ############################################################
-- Snapshot builders / delta
-- ############################################################

local function _rebuildLegacyPlayersFromSnapshot(snap)
    local out = {}
    if type(snap) ~= "table" or type(snap.byName) ~= "table" then
        return out
    end
    for name, _ in pairs(snap.byName) do
        if type(name) == "string" and name ~= "" then
            out[name] = true
        end
    end
    return out
end

local function _buildSnapshotFromEntries(ts, source, rawLines, entries, byName)
    return {
        ts = ts,
        source = source,
        rawLines = rawLines or {},
        entries = entries or {},
        byName = byName or {},
    }
end

local function _rebuildEntriesArrayFromByName(byName)
    local arr = {}
    if type(byName) ~= "table" then return arr end
    local names = _sortedKeys(byName)
    for i = 1, #names do
        local e = byName[names[i]]
        local c = _copyEntry(e)
        if c then arr[#arr + 1] = c end
    end
    return arr
end

local function _computeDeltaByName(beforeByName, afterByName)
    beforeByName = (type(beforeByName) == "table") and beforeByName or {}
    afterByName = (type(afterByName) == "table") and afterByName or {}

    local added, removed, changed = 0, 0, 0

    for name, afterE in pairs(afterByName) do
        local beforeE = beforeByName[name]
        if beforeE == nil then
            added = added + 1
        else
            -- title change is normative; treat as "changed" when titleText differs.
            local bt = (type(beforeE) == "table") and beforeE.titleText or nil
            local at = (type(afterE) == "table") and afterE.titleText or nil
            if tostring(bt or "") ~= tostring(at or "") then
                changed = changed + 1
            end
        end
    end

    for name, _ in pairs(beforeByName) do
        if afterByName[name] == nil then
            removed = removed + 1
        end
    end

    return { added = added, removed = removed, changed = changed, total = _countMap(afterByName) }
end

-- ############################################################
-- Event emission
-- ############################################################

local function _emitUpdated(payload)
    payload = (type(payload) == "table") and payload or {}

    if type(BUS) ~= "table" then
        _state.stats.lastEmitErr = "event bus not available"
        return false
    end

    if type(BUS.emit) ~= "function" then
        _state.stats.lastEmitErr = "event bus .emit not available"
        return false
    end

    local meta = {
        source = tostring(payload.source or _state.source or "WhoStoreService"),
        service = "dwkit.services.whostore_service",
        ts = payload.ts,
    }

    local okCall, okEmit, delivered, errs = pcall(BUS.emit, M.EV_UPDATED, payload, meta)

    if okCall and okEmit == true then
        _state.stats.emits = _state.stats.emits + 1
        _state.stats.lastEmitTs = os.time()
        _state.stats.lastEmitSource = meta.source
        _state.stats.lastEmitErr = nil
        return true
    end

    local errMsg = nil
    if okCall ~= true then
        errMsg = tostring(okEmit)
    else
        if type(errs) == "table" and errs[1] ~= nil then
            errMsg = tostring(errs[1])
        else
            errMsg = "emit returned ok=false"
        end
    end

    _state.stats.lastEmitErr = errMsg
    return false
end

-- ############################################################
-- Public API
-- ############################################################

function M.getVersion()
    return M.VERSION
end

function M.getUpdatedEventName()
    return M.EV_UPDATED
end

function M.onUpdated(handlerFn)
    if type(handlerFn) ~= "function" then
        return false, nil, "handlerFn must be function"
    end
    if type(BUS) ~= "table" then
        return false, nil, "event bus not available"
    end
    if type(BUS.on) ~= "function" then
        return false, nil, "event bus .on not available"
    end

    local ok, tokenOrErr, maybeErr = BUS.on(M.EV_UPDATED, handlerFn)
    if ok == true then
        return true, tokenOrErr, nil
    end

    return false, nil, maybeErr or tokenOrErr or "subscribe failed"
end

-- Auto capture gate (robust against orphan triggers)
function M.getAutoCaptureEnabled()
    return (_state.autoCaptureEnabled == true)
end

function M.setAutoCaptureEnabled(flag, opts)
    opts = (type(opts) == "table") and opts or {}
    _state.autoCaptureEnabled = (flag == true)
    return true, nil
end

-- Docs-first snapshot API
function M.getSnapshot()
    return _copySnapshot(_state.snapshot)
end

function M.getEntry(name)
    if type(name) ~= "string" or name == "" then return nil end
    local e = (type(_state.snapshot.byName) == "table") and _state.snapshot.byName[name] or nil
    if not e then return nil end
    return _copyEntry(e)
end

function M.getAllNames()
    return _sortedKeys(_state.snapshot.byName or {})
end

-- Legacy compatibility (kept)
function M.getState()
    return {
        version = M.VERSION,
        updatedEventName = M.EV_UPDATED,

        -- legacy player set view
        players = _copyTable(_state.players),

        -- auto capture gate (debug)
        autoCaptureEnabled = (_state.autoCaptureEnabled == true),

        -- legacy bookkeeping
        lastUpdatedTs = _state.lastUpdatedTs,
        source = _state.source,
        rawCount = _state.rawCount,
        stats = _copyTable(_state.stats),

        -- docs-first snapshot (exposed read-only)
        snapshot = _copySnapshot(_state.snapshot),
    }
end

function M.hasPlayer(name)
    local n = _normalizeNameForLegacy(tostring(name or ""))
    if not n then return false end
    return (_state.players[n] == true)
end

function M.getAllPlayers()
    return M.getAllNames()
end

-- ############################################################
-- Mutations (legacy + docs-first updates)
-- ############################################################

local function _applyNewSnapshot(newSnap, opts, delta)
    opts = (type(opts) == "table") and opts or {}
    newSnap = (type(newSnap) == "table") and newSnap or
        _buildSnapshotFromEntries(os.time(), "applyNewSnapshot", {}, {}, {})

    _state.snapshot = newSnap
    _state.players = _rebuildLegacyPlayersFromSnapshot(newSnap)

    _state.lastUpdatedTs = os.time()
    _state.source = tostring(opts.source or newSnap.source or "snapshot")
    _state.rawCount = tonumber(opts.rawCount or _state.rawCount or 0) or 0
    _state.stats.updates = _state.stats.updates + 1

    local payload = {
        ts = newSnap.ts or _state.lastUpdatedTs,
        source = _state.source,

        -- docs-first payload (authoritative)
        snapshot = _copySnapshot(newSnap),
    }

    if type(delta) == "table" then
        payload.delta = _copyTable(delta)
    end

    -- Legacy payload field (non-contract): some tools may still look at state
    payload.state = M.getState()

    _emitUpdated(payload)

    return true, nil
end

function M.setState(newState, opts)
    newState = (type(newState) == "table") and newState or {}
    opts = (type(opts) == "table") and opts or {}

    -- Legacy setState uses players list/map; we convert it into a minimal snapshot.
    local players = _asPlayersMap(newState.players)

    local ts = os.time()
    local src = tostring(opts.source or newState.source or "setState")

    local byName = {}
    local rawLines = {}
    local rawCount = 0

    for name, v in pairs(players) do
        if v == true and type(name) == "string" and name ~= "" then
            rawCount = rawCount + 1
            rawLines[#rawLines + 1] = name
            byName[name] = {
                name = name,
                rankTag = "",
                level = nil,
                class = nil,
                flags = {},
                extraText = "",
                titleText = nil,
                rawLine = name,
            }
        end
    end

    local entries = _rebuildEntriesArrayFromByName(byName)
    local snap = _buildSnapshotFromEntries(ts, src, rawLines, entries, byName)

    local delta = { added = rawCount, removed = 0, changed = 0, total = rawCount, mode = "setState" }

    _state.rawCount = rawCount
    return _applyNewSnapshot(snap, { source = src, rawCount = rawCount }, delta)
end

function M.update(delta, opts)
    delta = (type(delta) == "table") and delta or {}
    opts = (type(opts) == "table") and opts or {}

    local beforeByName = _state.snapshot.byName or {}
    local nextByName = _copyTable(beforeByName)

    -- delta.players can be map or array
    if delta.players ~= nil then
        local addMap = _asPlayersMap(delta.players)
        for n, _ in pairs(addMap) do
            -- create minimal entry if missing
            if nextByName[n] == nil then
                nextByName[n] = {
                    name = n,
                    rankTag = "",
                    level = nil,
                    class = nil,
                    flags = {},
                    extraText = "",
                    titleText = nil,
                    rawLine = n,
                }
            end
        end
    end

    -- Optional explicit remove list: delta.remove = {"Name", ...}
    if type(delta.remove) == "table" then
        for _, v in ipairs(delta.remove) do
            local n = _normalizeNameForLegacy(tostring(v or ""))
            if n then
                nextByName[n] = nil
            end
        end
    end

    local ts = os.time()
    local src = tostring(opts.source or "update")

    local entries = _rebuildEntriesArrayFromByName(nextByName)
    local rawLines = _copyArray((_state.snapshot and _state.snapshot.rawLines) or {})
    local snap = _buildSnapshotFromEntries(ts, src, rawLines, entries, nextByName)

    local d = _computeDeltaByName(beforeByName, nextByName)
    d.mode = "update"

    -- Derive a legacy-ish rawCount
    _state.rawCount = d.total

    -- Only emit when state changed
    if d.added > 0 or d.removed > 0 or d.changed > 0 then
        return _applyNewSnapshot(snap, { source = src, rawCount = d.total }, d)
    end

    -- Still update bookkeeping (SAFE), but no emit
    _state.snapshot = snap
    _state.players = _rebuildLegacyPlayersFromSnapshot(snap)
    _state.lastUpdatedTs = os.time()
    _state.source = src
    _state.stats.updates = _state.stats.updates + 1

    return true, nil
end

function M.clear(opts)
    opts = (type(opts) == "table") and opts or {}

    local beforeTotal = _countMap(_state.snapshot.byName or {})

    local ts = os.time()
    local src = tostring(opts.source or "clear")

    local snap = _buildSnapshotFromEntries(ts, src, {}, {}, {})
    _state.rawCount = 0

    if beforeTotal > 0 then
        local delta = { added = 0, removed = beforeTotal, changed = 0, total = 0, mode = "clear" }
        return _applyNewSnapshot(snap, { source = src, rawCount = 0 }, delta)
    end

    -- No emit if already empty
    _state.snapshot = snap
    _state.players = {}
    _state.lastUpdatedTs = os.time()
    _state.source = src
    _state.stats.updates = _state.stats.updates + 1
    return true, nil
end

-- ############################################################
-- Ingestion (WHO text/lines) -> Snapshot (v1.1)
-- ############################################################

function M.ingestWhoLines(lines, opts)
    opts = (type(opts) == "table") and opts or {}
    if type(lines) ~= "table" then
        return false, "lines must be table"
    end

    -- Gate: if watcher OFF, ignore auto-capture ingests (orphan triggers safe)
    if (_state.autoCaptureEnabled ~= true) and tostring(opts.source or "") == "dwwho:auto" then
        return true, nil
    end

    _state.stats.ingests = _state.stats.ingests + 1

    local mode = (opts.merge == true) and "merge" or "replace"
    local src = tostring(opts.source or "ingestWhoLines")
    local ts = os.time()

    local rawLines = {}
    for i = 1, #lines do
        rawLines[#rawLines + 1] = tostring(lines[i] or "")
    end

    local parsedEntries = {}
    local byNameNew = {}
    local parsedCount = 0

    for i = 1, #rawLines do
        local line = rawLines[i]
        local e = _parseWhoLineToEntry(line)
        if e and type(e.name) == "string" and e.name ~= "" then
            parsedCount = parsedCount + 1
            parsedEntries[#parsedEntries + 1] = e
            byNameNew[e.name] = e -- last wins
        end
    end

    local beforeByName = (type(_state.snapshot.byName) == "table") and _state.snapshot.byName or {}
    local nextByName = {}

    if mode == "merge" then
        nextByName = _copyTable(beforeByName)
        for name, e in pairs(byNameNew) do
            nextByName[name] = e
        end
    else
        nextByName = byNameNew
    end

    local entries = _rebuildEntriesArrayFromByName(nextByName)

    local nextRawLines = rawLines
    if mode == "merge" then
        -- best-effort: keep history by concatenating previous rawLines
        local prev = (type(_state.snapshot.rawLines) == "table") and _state.snapshot.rawLines or {}
        nextRawLines = _copyArray(prev)
        for i = 1, #rawLines do
            nextRawLines[#nextRawLines + 1] = rawLines[i]
        end
    end

    local snap = _buildSnapshotFromEntries(ts, src, nextRawLines, entries, nextByName)

    local d = _computeDeltaByName(beforeByName, nextByName)
    d.mode = mode
    d.rawCount = parsedCount

    _state.rawCount = parsedCount

    if d.added > 0 or d.removed > 0 or d.changed > 0 then
        return _applyNewSnapshot(snap, { source = src, rawCount = parsedCount }, d)
    end

    -- No changes: still update snapshot bookkeeping (SAFE), but do not emit.
    _state.snapshot = snap
    _state.players = _rebuildLegacyPlayersFromSnapshot(snap)
    _state.lastUpdatedTs = os.time()
    _state.source = src
    _state.stats.updates = _state.stats.updates + 1

    return true, nil
end

function M.ingestWhoText(text, opts)
    opts = (type(opts) == "table") and opts or {}
    if type(text) ~= "string" then
        return false, "text must be string"
    end

    text = text:gsub("\r", "")
    local lines = {}

    for line in text:gmatch("([^\n]+)") do
        lines[#lines + 1] = line
    end

    return M.ingestWhoLines(lines, opts)
end

return M
