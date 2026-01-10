-- #########################################################################
-- Module Name : dwkit.services.score_store_service
-- Owner       : Services
-- Version     : v2026-01-10A
-- Purpose     :
--   - Provide a SAFE, manual-only score text snapshot store (No-GMCP).
--   - Ingest score-like text via explicit API calls (no send(), no timers).
--   - Store latest snapshot in memory (persistence staged; no disk writes in this gate).
--   - Emit a namespaced update event when snapshot changes.
--
-- Public API  :
--   - getVersion() -> string
--   - getSnapshot() -> table|nil
--   - ingestFromText(text, meta?) -> boolean ok, string|nil err
--   - clear(meta?) -> boolean ok, string|nil err
--   - printSummary() -> nil (SAFE helper output)
--
-- Events Emitted :
--   - DWKit:Service:ScoreStore:Updated
--     payload: { ts=number, snapshot=table, source=string|nil }
--
-- Events Consumed  : None
-- Persistence      : None (staged)
-- Automation Policy: Manual only
-- Dependencies     : dwkit.core.identity
-- #########################################################################

local M = {}

M.VERSION = "v2026-01-10A"

local ID = require("dwkit.core.identity")

local PREFIX = tostring(ID.eventPrefix or "DWKit:")
local EV_UPDATED = PREFIX .. "Service:ScoreStore:Updated"

local SCHEMA_VERSION = 1

local _snapshot = nil

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

function M.getVersion()
    return tostring(M.VERSION or "unknown")
end

function M.getSnapshot()
    return _copySnapshot(_snapshot)
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
        parsed = nil, -- parsing is optional; staged
    }

    _snapshot = snap
    _emitUpdated(_snapshot, source)
    return true, nil
end

function M.clear(meta)
    meta = (type(meta) == "table") and meta or {}
    local source = _isNonEmptyString(meta.source) and meta.source or "manual"
    _snapshot = nil
    _emitUpdated({ schemaVersion = SCHEMA_VERSION, ts = os.time(), source = source, raw = "", parsed = nil }, source)
    return true, nil
end

function M.printSummary()
    _out("[DWKit ScoreStore] (source: dwkit.services.score_store_service " .. tostring(M.VERSION) .. ")")
    if type(_snapshot) ~= "table" then
        _out("  snapshot: (none)")
        _out("  hint: lua DWKit.services.scoreStoreService.ingestFromText(\"SCORE TEST\",{source=\"manual\"})")
        return
    end
    _out("  schemaVersion: " .. tostring(_snapshot.schemaVersion))
    _out("  ts          : " .. tostring(_snapshot.ts))
    _out("  source      : " .. tostring(_snapshot.source))
    local rawLen = (_isNonEmptyString(_snapshot.raw) and #_snapshot.raw or 0)
    _out("  rawLen      : " .. tostring(rawLen))
    _out("  parsed      : " .. (type(_snapshot.parsed) == "table" and "table" or "nil"))
end

return M
