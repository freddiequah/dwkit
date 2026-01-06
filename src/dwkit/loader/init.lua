-- #########################################################################
-- Module Name : dwkit.loader.init
-- Owner       : Loader
-- Purpose     :
--   - Initialize PackageRootGlobal (DWKit) and attach core modules.
--   - Manual use only. No automation, no gameplay output.
--
-- Public API  :
--   - init() -> DWKit table
--
-- Events Emitted   : None
-- Events Consumed  : None
-- Persistence      : None
-- Automation Policy: Manual only
-- #########################################################################

local Loader = {}

function Loader.init()
  -- Only allowed global namespace: DWKit
  DWKit = DWKit or {}

  DWKit.core = DWKit.core or {}
  DWKit.core.runtimeBaseline = require("dwkit.core.runtime_baseline")

  return DWKit
end

return Loader