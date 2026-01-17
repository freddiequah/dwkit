-- #########################################################################
-- Module Name : dwkit.bus.event_registry
-- Owner       : Bus
-- Version     : v2026-01-17A
-- Purpose     :
--   - Canonical registry for all DWKit events (code mirror of docs/Event_Registry_v1.0.md).
--   - No events are emitted here. Registry only.
--   - Runtime-only registration helper for development (NOT persisted).
--   - Markdown export derived from the same registry data (docs sync helper).
--   - Provides SAFE contract validation to detect registry drift (no printing by default).
--
-- Public API  :
--   - getRegistryVersion() -> string   (docs registry version, e.g. v1.8)
--   - getModuleVersion()   -> string   (code module version tag)
--   - getAll() -> table copy (name -> def)
--   - listAll(opts?) -> table list (sorted by name)
--   - has(name) -> boolean
--   - help(name, opts?) -> boolean ok, table|nil defOrNil, string|nil err
--   - register(def) -> boolean ok, string|nil err   (runtime-only)
--   - toMarkdown(opts?) -> string   (docs copy helper; SAFE)
--   - validateAll(opts?) -> boolean pass, table issues
--     opts:
--       - strict: boolean (default true). When strict, producers must be non-empty.
--       - requireProducers: boolean (default follows strict).
--       - requireDescription: boolean (default true).
--
-- Events Emitted   : None
-- Events Consumed  : None
-- Persistence      : None
-- Automation Policy: Manual only
-- Dependencies     : dwkit.core.identity
-- #########################################################################

local M                           = {}

M.VERSION                         = "v2026-01-17A"

local ID                          = require("dwkit.core.identity")

local PREFIX                      = tostring(ID.eventPrefix or "DWKit:")

local EV_BOOT_READY               = PREFIX .. "Boot:Ready"
local EV_SVC_PRESENCE_UPDATED     = PREFIX .. "Service:Presence:Updated"
local EV_SVC_ACTIONMODEL_UPDATED  = PREFIX .. "Service:ActionModel:Updated"
local EV_SVC_SKILLREG_UPDATED     = PREFIX .. "Service:SkillRegistry:Updated"
local EV_SVC_SCORESTORE_UPDATED   = PREFIX .. "Service:ScoreStore:Updated"
local EV_SVC_ROOMENTITIES_UPDATED = PREFIX .. "Service:RoomEntities:Updated"
local EV_SVC_WHOSTORE_UPDATED     = PREFIX .. "Service:WhoStore:Updated"

-- -------------------------
-- Output helper (copy/paste friendly)
-- NOTE: Validator functions do not print by default.
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

