-- #########################################################################
-- Module Name : dwkit.services.score_store_service
-- Owner       : Services
-- Version     : v2026-01-13I
-- Purpose     :
--   - Provide a SAFE, manual-only score text snapshot store (No-GMCP).
--   - Ingest score-like text via explicit API calls (no send(), no timers).
--   - Store latest snapshot in memory.
--   - Manual-only persistence using DWKit.persist.store (writes only on ingest/clear/wipe).
--   - Emit a namespaced update event when snapshot changes.
--   - Provide deterministic fixtures + a parser that supports MUD score variants:
--       * score (table short)
--       * score -l (table long)
--       * score -r (report text)
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
-- Events Emitted :
--   - DWKit:Service:ScoreStore:Updated
--     payload: { ts=number, snapshot=table, source=string|nil }
--
-- Events Consumed  : None
-- Persistence      :
--   - ENABLED by default (startup load best-effort; writes only on ingest/clear/wipe).
--   - relPath: <DataFolderName>/<relPath> (default: dwkit/services/score_store/history.tbl)
--   - envelope schemaVersion: "v0.1"
--   - envelope data:
--     - snapshot: table|nil
--     - history:  array of snapshot tables (bounded)
-- Automation Policy: Manual only
-- Dependencies     : dwkit.core.identity (optional best-effort persist via DWKit.persist.store)
-- #########################################################################

local M = {}

M.VERSION = "v2026-01-13I"

local ID = require("dwkit.core.identity")

local PREFIX = tostring(ID.eventPrefix or "DWKit:")
local EV_UPDATED = PREFIX .. "Service:ScoreStore:Updated"

local SCHEMA_VERSION = 1

local _snapshot = nil
local _history = {} -- array of snapshots, oldest -> newest

-- persistence (writes only on ingest/clear/wipe; startup may load)
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
-- Fixtures + Parser (supports 3 score variants)
-- -------------------------

