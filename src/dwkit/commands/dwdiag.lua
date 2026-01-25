-- #########################################################################
-- Module Name : dwkit.commands.dwdiag
-- Owner       : Commands
-- Version     : v2026-01-25A
-- Purpose     :
--   - Handler for "dwdiag" command surface.
--   - SAFE: prints a diagnostic bundle (versions, boot, services, event diag status).
--   - Manual only. No gameplay sends. No timers.
--
-- Public API  :
--   - dispatch(ctx, kit) -> boolean ok, string|nil err
--   - reset() -> nil
-- #########################################################################

local M = {}
M.VERSION = "v2026-01-25A"

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

local function _getCtx(ctx)
  ctx = (type(ctx) == "table") and ctx or {}
  return {
    out = (type(ctx.out) == "function") and ctx.out or _fallbackOut,
    err = (type(ctx.err) == "function") and ctx.err or _fallbackErr,
    ppTable = (type(ctx.ppTable) == "function") and ctx.ppTable or nil,
    callBestEffort = (type(ctx.callBestEffort) == "function") and ctx.callBestEffort or nil,
  }
end

local function _resolveKit(kit)
  if type(kit) == "table" then return kit end
  if type(_G) == "table" and type(_G.DWKit) == "table" then return _G.DWKit end
  if type(DWKit) == "table" then return DWKit end
  return nil
end

local function _safeRequire(modName)
  local ok, mod = pcall(require, modName)
  if ok and type(mod) == "table" then return true, mod, nil end
  return false, nil, tostring(mod)
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
    local K = _resolveKit(kit)
    if type(K) == "table" and type(K.bus) == "table" and type(K.bus.eventBus) == "table" then
      return K.bus.eventBus
    end
    local ok, mod = _safeRequire("dwkit.bus.event_bus")
    if ok then return mod end
    return nil
  end

  local function getEventRegistry()
    local K = _resolveKit(kit)
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

function M.dispatch(ctx, kit)
  local C = _getCtx(ctx)
  local K = _resolveKit(kit)

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
      -- event_diag expects (ctx, stateTable)
      -- state lives in alias module historically; for dwdiag we just print "module available" + bus/reg status.
      -- We supply a tiny synthetic state to avoid nil errors (printStatus should be tolerant).
      local diagCtx = _makeEventDiagCtx(C, K)
      local syntheticState = { maxLog = 50, log = {}, tapToken = nil, subs = {} }
      local okCall, errOrNil = pcall(modE.printStatus, diagCtx, syntheticState)
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
