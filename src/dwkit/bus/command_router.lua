-- #########################################################################
-- Module Name : dwkit.bus.command_router
-- Owner       : Bus
-- Version     : v2026-01-27A
-- Purpose     :
--   - Centralize SAFE command routing + router fallbacks (moved out of command_aliases.lua).
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

-- ------------------------------------------------------------
-- GUI helpers (legacy fallback support)
-- ------------------------------------------------------------
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

-- ------------------------------------------------------------
-- Release checklist (legacy fallback support)
-- Caller should provide ctx.legacyPrintVersionSummary() if desired.
-- ------------------------------------------------------------
local function _printReleaseChecklist(ctx)
    ctx.out("[DWKit Release] checklist (dwrelease)")
    ctx.out("  NOTE: SAFE + manual-only. This does not run git/gh commands.")
    ctx.out("")

    ctx.out("== versions (best-effort) ==")
    ctx.out("")
    if type(ctx.legacyPrintVersionSummary) == "function" then
        ctx.legacyPrintVersionSummary()
    else
        ctx.out("[DWKit Release] NOTE: legacyPrintVersionSummary not available")
    end
    ctx.out("")

    ctx.out("== PR workflow (PowerShell + gh) ==")
    ctx.out("")
    ctx.out("  1) Start clean:")
    ctx.out("     - git checkout main")
    ctx.out("     - git pull")
    ctx.out("     - git status -sb")
    ctx.out("")
    ctx.out("  2) Create topic branch:")
    ctx.out("     - git checkout -b <topic/name>")
    ctx.out("")
    ctx.out("  3) Commit changes (scope small):")
    ctx.out("     - git status")
    ctx.out("     - git add <paths...>")
    ctx.out("     - git commit -m \"<message>\"")
    ctx.out("")
    ctx.out("  4) Push branch:")
    ctx.out("     - git push --set-upstream origin <topic/name>")
    ctx.out("")
    ctx.out("  5) Create PR:")
    ctx.out("     - gh pr create --base main --head <topic/name> --title \"<title>\" --body \"<body>\"")
    ctx.out("")
    ctx.out("  6) Review + merge (preferred: squash + delete branch):")
    ctx.out("     - gh pr status")
    ctx.out("     - gh pr view")
    ctx.out("     - gh pr diff")
    ctx.out("     - gh pr checks    (if configured)")
    ctx.out("     - gh pr merge <PR_NUMBER> --squash --delete-branch")
    ctx.out("")
    ctx.out("  7) Sync local main AFTER merge:")
    ctx.out("     - git checkout main")
    ctx.out("     - git pull")
    ctx.out("     - git log -1 --oneline --decorate")
    ctx.out("")

    ctx.out("== release tagging discipline (annotated tag on main HEAD) ==")
    ctx.out("")
    ctx.out("  1) Verify main HEAD is correct:")
    ctx.out("     - git checkout main")
    ctx.out("     - git pull")
    ctx.out("     - git log -1 --oneline --decorate")
    ctx.out("")
    ctx.out("  2) Create annotated tag (after merge):")
    ctx.out("     - git tag -a vYYYY-MM-DDX -m \"<tag message>\"")
    ctx.out("     - git push origin vYYYY-MM-DDX")
    ctx.out("")
    ctx.out("  3) Verify tag targets origin/main:")
    ctx.out("     - git rev-parse --verify origin/main")
    ctx.out("     - git rev-parse --verify 'vYYYY-MM-DDX^{}'")
    ctx.out("     - (expected: hashes match)")
    ctx.out("")
    ctx.out("  4) If you tagged wrong commit (fix safely):")
    ctx.out("     - git tag -d vYYYY-MM-DDX")
    ctx.out("     - git push origin :refs/tags/vYYYY-MM-DDX")
    ctx.out("     - (then recreate on correct main HEAD)")
end