local FIXTURES = {
    -- Legacy fixture kept for backward compatibility tests
    basic = table.concat({
        "[DWKit SCORE FIXTURE v1 - GENERIC]",
        "Name: Example",
        "Class: ExampleClass",
        "Level: 50",
        "HP: 1234/5678",
        "Mana: 222/333",
        "Move: 44/55",
        "Gold: 98765",
        "Exp: 123456 (Next: 7890)",
    }, "\n"),

    -- Table short (score)
    score_table_short = table.concat({
        "+-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-+",
        "| Name:              Vzae | Class:        Warrior | Sex: M    Level:   48 |",
        "|-------------------------+-----------------------+-----------------------|",
        "| Stats:   Current   Base | Armor Class:     -146 | HitRoll:           51 |",
        "| Str:     18/100  18/100 | Alignment:         89 | DamRoll:           72 |",
        "| Int:         18      18 | Deaths:            45 | Hit:     (716/716+13) |",
        "| Wis:         18      18 | Kills:          11491 | Mana:     (100/100+3) |",
        "| Dex:         18      18 | Hometown:     Asgaard | Move:       (82/82+6) |",
        "| Con:         18      18 | Gold:         5437844 | Exp:         14333688 |",
        "| Cha:         12      12 | In Bank:            0 | To Level:      691312 |",
        "+-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-+",
    }, "\n"),

    -- Table long (score -l)
    score_table_long = table.concat({
        "+-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-+",
        "| Name:              Vzae | Class:        Warrior | Sex: M    Level:   48 |",
        "|-------------------------+-----------------------+-----------------------|",
        "| Stats:   Current   Base | Armor Class:     -146 | HitRoll:           51 |",
        "| Str:     18/100  18/100 | Alignment:         89 | DamRoll:           72 |",
        "| Int:         18      18 | Deaths:            45 | Hit:     (716/716+13) |",
        "| Wis:         18      18 | Kills:          11491 | Mana:     (100/100+3) |",
        "| Dex:         18      18 | Hometown:     Asgaard | Move:       (82/82+6) |",
        "| Con:         18      18 | Gold:         5437844 | Exp:         14333688 |",
        "| Cha:         12      12 | In Bank:            0 | To Level:      691312 |",
        "|-------------------------+-----------------------+-----------------------|",
        "| Age:                270 | Sacrifices:         0 | Position:    Standing |",
        "| Played:   0yr 30d 14hrs | Deathtraps:         0 | Hunger:             0 |",
        "| Race:          Minotaur | Quest Points:       0 | Thirst:             0 |",
        "| Remorts:              7 | Honor Points:       0 | Drunk:              0 |",
        "|-------------------------+-----------------------+-----------------------|",
        "| Saves vs   Para:   4   Rod:   5   Petri:   6   Breath:   5   Spell:   7 |",
        "|-------------------------+-----------------------+-----------------------|",
        "| Title: the adventurer                                                   |",
        "+-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-+",
    }, "\n"),

    -- Report (score -r)
    score_report = table.concat({
        "You are a 270 year-old male.",
        "You are a Warrior of the Minotaur race.",
        "You have 716(716) hit, 100(100) mana and 82(82) movement points.",
        "Current stats:  Str: 18/100 Int: 18 Wis: 18 Dex: 18 Con: 18 Cha: 12",
        "Original stats: Str: 18/100 Int: 18 Wis: 18 Dex: 18 Con: 18 Cha: 12",
        "Your armor class is -146/10, and your alignment is 89.",
        "Your Hitroll is 51, and your Damroll is 72.",
        "Your regeneration factors are: Hp: 13  Mp: 3  Mv: 6.",
        "You have scored 14333688 experience points.",
        "This ranks you as Vzae the adventurer  (level 48).",
        "You need 691312 experience points to reach your next level.",
        "You have 5437844 gold coins on hand, and 0 coins in the bank.",
        "You have been playing for 0 years, 30 days and 14 hours.",
        "Deaths: [45], Kills: [11491], DTs: [0], Sacrifices: [0]",
        "Saves vs: Para: [4]  Rod: [5]  Petri: [6]  Breath: [5]  Spell: [7]",
        "You have remorted this character into the mortal world 7 times.",
        "You have 0 Quest Points, and 0 Honor Points.",
        "Your hometown is Asgaard.",
        "You are standing.",
        "You are hungry.",
        "You are thirsty.",
    }, "\n"),
}

local function _trim(s)
    s = tostring(s or "")
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function _toNumber(s)
    if s == nil then return nil end
    local t = tostring(s)
    t = t:gsub(",", "")
    local n = tonumber(t)
    return n
end

local function _detectVariant(text)
    if not _isNonEmptyString(text) then return "unknown" end

    if text:find("%+%-%=%-%=%-%=%-", 1, false) then
        -- table variants
        if text:find("Age:", 1, true) or text:find("Saves vs", 1, true) or text:find("Played:", 1, true) then
            return "table_long"
        end
        return "table_short"
    end

    if text:find("You have ", 1, true) and text:find(" movement points", 1, true) and text:find("Current stats:", 1, true) then
        return "report"
    end

    return "unknown"
end

local function _parseScoreFixtureKV(text)
    -- Legacy fixture KV parsing (kept)
    if not _isNonEmptyString(text) then return nil end
    text = "\n" .. text .. "\n" -- padding for \n patterns

    local function _parseKV(key)
        local pat = "\n" .. key .. "%s*:%s*([^\n]+)"
        local v = text:match(pat)
        if not v then v = text:match("^" .. key .. "%s*:%s*([^\n]+)") end
        if v then return _trim(v) end
        return nil
    end

    local function _parseRatio(label)
        local pat = "\n" .. label .. "%s*:%s*(%d+)%s*/%s*(%d+)"
        local a, b = text:match(pat)
        if not a then a, b = text:match("^" .. label .. "%s*:%s*(%d+)%s*/%s*(%d+)") end
        if a and b then return tonumber(a), tonumber(b) end
        return nil, nil
    end

    local parsed = {}

    local name = _parseKV("Name")
    if name then parsed.name = name end

    local cls = _parseKV("Class")
    if cls then parsed.class = cls end

    do
        local lvl = _parseKV("Level")
        local n = tonumber(lvl or "")
        if n then parsed.level = n end
    end

    do
        local cur, max = _parseRatio("HP")
        if cur and max then parsed.hpCur, parsed.hpMax = cur, max end
    end

    do
        local cur, max = _parseRatio("Mana")
        if cur and max then parsed.manaCur, parsed.manaMax = cur, max end
    end

    do
        local cur, max = _parseRatio("Move")
        if cur and max then parsed.moveCur, parsed.moveMax = cur, max end
    end

    do
        local g = _parseKV("Gold")
        local n = _toNumber(g)
        if n then parsed.gold = n end
    end

    do
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

