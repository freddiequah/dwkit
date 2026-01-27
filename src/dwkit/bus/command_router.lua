-- #########################################################################
-- BEGIN FILE: src/dwkit/bus/command_router.lua
-- #########################################################################
-- Module Name : dwkit.bus.command_router
-- Owner       : Bus
-- Version     : v2026-01-27F
-- Purpose     :
--   - Centralize SAFE command routing (moved out of command_aliases.lua).
--   - Provide generic dispatch wrapper to:
--       * call split command modules (dwkit.commands.<cmd>.dispatch)
--       * fall back to DWKit.cmd.run (best-effort)
--       * keep micro-fallback printers (identity/version/boot/services + service snapshots)
--
-- IMPORTANT:
--   - This module does NOT install Mudlet aliases.
--   - Alias installation remains in dwkit.services.command_aliases.
--   - Context (ctx) functions are provided by the caller.
--   - ctx is normalized best-effort via dwkit.core.mudlet_ctx.ensure().
--
-- NOTE (StepN):
--   - Routered special-cases for dwgui/dwscorestore/dwrelease removed.
--     These should now be handled by their split command modules via dispatch().
--   - dispatchRoutered() is retained for backward compatibility and forwards to generic dispatch.
-- #########################################################################

local M = {}

M.VERSION = "v2026-01-27F"

local Ctx = require("dwkit.core.mudlet_ctx")
local Legacy = require("dwkit.services.legacy_printers")

local function _sortedKeys(t)
    local keys = {}
    if type(t) ~= "table" then return keys end
    for k, _ in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    return keys
end

-- Back-compat entry point.
-- Old callers may have used this for dwgui/dwscorestore/dwrelease, but those are now normal split commands.
function M.dispatchRoutered(ctx, kit, tokens)
    ctx = Ctx.ensure(ctx, { kit = kit, errPrefix = "[DWKit Router]" })
    kit = (type(kit) == "table") and kit or (type(ctx.getKit) == "function" and ctx.getKit()) or nil
    tokens = (type(tokens) == "table") and tokens or {}

    local cmd = tostring(tokens[1] or "")
    if cmd == "" then return true end

    -- Forward to generic dispatch (single source of truth).
    return M.dispatchGenericCommand(ctx, kit, cmd, tokens)
end

