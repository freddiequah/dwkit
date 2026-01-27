-- #########################################################################
-- Module Name : dwkit.commands.dwdiag
-- Owner       : Commands
-- Version     : v2026-01-27C
-- Purpose     :
--   - Handler for "dwdiag" command surface.
--   - SAFE: prints a diagnostic bundle (versions, boot, services, event diag status).
--   - Manual only. No gameplay sends. No timers.
--
-- Dispatch compatibility:
--   - dispatch(ctx, kit)
--   - dispatch(tokens)
--   - dispatch(ctx, tokens)
--   - dispatch(ctx, kit, tokens)
-- #########################################################################

local M = {}
M.VERSION = "v2026-01-27C"

local function _fallbackOut(line)
  line = tostring(line or "")
  if type(cecho) == "function" then
    cecho(line .. "\n")
  elseif type(echo) == "function" then
    echo(line .. "\n")
  else
    print(line)
  end
end

local function _fallbackErr(msg)
  _fallbackOut("[DWKit Diag] ERROR: " .. tostring(msg))
end

local function _safeRequire(modName)
  local ok, mod = pcall(require, modName)
  if ok and type(mod) == "table" then return true, mod, nil end
  return false, nil, tostring(mod)
end

local function _getKit(kit)
  if type(kit) == "table" then return kit end
  if type(_G) == "table" and type(_G.DWKit) == "table" then return _G.DWKit end
  if type(DWKit) == "table" then return DWKit end
  return nil
end

local function _getCtx(ctx)
  ctx = (type(ctx) == "table") and ctx or {}
  return {
    out = (type(ctx.out) == "function") and ctx.out or _fallbackOut,
    err = (type(ctx.err) == "function") and ctx.err or _fallbackErr,
    ppTable = (type(ctx.ppTable) == "function") and ctx.ppTable or nil,
    callBestEffort = (type(ctx.callBestEffort) == "function") and ctx.callBestEffort or nil,
  }
end

local function _tryDispatch(C, modName, ...)
  local okM, mod, errM = _safeRequire(modName)
  if not okM or type(mod.dispatch) ~= "function" then
    return false, "missing " .. modName .. " (" .. tostring(errM) .. ")"
  end
  local okCall, a, b = pcall(mod.dispatch, C, ...)
  if okCall and a ~= false then
    return true, nil
  end
  return false, tostring(b or a or "dispatch failed")
end

local function _makeEventDiagCtx(C, kit)
  local function getEventBus()
    local K = _getKit(kit)
    if type(K) == "table" and type(K.bus) == "table" and type(K.bus.eventBus) == "table" then
      return K.bus.eventBus
    end
    local ok, mod = _safeRequire("dwkit.bus.event_bus")
    if ok then return mod end
    return nil
  end

  local function getEventRegistry()
    local K = _getKit(kit)
    if type(K) == "table" and type(K.bus) == "table" and type(K.bus.eventRegistry) == "table" then
      return K.bus.eventRegistry
    end
    local ok, mod = _safeRequire("dwkit.bus.event_registry")
    if ok then return mod end
    return nil
  end

  return {
    out = C.out,
    err = C.err,
    ppTable = C.ppTable,
    hasEventBus = function() return type(getEventBus()) == "table" end,
    hasEventRegistry = function() return type(getEventRegistry()) == "table" end,
    getEventBus = function() return getEventBus() end,
    getEventRegistry = function() return getEventRegistry() end,
  }
end

local function _getEventDiagStateBestEffort(kit)
  local K = _getKit(kit)

  -- Preferred: dedicated state service (post-slimming)
  do
    local okS, S = _safeRequire("dwkit.services.event_diag_state")
    if okS and type(S) == "table" then
      if type(S.getState) == "function" then
        -- Prefer passing kit (matches how command_aliases uses it)
        local ok, st = pcall(S.getState, K)
        if ok and type(st) == "table" then return st end

        -- Fallbacks for older signatures
        ok, st = pcall(S.getState, S)
        if ok and type(st) == "table" then return st end
        ok, st = pcall(S.getState)
        if ok and type(st) == "table" then return st end
      end
      if type(S.STATE) == "table" then return S.STATE end
    end
  end

  -- Fallback: if kit exposes it somewhere
  if type(K) == "table" and type(K.services) == "table" then
    local s = K.services.eventDiagState
    if type(s) == "table" then
      if type(s.getState) == "function" then
        local ok, st = pcall(s.getState, K)
        if ok and type(st) == "table" then return st end
        ok, st = pcall(s.getState, s)
        if ok and type(st) == "table" then return st end
        ok, st = pcall(s.getState)
        if ok and type(st) == "table" then return st end
      end
      if type(s.STATE) == "table" then return s.STATE end
    end
  end

  -- Last resort: synthetic state (keeps printStatus from nil-crashing)
  return { maxLog = 50, log = {}, tapToken = nil, subs = {} }
end

local function _isArrayLike(t)
  if type(t) ~= "table" then return false end
  local n = #t
  if n == 0 then return false end
  for i = 1, n do if t[i] == nil then return false end end
  return true
end

function M.dispatch(a1, a2, a3)
  local ctx = nil
  local kit = nil

  -- dispatch(tokens)
  if _isArrayLike(a1) and tostring(a1[1] or "") == "dwdiag" then
    ctx = nil
    kit = nil
  else
    ctx = a1

    -- dispatch(ctx, tokens)
    if _isArrayLike(a2) and tostring(a2[1] or "") == "dwdiag" then
      kit = nil
      -- dispatch(ctx, kit, tokens)
    elseif _isArrayLike(a3) and tostring(a3[1] or "") == "dwdiag" then
      kit = a2
    else
      -- dispatch(ctx, kit)
      kit = a2
    end
  end

  local C = _getCtx(ctx)
  local K = _getKit(kit)

  C.out("[DWKit Diag] bundle (dwdiag)")
  C.out("  NOTE: SAFE + manual-only. Does not enable event tap or subscriptions.")
  C.out("")

  C.out("== dwversion ==")
  C.out("")
  _tryDispatch(C, "dwkit.commands.dwversion", K, "(via dwdiag)")
  C.out("")

  C.out("== dwboot ==")
  C.out("")
  _tryDispatch(C, "dwkit.commands.dwboot")
  C.out("")

  C.out("== dwservices ==")
  C.out("")
  _tryDispatch(C, "dwkit.commands.dwservices", K)
  C.out("")

  C.out("== event diag status ==")
  C.out("")
  do
    local okE, modE, errE = _safeRequire("dwkit.commands.event_diag")
    if okE and type(modE.printStatus) == "function" then
      local diagCtx = _makeEventDiagCtx(C, K)
      local st = _getEventDiagStateBestEffort(K)
      local okCall, errOrNil = pcall(modE.printStatus, diagCtx, st)
      if not okCall then
        C.err("event_diag.printStatus threw error: " .. tostring(errOrNil))
      end
    else
      C.err("dwkit.commands.event_diag not available (" .. tostring(errE) .. ")")
    end
  end

  return true, nil
end

function M.reset()
  -- no persistent state
end

return M
