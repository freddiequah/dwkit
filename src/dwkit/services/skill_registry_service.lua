-- #########################################################################
-- Module Name : dwkit.services.skill_registry_service
-- Owner       : Services
-- Version     : v2026-03-10B
-- Purpose     :
--   - SAFE SkillRegistryService (data only).
--   - Owns skill/spell registry (data-driven), emits updates.
--   - Provides class normalization + schema validation for ActionPad needs.
--   - Provides lookups by practiceKey and alias, plus list helpers.
--   - Supports transitional cross-class learn-spec declarations while keeping
--     legacy classKey + minLevel defs valid.
--   - Provides class-specific learn requirement resolution from canonical defs.
--   - No UI, no persistence, no timers, no send().
--   - Hardened validation: detects duplicate practiceKey + alias collisions.
--
-- Public API  :
--   - getVersion() -> string
--   - getRegistry() -> table copy
--   - getDef(key) -> table|nil
--   - getKeysSorted() -> table (array of keys)
--   - normalizeClassKey(raw) -> string|nil classKey, string|nil err
--   - normalizePracticeKey(raw) -> string|nil practiceKey, string|nil err
--   - validateDef(def, opts?) -> boolean ok, string|nil err
--   - validateAll(opts?) -> boolean ok, table issues
--   - resolveByPracticeKey(practiceKey) -> table|nil
--   - resolveByAlias(alias) -> table|nil
--   - listByClass(classKey, kind?) -> table (array of defs)
--   - listByKind(kind) -> table (array of defs)
--   - getLearnRequirementForClass(defOrKey, classKey?) -> table|nil req, string|nil err
--   - setRegistry(registry, opts?) -> boolean ok, string|nil err
--   - upsert(key, def, opts?) -> boolean ok, string|nil err
--   - remove(key, opts?) -> boolean ok, string|nil err
--   - onUpdated(handlerFn) -> boolean ok, number|nil token, string|nil err
--
-- Events Emitted:
--   - DWKit:Service:SkillRegistry:Updated
-- Automation Policy: Manual only
-- Dependencies     : dwkit.core.identity, dwkit.bus.event_bus,
--                    dwkit.data.skill_registry.*
-- #########################################################################

local M               = {}

M.VERSION             = "v2026-03-10B"

local ID              = require("dwkit.core.identity")
local BUS             = require("dwkit.bus.event_bus")

local CLERIC_DATA     = require("dwkit.data.skill_registry.cleric")
local WARRIOR_DATA    = require("dwkit.data.skill_registry.warrior")
local THIEF_DATA      = require("dwkit.data.skill_registry.thief")
local SEED_MISC_DATA  = require("dwkit.data.skill_registry.seed_misc")

local EV_UPDATED      = tostring(ID.eventPrefix or "DWKit:") .. "Service:SkillRegistry:Updated"

-- Locked class keys (ActionPad agreement)
local CLASS_KEYS      = {
    ["cleric"] = true,
    ["thief"] = true,
    ["warrior"] = true,
    ["mage"] = true,
    ["paladin"] = true,
    ["anti-paladin"] = true,
    ["ranger"] = true,
    ["monk"] = true,
    ["bard"] = true,
    ["pirate"] = true,
}

-- Alias mapping: compact form (lower, strip spaces + hyphen) -> canonical classKey
local CLASS_ALIASES   = {
    ["cleric"] = "cleric",
    ["thief"] = "thief",
    ["warrior"] = "warrior",
    ["mage"] = "mage",
    ["paladin"] = "paladin",
    ["antipaladin"] = "anti-paladin",
    ["antipal"] = "anti-paladin",
    ["apal"] = "anti-paladin",
    ["ranger"] = "ranger",
    ["monk"] = "monk",
    ["bard"] = "bard",
    ["pirate"] = "pirate",
}

-- Canonical kinds (ActionPad agreement)
local KIND_KEYS       = {
    ["skill"] = true,
    ["spell"] = true,
    ["race"] = true,
    ["weapon"] = true,
}

