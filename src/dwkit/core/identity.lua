-- #########################################################################
-- Module Name : dwkit.core.identity
-- Owner       : Core
-- Version     : v2026-01-06F
-- Purpose     :
--   - Provide the single authoritative, canonical identity values for DWKit.
--   - Safe to require from any layer.
--   - No persistence, no events, no automation.
--
-- Public API  :
--   - get() -> table (copy) of identity fields
--
-- Events Emitted   : None
-- Events Consumed  : None
-- Persistence      : None
-- Automation Policy: Manual only
-- Dependencies     : None
-- Invariants       :
--   - Values MUST match docs/PACKAGE_IDENTITY.md
-- #########################################################################

local M = {}

M.VERSION = "v2026-01-06F"

-- Canonical identity (LOCKED)
M.packageRootGlobal = "DWKit"
M.packageId         = "dwkit"
M.eventPrefix       = "DWKit:"
M.dataFolderName    = "dwkit"

-- Version tag style (docs: Calendar vYYYY-MM-DDX)
M.versionTagStyle   = "Calendar"
M.versionTagFormat  = "vYYYY-MM-DDX"

function M.get()
    return {
        packageRootGlobal = M.packageRootGlobal,
        packageId         = M.packageId,
        eventPrefix       = M.eventPrefix,
        dataFolderName    = M.dataFolderName,
        versionTagStyle   = M.versionTagStyle,
        versionTagFormat  = M.versionTagFormat,
        version           = M.VERSION,
    }
end

return M