local function _parseTableHeader(text, parsed)
    -- Extract Name / Class / Sex / Level from the header row (table variants)
    -- Example: | Name:              Vzae | Class:        Warrior | Sex: M    Level:   48 |
    local name = text:match("Name:%s*([^|]+)%|")
    if name then parsed.name = _trim(name) end

    local cls = text:match("Class:%s*([^|]+)%|")
    if cls then parsed.class = _trim(cls) end

    local sex = text:match("Sex:%s*([A-Za-z])")
    if sex then parsed.sex = _trim(sex) end

    local lvl = text:match("Level:%s*(%d+)")
    if lvl then parsed.level = tonumber(lvl) end
end

local function _parseTableCore(text, parsed)
    -- Armor Class, Alignment, HitRoll, DamRoll, Deaths, Kills, Hometown, Gold, Bank, Exp, To Level
    local ac = text:match("Armor Class:%s*([%-%d]+)")
    if ac then parsed.armorClass = tonumber(ac) end

    local align = text:match("Alignment:%s*([%-%d]+)")
    if align then parsed.alignment = tonumber(align) end

    local hr = text:match("HitRoll:%s*([%-%d]+)")
    if hr then parsed.hitroll = tonumber(hr) end

    local dr = text:match("DamRoll:%s*([%-%d]+)")
    if dr then parsed.damroll = tonumber(dr) end

    local deaths = text:match("Deaths:%s*(%d+)")
    if deaths then parsed.deaths = tonumber(deaths) end

    local kills = text:match("Kills:%s*(%d+)")
    if kills then parsed.kills = tonumber(kills) end

    local hometown = text:match("Hometown:%s*([^|]+)%|")
    if hometown then parsed.hometown = _trim(hometown) end

    local gold = text:match("Gold:%s*([%d,]+)")
    if gold then parsed.gold = _toNumber(gold) end

    local bank = text:match("In Bank:%s*([%d,]+)")
    if bank then parsed.bank = _toNumber(bank) end

    local exp = text:match("Exp:%s*([%d,]+)")
    if exp then parsed.exp = _toNumber(exp) end

    local toLevel = text:match("To Level:%s*([%d,]+)")
    if toLevel then parsed.toLevel = _toNumber(toLevel) end
end

local function _parseTableStats(text, parsed)
    -- Str: 18/100  18/100 ; Int/Wis/Dex/Con/Cha simple
    -- IMPORTANT: Many servers format columns with spacing; be permissive.
    local strCur, strBase, strBase2 = text:match("Str:%s*(%d+/%d+)%s+(%d+/%d+)")
    if strCur and strBase then
        parsed.strCur = strCur
        parsed.strBase = strBase
    end

    local int = text:match("Int:%s*(%d+)")
    if int then parsed.int = tonumber(int) end

    local wis = text:match("Wis:%s*(%d+)")
    if wis then parsed.wis = tonumber(wis) end

    local dex = text:match("Dex:%s*(%d+)")
    if dex then parsed.dex = tonumber(dex) end

    local con = text:match("Con:%s*(%d+)")
    if con then parsed.con = tonumber(con) end

    local cha = text:match("Cha:%s*(%d+)")
    if cha then parsed.cha = tonumber(cha) end
end

