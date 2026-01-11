-- #########################################################################
-- Module Name : dwkit.bus.event_bus
-- Owner       : Bus
-- Version     : v2026-01-11A
-- Purpose     :
--   - SAFE internal event bus (in-process publish/subscribe).
--   - Enforces: events MUST be registered in dwkit.bus.event_registry first.
--   - No Mudlet raiseEvent / tempTrigger / automation. Pure Lua dispatch.
--   - Adds SAFE "tap" subscribers (observe every emit) to support diagnostics harness
--     without changing runtime behavior for normal consumers.
--
-- Public API  :
--   - on(eventName, handlerFn) -> boolean ok, number|nil token, string|nil err
--   - off(token) -> boolean ok, string|nil err
--   - emit(eventName, payload) -> boolean ok, number deliveredCount, table errors
--   - tapOn(handlerFn) -> boolean ok, number|nil token, string|nil err
--   - tapOff(token) -> boolean ok, string|nil err
--   - getStats() -> table
--
-- Events Emitted   : None (this is the emitter)
-- Events Consumed  : None
-- Persistence      : None
-- Automation Policy: Manual only
-- Dependencies     : dwkit.core.identity, dwkit.bus.event_registry
-- #########################################################################

local M = {}

M.VERSION = "v2026-01-11A"

local ID  = require("dwkit.core.identity")
local REG = require("dwkit.bus.event_registry")

local function _isNonEmptyString(s) return type(s) == "string" and s ~= "" end

local function _startsWith(s, prefix)
  if type(s) ~= "string" or type(prefix) ~= "string" then return false end
  return s:sub(1, #prefix) == prefix
end

local STATE = {
  nextToken   = 1,

  -- Per-event subscriptions
  subsByToken = {},    -- token -> { eventName=..., fn=... }
  subsByEvent = {},    -- eventName -> { [token]=fn, ... }

  -- Tap subscriptions (observe every emitted registered event)
  tapByToken  = {},    -- token -> fn(payload, eventName, token)
  tapErrors   = 0,

  -- Stats
  emitted       = 0,
  delivered     = 0,
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

local function _nextToken()
  local token = STATE.nextToken
  STATE.nextToken = STATE.nextToken + 1
  return token
end

function M.on(eventName, handlerFn)
  local ok, err = _validateEventName(eventName)
  if not ok then return false, nil, err end

  if type(handlerFn) ~= "function" then
    return false, nil, "handlerFn must be a function"
  end

  local token = _nextToken()

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

-- Tap API: observe every emitted (validated) event.
-- This does NOT change delivery semantics; tap runs best-effort and is isolated via pcall.
function M.tapOn(handlerFn)
  if type(handlerFn) ~= "function" then
    return false, nil, "handlerFn must be a function"
  end

  local token = _nextToken()
  STATE.tapByToken[token] = handlerFn
  return true, token, nil
end

function M.tapOff(token)
  if type(token) ~= "number" then
    return false, "token must be a number"
  end

  if not STATE.tapByToken[token] then
    return false, "unknown token: " .. tostring(token)
  end

  STATE.tapByToken[token] = nil
  return true, nil
end

local function _snapshotTap()
  local snap = {}
  for token, fn in pairs(STATE.tapByToken) do
    if type(fn) == "function" then
      snap[#snap + 1] = { token = token, fn = fn }
    end
  end
  return snap
end

local function _snapshotBucket(bucket)
  local snap = {}
  for token, fn in pairs(bucket) do
    if type(fn) == "function" then
      snap[#snap + 1] = { token = token, fn = fn }
    end
  end
  return snap
end

function M.emit(eventName, payload)
  local ok, err = _validateEventName(eventName)
  if not ok then
    return false, 0, { err }
  end

  STATE.emitted = STATE.emitted + 1

  local delivered = 0
  local errors = {}

  -- 1) Tap handlers (observe all emits). Best-effort; failures do not block.
  local tapSnap = _snapshotTap()
  for _, rec in ipairs(tapSnap) do
    local token = rec.token
    local fn    = rec.fn
    local okTap, tapErr = pcall(fn, payload, eventName, token)
    if not okTap then
      STATE.tapErrors = STATE.tapErrors + 1
      -- Keep tap errors out of the main errors list to avoid changing emitter semantics.
      -- Tap is diagnostics-only; emit() result should remain about core delivery.
    end
  end

  -- 2) Normal per-event subscribers
  local bucket = STATE.subsByEvent[eventName]
  if not bucket then
    return true, 0, errors
  end

  -- Snapshot subscribers first (best practice):
  -- avoids undefined iteration behavior if handlers call off() during emit().
  local snapshot = _snapshotBucket(bucket)

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

  local taps = 0
  for _ in pairs(STATE.tapByToken) do taps = taps + 1 end

  return {
    version = M.VERSION,
    emitted = STATE.emitted,
    delivered = STATE.delivered,
    handlerErrors = STATE.handlerErrors,
    tapErrors = STATE.tapErrors,
    subscribers = subs,
    eventsWithSubscribers = eventsWithSubs,
    tapSubscribers = taps,
  }
end

return M
