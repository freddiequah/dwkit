-- #########################################################################
-- Module Name : dwkit.loader.init
-- Owner       : Loader
-- Version     : v2026-01-09A
-- Purpose     :
--   - Initialize PackageRootGlobal (DWKit) and attach core modules.
--   - Manual use only. No automation, no gameplay output.
--
-- Public API  :
--   - init() -> DWKit table
--
-- Events Emitted   :
--   - DWKit:Boot:Ready (SAFE internal, manual-only)
-- Events Consumed  : None
-- Persistence      : None
-- Automation Policy: Manual only
-- #########################################################################

local Loader = {}

function Loader.init()
    -- Only allowed global namespace: DWKit
    DWKit = DWKit or {}

    -- Boot marker for troubleshooting (SAFE)
    DWKit._lastInitTs = os.time()

    DWKit.core = DWKit.core or {}
    DWKit.core.identity = require("dwkit.core.identity")
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

    -- Bus surfaces (SAFE). Guarded to avoid hard failure.
    DWKit.bus = DWKit.bus or {}

    -- Event Registry (SAFE). Guarded. Registry only, no emit.
    local okEvReg, evRegOrErr = pcall(require, "dwkit.bus.event_registry")
    if okEvReg and type(evRegOrErr) == "table" then
        DWKit.bus.eventRegistry = evRegOrErr
        DWKit._eventRegistryLoadError = nil
    else
        DWKit.bus.eventRegistry = nil
        DWKit._eventRegistryLoadError = tostring(evRegOrErr)
    end

    -- Event Bus (SAFE skeleton). Guarded. Does nothing unless manually used.
    local okEvBus, evBusOrErr = pcall(require, "dwkit.bus.event_bus")
    if okEvBus and type(evBusOrErr) == "table" then
        DWKit.bus.eventBus = evBusOrErr
        DWKit._eventBusLoadError = nil
    else
        DWKit.bus.eventBus = nil
        DWKit._eventBusLoadError = tostring(evBusOrErr)
    end

    -- Command Registry runtime (SAFE). Guarded to avoid hard failure.
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

    -- Install SAFE typed aliases (dwcommands / dwhelp / dwid / dwversion / dwevents / dwevent / dwboot). Guarded and idempotent.
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

    -- ---------------------------------------------------------------------
    -- Attach SAFE spine services (data only). Guarded, no automation.
    -- ---------------------------------------------------------------------
    do
        local okP, modOrErr = pcall(require, "dwkit.services.presence_service")
        if okP and type(modOrErr) == "table" then
            DWKit.services.presenceService = modOrErr
            DWKit._presenceServiceLoadError = nil
        else
            DWKit.services.presenceService = nil
            DWKit._presenceServiceLoadError = tostring(modOrErr)
        end

        local okA, modOrErr2 = pcall(require, "dwkit.services.action_model_service")
        if okA and type(modOrErr2) == "table" then
            DWKit.services.actionModelService = modOrErr2
            DWKit._actionModelServiceLoadError = nil
        else
            DWKit.services.actionModelService = nil
            DWKit._actionModelServiceLoadError = tostring(modOrErr2)
        end

        local okS, modOrErr3 = pcall(require, "dwkit.services.skill_registry_service")
        if okS and type(modOrErr3) == "table" then
            DWKit.services.skillRegistryService = modOrErr3
            DWKit._skillRegistryServiceLoadError = nil
        else
            DWKit.services.skillRegistryService = nil
            DWKit._skillRegistryServiceLoadError = tostring(modOrErr3)
        end
    end

    -- Emit Boot:Ready (SAFE internal). Guarded and does not break init.
    do
        local prefix = (DWKit.core and DWKit.core.identity and DWKit.core.identity.eventPrefix) and
            tostring(DWKit.core.identity.eventPrefix) or "DWKit:"
        local evName = prefix .. "Boot:Ready"

        local eb = (DWKit.bus and DWKit.bus.eventBus) or nil
        if type(eb) == "table" and type(eb.emit) == "function" then
            local payload = { ts = os.time() }

            local okCall, ok, delivered, errs = pcall(eb.emit, evName, payload)
            if okCall and ok then
                DWKit._bootReadyEmitted = true
                DWKit._bootReadyEmitError = nil
                DWKit._bootReadyTs = payload.ts
            else
                DWKit._bootReadyEmitted = false
                DWKit._bootReadyTs = nil
                if okCall then
                    local errCount = (type(errs) == "table") and #errs or 0
                    DWKit._bootReadyEmitError = "emit failed: ok=" .. tostring(ok)
                        .. " delivered=" .. tostring(delivered)
                        .. " errors=" .. tostring(errCount)
                else
                    DWKit._bootReadyEmitError = "emit error: " .. tostring(ok)
                end
            end
        else
            DWKit._bootReadyEmitted = false
            DWKit._bootReadyTs = nil
            DWKit._bootReadyEmitError = "eventBus.emit not available"
        end
    end

    return DWKit
end

return Loader
