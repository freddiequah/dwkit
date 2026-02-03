-- FILE: src/dwkit/verify/verification_plan.lua
-- #########################################################################
-- BEGIN FILE: src/dwkit/verify/verification_plan.lua
-- #########################################################################
-- Module Name : dwkit.verify.verification_plan
-- Owner       : Verify
-- Version     : v2026-02-03B
-- Purpose     :
--   - Defines verification suites (data only) for dwverify.
--   - Each suite is a table with: title, description, delay, steps.
--   - steps can be:
--       * "command string" (Mudlet command)
--       * { cmd="...", note="...", expect="..." } for richer output
-- Notes:
--   - KEEP Lua steps single-line: use `lua do ... end` only (Mudlet input paste safety).
--   - Suites should avoid spamming gameplay commands; prefer SAFE commands.
-- #########################################################################

local M = {}

M.VERSION = "v2026-02-03B"

local SUITES = {
    -- Default suite (safe baseline)
    default = {
        title = "default",
        description = "Baseline sanity: dwwho refresh + watcher capture",
        delay = 0.40, -- default per-step delay (seconds)
        steps = {
            "dwwho",
            "dwwho watch status",
            "dwwho refresh",
            "dwwho",
            "who",
            "dwwho",
        },
    },

    -- WhoStore focused suite (alias convenience)
    whostore = {
        title = "whostore",
        description = "WhoStore sanity: trigger capture path + confirm status updates",
        delay = 0.40,
        steps = {
            "dwwho watch status",
            "dwwho refresh",
            "who",
            "dwwho",
        },
    },

    -- Fixture suite (NO MUD spam; validates parsing + snapshot update)
    whostore_fixture = {
        title = "whostore_fixture",
        description = "WhoStore fixture sanity: clear + ingest fixture + list + status (no who sends)",
        delay = 0.30,
        steps = {
            "dwwho clear",
            "dwwho fixture basic",
            "dwwho list",
            "dwwho status",
        },
    },

    -- NEW: Gate force-open on watcher header trigger (regression guard)
    whostore_gate_force_open_on_header = {
        title = "whostore_gate_force_open_on_header",
        description =
        "Regression: if autoCaptureEnabled is forced false, manual WHO header trigger must force-open gate before capture/ingest (expect autoCaptureEnabled=true after).",
        delay = 0.45,
        steps = {
            { cmd = "dwwho watch on", note = "Ensure watcher is ON so header triggers fire." },

            {
                cmd =
                'lua do local S=require("dwkit.services.whostore_service"); if type(S)=="table" and type(S.setAutoCaptureEnabled)=="function" then S.setAutoCaptureEnabled(false,{source="dwverify:force-close"}) end; print("[dwverify-whostore] forced autoCaptureEnabled=false") end',
                note = "Force-close auto-capture gate (this is the precondition for regression guard).",
            },

            {
                cmd =
                'lua do local S=require("dwkit.services.whostore_service"); if type(S)~="table" or type(S.getState)~="function" then error("WhoStoreService.getState missing") end; local st=S.getState(); _G.DWVERIFY_GATE_BASE_TS=st.lastUpdatedTs; print(string.format("[dwverify-whostore] baseline lastUpdatedTs=%s source=%s autoCaptureEnabled=%s", tostring(st.lastUpdatedTs), tostring(st.source), tostring(st.autoCaptureEnabled))) end',
                note = "Record baseline lastUpdatedTs into _G (used for change assertion).",
            },

            {
                cmd = "who",
                delay = 0.90,
                note = "Manual WHO: watcher header trigger must force-open gate and capture/ingest as dwwho:auto.",
            },

            {
                cmd =
                'lua do local S=require("dwkit.services.whostore_service"); if type(S)~="table" or type(S.getState)~="function" then error("WhoStoreService.getState missing") end; local st=S.getState(); if st.autoCaptureEnabled~=true then error("Expected autoCaptureEnabled=true after manual who; got "..tostring(st.autoCaptureEnabled)) end; if tostring(st.source)~="dwwho:auto" then error("Expected source dwwho:auto after manual who; got "..tostring(st.source)) end; if st.lastUpdatedTs==nil then error("Expected lastUpdatedTs non-nil after manual who") end; local base=_G.DWVERIFY_GATE_BASE_TS; if base~=nil and tostring(st.lastUpdatedTs)==tostring(base) then error("Expected lastUpdatedTs to change after manual who; before="..tostring(base).." after="..tostring(st.lastUpdatedTs)) end; print(string.format("[dwverify-whostore] PASS gate-force-open autoCaptureEnabled=%s source=%s lastUpdatedTs=%s", tostring(st.autoCaptureEnabled), tostring(st.source), tostring(st.lastUpdatedTs))) end',
                note = "ASSERT: gate was forced open + ingest happened (PASS/FAIL).",
            },

            { cmd = "dwwho status",   note = "Human confirmation: should show autoCaptureEnabled=true and updated timestamp/source." },
        },
    },

    -- NEW: Indexing policy suite (Option A)
    whostore_index_policy = {
        title = "whostore_index_policy",
        description = "Index policy: snapshot.byName keys are lowercase; getEntry is case-insensitive compatible",
        delay = 0.30,
        steps = {
            {
                cmd =
                'lua do local S=require("dwkit.services.whostore_service"); local ok,err=S.clear({source="dwverify:index"}); if not ok then error("clear failed: "..tostring(err)) end; ok,err=S.setState({players={"Gaidin"}},{source="dwverify:index"}); if not ok then error("setState failed: "..tostring(err)) end; local snap=S.getSnapshot(); local by=snap.byName; if type(by)~="table" then error("byName missing") end; if by["gaidin"]==nil then error("Expected byName[gaidin]") end; if by["Gaidin"]~=nil then error("Expected byName[Gaidin] nil") end; local e1=S.getEntry("Gaidin"); if not e1 or e1.name~="Gaidin" then error("getEntry(Gaidin) failed") end; local e2=S.getEntry("gaidin"); if not e2 or e2.name~="Gaidin" then error("getEntry(gaidin) failed") end; local names=S.getAllNames(); local found=false; for i=1,#names do if tostring(names[i])=="Gaidin" then found=true end end; if not found then error("getAllNames missing Gaidin") end; print("[dwverify-whostore] index policy OK (byName keys lower; getEntry compat OK)") end',
                note = "Asserts Option A indexing policy and compatibility lookups (FAILs if any check fails).",
            },
            { cmd = "dwwho status", note = "Optional human confirmation: status should reflect latest update source=dwverify:index." },
        },
    },

    -- NEW: RoomEntities confidence gate suite (prefer Unknown unless exact-case match)
    roomentities_whostore_confidence_gate = {
        title = "roomentities_whostore_confidence_gate",
        description =
        "RoomEntities policy: case-insensitive WhoStore match is candidate only; auto player classification requires exact display-name match. Note: ingestLookText replaces state each call, so human checks are split across steps.",
        delay = 0.30,
        steps = {
            {
                cmd =
                'lua do local W=require("dwkit.services.whostore_service"); local R=require("dwkit.services.roomentities_service"); local ok,err=W.clear({source="dwverify:reconf"}); if not ok then error("WhoStore clear failed: "..tostring(err)) end; ok,err=W.setState({players={"Gaidin"}},{source="dwverify:reconf"}); if not ok then error("WhoStore setState failed: "..tostring(err)) end; ok,err=R.clear({source="dwverify:reconf"}); if not ok then error("RoomEntities clear failed: "..tostring(err)) end; print("[dwverify-roomentities] seeded WhoStore players={Gaidin} and cleared RoomEntities") end',
                note = "Seed WhoStore with canonical display name and clear RoomEntities state.",
            },
            {
                cmd =
                'lua do local R=require("dwkit.services.roomentities_service"); local ok,err=R.ingestLookText("gaidin is here.",{source="dwverify:reconf"}); if not ok then error("ingestLookText failed: "..tostring(err)) end; local st=R.getState(); if type(st.players)=="table" and st.players["gaidin"]==true then error("Expected gaidin NOT in players (case mismatch)") end; if type(st.unknown)~="table" or st.unknown["gaidin"]~=true then error("Expected gaidin in unknown (candidate only)") end; ok,err=R.reclassifyFromWhoStore({source="dwverify:reconf"}); if not ok then error("reclassifyFromWhoStore failed: "..tostring(err)) end; st=R.getState(); if type(st.players)=="table" and st.players["gaidin"]==true then error("Expected gaidin NOT promoted by reclassify (case mismatch)") end; if type(st.unknown)~="table" or st.unknown["gaidin"]~=true then error("Expected gaidin still in unknown after reclassify") end; print("[dwverify-roomentities] PASS candidate-only gaidin stays unknown") end',
                note = "ASSERT: lower-case gaidin is candidate-only and remains Unknown (even after reclassify).",
            },
            { cmd = "dwroom status", note = "Human check after Step 2: unknown should include gaidin; players should be 0." },
            {
                cmd =
                'lua do local R=require("dwkit.services.roomentities_service"); local ok,err=R.ingestLookText("Gaidin is here.",{source="dwverify:reconf"}); if not ok then error("ingestLookText failed: "..tostring(err)) end; local st=R.getState(); if type(st.players)~="table" or st.players["Gaidin"]~=true then error("Expected Gaidin in players (exact match)") end; print("[dwverify-roomentities] PASS exact-match Gaidin classified as player") end',
                note = "ASSERT: exact-case Gaidin is classified as player.",
            },
            { cmd = "dwroom status", note = "Human check after Step 4: players should include Gaidin; unknown may be 0 due to replace-on-ingest." },
        },
    },

    roomentities_items_trailing_descriptors = {
        title = "roomentities_items_trailing_descriptors",
        description =
        "RoomEntities parsing: item lines like 'X is here. (glowing) ...' must be classified as items (not dropped).",
        delay = 0.30,
        steps = {
            {
                cmd =
                'lua do local R=require("dwkit.services.roomentities_service"); local ok,err=R.clear({source="dwverify:roomitems"}); if not ok then error("RoomEntities clear failed: "..tostring(err)) end; ok,err=R.ingestLookLines({"A large keg of Killians Irish Red is here.","A self-destruct mechanism is here. (whirring) (humming) (glowing)"},{source="dwverify:roomitems"}); if not ok then error("ingestLookLines failed: "..tostring(err)) end; local st=R.getState(); if type(st.items)~="table" then error("Expected items table") end; if st.items["A large keg of Killians Irish Red"]~=true then error("Expected item: large keg") end; if st.items["A self-destruct mechanism"]~=true then error("Expected item: self-destruct mechanism (trailing descriptors)") end; local c=0; for _ in pairs(st.items) do c=c+1 end; print("[dwverify-roomentities] PASS items captured (count="..tostring(c)..")") end',
                note = "ASSERT: item lines with trailing descriptors after first period are captured as items.",
            },
            { cmd = "dwroom status", note = "Human confirmation: items should be >= 2 after Step 1." },
        },
    },

    -- Live clear (NO WHO send; asserts empty snapshot after clear)
    whostore_live_clear = {
        title = "whostore_live_clear",
        description = "WhoStore live clear: clear snapshot + assert empty + human confirm (no WHO send)",
        delay = 0.30,
        steps = {
            { cmd = "dwwho clear",  note = "Clear WhoStore snapshot (no WHO send)." },

            {
                cmd =
                'lua do local ok,S=pcall(require,"dwkit.services.whostore_service"); if not ok or type(S)~="table" then error("WhoStoreService require failed") end; local snap=(type(S.getSnapshot)=="function") and S.getSnapshot() or ((type(S.getState)=="function") and S.getState() or nil); if type(snap)~="table" then error("WhoStore snapshot/state missing") end; local byName=snap.byName or (snap.snapshot and snap.snapshot.byName) or nil; local entries=snap.entries or (snap.snapshot and snap.snapshot.entries) or nil; if type(byName)=="table" and next(byName)~=nil then error("WhoStore not empty: byName has entries") end; if type(entries)=="table" and next(entries)~=nil then error("WhoStore not empty: entries has records") end end',
                note = "Assert WhoStore is empty after clear (suite FAILs if not).",
            },

            { cmd = "dwwho status", note = "Human confirmation: expect empty/0 counts." },
        },
    },

    -- NEW: End-to-end controlled live run (guarded refresh + WHO capture)
    whostore_live_refresh_capture = {
        title = "whostore_live_refresh_capture",
        description =
        "E2E live: watcher ON + guarded refresh (refresh sends WHO) + verify capture + list/status (controlled)",
        delay = 0.45,
        steps = {
            { cmd = "dwwho watch status", note = "Ensure watcher is enabled before doing any live capture." },

            {
                cmd = "dwwho refresh",
                note =
                "Trigger a guarded refresh (may skip if cooldown is active). Refresh sends WHO; watcher should capture.",
                expect = "refresh guard should show lastRefreshAttemptTs updated OR lastSkipReason set (cooldown).",
            },

            {
                cmd = "dwwho",
                note = "Expect WhoStore summary to reflect latest capture (players count may be 0 if nobody online).",
            },

            { cmd = "dwwho list",         note = "If players exist, expect parsed entries listed (names/classes/etc per contract)." },

            { cmd = "dwwho status",       note = "Human confirmation: refresh guard + watcher lastErr=nil; source should reflect latest update." },
        },
    },

    -- NEW: Expectations expiry check (refresh expectations MUST NOT tag later manual 'who')
    whostore_manual_who_after_refresh = {
        title = "whostore_manual_who_after_refresh",
        description =
        "Expiry check: do refresh, wait >2s (expectations TTL), then manual 'who' must be captured as dwwho:auto (NOT refresh).",
        delay = 0.45,
        steps = {
            { cmd = "dwwho watch status", note = "Ensure watcher is enabled (auto-capture active)." },

            {
                cmd = "dwwho refresh",
                delay = 2.60, -- wait after refresh so CAP.expectTtlSec (2s) expires before the manual who
                note = "Do refresh (source should be dwwho:refresh). Then wait >2s so refresh expectations expire.",
            },

            {
                cmd = "who",
                delay = 0.80, -- allow watcher capture + ingest to complete
                note = "Manual WHO after TTL expiry: should be captured/ingested as dwwho:auto (quiet).",
            },

            {
                cmd =
                'lua do local S=require("dwkit.services.whostore_service"); if type(S)~="table" or type(S.getState)~="function" then error("WhoStoreService.getState missing") end; local st=S.getState(); local src=st.source; if tostring(src)~="dwwho:auto" then error("Expected source dwwho:auto after manual who; got "..tostring(src)) end end',
                note = "Assert: WhoStore source is dwwho:auto after manual who (FAIL if still dwwho:refresh).",
            },

            { cmd = "dwwho status",       note = "Human confirmation: source should show dwwho:auto now." },
        },
    },

    -- NEW: Watch OFF must stop ingesting manual WHO (B4 lock-in; PASS/FAIL)
    whostore_watch_off_manual_who_no_ingest = {
        title = "whostore_watch_off_manual_who_no_ingest",
        description =
        "B4 regression lock-in: establish baseline via refresh, disable watcher, record OFF-baseline, then manual 'who' must NOT update WhoStore after OFF-baseline (lastUpdatedTs/source unchanged). Restores watcher ON at end.",
        delay = 0.45,
        steps = {
            { cmd = "dwwho watch on",     note = "Precondition: ensure watcher ON so baseline refresh definitely captures/ingests." },

            {
                cmd = "dwwho refresh",
                delay = 0.90,
                note = "Establish a known baseline snapshot (refresh sends WHO; watcher should capture/ingest).",
            },

            {
                cmd =
                'lua do local S=require("dwkit.services.whostore_service"); if type(S)~="table" or type(S.getState)~="function" then error("WhoStoreService.getState missing") end; local st=S.getState(); if st.lastUpdatedTs==nil then error("Baseline requires lastUpdatedTs non-nil; run again if refresh skipped due to cooldown") end; _G.DWVERIFY_WOFF_PRE_TS=st.lastUpdatedTs; _G.DWVERIFY_WOFF_PRE_SRC=st.source; print(string.format("[dwverify-whostore] pre-off baseline lastUpdatedTs=%s source=%s", tostring(_G.DWVERIFY_WOFF_PRE_TS), tostring(_G.DWVERIFY_WOFF_PRE_SRC))) end',
                note = "Record pre-off baseline (informational).",
            },

            { cmd = "dwwho watch off",    note = "Disable watcher (manual 'who' should no longer be ingested)." },
            { cmd = "dwwho watch status", note = "Human confirmation: enabled=false trigPlayers=nil trigTotal=nil lastErr=nil." },

            {
                cmd =
                'lua do local S=require("dwkit.services.whostore_service"); if type(S)~="table" or type(S.getState)~="function" then error("WhoStoreService.getState missing") end; local st=S.getState(); _G.DWVERIFY_WOFF_TS=st.lastUpdatedTs; _G.DWVERIFY_WOFF_SRC=st.source; print(string.format("[dwverify-whostore] OFF-baseline lastUpdatedTs=%s source=%s", tostring(_G.DWVERIFY_WOFF_TS), tostring(_G.DWVERIFY_WOFF_SRC))) end',
                note = "Record OFF-baseline AFTER watcher OFF (this is what must remain unchanged by manual who).",
            },

            {
                cmd = "who",
                delay = 0.80,
                note =
                "Manual WHO while watcher OFF: should NOT ingest/update WhoStore (no state change after OFF-baseline).",
            },

            {
                cmd =
                'lua do local S=require("dwkit.services.whostore_service"); if type(S)~="table" or type(S.getState)~="function" then error("WhoStoreService.getState missing") end; local st=S.getState(); if tostring(st.lastUpdatedTs)~=tostring(_G.DWVERIFY_WOFF_TS) then error("Expected lastUpdatedTs unchanged after manual who while watcher OFF; before="..tostring(_G.DWVERIFY_WOFF_TS).." after="..tostring(st.lastUpdatedTs)) end; if tostring(st.source)~=tostring(_G.DWVERIFY_WOFF_SRC) then error("Expected source unchanged after manual who while watcher OFF; before="..tostring(_G.DWVERIFY_WOFF_SRC).." after="..tostring(st.source)) end; print(string.format("[dwverify-whostore] PASS watch-off no-ingest source=%s lastUpdatedTs=%s", tostring(st.source), tostring(st.lastUpdatedTs))) end',
                note = "ASSERT: manual who caused NO WhoStore update after OFF-baseline (PASS/FAIL).",
            },

            { cmd = "dwwho status",       note = "Human confirmation: watcher disabled; source/ts unchanged from OFF-baseline." },
            { cmd = "dwwho watch on",     note = "Restore watcher ON for normal operation." },
            { cmd = "dwwho watch status", note = "Human confirmation: watcher enabled; singleton installed; lastErr=nil." },
        },
    },

    -- NEW: Watch OFF must stop ingesting manual WHO (no snapshot change)
    whostore_watch_off_no_ingest = {
        title = "whostore_watch_off_no_ingest",
        description =
        "Watcher off: record lastUpdatedTs, disable watcher, manual 'who' should NOT update WhoStore; then re-enable watcher.",
        delay = 0.45,
        steps = {
            { cmd = "dwwho watch on",  note = "Ensure watcher is ON before setting baseline." },

            {
                cmd = "dwwho refresh",
                delay = 0.80, -- let refresh capture + ingest settle
                note = "Create a known baseline snapshot via refresh (source=dwwho:refresh).",
            },

            {
                cmd =
                'lua do local S=require("dwkit.services.whostore_service"); if type(S)~="table" or type(S.getState)~="function" then error("WhoStoreService.getState missing") end; local st=S.getState(); _G.DWVERIFY_WHO_TS=st.lastUpdatedTs; _G.DWVERIFY_WHO_SRC=st.source; print(string.format("[dwverify-whostore] baseline lastUpdatedTs=%s source=%s", tostring(_G.DWVERIFY_WHO_TS), tostring(_G.DWVERIFY_WHO_SRC))) end',
                note = "Record baseline lastUpdatedTs + source into _G (used for later assert).",
            },

            { cmd = "dwwho watch off", note = "Disable watcher. Manual 'who' should no longer ingest." },

            {
                cmd = "who",
                delay = 0.80, -- allow any accidental ingest to happen (should NOT)
                note = "Manual WHO while watcher OFF: should NOT update WhoStore.",
            },

            {
                cmd =
                'lua do local S=require("dwkit.services.whostore_service"); if type(S)~="table" or type(S.getState)~="function" then error("WhoStoreService.getState missing") end; local st=S.getState(); if tostring(st.lastUpdatedTs)~=tostring(_G.DWVERIFY_WHO_TS) then error("Expected lastUpdatedTs unchanged while watcher OFF; before="..tostring(_G.DWVERIFY_WHO_TS).." after="..tostring(st.lastUpdatedTs)) end; if tostring(st.source)~=tostring(_G.DWVERIFY_WHO_SRC) then error("Expected source unchanged while watcher OFF; before="..tostring(_G.DWVERIFY_WHO_SRC).." after="..tostring(st.source)) end end',
                note = "Assert: lastUpdatedTs + source unchanged while watcher OFF (FAIL if changed).",
            },

            { cmd = "dwwho watch on", note = "Re-enable watcher for normal operation." },
            { cmd = "dwwho status",   note = "Human confirmation: watcher enabled; state stable." },
        },
    },

    -- Smoke suite (very short)
    smoke = {
        title = "smoke",
        description = "Very short smoke check (no who spam unless you choose)",
        delay = 0.20,
        steps = {
            "dwwho watch status",
            "dwwho",
        },
    },

    -- UI smoke suite (console visible state; no screenshots)
    -- IMPORTANT: UI modules' apply() uses gui_settings for enabled/visible; opts passed to apply() are ignored.
    -- This suite sets gui_settings (noSave) then calls apply({}) and prints pasteable state.
    ui_smoke = {
        title = "ui_smoke",
        description = "UI smoke: set gui_settings then apply; print visible true/false (no screenshots)",
        delay = 0.25,
        steps = {
            {
                cmd =
                'lua do local gs=require("dwkit.config.gui_settings"); gs.enableVisiblePersistence({noSave=true}); gs.setEnabled("presence_ui", true, {noSave=true}); gs.setVisible("presence_ui", true, {noSave=true}); local UI=require("dwkit.ui.presence_ui"); local ok,err=UI.apply({}); if not ok then error(err) end; local s=UI.getState(); print(string.format("[dwverify-ui] presence_ui visible=%s enabled=%s hasContainer=%s hasLabel=%s", tostring(s.visible), tostring(s.enabled), tostring(s.widgets and s.widgets.hasContainer), tostring(s.widgets and s.widgets.hasLabel))) end',
                note = "Show presence_ui via gui_settings + apply(); print state.",
            },
            {
                cmd =
                'lua do local gs=require("dwkit.config.gui_settings"); gs.enableVisiblePersistence({noSave=true}); gs.setEnabled("roomentities_ui", true, {noSave=true}); gs.setVisible("roomentities_ui", true, {noSave=true}); local UI=require("dwkit.ui.roomentities_ui"); local ok,err=UI.apply({}); if not ok then error(err) end; local s=UI.getState(); print(string.format("[dwverify-ui] roomentities_ui visible=%s enabled=%s hasContainer=%s hasLabel=%s hasListRoot=%s", tostring(s.visible), tostring(s.enabled), tostring(s.widgets and s.widgets.hasContainer), tostring(s.widgets and s.widgets.hasLabel), tostring(s.widgets and s.widgets.hasListRoot))) end',
                note = "Show roomentities_ui via gui_settings + apply(); print state.",
            },
        },
    },

    -- NEW: Locked semantics verification (Objective 1)
    ui_disable_forces_visible_off = {
        title = "ui_disable_forces_visible_off",
        description = "Locked semantics: dwgui disable must force visible=OFF (and stand down best-effort)",
        delay = 0.30,
        steps = {
            {
                cmd =
                'lua do local gs=require("dwkit.config.gui_settings"); gs.enableVisiblePersistence({noSave=true}); gs.setEnabled("roomentities_ui", true, {noSave=true}); gs.setVisible("roomentities_ui", true, {noSave=true}); local UI=require("dwkit.ui.roomentities_ui"); local ok,err=UI.apply({}); if not ok then error(err) end; local s=UI.getState(); print(string.format("[dwverify-ui] pre-disable roomentities_ui visible=%s enabled=%s", tostring(s.visible), tostring(s.enabled))) end',
                note = "Precondition: make roomentities_ui enabled+visible in-memory and show it.",
            },
            { cmd = "dwgui disable roomentities_ui", note = "Disable should also force visible OFF (and dispose best-effort)." },
            {
                cmd =
                'lua do local gs=require("dwkit.config.gui_settings"); local m=gs.list(); local rec=m["roomentities_ui"]; if type(rec)~="table" then error("Expected gui_settings record for roomentities_ui") end; if rec.enabled~=false then error("Expected enabled=false after disable; got "..tostring(rec.enabled)) end; if rec.visible~=false then error("Expected visible=false after disable; got "..tostring(rec.visible)) end; print("[dwverify-ui] PASS gui_settings enabled=false visible=false after disable") end',
                note = "ASSERT: gui_settings shows enabled=false and visible=false after dwgui disable.",
            },
            { cmd = "dwgui status",                  note = "Human confirmation: list should show roomentities_ui enabled=OFF visible=OFF." },
        },
    },

    -- ---------------------------------------------------------------------
    -- UI Manager + LaunchPad suites (ported from the provided changes, but
    -- kept compatible with existing runner schema + best-effort guards).
    -- ---------------------------------------------------------------------

    ui_manager_enabled_visible_matrix = {
        title = "ui_manager_enabled_visible_matrix",
        description =
        "UI manager applies enabled/visible matrix; visible toggles should reflect in UI state; disabled UI should stand down best-effort.",
        delay = 0.30,
        steps = {
            {
                cmd =
                'lua do local gs=require("dwkit.config.gui_settings"); gs.enableVisiblePersistence({noSave=true}); if type(gs.register)=="function" then pcall(gs.register,"presence_ui",{enabled=false,visible=false},{save=false}); pcall(gs.register,"roomentities_ui",{enabled=false,visible=false},{save=false}); pcall(gs.register,"launchpad_ui",{enabled=false,visible=false},{save=false}); end; gs.setEnabled("presence_ui",true,{noSave=true}); gs.setVisible("presence_ui",true,{noSave=true}); gs.setEnabled("roomentities_ui",true,{noSave=true}); gs.setVisible("roomentities_ui",true,{noSave=true}); gs.setEnabled("launchpad_ui",false,{noSave=true}); gs.setVisible("launchpad_ui",false,{noSave=true}); local UM=require("dwkit.ui.ui_manager"); if type(UM)~="table" or type(UM.applyAll)~="function" then error("ui_manager.applyAll missing") end; local ok,err=UM.applyAll({source="dwverify:matrix"}); if ok==false then error("ui_manager.applyAll failed: "..tostring(err)) end; local P=require("dwkit.ui.presence_ui"); local R=require("dwkit.ui.roomentities_ui"); local sp=P.getState(); local sr=R.getState(); if sp.visible~=true then error("Expected presence_ui visible=true; got "..tostring(sp.visible)) end; if sr.visible~=true then error("Expected roomentities_ui visible=true; got "..tostring(sr.visible)) end; print("[dwverify-ui] PASS matrix step1 presence_ui visible=true roomentities_ui visible=true") end',
                note = "Seed enabled/visible for presence+roomentities; applyAll; assert both visible=true.",
            },
            {
                cmd =
                'lua do local gs=require("dwkit.config.gui_settings"); gs.setVisible("presence_ui",false,{noSave=true}); local UM=require("dwkit.ui.ui_manager"); local ok,err=UM.applyOne("presence_ui",{source="dwverify:matrix"}); if ok==false then error("applyOne(presence_ui) failed: "..tostring(err)) end; local P=require("dwkit.ui.presence_ui"); local st=P.getState(); if st.visible~=false then error("Expected presence_ui visible=false; got "..tostring(st.visible)) end; print("[dwverify-ui] PASS matrix step2 presence_ui visible=false (enabled remains ON)") end',
                note = "Toggle presence_ui visible OFF (still enabled); applyOne; assert visible=false.",
            },
            {
                cmd =
                'lua do local gs=require("dwkit.config.gui_settings"); gs.setEnabled("roomentities_ui",false,{noSave=true}); gs.setVisible("roomentities_ui",false,{noSave=true}); local UM=require("dwkit.ui.ui_manager"); local ok,err=UM.applyOne("roomentities_ui",{source="dwverify:matrix"}); if ok==false then error("applyOne(roomentities_ui) failed: "..tostring(err)) end; local R=require("dwkit.ui.roomentities_ui"); local st=R.getState(); local okState=(st.visible==false) or (st.enabled==false) or (st.inited==false); if not okState then error("Expected roomentities_ui to stand down (visible/enabled/inited false); got visible="..tostring(st.visible).." enabled="..tostring(st.enabled).." inited="..tostring(st.inited)) end; print("[dwverify-ui] PASS matrix step3 roomentities_ui stood down best-effort") end',
                note =
                "Disable roomentities_ui; applyOne; accept any of: visible=false OR enabled=false OR inited=false (best-effort stand-down).",
            },
        },
        _toggle_helper = true, -- (ignored; harmless marker if your runner prints raw suite table; remove if undesired)
    },

    launchpad_only_when_any_enabled = {
        title = "launchpad_only_when_any_enabled",
        description = "LaunchPad must not appear when no other UI is enabled; must appear when at least one is enabled.",
        delay = 0.30,
        steps = {
            {
                cmd =
                'lua do local gs=require("dwkit.config.gui_settings"); gs.enableVisiblePersistence({noSave=true}); if type(gs.register)=="function" then pcall(gs.register,"launchpad_ui",{enabled=true,visible=true},{save=false}); pcall(gs.register,"presence_ui",{enabled=false,visible=false},{save=false}); pcall(gs.register,"roomentities_ui",{enabled=false,visible=false},{save=false}); end; gs.setEnabled("presence_ui",false,{noSave=true}); gs.setVisible("presence_ui",false,{noSave=true}); gs.setEnabled("roomentities_ui",false,{noSave=true}); gs.setVisible("roomentities_ui",false,{noSave=true}); gs.setEnabled("launchpad_ui",true,{noSave=true}); gs.setVisible("launchpad_ui",true,{noSave=true}); local UM=require("dwkit.ui.ui_manager"); if type(UM)=="table" and type(UM.applyOne)=="function" then UM.applyOne("launchpad_ui",{source="dwverify:launchpad"}) else local L=require("dwkit.ui.launchpad_ui"); if type(L.apply)=="function" then L.apply({}) end end; local L=require("dwkit.ui.launchpad_ui"); local st=L.getState(); local rowCount=(st.widgets and st.widgets.rowCount) or (st.rowCount) or 0; if st.visible~=false then error("Expected launchpad visible=false when no other UI enabled; got "..tostring(st.visible)) end; if tonumber(rowCount)~=0 then error("Expected launchpad rowCount=0 when none enabled; got "..tostring(rowCount)) end; print("[dwverify-ui] PASS launchpad step1 hidden when none enabled (rowCount=0)") end',
                note = "No enabled UIs (besides LaunchPad itself). Expect LaunchPad forces itself hidden and 0 rows.",
            },
            {
                cmd =
                'lua do local gs=require("dwkit.config.gui_settings"); gs.setEnabled("roomentities_ui",true,{noSave=true}); gs.setVisible("roomentities_ui",false,{noSave=true}); gs.setVisible("launchpad_ui",true,{noSave=true}); local UM=require("dwkit.ui.ui_manager"); if type(UM)=="table" and type(UM.applyOne)=="function" then UM.applyOne("roomentities_ui",{source="dwverify:launchpad"}); UM.applyOne("launchpad_ui",{source="dwverify:launchpad"}) else local R=require("dwkit.ui.roomentities_ui"); if type(R.apply)=="function" then R.apply({}) end; local L=require("dwkit.ui.launchpad_ui"); if type(L.apply)=="function" then L.apply({}) end end; local L=require("dwkit.ui.launchpad_ui"); local st=L.getState(); local ids=st.renderedUiIds or {}; local has=false; for i=1,#ids do if ids[i]=="roomentities_ui" then has=true end end; local rowCount=(st.widgets and st.widgets.rowCount) or (st.rowCount) or #ids; if st.visible~=true then error("Expected launchpad visible=true when at least one enabled; got "..tostring(st.visible)) end; if not has then error("Expected launchpad list to include roomentities_ui; ids="..tostring(table.concat(ids,","))) end; if tonumber(rowCount)<1 then error("Expected launchpad rowCount>=1; got "..tostring(rowCount)) end; print("[dwverify-ui] PASS launchpad step2 visible and lists roomentities_ui") end',
                note = "Enable roomentities_ui only. Expect LaunchPad visible=true and lists roomentities_ui.",
            },
        },
    },

    launchpad_lists_enabled_only = {
        title = "launchpad_lists_enabled_only",
        description =
        "LaunchPad list contains only enabled UIs and updates after enable/disable changes (sorted by uiId).",
        delay = 0.30,
        steps = {
            {
                cmd =
                'lua do local gs=require("dwkit.config.gui_settings"); gs.enableVisiblePersistence({noSave=true}); if type(gs.register)=="function" then pcall(gs.register,"launchpad_ui",{enabled=true,visible=true},{save=false}); pcall(gs.register,"presence_ui",{enabled=false,visible=false},{save=false}); pcall(gs.register,"roomentities_ui",{enabled=false,visible=false},{save=false}); end; gs.setEnabled("presence_ui",true,{noSave=true}); gs.setVisible("presence_ui",true,{noSave=true}); gs.setEnabled("roomentities_ui",true,{noSave=true}); gs.setVisible("roomentities_ui",false,{noSave=true}); gs.setEnabled("launchpad_ui",true,{noSave=true}); gs.setVisible("launchpad_ui",true,{noSave=true}); local UM=require("dwkit.ui.ui_manager"); if type(UM)~="table" or type(UM.applyAll)~="function" then error("ui_manager.applyAll missing") end; local ok,err=UM.applyAll({source="dwverify:launchpad"}); if ok==false then error("ui_manager.applyAll failed: "..tostring(err)) end; local L=require("dwkit.ui.launchpad_ui"); local st=L.getState(); local ids=st.renderedUiIds or {}; if #ids~=2 or ids[1]~="presence_ui" or ids[2]~="roomentities_ui" then error("Expected ids=[presence_ui,roomentities_ui]; got "..tostring(table.concat(ids,","))) end; print("[dwverify-ui] PASS launchpad list step1 ids="..tostring(table.concat(ids,","))) end',
                note = "Enable presence_ui + roomentities_ui; LaunchPad should list exactly both (sorted by uiId).",
            },
            {
                cmd =
                'lua do local gs=require("dwkit.config.gui_settings"); gs.setEnabled("presence_ui",false,{noSave=true}); gs.setVisible("presence_ui",false,{noSave=true}); local UM=require("dwkit.ui.ui_manager"); if type(UM)~="table" or type(UM.applyOne)~="function" then error("ui_manager.applyOne missing") end; UM.applyOne("presence_ui",{source="dwverify:launchpad"}); UM.applyOne("launchpad_ui",{source="dwverify:launchpad"}); local L=require("dwkit.ui.launchpad_ui"); local st=L.getState(); local ids=st.renderedUiIds or {}; if #ids~=1 or ids[1]~="roomentities_ui" then error("Expected ids=[roomentities_ui]; got "..tostring(table.concat(ids,","))) end; print("[dwverify-ui] PASS launchpad list step2 ids="..tostring(table.concat(ids,","))) end',
                note = "Disable presence_ui; LaunchPad should list only roomentities_ui.",
            },
        },
    },
}

function M.getSuites()
    return SUITES
end

return M

-- #########################################################################
-- END FILE: src/dwkit/verify/verification_plan.lua
-- #########################################################################
