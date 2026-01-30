-- #########################################################################
-- BEGIN FILE: src/dwkit/verify/verification_plan.lua
-- #########################################################################
-- Module Name : dwkit.verify.verification_plan
-- Owner       : Verify
-- Version     : v2026-01-30D
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

M.VERSION = "v2026-01-30D"

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
                'lua do local gs=require("dwkit.config.gui_settings"); gs.enableVisiblePersistence({noSave=true}); gs.setEnabled("presence_ui", true, {noSave=true}); gs.setVisible("presence_ui", false, {noSave=true}); local UI=require("dwkit.ui.presence_ui"); local ok,err=UI.apply({}); if not ok then error(err) end; local s=UI.getState(); print(string.format("[dwverify-ui] presence_ui visible=%s enabled=%s", tostring(s.visible), tostring(s.enabled))) end',
                note = "Hide presence_ui via gui_settings + apply(); print state.",
            },

            {
                cmd =
                'lua do local gs=require("dwkit.config.gui_settings"); gs.enableVisiblePersistence({noSave=true}); gs.setEnabled("roomentities_ui", true, {noSave=true}); gs.setVisible("roomentities_ui", true, {noSave=true}); local UI=require("dwkit.ui.roomentities_ui"); local ok,err=UI.apply({}); if not ok then error(err) end; local s=UI.getState(); print(string.format("[dwverify-ui] roomentities_ui visible=%s enabled=%s hasContainer=%s hasLabel=%s", tostring(s.visible), tostring(s.enabled), tostring(s.widgets and s.widgets.hasContainer), tostring(s.widgets and s.widgets.hasLabel))) end',
                note = "Show roomentities_ui via gui_settings + apply(); print state.",
            },
            {
                cmd =
                'lua do local gs=require("dwkit.config.gui_settings"); gs.enableVisiblePersistence({noSave=true}); gs.setEnabled("roomentities_ui", true, {noSave=true}); gs.setVisible("roomentities_ui", false, {noSave=true}); local UI=require("dwkit.ui.roomentities_ui"); local ok,err=UI.apply({}); if not ok then error(err) end; local s=UI.getState(); print(string.format("[dwverify-ui] roomentities_ui visible=%s enabled=%s", tostring(s.visible), tostring(s.enabled))) end',
                note = "Hide roomentities_ui via gui_settings + apply(); print state.",
            },
        },
    },

    -- NEW: RoomEntities row-list smoke (console verification; no clicks required)
    roomentities_smoke = {
        title = "roomentities_smoke",
        description = "RoomEntities row list: show UI, print lastRender counts/flags, hide UI (no screenshots)",
        delay = 0.25,
        steps = {
            {
                cmd =
                'lua do local gs=require("dwkit.config.gui_settings"); gs.enableVisiblePersistence({noSave=true}); gs.setEnabled("roomentities_ui", true, {noSave=true}); gs.setVisible("roomentities_ui", true, {noSave=true}); local UI=require("dwkit.ui.roomentities_ui"); local ok,err=UI.apply({}); if not ok then error(err) end; local s=UI.getState(); local lr=s.lastRender or {}; local c=lr.counts or {}; print(string.format("[dwverify-roomentities] visible=%s enabled=%s rowUi=%s whoBoost=%s overrides=%s players=%s mobs=%s items=%s unknown=%s err=%s", tostring(s.visible), tostring(s.enabled), tostring(lr.usedRowUi), tostring(lr.usedWhoStoreBoost), tostring((s.overrides and s.overrides.activeOverrideCount) or 0), tostring(c.players), tostring(c.mobs), tostring(c.items), tostring(c.unknown), tostring(lr.lastError))) end',
                note = "Show roomentities_ui, render, and print lastRender counters.",
            },
            {
                cmd =
                'lua do local gs=require("dwkit.config.gui_settings"); gs.enableVisiblePersistence({noSave=true}); gs.setEnabled("roomentities_ui", true, {noSave=true}); gs.setVisible("roomentities_ui", false, {noSave=true}); local UI=require("dwkit.ui.roomentities_ui"); local ok,err=UI.apply({}); if not ok then error(err) end; local s=UI.getState(); print(string.format("[dwverify-roomentities] hide visible=%s enabled=%s", tostring(s.visible), tostring(s.enabled))) end',
                note = "Hide roomentities_ui via gui_settings + apply(); print state.",
            },
        },
    },

    -- NEW: RoomEntities + WhoStore boost proof (fixture-driven, deterministic PASS/FAIL)
    roomentities_whostore_boost_fixture = {
        title = "roomentities_whostore_boost_fixture",
        description =
        "Deterministic: seed WhoStore (Gaidin), seed RoomEntities unknown ('Gaidin the adventurer'), show UI and ASSERT whoBoost=true + players>=1, then hide.",
        delay = 0.30,
        steps = {
            {
                cmd =
                'lua do local WS=require("dwkit.services.whostore_service"); local ok,err=WS.clear({source="dwverify:roomentities"}); if not ok then error("WhoStore clear failed: "..tostring(err)) end; ok,err=WS.setState({players={"Gaidin"}},{source="dwverify:roomentities"}); if not ok then error("WhoStore setState failed: "..tostring(err)) end; print("[dwverify-roomentities] seeded WhoStore players=Gaidin") end',
                note = "Seed WhoStore with known player Gaidin (case-insensitive getEntry).",
            },
            {
                cmd =
                'lua do local S=require("dwkit.services.roomentities_service"); local ok,err=S.ingestFixture({unknown={"Gaidin the adventurer"}, mobs={"a fixture goblin"}, items={"a fixture chest"}, source="dwverify:roomentities"}); if not ok then error("RoomEntities ingestFixture failed: "..tostring(err)) end; print("[dwverify-roomentities] seeded RoomEntities fixture (unknown includes prefix phrase)") end',
                note =
                "Seed RoomEntities with unknown phrase starting with known player name (triggers UI prefix boost).",
            },
            {
                cmd =
                'lua do local gs=require("dwkit.config.gui_settings"); gs.enableVisiblePersistence({noSave=true}); gs.setEnabled("roomentities_ui", true, {noSave=true}); gs.setVisible("roomentities_ui", true, {noSave=true}); local UI=require("dwkit.ui.roomentities_ui"); local ok,err=UI.apply({}); if not ok then error(err) end; local s=UI.getState(); local lr=s.lastRender or {}; local c=lr.counts or {}; if lr.usedWhoStoreBoost~=true then error("Expected whoBoost=true") end; if tonumber(c.players or 0)<1 then error("Expected players>=1") end; print(string.format("[dwverify-roomentities] PASS whoBoost=%s players=%s mobs=%s items=%s unknown=%s err=%s", tostring(lr.usedWhoStoreBoost), tostring(c.players), tostring(c.mobs), tostring(c.items), tostring(c.unknown), tostring(lr.lastError))) end',
                note = "Show UI and ASSERT whoBoost=true + players>=1 (suite FAILs if not).",
            },
            {
                cmd =
                'lua do local gs=require("dwkit.config.gui_settings"); gs.enableVisiblePersistence({noSave=true}); gs.setEnabled("roomentities_ui", true, {noSave=true}); gs.setVisible("roomentities_ui", false, {noSave=true}); local UI=require("dwkit.ui.roomentities_ui"); local ok,err=UI.apply({}); if not ok then error(err) end; local s=UI.getState(); print(string.format("[dwverify-roomentities] hide visible=%s enabled=%s", tostring(s.visible), tostring(s.enabled))) end',
                note = "Hide roomentities_ui via gui_settings + apply(); print state.",
            },
        },
    },

    -- NEW: RoomEntities auto-reclassify on WhoStore Updated (event-driven, deterministic PASS/FAIL)
    roomentities_whostore_live_update_reacts = {
        title = "roomentities_whostore_live_update_reacts",
        description =
        "Event-driven: seed RoomEntities unknown ('Gaidin the adventurer') while WhoStore empty; then set WhoStore players=Gaidin and ASSERT RoomEntitiesService reclassified to players['Gaidin'] and emitted update; optionally show UI and confirm players>=1.",
        delay = 0.35,
        steps = {
            {
                cmd =
                'lua do local WS=require("dwkit.services.whostore_service"); local ok,err=WS.clear({source="dwverify:reclassify"}); if not ok then error("WhoStore clear failed: "..tostring(err)) end; local S=require("dwkit.services.roomentities_service"); ok,err=S.clear({source="dwverify:reclassify"}); if not ok then error("RoomEntities clear failed: "..tostring(err)) end; ok,err=S.ingestFixture({unknown={"Gaidin the adventurer"}, source="dwverify:reclassify"}); if not ok then error("RoomEntities ingestFixture failed: "..tostring(err)) end; local st=S.getState(); if type(st.unknown)~="table" or st.unknown["Gaidin the adventurer"]~=true then error("Expected baseline unknown contains phrase") end; if type(st.players)=="table" and st.players["Gaidin"]==true then error("Unexpected baseline players[Gaidin] already true") end; local stats=S.getStats(); _G.DWVERIFY_RE_UPD=tonumber((stats and stats.updates) or 0) or 0; _G.DWVERIFY_RE_EMIT=tonumber((stats and stats.emits) or 0) or 0; print(string.format("[dwverify-roomentities] baseline set; updates=%s emits=%s", tostring(_G.DWVERIFY_RE_UPD), tostring(_G.DWVERIFY_RE_EMIT))) end',
                note = "Baseline: WhoStore empty; RoomEntities has unknown phrase; record RoomEntities stats.",
            },
            {
                cmd =
                'lua do local WS=require("dwkit.services.whostore_service"); local ok,err=WS.setState({players={"Gaidin"}},{source="dwverify:reclassify"}); if not ok then error("WhoStore setState failed: "..tostring(err)) end; print("[dwverify-roomentities] seeded WhoStore players=Gaidin (should trigger RoomEntities reclassify via event)") end',
                delay = 0.85,
                note = "Trigger WhoStore Updated; wait for RoomEntities event-driven reclassify + emit.",
            },
            {
                cmd =
                'lua do local S=require("dwkit.services.roomentities_service"); local st=S.getState(); if type(st.players)~="table" or st.players["Gaidin"]~=true then error("Expected players[Gaidin]=true after WhoStore update") end; if type(st.unknown)=="table" and st.unknown["Gaidin the adventurer"]==true then error("Expected unknown phrase removed after canonicalize") end; local stats=S.getStats(); local u=tonumber((stats and stats.updates) or 0) or 0; local e=tonumber((stats and stats.emits) or 0) or 0; if u<=tonumber(_G.DWVERIFY_RE_UPD or 0) then error("Expected updates increased after reclassify; before="..tostring(_G.DWVERIFY_RE_UPD).." after="..tostring(u)) end; if e<=tonumber(_G.DWVERIFY_RE_EMIT or 0) then error("Expected emits increased after reclassify; before="..tostring(_G.DWVERIFY_RE_EMIT).." after="..tostring(e)) end; print(string.format("[dwverify-roomentities] PASS reclassify players[Gaidin]=true updates=%s emits=%s", tostring(u), tostring(e))) end',
                note = "ASSERT: RoomEntitiesService reclassified + emitted (suite FAILs if not).",
            },
            {
                cmd =
                'lua do local gs=require("dwkit.config.gui_settings"); gs.enableVisiblePersistence({noSave=true}); gs.setEnabled("roomentities_ui", true, {noSave=true}); gs.setVisible("roomentities_ui", true, {noSave=true}); local UI=require("dwkit.ui.roomentities_ui"); local ok,err=UI.apply({}); if not ok then error(err) end; local s=UI.getState(); local lr=s.lastRender or {}; local c=lr.counts or {}; if tonumber(c.players or 0)<1 then error("Expected UI players>=1 after service reclassify") end; print(string.format("[dwverify-roomentities] UI PASS players=%s mobs=%s items=%s unknown=%s whoBoost=%s rowUi=%s err=%s", tostring(c.players), tostring(c.mobs), tostring(c.items), tostring(c.unknown), tostring(lr.usedWhoStoreBoost), tostring(lr.usedRowUi), tostring(lr.lastError))) end',
                note = "Optional consumer proof: show UI and confirm players>=1 after reclassify.",
            },
            {
                cmd =
                'lua do local gs=require("dwkit.config.gui_settings"); gs.enableVisiblePersistence({noSave=true}); gs.setEnabled("roomentities_ui", true, {noSave=true}); gs.setVisible("roomentities_ui", false, {noSave=true}); local UI=require("dwkit.ui.roomentities_ui"); local ok,err=UI.apply({}); if not ok then error(err) end; local s=UI.getState(); print(string.format("[dwverify-roomentities] hide visible=%s enabled=%s", tostring(s.visible), tostring(s.enabled))) end',
                note = "Hide roomentities_ui via gui_settings + apply(); print state.",
            },
        },
    },

    -- NEW: RoomEntities double update no-change suppression (event-driven; PASS/FAIL via stats)
    roomentities_whostore_double_update_no_change = {
        title = "roomentities_whostore_double_update_no_change",
        description =
        "Event-driven: baseline RoomEntities unknown ('Gaidin the adventurer'); set WhoStore players=Gaidin to reclassify once (emit). Then set WhoStore players=Gaidin again and ASSERT RoomEntities does NOT emit when state does not change (suppressedEmits increments; emits stable).",
        delay = 0.35,
        steps = {
            {
                cmd =
                'lua do local WS=require("dwkit.services.whostore_service"); local ok,err=WS.clear({source="dwverify:nc"}); if not ok then error("WhoStore clear failed: "..tostring(err)) end; local S=require("dwkit.services.roomentities_service"); ok,err=S.clear({source="dwverify:nc"}); if not ok then error("RoomEntities clear failed: "..tostring(err)) end; ok,err=S.ingestFixture({unknown={"Gaidin the adventurer"}, source="dwverify:nc"}); if not ok then error("RoomEntities ingestFixture failed: "..tostring(err)) end; local st=S.getState(); if type(st.unknown)~="table" or st.unknown["Gaidin the adventurer"]~=true then error("Expected baseline unknown contains phrase") end; local stats=S.getStats(); _G.DWVERIFY_NC_EMIT=tonumber((stats and stats.emits) or 0) or 0; _G.DWVERIFY_NC_SUP=tonumber((stats and stats.suppressedEmits) or 0) or 0; print(string.format("[dwverify-roomentities] baseline set; emits=%s suppressed=%s", tostring(_G.DWVERIFY_NC_EMIT), tostring(_G.DWVERIFY_NC_SUP))) end',
                note = "Baseline: WhoStore empty; RoomEntities has unknown phrase; record emits + suppressedEmits.",
            },
            {
                cmd =
                'lua do local WS=require("dwkit.services.whostore_service"); local ok,err=WS.setState({players={"Gaidin"}},{source="dwverify:nc"}); if not ok then error("WhoStore setState(1) failed: "..tostring(err)) end; print("[dwverify-roomentities] WhoStore setState #1 players=Gaidin (should reclassify + emit once)") end',
                delay = 0.85,
                note = "First WhoStore update: should cause reclassify and emit (state changed).",
            },
            {
                cmd =
                'lua do local S=require("dwkit.services.roomentities_service"); local st=S.getState(); if type(st.players)~="table" or st.players["Gaidin"]~=true then error("Expected players[Gaidin]=true after first WhoStore update") end; if type(st.unknown)=="table" and st.unknown["Gaidin the adventurer"]==true then error("Expected unknown phrase removed after canonicalize") end; local stats=S.getStats(); local e=tonumber((stats and stats.emits) or 0) or 0; if e<=tonumber(_G.DWVERIFY_NC_EMIT or 0) then error("Expected emits increased after first reclassify; before="..tostring(_G.DWVERIFY_NC_EMIT).." after="..tostring(e)) end; _G.DWVERIFY_NC_EMIT1=e; _G.DWVERIFY_NC_SUP1=tonumber((stats and stats.suppressedEmits) or 0) or 0; print(string.format("[dwverify-roomentities] PASS stage1 emits=%s suppressed=%s", tostring(_G.DWVERIFY_NC_EMIT1), tostring(_G.DWVERIFY_NC_SUP1))) end',
                note =
                "ASSERT stage1: reclassified + emitted (suite FAILs if not). Capture emits/suppressed baselines for stage2.",
            },
            {
                cmd =
                'lua do local WS=require("dwkit.services.whostore_service"); local ok,err=WS.setState({players={"Gaidin"}},{source="dwverify:nc"}); if not ok then error("WhoStore setState(2) failed: "..tostring(err)) end; print("[dwverify-roomentities] WhoStore setState #2 players=Gaidin (no state change expected; RoomEntities should suppress emit)") end',
                delay = 0.85,
                note = "Second WhoStore update with same set: RoomEntities should detect no change and suppress emit.",
            },
            {
                cmd =
                'lua do local S=require("dwkit.services.roomentities_service"); local st=S.getState(); if type(st.players)~="table" or st.players["Gaidin"]~=true then error("Expected players[Gaidin]=true after second WhoStore update") end; local stats=S.getStats(); local e=tonumber((stats and stats.emits) or 0) or 0; local s=tonumber((stats and stats.suppressedEmits) or 0) or 0; if tostring(e)~=tostring(_G.DWVERIFY_NC_EMIT1) then error("Expected emits unchanged on no-change reclassify; before="..tostring(_G.DWVERIFY_NC_EMIT1).." after="..tostring(e)) end; if s<=tonumber(_G.DWVERIFY_NC_SUP1 or 0) then error("Expected suppressedEmits increased on no-change reclassify; before="..tostring(_G.DWVERIFY_NC_SUP1).." after="..tostring(s)) end; print(string.format("[dwverify-roomentities] PASS no-change suppression emits=%s suppressed=%s", tostring(e), tostring(s))) end',
                note = "ASSERT stage2: emits unchanged + suppressedEmits increased (suite FAILs if not).",
            },
        },
    },
}

function M.getSuites()
    return SUITES
end

function M.getSuite(name)
    if type(name) ~= "string" or name == "" then return nil end
    return SUITES[name]
end

return M

-- #########################################################################
-- END FILE: src/dwkit/verify/verification_plan.lua
-- #########################################################################
