-- FILE: src/dwkit/services/roomentities_service.lua
-- #########################################################################
-- Module Name : dwkit.services.roomentities_service
-- Owner       : Services
-- Version     : v2026-02-04C
-- Purpose     :
--   - SAFE, profile-portable RoomEntitiesService (data only).
--   - No GMCP dependency, no Mudlet events, no timers, no send().
--   - Emits a registered internal event when state changes.
--   - Provides manual ingestion helpers for "look" output parsing.
--   - Classification (best-effort, SAFE):
--       - Presence-assisted classification during ingest (existing).
--       - WhoStore-assisted classification during ingest (NEW).
--       - AUTO reclassify on WhoStore updates (NEW "superpower"):
--           When WhoStore player set updates, we re-bucket current entities
--           (unknown/mobs/items -> players) when names are now known players,
--           and emit RoomEntities Updated only if state actually changes.
--
--   - FIX (v2026-02-04A):
--       - Broaden entity parsing for real-world LOOK lines:
--           * Accept "is here," in addition to "is here."
--           * Accept "is <posture> here," in addition to "is <posture> here."
--           * Conservative heuristic for lines like:
--               "A beastly fido ... here ... ."
--             Extract leading noun phrase (e.g., "A beastly fido") and bucket as
--             mobs/items (item keyword check), rather than dropping the line.
--
--   - FIX (v2026-02-04B):
--       - Recognize common item lines: "<thing> lies here." (with optional trailing tags)
--         Example:
--           "Achilles' breastplate lies here. (glowing) (damaged)"
--         These were previously ignored, causing items=0 in many rooms.
--
--   - FIX (v2026-02-04C):
--       - Recognize common encounter lines where "here" is NOT the end of line:
--           * "<thing> is here <doing something>."
--           * "<thing> is here, <doing something>..."
--           * "<thing> stands here <doing something>."
--           * "<thing> is <verb/posture> here <...>."
--         This fixes the majority of missed encounters in real movement logs.
--
--   - NEW (v2026-01-17E):
--       - Known-player prefix matching:
--           "Scynox the adventurer" becomes player "Scynox" if WhoStore knows Scynox.
--           "Borai hates ..." becomes player "Borai" if WhoStore knows Borai.
--       - Reclassify also canonicalizes keys (renames bucket entries) when prefix matches.
--
--   - NEW (v2026-01-17F):
--       - Ignore non-entity look lines:
--           room title, indented description lines, and exit direction rows.
--       - Better items classification for common room objects:
--           board/bulletin/keg/mechanism/etc => items
--
--   - FIX (v2026-01-17G):
--       - Do NOT discard indented entity lines.
--         Some clipboard/capture flows indent ALL lines.
--         If an indented line contains "is here." or "standing here.", treat as entity.
--
--   - NEW (v2026-01-17H):
--       - Support more player postures:
--           standing/sitting/sleeping/resting/kneeling/meditating.
--       - Opt-in ingestion noise filters (caller-controlled):
--           opts.ignorePatterns (Lua patterns) + opts.ignoreSubstrings (plain contains).
--
--   - FIX (v2026-01-19D):
--       - Ignore wrapped/unindented LOOK description lines.
--         Only treat lines as entity candidates when they match entity-ish patterns:
--           - "is here."
--           - "is <posture> here."
--           - contains "corpse"
--         This prevents paragraph text from being misclassified into unknown bucket.
--
--   - NEW (v2026-01-20B):
--       - Add public emitUpdated(meta) API so command surfaces can request an
--         explicit RoomEntities Updated emission without relying on eventBus fallback.
--
--   - NEW (v2026-01-20C):
--       - Add SAFE ingestFixture(opts) API for command surfaces (dwroom fixture).
--         Provides deterministic bucket seeding for UI + pipeline validation.
--
--   - FIX (v2026-01-23A):
--       - event_bus.emit() requires 3-arg signature: emit(eventName, payload, meta)
--         Without meta, emit does not deliver (verified live).
--       - _emit now passes meta and checks the ok flag (pcall success != emit success).
--
--   - NEW (v2026-01-23B):
--       - Arm WhoStore subscription automatically on setState/update/clear/emitUpdated.
--         This ensures WhoStore-driven reclassify works even if callers seed state
--         via setState() and then trigger WhoStore updates (no manual "arm" step).
--
--   - FIX (v2026-01-23C):
--       - Also arm WhoStore subscription at module load (best-effort).
--         So immediately after init(), getStats() reflects subscribed=true when available.
--
--   - NEW (v2026-01-31A):
--       - Normalize entity keys by stripping trailing parenthetical tags:
--           "a wooden board (glowing)" -> "a wooden board"
--       - Classify common object lines:
--           "<thing> hangs here ..." -> items
--           "<thing> is mounted here ..." -> items
--
--   - NEW (v2026-02-01A):
--       - Confidence gate for WhoStore/presence-assisted player classification:
--           * Case-insensitive membership is treated as a BOOST CANDIDATE only.
--           * Auto "players" classification requires an EXACT display-name match.
--           * If candidate but not exact, prefer "unknown" (safe) unless caller overrides
--             via UI override mechanism (handled in UI module).
--       - ReclassifyFromWhoStore also applies the same gate (no prefix-based promotion).
--
--   - FIX (v2026-02-01B):
--       - WhoStore Option-A legacy players map uses lowercase keys, which MUST NOT
--         be treated as canonical display names. Build known-player index from
--         WhoStore snapshot entries (entry.name) when available.
--       - If snapshot not available, legacy players map is treated as candidate-only.
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
--   - emitUpdated(meta?) -> boolean ok, string|nil err
--   - ingestFixture(opts?) -> boolean ok, string|nil err
--   - ingestLookLines(lines, opts?) -> boolean ok, string|nil err
--   - ingestLookText(text, opts?) -> boolean ok, string|nil err
--   - reclassifyFromWhoStore(opts?) -> boolean ok, string|nil err
--
-- Events Emitted:
--   - DWKit:Service:RoomEntities:Updated
-- Automation Policy: Manual only (no gameplay commands). WhoStore reclassify is event-driven.
-- Dependencies     : dwkit.core.identity, dwkit.bus.event_bus
-- #########################################################################