-- -------------------------
-- Registry (single source of truth)
-- Notes:
-- - REG.version mirrors docs/Event_Registry_v1.0.md "## Version"
-- - M.VERSION is the code module version tag (calendar style)
-- -------------------------
local REG = {
  version = "v1.9",
  moduleVersion = M.VERSION,
  events = {
    [EV_BOOT_READY] = {
      name = EV_BOOT_READY,
      description = "Emitted once after loader.init attaches DWKit surfaces; indicates kit is ready for manual use.",
      payloadSchema = {
        ts = "number",
        tsMs = "number (epoch ms; monotonic)",
      },
      producers = {
        "dwkit.loader.init",
      },
      consumers = {
        "internal (services/ui/tests)",
      },
      notes = {
        "SAFE internal event (no gameplay commands).",
        "Manual-only: emitted only when loader.init() is invoked.",
        "Docs-first: registered in docs/Event_Registry_v1.0.md, mirrored here.",
      },
    },

    [EV_SVC_PRESENCE_UPDATED] = {
      name = EV_SVC_PRESENCE_UPDATED,
      description = "Emitted when PresenceService updates its state (SAFE; no gameplay sends).",
      payloadSchema = {
        ts = "number",
        state = "table",
        delta = "table (optional)",
        source = "string (optional)",
      },
      producers = {
        "dwkit.services.presence_service",
      },
      consumers = {
        "internal (ui/tests/integrations)",
      },
      notes = {
        "SAFE internal event (no gameplay commands).",
        "Manual-only: emitted only when service API is invoked.",
      },
    },

    [EV_SVC_ACTIONMODEL_UPDATED] = {
      name = EV_SVC_ACTIONMODEL_UPDATED,
      description = "Emitted when ActionModelService updates the action model (SAFE; data only).",
      payloadSchema = {
        ts = "number",
        model = "table",
        changed = "table (optional)",
        source = "string (optional)",
      },
      producers = {
        "dwkit.services.action_model_service",
      },
      consumers = {
        "internal (ui/tests)",
      },
      notes = {
        "SAFE internal event (no gameplay commands).",
        "Manual-only: emitted only when service API is invoked.",
      },
    },

    [EV_SVC_SKILLREG_UPDATED] = {
      name = EV_SVC_SKILLREG_UPDATED,
      description = "Emitted when SkillRegistryService updates skill/spell registry data (SAFE; data only).",
      payloadSchema = {
        ts = "number",
        registry = "table",
        changed = "table (optional)",
        source = "string (optional)",
      },
      producers = {
        "dwkit.services.skill_registry_service",
      },
      consumers = {
        "internal (ui/tests)",
      },
      notes = {
        "SAFE internal event (no gameplay commands).",
        "Manual-only: emitted only when service API is invoked.",
      },
    },

    [EV_SVC_SCORESTORE_UPDATED] = {
      name = EV_SVC_SCORESTORE_UPDATED,
      description = "Emitted when ScoreStoreService ingests a score-like text snapshot (SAFE; no gameplay sends).",
      payloadSchema = {
        ts = "number",
        snapshot = "table",
        source = "string (optional)",
      },
      producers = {
        "dwkit.services.score_store_service",
      },
      consumers = {
        "internal (future ui/services/tests)",
      },
      notes = {
        "SAFE internal event (no gameplay commands).",
        "Emitted when ScoreStoreService ingest API is invoked (may be triggered by passive capture during loader.init, or manual/fixture ingestion).",
        "Parsing is optional; raw capture is the stable core contract.",
      },
    },

    [EV_SVC_ROOMENTITIES_UPDATED] = {
      name = EV_SVC_ROOMENTITIES_UPDATED,
      description = "Emitted when RoomEntitiesService updates its room entity classification state (SAFE; data only).",
      payloadSchema = {
        ts = "number",
        state = "table",
        delta = "table (optional)",
        source = "string (optional)",
      },
      producers = {
        "dwkit.services.roomentities_service",
      },
      consumers = {
        "internal (ui/tests/integrations)",
      },
      notes = {
        "SAFE internal event (no gameplay commands).",
        "Manual-only: emitted only when service API is invoked.",
        "Primary consumer is ui_autorefresh and RoomEntities UI modules.",
      },
    },

    [EV_SVC_WHOSTORE_UPDATED] = {
      name = EV_SVC_WHOSTORE_UPDATED,
      description =
      "Emitted when WhoStoreService updates its authoritative player-name set derived from WHO parsing (SAFE; no gameplay sends).",
      payloadSchema = {
        ts = "number",
        state = "table",
        delta = "table (optional)",
        source = "string (optional)",
      },
      producers = {
        "dwkit.services.whostore_service",
      },
      consumers = {
        "internal (roomentities_service/ui/tests/integrations)",
      },
      notes = {
        "SAFE internal event (no gameplay commands).",
        "Manual-only: emitted only when service API is invoked.",
        "Primary consumer is RoomEntitiesService for best-effort player reclassification.",
      },
    },
  }
}

-- -------------------------
-- Validation helpers
-- -------------------------
local function _isNonEmptyString(s) return type(s) == "string" and s ~= "" end