local function _parseTableVitals(text, parsed)
    -- Hit: (716/716+13) Mana: (100/100+3) Move: (82/82+6)
    local hcur, hmax, hregen = text:match("Hit:%s*%((%d+)%s*/%s*(%d+)%s*%+%s*(%d+)%)")
    if hcur and hmax then
        parsed.hpCur = tonumber(hcur)
        parsed.hpMax = tonumber(hmax)
        parsed.regenHp = tonumber(hregen)
    end

    local mcur, mmax, mregen = text:match("Mana:%s*%((%d+)%s*/%s*(%d+)%s*%+%s*(%d+)%)")
    if mcur and mmax then
        parsed.manaCur = tonumber(mcur)
        parsed.manaMax = tonumber(mmax)
        parsed.regenMp = tonumber(mregen)
    end

    local vcur, vmax, vregen = text:match("Move:%s*%((%d+)%s*/%s*(%d+)%s*%+%s*(%d+)%)")
    if vcur and vmax then
        parsed.moveCur = tonumber(vcur)
        parsed.moveMax = tonumber(vmax)
        parsed.regenMv = tonumber(vregen)
    end
end

local function _parseTableLongExtras(text, parsed)
    local age = text:match("Age:%s*(%d+)")
    if age then parsed.age = tonumber(age) end

    local played = text:match("Played:%s*([^|]+)%|")
    if played then parsed.played = _trim(played) end

    local race = text:match("Race:%s*([^|]+)%|")
    if race then parsed.race = _trim(race) end

    local remorts = text:match("Remorts:%s*(%d+)")
    if remorts then parsed.remorts = tonumber(remorts) end

    local qp = text:match("Quest Points:%s*(%d+)")
    if qp then parsed.questPoints = tonumber(qp) end

    local hp = text:match("Honor Points:%s*(%d+)")
    if hp then parsed.honorPoints = tonumber(hp) end

    local pos = text:match("Position:%s*([^|]+)%|")
    if pos then parsed.position = _trim(pos) end

    local hunger = text:match("Hunger:%s*(%d+)")
    if hunger then parsed.hunger = tonumber(hunger) end

    local thirst = text:match("Thirst:%s*(%d+)")
    if thirst then parsed.thirst = tonumber(thirst) end

    local drunk = text:match("Drunk:%s*(%d+)")
    if drunk then parsed.drunk = tonumber(drunk) end

    -- Saves vs line
    local p = text:match("Para:%s*(%d+)")
    local r = text:match("Rod:%s*(%d+)")
    local pe = text:match("Petri:%s*(%d+)")
    local b = text:match("Breath:%s*(%d+)")
    local s = text:match("Spell:%s*(%d+)")
    if p then parsed.savePara = tonumber(p) end
    if r then parsed.saveRod = tonumber(r) end
    if pe then parsed.savePetri = tonumber(pe) end
    if b then parsed.saveBreath = tonumber(b) end
    if s then parsed.saveSpell = tonumber(s) end

    local title = text:match("Title:%s*([^\n|]+)")
    if title then parsed.title = _trim(title) end
end