local M = {}

M.VERSION = "v2026-02-04C"

local ID = require("dwkit.core.identity")
local BUS = require("dwkit.bus.event_bus")

local EV_UPDATED = tostring(ID.eventPrefix or "DWKit:") .. "Service:RoomEntities:Updated"

-- Expose event name for UIs and consumers (contract)
M.EV_UPDATED = EV_UPDATED

local function _newBuckets()
    return {
        players = {},
        mobs = {},
        items = {},
        unknown = {},
    }
end

local function _ensureBucketsPresent(s)
    if type(s) ~= "table" then
        return _newBuckets()
    end
    if type(s.players) ~= "table" then s.players = {} end
    if type(s.mobs) ~= "table" then s.mobs = {} end
    if type(s.items) ~= "table" then s.items = {} end
    if type(s.unknown) ~= "table" then s.unknown = {} end
    return s
end

local STATE = {
    state = _newBuckets(),
    lastTs = nil,
    updates = 0,
    emits = 0,
    suppressedEmits = 0,
}

-- Supported player postures in "is <posture> here."
local POSTURES = {
    standing = true,
    sitting = true,
    sleeping = true,
    resting = true,
    kneeling = true,
    meditating = true,
}

local function _trim(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function _normName(s)
    s = _trim(s or "")
    if s == "" then return "" end
    return s:lower()
end

-- Strip trailing parenthetical tags like "(glowing)" "(humming)" etc.
-- Repeats to remove multiple tags at end.
local function _stripTrailingParenTags(s)
    if type(s) ~= "string" then return "" end
    local out = _trim(s)
    if out == "" then return "" end

    local changed = true
    while changed do
        changed = false
        local before = out
        out = out:gsub("%s*%b()%s*$", "")
        out = _trim(out)
        if out ~= before then
            changed = true
        end
    end

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

-- FIXED: event_bus.emit requires (eventName, payload, meta) in this DWKit environment.
-- Also: pcall success only means "no crash", not that emit succeeded. Check okEmit flag.
local function _emit(stateCopy, deltaCopy, source)
    local payload = {
        ts = os.time(),
        state = stateCopy,
    }
    if type(deltaCopy) == "table" then payload.delta = deltaCopy end
    if type(source) == "string" and source ~= "" then payload.source = source end

    local meta = {
        source = tostring(source or "RoomEntitiesService"),
        service = "dwkit.services.roomentities_service",
        ts = payload.ts,
    }

    local okCall, okEmit, delivered, errs = pcall(BUS.emit, EV_UPDATED, payload, meta)

    if okCall and okEmit == true then
        return true, nil
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

    return false, errMsg
end

-- Normalize + build a stable key for buckets.
local function _asKey(s)
    s = _stripTrailingParenTags(_trim(s or ""))
    if s == "" then return nil end
    return s
end

local function _addBucket(bucket, key)
    if type(bucket) ~= "table" then return end
    if type(key) ~= "string" or key == "" then return end
    bucket[key] = true
end

local function _bucketKeysEqual(a, b)
    if type(a) ~= "table" then a = {} end
    if type(b) ~= "table" then b = {} end

    local ca = 0
    for _ in pairs(a) do ca = ca + 1 end

    local cb = 0
    for k in pairs(b) do
        cb = cb + 1
        if a[k] ~= true then
            return false
        end
    end

    if ca ~= cb then
        return false
    end

    for k in pairs(a) do
        if b[k] ~= true then
            return false
        end
    end

    return true
end

local function _statesEqual(s1, s2)
    s1 = _ensureBucketsPresent((type(s1) == "table") and s1 or {})
    s2 = _ensureBucketsPresent((type(s2) == "table") and s2 or {})

    if not _bucketKeysEqual(s1.players, s2.players) then return false end
    if not _bucketKeysEqual(s1.mobs, s2.mobs) then return false end
    if not _bucketKeysEqual(s1.items, s2.items) then return false end
    if not _bucketKeysEqual(s1.unknown, s2.unknown) then return false end

    local known = { players = true, mobs = true, items = true, unknown = true }

    for k, v in pairs(s1) do
        if not known[k] then
            if s2[k] ~= v then return false end
        end
    end
    for k, v in pairs(s2) do
        if not known[k] then
            if s1[k] ~= v then return false end
        end
    end

    return true
end

local function _safeRequire(modName)
    local ok, mod = pcall(require, modName)
    if ok then return true, mod end
    return false, mod
end

local function _isArrayTable(t)
    if type(t) ~= "table" then return false end
    for k in pairs(t) do
        if type(k) ~= "number" then
            return false
        end
    end
    return true
end

-- ############################################################
-- Confidence gate helpers (exact display-name match required)
-- ############################################################

local function _newNameIndex()
    return {
        set = {},          -- { [lower] = true }
        canonByLower = {}, -- { [lower] = "DisplayName" }
    }
end

local function _indexAdd(idx, name)
    if type(idx) ~= "table" or type(name) ~= "string" then return end

    local canon = _asKey(name) -- trims + strips trailing paren tags
    if type(canon) ~= "string" or canon == "" then return end

    local lower = _normName(canon)
    if lower == "" then return end

    idx.set[lower] = true
    -- prefer later authoritative sources (caller controls merge order)
    idx.canonByLower[lower] = canon
end

-- candidate-only add: membership without a canonical display name
local function _indexAddLowerOnly(idx, name)
    if type(idx) ~= "table" or type(name) ~= "string" then return end
    local canon = _asKey(name)
    if type(canon) ~= "string" or canon == "" then return end
    local lower = _normName(canon)
    if lower == "" then return end
    idx.set[lower] = true
    -- intentionally NOT setting canonByLower => candidate-only
end

local function _indexMerge(dst, src)
    if type(dst) ~= "table" or type(src) ~= "table" then return end
    if type(src.set) == "table" then
        for k, v in pairs(src.set) do
            if v == true then dst.set[k] = true end
        end
    end
    if type(src.canonByLower) == "table" then
        for k, v in pairs(src.canonByLower) do
            if type(k) == "string" and type(v) == "string" and v ~= "" then
                dst.canonByLower[k] = v
            end
        end
    end
end

local function _absorbNamesToIndex(idx, t)
    if type(idx) ~= "table" or type(t) ~= "table" then return end

    if _isArrayTable(t) then
        for _, v in ipairs(t) do
            if type(v) == "string" then
                _indexAdd(idx, v)
            elseif type(v) == "table" and type(v.name) == "string" then
                _indexAdd(idx, v.name)
            end
        end
        return
    end

    for k, v in pairs(t) do
        if type(k) == "string" then
            if v == true then
                _indexAdd(idx, k)
            elseif type(v) == "string" then
                _indexAdd(idx, v)
            elseif type(v) == "table" then
                if type(v.name) == "string" then
                    _indexAdd(idx, v.name)
                end
            end
        elseif type(v) == "string" then
            _indexAdd(idx, v)
        elseif type(v) == "table" and type(v.name) == "string" then
            _indexAdd(idx, v.name)
        end
    end
end

-- returns "exact" | "candidate" | "none"
local function _confidenceForName(name, idx)
    if type(name) ~= "string" then return "none" end
    idx = (type(idx) == "table") and idx or _newNameIndex()

    local canon = _asKey(name)
    if type(canon) ~= "string" or canon == "" then
        return "none"
    end

    local lower = _normName(canon)
    if lower == "" then
        return "none"
    end

    if idx.set[lower] ~= true then
        return "none"
    end

    local expected = idx.canonByLower[lower]
    if type(expected) == "string" and expected ~= "" then
        if expected == canon then
            return "exact"
        end
        return "candidate"
    end

    -- no canonical known; treat as candidate only
    return "candidate"
end

-- ############################################################
-- Presence / WhoStore known player extraction (index form)
-- ############################################################

local function _extractKnownPlayersIndexFromPresenceState(pState)
    local idx = _newNameIndex()
    if type(pState) ~= "table" then
        return idx
    end

    _absorbNamesToIndex(idx, pState)

    local keys = { "players", "nearby", "present", "who", "names", "list" }
    for _, k in ipairs(keys) do
        local v = pState[k]
        if type(v) == "table" then
            _absorbNamesToIndex(idx, v)
        end
    end

    return idx
end

local function _getPresenceKnownPlayersIndexBestEffort(opts)
    opts = (type(opts) == "table") and opts or {}

    if type(opts.knownPlayers) == "table" then
        local idx = _newNameIndex()
        _absorbNamesToIndex(idx, opts.knownPlayers)
        return idx
    end

    if opts.usePresence ~= nil and opts.usePresence ~= true then
        return _newNameIndex()
    end

    local okP, P = _safeRequire("dwkit.services.presence_service")
    if not okP or type(P) ~= "table" then
        return _newNameIndex()
    end

    if type(P.getState) ~= "function" then
        return _newNameIndex()
    end

    local okS, pState = pcall(P.getState)
    if not okS or type(pState) ~= "table" then
        return _newNameIndex()
    end

    return _extractKnownPlayersIndexFromPresenceState(pState)
end

local function _extractKnownPlayersIndexFromWhoStoreState(wState)
    local idx = _newNameIndex()
    if type(wState) ~= "table" then
        return idx
    end

    -- Prefer docs-first snapshot entries which preserve display-case (entry.name).
    -- This avoids treating WhoStore Option-A lowercase legacy players map as canonical.
    do
        local snap = wState.snapshot
        if type(snap) ~= "table" and type(wState.byName) == "table" then
            -- caller might have passed a snapshot directly
            snap = wState
        end

        if type(snap) == "table" and type(snap.byName) == "table" then
            for _, e in pairs(snap.byName) do
                if type(e) == "table" and type(e.name) == "string" and e.name ~= "" then
                    _indexAdd(idx, e.name)
                end
            end
            return idx
        end

        if type(snap) == "table" and type(snap.entries) == "table" then
            for i = 1, #snap.entries do
                local e = snap.entries[i]
                if type(e) == "table" and type(e.name) == "string" and e.name ~= "" then
                    _indexAdd(idx, e.name)
                end
            end
            if next(idx.set) ~= nil then
                return idx
            end
        end
    end

    -- Fallback: legacy players map may only contain lowercase canonical keys.
    -- Treat as membership-only (candidate), not canonical display-name exact.
    if type(wState.players) == "table" then
        for k, v in pairs(wState.players) do
            if v == true and type(k) == "string" and k ~= "" then
                _indexAddLowerOnly(idx, k)
            end
        end
        return idx
    end

    -- Last resort: if someone passed a plain list/map of names, absorb normally.
    _absorbNamesToIndex(idx, wState)
    return idx
end

local function _getWhoStoreKnownPlayersIndexBestEffort()
    local okW, W = _safeRequire("dwkit.services.whostore_service")
    if not okW or type(W) ~= "table" then
        return _newNameIndex()
    end
    if type(W.getState) ~= "function" then
        return _newNameIndex()
    end

    local okS, wState = pcall(W.getState)
    if not okS or type(wState) ~= "table" then
        return _newNameIndex()
    end

    return _extractKnownPlayersIndexFromWhoStoreState(wState)
end

local function _getKnownPlayersIndexCombined(opts)
    opts = (type(opts) == "table") and opts or {}

    if type(opts.knownPlayers) == "table" then
        local idx = _newNameIndex()
        _absorbNamesToIndex(idx, opts.knownPlayers)
        return idx
    end

    local idx = _newNameIndex()

    -- Merge order matters: Presence first, then WhoStore overrides canonical names.
    if opts.usePresence == nil or opts.usePresence == true then
        local pIdx = _getPresenceKnownPlayersIndexBestEffort(opts)
        _indexMerge(idx, pIdx)
    end

    if opts.useWhoStore == nil or opts.useWhoStore == true then
        local wIdx = _getWhoStoreKnownPlayersIndexBestEffort()
        _indexMerge(idx, wIdx)
    end

    return idx
end

local function _looksLikeExitRow(lineLower)
    if type(lineLower) ~= "string" then return false end
    return (lineLower:match("^(north|south|east|west|up|down)%s+%-%s+") ~= nil)
end

local function _looksLikeRoomTitle(line)
    if type(line) ~= "string" then return false end
    if line:find("%.") then return false end
    if #line > 60 then return false end
    if line:match("^%s+") then return false end
    if line:lower():find(" is here") or line:lower():find("standing here") then return false end
    if line:lower():find("^obvious exits:") then return false end
    if line:lower():find("^exits:") then return false end

    if line:match("^[%a%s']+$") then
        return true
    end
    return false
end

local function _isProbablyItemPhrase(phraseLower)
    if type(phraseLower) ~= "string" then return false end

    local itemKeys = {
        "board", "bulletin", "announcement", "keg", "mechanism", "altar",
        "portal", "sign", "plaque", "statue", "fountain", "table", "chair",
        "bench", "door", "gate", "lever", "switch", "chest", "bag",
        "scroll", "potion", "sword", "shield", "corpse",
        "breastplate", "helmet", "armor", "armour", "gauntlet", "greave",
        "boot", "cloak", "ring", "amulet", "necklace", "bracelet",
    }

    for _, k in ipairs(itemKeys) do
        if phraseLower:find(k, 1, true) then
            return true
        end
    end

    return false
end

local function _isEntityishPostureLine(lowerTrimmed)
    if type(lowerTrimmed) ~= "string" then return false end

    -- accept "is here," / "is here." / "is here <more...>"
    if lowerTrimmed:match("^.-%s+is%s+here[%s,%.]") ~= nil then
        return true
    end

    -- accept "stands here <...>"
    if lowerTrimmed:match("^.-%s+stands%s+here[%s,%.]") ~= nil then
        return true
    end

    -- accept "is <word> here," / "is <word> here." / "is <word> here <more...>"
    local w = lowerTrimmed:match("^.-%s+is%s+(%a+)%s+here[%s,%.]")
    if type(w) == "string" and w ~= "" then
        return true
    end

    return false
end

local function _shouldIgnoreByCallerRules(trimmed, opts)
    opts = (type(opts) == "table") and opts or {}
    if type(trimmed) ~= "string" or trimmed == "" then
        return false
    end

    if type(opts.ignoreSubstrings) == "table" then
        for _, sub in ipairs(opts.ignoreSubstrings) do
            if type(sub) == "string" and sub ~= "" then
                if trimmed:find(sub, 1, true) ~= nil then
                    return true
                end
            end
        end
    end

    if type(opts.ignorePatterns) == "table" then
        for _, pat in ipairs(opts.ignorePatterns) do
            if type(pat) == "string" and pat ~= "" then
                local okMatch, res = pcall(function()
                    return (trimmed:match(pat) ~= nil)
                end)
                if okMatch and res == true then
                    return true
                end
            end
        end
    end

    return false
end

local function _classifyLookLine(line, opts, knownPlayersIdx)
    opts = (type(opts) == "table") and opts or {}
    if type(line) ~= "string" then return nil, nil end

    local rawLine = line
    local trimmed = _trim(line)
    if trimmed == "" then return nil, nil end

    if _shouldIgnoreByCallerRules(trimmed, opts) then
        return nil, nil
    end

    local lowerTrimmed = trimmed:lower()

    if rawLine:match("^%s%s%s+") then
        local isEntityish = _isEntityishPostureLine(lowerTrimmed)
        if not isEntityish then
            return nil, nil
        end
    end

    local lineClean = trimmed
    local lower = lowerTrimmed

    if lower == "you see nothing special." then return nil, nil end
    if lower:find("^exits:") then return nil, nil end
    if lower:find("^obvious exits:") then return nil, nil end
    if _looksLikeExitRow(lower) then return nil, nil end

    if lower == "huh?!?" then return nil, nil end
    if lower == "you are hungry." then return nil, nil end
    if lower == "you are thirsty." then return nil, nil end

    if _looksLikeRoomTitle(lineClean) then
        return nil, nil
    end

    -- "<thing> hangs here ..." -> items
    do
        local phrase = lineClean:match("^(.-)%s+hangs%s+here")
        if type(phrase) == "string" then
            phrase = _trim(phrase)
            if phrase ~= "" then
                return "items", _asKey(phrase)
            end
        end
    end

    -- "<thing> is mounted here ..." -> items
    do
        local phrase = lineClean:match("^(.-)%s+is%s+mounted%s+here")
        if type(phrase) == "string" then
            phrase = _trim(phrase)
            if phrase ~= "" then
                return "items", _asKey(phrase)
            end
        end
    end

    -- FIX (v2026-02-04B): "<thing> lies here." -> items
    do
        local phrase = lineClean:match("^(.-)%s+lies%s+here[%,%.]")
        if type(phrase) == "string" then
            phrase = _trim(phrase)
            if phrase ~= "" then
                return "items", _asKey(phrase)
            end
        end
    end

    -- NEW (v2026-02-04C): "<thing> stands here ..." (with any trailing text)
    do
        local phrase = lineClean:match("^(.-)%s+stands%s+here[%s,%.]")
        if type(phrase) == "string" then
            phrase = _trim(phrase)
            if phrase ~= "" then
                local conf = _confidenceForName(phrase, knownPlayersIdx)
                if conf == "exact" then
                    return "players", _asKey(phrase)
                end
                if conf == "candidate" then
                    return "unknown", _asKey(phrase)
                end

                if lower:find("corpse") then
                    return "items", _asKey(phrase)
                end

                local pLower = phrase:lower()
                if pLower:match("^(a%s+)") or pLower:match("^(an%s+)") or pLower:match("^(the%s+)") then
                    if _isProbablyItemPhrase(pLower) then
                        return "items", _asKey(phrase)
                    end
                    return "mobs", _asKey(phrase)
                end

                return "unknown", _asKey(phrase)
            end
        end
    end

    -- posture-ish / verb-ish line: "X is <word> here ..." (comma/period/space after here)
    do
        local phrase, posture = lineClean:match("^(.-)%s+is%s+(%a+)%s+here[%s,%.]")
        if type(phrase) == "string" and type(posture) == "string" then
            phrase = _trim(phrase)
            posture = posture:lower()
            if phrase ~= "" then
                local conf = _confidenceForName(phrase, knownPlayersIdx)
                if conf == "exact" then
                    return "players", _asKey(phrase)
                end
                if conf == "candidate" then
                    return "unknown", _asKey(phrase)
                end

                if lower:find("corpse") then
                    return "items", _asKey(phrase)
                end

                -- If it looks like a normal player posture, still prefer unknown unless known.
                -- For non-postures (grazing/floating/etc), treat as mob/item/unknown by heuristics.
                local pLower = phrase:lower()
                if pLower:match("^(a%s+)") or pLower:match("^(an%s+)") or pLower:match("^(the%s+)") then
                    if _isProbablyItemPhrase(pLower) then
                        return "items", _asKey(phrase)
                    end
                    return "mobs", _asKey(phrase)
                end

                if opts.assumeCapitalizedAsPlayer == true and POSTURES[posture] == true then
                    local first = phrase:sub(1, 1)
                    if first:match("%u") then
                        return "players", _asKey(phrase)
                    end
                end

                return "unknown", _asKey(phrase)
            end
        end
    end

    -- "X is here ..." (with any trailing text)
    do
        local phrase = lineClean:match("^(.-)%s+is%s+here[%s,%.]")
        if type(phrase) == "string" then
            phrase = _trim(phrase)
            if phrase ~= "" then
                local conf = _confidenceForName(phrase, knownPlayersIdx)
                if conf == "exact" then
                    return "players", _asKey(phrase)
                end
                if conf == "candidate" then
                    return "unknown", _asKey(phrase)
                end

                if lower:find("corpse") then
                    return "items", _asKey(phrase)
                end

                local pLower = phrase:lower()

                if pLower:match("^(a%s+)") or pLower:match("^(an%s+)") or pLower:match("^(the%s+)") then
                    if _isProbablyItemPhrase(pLower) then
                        return "items", _asKey(phrase)
                    end
                    return "mobs", _asKey(phrase)
                end

                return "unknown", _asKey(phrase)
            end
        end
    end

    -- Conservative: "A/An/The <noun> ... here ... ."
    do
        if not lower:find("%sis%s", 1, true) then
            if (lower:match("^(a%s+)") or lower:match("^(an%s+)") or lower:match("^(the%s+)")) and lower:find("%shere%s", 1, true) and lower:match("%.%s*$") then
                local noun = lineClean:match("^(An?%s+.-)%s+%a+%s")
                if type(noun) ~= "string" or noun == "" then
                    noun = lineClean:match("^(The%s+.-)%s+%a+%s")
                end
                noun = _trim(noun or "")
                if noun ~= "" then
                    local nLower = noun:lower()
                    if _isProbablyItemPhrase(nLower) then
                        return "items", _asKey(noun)
                    end
                    return "mobs", _asKey(noun)
                end
            end
        end
    end

    if lower:find("corpse") then
        return "items", _asKey(lineClean)
    end

    if _isEntityishPostureLine(lower) then
        return "unknown", _asKey(lineClean)
    end

    return nil, nil
end

-- ############################################################
-- WhoStore "superpower" wiring (SAFE)
-- ############################################################

local _who = {
    subscribed = false,
    token = nil,
    eventName = nil,
    lastErr = nil,
    reclassifyRunning = false,
}

local function _resolveWhoStoreUpdatedEventName(W)
    if type(W) ~= "table" then return nil end
    if type(W.getUpdatedEventName) == "function" then
        local ok, v = pcall(W.getUpdatedEventName)
        if ok and type(v) == "string" and v ~= "" then
            return v
        end
    end
    if type(W.EV_UPDATED) == "string" and W.EV_UPDATED ~= "" then
        return W.EV_UPDATED
    end
    return nil
end

local function _reclassifyBucketsWithKnownPlayers(current, knownIdx)
    current = _ensureBucketsPresent((type(current) == "table") and current or {})
    knownIdx = (type(knownIdx) == "table") and knownIdx or _newNameIndex()

    local next = _newBuckets()

    local moved = 0

    local function placeName(originalBucket, name)
        if type(name) ~= "string" or name == "" then return end

        local conf = _confidenceForName(name, knownIdx)

        if conf == "exact" then
            next.players[name] = true
            moved = moved + 1
            return
        end

        if conf == "candidate" then
            next.unknown[name] = true
            return
        end

        if originalBucket == "players" then
            next.unknown[name] = true
        elseif originalBucket == "mobs" then
            next.mobs[name] = true
        elseif originalBucket == "items" then
            next.items[name] = true
        else
            next.unknown[name] = true
        end
    end

    for k, v in pairs(current.players) do
        if v == true and type(k) == "string" and k ~= "" then
            placeName("players", k)
        end
    end

    for k, v in pairs(current.unknown) do
        if v == true and type(k) == "string" and k ~= "" then
            placeName("unknown", k)
        end
    end

    for k, v in pairs(current.mobs) do
        if v == true and type(k) == "string" and k ~= "" then
            placeName("mobs", k)
        end
    end

    for k, v in pairs(current.items) do
        if v == true and type(k) == "string" and k ~= "" then
            placeName("items", k)
        end
    end

    return next, moved
end

local function _applyReclassifyNow(opts)
    opts = (type(opts) == "table") and opts or {}

    if _who.reclassifyRunning == true then
        return true, nil
    end

    _who.reclassifyRunning = true

    local knownIdx = _getWhoStoreKnownPlayersIndexBestEffort()
    local before = _copyOneLevel(_ensureBucketsPresent(STATE.state))

    local next, moved = _reclassifyBucketsWithKnownPlayers(before, knownIdx)

    if opts.forceEmit ~= true and _statesEqual(before, next) then
        STATE.suppressedEmits = STATE.suppressedEmits + 1
        _who.reclassifyRunning = false
        return true, nil
    end

    STATE.state = _copyOneLevel(_ensureBucketsPresent(next))
    STATE.lastTs = os.time()
    STATE.updates = STATE.updates + 1

    local src = tostring(opts.source or "reclassify:whostore")
    local delta = { reclassified = moved }

    local okEmit, errEmit = _emit(_copyOneLevel(STATE.state), delta, src)
    if not okEmit then
        _who.reclassifyRunning = false
        return false, errEmit
    end

    STATE.emits = STATE.emits + 1
    _who.reclassifyRunning = false
    return true, nil
end

local function _ensureWhoStoreSubscription()
    if _who.subscribed == true then
        return true, nil
    end

    if type(BUS) ~= "table" or type(BUS.on) ~= "function" then
        _who.lastErr = "event bus .on not available"
        return false, _who.lastErr
    end

    local okW, W = _safeRequire("dwkit.services.whostore_service")
    if not okW or type(W) ~= "table" then
        _who.lastErr = "WhoStoreService not available"
        return false, _who.lastErr
    end

    local evName = _resolveWhoStoreUpdatedEventName(W)
    if type(evName) ~= "string" or evName == "" then
        _who.lastErr = "WhoStore updated event name not available"
        return false, _who.lastErr
    end

    local handlerFn = function(payload)
        _applyReclassifyNow({ source = "whostore:updated" })
    end

    local okSub, tokenOrErr, maybeErr = BUS.on(evName, handlerFn)
    if okSub ~= true then
        _who.lastErr = tostring(maybeErr or tokenOrErr or "WhoStore subscribe failed")
        return false, _who.lastErr
    end

    _who.subscribed = true
    _who.token = tokenOrErr
    _who.eventName = evName
    _who.lastErr = nil
    return true, nil
end

local function _armWhoStoreSubscriptionBestEffort()
    local ok, err = _ensureWhoStoreSubscription()
    if ok ~= true then
        _who.lastErr = tostring(err or _who.lastErr or "WhoStore subscribe failed")
    end
end

function M.getVersion()
    return tostring(M.VERSION)
end

function M.getUpdatedEventName()
    return tostring(EV_UPDATED)
end

function M.getState()
    return _copyOneLevel(_ensureBucketsPresent(STATE.state))
end

function M.emitUpdated(meta)
    meta = (type(meta) == "table") and meta or {}

    _armWhoStoreSubscriptionBestEffort()

    local source = nil
    if type(meta.source) == "string" and meta.source ~= "" then
        source = meta.source
    end

    local delta = _copyOneLevel(meta)
    delta.source = nil
    delta.ts = nil
    delta.state = nil
    delta.delta = nil

    local hasAny = false
    for _ in pairs(delta) do
        hasAny = true
        break
    end
    if not hasAny then
        delta = nil
    end

    local okEmit, errEmit = _emit(_copyOneLevel(_ensureBucketsPresent(STATE.state)), delta, source)
    if not okEmit then
        return false, errEmit
    end

    STATE.emits = STATE.emits + 1
    return true, nil
end

function M.ingestFixture(opts)
    opts = (type(opts) == "table") and opts or {}

    _ensureWhoStoreSubscription()

    local function absorb(dstSet, t)
        if type(dstSet) ~= "table" then return end
        if type(t) ~= "table" then return end

        if _isArrayTable(t) then
            for _, v in ipairs(t) do
                if type(v) == "string" and v ~= "" then
                    dstSet[v] = true
                elseif type(v) == "table" and type(v.name) == "string" and v.name ~= "" then
                    dstSet[v.name] = true
                end
            end
            return
        end

        for k, v in pairs(t) do
            if type(k) == "string" and k ~= "" then
                if v == true then
                    dstSet[k] = true
                elseif type(v) == "string" and v ~= "" then
                    dstSet[v] = true
                elseif type(v) == "table" and type(v.name) == "string" and v.name ~= "" then
                    dstSet[v.name] = true
                end
            elseif type(v) == "string" and v ~= "" then
                dstSet[v] = true
            elseif type(v) == "table" and type(v.name) == "string" and v.name ~= "" then
                dstSet[v.name] = true
            end
        end
    end

    local buckets = _newBuckets()

    buckets.players["FixturePlayer"] = true
    buckets.mobs["a fixture goblin"] = true
    buckets.items["a fixture chest"] = true
    buckets.unknown["Mysterious figure"] = true

    if type(opts.players) == "table" then
        buckets.players = {}
        absorb(buckets.players, opts.players)
    end
    if type(opts.mobs) == "table" then
        buckets.mobs = {}
        absorb(buckets.mobs, opts.mobs)
    end
    if type(opts.items) == "table" then
        buckets.items = {}
        absorb(buckets.items, opts.items)
    end
    if type(opts.unknown) == "table" then
        buckets.unknown = {}
        absorb(buckets.unknown, opts.unknown)
    end

    local src = tostring(opts.source or "fixture:roomentities")
    return M.setState(buckets, { source = src, forceEmit = (opts.forceEmit == true) })
end

function M.setState(newState, opts)
    opts = (type(opts) == "table") and opts or {}
    if type(newState) ~= "table" then
        return false, "setState(newState): newState must be a table"
    end

    _armWhoStoreSubscriptionBestEffort()

    local nextState = _copyOneLevel(newState)
    nextState = _ensureBucketsPresent(nextState)

    local before = _ensureBucketsPresent(STATE.state)

    if opts.forceEmit ~= true and _statesEqual(before, nextState) then
        STATE.suppressedEmits = STATE.suppressedEmits + 1
        return true, nil
    end

    STATE.state = nextState
    STATE.lastTs = os.time()
    STATE.updates = STATE.updates + 1

    local okEmit, errEmit = _emit(_copyOneLevel(STATE.state), nil, opts.source)
    if not okEmit then
        return false, errEmit
    end

    STATE.emits = STATE.emits + 1
    return true, nil
end

function M.update(delta, opts)
    opts = (type(opts) == "table") and opts or {}
    if type(delta) ~= "table" then
        return false, "update(delta): delta must be a table"
    end

    _armWhoStoreSubscriptionBestEffort()

    STATE.state = _ensureBucketsPresent(STATE.state)

    local before = _copyOneLevel(STATE.state)

    _merge(STATE.state, delta)
    STATE.state = _ensureBucketsPresent(STATE.state)

    local after = _copyOneLevel(STATE.state)

    if opts.forceEmit ~= true and _statesEqual(before, after) then
        STATE.suppressedEmits = STATE.suppressedEmits + 1
        return true, nil
    end

    STATE.lastTs = os.time()
    STATE.updates = STATE.updates + 1

    local okEmit, errEmit = _emit(_copyOneLevel(STATE.state), _copyOneLevel(delta), opts.source)
    if not okEmit then
        return false, errEmit
    end

    STATE.emits = STATE.emits + 1
    return true, nil
end

function M.clear(opts)
    opts = (type(opts) == "table") and opts or {}

    _armWhoStoreSubscriptionBestEffort()

    STATE.state = _ensureBucketsPresent(STATE.state)
    local before = _copyOneLevel(STATE.state)

    STATE.state = _newBuckets()
    local after = _copyOneLevel(STATE.state)

    if opts.forceEmit ~= true and _statesEqual(before, after) then
        STATE.suppressedEmits = STATE.suppressedEmits + 1
        return true, nil
    end

    STATE.lastTs = os.time()
    STATE.updates = STATE.updates + 1

    local okEmit, errEmit = _emit(_copyOneLevel(STATE.state), { cleared = true }, opts.source)
    if not okEmit then
        return false, errEmit
    end

    STATE.emits = STATE.emits + 1
    return true, nil
end

function M.onUpdated(handlerFn)
    return BUS.on(EV_UPDATED, handlerFn)
end

function M.reclassifyFromWhoStore(opts)
    opts = (type(opts) == "table") and opts or {}
    _ensureWhoStoreSubscription()
    return _applyReclassifyNow({ source = opts.source or "manual:reclassify", forceEmit = (opts.forceEmit == true) })
end

function M.ingestLookLines(lines, opts)
    opts = (type(opts) == "table") and opts or {}
    if type(lines) ~= "table" then
        return false, "ingestLookLines(lines): lines must be a table"
    end

    _ensureWhoStoreSubscription()

    local knownPlayersIdx = _getKnownPlayersIndexCombined(opts)
    local buckets = _newBuckets()

    for _, raw in ipairs(lines) do
        local bucketName, key = _classifyLookLine(raw, opts, knownPlayersIdx)
        if bucketName and key then
            _addBucket(buckets[bucketName], key)
        end
    end

    return M.setState(buckets, { source = opts.source or "ingestLookLines", forceEmit = (opts.forceEmit == true) })
end

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
    local s = _ensureBucketsPresent(STATE.state)

    return {
        version = M.VERSION,
        lastTs = STATE.lastTs,
        updates = STATE.updates,
        emits = STATE.emits,
        suppressedEmits = STATE.suppressedEmits,
        keys = (function()
            local n = 0
            for _ in pairs(s) do n = n + 1 end
            return n
        end)(),
        who = {
            subscribed = (_who.subscribed == true),
            eventName = _who.eventName,
            hasToken = (_who.token ~= nil),
            lastErr = _who.lastErr,
        },
    }
end

-- Arm subscription at module load (best-effort) so init() immediately reflects subscribed=true
-- when WhoStore + BUS are available.
_armWhoStoreSubscriptionBestEffort()

return M

-- END FILE: src/dwkit/services/roomentities_service.lua
