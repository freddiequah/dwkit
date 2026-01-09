-- #########################################################################
-- Module Name : dwkit.bus.event_registry
-- Owner       : Bus
-- Version     : v2026-01-09A
-- Purpose     :
--   - Canonical registry for all DWKit events (code mirror of docs/Event_Registry_v1.0.md).
--   - No events are emitted here. Registry only.
--   - Runtime-only registration helper for development (NOT persisted).
--
-- Public API  :
--   - getRegistryVersion() -> string   (docs registry version, e.g. v1.6)
--   - getModuleVersion()   -> string   (code module version tag)
--   - getAll() -> table copy (name -> def)
--   - listAll(opts?) -> table list (sorted by name)
--   - has(name) -> boolean
--   - help(name, opts?) -> boolean ok, table|nil defOrNil, string|nil err
--   - register(def) -> boolean ok, string|nil err   (runtime-only)
--
-- Events Emitted   : None
-- Events Consumed  : None
-- Persistence      : None
-- Automation Policy: Manual only
-- Dependencies     : dwkit.core.identity
-- #########################################################################

local M                          = {}

M.VERSION                        = "v2026-01-09A"

local ID                         = require("dwkit.core.identity")

local PREFIX                     = tostring(ID.eventPrefix or "DWKit:")

local EV_BOOT_READY              = PREFIX .. "Boot:Ready"
local EV_SVC_PRESENCE_UPDATED    = PREFIX .. "Service:Presence:Updated"
local EV_SVC_ACTIONMODEL_UPDATED = PREFIX .. "Service:ActionModel:Updated"
local EV_SVC_SKILLREG_UPDATED    = PREFIX .. "Service:SkillRegistry:Updated"

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

-- -------------------------
-- Registry (single source of truth)
-- Notes:
-- - REG.version mirrors docs/Event_Registry_v1.0.md "## Version"
-- - M.VERSION is the code module version tag (calendar style)
-- -------------------------
local REG = {
  version = "v1.6",
  moduleVersion = M.VERSION,
  events = {
    [EV_BOOT_READY] = {
      name = EV_BOOT_READY,
      description = "Emitted once after loader.init attaches DWKit surfaces; indicates kit is ready for manual use.",
      payloadSchema = {
        ts = "number",
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
  }
}

-- -------------------------
-- Validation (minimal, strict)
-- -------------------------
local function _isNonEmptyString(s) return type(s) == "string" and s ~= "" end

local function _startsWith(s, prefix)
  if type(s) ~= "string" or type(prefix) ~= "string" then return false end
  return s:sub(1, #prefix) == prefix
end

local function _validateDef(def)
  if type(def) ~= "table" then return false, "def must be a table" end
  if not _isNonEmptyString(def.name) then return false, "missing/invalid: name" end
  if not _startsWith(def.name, ID.eventPrefix) then
    return false, "invalid: name must start with EventPrefix (" .. tostring(ID.eventPrefix) .. ")"
  end
  if not _isNonEmptyString(def.description) then return false, "missing/invalid: description" end

  if def.payloadSchema ~= nil and type(def.payloadSchema) ~= "table" then
    return false, "invalid: payloadSchema must be a table if provided"
  end
  if def.producers ~= nil and type(def.producers) ~= "table" then
    return false, "invalid: producers must be a table if provided"
  end
  if def.consumers ~= nil and type(def.consumers) ~= "table" then
    return false, "invalid: consumers must be a table if provided"
  end

  return true, nil
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
  local ok, err = _validateDef(def)
  if not ok then return false, err end

  local name = def.name
  if REG.events[name] then
    return false, "Event already exists: " .. tostring(name)
  end

  REG.events[name] = _copyDef(def)
  return true, nil
end

return M
