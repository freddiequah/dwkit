-- #########################################################################
-- Module Name : dwkit.commands.dwpresence
-- Owner       : Commands
-- Version     : v2026-01-21G
-- Purpose     :
--   - SAFE command handler for:
--       * dwpresence
--   - Prints PresenceService snapshot (best-effort, SAFE).
--
-- Public API  :
--   - dispatch(ctx, kit?) -> nil
--   - reset() -> nil
-- #########################################################################

local M = {}

M.VERSION = "v2026-01-21G"

local function _out(ctx, line)
  if ctx and type(ctx.out) == "function" then
    ctx.out(line)
    return
  end
  if type(cecho) == "function" then
    cecho(tostring(line or "") .. "\n")
  elseif type(echo) == "function" then
    echo(tostring(line or "") .. "\n")
  else
    print(tostring(line or ""))
  end
end

local function _err(ctx, msg)
  if ctx and type(ctx.err) == "function" then
    ctx.err(msg)
    return
  end
  _out(ctx, "[DWKit] ERROR: " .. tostring(msg))
end

local function _getKit(kit)
  if type(kit) == "table" then return kit end
  if type(_G) == "table" and type(_G.DWKit) == "table" then
    return _G.DWKit
  end
  if type(DWKit) == "table" then
    return DWKit
  end
  return nil
end

local function _getService(kit, name)
  if type(kit) ~= "table" or type(kit.services) ~= "table" then return nil end
  local s = kit.services[name]
  if type(s) == "table" then return s end
  return nil
end

local function _tryCall(fn, ...)
  if type(fn) ~= "function" then return false, nil end
  local ok, res = pcall(fn, ...)
  return ok, res
end

function M.dispatch(ctx, kit)
  kit = _getKit(kit)

  _out(ctx, "[DWKit Service] PresenceService")
  local svc = _getService(kit, "presenceService")
  if not svc then
    _err(ctx, "DWKit.services.presenceService not available. Run loader.init() first.")
    return
  end

  _out(ctx, "  version=" .. tostring(svc.VERSION or "unknown"))

  -- Prefer ctx.ppTable if available for consistent formatting
  local pp = (ctx and type(ctx.ppTable) == "function") and ctx.ppTable or nil

  if type(svc.getState) == "function" then
    local ok, state = _tryCall(svc.getState)
    if ok then
      _out(ctx, "  getState(): OK")
      if pp then
        pp(state, { maxDepth = 2, maxItems = 30 })
      else
        _out(ctx, "  (state table)")
      end
      return
    end
    _out(ctx, "  getState(): ERROR")
  end

  if type(svc.getAll) == "function" then
    local ok, state = _tryCall(svc.getAll)
    if ok then
      _out(ctx, "  getAll(): OK")
      if pp then
        pp(state, { maxDepth = 2, maxItems = 30 })
      else
        _out(ctx, "  (all table)")
      end
      return
    end
    _out(ctx, "  getAll(): ERROR")
  end

  _out(ctx, "  NOTE: no getState/getAll surface detected; dumping keys (bounded)")
  local keys = {}
  for k, _ in pairs(svc) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)

  local limit = math.min(#keys, 40)
  for i = 1, limit do
    _out(ctx, "    - " .. tostring(keys[i]))
  end
  if #keys > limit then
    _out(ctx, "    ... (" .. tostring(#keys - limit) .. " more)")
  end
end

function M.reset()
  -- no state
end

return M