-- Legacy kind mapping (backward compatible with earlier seeds)
local LEGACY_KIND_MAP = {
    ["race-skill"] = "race",
    ["weapon-prof"] = "weapon",
}

local STATE           = {
    registry = {}, -- key -> def table
    lastTs = nil,
    updates = 0,

    -- indexes (rebuilt on changes; SAFE)
    practiceIndex = {}, -- practiceKey -> key (first-wins; collisions are reported by validateAll)
    aliasIndex = {},    -- alias(normalized) -> key (first-wins; collisions are reported by validateAll)
}

local function _shallowCopy(t)
    local out = {}
    if type(t) ~= "table" then return out end
    for k, v in pairs(t) do out[k] = v end
    return out
end

local function _copyRegistry(r)
    local out = {}
    if type(r) ~= "table" then return out end
    for k, def in pairs(r) do
        if type(def) == "table" then
            out[k] = _shallowCopy(def)
        else
            out[k] = def
        end
    end
    return out
end

local function _trim(s)
    s = tostring(s or "")
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    return s
end

local function _lowerCollapseSpaces(s)
    s = _trim(s):lower()
    s = s:gsub("%s+", " ")
    return s
end

local function _compactKey(s)
    s = _lowerCollapseSpaces(s)
    s = s:gsub("[%s%-]", "")
    return s
end

local function _getEntriesFromModule(mod)
    if type(mod) ~= "table" or type(mod.getEntries) ~= "function" then
        return {}
    end
    local ok, entries = pcall(mod.getEntries)
    if not ok or type(entries) ~= "table" then
        return {}
    end
    return entries
end

local function _mergeEntries(dst, src)
    if type(dst) ~= "table" or type(src) ~= "table" then
        return dst
    end
    for k, v in pairs(src) do
        dst[k] = v
    end
    return dst
end

local function _buildDefaultRegistry()
    local out = {}
    _mergeEntries(out, _getEntriesFromModule(CLERIC_DATA))
    _mergeEntries(out, _getEntriesFromModule(WARRIOR_DATA))
    _mergeEntries(out, _getEntriesFromModule(THIEF_DATA))
    _mergeEntries(out, _getEntriesFromModule(SEED_MISC_DATA))
    return out
end

local DEFAULT_REGISTRY = _buildDefaultRegistry()

function M.normalizeClassKey(raw)
    if raw == nil then return nil, "normalizeClassKey(raw): raw is nil" end
    local s = _trim(raw)
    if s == "" then return nil, "normalizeClassKey(raw): raw is empty" end

    local direct = _lowerCollapseSpaces(s)
    if direct == "anti paladin" or direct == "anti-paladin" then
        return "anti-paladin", nil
    end

    local compact = _compactKey(s)
    local mapped = CLASS_ALIASES[compact]
    if mapped ~= nil then
        return mapped, nil
    end

    local maybe = direct
    if maybe == "anti paladin" then maybe = "anti-paladin" end
    if CLASS_KEYS[maybe] == true then
        return maybe, nil
    end

    return nil, "normalizeClassKey(raw): unknown class: " .. tostring(raw)
end

function M.normalizePracticeKey(raw)
    if raw == nil then return nil, "normalizePracticeKey(raw): raw is nil" end
    local s = _lowerCollapseSpaces(raw)
    if s == "" then return nil, "normalizePracticeKey(raw): raw is empty" end
    return s, nil
end

local function _isInt(n)
    if type(n) ~= "number" then return false end
    return n == math.floor(n)
end

