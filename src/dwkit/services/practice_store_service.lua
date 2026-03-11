-- #########################################################################
-- Module Name : dwkit.services.practice_store_service
-- Owner       : Services
-- Version     : v2026-03-11B
-- Purpose     :
--   - Provide a SAFE, manual-only practice text snapshot store (No-GMCP).
--   - Ingest practice-like text via explicit API calls (no send(), no timers).
--   - Store latest snapshot in memory.
--   - Manual-only persistence using DWKit.persist.store (writes only on ingest/clear/wipe).
--   - Emit a namespaced update event when snapshot changes.
--   - Provide deterministic fixtures + a tolerant parser for practice variants.
--   - Provide SAFE query helpers for ActionPad gating (learned / unknown-stale).
--   - Provide best-effort CPC fallback publish when PracticeStore update event
--     subscription is unavailable in the current runtime.
--
-- Public API  :
--   - getVersion() -> string
--   - getUpdatedEventName() -> string
--   - getSnapshot() -> table|nil
--   - getHistory() -> table (array; shallow-copied; oldest->newest)
--   - configurePersistence(opts) -> boolean ok, string|nil err
--       opts:
--         - enabled: boolean (default true in this build)
--         - relPath: string (default "services/practice_store/history.tbl")
--         - maxEntries: number (default 50; min 1; max 500)
--         - loadExisting: boolean (default true when enabling)
--   - getPersistenceStatus() -> table (SAFE diagnostics)
--   - ingestFromText(text, meta?) -> boolean ok, string|nil err
--   - clear(meta?) -> boolean ok, string|nil err
--       NOTE: clears snapshot only (history preserved)
--   - wipe(meta?) -> boolean ok, string|nil err
--       meta:
--         - source: string (default "manual")
--         - deleteFile: boolean (optional) if true, attempts store.delete(relPath)
--   - printSummary() -> nil (SAFE helper output)
--   - getFixture(name?) -> (ok:boolean, text:string|nil, err:string|nil)
--   - ingestFixture(name?, meta?) -> boolean ok, string|nil err
--   - selfTestPersistenceSmoke(opts?) -> boolean ok, string|nil err (SAFE; test-only)
--
--   -- Bucket B gating helpers (SAFE, data-only):
--   - normalizePracticeKey(raw) -> string|nil key, string|nil err
--   - getLearnStatus(kind, practiceKey) -> table status
--       status fields:
--         - ok:boolean
--         - kind:string
--         - practiceKey:string
--         - hasSnapshot:boolean
--         - hasParsed:boolean
--         - learned:boolean
--         - tier:string|nil
--         - cost:number|nil
--         - percent:number|nil
--         - reason:string|nil  ("unknown_stale" | "not_learned" | "not_listed" | "ok")
--         - snapshotTs:number|nil
--         - snapshotSource:string|nil
--
-- Events Emitted :
--   - DWKit:Service:PracticeStore:Updated
--     payload: { ts=number, snapshot=table, source=string|nil }
--
-- Events Consumed  : None
-- Persistence      :
--   - ENABLED by default (startup load best-effort; writes only on ingest/clear/wipe).
--   - relPath: <DataFolderName>/<relPath> (default: dwkit/services/practice_store/history.tbl)
--   - envelope schemaVersion: "v0.1"
--   - envelope data:
--     - snapshot: table|nil
--     - history:  array of snapshot tables (bounded)
-- Automation Policy: Manual only (Passive capture triggers ingest; no commands sent)
-- Dependencies     :
--   - dwkit.core.identity
--   - optional best-effort persist via DWKit.persist.store
--   - optional best-effort CPC fallback via dwkit.services.cross_profile_comm_service
-- #########################################################################

local M = {}

M.VERSION = "v2026-03-11B"

local ID = require("dwkit.core.identity")

local PREFIX = tostring(ID.eventPrefix or "DWKit:")
local EV_UPDATED = PREFIX .. "Service:PracticeStore:Updated"

local SCHEMA_VERSION = 1

local _snapshot = nil
local _history = {} -- array of snapshots, oldest -> newest