-- ------------------------------------------------------------
-- Routered dispatch: dwgui / dwscorestore / dwrelease
-- Returns: true if handled, false if not.
-- ------------------------------------------------------------
function M.dispatchRoutered(ctx, kit, tokens)
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

        local sub  = tokens[2] or ""
        local uiId = tokens[3] or ""
        local arg3 = tokens[4] or ""

        -- Delegate FIRST (best-effort).
        do
            if type(ctx.safeRequire) == "function" then
                local okM, mod = ctx.safeRequire("dwkit.commands.dwgui")
                if okM and type(mod) == "table" and type(mod.dispatch) == "function" then
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
                    if ok1 then
                        return true
                    end

                    local ok2, err2 = pcall(mod.dispatch, dctx, sub, uiId, arg3)
                    if ok2 then
                        return true
                    end

                    ctx.out("[DWKit GUI] NOTE: dwgui delegate failed; falling back to inline handler")
                    ctx.out("  err1=" .. tostring(err1))
                    ctx.out("  err2=" .. tostring(err2))
                end
            end
        end

        -- Inline fallback (legacy behaviour)
        local function usage()
            ctx.out("[DWKit GUI] Usage:")
            ctx.out("  dwgui")
            ctx.out("  dwgui status")
            ctx.out("  dwgui list")
            ctx.out("  dwgui enable <uiId>")
            ctx.out("  dwgui disable <uiId>")
            ctx.out("  dwgui visible <uiId> on|off")
            ctx.out("  dwgui validate")
            ctx.out("  dwgui validate enabled")
            ctx.out("  dwgui validate <uiId>")
            ctx.out("  dwgui apply")
            ctx.out("  dwgui apply <uiId>")
            ctx.out("  dwgui dispose <uiId>")
            ctx.out("  dwgui reload")
            ctx.out("  dwgui reload <uiId>")
            ctx.out("  dwgui state <uiId>")
        end

        if sub == "" or sub == "status" or sub == "list" then
            _printGuiStatusAndList(ctx, gs)
            return true
        end

        if (sub == "enable" or sub == "disable") then
            if uiId == "" then
                usage()
                return true
            end
            if type(gs.setEnabled) ~= "function" then
                ctx.err("guiSettings.setEnabled not available.")
                return true
            end
            local enable = (sub == "enable")
            local okCall, errOrNil = pcall(gs.setEnabled, uiId, enable)
            if not okCall then
                ctx.err("setEnabled failed: " .. tostring(errOrNil))
                return true
            end
            ctx.out(string.format("[DWKit GUI] setEnabled uiId=%s enabled=%s", tostring(uiId), enable and "ON" or "OFF"))
            return true
        end

        if sub == "visible" then
            if uiId == "" or (arg3 ~= "on" and arg3 ~= "off") then
                usage()
                return true
            end
            if type(gs.setVisible) ~= "function" then
                ctx.err("guiSettings.setVisible not available.")
                return true
            end
            local vis = (arg3 == "on")
            local okCall, errOrNil = pcall(gs.setVisible, uiId, vis)
            if not okCall then
                ctx.err("setVisible failed: " .. tostring(errOrNil))
                return true
            end
            ctx.out(string.format("[DWKit GUI] setVisible uiId=%s visible=%s", tostring(uiId), vis and "ON" or "OFF"))
            return true
        end

        if sub == "validate" then
            local v = _getUiValidatorBestEffort(ctx)
            if type(v) ~= "table" or type(v.validateAll) ~= "function" then
                ctx.err("dwkit.ui.ui_validator.validateAll not available.")
                return true
            end

            local target = uiId
            local verbose = (arg3 == "verbose" or uiId == "verbose")

            if uiId == "enabled" then
                target = "enabled"
            end

            if target == "" then
                local okCall, a, b, c, err = ctx.callBestEffort(v, "validateAll", { source = "dwgui" })
                if not okCall or a ~= true then
                    ctx.err("validateAll failed: " .. tostring(b or c or err))
                    return true
                end
                if verbose then
                    if type(ctx.ppTable) == "function" then ctx.ppTable(b, { maxDepth = 3, maxItems = 40 }) end
                else
                    ctx.out("[DWKit GUI] validateAll OK")
                end
                return true
            end

            if target == "enabled" and type(v.validateEnabled) == "function" then
                local okCall, a, b, c, err = ctx.callBestEffort(v, "validateEnabled", { source = "dwgui" })
                if not okCall or a ~= true then
                    ctx.err("validateEnabled failed: " .. tostring(b or c or err))
                    return true
                end
                if verbose then
                    if type(ctx.ppTable) == "function" then ctx.ppTable(b, { maxDepth = 3, maxItems = 40 }) end
                else
                    ctx.out("[DWKit GUI] validateEnabled OK")
                end
                return true
            end

            if target ~= "" and type(v.validateOne) == "function" then
                local okCall, a, b, c, err = ctx.callBestEffort(v, "validateOne", target, { source = "dwgui" })
                if not okCall or a ~= true then
                    ctx.err("validateOne failed: " .. tostring(b or c or err))
                    return true
                end
                if verbose then
                    if type(ctx.ppTable) == "function" then ctx.ppTable(b, { maxDepth = 3, maxItems = 40 }) end
                else
                    ctx.out("[DWKit GUI] validateOne OK uiId=" .. tostring(target))
                end
                return true
            end

            ctx.err("validate target unsupported (missing validateEnabled/validateOne)")
            return true
        end

        if sub == "apply" or sub == "dispose" or sub == "reload" or sub == "state" then
            local okUM, um = ctx.safeRequire("dwkit.ui.ui_manager")
            if not okUM or type(um) ~= "table" then
                ctx.err("dwkit.ui.ui_manager not available.")
                return true
            end

            local function callAny(fnNames, ...)
                for _, fn in ipairs(fnNames or {}) do
                    if type(um[fn]) == "function" then
                        local okCall, errOrNil = pcall(um[fn], ...)
                        if not okCall then
                            ctx.err("ui_manager." .. tostring(fn) .. " failed: " .. tostring(errOrNil))
                        end
                        return true
                    end
                end
                return false
            end

            if sub == "apply" then
                if uiId == "" then
                    if callAny({ "applyAll" }, { source = "dwgui" }) then return true end
                else
                    if callAny({ "applyOne" }, uiId, { source = "dwgui" }) then return true end
                end
                ctx.err("ui_manager apply not supported")
                return true
            end

            if sub == "dispose" then
                if uiId == "" then
                    usage()
                    return true
                end
                if callAny({ "disposeOne" }, uiId, { source = "dwgui" }) then return true end
                ctx.err("ui_manager.disposeOne not supported")
                return true
            end

            if sub == "reload" then
                if uiId == "" then
                    if callAny({ "reloadAllEnabled", "reloadAll" }, { source = "dwgui" }) then return true end
                else
                    if callAny({ "reloadOne" }, uiId, { source = "dwgui" }) then return true end
                end
                ctx.err("ui_manager reload not supported")
                return true
            end

            if sub == "state" then
                if uiId == "" then
                    usage()
                    return true
                end
                if callAny({ "printState", "stateOne" }, uiId) then return true end
                ctx.err("ui_manager state not supported")
                return true
            end
        end

        -- default
        do
            local function usage()
                ctx.out("[DWKit GUI] Usage:")
                ctx.out("  dwgui [status|list|enable <uiId>|disable <uiId>|visible <uiId> on|off|validate|apply|dispose|reload|state]")
            end
            usage()
        end
        return true
    end

    if cmd == "dwscorestore" then
        if type(ctx.getService) ~= "function" then
            ctx.err("ctx.getService not available (cannot resolve scoreStoreService).")
            return true
        end

        local svc = ctx.getService("scoreStoreService")
        if type(svc) ~= "table" then
            -- Best-effort fallback require
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
        if okM and type(mod) == "table" and type(mod.dispatch) == "function" then
            local dctx = {
                out = ctx.out,
                err = ctx.err,
                callBestEffort = ctx.callBestEffort,
            }

            local ok1, err1 = pcall(mod.dispatch, dctx, svc, sub, arg)
            if ok1 then
                return true
            end

            local ok2, err2 = pcall(mod.dispatch, nil, svc, sub, arg)
            if ok2 then
                return true
            end

            ctx.out("[DWKit ScoreStore] NOTE: dwscorestore delegate failed; falling back to inline handler")
            ctx.out("  err1=" .. tostring(err1))
            ctx.out("  err2=" .. tostring(err2))
        end

        -- Inline fallback (legacy behaviour)
        local function usage()
            ctx.out("[DWKit ScoreStore] Usage:")
            ctx.out("  dwscorestore")
            ctx.out("  dwscorestore status")
            ctx.out("  dwscorestore persist on|off|status")
            ctx.out("  dwscorestore fixture [basic]")
            ctx.out("  dwscorestore clear")
            ctx.out("  dwscorestore wipe [disk]")
            ctx.out("  dwscorestore reset [disk]")
            ctx.out("")
            ctx.out("Notes:")
            ctx.out("  - clear = clears snapshot only (history preserved)")
            ctx.out("  - wipe/reset = clears snapshot + history")
            ctx.out("  - wipe/reset disk = also deletes persisted file (best-effort; requires store.delete)")
        end

        if sub == "" or sub == "status" then
            local ok, _, _, _, err = ctx.callBestEffort(svc, "printSummary")
            if not ok then
                ctx.err("ScoreStoreService.printSummary failed: " .. tostring(err))
            end
            return true
        end

        if sub == "persist" then
            if arg ~= "on" and arg ~= "off" and arg ~= "status" then
                usage()
                return true
            end

            if arg == "status" then
                local ok, _, _, _, err = ctx.callBestEffort(svc, "printSummary")
                if not ok then
                    ctx.err("ScoreStoreService.printSummary failed: " .. tostring(err))
                end
                return true
            end

            if type(svc.configurePersistence) ~= "function" then
                ctx.err("ScoreStoreService.configurePersistence not available.")
                return true
            end

            local enable = (arg == "on")
            local ok, _, _, _, err = ctx.callBestEffort(svc, "configurePersistence", { enabled = enable, loadExisting = true })
            if not ok then
                ctx.err("configurePersistence failed: " .. tostring(err))
                return true
            end

            local ok2, _, _, _, err2 = ctx.callBestEffort(svc, "printSummary")
            if not ok2 then
                ctx.err("ScoreStoreService.printSummary failed: " .. tostring(err2))
            end
            return true
        end

        if sub == "fixture" then
            local name = (arg ~= "" and arg) or "basic"
            if type(svc.ingestFixture) ~= "function" then
                ctx.err("ScoreStoreService.ingestFixture not available.")
                return true
            end
            local ok, _, _, _, err = ctx.callBestEffort(svc, "ingestFixture", name, { source = "fixture" })
            if not ok then
                ctx.err("ingestFixture failed: " .. tostring(err))
                return true
            end
            local ok2, _, _, _, err2 = ctx.callBestEffort(svc, "printSummary")
            if not ok2 then
                ctx.err("ScoreStoreService.printSummary failed: " .. tostring(err2))
            end
            return true
        end

        if sub == "clear" then
            if type(svc.clear) ~= "function" then
                ctx.err("ScoreStoreService.clear not available.")
                return true
            end
            local ok, _, _, _, err = ctx.callBestEffort(svc, "clear", { source = "manual" })
            if not ok then
                ctx.err("clear failed: " .. tostring(err))
                return true
            end
            local ok2, _, _, _, err2 = ctx.callBestEffort(svc, "printSummary")
            if not ok2 then
                ctx.err("ScoreStoreService.printSummary failed: " .. tostring(err2))
            end
            return true
        end

        if sub == "wipe" or sub == "reset" then
            if arg ~= "" and arg ~= "disk" then
                usage()
                return true
            end
            if type(svc.wipe) ~= "function" then
                ctx.err("ScoreStoreService.wipe not available. Update dwkit.services.score_store_service first.")
                return true
            end

            local meta = { source = "manual" }
            if arg == "disk" then
                meta.deleteFile = true
            end

            local ok, _, _, _, err = ctx.callBestEffort(svc, "wipe", meta)
            if not ok then
                ctx.err(sub .. " failed: " .. tostring(err))
                return true
            end

            local ok2, _, _, _, err2 = ctx.callBestEffort(svc, "printSummary")
            if not ok2 then
                ctx.err("ScoreStoreService.printSummary failed: " .. tostring(err2))
            end
            return true
        end

        usage()
        return true
    end

    if cmd == "dwrelease" then
        local okM, mod = ctx.safeRequire("dwkit.commands.dwrelease")
        if okM and type(mod) == "table" and type(mod.dispatch) == "function" then
            local dctx = {
                out = ctx.out,
                err = ctx.err,
                ppTable = ctx.ppTable,
                callBestEffort = ctx.callBestEffort,
                getKit = function() return kit end,

                legacyPrint = function() _printReleaseChecklist(ctx) end,
                legacyPrintVersion = function()
                    if type(ctx.legacyPrintVersionSummary) == "function" then
                        ctx.legacyPrintVersionSummary()
                    end
                end,
            }

            local ok1, r1 = pcall(mod.dispatch, dctx, kit, tokens)
            if ok1 and r1 ~= false then return true end

            local ok2, r2 = pcall(mod.dispatch, dctx, tokens)
            if ok2 and r2 ~= false then return true end

            local ok3, r3 = pcall(mod.dispatch, tokens)
            if ok3 and r3 ~= false then return true end

            ctx.out("[DWKit Release] NOTE: dwrelease delegate returned false; falling back to inline handler")
        end

        _printReleaseChecklist(ctx)
        return true
    end

    return false
