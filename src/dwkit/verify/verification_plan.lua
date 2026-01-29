-- #########################################################################
-- BEGIN FILE: src/dwkit/verify/verification_plan.lua
-- #########################################################################
-- Module Name : dwkit.verify.verification_plan
-- Owner       : Verify
-- Version     : v2026-01-29A
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

M.VERSION = "v2026-01-29A"

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