-- persistence (writes only on ingest/clear/wipe; startup may load)
local _persist = {
    enabled = true, -- enabled by default (manual-only writes)
    schemaVersion = "v0.1",
    relPath = "services/practice_store/history.tbl",
    maxEntries = 50,
    lastSaveOk = nil,
    lastSaveErr = nil,
    lastSaveTs = nil,
    lastLoadOk = nil,
    lastLoadErr = nil,
    lastLoadTs = nil,
}

-- -------------------------
-- Output helper (copy/paste friendly)
-- -------------------------
local function _out(line)
    line = tostring(line or "")
    if type(cecho) == "function" then
        cecho(line .. "\n")
    elseif type(echo) == "function" then
        echo(line .. "\n")
    else
        print(line)
    end
end

local function _isNonEmptyString(s)
    return type(s) == "string" and s ~= ""
end

local function _safeRequire(modName)
    local ok, mod = pcall(require, modName)
    if ok then return true, mod end
    return false, mod
end

local function _notifyCrossProfilePublisherFallback(source)
    local okC, C = _safeRequire("dwkit.services.cross_profile_comm_service")
    if not okC or type(C) ~= "table" then return end

    if type(C.isInstalled) == "function" and C.isInstalled() ~= true then
        return
    end

    local hasPracticeSub = false
    if type(C.getStats) == "function" then
        local ok, st = pcall(C.getStats)
        if ok and type(st) == "table" and type(st.publisher) == "table" then
            hasPracticeSub = (st.publisher.hasPracticeSub == true)
        end
    end

    if hasPracticeSub == true then
        return
    end

    if type(C.publishLocalRowFacts) == "function" then
        pcall(C.publishLocalRowFacts, {
            source = tostring(source or "practice_store:fallback_publish"),
        })
    end
end

