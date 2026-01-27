-- #########################################################################
-- BEGIN FILE: src/dwkit/bus/command_router.lua
-- #########################################################################
-- Module Name : dwkit.bus.command_router
-- Owner       : Bus
-- Version     : v2026-01-27E
-- Purpose     :
--   - Centralize SAFE command routing (moved out of command_aliases.lua).
--   - Provide routered dispatch for commands that need special routing:
--       * dwgui / dwscorestore / dwrelease
--   - Provide generic dispatch wrapper to:
--       * call split command modules (dwkit.commands.<cmd>.dispatch)
--       * fall back to DWKit.cmd.run (best-effort)
--       * keep micro-fallbacks (identity/version/boot/services + service snapshots)
--
-- IMPORTANT:
--   - This module does NOT install Mudlet aliases.
--   - Alias installation remains in dwkit.services.command_aliases.
--   - Context (ctx) functions are provided by the caller (out/err/safeRequire/callBestEffort/etc).
--   - Option A: ctx is now normalized best-effort via dwkit.core.mudlet_ctx.ensure().
--   - StepD: fallback printers can now be supplied by dwkit.services.legacy_printers
--           even when ctx lacks legacy helpers.
-- #########################################################################

local M = {}

M.VERSION = "v2026-01-27E"

local Ctx = require("dwkit.core.mudlet_ctx")
local Legacy = require("dwkit.services.legacy_printers")

local function _sortedKeys(t)
    local keys = {}
    if type(t) ~= "table" then return keys end
    for k, _ in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    return keys
end

local function _printGuiStatusAndList(ctx, gs)
    if type(ctx) ~= "table" then return end
    if type(gs) ~= "table" or type(gs.status) ~= "function" or type(gs.list) ~= "function" then
        ctx.err("guiSettings not available.")
        return
    end

    local okS, st = pcall(gs.status)
    if not okS or type(st) ~= "table" then
        ctx.err("guiSettings.status failed")
        return
    end

    ctx.out("[DWKit GUI] status (dwgui)")
    ctx.out("  version=" .. tostring(gs.VERSION or "unknown"))
    ctx.out("  loaded=" .. tostring(st.loaded == true))
    ctx.out("  relPath=" .. tostring(st.relPath or ""))
    ctx.out("  uiCount=" .. tostring(st.uiCount or 0))
    if type(st.options) == "table" then
        ctx.out("  options.visiblePersistenceEnabled=" .. tostring(st.options.visiblePersistenceEnabled == true))
        ctx.out("  options.enabledDefault=" .. tostring(st.options.enabledDefault == true))
        ctx.out("  options.visibleDefault=" .. tostring(st.options.visibleDefault == true))
    end
    if st.lastError then
        ctx.out("  lastError=" .. tostring(st.lastError))
    end

    local okL, uiMap = pcall(gs.list)
    if not okL or type(uiMap) ~= "table" then
        ctx.err("guiSettings.list failed")
        return
    end

    ctx.out("")
    ctx.out("[DWKit GUI] list (uiId -> enabled/visible)")

    local keys = _sortedKeys(uiMap)
    if #keys == 0 then
        ctx.out("  (none)")
        return
    end

    for _, uiId in ipairs(keys) do
        local rec = uiMap[uiId]
        local en = (type(rec) == "table" and rec.enabled == true) and "ON" or "OFF"
        local vis = "(unset)"
        if type(rec) == "table" then
            if rec.visible == true then
                vis = "ON"
            elseif rec.visible == false then
                vis = "OFF"
            end
        end
        ctx.out("  - " .. tostring(uiId) .. "  enabled=" .. en .. "  visible=" .. vis)
    end
end

local function _printNoUiNote(ctx, context)
    context = tostring(context or "UI")
    ctx.out("  NOTE: No UI modules found for this profile (" .. context .. ").")
    ctx.out("  Tips:")
    ctx.out("    - dwgui list")
    ctx.out("    - dwgui enable <uiId>")
    ctx.out("    - dwgui apply   (optional: render enabled UI)")
end