function M.dispatchGenericCommand(ctx, kit, cmd, tokens)
    ctx = Ctx.ensure(ctx, { kit = kit, errPrefix = "[DWKit Router]" })
    cmd = tostring(cmd or "")
    kit = (type(kit) == "table") and kit
        or (type(ctx.getKit) == "function" and ctx.getKit())
        or nil
    tokens = (type(tokens) == "table") and tokens or {}

    if cmd == "" then return true end

    -- ------------------------------------------------------------
    -- Special-case dwcommands (uses DWKit.cmd list methods)
    -- ------------------------------------------------------------
    if cmd == "dwcommands" then
        if type(kit) ~= "table" or type(kit.cmd) ~= "table" then
            ctx.err("DWKit.cmd not available. Run loader.init() first.")
            return true
        end

        local sub = tostring(tokens[2] or "")
        if sub == "" then
            local okCall, _, _, _, err = ctx.callBestEffort(kit.cmd, "listAll")
            if not okCall then
                ctx.err("DWKit.cmd.listAll not available: " .. tostring(err))
            end
            return true
        end

        if sub == "safe" then
            local okCall, _, _, _, err = ctx.callBestEffort(kit.cmd, "listSafe")
            if not okCall then
                ctx.err("DWKit.cmd.listSafe not available: " .. tostring(err))
            end
            return true
        end

        if sub == "game" then
            local okCall, _, _, _, err = ctx.callBestEffort(kit.cmd, "listGame")
            if not okCall then
                ctx.err("DWKit.cmd.listGame not available: " .. tostring(err))
            end
            return true
        end

        if sub == "md" then
            local okCall, md, _, _, err = ctx.callBestEffort(kit.cmd, "toMarkdown")
            if not okCall or type(md) ~= "string" then
                ctx.err("DWKit.cmd.toMarkdown not available: " .. tostring(err))
                return true
            end
            ctx.out(md)
            return true
        end

        ctx.err("Usage: dwcommands [safe|game|md]")
        return true
    end

    -- ------------------------------------------------------------
    -- Prefer split command module: dwkit.commands.<cmd>.dispatch
    -- ------------------------------------------------------------
    do
        local okM, mod = ctx.safeRequire("dwkit.commands." .. cmd)
        if okM and type(mod) == "table" and type(mod.dispatch) == "function" then
            local ok1, r1 = pcall(mod.dispatch, ctx, kit, tokens)
            if ok1 and r1 ~= false then return true end

            local ok2, r2 = pcall(mod.dispatch, ctx, tokens)
            if ok2 and r2 ~= false then return true end

            local ok3, r3 = pcall(mod.dispatch, tokens)
            if ok3 and r3 ~= false then return true end
        end
    end

    -- ------------------------------------------------------------
    -- Next: DWKit.cmd.run fallback (best-effort)
    -- ------------------------------------------------------------
    if type(kit) == "table" and type(kit.cmd) == "table" and type(kit.cmd.run) == "function" then
        local argString = ""
        if #tokens >= 2 then
            argString = table.concat(tokens, " ", 2)
        end

        local okA = pcall(kit.cmd.run, cmd, argString)
        if okA then return true end

        local okB = pcall(kit.cmd.run, kit.cmd, cmd, argString)
        if okB then return true end
    end

    -- ------------------------------------------------------------
    -- Micro-fallbacks (best-effort, SAFE)
    -- Keeps router resilient if a split module is missing.
    -- ------------------------------------------------------------
    local caVer = (type(ctx) == "table" and ctx.commandAliasesVersion) or "unknown"

    local fallback = {
        dwid = function()
            if type(ctx.legacyPrintIdentity) == "function" then
                ctx.legacyPrintIdentity()
            else
                Legacy.printIdentity(ctx, kit)
            end
        end,

        dwversion = function()
            if type(ctx.legacyPrintVersionSummary) == "function" then
                ctx.legacyPrintVersionSummary()
            else
                Legacy.printVersionSummary(ctx, kit, caVer)
            end
        end,

        dwboot = function()
            if type(ctx.legacyPrintBoot) == "function" then
                ctx.legacyPrintBoot()
            else
                Legacy.printBootHealth(ctx, kit)
            end
        end,

        dwservices = function()
            if type(ctx.legacyPrintServices) == "function" then
                ctx.legacyPrintServices()
            else
                Legacy.printServicesHealth(ctx, kit)
            end
        end,

        dwpresence = function()
            if type(ctx.printServiceSnapshot) == "function" then
                ctx.printServiceSnapshot("PresenceService", "presenceService")
            else
                Legacy.printServiceSnapshot(ctx, kit, "PresenceService", "presenceService")
            end
        end,

        dwactions = function()
            if type(ctx.printServiceSnapshot) == "function" then
                ctx.printServiceSnapshot("ActionModelService", "actionModelService")
            else
                Legacy.printServiceSnapshot(ctx, kit, "ActionModelService", "actionModelService")
            end
        end,

        dwskills = function()
            if type(ctx.printServiceSnapshot) == "function" then
                ctx.printServiceSnapshot("SkillRegistryService", "skillRegistryService")
            else
                Legacy.printServiceSnapshot(ctx, kit, "SkillRegistryService", "skillRegistryService")
            end
        end,
    }

    local f = fallback[cmd]
    if type(f) == "function" then
        f()
        return true
    end

    ctx.err("Command handler not available for: " .. cmd .. " (no split module / no DWKit.cmd.run).")
    return true
end

function M._debugSummaryFallbacks()
    local keys = _sortedKeys({
        dwid = true,
        dwversion = true,
        dwboot = true,
        dwservices = true,
        dwpresence = true,
        dwactions = true,
        dwskills = true,
    })
    return { count = #keys, keys = keys }
end

return M

-- #########################################################################
-- END FILE: src/dwkit/bus/command_router.lua
-- #########################################################################
