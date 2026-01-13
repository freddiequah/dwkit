-- #########################################################################
-- Module Name : dwkit.services.score_store_service
-- Owner       : Services
-- Version     : v2026-01-13F
-- Purpose     :
--   - Provide a SAFE, manual-only score text snapshot store (No-GMCP).
--   - Ingest score-like text via explicit API calls (no send(), no timers).
--   - Store latest snapshot in memory.
--   - Manual-only persistence using DWKit.persist.store (writes only on ingest/clear).
--   - Emit a namespaced update event when snapshot changes.
--   - Provide deterministic fixtures + a simple parser for repeatable tests.
--
-- Public API  :
--   - getVersion() -> string
--   - getSnapshot() -> table|nil
--   - getHistory() -> table (array; shallow-copied; oldest->newest)
--   - configurePersistence(opts) -> boolean ok, string|nil err
--       opts:
--         - enabled: boolean (default true in this build)
--         - relPath: string (default "services/score_store/history.tbl")
--         - maxEntries: number (default 50; min 1; max 500)
--         - loadExisting: boolean (default true when enabling)
--   - getPersistenceStatus() -> table (SAFE diagnostics)
--   - ingestFromText(text, meta?) -> boolean ok, string|nil err
--   - clear(meta?) -> boolean ok, string|nil err
--   - printSummary() -> nil (SAFE helper output)
--   - getFixture(name?) -> (ok:boolean, text:string|nil, err:string|nil)
--   - ingestFixture(name?, meta?) -> boolean ok, string|nil err
--   - selfTestPersistenceSmoke(opts?) -> boolean ok, string|nil err (SAFE; test-only)
--
-- Events Emitted :
--   - DWKit:Service:ScoreStore:Updated
--     payload: { ts=number, snapshot=table, source=string|nil }
--
-- Events Consumed  : None
-- Persistence      :
--   - ENABLED by default (startup load best-effort; writes only on ingest/clear).
--   - relPath: <DataFolderName>/<relPath> (default: dwkit/services/score_store/history.tbl)
--   - envelope schemaVersion: "v0.1"
--   - envelope data:
--     - snapshot: table|nil
--     - history:  array of snapshot tables (bounded)
-- Automation Policy: Manual only
-- Dependencies     : dwkit.core.identity (optional best-effort persist via DWKit.persist.store)
-- #########################################################################

local M = {}

M.VERSION = "v2026-01-13F"

local ID = require("dwkit.core.identity")

local PREFIX = tostring(ID.eventPrefix or "DWKit:")
local EV_UPDATED = PREFIX .. "Service:ScoreStore:Updated"

local SCHEMA_VERSION = 1

local _snapshot = nil
local _history = {} -- array of snapshots, oldest -> newest