end

-- ------------------------------------------------------------
-- Generic dispatch wrapper (moved from command_aliases.lua)
-- Expectations:
--   - ctx has: out, err, safeRequire, callBestEffort
--   - ctx may also supply: ppTable, getKit, getService, makeEventDiagCtx,
--     getEventDiagState, legacyPrintVersionSummary, legacyPrintBoot, legacyPrintServices,
--     legacyPrintIdentity, printServiceSnapshot
-- ------------------------------------------------------------
function M.dispatchGenericCommand(ctx, kit, cmd, tokens)
    cmd = tostring(cmd or "")
    kit = (type(kit) == "table") and kit or (type(ctx) == "table" and type(ctx.getKit) == "function" and ctx.getKit()) or nil
    tokens = (type(tokens) == "table") and tokens or {}

    if cmd == "" then return true end

    -- (0) dwcommands inline (keeps SAFE behavior independent of split module failures)
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

    -- 1) Split module dispatch
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

    -- 2) Try DWKit.cmd.run (best-effort)
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

    -- 3) Micro-fallbacks for a few essential commands
    if cmd == "dwid" and type(ctx.legacyPrintIdentity) == "function" then
        ctx.legacyPrintIdentity()
        return true
    end
    if cmd == "dwversion" and type(ctx.legacyPrintVersionSummary) == "function" then
        ctx.legacyPrintVersionSummary()
        return true
    end
    if cmd == "dwboot" and type(ctx.legacyPrintBoot) == "function" then
        ctx.legacyPrintBoot()
        return true
    end
    if cmd == "dwservices" and type(ctx.legacyPrintServices) == "function" then
        ctx.legacyPrintServices()
        return true
    end
    if cmd == "dwpresence" and type(ctx.printServiceSnapshot) == "function" then
        ctx.printServiceSnapshot("PresenceService", "presenceService")
        return true
    end
    if cmd == "dwactions" and type(ctx.printServiceSnapshot) == "function" then
        ctx.printServiceSnapshot("ActionModelService", "actionModelService")
        return true
    end
    if cmd == "dwskills" and type(ctx.printServiceSnapshot) == "function" then
        ctx.printServiceSnapshot("SkillRegistryService", "skillRegistryService")
        return true
    end

    ctx.err("Command handler not available for: " .. cmd .. " (no split module / no DWKit.cmd.run).")
    return true
end

return M