local function _getGuiSettingsBestEffort(kit, ctx)
    if type(kit) == "table" and type(kit.config) == "table" and type(kit.config.guiSettings) == "table" then
        return kit.config.guiSettings
    end
    if type(ctx) == "table" and type(ctx.safeRequire) == "function" then
        local ok, mod = ctx.safeRequire("dwkit.config.gui_settings")
        if ok and type(mod) == "table" then return mod end
    end
    return nil
end

local function _getUiValidatorBestEffort(ctx)
    if type(ctx) == "table" and type(ctx.safeRequire) == "function" then
        local ok, mod = ctx.safeRequire("dwkit.ui.ui_validator")
        if ok and type(mod) == "table" then return mod end
    end
    return nil
end

function M.dispatchRoutered(ctx, kit, tokens)
    ctx = Ctx.ensure(ctx, { kit = kit, errPrefix = "[DWKit Router]" })
    kit = (type(kit) == "table") and kit or (type(ctx.getKit) == "function" and ctx.getKit()) or nil

    tokens = (type(tokens) == "table") and tokens or {}
    local cmd = tostring(tokens[1] or "")

    if cmd == "dwgui" then
        local gs = _getGuiSettingsBestEffort(kit, ctx)
        if type(gs) ~= "table" then
            ctx.err("DWKit.config.guiSettings not available. Run loader.init() first.")
            return true
        end

        local alreadyLoaded = false
        if type(gs.isLoaded) == "function" then
            local okLoaded, v = pcall(gs.isLoaded)
            alreadyLoaded = (okLoaded and v == true)
        end

        if (not alreadyLoaded) and type(gs.load) == "function" then
            pcall(gs.load, { quiet = true })
        end

        local sub = tokens[2] or ""
        local uiId = tokens[3] or ""
        local arg3 = tokens[4] or ""

        local okM, mod = ctx.safeRequire("dwkit.commands.dwgui")
        if not okM or type(mod) ~= "table" or type(mod.dispatch) ~= "function" then
            ctx.err("dwkit.commands.dwgui not available (dispatch missing).")
            return true
        end

        local dctx = {
            out = ctx.out,
            err = ctx.err,
            ppTable = ctx.ppTable,
            callBestEffort = ctx.callBestEffort,

            getGuiSettings = function() return gs end,
            getUiValidator = function() return _getUiValidatorBestEffort(ctx) end,
            printGuiStatusAndList = function(x) _printGuiStatusAndList(ctx, x) end,
            printNoUiNote = function(context) _printNoUiNote(ctx, context) end,

            safeRequire = ctx.safeRequire,
        }

        local ok1, err1 = pcall(mod.dispatch, dctx, gs, sub, uiId, arg3)
        if ok1 then return true end

        local ok2, err2 = pcall(mod.dispatch, dctx, sub, uiId, arg3)
        if ok2 then return true end

        ctx.err("dwgui dispatch failed.")
        ctx.err("  err1=" .. tostring(err1))
        ctx.err("  err2=" .. tostring(err2))
        return true
    end

    if cmd == "dwscorestore" then
        if type(ctx.getService) ~= "function" then
            ctx.err("ctx.getService not available (cannot resolve scoreStoreService).")
            return true
        end

        local svc = ctx.getService("scoreStoreService")
        if type(svc) ~= "table" then
            local okS, mod = ctx.safeRequire("dwkit.services.score_store_service")
            if okS and type(mod) == "table" then
                svc = mod
            end
        end

        if type(svc) ~= "table" then
            ctx.err("ScoreStoreService not available. Run loader.init() first.")
            return true
        end

        local sub = tokens[2] or ""
        local arg = tokens[3] or ""

        local okM, mod = ctx.safeRequire("dwkit.commands.dwscorestore")
        if not okM or type(mod) ~= "table" or type(mod.dispatch) ~= "function" then
            ctx.err("dwkit.commands.dwscorestore not available (dispatch missing).")
            return true
        end

        local dctx = {
            out = ctx.out,
            err = ctx.err,
            callBestEffort = ctx.callBestEffort,
        }

        local ok1, err1 = pcall(mod.dispatch, dctx, svc, sub, arg)
        if ok1 then return true end

        local ok2, err2 = pcall(mod.dispatch, nil, svc, sub, arg)
        if ok2 then return true end

        ctx.err("dwscorestore dispatch failed.")
        ctx.err("  err1=" .. tostring(err1))
        ctx.err("  err2=" .. tostring(err2))
        return true
    end

    if cmd == "dwrelease" then
        local okM, mod = ctx.safeRequire("dwkit.commands.dwrelease")
        if not okM or type(mod) ~= "table" or type(mod.dispatch) ~= "function" then
            ctx.err("dwkit.commands.dwrelease not available (dispatch missing).")
            return true
        end

        local dctx = {
            out = ctx.out,
            err = ctx.err,
            ppTable = ctx.ppTable,
            callBestEffort = ctx.callBestEffort,
            getKit = function() return kit end,
        }

        local ok1, a1, b1 = pcall(mod.dispatch, dctx, kit, tokens)
        if ok1 and a1 ~= false then return true end

        local ok2, a2, b2 = pcall(mod.dispatch, dctx, tokens)
        if ok2 and a2 ~= false then return true end

        local ok3, a3, b3 = pcall(mod.dispatch, tokens)
        if ok3 and a3 ~= false then return true end

        ctx.err("dwrelease dispatch failed.")
        ctx.err("  err1=" .. tostring(b1 or a1))
        ctx.err("  err2=" .. tostring(b2 or a2))
        ctx.err("  err3=" .. tostring(b3 or a3))
        return true
    end

    return false