local function _normalizeAliases(t)
    if t == nil then return nil end
    if type(t) ~= "table" then return nil end
    local out = {}
    local seen = {}
    for i = 1, #t do
        local vRaw = _trim(t[i])
        if vRaw ~= "" then
            local vNorm, _ = M.normalizePracticeKey(vRaw)
            if vNorm and vNorm ~= "" and seen[vNorm] ~= true then
                seen[vNorm] = true
                out[#out + 1] = vNorm
            end
        end
    end
    if #out == 0 then return nil end
    return out
end

local function _normalizeTags(t)
    if t == nil then return {} end
    if type(t) ~= "table" then return {} end
    local out = {}
    for i = 1, #t do
        local v = _trim(t[i])
        if v ~= "" then out[#out + 1] = v end
    end
    return out
end

local function _normalizeKind(kind)
    kind = _trim(kind)
    if kind == "" then return kind end
    local k = _lowerCollapseSpaces(kind)
    if LEGACY_KIND_MAP[k] ~= nil then
        return LEGACY_KIND_MAP[k]
    end
    return k
end

local function _pushIssue(issues, key, err, meta)
    local it = { key = tostring(key), error = tostring(err) }
    if type(meta) == "table" then
        for k, v in pairs(meta) do it[k] = v end
    end
    issues[#issues + 1] = it
end

local function _normalizeLearnSpecs(t)
    if t == nil then return nil end
    if type(t) ~= "table" then return nil end

    local out = {}
    local seen = {}

    for i = 1, #t do
        local spec = t[i]
        if type(spec) == "table" then
            local row = _shallowCopy(spec)

            if row.classKey ~= nil then
                local ckNorm, _ = M.normalizeClassKey(row.classKey)
                if ckNorm then row.classKey = ckNorm end
            end

            if row.tags ~= nil then
                row.tags = _normalizeTags(row.tags)
            end

            local sig = tostring(row.classKey or "") .. "|" .. tostring(row.minLevel or "")
            if seen[sig] ~= true then
                seen[sig] = true
                out[#out + 1] = row
            end
        end
    end

    if #out == 0 then return nil end
    return out
end

local function _hasLearnSpecs(def)
    return type(def) == "table" and type(def.learnSpecs) == "table" and #def.learnSpecs > 0
end

local function _hasLegacyLearn(def)
    return type(def) == "table"
        and type(def.classKey) == "string" and _trim(def.classKey) ~= ""
        and type(def.minLevel) == "number"
end

local function _defMatchesClass(def, ck)
    if type(def) ~= "table" or type(ck) ~= "string" or ck == "" then
        return false
    end

    if tostring(def.classKey or "") == ck then
        return true
    end

    local specs = def.learnSpecs
    if type(specs) == "table" then
        for i = 1, #specs do
            local spec = specs[i]
            if type(spec) == "table" and tostring(spec.classKey or "") == ck then
                return true
            end
        end
    end

    return false
end

local function _firstLearnSpec(def)
    if type(def) ~= "table" then return nil end
    local specs = def.learnSpecs
    if type(specs) ~= "table" or #specs <= 0 then return nil end
    local first = specs[1]
    if type(first) ~= "table" then return nil end
    return _shallowCopy(first)
end

local function _legacyLearnRequirement(def)
    if _hasLegacyLearn(def) ~= true then
        return nil
    end
    return {
        classKey = tostring(def.classKey),
        minLevel = tonumber(def.minLevel),
        tags = _normalizeTags(def.tags or {}),
        source = "legacy",
        matched = true,
    }
end

local function _matchLearnSpec(def, ck)
    if type(def) ~= "table" or type(ck) ~= "string" or ck == "" then
        return nil
    end
    local specs = def.learnSpecs
    if type(specs) ~= "table" then
        return nil
    end
    for i = 1, #specs do
        local spec = specs[i]
        if type(spec) == "table" and tostring(spec.classKey or "") == ck then
            local out = _shallowCopy(spec)
            out.classKey = tostring(out.classKey or "")
            out.minLevel = tonumber(out.minLevel or 0) or 0
            out.tags = _normalizeTags(out.tags or {})
            out.source = "learnSpecs"
            out.matched = true
            out.learnSpecIndex = i
            return out
        end
    end
    return nil
end

local function _resolveDefInput(defOrKey)
    if type(defOrKey) == "table" then
        return defOrKey, nil
    end
    if type(defOrKey) ~= "string" or _trim(defOrKey) == "" then
        return nil, "getLearnRequirementForClass(defOrKey, classKey): defOrKey invalid"
    end

    local def = M.getDef(_trim(defOrKey))
    if type(def) == "table" then
        return def, nil
    end

    def = M.resolveByPracticeKey(defOrKey)
    if type(def) == "table" then
        return def, nil
    end

    def = M.resolveByAlias(defOrKey)
    if type(def) == "table" then
        return def, nil
    end

    return nil, "getLearnRequirementForClass(defOrKey, classKey): def not found: " .. tostring(defOrKey)
end

function M.validateDef(def, opts)
    opts = opts or {}
    if type(def) ~= "table" then
        return false, "validateDef(def): def must be a table"
    end

    if type(def.id) ~= "string" or _trim(def.id) == "" then
        return false, "validateDef(def): missing/invalid required field: id"
    end
    if type(def.displayName) ~= "string" or _trim(def.displayName) == "" then
        return false, "validateDef(def): missing/invalid required field: displayName"
    end
    if type(def.practiceKey) ~= "string" or _trim(def.practiceKey) == "" then
        return false, "validateDef(def): missing/invalid required field: practiceKey"
    end
    if type(def.kind) ~= "string" or _trim(def.kind) == "" then
        return false, "validateDef(def): missing/invalid required field: kind"
    end

    local kindNorm = _normalizeKind(def.kind)
    if KIND_KEYS[kindNorm] ~= true then
        return false, "validateDef(def): invalid kind: " .. tostring(def.kind)
    end

    if type(def.tags) ~= "table" then
        return false, "validateDef(def): missing/invalid required field: tags (array)"
    end
    for i = 1, #def.tags do
        if type(def.tags[i]) ~= "string" then
            return false, "validateDef(def): tags must be array of strings"
        end
    end

    local pk, pkErr = M.normalizePracticeKey(def.practiceKey)
    if not pk then
        return false, "validateDef(def): practiceKey invalid: " .. tostring(pkErr)
    end

    local hasLegacy = _hasLegacyLearn(def)
    local hasSpecs = _hasLearnSpecs(def)

    if hasLegacy ~= true and hasSpecs ~= true then
        return false,
            "validateDef(def): must provide legacy classKey+minLevel or learnSpecs[]"
    end

    if hasLegacy == true then
        local ck, ckErr = M.normalizeClassKey(def.classKey)
        if not ck then
            return false, "validateDef(def): classKey invalid: " .. tostring(ckErr)
        end

        if type(def.minLevel) ~= "number" or _isInt(def.minLevel) ~= true or def.minLevel < 0 then
            return false, "validateDef(def): missing/invalid required field: minLevel (int >= 0)"
        end

        if opts.strictClassList == true and CLASS_KEYS[ck] ~= true then
            return false, "validateDef(def): classKey not in locked class list: " .. tostring(ck)
        end
    end

    if hasSpecs == true then
        local specs = def.learnSpecs
        for i = 1, #specs do
            local spec = specs[i]
            if type(spec) ~= "table" then
                return false, "validateDef(def): learnSpecs must be array of tables"
            end
            if type(spec.classKey) ~= "string" or _trim(spec.classKey) == "" then
                return false, "validateDef(def): learnSpecs[].classKey is required"
            end
            local ck, ckErr = M.normalizeClassKey(spec.classKey)
            if not ck then
                return false, "validateDef(def): learnSpecs[].classKey invalid: " .. tostring(ckErr)
            end
            if type(spec.minLevel) ~= "number" or _isInt(spec.minLevel) ~= true or spec.minLevel < 0 then
                return false, "validateDef(def): learnSpecs[].minLevel must be int >= 0"
            end
            if spec.tags ~= nil then
                if type(spec.tags) ~= "table" then
                    return false, "validateDef(def): learnSpecs[].tags must be array (when present)"
                end
                for j = 1, #spec.tags do
                    if type(spec.tags[j]) ~= "string" then
                        return false, "validateDef(def): learnSpecs[].tags must be array of strings"
                    end
                end
            end
            if opts.strictClassList == true and CLASS_KEYS[ck] ~= true then
                return false, "validateDef(def): learnSpecs[].classKey not in locked class list: " .. tostring(ck)
            end
        end
    end

    if def.aliases ~= nil then
        if type(def.aliases) ~= "table" then
            return false, "validateDef(def): aliases must be array (when present)"
        end
        for i = 1, #def.aliases do
            if type(def.aliases[i]) ~= "string" or _trim(def.aliases[i]) == "" then
                return false, "validateDef(def): aliases must be non-empty strings"
            end
        end
    end

    return true, nil
end

local function _normalizeDef(def)
    local out = _shallowCopy(def)

    if out.classKey ~= nil then
        local ckNorm, _ = M.normalizeClassKey(out.classKey)
        if ckNorm then out.classKey = ckNorm end
    end

    local pk = out.practiceKey
    local pkNorm, _ = M.normalizePracticeKey(pk)
    if pkNorm then out.practiceKey = pkNorm end

    out.kind = _normalizeKind(out.kind)
    out.aliases = _normalizeAliases(out.aliases)
    out.tags = _normalizeTags(out.tags)
    out.learnSpecs = _normalizeLearnSpecs(out.learnSpecs)

    return out
end

local function _rebuildIndexes()
    local p = {}
    local a = {}

    for key, def in pairs(STATE.registry) do
        if type(key) == "string" and key ~= "" and type(def) == "table" then
            local pk = tostring(def.practiceKey or "")
            if pk ~= "" and p[pk] == nil then
                p[pk] = key
            end

            local aliases = def.aliases
            if type(aliases) == "table" then
                for i = 1, #aliases do
                    local al = tostring(aliases[i] or "")
                    if al ~= "" and a[al] == nil then
                        a[al] = key
                    end
                end
            end
        end
    end

    STATE.practiceIndex = p
    STATE.aliasIndex = a
end

local function _emit(changed, source)
    local payload = {
        ts = os.time(),
        registry = _copyRegistry(STATE.registry),
    }
    if type(changed) == "table" then payload.changed = _shallowCopy(changed) end
    if type(source) == "string" and source ~= "" then payload.source = source end

    local ok, delivered, errs = BUS.emit(EV_UPDATED, payload)
    if not ok then
        local first = (type(errs) == "table" and errs[1]) and tostring(errs[1]) or "emit failed"
        return false, first
    end
    return true, nil
end

function M.getVersion()
    return tostring(M.VERSION)
end

function M.getRegistry()
    return _copyRegistry(STATE.registry)
end

function M.getDef(key)
    if type(key) ~= "string" or key == "" then return nil end
    local def = STATE.registry[key]
    if type(def) ~= "table" then return nil end
    return _shallowCopy(def)
end

function M.getKeysSorted()
    local keys = {}
    for k, _ in pairs(STATE.registry) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    return keys
end

function M.resolveByPracticeKey(practiceKey)
    local pk, err = M.normalizePracticeKey(practiceKey)
    if not pk then return nil end

    local key = STATE.practiceIndex[pk]
    if not key then return nil end

    return M.getDef(key)
end

function M.resolveByAlias(alias)
    local a, err = M.normalizePracticeKey(alias)
    if not a then return nil end

    local def = M.resolveByPracticeKey(a)
    if def then return def end

    local key = STATE.aliasIndex[a]
    if not key then return nil end

    return M.getDef(key)
end

function M.listByClass(classKey, kind)
    local ck, err = M.normalizeClassKey(classKey)
    if not ck then return {} end

    local kindNorm = nil
    if kind ~= nil then
        kindNorm = _normalizeKind(kind)
        if KIND_KEYS[kindNorm] ~= true then
            return {}
        end
    end

    local out = {}
    for _, def in pairs(STATE.registry) do
        if type(def) == "table" and _defMatchesClass(def, ck) == true then
            if kindNorm == nil or tostring(def.kind) == kindNorm then
                out[#out + 1] = _shallowCopy(def)
            end
        end
    end

    table.sort(out, function(a, b)
        return tostring(a.practiceKey or "") < tostring(b.practiceKey or "")
    end)

    return out
end

function M.listByKind(kind)
    local kindNorm = _normalizeKind(kind)
    if KIND_KEYS[kindNorm] ~= true then
        return {}
    end

    local out = {}
    for _, def in pairs(STATE.registry) do
        if type(def) == "table" and tostring(def.kind) == kindNorm then
            out[#out + 1] = _shallowCopy(def)
        end
    end

    table.sort(out, function(a, b)
        return tostring(a.practiceKey or "") < tostring(b.practiceKey or "")
    end)

    return out
end

function M.getLearnRequirementForClass(defOrKey, classKey)
    local def, errDef = _resolveDefInput(defOrKey)
    if type(def) ~= "table" then
        return nil, tostring(errDef or "def not found")
    end

    if classKey ~= nil then
        local ck, errCk = M.normalizeClassKey(classKey)
        if not ck then
            return nil, "getLearnRequirementForClass(defOrKey, classKey): classKey invalid: " .. tostring(errCk)
        end

        local spec = _matchLearnSpec(def, ck)
        if spec then
            return spec, nil
        end

        local legacy = _legacyLearnRequirement(def)
        if legacy and tostring(legacy.classKey or "") == ck then
            return legacy, nil
        end

        return nil, "getLearnRequirementForClass(defOrKey, classKey): no learn requirement for classKey=" .. tostring(ck)
    end

    local legacy = _legacyLearnRequirement(def)
    if legacy then
        return legacy, nil
    end

    local first = _firstLearnSpec(def)
    if type(first) == "table" then
        first.classKey = tostring(first.classKey or "")
        first.minLevel = tonumber(first.minLevel or 0) or 0
        first.tags = _normalizeTags(first.tags or {})
        first.source = "learnSpecs:first"
        first.matched = true
        first.learnSpecIndex = 1
        return first, nil
    end

    return nil, "getLearnRequirementForClass(defOrKey, classKey): def has no learn requirement"
end

function M.validateAll(opts)
    opts = opts or {}
    local strictClassList = (opts.strictClassList ~= false)

    local issues = {}

    local seenPractice = {}
    local seenAlias = {}

    for k, def in pairs(STATE.registry) do
        if type(k) ~= "string" or k == "" then
            _pushIssue(issues, tostring(k), "registry key must be non-empty string")
        elseif type(def) ~= "table" then
            _pushIssue(issues, tostring(k), "def must be a table")
        else
            local ok, err = M.validateDef(def, { strictClassList = strictClassList })
            if not ok then
                _pushIssue(issues, tostring(k), tostring(err))
            else
                if tostring(def.id) ~= tostring(k) then
                    _pushIssue(issues, tostring(k), "def.id must match registry key", { id = tostring(def.id) })
                end

                local pk = tostring(def.practiceKey or "")
                if pk ~= "" then
                    local first = seenPractice[pk]
                    if first == nil then
                        seenPractice[pk] = tostring(k)
                    elseif tostring(first) ~= tostring(k) then
                        _pushIssue(issues, tostring(k), "duplicate practiceKey (must be unique)",
                            { practiceKey = pk, firstKey = tostring(first) })
                    end
                end

                if type(def.aliases) == "table" then
                    for i = 1, #def.aliases do
                        local al = tostring(def.aliases[i] or "")
                        if al ~= "" then
                            local firstA = seenAlias[al]
                            if firstA == nil then
                                seenAlias[al] = tostring(k)
                            elseif tostring(firstA) ~= tostring(k) then
                                _pushIssue(issues, tostring(k), "alias collision (must be unique)",
                                    { alias = al, firstKey = tostring(firstA) })
                            end

                            local firstPk = seenPractice[al]
                            if firstPk ~= nil and tostring(firstPk) ~= tostring(k) then
                                _pushIssue(issues, tostring(k), "alias collides with another def.practiceKey",
                                    { alias = al, practiceKeyKey = tostring(firstPk) })
                            end
                        end
                    end
                end
            end
        end
    end

    return (#issues == 0), issues
end

function M.setRegistry(registry, opts)
    opts = opts or {}
    if type(registry) ~= "table" then
        return false, "setRegistry(registry): registry must be a table"
    end

    local nextReg = {}
    for k, def in pairs(registry) do
        if type(k) ~= "string" or k == "" then
            return false, "setRegistry(registry): registry key must be non-empty string"
        end
        if type(def) ~= "table" then
            return false, "setRegistry(registry): def must be table for key: " .. tostring(k)
        end
        local norm = _normalizeDef(def)

        norm.id = tostring(norm.id or "")
        if norm.id == "" then norm.id = tostring(k) end
        if tostring(norm.id) ~= tostring(k) then
            return false,
                "setRegistry(registry): def.id must match key. key=" .. tostring(k) .. " id=" .. tostring(norm.id)
        end

        local okV, errV = M.validateDef(norm, { strictClassList = true })
        if not okV then
            return false, "setRegistry(registry): invalid def for key=" .. tostring(k) .. " err=" .. tostring(errV)
        end
        nextReg[k] = _shallowCopy(norm)
    end

    STATE.registry = nextReg
    _rebuildIndexes()

    local okAll, issues = M.validateAll({ strictClassList = true })
    if not okAll then
        return false, "setRegistry(registry): validateAll failed issues=" .. tostring(#issues)
    end

    STATE.lastTs = os.time()
    STATE.updates = STATE.updates + 1

    local okEmit, errEmit = _emit({ setRegistry = true }, opts.source)
    if not okEmit then return false, errEmit end
    return true, nil
end

function M.upsert(key, def, opts)
    opts = opts or {}
    if type(key) ~= "string" or key == "" then
        return false, "upsert(key, def): key must be a non-empty string"
    end
    if type(def) ~= "table" then
        return false, "upsert(key, def): def must be a table"
    end

    local norm = _normalizeDef(def)

    norm.id = tostring(norm.id or "")
    if norm.id == "" then norm.id = tostring(key) end
    if tostring(norm.id) ~= tostring(key) then
        return false, "upsert(key, def): def.id must match key. key=" .. tostring(key) .. " id=" .. tostring(norm.id)
    end

    local okV, errV = M.validateDef(norm, { strictClassList = true })
    if not okV then
        return false, "upsert(key, def): invalid def err=" .. tostring(errV)
    end

    STATE.registry[key] = _shallowCopy(norm)
    _rebuildIndexes()

    local okAll, issues = M.validateAll({ strictClassList = true })
    if not okAll then
        STATE.registry[key] = nil
        _rebuildIndexes()
        return false, "upsert(key, def): validateAll failed issues=" .. tostring(#issues)
    end

    STATE.lastTs = os.time()
    STATE.updates = STATE.updates + 1

    local okEmit, errEmit = _emit({ upsert = key }, opts.source)
    if not okEmit then return false, errEmit end
    return true, nil
end

function M.remove(key, opts)
    opts = opts or {}
    if type(key) ~= "string" or key == "" then
        return false, "remove(key): key must be a non-empty string"
    end

    if STATE.registry[key] == nil then
        return false, "remove(key): unknown key: " .. tostring(key)
    end

    STATE.registry[key] = nil
    _rebuildIndexes()

    STATE.lastTs = os.time()
    STATE.updates = STATE.updates + 1

    local okEmit, errEmit = _emit({ remove = key }, opts.source)
    if not okEmit then return false, errEmit end
    return true, nil
end

function M.onUpdated(handlerFn)
    return BUS.on(EV_UPDATED, handlerFn)
end

function M.getStats()
    local n = 0
    for _ in pairs(STATE.registry) do n = n + 1 end
    return {
        version = M.VERSION,
        lastTs = STATE.lastTs,
        updates = STATE.updates,
        entries = n,
    }
end

do
    local nextReg = {}
    for k, def in pairs(DEFAULT_REGISTRY) do
        if type(k) == "string" and k ~= "" and type(def) == "table" then
            local norm = _normalizeDef(def)

            norm.id = tostring(norm.id or "")
            if norm.id == "" then norm.id = tostring(k) end
            if tostring(norm.id) ~= tostring(k) then
                -- skip invalid seed
            else
                local okV = M.validateDef(norm, { strictClassList = true })
                if okV then
                    nextReg[k] = _shallowCopy(norm)
                end
            end
        end
    end
    STATE.registry = nextReg
    _rebuildIndexes()
end

return M
