-- #########################################################################
-- Module Name : dwkit.ui.ui_utils
-- Owner       : UI
-- Version     : v2026-01-30A
-- Purpose     :
--   - Tiny UI helper utilities shared by ui_window and command surfaces.
--   - SAFE: no send(), no timers, no hidden automation.
-- #########################################################################

local M = {}

M.VERSION = "v2026-01-30A"

-- Best-effort Geyser accessor.
-- In Mudlet, Geyser is typically global, but we guard all paths.
function M.getGeyser()
    if type(_G) == "table" and type(_G.Geyser) == "table" then
        return _G.Geyser
    end

    -- Some environments allow requiring Geyser as a module. Best-effort only.
    local ok, modOrErr = pcall(require, "Geyser")
    if ok and type(modOrErr) == "table" then
        return modOrErr
    end

    return nil
end

return M