end

function M.dispatchGenericCommand(ctx, kit, cmd, tokens)
    ctx = Ctx.ensure(ctx, { kit = kit, errPrefix = "[DWKit Router]" })
    cmd = tostring(cmd or "")
    kit = (type(kit) == "table") and kit
        or (type(ctx.getKit) == "function" and ctx.getKit())
        or nil
    tokens = (type(tokens) == "table") and tokens or {}

    if cmd == "" then return true end

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
    -- ------------------------------------------------------------
    local caVer = (type(ctx) == "table" and ctx.commandAliasesVersion) or "unknown"

    if cmd == "dwid" then
        if type(ctx.legacyPrintIdentity) == "function" then
            ctx.legacyPrintIdentity()
        else
            Legacy.printIdentity(ctx, kit)
        end
        return true
    end

    if cmd == "dwversion" then
        if type(ctx.legacyPrintVersionSummary) == "function" then
            ctx.legacyPrintVersionSummary()
        else
            Legacy.printVersionSummary(ctx, kit, caVer)
        end
        return true
    end

    if cmd == "dwboot" then
        if type(ctx.legacyPrintBoot) == "function" then
            ctx.legacyPrintBoot()
        else
            Legacy.printBootHealth(ctx, kit)
        end
        return true
    end

    if cmd == "dwservices" then
        if type(ctx.legacyPrintServices) == "function" then
            ctx.legacyPrintServices()
        else
            Legacy.printServicesHealth(ctx, kit)
        end
        return true
    end

    if cmd == "dwpresence" then
        if type(ctx.printServiceSnapshot) == "function" then
            ctx.printServiceSnapshot("PresenceService", "presenceService")
        else
            Legacy.printServiceSnapshot(ctx, kit, "PresenceService", "presenceService")
        end
        return true
    end

    if cmd == "dwactions" then
        if type(ctx.printServiceSnapshot) == "function" then
            ctx.printServiceSnapshot("ActionModelService", "actionModelService")
        else
            Legacy.printServiceSnapshot(ctx, kit, "ActionModelService", "actionModelService")
        end
        return true
    end

    if cmd == "dwskills" then
        if type(ctx.printServiceSnapshot) == "function" then
            ctx.printServiceSnapshot("SkillRegistryService", "skillRegistryService")
        else
            Legacy.printServiceSnapshot(ctx, kit, "SkillRegistryService", "skillRegistryService")
        end
        return true
    end

    ctx.err("Command handler not available for: " .. cmd .. " (no split module / no DWKit.cmd.run).")
    return true
end

return M

-- #########################################################################
-- END FILE: src/dwkit/bus/command_router.lua
-- #########################################################################
