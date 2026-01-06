-- #########################################################################
-- Module Name : dwkit.bus.event_bus
-- Owner       : Bus
-- Version     : v2026-01-06H
-- Purpose     :
--   - SAFE internal event bus skeleton (in-process publish/subscribe).
--   - Enforces: events MUST be registered in dwkit.bus.event_registry first.
--   - No Mudlet raiseEvent / tempTrigger / automation. Pure Lua dispatch.
--
-- Public API  :
--   - on(eventName, handlerFn) -> boolean ok, number|nil token, string|nil err
--   - off(token) -> boolean ok, string|nil err
--   - emit(eventName, payload) -> boolean ok, number deliveredCount, table errors
--   - getStats() -> table
--
-- Events Emitted   : None (this is the emitter)
-- Events Consumed  : None
-- Persistence      : None
-- Automation Policy: Manual only
-- Dependencies     : dwkit.core.identity, dwkit.bus.event_registry
-- #########################################################################

local M = {}

M.VERSION = "v2026-01-06H"

local ID  = require("dwkit.core.identity")
local REG = require("dwkit.bus.event_registry")

local function _isNonEmptyString(s) return type(s) == "string" and s ~= "" end

local function _startsWith(s, prefix)
  if type(s) ~= "string" or type(prefix) ~= "string" then return false end
  return s:sub(1, #prefix) == prefix
end

local STATE = {
  nextToken   = 1,
  subsByToken = {},    -- token -> { eventName=..., fn=... }
  subsByEvent = {},    -- eventName -> { [token]=fn, ... }
  emitted     = 0,
  delivered   = 0,
  handlerErrors = 0,
}

local function _validateEventName(eventName)
  if not _isNonEmptyString(eventName) then
    return false, "eventName must be a non-empty string"
  end
  if not _startsWith(eventName, ID.eventPrefix) then
    return false, "eventName must start with EventPrefix (" .. tostring(ID.eventPrefix) .. ")"
  end
  if not REG.has(eventName) then
    return false, "eventName not registered: " .. tostring(eventName)
  end
  return true, nil
end

function M.on(eventName, handlerFn)
  local ok, err = _validateEventName(eventName)
  if not ok then return false, nil, err end

  if type(handlerFn) ~= "function" then
    return false, nil, "handlerFn must be a function"
  end

  local token = STATE.nextToken
  STATE.nextToken = STATE.nextToken + 1

  STATE.subsByToken[token] = { eventName = eventName, fn = handlerFn }
  STATE.subsByEvent[eventName] = STATE.subsByEvent[eventName] or {}
  STATE.subsByEvent[eventName][token] = handlerFn

  return true, token, nil
end

function M.off(token)
  if type(token) ~= "number" then
    return false, "token must be a number"
  end

  local rec = STATE.subsByToken[token]
  if not rec then
    return false, "unknown token: " .. tostring(token)
  end

  local ev = rec.eventName
  STATE.subsByToken[token] = nil

  if STATE.subsByEvent[ev] then
    STATE.subsByEvent[ev][token] = nil

    -- Clean up empty buckets (helps keep state tidy)
    local any = false
    for _ in pairs(STATE.subsByEvent[ev]) do any = true break end
    if not any then
      STATE.subsByEvent[ev] = nil
    end
  end

  return true, nil
end

function M.emit(eventName, payload)
  local ok, err = _validateEventName(eventName)
  if not ok then
    return false, 0, { err }
  end

  STATE.emitted = STATE.emitted + 1

  local delivered = 0
  local errors = {}

  local bucket = STATE.subsByEvent[eventName]
  if not bucket then
    return true, 0, errors
  end

  -- Snapshot subscribers first (best practice):
  -- avoids undefined iteration behavior if handlers call off() during emit().
  local snapshot = {}
  for token, fn in pairs(bucket) do
    if type(fn) == "function" then
      table.insert(snapshot, { token = token, fn = fn })
    end
  end

  for _, rec in ipairs(snapshot) do
    local token = rec.token
    local fn    = rec.fn

    local okCall, callErr = pcall(fn, payload, eventName, token)
    if okCall then
      delivered = delivered + 1
      STATE.delivered = STATE.delivered + 1
    else
      STATE.handlerErrors = STATE.handlerErrors + 1
      table.insert(errors, "handler error token=" .. tostring(token) .. " :: " .. tostring(callErr))
    end
  end

  return (#errors == 0), delivered, errors
end

function M.getStats()
  local subs = 0
  for _ in pairs(STATE.subsByToken) do subs = subs + 1 end

  local eventsWithSubs = 0
  for _ in pairs(STATE.subsByEvent) do eventsWithSubs = eventsWithSubs + 1 end

  return {
    version = M.VERSION,
    emitted = STATE.emitted,
    delivered = STATE.delivered,
    handlerErrors = STATE.handlerErrors,
    subscribers = subs,
    eventsWithSubscribers = eventsWithSubs,
  }
end

return M
