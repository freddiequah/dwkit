-- #########################################################################
-- BEGIN FILE: src/dwkit/services/alias_factory.lua
-- #########################################################################
-- Module Name : dwkit.services.alias_factory
-- Owner       : Services
-- Version     : v2026-01-27A
-- Purpose     :
--   - Objective extraction from command_aliases.lua:
--       * SAFE command enumeration (best-effort)
--       * AUTO SAFE alias creation loop (generic aliases)
--
-- Design:
--   - This module is dependency-injected to avoid importing Mudlet globals directly.
--   - Special-case aliases (dwwho/dwroom/dwdiag/dwgui/dwscorestore/dwrelease routered) remain
--     in dwkit.services.command_aliases (for now).
--
-- Public API:
--   - getSafeCommandNamesBestEffort(deps, kit) -> table|nil
--   - installAutoSafeAliases(deps, kit, safeNames, specialMap) -> table createdMap
--
-- deps contract (minimum):
--   deps.safeRequire(name) -> ok, modOrErr
--   deps.callBestEffort(obj, fnName, ...) -> ok, a,b,c, err
--   deps.mkAlias(pattern, fn) -> aliasId|nil
--   deps.tokenizeFromMatches() -> tokens[]
--   deps.hasCmd() -> boolean
--   deps.getKit() -> kit|nil
--   deps.getService(name) -> svc|nil
--   deps.getRouter() -> routerModule|nil
--   deps.out(line)
--   deps.err(msg)
--   deps.legacyPpTable(t, opts)
--   deps.makeEventDiagCtx() -> ctx
--   deps.getEventDiagStateBestEffort(kit) -> table|nil
--   deps.legacyPrintVersionSummary()
--   deps.legacyPrintBoot()
--   deps.legacyPrintServices()
--   deps.legacyPrintIdentity()
--   deps.legacyPrintServiceSnapshot(label, svcName)
-- #########################################################################

local M = {}

M.VERSION = "v2026-01-27A"

local function _sortedKeys(t)
    local keys = {}
    if type(t) ~= "table" then return keys end
    for k, _ in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    return keys
end

local function _normalizeNames(v)
    if type(v) ~= "table" then return nil end
    local names = {}
    local isArray = (v[1] ~= nil)

    if isArray then
        for _, x in ipairs(v) do
            if type(x) == "string" and x ~= "" then
                names[#names + 1] = x
            end
        end
    else
        for k, _ in pairs(v) do
            if type(k) == "string" and k ~= "" then
                names[#names + 1] = k
            end
        end
    end

    if #names == 0 then return nil end
    table.sort(names)
    return names
end

-- ------------------------------------------------------------
-- SAFE command enumeration (best-effort)
-- ------------------------------------------------------------
function M.getSafeCommandNamesBestEffort(deps, kit)
    deps = (type(deps) == "table") and deps or {}
    kit = (type(kit) == "table") and kit or (type(deps.getKit) == "function" and deps.getKit()) or nil
    if type(kit) ~= "table" then return nil end

    -- Try DWKit.cmd helper methods first (preferred)
    if type(kit.cmd) == "table" and type(deps.callBestEffort) == "function" then
        local candidates = {
            "getSafeNames",
            "listSafeNames",
            "safeNames",
            "getSafeCommands",
            "getSafe",
        }

        for _, fnName in ipairs(candidates) do
            if type(kit.cmd[fnName]) == "function" then
                local ok, a = deps.callBestEffort(kit.cmd, fnName)
                if ok then
                    local names = _normalizeNames(a)
                    if names then return names end
                end
            end
        end
    end

    -- Try command_registry module directly (best-effort)
    if type(deps.safeRequire) == "function" then
        local okR, reg = deps.safeRequire("dwkit.bus.command_registry")
        if okR and type(reg) == "table" then
            local candidates = {
                "getSafeNames",
                "listSafeNames",
                "safeNames",
                "getSafe",
            }
            for _, fnName in ipairs(candidates) do
                if type(reg[fnName]) == "function" then
                    local ok, v = pcall(reg[fnName], reg)
                    if ok then
                        local names = _normalizeNames(v)
                        if names then return names end
                    end
                end
            end
        end
    end

    return nil
end

local function _makeGenericAliasCtx(deps, k)
    return {
        out = deps.out,
        err = deps.err,
        ppTable = function(t, opts2) deps.legacyPpTable(t, opts2) end,
        callBestEffort = deps.callBestEffort,
        safeRequire = deps.safeRequire,

        getKit = function() return k end,
        getService = deps.getService,
        printServiceSnapshot = function(label, svcName)
            if type(deps.legacyPrintServiceSnapshot) == "function" then
                return deps.legacyPrintServiceSnapshot(label, svcName)
            end
        end,

        makeEventDiagCtx = deps.makeEventDiagCtx,
        getEventDiagState = function()
            if type(deps.getEventDiagStateBestEffort) == "function" then
                return deps.getEventDiagStateBestEffort(k)
            end
            return nil
        end,

        legacyPrintVersionSummary = deps.legacyPrintVersionSummary,
        legacyPrintBoot = deps.legacyPrintBoot,
        legacyPrintServices = deps.legacyPrintServices,
        legacyPrintIdentity = deps.legacyPrintIdentity,
    }
end

-- ------------------------------------------------------------
-- AUTO SAFE aliases for non-special SAFE commands
-- ------------------------------------------------------------
function M.installAutoSafeAliases(deps, kit, safeNames, specialMap)
    deps = (type(deps) == "table") and deps or {}
    kit = (type(kit) == "table") and kit or (type(deps.getKit) == "function" and deps.getKit()) or nil
    safeNames = (type(safeNames) == "table") and safeNames or {}
    specialMap = (type(specialMap) == "table") and specialMap or {}

    local created = {}

    if type(deps.mkAlias) ~= "function" then
        return created
    end

    for _, cmdName in ipairs(safeNames) do
        cmdName = tostring(cmdName or "")
        if cmdName ~= "" and (specialMap[cmdName] ~= true) then
            local pat = "^" .. cmdName .. "(?:\\s+(.+))?\\s*$"

            local id = deps.mkAlias(pat, function()
                if type(deps.hasCmd) == "function" and deps.hasCmd() ~= true then
                    if type(deps.err) == "function" then
                        deps.err("DWKit.cmd not available. Run loader.init() first.")
                    end
                    return
                end

                local k = (type(deps.getKit) == "function" and deps.getKit()) or kit
                local tokens = (type(deps.tokenizeFromMatches) == "function" and deps.tokenizeFromMatches()) or {}
                local cmd = tokens[1] or cmdName

                local R = (type(deps.getRouter) == "function" and deps.getRouter()) or nil
                if type(R) ~= "table" or type(R.dispatchGenericCommand) ~= "function" then
                    if type(deps.err) == "function" then
                        deps.err("command_router not available (dispatchGenericCommand missing)")
                    end
                    return
                end

                local ctx = _makeGenericAliasCtx(deps, k)
                R.dispatchGenericCommand(ctx, k, cmd, tokens)
            end)

            created[cmdName] = id
        end
    end

    return created
end

-- Optional: debug helper for quick inspection
function M._debugSummary(created)
    created = (type(created) == "table") and created or {}
    local keys = _sortedKeys(created)
    return {
        count = #keys,
        keys = keys,
    }
end

return M

-- #########################################################################
-- END FILE: src/dwkit/services/alias_factory.lua
-- #########################################################################