local function _shallowCopy(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do out[k] = v end
    return out
end

local function _copySnapshot(s)
    if type(s) ~= "table" then return nil end
    local c = _shallowCopy(s)
    if type(c.parsed) == "table" then
        c.parsed = _shallowCopy(c.parsed)
        -- deep-ish copy for section tables
        local function copyMap(m)
            if type(m) ~= "table" then return nil end
            local out2 = {}
            for k, v in pairs(m) do
                if type(v) == "table" then
                    out2[k] = _shallowCopy(v)
                else
                    out2[k] = v
                end
            end
            return out2
        end
        c.parsed.skills = copyMap(c.parsed.skills) or {}
        c.parsed.spells = copyMap(c.parsed.spells) or {}
        c.parsed.raceSkills = copyMap(c.parsed.raceSkills) or {}
        c.parsed.weaponProfs = copyMap(c.parsed.weaponProfs) or {}
    end
    return c
end

local function _copyHistory(hist)
    if type(hist) ~= "table" then return {} end
    local out2 = {}
    for i = 1, #hist do
        out2[i] = _copySnapshot(hist[i])
    end
    return out2
end

local function _emitUpdated(snapshot, source)
    local DW = (type(_G.DWKit) == "table") and _G.DWKit or nil
    local eb = (DW and type(DW.bus) == "table") and DW.bus.eventBus or nil
    if type(eb) == "table" and type(eb.emit) == "function" then
        local payload = {
            ts = os.time(),
            snapshot = _copySnapshot(snapshot),
            source = source,
        }
        pcall(eb.emit, EV_UPDATED, payload) -- SAFE best-effort; never crash
    end
end

local function _clampMaxEntries(n)
    n = tonumber(n or _persist.maxEntries) or _persist.maxEntries
    if n < 1 then n = 1 end
    if n > 500 then n = 500 end
    return math.floor(n)
end

local function _fmtTs(ts)
    if type(ts) ~= "number" then return "(none)" end
    local ok, s = pcall(os.date, "%Y-%m-%d %H:%M:%S", ts)
    if ok and _isNonEmptyString(s) then
        return tostring(ts) .. " (" .. s .. ")"
    end
    return tostring(ts)
end

local function _getPersistPaths()
    -- Preferred: attached surface from loader (DWKit.persist.paths)
    local DW = (type(_G.DWKit) == "table") and _G.DWKit or nil
    local p = (DW and type(DW.persist) == "table") and DW.persist.paths or nil
    if type(p) == "table" and type(p.getDataDir) == "function" then
        return true, p, nil
    end

    -- Fallback: direct require (still SAFE)
    local ok, modOrErr = pcall(require, "dwkit.persist.paths")
    if ok and type(modOrErr) == "table" and type(modOrErr.getDataDir) == "function" then
        return true, modOrErr, nil
    end

    return false, nil, "persist paths not available"
end

local function _getPersistStore()
    -- Preferred: attached surface from loader (DWKit.persist.store)
    local DW = (type(_G.DWKit) == "table") and _G.DWKit or nil
    local s = (DW and type(DW.persist) == "table") and DW.persist.store or nil
    if type(s) == "table" and type(s.saveEnvelope) == "function" and type(s.loadEnvelope) == "function" then
        return true, s, nil
    end

    -- Fallback: direct require (still SAFE)
    local ok, modOrErr = pcall(require, "dwkit.persist.store")
    if ok and type(modOrErr) == "table" and type(modOrErr.saveEnvelope) == "function" and type(modOrErr.loadEnvelope) == "function" then
        return true, modOrErr, nil
    end

    return false, nil, "persist store not available"
end

local function _persistSave(source)
    if not _persist.enabled then
        return true, nil
    end

    local okStore, store, err = _getPersistStore()
    if not okStore then
        _persist.lastSaveOk = false
        _persist.lastSaveErr = tostring(err)
        _persist.lastSaveTs = os.time()
        return false, _persist.lastSaveErr
    end

    local data = {
        snapshot = _copySnapshot(_snapshot),
        history = _copyHistory(_history),
    }

    local meta = {
        source = source or "manual",
        service = "dwkit.services.practice_store_service",
    }

    local ok, saveErr = store.saveEnvelope(_persist.relPath, _persist.schemaVersion, data, meta)
    _persist.lastSaveOk = ok
    _persist.lastSaveErr = saveErr
    _persist.lastSaveTs = os.time()

    return ok, saveErr
end

local function _persistLoad()
    local okStore, store, err = _getPersistStore()
    if not okStore then
        _persist.lastLoadOk = false
        _persist.lastLoadErr = tostring(err)
        _persist.lastLoadTs = os.time()
        return false, _persist.lastLoadErr
    end

    local ok, env, loadErr = store.loadEnvelope(_persist.relPath)
    _persist.lastLoadOk = ok
    _persist.lastLoadErr = loadErr
    _persist.lastLoadTs = os.time()

    if not ok then
        return false, loadErr
    end

    if type(env) ~= "table" or type(env.data) ~= "table" then
        return false, "persist envelope invalid"
    end

    local snap = env.data.snapshot
    local hist = env.data.history

    if snap ~= nil and type(snap) ~= "table" then
        return false, "persist snapshot invalid"
    end
    if hist ~= nil and type(hist) ~= "table" then
        return false, "persist history invalid"
    end

    if type(hist) == "table" then
        _history = {}
        for i = 1, #hist do
            if type(hist[i]) == "table" then
                _history[#_history + 1] = _copySnapshot(hist[i])
            end
        end
    end

    _snapshot = (type(snap) == "table") and _copySnapshot(snap) or nil

    local maxN = _clampMaxEntries(_persist.maxEntries)
    while #_history > maxN do
        table.remove(_history, 1)
    end

    return true, nil
end

-- -------------------------
-- Normalization + Parser (tolerant)
-- -------------------------

local function _trim(s)
    s = tostring(s or "")
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function _normKey(s)
    -- lowercase + trim + collapse spaces
    s = _trim(s)
    s = s:gsub("%s+", " ")
    s = s:lower()
    return s
end

function M.normalizePracticeKey(raw)
    if raw == nil then return nil, "normalizePracticeKey(raw): raw is nil" end
    local s = _normKey(raw)
    if s == "" then return nil, "normalizePracticeKey(raw): raw is empty" end
    return s, nil
end

local function _parsePercent(s)
    if type(s) ~= "string" then return nil end
    local n = s:match("(%d+)%s*%%")
    if n then return tonumber(n) end
    return nil
end

local function _looksHeaderLine(ln)
    ln = tostring(ln or "")
    local l = ln:lower()

    -- current DW headers
    if l:find("you can practice any of these", 1, true) then return true end
    if l:find("your race grants you the following", 1, true) then return true end

    -- legacy headers
    if l:find("you have the following", 1, true) then return true end
    if l:find("weapon pro", 1, true) then return true end
    if l:find("race skill", 1, true) then return true end

    return false
end

local function _sectionFromHeader(ln)
    local l = tostring(ln or ""):lower()

    -- 1) weapon profs (most specific)
    if l:find("weapon", 1, true) and l:find("pro", 1, true) then
        return "weaponProfs"
    end

    -- 2) race skills (handle both "Race skills:" and "Your race grants you the following skills:")
    if (l:find("your race grants you the following", 1, true) ~= nil) then
        return "raceSkills"
    end
    if l:find("race", 1, true) and (l:find("skill", 1, true) or l:find("skills", 1, true)) then
        return "raceSkills"
    end

    -- 3) spells
    if l:find("spell", 1, true) then
        return "spells"
    end

    -- 4) skills (fallback)
    if l:find("skill", 1, true) or l:find("skills", 1, true) then
        return "skills"
    end

    return nil
