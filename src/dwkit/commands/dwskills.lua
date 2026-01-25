-- #########################################################################
-- Module Name : dwkit.commands.dwskills
-- Owner       : Commands
-- Version     : v2026-01-25A
-- Purpose     :
--   - Handler for "dwskills" command surface.
--   - SAFE: prints SkillRegistryService snapshot/state.
--   - No gameplay sends. No timers. Manual only.
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
  _fallbackOut("[DWKit Skills] ERROR: " .. tostring(msg))
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

local function _callBestEffort(C, obj, fnName, ...)
  if C.callBestEffort then
    return C.callBestEffort(obj, fnName, ...)
  end
  if type(obj) ~= "table" or type(obj[fnName]) ~= "function" then
    return false, nil, nil, nil, "missing function: " .. tostring(fnName)
  end
  local ok, a, b, c = pcall(obj[fnName], ...)
  if ok then return true, a, b, c, nil end
  return false, nil, nil, nil, tostring(a)
end

local function _pp(C, t, opts)
  if type(C.ppTable) == "function" then
    C.ppTable(t, opts)
  else
    C.out(tostring(t))
  end
end

local function _printServiceSnapshot(C, label, svc)
  C.out("[DWKit Service] " .. tostring(label))
  C.out("  version=" .. tostring(svc.VERSION or "unknown"))

  if type(svc.getState) == "function" then
    local ok, state, _, _, err = _callBestEffort(C, svc, "getState")
    if ok then
      C.out("  getState(): OK")
      _pp(C, state, { maxDepth = 2, maxItems = 30 })
      return true
    end
    C.out("  getState(): ERROR")
    if err and err ~= "" then C.out("    err=" .. tostring(err)) end
  end

  if type(svc.getAll) == "function" then
    local ok, state, _, _, err = _callBestEffort(C, svc, "getAll")
    if ok then
      C.out("  getAll(): OK")
      _pp(C, state, { maxDepth = 2, maxItems = 30 })
      return true
    end
    C.out("  getAll(): ERROR")
    if err and err ~= "" then C.out("    err=" .. tostring(err)) end
  end

  local keys = {}
  for k, _ in pairs(svc) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)

  C.out("  APIs available (keys on service table): count=" .. tostring(#keys))
  local limit = math.min(#keys, 40)
  for i = 1, limit do
    C.out("    - " .. tostring(keys[i]))
  end
  if #keys > limit then
    C.out("    ... (" .. tostring(#keys - limit) .. " more)")
  end

  return true
end

function M.dispatch(ctx, kit)
  local C = _getCtx(ctx)
  local K = _resolveKit(kit)
  if type(K) ~= "table" then
    C.err("DWKit global not available. Run loader.init() first.")
    return false, "DWKit missing"
  end
  if type(K.services) ~= "table" then
    C.err("DWKit.services not available. Run loader.init() first.")
    return false, "services missing"
  end

  local svc = K.services.skillRegistryService
  if type(svc) ~= "table" then
    C.err("DWKit.services.skillRegistryService not available. Run loader.init() first.")
    return false, "skillRegistryService missing"
  end

  return _printServiceSnapshot(C, "SkillRegistryService", svc), nil
end

function M.reset()
  -- no persistent state
end

return M