local function _parseReport(text, parsed)
    -- Name + title + level line
    local name, title, lvl = text:match("This ranks you as%s+([%w_%-]+)%s+([^%(]+)%s*%(%s*level%s+(%d+)%)")
    if name then parsed.name = _trim(name) end
    if title then parsed.title = _trim(title) end
    if lvl then parsed.level = tonumber(lvl) end

    -- Class + race
    local cls, race = text:match("You are a%s+([%w_%-]+)%s+of the%s+([^%s]+)%s+race")
    if cls then parsed.class = _trim(cls) end
    if race then parsed.race = _trim(race) end

    -- Sex + age
    local age = text:match("You are a%s+(%d+)%s+year%-old%s+([%w]+)")
    if age then parsed.age = tonumber(age) end
    -- sex word like male/female
    local sexWord = text:match("You are a%s+%d+%s+year%-old%s+([%w]+)")
    if sexWord then parsed.sexWord = _trim(sexWord) end

    -- Vitals
    local hcur, hmax, mcur, mmax, vcur, vmax =
        text:match("You have%s+(%d+)%((%d+)%)%s+hit,%s+(%d+)%((%d+)%)%s+mana%s+and%s+(%d+)%((%d+)%)%s+movement points")
    if hcur and hmax then parsed.hpCur, parsed.hpMax = tonumber(hcur), tonumber(hmax) end
    if mcur and mmax then parsed.manaCur, parsed.manaMax = tonumber(mcur), tonumber(mmax) end
    if vcur and vmax then parsed.moveCur, parsed.moveMax = tonumber(vcur), tonumber(vmax) end

    -- Stats (current + original)
    local str = text:match("Current stats:%s+Str:%s+([%d/]+)")
    if str then parsed.strCur = _trim(str) end
    local strO = text:match("Original stats:%s+Str:%s+([%d/]+)")
    if strO then parsed.strBase = _trim(strO) end

    local int = text:match("Current stats:.-Int:%s+(%d+)")
    if int then parsed.int = tonumber(int) end
    local wis = text:match("Current stats:.-Wis:%s+(%d+)")
    if wis then parsed.wis = tonumber(wis) end
    local dex = text:match("Current stats:.-Dex:%s+(%d+)")
    if dex then parsed.dex = tonumber(dex) end
    local con = text:match("Current stats:.-Con:%s+(%d+)")
    if con then parsed.con = tonumber(con) end
    local cha = text:match("Current stats:.-Cha:%s+(%d+)")
    if cha then parsed.cha = tonumber(cha) end

    -- AC + alignment
    local ac = text:match("Your armor class is%s+([%-%d]+)")
    if ac then parsed.armorClass = tonumber(ac) end
    local align = text:match("alignment is%s+([%-%d]+)")
    if align then parsed.alignment = tonumber(align) end

    -- Hitroll / damroll
    local hr = text:match("Your Hitroll is%s+([%-%d]+)")
    if hr then parsed.hitroll = tonumber(hr) end
    local dr = text:match("your Damroll is%s+([%-%d]+)")
    if not dr then dr = text:match("Your Damroll is%s+([%-%d]+)") end
    if dr then parsed.damroll = tonumber(dr) end

    -- Regen factors
    local rh, rm, rv = text:match("regeneration factors are:%s+Hp:%s+(%d+)%s+Mp:%s+(%d+)%s+Mv:%s+(%d+)")
    if rh then parsed.regenHp = tonumber(rh) end
    if rm then parsed.regenMp = tonumber(rm) end
    if rv then parsed.regenMv = tonumber(rv) end

    -- Exp + to level
    local exp = text:match("You have scored%s+([%d,]+)%s+experience points")
    if exp then parsed.exp = _toNumber(exp) end
    local toLevel = text:match("You need%s+([%d,]+)%s+experience points to reach your next level")
    if toLevel then parsed.toLevel = _toNumber(toLevel) end

    -- Gold / bank
    local gold, bank = text:match("You have%s+([%d,]+)%s+gold coins on hand,%s+and%s+([%d,]+)%s+coins in the bank")
    if gold then parsed.gold = _toNumber(gold) end
    if bank then parsed.bank = _toNumber(bank) end

    -- Played
    local played = text:match("You have been playing for%s+([^\n%.]+)")
    if played then parsed.played = _trim(played) end

    -- Deaths/kills/dts/sacrifices
    local d, k, dt, sac = text:match(
    "Deaths:%s*%[(%d+)%],%s*Kills:%s*%[(%d+)%],%s*DTs:%s*%[(%d+)%],%s*Sacrifices:%s*%[(%d+)%]")
    if d then parsed.deaths = tonumber(d) end
    if k then parsed.kills = tonumber(k) end
    if dt then parsed.deathtraps = tonumber(dt) end
    if sac then parsed.sacrifices = tonumber(sac) end

    -- Saves
    local sp = text:match("Para:%s*%[(%d+)%]")
    local sr = text:match("Rod:%s*%[(%d+)%]")
    local spe = text:match("Petri:%s*%[(%d+)%]")
    local sb = text:match("Breath:%s*%[(%d+)%]")
    local ss = text:match("Spell:%s*%[(%d+)%]")
    if sp then parsed.savePara = tonumber(sp) end
    if sr then parsed.saveRod = tonumber(sr) end
    if spe then parsed.savePetri = tonumber(spe) end
    if sb then parsed.saveBreath = tonumber(sb) end
    if ss then parsed.saveSpell = tonumber(ss) end

    -- Remorts
    local rem = text:match("remorted.-%s+(%d+)%s+times")
    if rem then parsed.remorts = tonumber(rem) end

    -- QP / Honor
    local qp = text:match("You have%s+(%d+)%s+Quest Points")
    if qp then parsed.questPoints = tonumber(qp) end
    local hp = text:match("and%s+(%d+)%s+Honor Points")
    if hp then parsed.honorPoints = tonumber(hp) end

    -- Hometown
    local ht = text:match("Your hometown is%s+([%w_%-]+)")
    if ht then parsed.hometown = _trim(ht) end

    -- Position / hunger / thirst
    local pos = text:match("You are%s+([%w_%-]+)%.")
    if pos then parsed.position = _trim(pos) end
    if text:find("You are hungry", 1, true) then parsed.hungry = true end
    if text:find("You are thirsty", 1, true) then parsed.thirsty = true end
