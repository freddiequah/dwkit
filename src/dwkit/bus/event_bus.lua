-- #########################################################################
-- Module Name : dwkit.bus.event_bus
-- Owner       : Bus
-- Version     : v2026-01-29D
-- Purpose     :
--   - SAFE internal event bus (in-process publish/subscribe).
--   - Enforces: events MUST be registered in dwkit.bus.event_registry first.
--   - No Mudlet raiseEvent / tempTrigger / automation. Pure Lua dispatch.
--   - Adds SAFE "tap" subscribers (observe every emit) to support diagnostics harness
--     without changing runtime behavior for normal consumers.
--
--   - API NORMALIZATION (v2026-01-19B):
--       Support both dot-call and colon-call styles for all public APIs:
--         BUS.on(...)   and  BUS:on(...)
--         BUS.emit(...) and  BUS:emit(...)
--         BUS.off(...)  and  BUS:off(...)
--         BUS.tapOn(...) and BUS:tapOn(...)
--         BUS.tapOff(...) and BUS:tapOff(...)
--
--       Also supports swapped emit arg order (back-compat):
--         BUS.emit(eventName, payload)
--         BUS.emit(payload, eventName)
--         BUS:emit(eventName, payload)
--         BUS:emit(payload, eventName)
--
--   - META FORWARDING (v2026-01-29D):
--       emit(eventName, payload, meta?) forwards meta as 4th arg to handlers:
--         handler(payload, eventName, token, meta)
--       Backward compatible: existing handlers that accept 1-3 args still work.
--       Tap handlers also receive meta as 4th arg:
--         tap(payload, eventName, token, meta)
--
-- Public API  :
--   - on(eventName, handlerFn) -> boolean ok, number|nil token, string|nil err
--   - off(token) -> boolean ok, string|nil err
--   - emit(eventName, payload, meta?) -> boolean ok, number deliveredCount, table errors
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

local M   = {}

M.VERSION = "v2026-01-29D"

local ID  = require("dwkit.core.identity")
local REG = require("dwkit.bus.event_registry")

local function _isNonEmptyString(s) return type(s) == "string" and s ~= "" end

local function _startsWith(s, prefix)
  if type(s) ~= "string" or type(prefix) ~= "string" then return false end
  return s:sub(1, #prefix) == prefix
end

local function _eventPrefix()
  -- defensive: identity is authoritative, but keep SAFE fallback
  return tostring(ID.eventPrefix or "DWKit:")
end

local STATE = {
  nextToken     = 1,

  -- Per-event subscriptions
  subsByToken   = {}, -- token -> { eventName=..., fn=... }
  subsByEvent   = {}, -- eventName -> { [token]=fn, ... }

  -- Tap subscriptions (observe every emitted registered event)
  tapByToken    = {}, -- token -> fn(payload, eventName, token, meta)
  tapErrors     = 0,

  -- Stats
  emitted       = 0,
  delivered     = 0,
  handlerErrors = 0,
}

local function _validateEventName(eventName)
  if not _isNonEmptyString(eventName) then
    return false, "eventName must be a non-empty string"
  end

  local pref = _eventPrefix()
  if not _startsWith(eventName, pref) then
    return false, "eventName must start with EventPrefix (" .. tostring(pref) .. ")"
  end

  if type(REG) ~= "table" or type(REG.has) ~= "function" then
    return false, "event registry not available"
  end

  local okHas, exists = pcall(REG.has, eventName)
  if not okHas then
    return false, "event registry check failed"
  end
  if not exists then
    return false, "eventName not registered: " .. tostring(eventName)
  end

  return true, nil
end

local function _nextToken()
  local token = STATE.nextToken
  STATE.nextToken = STATE.nextToken + 1
  return token
end

-- Normalize dot vs colon calls:
--   M.fn(a,b,...)     -> a,b
--   M:fn(a,b,...)     -> self=M, a,b
local function _isSelfCall(x)
  return (x == M)
end

local function _norm_on(a, b, c)
  -- returns: eventName, handlerFn
  if _isSelfCall(a) then
    return b, c
  end
  return a, b
end

local function _norm_off(a, b)
  -- returns: token
  if _isSelfCall(a) then
    return b
  end
  return a
end

local function _norm_tapOn(a, b)
  -- returns: handlerFn
  if _isSelfCall(a) then
    return b
  end
  return a
end

local function _norm_tapOff(a, b)
  -- returns: token
  if _isSelfCall(a) then
    return b
  end
  return a
end

local function _norm_emit(a, b, c, d)
  -- returns: eventName, payload, meta
  -- Support:
  --   emit(eventName, payload, meta?)
  --   emit(payload, eventName, meta?)
  --   :emit(eventName, payload, meta?)
  --   :emit(payload, eventName, meta?)
  --
  -- NOTE: "meta" is optional and is forwarded to handlers as 4th arg.
  if _isSelfCall(a) then
    -- colon call
    if type(b) == "string" then
      return b, c, d
    end
    if type(b) == "table" and type(c) == "string" then
      return c, b, d
    end
    -- fall back (let validation error be meaningful)
    return b, c, d
  end

  -- dot call
  if type(a) == "string" then
    return a, b, c
  end
  if type(a) == "table" and type(b) == "string" then
    return b, a, c
  end

  return a, b, c
end

function M.on(a, b, c)
  local eventName, handlerFn = _norm_on(a, b, c)

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

function M.off(a, b)
  local token = _norm_off(a, b)

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
    for _ in pairs(STATE.subsByEvent[ev]) do
      any = true
      break
    end
    if not any then
      STATE.subsByEvent[ev] = nil
    end
  end

  return true, nil
end

-- Tap API: observe every emitted (validated) event.
-- This does NOT change delivery semantics; tap runs best-effort and is isolated via pcall.
function M.tapOn(a, b)
  local handlerFn = _norm_tapOn(a, b)

  if type(handlerFn) ~= "function" then
    return false, nil, "handlerFn must be a function"
  end

  local token = _nextToken()
  STATE.tapByToken[token] = handlerFn
  return true, token, nil
end

function M.tapOff(a, b)
  local token = _norm_tapOff(a, b)

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

function M.emit(a, b, c, d)
  local eventName, payload, meta = _norm_emit(a, b, c, d)

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
    local token    = rec.token
    local fn       = rec.fn

    local okTap, _ = pcall(fn, payload, eventName, token, meta)
    if not okTap then
      STATE.tapErrors = STATE.tapErrors + 1
      -- Tap is diagnostics-only; keep tap errors out of main emit() errors list.
    end
  end

  -- 2) Normal per-event subscribers
  local bucket = STATE.subsByEvent[eventName]
  if not bucket then
    return true, 0, errors
  end

  -- Snapshot subscribers first:
  -- avoids undefined iteration behavior if handlers call off() during emit().
  local snapshot = _snapshotBucket(bucket)

  for _, rec in ipairs(snapshot) do
    local token           = rec.token
    local fn              = rec.fn

    local okCall, callErr = pcall(fn, payload, eventName, token, meta)
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