end

local function _parsePracticeLine_GenericTier(ln)
    local raw = tostring(ln or "")
    local s = _trim(raw)
    if s == "" then return nil end

    local lower = s:lower()

    -- quick ignore obvious prompts/noise that might slip in
    if lower:match("^%d+%(%d+%)hp") and lower:find("mv>", 1, true) then
        return nil
    end
    if lower:match(">%s*$") then
        return nil
    end

    local pct = _parsePercent(s)
    local tier = nil
    local learned = nil

    if pct ~= nil then
        tier = tostring(pct) .. "%"
        learned = true
    elseif lower:find("not known", 1, true) then
        tier = "not known"
        learned = false
    end

    local cost = nil
    do
        local c1 = s:match("%((%d+)%s*[Mm][Aa][Nn][Aa]%)")
        if not c1 then c1 = s:match("%((%d+)%s*[Mm][Pp]%)") end
        if not c1 then c1 = s:match("[Mm][Aa][Nn][Aa]%s*[:=]%s*(%d+)") end
        if not c1 then c1 = s:match("[Cc]ost%s*[:=]%s*(%d+)") end
        if c1 then cost = tonumber(c1) end
    end

    local name = s
    if tier ~= nil then
        if learned == true then
            name = s:gsub("%s*%d+%s*%%%s*.*$", "")
        else
            name = s:gsub("%s*[Nn][Oo][Tt]%s+[Kk][Nn][Oo][Ww][Nn]%s*.*$", "")
        end
        name = _trim(name)
    else
        local a, b = s:match("^(.-)%s+([^%s]+)$")
        if a and b then
            name = _trim(a)
            tier = _normKey(b)
            learned = (tier ~= "not known")
        end
    end

    if _trim(name) == "" then
        return nil
    end

    local entry = {
        name = name,
        key = _normKey(name),
        tier = tostring(tier or "unknown"),
        learned = (learned == true),
        cost = cost,
        rawLine = raw,
    }

    if tostring(entry.tier):lower() == "not known" then
        entry.learned = false
    end

    return entry
end

local function _parseWeaponProfLine(ln)
    local e = _parsePracticeLine_GenericTier(ln)
    if not e then return nil end

    local pct = _parsePercent(e.tier)
    if pct ~= nil then
        e.percent = pct
        e.learned = true
    else
        e.percent = nil
        e.learned = false
    end

    return e
end