end

local function _parseScoreText(text)
    if not _isNonEmptyString(text) then return nil end

    local variant = _detectVariant(text)

    -- Legacy KV fixture remains supported
    if text:find("[DWKit SCORE FIXTURE", 1, true) then
        local p = _parseScoreFixtureKV(text)
        if type(p) == "table" then
            p._variant = "fixture_kv"
        end
        return p
    end

    local parsed = {}
    parsed._variant = variant

    if variant == "table_short" or variant == "table_long" then
        _parseTableHeader(text, parsed)
        _parseTableCore(text, parsed)
        _parseTableStats(text, parsed)
        _parseTableVitals(text, parsed)
        if variant == "table_long" then
            _parseTableLongExtras(text, parsed)
        end
        parsed._parser = "dwkit.score.mud.table.v1"
        return (next(parsed) ~= nil) and parsed or nil
    end

    if variant == "report" then
        _parseReport(text, parsed)
        parsed._parser = "dwkit.score.mud.report.v1"
        return (next(parsed) ~= nil) and parsed or nil
    end

    -- Unknown format: return nil parsed (raw still stored)
    return nil
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

        -- NOTE: do not force a save here; we only write on manual ingest/clear/wipe.
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

    local variant = _detectVariant(text)

    local snap = {
        schemaVersion = SCHEMA_VERSION,
        ts = os.time(),
        source = source,
        variant = variant, -- NEW: table_short | table_long | report | unknown | fixture_kv
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

            -- Mark as "ok" in the existing status fields (best-effort; delete is destructive but successful).
            _persist.lastSaveOk = true
            _persist.lastSaveErr = nil
            _persist.lastSaveTs = os.time()
        else
            _persistSave(source)
        end
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

        -- Fixture should parse
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
    _out("  variant     : " .. tostring(_snapshot.variant or "(none)"))
    local rawLen = (_isNonEmptyString(_snapshot.raw) and #_snapshot.raw or 0)
    _out("  rawLen      : " .. tostring(rawLen))

    if type(_snapshot.parsed) == "table" then
        local n = 0
        for _ in pairs(_snapshot.parsed) do n = n + 1 end
        _out("  parsed      : table (keys=" .. tostring(n) .. ")")
        if _isNonEmptyString(_snapshot.parsed._variant) then
            _out("  parsedType  : " .. tostring(_snapshot.parsed._variant))
        end
        if _isNonEmptyString(_snapshot.parsed._parser) then
            _out("  parser      : " .. tostring(_snapshot.parsed._parser))
        end
    else
        _out("  parsed      : nil")
    end
end

return M
