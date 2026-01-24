-- ########################################################################
-- DWKit: Alias Control Service
-- Provides minimal always-on aliases: dwinit, dwalias
-- Manages install/uninstall of command aliases (dwversion, dwcommands, etc.)
-- ########################################################################

local M = {}

M.serviceId = "dwkit.services.alias_control"
M.serviceVersion = "v2026-01-24H" -- bump

local function nowMs()
  if type(getEpoch) == "function" then
    return getEpoch()
  end
  return math.floor(os.clock() * 1000)
end

local function log(msg)
  print(string.format("[DWKit AliasCtl] %s", tostring(msg)))
end

local function getRoot()
  _G.DWKit = _G.DWKit or {}
  return _G.DWKit
end

local function getState()
  local root = getRoot()
  root._aliasControl = root._aliasControl or {}
  local st = root._aliasControl
  st.aliasIds = st.aliasIds or {}
  st.dispatchGuard = st.dispatchGuard or { lastAt = 0, lastKey = "" }
  st.aliasesInstalled = (st.aliasesInstalled == true)
  return st
end

local function safeKillAlias(id)
  if type(id) ~= "number" then return false end
  local ok = pcall(killAlias, id)
  return ok == true
end

local function wipeKnownLegacyIdStores()
  -- Best-effort cleanup for older versions that might have stored alias IDs elsewhere.
  local root = getRoot()

  local candidates = {
    root._aliasControlAliasIds,
    root._aliasControlAliasIDs,
    root._aliasCtlAliasIds,
    root._aliasCtlAliasIDs,
    _G._DWKitAliasCtlAliasIds,
    _G._DWKitAliasCtlAliasIDs,
  }

  for _, t in ipairs(candidates) do
    if type(t) == "table" then
      for _, id in pairs(t) do
        safeKillAlias(id)
      end
    end
  end

  -- Also scan DWKit root for any table that looks like {number, number}
  for k, v in pairs(root) do
    if type(k) == "string" and type(v) == "table" then
      local lk = k:lower()
      if lk:find("alias") and (lk:find("ctl") or lk:find("control")) then
        for _, id in pairs(v) do
          safeKillAlias(id)
        end
      end
    end
  end
end

local function tempAliasSafe(regex, code)
  local ok, idOrErr = pcall(tempAlias, regex, code)
  if not ok then
    return nil, tostring(idOrErr)
  end
  return idOrErr, nil
end

local function installCoreAliases()
  local st = getState()

  -- hard pre-clean: kill anything we previously created
  for _, id in ipairs(st.aliasIds) do
    safeKillAlias(id)
  end
  st.aliasIds = {}

  -- Also wipe known legacy stores so old installs can't survive hot reloads
  wipeKnownLegacyIdStores()

  -- IMPORTANT:
  -- We use STRING bodies calling require() each time, so aliases always
  -- execute the current module code (prevents stale closures).
  local id1, e1 = tempAliasSafe("^dwinit$", [[require("dwkit.services.alias_control")._dispatch("dwinit")]])
  if not id1 then return nil, e1 end
  table.insert(st.aliasIds, id1)

  local id2, e2 = tempAliasSafe("^dwalias(?:\\s+(.*))?$", [[require("dwkit.services.alias_control")._dispatch("dwalias")]])
  if not id2 then
    safeKillAlias(id1)
    return nil, e2
  end
  table.insert(st.aliasIds, id2)

  -- Keep a legacy mirror key as well (for older cleanups)
  local root = getRoot()
  root._aliasControlAliasIds = { id1, id2 }

  return { "dwinit", "dwalias" }, nil
end

function M.install()
  -- Make install idempotent: always clean + re-install core aliases
  local okList, err = installCoreAliases()
  if not okList then
    return false, err
  end
  log("Installed: " .. table.concat(okList, ", "))
  return true, nil
end

function M.uninstall()
  local st = getState()

  -- kill command aliases first (if installed)
  pcall(function()
    local A = require("dwkit.services.command_aliases")
    if type(A.uninstall) == "function" then
      A.uninstall()
    end
  end)

  for _, id in ipairs(st.aliasIds) do
    safeKillAlias(id)
  end
  st.aliasIds = {}

  wipeKnownLegacyIdStores()

  st.aliasesInstalled = false
  return true
end

