-- #########################################################################
-- Module Name : dwkit.commands.dwskills
-- Owner       : Commands
-- Version     : v2026-03-04B
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
M.VERSION = "v2026-03-04B"

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
    tokens = (type(ctx.tokens) == "table") and ctx.tokens or nil,
    args = (type(ctx.args) == "string") and ctx.args or nil,
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

local function _sortKeys(t)
  local keys = {}
  if type(t) ~= "table" then return keys end
  for k, _ in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  return keys
end

local function _shortTags(tags)
  if type(tags) ~= "table" then return "" end
  if #tags == 0 then return "" end
  return table.concat(tags, ",")
end

local function _printRegistry(C, svc, limit)
  limit = tonumber(limit) or 30

  local okStats, stats, _, _, errStats = _callBestEffort(C, svc, "getStats")
  if okStats then
    C.out(string.format("  stats: entries=%s updates=%s lastTs=%s",
      tostring(stats.entries), tostring(stats.updates), tostring(stats.lastTs)))
  else
    C.out("  stats: unavailable err=" .. tostring(errStats))
  end

  local okReg, reg, _, _, errReg = _callBestEffort(C, svc, "getRegistry")
  if not okReg then
    C.out("  getRegistry(): ERROR err=" .. tostring(errReg))
    return false
  end

  local keys = _sortKeys(reg)
  C.out("  registry keys: count=" .. tostring(#keys))

  local n = math.min(#keys, limit)
  for i = 1, n do
    local k = keys[i]
    local def = reg[k]
    if type(def) == "table" then
      C.out(string.format("    - %s | kind=%s class=%s minLevel=%s practiceKey=%s display=%s tags=%s",
        tostring(k),
        tostring(def.kind or "nil"),
        tostring(def.classKey or "nil"),
        tostring(def.minLevel or "nil"),
        tostring(def.practiceKey or "nil"),
        tostring(def.displayName or "nil"),
        _shortTags(def.tags)))
    else
      C.out("    - " .. tostring(k) .. " | <non-table def>")
    end
  end
  if #keys > n then
    C.out("    ... (" .. tostring(#keys - n) .. " more)")
  end

  return true
end

local function _printDumpKey(C, svc, key)
  local okDef, def, _, _, errDef = _callBestEffort(C, svc, "getDef", key)
  if okDef and type(def) == "table" then
    C.out("  getDef(" .. tostring(key) .. "): OK")
    _pp(C, def, { maxDepth = 3, maxItems = 60 })
    return true
  end

  -- fallback: try snapshot registry and index
  local okReg, reg, _, _, errReg = _callBestEffort(C, svc, "getRegistry")
  if not okReg then
    C.out("  getRegistry(): ERROR err=" .. tostring(errReg))
    return false
  end
  if type(reg[key]) == "table" then
    C.out("  dump(" .. tostring(key) .. "): OK (from registry snapshot)")
    _pp(C, reg[key], { maxDepth = 3, maxItems = 60 })
    return true
  end

  C.out("  dump(" .. tostring(key) .. "): NOT FOUND")
  if errDef and errDef ~= "" then
    C.out("    err=" .. tostring(errDef))
  end
  return false
end

local function _parseMode(C)
  -- best-effort parse:
  -- tokens: {"dwskills","dump","heal"} or {"dwskills","list"} etc.
  if type(C.tokens) == "table" and #C.tokens >= 2 then
    local a = tostring(C.tokens[2] or ""):lower()
    if a == "dump" and #C.tokens >= 3 then
      return "dump", tostring(C.tokens[3])
    end
    if a == "list" then
      return "list", nil
    end
  end

  -- args string: "dump heal" / "list"
  if type(C.args) == "string" and C.args ~= "" then
    local s = tostring(C.args)
    local m = s:match("^%s*(%S+)%s*(.-)%s*$")
    local cmd = (m and m:lower()) or ""
    if cmd == "dump" then
      local key = s:match("^%s*dump%s+(.+)%s*$")
      if key and key ~= "" then return "dump", _trimKey(key) end
      return "dump", nil
    end
    if cmd == "list" then
      return "list", nil
    end
  end

  return "list", nil
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

  C.out("[DWKit Service] SkillRegistryService")
  C.out("  version=" .. tostring(svc.VERSION or "unknown"))

  local mode, key = "list", nil
  do
    -- minimal non-breaking parser; default list
    if type(C.tokens) == "table" and #C.tokens >= 2 then
      local a = tostring(C.tokens[2] or ""):lower()
      if a == "dump" then
        mode = "dump"
        key = tostring(C.tokens[3] or "")
      elseif a == "list" then
        mode = "list"
      end
    end
  end

  if mode == "dump" then
    if type(key) ~= "string" or key == "" then
      C.out("  usage: dwskills dump <key>")
      return false, "missing key"
    end
    return _printDumpKey(C, svc, key), nil
  end

  return _printRegistry(C, svc, 30), nil
end

function M.reset()
  -- no persistent state
end

return M
