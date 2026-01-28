-- #########################################################################
-- Module Name : dwkit.loader.init
-- Owner       : Loader
-- Version     : v2026-01-23D
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

-- Best-effort epoch-ms helper + monotonic guard
local function _epochMsMonotonic()
    local ms = nil

    -- Mudlet provides getEpoch(); its unit can vary (seconds float vs ms int) depending on environment/version.
    if type(getEpoch) == "function" then
        local ok, v = pcall(getEpoch)
        if ok and type(v) == "number" then
            -- Heuristic:
            -- - seconds epoch is ~1.7e9
            -- - ms epoch is ~1.7e12
            if v < 20000000000 then
                -- treat as seconds (possibly float)
                ms = math.floor((v * 1000) + 0.5)
            else
                -- treat as ms already
                ms = math.floor(v)
            end
        end
    end

    if type(ms) ~= "number" then
        ms = os.time() * 1000
    end

    -- Monotonic guard (per-process/session)
    DWKit._bootReadyLastTsMs = tonumber(DWKit._bootReadyLastTsMs) or 0
    if ms <= DWKit._bootReadyLastTsMs then
        ms = DWKit._bootReadyLastTsMs + 1
    end
    DWKit._bootReadyLastTsMs = ms

    return ms
end

function Loader.init()
    -- Only allowed global namespace: DWKit
    DWKit = DWKit or {}

    -- Boot marker for troubleshooting (SAFE)
    DWKit._lastInitTs = os.time()

    DWKit.core = DWKit.core or {}
    DWKit.core.identity = require("dwkit.core.identity")
    DWKit.core.runtimeBaseline = require("dwkit.core.runtime_baseline")

    -- Persist foundation (SAFE). Guarded. No writes unless manually invoked by a module/service/test.
    DWKit.persist = DWKit.persist or {}

    local okPaths, pathsOrErr = pcall(require, "dwkit.persist.paths")
    if okPaths and type(pathsOrErr) == "table" then
        DWKit.persist.paths = pathsOrErr
        DWKit._persistPathsLoadError = nil
    else
        DWKit.persist.paths = nil
        DWKit._persistPathsLoadError = tostring(pathsOrErr)
    end

    local okStore, storeOrErr = pcall(require, "dwkit.persist.store")
    if okStore and type(storeOrErr) == "table" then
        DWKit.persist.store = storeOrErr
        DWKit._persistStoreLoadError = nil
    else
        DWKit.persist.store = nil
        DWKit._persistStoreLoadError = tostring(storeOrErr)
    end

    -- ---------------------------------------------------------------------
    -- Config surfaces (SAFE). Guarded. No writes during load.
    -- ---------------------------------------------------------------------
    DWKit.config = DWKit.config or {}

    local okGui, guiOrErr = pcall(require, "dwkit.config.gui_settings")
    if okGui and type(guiOrErr) == "table" then
        DWKit.config.guiSettings = guiOrErr
        DWKit._guiSettingsLoadError = nil

        -- Safe read-only load (missing file => defaults, no save)
        if type(guiOrErr.load) == "function" then
            local okLoad, loadOkOrErr = pcall(guiOrErr.load, { quiet = true })
            if okLoad and loadOkOrErr == true then
                DWKit._guiSettingsInitLoaded = true
                DWKit._guiSettingsInitLoadError = nil
            else
                DWKit._guiSettingsInitLoaded = false
                DWKit._guiSettingsInitLoadError = tostring(loadOkOrErr)
            end
        else
            DWKit._guiSettingsInitLoaded = false
            DWKit._guiSettingsInitLoadError = "guiSettings.load() missing"
        end
    else
        DWKit.config.guiSettings = nil
        DWKit._guiSettingsLoadError = tostring(guiOrErr)
        DWKit._guiSettingsInitLoaded = false
        DWKit._guiSettingsInitLoadError = "guiSettings require failed"
    end

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

    -- ---------------------------------------------------------------------
    -- Install Event Watcher (SAFE). Subscribes to registry allowlist only.
    -- IMPORTANT: install before Boot:Ready emit so watcher can receive it.
    -- ---------------------------------------------------------------------
    DWKit.services = DWKit.services or {}
    do
        local okW, wOrErr = pcall(require, "dwkit.services.event_watcher_service")
        if okW and type(wOrErr) == "table" and type(wOrErr.install) == "function" then
            DWKit.services.eventWatcherService = wOrErr
            local okInstall, installErr = wOrErr.install({ quiet = true })
            if okInstall then
                DWKit._eventWatcherServiceLoadError = nil
            else
                DWKit._eventWatcherServiceLoadError = tostring(installErr)
            end
        else
            DWKit.services.eventWatcherService = nil
            DWKit._eventWatcherServiceLoadError = tostring(wOrErr)
        end
    end

    -- Install SAFE typed aliases (dwcommands / dwhelp / dwid / dwversion / dwevents / dwevent / dwboot). Guarded and idempotent.
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

        local okScore, modOrErr4 = pcall(require, "dwkit.services.score_store_service")
        if okScore and type(modOrErr4) == "table" then
            DWKit.services.scoreStoreService = modOrErr4
            DWKit._scoreStoreServiceLoadError = nil
        else
            DWKit.services.scoreStoreService = nil
            DWKit._scoreStoreServiceLoadError = tostring(modOrErr4)
        end

        -- WhoStore (SAFE). Canonical registry path for all consumers:
        --   ctx.getService("whoStoreService") -> kit.services.whoStoreService
        local okWho, whoOrErr = pcall(require, "dwkit.services.whostore_service")
        if okWho and type(whoOrErr) == "table" then
            DWKit.services.whoStoreService = whoOrErr
            DWKit._whoStoreServiceLoadError = nil
        else
            DWKit.services.whoStoreService = nil
            DWKit._whoStoreServiceLoadError = tostring(whoOrErr)
        end
    end

    -- ---------------------------------------------------------------------
    -- Install passive score capture (SAFE). No send(), no timers.
    -- Captures score / score -l / score -r when YOU run them.
    -- ---------------------------------------------------------------------
    do
        DWKit.capture = DWKit.capture or {}

        local okCap, capOrErr = pcall(require, "dwkit.capture.score_capture")
        if okCap and type(capOrErr) == "table" and type(capOrErr.install) == "function" then
            DWKit.capture.scoreCapture = capOrErr

            local okInstall, installErr = capOrErr.install()
            if okInstall then
                DWKit._scoreCaptureLoadError = nil
            else
                DWKit._scoreCaptureLoadError = tostring(installErr)
            end
        else
            DWKit.capture.scoreCapture = nil
            DWKit._scoreCaptureLoadError = tostring(capOrErr)
        end
    end

    -- Emit Boot:Ready (SAFE internal). Guarded and does not break init.
    do
        local prefix = (DWKit.core and DWKit.core.identity and DWKit.core.identity.eventPrefix) and
            tostring(DWKit.core.identity.eventPrefix) or "DWKit:"
        local evName = prefix .. "Boot:Ready"

        local eb = (DWKit.bus and DWKit.bus.eventBus) or nil
        if type(eb) == "table" and type(eb.emit) == "function" then
            local payload = {
                ts = os.time(),
                tsMs = _epochMsMonotonic(),
            }

            -- IMPORTANT: event_bus.emit requires meta as 3rd arg.
            local meta = {
                source = "dwkit.loader.init",
                ts = payload.ts,
            }

            local okCall, ok, delivered, errs = pcall(eb.emit, evName, payload, meta)
            if okCall and ok then
                DWKit._bootReadyEmitted = true
                DWKit._bootReadyEmitError = nil
                DWKit._bootReadyTs = payload.ts
                DWKit._bootReadyTsMs = payload.tsMs
            else
                DWKit._bootReadyEmitted = false
                DWKit._bootReadyTs = nil
                DWKit._bootReadyTsMs = nil
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
            DWKit._bootReadyTsMs = nil
            DWKit._bootReadyEmitError = "eventBus.emit not available"
        end
    end

    return DWKit
end

return Loader
