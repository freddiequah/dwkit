-- #########################################################################
-- Module Name : dwkit.loader.init
-- Owner       : Loader
-- Version     : v2026-01-06E
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

    -- Attach test surface (SAFE, manual-only). Guarded to avoid hard failure.
    DWKit.test = DWKit.test or {}

    local okRunner, runnerOrErr = pcall(require, "dwkit.tests.self_test_runner")
    if okRunner and type(runnerOrErr) == "table" and type(runnerOrErr.run) == "function" then
        DWKit.test.run = runnerOrErr.run
        DWKit.test._selfTestLoadError = nil
    else
        DWKit.test.run = nil
        DWKit.test._selfTestLoadError = tostring(runnerOrErr)
    end

    -- Command Registry runtime (SAFE). Guarded to avoid hard failure.
    DWKit.bus = DWKit.bus or {}

    local okCmd, cmdOrErr = pcall(require, "dwkit.bus.command_registry")
    if okCmd and type(cmdOrErr) == "table" then
        DWKit.bus.commandRegistry = cmdOrErr
        DWKit.cmd = cmdOrErr -- convenience surface for runtime listing/help
        DWKit._cmdRegistryLoadError = nil
    else
        DWKit.bus.commandRegistry = nil
        DWKit.cmd = nil
        DWKit._cmdRegistryLoadError = tostring(cmdOrErr)
    end

    -- Install SAFE typed aliases (dwcommands / dwhelp). Guarded and idempotent.
    DWKit.services = DWKit.services or {}

    local okAlias, aliasOrErr = pcall(require, "dwkit.services.command_aliases")
    if okAlias and type(aliasOrErr) == "table" and type(aliasOrErr.install) == "function" then
        DWKit.services.commandAliases = aliasOrErr
        local okInstall, installErr = aliasOrErr.install({ quiet = true })
        if okInstall then
            DWKit._commandAliasesLoadError = nil
        else
            DWKit._commandAliasesLoadError = tostring(installErr)
        end
    else
        DWKit.services.commandAliases = nil
        DWKit._commandAliasesLoadError = tostring(aliasOrErr)
    end

    return DWKit
end

return Loader
