-- #########################################################################
-- BEGIN FILE: src/dwkit/services/safe_command_defaults.lua
-- #########################################################################
-- Module Name : dwkit.services.safe_command_defaults
-- Owner       : Services
-- Version     : v2026-01-27A
-- Purpose     :
--   - Single place for default SAFE command list used when registry enumeration
--     is unavailable (best-effort fallback).
--
-- Public API:
--   - get() -> table (array of command names)
-- #########################################################################

local M = {}

M.VERSION = "v2026-01-27A"

local _DEFAULT = {
  "dwactions",
  "dwboot",
  "dwcommands",
  "dwdiag",
  "dwevent",
  "dweventlog",
  "dwevents",
  "dweventsub",
  "dweventtap",
  "dweventunsub",
  "dwgui",
  "dwhelp",
  "dwid",
  "dwinfo",
  "dwpresence",
  "dwrelease",
  "dwroom",
  "dwscorestore",
  "dwservices",
  "dwskills",
  "dwtest",
  "dwversion",
  "dwwho",
}

function M.get()
  local out = {}
  for i = 1, #_DEFAULT do
    out[i] = _DEFAULT[i]
  end
  return out
end

return M

-- #########################################################################
-- END FILE: src/dwkit/services/safe_command_defaults.lua
-- #########################################################################