local function getAliasesVersion()
  local ok, A = pcall(require, "dwkit.services.command_aliases")
  if not ok or type(A) ~= "table" then
    return nil
  end
  return A.VERSION or A.serviceVersion or A.version or A.serviceVersionTag or nil
end

local function getAliasesInstalledBestEffort()
  local st = getState()

  local ok, A = pcall(require, "dwkit.services.command_aliases")
  if ok and type(A) == "table" then
    if type(A.getState) == "function" then
      local okS, v = pcall(A.getState)
      if okS and type(v) == "table" and v.installed ~= nil then
        return (v.installed == true)
      end
    end
    if type(A.isInstalled) == "function" then
      local okI, v = pcall(A.isInstalled)
      if okI then
        return v == true
      end
    end
  end

  -- fallback: our own state bit (set by dwalias on/off handlers)
  return (st.aliasesInstalled == true)
end

function M.status()
  local st = getState()

  log("status")
  log("  installed=true") -- AliasCtl core is always-on once installed
  log("  version=" .. tostring(M.serviceVersion))

  local installed = getAliasesInstalledBestEffort()
  local av = getAliasesVersion()

  log("  aliasesInstalled=" .. tostring(installed))
  if av then
    log("  aliasesVersion=" .. tostring(av))
  end

  log("  tip: dwalias on | dwalias off | dwalias reinstall")
  return true
end

local function defer(fn)
  -- Defer to avoid weird alias install/uninstall timing clashes.
  tempTimer(0, function()
    local ok, err = pcall(fn)
    if not ok then
      log("[FAIL] deferred op: " .. tostring(err))
    end
  end)
end

local function aliasesOn()
  local st = getState()
  log("[PASS] aliases installed/ensured")
  log("NOTE: installing aliases (deferred)")
  defer(function()
    local A = require("dwkit.services.command_aliases")
    local ok, err = A.install({ quiet = true })
    if ok then
      st.aliasesInstalled = true
      log("[PASS] aliases installed")
    else
      log("[FAIL] aliases install: " .. tostring(err))
    end
  end)
end

local function aliasesOff()
  local st = getState()
  log("NOTE: uninstalling aliases (deferred)")
  defer(function()
    local A = require("dwkit.services.command_aliases")
    local ok, err = A.uninstall()
    if ok then
      st.aliasesInstalled = false
      log("[PASS] aliases uninstalled")
    else
      log("[FAIL] aliases uninstall: " .. tostring(err))
    end
  end)
end

local function aliasesReinstall()
  local st = getState()
  log("NOTE: reinstalling aliases (deferred)")
  defer(function()
    local A = require("dwkit.services.command_aliases")
    pcall(A.uninstall)
    local ok, err = A.install({ quiet = true })
    if ok then
      st.aliasesInstalled = true
      log("[PASS] aliases reinstalled")
    else
      log("[FAIL] aliases reinstall: " .. tostring(err))
    end
  end)
end

-- Dedup guard: if two aliases fire in the same moment with same input,
-- ignore the second execution (solves double-installed tempAlias).
local function shouldDropDuplicate(which)
  local st = getState()
  local key = tostring(which) .. "|" .. tostring(matches and matches[1] or "")
  local t = nowMs()

  if st.dispatchGuard.lastKey == key and (t - st.dispatchGuard.lastAt) < 150 then
    return true
  end

  st.dispatchGuard.lastKey = key
  st.dispatchGuard.lastAt = t
  return false
end

function M._dispatch(which)
  if shouldDropDuplicate(which) then
    return
  end

  which = tostring(which or ""):lower()

  if which == "dwinit" then
    local ok, err = pcall(function()
      local L = require("dwkit.loader.init")
      L.init()
    end)
    if ok then
      log("[PASS] loader.init()")
    else
      log("[FAIL] loader.init(): " .. tostring(err))
    end
    return
  end

  if which == "dwalias" then
    local sub = ""
    if matches and matches[2] then
      sub = tostring(matches[2]):lower():gsub("^%s+", ""):gsub("%s+$", "")
    end

    if sub == "" or sub == "status" then
      M.status()
      return
    end

    if sub == "on" then
      aliasesOn()
      return
    end

    if sub == "off" then
      aliasesOff()
      return
    end

    if sub == "reinstall" then
      aliasesReinstall()
      return
    end

    log("[FAIL] unknown subcommand: " .. tostring(sub))
    log("  tip: dwalias on | dwalias off | dwalias reinstall | dwalias status")
    return
  end
end

return M