local function _startsWith(s, prefix)
  if type(s) ~= "string" or type(prefix) ~= "string" then return false end
  return s:sub(1, #prefix) == prefix
end

local function _isArrayLike(t)
  if type(t) ~= "table" then return false end
  local n = #t
  if n == 0 then
    -- could be empty list; treat as array-like if no non-numeric keys
    for k, _ in pairs(t) do
      if type(k) ~= "number" then return false end
    end
    return true
  end
  for i = 1, n do
    if t[i] == nil then return false end
  end
  -- Ensure no obvious non-numeric keys
  for k, _ in pairs(t) do
    if type(k) ~= "number" then return false end
  end
  return true
end

local function _validateStringArray(fieldName, t, allowEmpty)
  if t == nil then
    return true, nil
  end
  if type(t) ~= "table" then
    return false, fieldName .. " must be a table (array)"
  end
  if not _isArrayLike(t) then
    return false, fieldName .. " must be an array-like table"
  end
  if (not allowEmpty) and (#t == 0) then
    return false, fieldName .. " must be non-empty"
  end
  for i, v in ipairs(t) do
    if not _isNonEmptyString(v) then
      return false, fieldName .. "[" .. tostring(i) .. "] must be a non-empty string"
    end
  end
  return true, nil
end

local function _validatePayloadSchema(ps)
  if ps == nil then return true, nil end
  if type(ps) ~= "table" then return false, "payloadSchema must be a table if provided" end
  for k, v in pairs(ps) do
    if not _isNonEmptyString(k) then return false, "payloadSchema keys must be non-empty strings" end
    if not _isNonEmptyString(v) then return false, "payloadSchema[" .. tostring(k) .. "] must be a non-empty string" end
  end
  return true, nil
end

local function _validateDef(def, opts)
  opts = opts or {}
  local requireDescription = (opts.requireDescription ~= false)

  if type(def) ~= "table" then return false, "def must be a table" end
  if not _isNonEmptyString(def.name) then return false, "missing/invalid: name" end
  if not _startsWith(def.name, ID.eventPrefix) then
    return false, "invalid: name must start with EventPrefix (" .. tostring(ID.eventPrefix) .. ")"
  end
  if requireDescription and (not _isNonEmptyString(def.description)) then
    return false, "missing/invalid: description"
  end

  local okPS, errPS = _validatePayloadSchema(def.payloadSchema)
  if not okPS then return false, errPS end

  -- producers/consumers/notes should be arrays if present; strictness applied by caller
  if def.producers ~= nil and type(def.producers) ~= "table" then
    return false,
        "invalid: producers must be a table if provided"
  end
  if def.consumers ~= nil and type(def.consumers) ~= "table" then
    return false,
        "invalid: consumers must be a table if provided"
  end
  if def.notes ~= nil and type(def.notes) ~= "table" then return false, "invalid: notes must be a table if provided" end

  return true, nil
end

local function _mkIssue(evName, message)
  return { name = tostring(evName or ""), error = tostring(message or "") }
end

-- -------------------------
-- Safe copy helpers
-- -------------------------
local function _shallowCopy(t)
  local out = {}
  for k, v in pairs(t) do out[k] = v end
  return out
end

local function _copyDef(def)
  local c         = _shallowCopy(def)
  c.payloadSchema = _shallowCopy(def.payloadSchema or {})
  c.producers     = _shallowCopy(def.producers or {})
  c.consumers     = _shallowCopy(def.consumers or {})
  c.notes         = _shallowCopy(def.notes or {})
  return c
end

local function _collectList()
  local list = {}
  for _, def in pairs(REG.events) do
    table.insert(list, _copyDef(def))
  end
  table.sort(list, function(a, b) return tostring(a.name) < tostring(b.name) end)
  return list
end

-- -------------------------
-- Markdown export (docs helper; SAFE)
-- -------------------------
local function _mdEscape(s)
  s = tostring(s or "")
  s = s:gsub("\r\n", "\n")
  s = s:gsub("\r", "\n")
  return s
end

local function _mdLine(lines, s)
  lines[#lines + 1] = tostring(s or "")
end

local function _mdBullet(lines, s)
  _mdLine(lines, "- " .. _mdEscape(s))
end

local function _mdIndentBullet(lines, s)
  _mdLine(lines, "  - " .. _mdEscape(s))
end

local function _mdSection(lines, title)
  _mdLine(lines, "")
  _mdLine(lines, "### " .. _mdEscape(title))
end

local function _mdValueLine(lines, label, value)
  _mdLine(lines, "- " .. _mdEscape(label) .. ": " .. _mdEscape(value))
end

function M.toMarkdown(opts)
  opts = opts or {}

  local lines = {}
  _mdLine(lines, "# Event Registry (Runtime Export)")
  _mdLine(lines, "")
  _mdLine(lines, "## Source")
  _mdBullet(lines, "Generated from code registry mirror: dwkit.bus.event_registry " .. tostring(M.VERSION or "unknown"))
  _mdBullet(lines, "Registry version (docs): " .. tostring(REG.version or "unknown"))
  _mdBullet(lines, "Generated at ts: " .. tostring(os.time()))
  _mdLine(lines, "")
  _mdLine(lines, "## Notes")
  _mdBullet(lines, "This is a copy/paste helper. It does not emit events or change runtime behavior.")
  _mdBullet(lines, "For list view, use: dwevents. For details, use: dwevent <EventName>.")
  _mdLine(lines, "")
  _mdLine(lines, "## Events")

  local list = _collectList()
  for _, def in ipairs(list) do
    _mdSection(lines, def.name)

    _mdValueLine(lines, "Description", tostring(def.description or ""))
    if def.payloadSchema and next(def.payloadSchema) ~= nil then
      _mdLine(lines, "- PayloadSchema:")
      local keys = {}
      for k, _ in pairs(def.payloadSchema) do keys[#keys + 1] = tostring(k) end
      table.sort(keys)
      for _, k in ipairs(keys) do
        _mdIndentBullet(lines, k .. ": " .. tostring(def.payloadSchema[k]))
      end
    else
      _mdLine(lines, "- PayloadSchema: (none)")
    end

    if def.producers and #def.producers > 0 then
      _mdLine(lines, "- Producers:")
      for _, p in ipairs(def.producers) do _mdIndentBullet(lines, tostring(p)) end
    else
      _mdLine(lines, "- Producers: (unknown)")
    end

    if def.consumers and #def.consumers > 0 then
      _mdLine(lines, "- Consumers:")
      for _, c in ipairs(def.consumers) do _mdIndentBullet(lines, tostring(c)) end
    else
      _mdLine(lines, "- Consumers: (unknown)")
    end

    if def.notes and #def.notes > 0 then
      _mdLine(lines, "- Notes:")
      for _, n in ipairs(def.notes) do _mdIndentBullet(lines, tostring(n)) end
    else
      _mdLine(lines, "- Notes: (none)")
    end
  end

  return table.concat(lines, "\n")
end

-- -------------------------
-- Public API
-- -------------------------
function M.getRegistryVersion()
  return tostring(REG.version or "unknown")
end

function M.getModuleVersion()
  return tostring(M.VERSION or "unknown")
end

function M.getAll()
  local out = {}
  for name, def in pairs(REG.events) do
    out[name] = _copyDef(def)
  end
  return out
end

function M.has(name)
  if not _isNonEmptyString(name) then return false end
  return REG.events[name] ~= nil
end

local function _printList(title, list)
  _out("[DWKit Events] " .. title .. " (source: dwkit.bus.event_registry " .. tostring(REG.version) .. ")")
  if #list == 0 then
    _out("  (none)")
    return
  end
  for _, def in ipairs(list) do
    _out(string.format("  - %s  | %s", tostring(def.name), tostring(def.description)))
  end
end

function M.listAll(opts)
  opts = opts or {}
  local list = _collectList()
  if not opts.quiet then _printList("ALL", list) end
  return list
end

function M.help(name, opts)
  opts = opts or {}
  if not _isNonEmptyString(name) then
    return false, nil, "help(name): name must be a non-empty string"
  end

  local def = REG.events[name]
  if not def then
    return false, nil, "Unknown event: " .. tostring(name)
  end

  local c = _copyDef(def)

  if not opts.quiet then
    _out("[DWKit Event Help] " ..
      tostring(c.name) .. " (source: dwkit.bus.event_registry " .. tostring(REG.version) .. ")")
    _out("  Desc     : " .. tostring(c.description))
    _out("  Producers: " .. ((c.producers and #c.producers > 0) and table.concat(c.producers, ", ") or "(unknown)"))
    _out("  Consumers: " .. ((c.consumers and #c.consumers > 0) and table.concat(c.consumers, ", ") or "(unknown)"))
    _out("  PayloadSchema keys:")
    local keys = {}
    for k, _ in pairs(c.payloadSchema or {}) do table.insert(keys, tostring(k)) end
    table.sort(keys)
    if #keys == 0 then
      _out("    - (none)")
    else
      for _, k in ipairs(keys) do _out("    - " .. k) end
    end
    if c.notes and #c.notes > 0 then
      _out("  Notes:")
      for _, n in ipairs(c.notes) do _out("    - " .. tostring(n)) end
    end
  end

  return true, c, nil
end

-- Runtime-only registration (NOT persisted)
function M.register(def)
  local ok, err = _validateDef(def, { requireDescription = true })
  if not ok then return false, err end

  local name = def.name
  if REG.events[name] then
    return false, "Event already exists: " .. tostring(name)
  end

  REG.events[name] = _copyDef(def)
  return true, nil
end

-- SAFE validation for the static registry content (no printing by default).
-- Returns pass, issues[] where each issue = {name=<eventName>, error=<string>}
function M.validateAll(opts)
  opts = opts or {}
  local strict = (opts.strict ~= false)

  local requireProducers = opts.requireProducers
  if requireProducers == nil then requireProducers = strict end

  local issues = {}

  if not _isNonEmptyString(REG.version) then
    table.insert(issues, _mkIssue("(registry)", "REG.version must be a non-empty string"))
  end

  if type(REG.events) ~= "table" then
    table.insert(issues, _mkIssue("(registry)", "REG.events must be a table"))
    return false, issues
  end

  for k, def in pairs(REG.events) do
    local keyName = tostring(k or "")
    local okDef, errDef = _validateDef(def, opts)
    if not okDef then
      table.insert(issues, _mkIssue(keyName, errDef))
    else
      local defName = tostring(def.name or "")
      if keyName ~= defName then
        table.insert(issues, _mkIssue(defName ~= "" and defName or keyName, "registry key must equal def.name"))
      end

      -- producers must be array-like (and non-empty if strict/requireProducers)
      local okP, errP = _validateStringArray("producers", def.producers, not requireProducers)
      if not okP then table.insert(issues, _mkIssue(defName, errP)) end

      local okC, errC = _validateStringArray("consumers", def.consumers, true)
      if not okC then table.insert(issues, _mkIssue(defName, errC)) end

      local okN, errN = _validateStringArray("notes", def.notes, true)
      if not okN then table.insert(issues, _mkIssue(defName, errN)) end
    end
  end

  return (#issues == 0), issues
end

return M