-- persistence (writes only on ingest/clear; startup may load)
local _persist = {
    enabled = true, -- enabled by default (manual-only writes)
    schemaVersion = "v0.1",
    relPath = "services/score_store/history.tbl",
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

local function _shallowCopy(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do out[k] = v end
    return out
end

local function _copySnapshot(s)
    if type(s) ~= "table" then return nil end
    local c = _shallowCopy(s)
    if type(c.parsed) == "table" then c.parsed = _shallowCopy(c.parsed) end
    return c
end

local function _copyHistory(hist)
    if type(hist) ~= "table" then return {} end
    local out = {}
    for i = 1, #hist do
        out[i] = _copySnapshot(hist[i])
    end
    return out
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
        service = "dwkit.services.score_store_service",
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
-- Deterministic fixture + parser
-- -------------------------
local FIXTURES = {
    basic = table.concat({
        "[DWKit SCORE FIXTURE v1]",
        "Name: Vzae",
        "Class: Warrior",
        "Level: 50",
        "HP: 1234/5678",
        "Mana: 222/333",
        "Move: 44/55",
        "Gold: 98765",
        "Exp: 123456 (Next: 7890)",
    }, "\n"),
}

local function _trim(s)
    s = tostring(s or "")
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function _parseKV(text, key)
    -- Matches "Key: value" on any line
    local pat = "\n" .. key .. "%s*:%s*([^\n]+)"
    local v = text:match(pat)
    if not v then
        v = text:match("^" .. key .. "%s*:%s*([^\n]+)")
    end
    if v then
        return _trim(v)
    end
    return nil
end

local function _parseRatio(text, label)
    -- Matches "Label: cur/max" -> numbers
    local pat = "\n" .. label .. "%s*:%s*(%d+)%s*/%s*(%d+)"
    local a, b = text:match(pat)
    if not a then
        a, b = text:match("^" .. label .. "%s*:%s*(%d+)%s*/%s*(%d+)")
    end
    if a and b then
        return tonumber(a), tonumber(b)
    end
    return nil, nil
end

local function _parseScoreText(text)
    if not _isNonEmptyString(text) then return nil end
    text = "\n" .. text .. "\n" -- padding for \n patterns

    local parsed = {}

    local name = _parseKV(text, "Name")
    if name then parsed.name = name end

    local cls = _parseKV(text, "Class")
    if cls then parsed.class = cls end

    do
        local lvl = _parseKV(text, "Level")
        local n = tonumber(lvl or "")
        if n then parsed.level = n end
    end

    do
        local cur, max = _parseRatio(text, "HP")
        if cur and max then
            parsed.hpCur = cur
            parsed.hpMax = max
        end
    end

    do
        local cur, max = _parseRatio(text, "Mana")
        if cur and max then
            parsed.manaCur = cur
            parsed.manaMax = max
        end
    end

    do
        local cur, max = _parseRatio(text, "Move")
        if cur and max then
            parsed.moveCur = cur
            parsed.moveMax = max
        end
    end

    do
        local g = _parseKV(text, "Gold")
        if g ~= nil then
            -- IMPORTANT: gsub returns (string, count). Capture only the string.
            local s = tostring(g):gsub(",", "")
            local n = tonumber(s)
            if n then parsed.gold = n end
        end
    end

    do
        -- "Exp: 123456 (Next: 7890)"
        local exp = text:match("\nExp%s*:%s*(%d+)")
        if not exp then exp = text:match("^Exp%s*:%s*(%d+)") end
        if exp then parsed.exp = tonumber(exp) end

        local nxt = text:match("Next%s*:%s*(%d+)")
        if nxt then parsed.nextExp = tonumber(nxt) end
    end

    if next(parsed) == nil then
        return nil
    end

    parsed._parser = "dwkit.score.fixture.v1"
    return parsed
end

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
        -- Missing file is normal on first run; do not disable persistence.
        _persist.lastLoadOk = true
        _persist.lastLoadErr = nil
        _persist.lastLoadTs = os.time()
        return
    end

    -- For other errors: keep enabled=true, but record the error for diagnostics.
    _persist.lastLoadOk = false
    _persist.lastLoadErr = "startup load failed: " .. msg
    _persist.lastLoadTs = os.time()
end

_startupLoadIfEnabled()

function M.getVersion()
    return tostring(M.VERSION or "unknown")
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

        -- NOTE: do not force a save here; we only write on manual ingest/clear.
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
        parsed = _parseScoreText(text),
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
    return true, nil
end

-- SAFE, test-only:
-- - Writes to a selftest relPath (default under selftest/*)
-- - Uses configurePersistence + ingest + internal load to validate round-trip
-- - Cleans up the file best-effort (if store.delete exists)
-- - Restores ALL prior in-memory state + persistence config/status
function M.selfTestPersistenceSmoke(opts)
    opts = (type(opts) == "table") and opts or {}
    local relPath = _isNonEmptyString(opts.relPath) and tostring(opts.relPath) or
        "selftest/score_store_service_smoke.tbl"

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

        -- restore all known keys
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
            error("loaded snapshot parsed missing (parser should succeed for fixture)")
        end
        if type(_history) ~= "table" or #_history < 1 then
            error("loaded history missing/empty")
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
    _out("[DWKit ScoreStore] (source: dwkit.services.score_store_service " .. tostring(M.VERSION) .. ")")

    _out("  persistence : " .. (_persist.enabled and "ENABLED" or "DISABLED"))

    -- Best-effort: show data directory when persist paths are available
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
        _out("  hint: dwscorestore fixture")
        return
    end

    _out("  schemaVersion: " .. tostring(_snapshot.schemaVersion))
    _out("  ts          : " .. tostring(_snapshot.ts))
    _out("  source      : " .. tostring(_snapshot.source))
    local rawLen = (_isNonEmptyString(_snapshot.raw) and #_snapshot.raw or 0)
    _out("  rawLen      : " .. tostring(rawLen))

    if type(_snapshot.parsed) == "table" then
        local n = 0
        for _ in pairs(_snapshot.parsed) do n = n + 1 end
        _out("  parsed      : table (keys=" .. tostring(n) .. ")")
    else
        _out("  parsed      : nil")
    end
end

return M
