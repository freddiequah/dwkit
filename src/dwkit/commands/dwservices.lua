-- #########################################################################
-- Module Name : dwkit.commands.dwservices
-- Owner       : Commands
-- Version     : v2026-01-21G
-- Purpose     :
--   - SAFE command handler for:
--       * dwservices
--   - Prints health/loaded status of core spine services.
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

function M.dispatch(ctx, kit)
  kit = _getKit(kit)

  _out(ctx, "[DWKit Services] Health summary (dwservices)")
  _out(ctx, "")

  if type(kit) ~= "table" then
    _out(ctx, "  DWKit global: MISSING")
    _out(ctx, "  Next step: lua local L=require(\"dwkit.loader.init\"); L.init()")
    return
  end

  if type(kit.services) ~= "table" then
    _out(ctx, "  DWKit.services: MISSING")
    return
  end

  local function showSvc(fieldName, errKey)
    local svc = kit.services[fieldName]
    local ok = (type(svc) == "table")
    local v = ok and tostring(svc.VERSION or "unknown") or "unknown"
    _out(ctx, "  " .. fieldName .. " : " .. (ok and "OK" or "MISSING") .. "  version=" .. v)

    local errVal = kit[errKey]
    if errVal ~= nil and tostring(errVal) ~= "" then
      _out(ctx, "    loadError: " .. tostring(errVal))
    end
  end

  showSvc("presenceService", "_presenceServiceLoadError")
  showSvc("actionModelService", "_actionModelServiceLoadError")
  showSvc("skillRegistryService", "_skillRegistryServiceLoadError")
  showSvc("scoreStoreService", "_scoreStoreServiceLoadError")
end

function M.reset()
  -- no state
end

return M