local function _splitPipes(line)
    local s = tostring(line or "")
    local out = {}

    if s:find("|", 1, true) == nil then
        out[1] = _trim(s)
        return out
    end

    for seg in s:gmatch("([^|]+)") do
        local t = _trim(seg)
        if t ~= "" then
            out[#out + 1] = t
        end
    end

    if #out == 0 then
        out[1] = _trim(s)
    end

    return out
end

local function _parsePracticeText(text)
    if not _isNonEmptyString(text) then return nil end

    local lines = {}
    do
        local t = text:gsub("\r\n", "\n"):gsub("\r", "\n")
        for ln in t:gmatch("([^\n]*)\n?") do
            if ln == nil then break end
            lines[#lines + 1] = tostring(ln)
        end
        while #lines > 0 and lines[#lines] == "" do
            table.remove(lines, #lines)
        end
    end

    local parsed = {
        _parser = "dwkit.practice.mud.tolerant.v1",
        skills = {},
        spells = {},
        raceSkills = {},
        weaponProfs = {},
    }

    local curSection = nil

    for i = 1, #lines do
        local ln = tostring(lines[i] or "")
        local t = _trim(ln)
        local lower = t:lower()

        if lower:match("^you have %d+ practice sessions remaining%.") then
            -- skip
        elseif _looksHeaderLine(t) then
            local sec = _sectionFromHeader(t)
            if sec ~= nil then
                curSection = sec
            end
        else
            if curSection ~= nil and t ~= "" then
                local parts = _splitPipes(t)

                for p = 1, #parts do
                    local part = parts[p]

                    if curSection == "weaponProfs" then
                        local e = _parseWeaponProfLine(part)
                        if e and _isNonEmptyString(e.key) then
                            parsed.weaponProfs[e.key] = e
                        end
                    else
                        local e = _parsePracticeLine_GenericTier(part)
                        if e and _isNonEmptyString(e.key) then
                            if curSection == "skills" then
                                parsed.skills[e.key] = e
                            elseif curSection == "spells" then
                                parsed.spells[e.key] = e
                            elseif curSection == "raceSkills" then
                                parsed.raceSkills[e.key] = e
                            end
                        end
                    end
                end
            end

            if lower:find("you do not know any", 1, true) or lower:find("you haven't learned any", 1, true) then
                -- keep parsed empty; still valid snapshot
            end
        end
    end

    return parsed
end

-- -------------------------
-- Fixtures
-- -------------------------

local FIXTURES = {
    basic = table.concat({
        "[DWKit PRACTICE FIXTURE v1 - GENERIC]",
        "You have the following skills:",
        "  kick                 75%",
        "  bash                 not known",
        "",
        "You have the following spells:",
        "  heal                 82% (10 mana)",
        "  power heal           not known (25 mana)",
        "",
        "Race skills:",
        "  gore                 60%",
        "",
        "Weapon proficiencies:",
        "  sword                73%",
        "  mace                 not known",
    }, "\n"),
}

local function _startupLoadIfEnabled()
    if not _persist.enabled then
        return
    end

    local okLoad, loadErr = _persistLoad()
    if okLoad then
        return
    end

    local msg = tostring(loadErr or "")
    local isMissing =
        (msg == "file not found") or
        (msg:find("file not found", 1, true) ~= nil) or
        (msg:find("no data loaded", 1, true) ~= nil)

    if isMissing then
        _persist.lastLoadOk = true
        _persist.lastLoadErr = nil
        _persist.lastLoadTs = os.time()
        return
    end

    _persist.lastLoadOk = false
    _persist.lastLoadErr = "startup load failed: " .. msg
    _persist.lastLoadTs = os.time()
end

_startupLoadIfEnabled()

function M.getVersion()
    return tostring(M.VERSION or "unknown")
end

function M.getUpdatedEventName()
    return tostring(EV_UPDATED)
end

function M.getSnapshot()
    return _copySnapshot(_snapshot)
end

function M.getHistory()
    return _copyHistory(_history)
end

function M.getPersistenceStatus()
    return {
        enabled = _persist.enabled,
        schemaVersion = _persist.schemaVersion,
        relPath = _persist.relPath,
        maxEntries = _persist.maxEntries,
        lastSaveOk = _persist.lastSaveOk,
        lastSaveErr = _persist.lastSaveErr,
        lastSaveTs = _persist.lastSaveTs,
        lastLoadOk = _persist.lastLoadOk,
        lastLoadErr = _persist.lastLoadErr,
        lastLoadTs = _persist.lastLoadTs,
    }
end

function M.configurePersistence(opts)
    opts = (type(opts) == "table") and opts or {}

    if opts.relPath ~= nil then
        if not _isNonEmptyString(opts.relPath) then
            return false, "configurePersistence: relPath must be non-empty string"
        end
        _persist.relPath = tostring(opts.relPath)
    end

    if opts.maxEntries ~= nil then
        _persist.maxEntries = _clampMaxEntries(opts.maxEntries)
        while #_history > _persist.maxEntries do
            table.remove(_history, 1)
        end
    end

    local enable = (opts.enabled == true)

    if enable and not _persist.enabled then
        _persist.enabled = true

        local loadExisting = (opts.loadExisting ~= false)
        if loadExisting then
            local okLoad, loadErr = _persistLoad()
            if not okLoad then
                local msg = tostring(loadErr or "")
                local isMissing =
                    (msg == "file not found") or
                    (msg:find("file not found", 1, true) ~= nil) or
                    (msg:find("no data loaded", 1, true) ~= nil)

                if not isMissing then
                    _persist.enabled = false
                    return false, "persistence enable failed (load): " .. msg
                end
            end
        end

        return true, nil
    end

    if (not enable) and _persist.enabled then
        _persist.enabled = false
        return true, nil
    end

    _persist.enabled = enable
    return true, nil
end

function M.getFixture(name)
    name = _isNonEmptyString(name) and tostring(name) or "basic"
    local text = FIXTURES[name]
    if not _isNonEmptyString(text) then
        return false, nil, "unknown fixture: " .. tostring(name)
    end
    return true, text, nil
end

function M.ingestFixture(name, meta)
    local okF, text, ferr = M.getFixture(name)
    if not okF then
        return false, ferr
    end
    meta = (type(meta) == "table") and meta or {}
    if not _isNonEmptyString(meta.source) then
        meta.source = "fixture"
    end
    return M.ingestFromText(text, meta)
end

function M.ingestFromText(text, meta)
    if not _isNonEmptyString(text) then
        return false, "ingestFromText(text): text must be a non-empty string"
    end
    meta = (type(meta) == "table") and meta or {}
    local source = _isNonEmptyString(meta.source) and meta.source or "manual"

    local snap = {
        schemaVersion = SCHEMA_VERSION,
        ts = os.time(),
        source = source,
        raw = text,
        parsed = _parsePracticeText(text),
    }

    _snapshot = snap

    _history[#_history + 1] = _copySnapshot(_snapshot)
    local maxN = _clampMaxEntries(_persist.maxEntries)
    while #_history > maxN do
        table.remove(_history, 1)
    end

    if _persist.enabled then
        _persistSave(source)
    end

    _emitUpdated(_snapshot, source)
    _notifyCrossProfilePublisherFallback("practice_store:ingest")
    return true, nil
end

function M.clear(meta)
    meta = (type(meta) == "table") and meta or {}
    local source = _isNonEmptyString(meta.source) and meta.source or "manual"

    _snapshot = nil

    if _persist.enabled then
        _persistSave(source)
    end

    _emitUpdated({ schemaVersion = SCHEMA_VERSION, ts = os.time(), source = source, raw = "", parsed = nil }, source)
    _notifyCrossProfilePublisherFallback("practice_store:clear")
    return true, nil
end

function M.wipe(meta)
    meta = (type(meta) == "table") and meta or {}
    local source = _isNonEmptyString(meta.source) and meta.source or "manual"
    local deleteFile = (meta.deleteFile == true)

    _snapshot = nil
    _history = {}

    if _persist.enabled then
        if deleteFile then
            local okStore, store, err = _getPersistStore()
            if not okStore then
                return false, "wipe disk failed: persist store not available: " .. tostring(err)
            end
            if type(store.delete) ~= "function" then
                return false, "wipe disk failed: persist store.delete not available"
            end
            local okDel, delErr = pcall(store.delete, _persist.relPath)
            if not okDel then
                return false, "wipe disk failed: " .. tostring(delErr)
            end

            _persist.lastSaveOk = true
            _persist.lastSaveErr = nil
            _persist.lastSaveTs = os.time()
        else
            _persistSave(source)
        end
    end

    _emitUpdated({ schemaVersion = SCHEMA_VERSION, ts = os.time(), source = source, raw = "", parsed = nil }, source)
    _notifyCrossProfilePublisherFallback("practice_store:wipe")
    return true, nil
end

-- -------------------------
-- Bucket B gating helpers (SAFE, data-only)
-- -------------------------

local function _sectionForKind(kind)
    kind = tostring(kind or ""):lower()
    if kind == "skill" or kind == "skills" then return "skills" end
    if kind == "spell" or kind == "spells" then return "spells" end
    if kind == "race" or kind == "raceskill" or kind == "raceskills" or kind == "race-skill" or kind == "race skill" then
        return "raceSkills"
    end
    if kind == "weapon" or kind == "weapons" or kind == "weaponprof" or kind == "weaponprofs" or kind == "weapon-prof" then
        return "weaponProfs"
    end
    return nil
end

local function _getEntryFromSnapshot(snap, section, key)
    if type(snap) ~= "table" then return nil end
    if type(snap.parsed) ~= "table" then return nil end
    local p = snap.parsed
    local sec = p[section]
    if type(sec) ~= "table" then return nil end
    local e = sec[key]
    if type(e) ~= "table" then return nil end
    return e
end

function M.getLearnStatus(kind, practiceKey)
    local section = _sectionForKind(kind)
    if section == nil then
        return {
            ok = false,
            kind = tostring(kind or ""),
            practiceKey = tostring(practiceKey or ""),
            hasSnapshot = (type(_snapshot) == "table"),
            hasParsed = (type(_snapshot) == "table" and type(_snapshot.parsed) == "table"),
            learned = false,
            tier = nil,
            cost = nil,
            percent = nil,
            reason = "bad_kind",
            snapshotTs = (type(_snapshot) == "table") and _snapshot.ts or nil,
            snapshotSource = (type(_snapshot) == "table") and _snapshot.source or nil,
        }
    end

    local pk, pkErr = M.normalizePracticeKey(practiceKey)
    if not pk then
        return {
            ok = false,
            kind = tostring(kind or ""),
            practiceKey = tostring(practiceKey or ""),
            hasSnapshot = (type(_snapshot) == "table"),
            hasParsed = (type(_snapshot) == "table" and type(_snapshot.parsed) == "table"),
            learned = false,
            tier = nil,
            cost = nil,
            percent = nil,
            reason = "bad_key:" .. tostring(pkErr),
            snapshotTs = (type(_snapshot) == "table") and _snapshot.ts or nil,
            snapshotSource = (type(_snapshot) == "table") and _snapshot.source or nil,
        }
    end

    local snap = _snapshot
    local hasSnap = (type(snap) == "table")
    local hasParsed = (hasSnap and type(snap.parsed) == "table")

    if not hasSnap or not hasParsed then
        return {
            ok = true,
            kind = tostring(kind or ""),
            practiceKey = pk,
            hasSnapshot = hasSnap,
            hasParsed = hasParsed,
            learned = false,
            tier = nil,
            cost = nil,
            percent = nil,
            reason = "unknown_stale",
            snapshotTs = hasSnap and snap.ts or nil,
            snapshotSource = hasSnap and snap.source or nil,
        }
    end

    local e = _getEntryFromSnapshot(snap, section, pk)
    if type(e) ~= "table" then
        -- Not present in parsed list (common: not learned or not shown in output)
        return {
            ok = true,
            kind = tostring(kind or ""),
            practiceKey = pk,
            hasSnapshot = true,
            hasParsed = true,
            learned = false,
            tier = nil,
            cost = nil,
            percent = nil,
            reason = "not_listed",
            snapshotTs = snap.ts,
            snapshotSource = snap.source,
        }
    end

    local tier = (type(e.tier) == "string") and e.tier or nil
    local learned = (e.learned == true)
    if type(tier) == "string" and tier:lower() == "not known" then
        learned = false
    end

    local reason = learned and "ok" or "not_learned"

    return {
        ok = true,
        kind = tostring(kind or ""),
        practiceKey = pk,
        hasSnapshot = true,
        hasParsed = true,
        learned = learned,
        tier = tier,
        cost = (type(e.cost) == "number") and e.cost or nil,
        percent = (type(e.percent) == "number") and e.percent or nil,
        reason = reason,
        snapshotTs = snap.ts,
        snapshotSource = snap.source,
    }
end

-- SAFE, test-only:
function M.selfTestPersistenceSmoke(opts)
    opts = (type(opts) == "table") and opts or {}
    local relPath = _isNonEmptyString(opts.relPath) and tostring(opts.relPath) or
        "selftest/practice_store_service_smoke.tbl"

    local okStore, store, err = _getPersistStore()
    if not okStore then
        return false, "persist store not available: " .. tostring(err)
    end

    local prevSnap = _copySnapshot(_snapshot)
    local prevHist = _copyHistory(_history)
    local prevPersist = {}
    for k, v in pairs(_persist) do prevPersist[k] = v end

    local function _restore()
        _snapshot = (type(prevSnap) == "table") and _copySnapshot(prevSnap) or nil
        _history = _copyHistory(prevHist)

        for k, _ in pairs(_persist) do
            _persist[k] = prevPersist[k]
        end
        for k, v in pairs(prevPersist) do
            _persist[k] = v
        end
    end

    local ok, thrown = pcall(function()
        if type(store.delete) == "function" then
            pcall(store.delete, relPath)
        end

        local okCfg, cfgErr = M.configurePersistence({
            enabled = true,
            relPath = relPath,
            maxEntries = 5,
            loadExisting = false,
        })
        if not okCfg then
            error("configurePersistence enable failed: " .. tostring(cfgErr))
        end

        local text = FIXTURES.basic
        local okIn, inErr = M.ingestFromText(text, { source = "self_test_runner" })
        if not okIn then
            error("ingestFromText failed: " .. tostring(inErr))
        end

        _snapshot = nil
        _history = {}

        local okLoad, loadErr = _persistLoad()
        if not okLoad then
            error("persist load failed: " .. tostring(loadErr))
        end

        if type(_snapshot) ~= "table" then
            error("loaded snapshot missing")
        end
        if tostring(_snapshot.raw or "") ~= text then
            error("loaded snapshot raw mismatch")
        end
        if tostring(_snapshot.source or "") ~= "self_test_runner" then
            error("loaded snapshot source mismatch")
        end

        if type(_snapshot.parsed) ~= "table" then
            error("loaded snapshot parsed missing")
        end

        M.configurePersistence({ enabled = false })

        if type(store.delete) == "function" then
            pcall(store.delete, relPath)
        end
    end)

    _restore()

    if ok then
        return true, nil
    end
    return false, tostring(thrown)
end

function M.printSummary()
    _out("[DWKit PracticeStore] (source: dwkit.services.practice_store_service " .. tostring(M.VERSION) .. ")")

    _out("  persistence : " .. (_persist.enabled and "ENABLED" or "DISABLED"))

    do
        local okP, paths = _getPersistPaths()
        if okP and type(paths) == "table" and type(paths.getDataDir) == "function" then
            local okCall, okGet, dir, derr = pcall(paths.getDataDir)
            if okCall and okGet and dir ~= nil then
                _out("  dataDir     : " .. tostring(dir))
            elseif okCall then
                _out("  dataDir     : (error) " .. tostring(derr))
            else
                _out("  dataDir     : (error) " .. tostring(okGet))
            end
        end
    end

    _out("  persistPath : " .. tostring(_persist.relPath))
    _out("  maxEntries  : " .. tostring(_persist.maxEntries))

    if _persist.enabled then
        _out("  lastSaveOk  : " .. tostring(_persist.lastSaveOk))
        _out("  lastSaveTs  : " .. _fmtTs(_persist.lastSaveTs))
        if _persist.lastSaveErr ~= nil then
            _out("  lastSaveErr : " .. tostring(_persist.lastSaveErr))
        end

        _out("  lastLoadOk  : " .. tostring(_persist.lastLoadOk))
        _out("  lastLoadTs  : " .. _fmtTs(_persist.lastLoadTs))
        if _persist.lastLoadErr ~= nil then
            _out("  lastLoadErr : " .. tostring(_persist.lastLoadErr))
        end
    end

    _out("  historyCount: " .. tostring(#_history))

    if type(_snapshot) ~= "table" then
        _out("  snapshot: (none)")
        _out("  hint: dwpracticestore fixture")
        return
    end

    _out("  schemaVersion: " .. tostring(_snapshot.schemaVersion))
    _out("  ts          : " .. tostring(_snapshot.ts))
    _out("  source      : " .. tostring(_snapshot.source))
    local rawLen = (_isNonEmptyString(_snapshot.raw) and #_snapshot.raw or 0)
    _out("  rawLen      : " .. tostring(rawLen))

    if type(_snapshot.parsed) == "table" then
        local p = _snapshot.parsed
        local function cnt(m)
            local n = 0
            if type(m) == "table" then for _ in pairs(m) do n = n + 1 end end
            return n
        end
        _out("  parsed      : table (" .. tostring(p._parser or "unknown") .. ")")
        _out("  skills      : " .. tostring(cnt(p.skills)))
        _out("  spells      : " .. tostring(cnt(p.spells)))
        _out("  raceSkills  : " .. tostring(cnt(p.raceSkills)))
        _out("  weaponProfs : " .. tostring(cnt(p.weaponProfs)))
    else
        _out("  parsed      : nil")
    end
end

return M
