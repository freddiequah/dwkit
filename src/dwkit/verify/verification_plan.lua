-- FILE: src/dwkit/verify/verification_plan.lua
-- #########################################################################
-- BEGIN FILE: src/dwkit/verify/verification_plan.lua
-- #########################################################################
-- Module Name : dwkit.verify.verification_plan
-- Owner       : Verify
-- Version     : v2026-02-23M
-- Purpose     :
--   - Defines verification suites (data only) for dwverify.
--   - Each suite is a table with: title, description, delay, steps.
--   - steps can be:
--       * "command string" (Mudlet command)
--       * { cmd="...", note="...", expect="...", delay=... } for richer output
-- Notes:
--   - KEEP Lua steps single-line: use `lua do ... end` only (Mudlet input paste safety).
--   - Suites should avoid spamming gameplay commands; prefer SAFE commands.
-- #########################################################################

local M = {}

M.VERSION = "v2026-02-23M"

local SUITES = {
    -- Default suite (safe baseline)
    default = {
        title = "default",
        description = "Baseline sanity: dwwho refresh + watcher capture",
        delay = 0.40,
        steps = {
            "dwwho",
            "dwwho watch status",
            "dwwho refresh",
            "dwwho",
            "who",
            "dwwho",
        },
    },

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

    roomfeed_partial_snapshot_finalize = {
        title = "roomfeed_partial_snapshot_finalize",
        description =
        "RoomFeed v2026-02-09B + v2026-02-23B: prompt before exits should ingest as PARTIAL snapshot (no abort), update lastSnapshotTs, and latch degradedReason=partial:prompt_before_exits. Uses capture._testIngestSnapshot (SAFE; no sends).",
        delay = 0.30,
        steps = {
            {
                cmd =
                'lua do local C=require("dwkit.capture.roomfeed_capture"); local S=require("dwkit.services.roomfeed_status_service"); if type(C)~="table" or type(C._testIngestSnapshot)~="function" then error("Expected roomfeed_capture._testIngestSnapshot") end; local pre=S.getState(); local preTs=tostring(pre.lastSnapshotTs or ""); local ok,err=C._testIngestSnapshot({"The Temple of Asgaard","   A plain room description line."},{hasExits=false,startKind="fallback"}); if not ok then error("test ingest failed: "..tostring(err)) end; local post=S.getState(); if post.lastSnapshotTs==nil then error("Expected lastSnapshotTs non-nil after partial finalize") end; if tostring(post.lastSnapshotTs)==preTs then error("Expected lastSnapshotTs to change after partial finalize; before="..preTs.." after="..tostring(post.lastSnapshotTs)) end; if tostring(post.degradedReason or "")~="partial:prompt_before_exits" then error("Expected degradedReason partial:prompt_before_exits; got "..tostring(post.degradedReason)) end; local dbg=C.getDebugState(); if tostring(dbg.lastAbortReason or "")~="" then error("Expected lastAbortReason nil/empty after partial finalize; got "..tostring(dbg.lastAbortReason)) end; if tostring(dbg.lastDegradedReason or "")~="partial:prompt_before_exits" then error("Expected capture lastDegradedReason partial:prompt_before_exits; got "..tostring(dbg.lastDegradedReason)) end; print(string.format("[dwverify-roomfeed] PASS partial finalize snapshotTs=%s degraded=%s", tostring(post.lastSnapshotTs), tostring(post.degradedReason))) end',
                note =
                "ASSERT: partial finalize updates snapshot freshness and latches degraded state; capture does not abort.",
            },
            { cmd = "dwroom watch status", note = "Human confirmation: RoomWatch should show health=DEGRADED with note partial:prompt_before_exits and a recent lastCaptureTs." },
        },
    },

    roomfeed_partial_fallback_guard = {
        title = "roomfeed_partial_fallback_guard",
        description =
        "RoomFeed v2026-02-23B: fallback-start snapshot that is NOT room-like (e.g. WHO header 'Players') must NOT ingest/overwrite RoomEntities; it must abort as abort:partial_fallback_not_roomlike. SAFE; no sends.",
        delay = 0.30,
        steps = {
            {
                cmd =
                'lua do local R=require("dwkit.services.roomentities_service"); local ok,err=R.ingestFixture({unknown={"A large keg of Killians Irish Red"},source="dwverify:roomfeed_guard",forceEmit=true}); if ok==false then error("fixture ingest failed: "..tostring(err)) end; local st=R.getState(); if st==nil or type(st.unknown)~="table" or st.unknown["A large keg of Killians Irish Red"]~=true then error("Precondition failed: expected unknown fixture present") end; print("[dwverify-roomfeed] precondition OK fixture unknown present") end',
                note = "Precondition: seed RoomEntities with a known unknown so we can detect accidental wipe.",
            },
            {
                cmd =
                'lua do local C=require("dwkit.capture.roomfeed_capture"); local ok,err=C._testIngestSnapshot({"Players","-------","[50 War] Nuku is putting on the foil!"},{hasExits=false,startKind="fallback"}); if ok==false then error("test ingest failed: "..tostring(err)) end; local dbg=C.getDebugState(); if tostring(dbg.lastAbortReason or "")~="abort:partial_fallback_not_roomlike" then error("Expected abort:partial_fallback_not_roomlike; got "..tostring(dbg.lastAbortReason)) end; local R=require("dwkit.services.roomentities_service"); local st=R.getState(); if st==nil or type(st.unknown)~="table" then error("Expected RoomEntities state table") end; if st.unknown["A large keg of Killians Irish Red"]~=true then error("FAIL: RoomEntities fixture was wiped/overwritten by fallback partial") end; print(string.format("[dwverify-roomfeed] PASS fallback guard abort=%s fixturePreserved=true", tostring(dbg.lastAbortReason))) end',
                note = "ASSERT: fallback-start non-room-like partial aborts and does NOT wipe RoomEntities.",
            },
        },
    },

    roomfeed_promptprefix_no_restart = {
        title = "roomfeed_promptprefix_no_restart",
        description =
        "RoomFeed regression: prompt+header on same line must start capture; look block must NOT trigger mid-capture restart on wrapped description lines; works for both Immortal (id/flags) and normal rooms (title-only). Expect lastOkTs non-nil and lastAbortReason != abort:restart_header_seen.",
        delay = 0.40,
        steps = {
            { cmd = "dwroom watch off", note = "Ensure clean start: remove passive capture trigger." },
            { cmd = "dwroom watch on",  note = "Install passive capture trigger." },
            { cmd = "look",             delay = 1.80,                                                note = "Trigger look output (header may be prefixed by prompt). Wait for prompt to ensure finalize occurs." },
            {
                cmd =
                'lua do local C=require("dwkit.capture.roomfeed_capture"); local s=C.getDebugState(); local kind=tostring(s.lastHeaderSeenKind or ""); local isStrong=(kind:sub(1,6)=="strong"); local isFallback=(kind:sub(1,8)=="fallback"); if (not isStrong) and (not isFallback) then error("Expected lastHeaderSeenKind strong* OR fallback*; got "..kind) end; local eff=tostring(s.lastHeaderSeenEffectiveClean or ""); if eff=="" then error("Expected non-empty effective header; got empty") end; if isStrong then local hasId=(eff:find("#",1,true)~=nil); local hasFlags=(eff:find("[",1,true)~=nil and eff:find("]",1,true)~=nil); if (not hasId) and (not hasFlags) then error("Expected strong header to include id (#) or flags ([..]); got "..eff) end end; if tostring(s.lastAbortReason or "")=="abort:restart_header_seen" then error("Unexpected restart_header_seen (wrapped text misdetected as header).") end; if s.lastOkTs==nil then error("Expected lastOkTs non-nil after look finalize; stillCapturing="..tostring(s.snapCapturing).." hasExits="..tostring(s.snapHasExits).." bufLen="..tostring(s.snapBufLen).." lastLine="..tostring(s.lastLineSeenClean)) end; print(string.format("[dwverify-roomfeed] PASS kind=%s okTs=%s abort=%s eff=%s", kind, tostring(s.lastOkTs), tostring(s.lastAbortReason), eff)) end',
                note =
                "ASSERT: finalize succeeded; no false restart; header classification allows Immortal strong OR normal fallback; strong implies id/flags present.",
            },
            { cmd = "dwroom status", note = "Human confirmation: Room feed capture status should show lastOkTs updated and no restart abort." },
        },
    },

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
                note = "Force-close auto-capture gate (precondition).",
            },
            {
                cmd =
                'lua do local S=require("dwkit.services.whostore_service"); if type(S)~="table" or type(S.getState)~="function" then error("WhoStoreService.getState missing") end; local st=S.getState(); _G.DWVERIFY_GATE_BASE_TS=st.lastUpdatedTs; print(string.format("[dwverify-whostore] baseline lastUpdatedTs=%s source=%s autoCaptureEnabled=%s", tostring(st.lastUpdatedTs), tostring(st.source), tostring(st.autoCaptureEnabled))) end',
                note = "Record baseline lastUpdatedTs into _G.",
            },
            { cmd = "who",            delay = 0.90,                                          note = "Manual WHO: watcher header trigger must force-open gate and capture/ingest as dwwho:auto." },
            {
                cmd =
                'lua do local S=require("dwkit.services.whostore_service"); if type(S)~="table" or type(S.getState)~="function" then error("WhoStoreService.getState missing") end; local st=S.getState(); if st.autoCaptureEnabled~=true then error("Expected autoCaptureEnabled=true after manual who; got "..tostring(st.autoCaptureEnabled)) end; if tostring(st.source)~="dwwho:auto" then error("Expected source dwwho:auto after manual who; got "..tostring(st.source)) end; if st.lastUpdatedTs==nil then error("Expected lastUpdatedTs non-nil after manual who") end; local base=_G.DWVERIFY_GATE_BASE_TS; if base~=nil and tostring(st.lastUpdatedTs)==tostring(base) then error("Expected lastUpdatedTs to change; before="..tostring(base).." after="..tostring(st.lastUpdatedTs)) end; print(string.format("[dwverify-whostore] PASS gate-force-open autoCaptureEnabled=%s source=%s lastUpdatedTs=%s", tostring(st.autoCaptureEnabled), tostring(st.source), tostring(st.lastUpdatedTs))) end',
                note = "ASSERT: gate forced open + ingest happened.",
            },
            { cmd = "dwwho status", note = "Human confirmation: expect autoCaptureEnabled=true and updated source/ts." },
        },
    },

    smoke = {
        title = "smoke",
        description = "Very short smoke check (no who spam unless you choose)",
        delay = 0.20,
        steps = {
            "dwwho watch status",
            "dwwho",
        },
    },

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
            {
                cmd =
                'lua do local gs=require("dwkit.config.gui_settings"); gs.enableVisiblePersistence({noSave=true}); gs.setEnabled("launchpad_ui", true, {noSave=true}); gs.setVisible("launchpad_ui", true, {noSave=true}); local UM=require("dwkit.ui.ui_manager"); if type(UM)=="table" and type(UM.applyOne)=="function" then UM.applyOne("launchpad_ui",{source="dwverify:ui_smoke"}) else local UI=require("dwkit.ui.launchpad_ui"); if type(UI.apply)=="function" then local ok,err=UI.apply({}); if ok==false then error(err) end end end; local UI=require("dwkit.ui.launchpad_ui"); local s=UI.getState(); local rowCount=(s.widgets and s.widgets.rowCount) or s.rowCount or 0; local ids=s.renderedUiIds or {}; print(string.format("[dwverify-ui] launchpad_ui visible=%s enabled=%s rowCount=%s ids=%s", tostring(s.visible), tostring(s.enabled), tostring(rowCount), tostring(table.concat(ids,",")))) end',
                note = "Show launchpad_ui and print rendered list state.",
            },
            {
                cmd =
                'lua do local gs=require("dwkit.config.gui_settings"); gs.enableVisiblePersistence({noSave=true}); gs.setEnabled("chat_ui", true, {noSave=true}); gs.setVisible("chat_ui", true, {noSave=true}); local UM=require("dwkit.ui.ui_manager"); if type(UM)=="table" and type(UM.applyOne)=="function" then local ok,err=UM.applyOne("chat_ui",{source="dwverify:ui_smoke"}); if ok==false then error("applyOne(chat_ui) failed: "..tostring(err)) end end; local UI=require("dwkit.ui.chat_ui"); local s=UI.getState(); local u=(s and s.unread and s.unread.Other) or 0; print(string.format("[dwverify-ui] chat_ui visible=%s activeTab=%s unreadOther=%s", tostring(s and s.visible), tostring(s and s.activeTab), tostring(u))); end',
                note = "Show chat_ui and print state.",
            },
        },
    },

    -- ---------------------------------------------------------------------
    -- Chat Manager UI suites (canonical)
    -- ---------------------------------------------------------------------

    chat_manager_ui_live_readback = {
        title = "chat_manager_ui_live_readback",
        description =
        "Chat Manager UI: deterministic live readback. External ChatMgr.setFeature(apply=false) + UI.refresh(force=false) must update rowWidgets[all_unread_badge].toggleText. SAFE; no clicks.",
        delay = 0.30,
        steps = {
            {
                cmd =
                'lua do local gs=require("dwkit.config.gui_settings"); gs.enableVisiblePersistence({noSave=true}); gs.setEnabled("chat_manager_ui", true, {noSave=true}); gs.setVisible("chat_manager_ui", true, {noSave=true}); local UM=require("dwkit.ui.ui_manager"); local ok,err=UM.applyOne("chat_manager_ui",{source="dwverify:cm:live"}); if ok==false then error("applyOne(chat_manager_ui) failed: "..tostring(err)) end; local UI=require("dwkit.ui.chat_manager_ui"); UI.refresh({source="dwverify:cm:live:refresh0",force=false}); local dbg=UI.getLayoutDebug(); if type(dbg)~="table" then error("Expected layout debug table") end; if dbg.visible~=true then error("Expected visible=true") end; if dbg.hasStatusLabel~=true then error("Expected hasStatusLabel=true") end; local W=dbg.rowWidgets or {}; local row=W.all_unread_badge; if type(row)~="table" then error("Missing rowWidgets all_unread_badge") end; if row.kind~="bool" or row.hasToggle~=true then error("Expected bool toggle row all_unread_badge") end; if tostring(row.toggleText or "")=="" then error("Expected non-empty toggleText precondition") end; print(string.format("[dwverify-cm] pre toggleText=%s", tostring(row.toggleText))) end',
                note = "Precondition: UI visible, status label exists, all_unread_badge row exists and has toggleText.",
            },
            {
                cmd =
                'lua do local UI=require("dwkit.ui.chat_manager_ui"); local Mgr=require("dwkit.services.chat_manager"); local pre=(Mgr.getFeature("all_unread_badge")==true); local want=(not pre); local okSet,errSet=Mgr.setFeature("all_unread_badge", want, {source="dwverify:cm:live:set", apply=false}); if okSet==false then error("setFeature failed: "..tostring(errSet)) end; UI.refresh({source="dwverify:cm:live:refresh1",force=false}); local dbg=UI.getLayoutDebug(); local row=(dbg.rowWidgets or {}).all_unread_badge; if type(row)~="table" then error("Missing rowWidgets all_unread_badge after refresh") end; local got=tostring(row.toggleText or ""); local wantTxt=want and "Disable" or "Enable"; if not got:find(wantTxt,1,true) then error("Expected toggleText to include "..wantTxt.."; got "..got) end; print(string.format("[dwverify-cm] PASS live_readback all_unread_badge %s->%s toggleText=%s", tostring(pre), tostring(want), got)) end',
                note =
                "ASSERT: external setFeature(apply=false) + refresh(force=false) updates toggleText deterministically.",
            },
        },
    },

    -- ---------------------------------------------------------------------
    -- Chat UI feature propagation (your existing one)
    -- ---------------------------------------------------------------------
    chat_ui_feature_effects = {
        title = "chat_ui_feature_effects",
        description =
        "Chat UI Phase 2: asserts chat_manager feature config propagates into chat_ui, and asserts All unread badge aggregation behavior. SAFE; uses chat_log_service injection; no clicks; no screenshots.",
        delay = 0.30,
        steps = {
            { cmd = "dwchat",       note = "Ensure chat_ui is enabled+visible." },
            { cmd = "dwchat clear", note = "Clear store/UI counters to a clean baseline." },

            {
                cmd =
                'lua do local Mgr=require("dwkit.services.chat_manager"); local UI=require("dwkit.ui.chat_ui"); Mgr.resetDefaults({source="dwverify:chatui:defaults",apply=true}); UI.refresh({force=true,source="dwverify:chatui:refresh0"}); local feats=(UI.getFeatureConfig() and UI.getFeatureConfig().features) or {}; local function b(k) return feats[k]==true end; local function n(k) return tonumber(feats[k] or 0) end; if b("all_unread_badge")~=false then error("Expected default all_unread_badge=false") end; if b("auto_scroll_follow")~=false then error("Expected default auto_scroll_follow=false") end; if b("per_tab_line_limit")~=false then error("Expected default per_tab_line_limit=false") end; if n("per_tab_line_limit_n")~=500 then error("Expected default per_tab_line_limit_n=500; got "..tostring(n("per_tab_line_limit_n"))) end; if b("timestamp_prefix")~=false then error("Expected default timestamp_prefix=false") end; if b("debug_overlay")~=false then error("Expected default debug_overlay=false") end; print("[dwverify-chatui] PASS defaults propagated into chat_ui") end',
                note = "ASSERT: chat_manager defaults propagate into chat_ui featureCfg (best-effort config contract).",
            },

            {
                cmd =
                'lua do local Mgr=require("dwkit.services.chat_manager"); local UI=require("dwkit.ui.chat_ui"); Mgr.setFeature("all_unread_badge", true, {source="dwverify:chatui:set",apply=true}); Mgr.setFeature("timestamp_prefix", true, {source="dwverify:chatui:set",apply=true}); Mgr.setFeature("per_tab_line_limit", true, {source="dwverify:chatui:set",apply=true}); Mgr.setFeature("per_tab_line_limit_n", 50, {source="dwverify:chatui:set",apply=true}); Mgr.setFeature("debug_overlay", true, {source="dwverify:chatui:set",apply=true}); Mgr.setFeature("auto_scroll_follow", true, {source="dwverify:chatui:set",apply=true}); UI.refresh({force=true,source="dwverify:chatui:refresh1"}); local feats=(UI.getFeatureConfig() and UI.getFeatureConfig().features) or {}; local function reqTrue(k) if feats[k]~=true then error("Expected "..tostring(k).."=true in chat_ui featureCfg; got "..tostring(feats[k])) end end; reqTrue("all_unread_badge"); reqTrue("timestamp_prefix"); reqTrue("per_tab_line_limit"); reqTrue("debug_overlay"); reqTrue("auto_scroll_follow"); local n=tonumber(feats.per_tab_line_limit_n or 0) or 0; if n~=50 then error("Expected per_tab_line_limit_n=50 in chat_ui featureCfg; got "..tostring(n)) end; print("[dwverify-chatui] PASS feature flags propagated into chat_ui") end',
                note = "ASSERT: toggles from chat_manager propagate into chat_ui featureCfg (integration path).",
            },

            { cmd = "dwchat tab SAY", note = "Active tab = SAY so All unread badge can accumulate when enabled." },
            {
                cmd =
                'lua do local Log=require("dwkit.services.chat_log_service"); Log.addLine("[DWKitTEST_PUBLIC_A1]",{channel="GOSSIP",speaker="Vzae",source="dwverify:chatui"}); local UI=require("dwkit.ui.chat_ui"); UI.refresh({force=true,source="dwverify:chatui:refresh2"}); local u=UI.getState().unread or {}; local a=tonumber(u.All or 0) or 0; local p=tonumber(u.PUBLIC or 0) or 0; if a<1 then error("Expected unread.All >=1 when all_unread_badge ON and tab!=All; got "..tostring(a)) end; if p<1 then error("Expected unread.PUBLIC >=1 when active tab=SAY; got "..tostring(p)) end; print(string.format("[dwverify-chatui] PASS all_unread_badge behavior All=%s PUBLIC=%s", tostring(a), tostring(p))) end',
                note = "ASSERT: all_unread_badge aggregates into unread.All when All is not active.",
            },

            { cmd = "dwchat tab All", note = "Switch to All; should clear unread.All immediately (tab-view semantics)." },
            {
                cmd =
                'lua do local UI=require("dwkit.ui.chat_ui"); UI.refresh({force=true,source="dwverify:chatui:refresh3"}); local u=UI.getState().unread or {}; local a=tonumber(u.All or 0) or 0; if a~=0 then error("Expected unread.All cleared when viewing All; got "..tostring(a)) end; print("[dwverify-chatui] PASS unread.All cleared on viewing All") end',
                note = "ASSERT: viewing All clears unread.All.",
            },

            { cmd = 'lua do print("[dwverify-chatui] PASS chat_ui_feature_effects") end', note = "Final PASS marker." },
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