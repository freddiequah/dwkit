-- FILE: src/dwkit/verify/verification_plan.lua
-- #########################################################################
-- BEGIN FILE: src/dwkit/verify/verification_plan.lua
-- #########################################################################
-- Module Name : dwkit.verify.verification_plan
-- Owner       : Verify
-- Version     : v2026-03-05C
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

M.VERSION = "v2026-03-05C"

local SUITES = {
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

    cpc_smoke = {
        title = "cpc_smoke",
        description =
        "CrossProfileComm smoke: print installed state, inject a fake peer (session-only) and assert isProfileOnline works. Then (manual) open/close another Mudlet profile and observe Presence roster change.",
        delay = 0.35,
        steps = {
            {
                cmd =
                'lua do local C=require("dwkit.services.cross_profile_comm_service"); local ok,err=C.install({quiet=true}); print(string.format("[dwverify-cpc] install ok=%s err=%s", tostring(ok==true), tostring(err))) local st=C.getStats(); print(string.format("[dwverify-cpc] myProfile=%s instanceId=%s peerCount=%s", tostring(st.myProfile), tostring(st.instanceId), tostring(st.peerCount))) end',
                note = "Ensure CPC service installed and print state.",
            },
            {
                cmd =
                'lua do local C=require("dwkit.services.cross_profile_comm_service"); C._testClearPeers(); local ok,err=C._testNotePeer("Profile-B",{instanceId="TEST-1"}); if ok==false then error("testNotePeer failed: "..tostring(err)) end; if C.isProfileOnline("Profile-B")~=true then error("Expected Profile-B online after testNotePeer") end; local st=C.getStats(); print(string.format("[dwverify-cpc] PASS test peer online peerCount=%s", tostring(st.peerCount))) end',
                note = "Deterministic local test: inject a fake peer and assert online=true.",
            },
            {
                cmd =
                'lua do print("[dwverify-cpc] MANUAL: open another Mudlet profile tab whose profile name matches one of your owned_profiles labels (e.g., Profile-B). Expect Presence roster to flip it to [ONLINE] immediately. Close it and expect it to flip to [OFFLINE] immediately (sysExitEvent best-effort).") end',
                note = "Human live behavior check (same instance).",
            },
        },
    },

    -- RemoteExec smoke (Objective B)
    remoteexec_smoke = {
        title = "remoteexec_smoke",
        description =
        "RemoteExec MVP smoke (owned-only, manual-triggered). Deterministic receiver simulation: install service, ensure current profile label is treated as owned (noSave; merge into existing map), then inject a receiver-side SEND (empty allowlist) using test helpers and assert send:not_allowlisted. This avoids relying on raiseGlobalEvent loopback which may not deliver to the same profile in some Mudlet builds.",
        delay = 0.25,
        steps = {
            {
                cmd =
                'lua do local S=require("dwkit.services.remote_exec_service"); local ok,err=S.install({quiet=true}); print(string.format("[dwverify-remoteexec] install ok=%s err=%s", tostring(ok==true), tostring(err))) local st=S.status(); print(string.format("[dwverify-remoteexec] installed=%s myProfile=%s event=%s", tostring(st.installed), tostring(st.myProfile), tostring(st.globalEventName))) end',
                note = "Ensure RemoteExec installed and print basic state.",
            },
            {
                cmd =
                'lua do local O=require("dwkit.config.owned_profiles"); local p=(type(getProfileName)=="function" and getProfileName()) or "unknown-profile"; local before=O.status(); local m=(type(O.getMap)=="function" and O.getMap()) or {}; local merged={}; if type(m)=="table" then for k,v in pairs(m) do merged[k]=v end end; merged["SelfChar"]=tostring(p); local ok,err=O.setMap(merged,{noSave=true}); if ok==false then error("owned_profiles.setMap failed: "..tostring(err)) end; local after=O.status(); print(string.format("[dwverify-remoteexec] ensured SelfChar owned (merge) beforeCount=%s afterCount=%s selfProfile=%s", tostring(before and before.count), tostring(after and after.count), tostring(p))) end',
                note =
                "Ensure current profile label is treated as owned (session-only) WITHOUT clobbering an existing owned_profiles map (merge best-effort).",
            },
            {
                cmd =
                'lua do local S=require("dwkit.services.remote_exec_service"); S.clearAllowlist(); local p=(type(getProfileName)=="function" and getProfileName()) or "unknown-profile"; local wire=S._testMakeWire(tostring(p),"SEND","say hello",{source="dwverify:remoteexec"}); local ok,err=S._testInjectWire(wire); print(string.format("[dwverify-remoteexec] injected SEND ok=%s err=%s (expect REJECT send:not_allowlisted)", tostring(ok==true), tostring(err))) end',
                note =
                "Deterministic receiver simulation: inject SEND to self with empty allowlist; receiver must REJECT send:not_allowlisted.",
            },
            {
                cmd =
                'lua do local S=require("dwkit.services.remote_exec_service"); local st=S.status(); local stats=st.stats or {}; print(string.format("[dwverify-remoteexec] stats sends=%s recv=%s rejected=%s lastReject=%s", tostring(stats.sends or 0), tostring(stats.recv or 0), tostring(stats.rejected or 0), tostring(stats.lastReject or "nil"))) if tostring(stats.lastReject or "")~="send:not_allowlisted" then error("Expected lastReject=send:not_allowlisted; got "..tostring(stats.lastReject)) end; print("[dwverify-remoteexec] PASS remoteexec_smoke") end',
                note = "ASSERT: lastReject must be send:not_allowlisted (proves allowlist gate works).",
            },
            {
                cmd =
                'lua do print("[dwverify-remoteexec] OPTIONAL MANUAL: open a second Mudlet profile whose profile label is in owned_profiles values, then run: dwremoteexec ping <thatProfileLabel> and watch for PING received on the target tab.") end',
                note = "Optional real cross-profile delivery check (not required for PASS).",
            },
        },
    },

    -- SkillRegistry smoke (Objective: SkillRegistry expansion)
    skill_registry_smoke = {
        title = "skill_registry_smoke",
        description =
        "SkillRegistry smoke: assert expanded baseline, canonical kind set, alias lookup, class normalization, validateAll PASS, and seed keys exist. Also confirms dwskills prints without error.",
        delay = 0.20,
        steps = {
            {
                cmd =
                'lua do local S=require("dwkit.services.skill_registry_service"); print(string.format("[dwverify-skillreg] service version=%s", tostring(S.getVersion()))) local st=S.getStats(); print(string.format("[dwverify-skillreg] stats entries=%s updates=%s lastTs=%s", tostring(st.entries), tostring(st.updates), tostring(st.lastTs or "nil"))) end',
                note = "Load service and print version + stats.",
            },
            {
                cmd =
                'lua do local S=require("dwkit.services.skill_registry_service"); local ok,issues=S.validateAll({strictClassList=true}); print(string.format("[dwverify-skillreg] validateAll ok=%s issues=%s", tostring(ok==true), tostring(type(issues)=="table" and #issues or "nil"))) if ok~=true then for i=1,math.min(10,#issues) do local it=issues[i]; print(string.format("[dwverify-skillreg] issue[%s] key=%s err=%s", tostring(i), tostring(it.key), tostring(it.error))) end; error("validateAll expected PASS") end; print("[dwverify-skillreg] PASS validateAll") end',
                note = "ASSERT: validateAll(strictClassList=true) must PASS.",
            },
            {
                cmd =
                'lua do local S=require("dwkit.services.skill_registry_service"); local reg=S.getRegistry(); if type(reg)~="table" then error("Expected registry table") end; if type(reg["heal"])~="table" then error("Expected key heal present") end; if type(reg["power heal"])~="table" then error("Expected key power heal present") end; if type(reg["anti-paladin example"])~="table" then error("Expected key anti-paladin example present") end; local def=reg["anti-paladin example"]; if tostring(def.classKey)~="anti-paladin" then error("Expected classKey anti-paladin; got "..tostring(def.classKey)) end; print("[dwverify-skillreg] PASS seed keys + anti-paladin classKey") end',
                note = "ASSERT: required keys exist; anti-paladin is hyphen-preserved.",
            },
            {
                cmd =
                'lua do local S=require("dwkit.services.skill_registry_service"); local def=S.resolveByPracticeKey("Power   Heal"); if not def then error("Expected resolveByPracticeKey Power Heal to find entry") end; if tostring(def.practiceKey)~="power heal" then error("Expected practiceKey power heal; got "..tostring(def.practiceKey)) end; local def2=S.resolveByAlias("PHEAL"); if not def2 then error("Expected resolveByAlias PHEAL to find entry") end; if tostring(def2.practiceKey)~="power heal" then error("Expected alias to resolve to power heal; got "..tostring(def2.practiceKey)) end; print("[dwverify-skillreg] PASS resolveByPracticeKey + resolveByAlias") end',
                note = "ASSERT: practiceKey normalization and alias lookup work.",
            },
            {
                cmd =
                'lua do local S=require("dwkit.services.skill_registry_service"); local ck,err=S.normalizeClassKey("APAL"); if not ck then error("normalizeClassKey(APAL) failed: "..tostring(err)) end; if ck~="anti-paladin" then error("Expected anti-paladin; got "..tostring(ck)) end; local list=S.listByClass("anti paladin","skill"); if type(list)~="table" then error("Expected list table") end; if #list < 1 then error("Expected >=1 anti-paladin skill entry") end; print(string.format("[dwverify-skillreg] PASS class normalization + listByClass count=%s", tostring(#list))) end',
                note = "ASSERT: class normalization preserves hyphen and listByClass works.",
            },
            {
                cmd =
                'lua do local S=require("dwkit.services.skill_registry_service"); local kinds={"skill","spell","race","weapon"}; for i=1,#kinds do local k=kinds[i]; local list=S.listByKind(k); if type(list)~="table" then error("Expected listByKind("..k..") returns table") end end; local st=S.getStats(); if tonumber(st.entries or 0) < 12 then error("Expected expanded baseline entries >= 12; got "..tostring(st.entries)) end; local s=S.listByKind("spell"); local sk=S.listByKind("skill"); local r=S.listByKind("race"); local w=S.listByKind("weapon"); if #s < 3 then error("Expected >=3 spells; got "..tostring(#s)) end; if #sk < 6 then error("Expected >=6 skills; got "..tostring(#sk)) end; if #r < 1 then error("Expected >=1 race entry; got "..tostring(#r)) end; if #w < 1 then error("Expected >=1 weapon entry; got "..tostring(#w)) end; print(string.format("[dwverify-skillreg] PASS coverage spells=%s skills=%s race=%s weapon=%s", tostring(#s), tostring(#sk), tostring(#r), tostring(#w))) end',
                note = "ASSERT: minimum coverage counts per kind (starter baseline).",
            },
            { cmd = "dwskills",                 note = "Should print SkillRegistryService summary and list keys (SAFE)." },
            { cmd = "dwskills dump power heal", note = "Optional: dump one entry; should show normalized practiceKey + classKey." },
        },
    },

    -- NEW: ActionPad gating foundation smoke (Bucket B)
    actionpad_gating_smoke = {
        title = "actionpad_gating_smoke",
        description =
        "ActionPad gating foundation smoke (Bucket B): verify PracticeStore.getLearnStatus and ScoreStore.getCore behave deterministically via fixtures and clear. No gameplay sends.",
        delay = 0.25,
        steps = {
            {
                cmd =
                'lua do local P=require("dwkit.services.practice_store_service"); local ok,err=P.ingestFixture("basic",{source="dwverify:actionpad_gating:practice_fixture"}); print(string.format("[dwverify-gating] practice ingestFixture ok=%s err=%s", tostring(ok==true), tostring(err))) if ok~=true then error("practice ingestFixture failed: "..tostring(err)) end end',
                note = "PracticeStore: ingest fixture basic.",
            },
            {
                cmd =
                'lua do local P=require("dwkit.services.practice_store_service"); local st=P.getLearnStatus("spell","heal"); print(string.format("[dwverify-gating] practice heal learned=%s reason=%s tier=%s cost=%s", tostring(st.learned==true), tostring(st.reason), tostring(st.tier or "nil"), tostring(st.cost or "nil"))) if st.ok~=true then error("heal status ok~=true") end; if st.learned~=true then error("Expected heal learned=true") end; if tostring(st.reason)~="ok" then error("Expected heal reason=ok; got "..tostring(st.reason)) end end',
                note = "ASSERT: spell heal learned=true reason=ok.",
            },
            {
                cmd =
                'lua do local P=require("dwkit.services.practice_store_service"); local st=P.getLearnStatus("skill","bash"); print(string.format("[dwverify-gating] practice bash learned=%s reason=%s tier=%s", tostring(st.learned==true), tostring(st.reason), tostring(st.tier or "nil"))) if st.ok~=true then error("bash status ok~=true") end; if st.learned~=false then error("Expected bash learned=false") end; if tostring(st.reason)~="not_learned" then error("Expected bash reason=not_learned; got "..tostring(st.reason)) end end',
                note = "ASSERT: skill bash learned=false reason=not_learned.",
            },
            {
                cmd =
                'lua do local P=require("dwkit.services.practice_store_service"); local st=P.getLearnStatus("spell","power heal"); print(string.format("[dwverify-gating] practice power heal learned=%s reason=%s tier=%s cost=%s", tostring(st.learned==true), tostring(st.reason), tostring(st.tier or "nil"), tostring(st.cost or "nil"))) if st.ok~=true then error("power heal status ok~=true") end; if st.learned~=false then error("Expected power heal learned=false") end; if tostring(st.reason)~="not_learned" then error("Expected power heal reason=not_learned; got "..tostring(st.reason)) end end',
                note = "ASSERT: spell power heal learned=false reason=not_learned.",
            },
            {
                cmd =
                'lua do local P=require("dwkit.services.practice_store_service"); local ok,err=P.clear({source="dwverify:actionpad_gating:practice_clear"}); if ok==false then error("practice clear failed: "..tostring(err)) end; local st=P.getLearnStatus("spell","heal"); print(string.format("[dwverify-gating] practice after clear reason=%s hasSnapshot=%s hasParsed=%s", tostring(st.reason), tostring(st.hasSnapshot), tostring(st.hasParsed))) if tostring(st.reason)~="unknown_stale" then error("Expected unknown_stale after clear; got "..tostring(st.reason)) end end',
                note = "ASSERT: after PracticeStore.clear, learn status returns unknown_stale.",
            },
            {
                cmd =
                'lua do local S=require("dwkit.services.score_store_service"); local ok,err=S.ingestFixture("score_table_short",{source="dwverify:actionpad_gating:score_fixture"}); print(string.format("[dwverify-gating] score ingestFixture ok=%s err=%s", tostring(ok==true), tostring(err))) if ok~=true then error("score ingestFixture failed: "..tostring(err)) end; local core=S.getCore(); print(string.format("[dwverify-gating] score core reason=%s name=%s class=%s level=%s variant=%s", tostring(core.reason), tostring(core.name or "nil"), tostring(core.class or "nil"), tostring(core.level or "nil"), tostring(core.variant or "nil"))) if core.ok~=true then error("score core ok~=true") end; if tostring(core.reason)~="ok" then error("Expected score core reason=ok; got "..tostring(core.reason)) end; if tonumber(core.level or 0)~=48 then error("Expected level=48; got "..tostring(core.level)) end; if tostring(core.class or "")~="Warrior" then error("Expected class=Warrior; got "..tostring(core.class)) end; if tostring(core.name or "")~="Vzae" then error("Expected name=Vzae; got "..tostring(core.name)) end end',
                note = "ASSERT: ScoreStore fixture parses core name/class/level and reason=ok.",
            },
            {
                cmd =
                'lua do local S=require("dwkit.services.score_store_service"); local ok,err=S.clear({source="dwverify:actionpad_gating:score_clear"}); if ok==false then error("score clear failed: "..tostring(err)) end; local core=S.getCore(); print(string.format("[dwverify-gating] score after clear reason=%s hasSnapshot=%s hasParsed=%s", tostring(core.reason), tostring(core.hasSnapshot), tostring(core.hasParsed))) if tostring(core.reason)~="unknown_stale" then error("Expected score unknown_stale after clear; got "..tostring(core.reason)) end; print("[dwverify-gating] PASS actionpad_gating_smoke") end',
                note = "ASSERT: after ScoreStore.clear, core returns unknown_stale.",
            },
        },
    },

    -- NEW: ActionPad gating UI smoke (Bucket B implementation)
    actionpad_gating_ui_smoke = {
        title = "actionpad_gating_ui_smoke",
        description =
        "ActionPad gating UI smoke (Bucket B): deterministic seed (owned_profiles + Presence + ActionPadService rows), ingest Practice+Score fixtures, show ActionPad UI, then ASSERT ActionPadService.resolveActionGate returns expected reason codes: ok/not_learned/unknown_stale.practice/unknown_stale.score/below_level/wrong_class. No gameplay sends.",
        delay = 0.25,
        steps = {
            {
                cmd =
                'lua do local O=require("dwkit.config.owned_profiles"); local ok,err=O.setMap({["Alpha"]="Profile-A",["Beta"]="Profile-B",["Healer"]="Profile-Heal"},{noSave=true}); if ok==false then error("owned_profiles.setMap failed: "..tostring(err)) end; local st=O.status(); print(string.format("[dwverify-actionpad-gui] seeded owned_profiles count=%s", tostring(st.count))) end',
                note = "Seed deterministic owned_profiles (session-only).",
            },
            {
                cmd =
                'lua do local P=require("dwkit.services.presence_service"); local ok,err=P.setState({myProfilesOnline={"Alpha (Profile-A) [ONLINE] [HERE]","Beta (Profile-B) [ONLINE]","Healer (Profile-Heal) [ONLINE]"},myProfilesOffline={},myProfilesHere={"Alpha (Profile-A) [ONLINE] [HERE]"},otherPlayersInRoom={"OtherGuy"},mapping={count=3},roomTs=os.time(),whoTs=os.time()},{source="dwverify:actionpad_gating_ui:seed_presence"}); if ok==false then error("PresenceService.setState failed: "..tostring(err)) end; print("[dwverify-actionpad-gui] seeded PresenceService roster (Healer ONLINE for stub gate)") end',
                note =
                "Seed PresenceService roster with Healer ONLINE so service buttons can pass healer stub gate when learned/known.",
            },
            {
                cmd =
                'lua do local A=require("dwkit.services.actionpad_service"); local ok,err=A.recompute({source="dwverify:actionpad_gating_ui:recompute"}); if ok==false then error("ActionPadService.recompute failed: "..tostring(err)) end; local rows=A.getRowsOnlineOnly(); print(string.format("[dwverify-actionpad-gui] ActionPadService rowsOnline count=%s (expect 3)", tostring(#rows))) if #rows~=3 then error("Expected ActionPadService rowsOnline=3; got "..tostring(#rows)) end end',
                note = "Recompute ActionPadService; ASSERT online-only rows count=3 (Alpha/Beta/Healer).",
            },
            {
                cmd =
                'lua do local P=require("dwkit.services.practice_store_service"); local ok,err=P.ingestFixture("basic",{source="dwverify:actionpad_gating_ui:practice_fixture"}); print(string.format("[dwverify-actionpad-gui] practice ingestFixture ok=%s err=%s", tostring(ok==true), tostring(err))) if ok~=true then error("practice ingestFixture failed: "..tostring(err)) end end',
                note = "PracticeStore fixture ingest (learned vs not learned).",
            },
            {
                cmd =
                'lua do local S=require("dwkit.services.score_store_service"); local ok,err=S.ingestFixture("score_table_short",{source="dwverify:actionpad_gating_ui:score_fixture"}); print(string.format("[dwverify-actionpad-gui] score ingestFixture ok=%s err=%s", tostring(ok==true), tostring(err))) if ok~=true then error("score ingestFixture failed: "..tostring(err)) end; local core=S.getCore(); print(string.format("[dwverify-actionpad-gui] score core reason=%s class=%s level=%s", tostring(core.reason), tostring(core.class or "nil"), tostring(core.level or "nil"))) if core.ok~=true then error("score core ok~=true") end end',
                note = "ScoreStore fixture ingest (Warrior level 48).",
            },
            {
                cmd =
                'lua do local gs=require("dwkit.config.gui_settings"); gs.enableVisiblePersistence({noSave=true}); gs.setEnabled("actionpad_ui", true, {noSave=true}); gs.setVisible("actionpad_ui", true, {noSave=true}); local UI=require("dwkit.ui.actionpad_ui"); local ok,err=UI.apply({source="dwverify:actionpad_gating_ui_smoke:show"}); if ok==false then error("actionpad_ui.apply failed: "..tostring(err)) end; local s=UI.getState(); local lr=s.lastRender or {}; print(string.format("[dwverify-actionpad-gui] SHOW visible=%s enabled=%s runtimeVisible=%s rows=%s lastErr=%s", tostring(s.visible), tostring(s.enabled), tostring(s.runtimeVisible), tostring(lr.rowsCount or "nil"), tostring(s.lastError))) end',
                note = "Show ActionPad UI (console-first).",
            },

            -- FIXED: ok path uses honorSpec=true to avoid registry classKey constraints (verification-only).
            {
                cmd =
                'lua do local A=require("dwkit.services.actionpad_service"); local g=A.resolveActionGate({kind="spell",practiceKey="heal",displayName="Heal",classKey="",minLevel=1},{honorSpec=true}); print(string.format("[dwverify-actionpad-gui] gate heal(ok via honorSpec) enabled=%s reason=%s detail=%s", tostring(g.enabled==true), tostring(g.reason), tostring(g.detail))) if g.enabled~=true then error("Expected heal enabled=true; got reason="..tostring(g.reason)) end; if tostring(g.reason)~="ok" then error("Expected heal reason=ok; got "..tostring(g.reason)) end end',
                note = "ASSERT: ok (verification-only override; UI default still respects registry constraints).",
            },

            {
                cmd =
                'lua do local A=require("dwkit.services.actionpad_service"); local g=A.resolveActionGate({kind="spell",practiceKey="power heal",displayName="Power Heal"}); print(string.format("[dwverify-actionpad-gui] gate power heal enabled=%s reason=%s detail=%s", tostring(g.enabled==true), tostring(g.reason), tostring(g.detail))) if g.enabled~=false then error("Expected power heal enabled=false") end; if tostring(g.reason)~="not_learned" then error("Expected power heal reason=not_learned; got "..tostring(g.reason)) end end',
                note = "ASSERT: not_learned (power heal is not learned in fixture).",
            },
            {
                cmd =
                'lua do local A=require("dwkit.services.actionpad_service"); local g=A.resolveActionGate({kind="spell",practiceKey="heal",displayName="Heal",classKey="",minLevel=60},{honorSpec=true}); print(string.format("[dwverify-actionpad-gui] gate below_level enabled=%s reason=%s detail=%s", tostring(g.enabled==true), tostring(g.reason), tostring(g.detail))) if g.enabled~=false then error("Expected below_level enabled=false") end; if tostring(g.reason)~="below_level" then error("Expected below_level reason=below_level; got "..tostring(g.reason)) end end',
                note = "ASSERT: below_level via explicit minLevel=60 (score fixture level=48), using a learned ability.",
            },
            {
                cmd =
                'lua do local A=require("dwkit.services.actionpad_service"); local g=A.resolveActionGate({kind="spell",practiceKey="heal",displayName="Heal",classKey="cleric"}); print(string.format("[dwverify-actionpad-gui] gate wrong_class enabled=%s reason=%s detail=%s", tostring(g.enabled==true), tostring(g.reason), tostring(g.detail))) if g.enabled~=false then error("Expected wrong_class enabled=false") end; if tostring(g.reason)~="wrong_class" then error("Expected wrong_class reason=wrong_class; got "..tostring(g.reason)) end end',
                note = "ASSERT: wrong_class (score class is Warrior; spec wants cleric).",
            },
            {
                cmd =
                'lua do local P=require("dwkit.services.practice_store_service"); local ok,err=P.clear({source="dwverify:actionpad_gating_ui:practice_clear"}); if ok==false then error("practice clear failed: "..tostring(err)) end; local A=require("dwkit.services.actionpad_service"); local g=A.resolveActionGate({kind="spell",practiceKey="heal",displayName="Heal"}); print(string.format("[dwverify-actionpad-gui] gate practice stale enabled=%s reason=%s detail=%s", tostring(g.enabled==true), tostring(g.reason), tostring(g.detail))) if g.enabled~=false then error("Expected practice stale enabled=false") end; if tostring(g.reason)~="unknown_stale.practice" then error("Expected unknown_stale.practice; got "..tostring(g.reason)) end end',
                note = "ASSERT: unknown_stale.practice after PracticeStore.clear.",
            },
            {
                cmd =
                'lua do local P=require("dwkit.services.practice_store_service"); local ok,err=P.ingestFixture("basic",{source="dwverify:actionpad_gating_ui:practice_fixture2"}); if ok~=true then error("practice ingestFixture failed: "..tostring(err)) end; local S=require("dwkit.services.score_store_service"); local ok2,err2=S.clear({source="dwverify:actionpad_gating_ui:score_clear"}); if ok2==false then error("score clear failed: "..tostring(err2)) end; local A=require("dwkit.services.actionpad_service"); local g=A.resolveActionGate({kind="spell",practiceKey="heal",displayName="Heal",minLevel=1,classKey="warrior"}); print(string.format("[dwverify-actionpad-gui] gate score stale enabled=%s reason=%s detail=%s", tostring(g.enabled==true), tostring(g.reason), tostring(g.detail))) if g.enabled~=false then error("Expected score stale enabled=false") end; if tostring(g.reason)~="unknown_stale.score" then error("Expected unknown_stale.score; got "..tostring(g.reason)) end; print("[dwverify-actionpad-gui] PASS actionpad_gating_ui_smoke (service gate assertions)") end',
                note = "ASSERT: unknown_stale.score after ScoreStore.clear (with minLevel/classKey forcing scoreNeeded).",
            },
            {
                cmd =
                'lua do local gs=require("dwkit.config.gui_settings"); gs.enableVisiblePersistence({noSave=true}); gs.setEnabled("actionpad_ui", true, {noSave=true}); gs.setVisible("actionpad_ui", false, {noSave=true}); local UI=require("dwkit.ui.actionpad_ui"); local ok,err=UI.apply({source="dwverify:actionpad_gating_ui_smoke:hide"}); if ok==false then error("actionpad_ui.apply(hide) failed: "..tostring(err)) end; local s=UI.getState(); print(string.format("[dwverify-actionpad-gui] HIDE visible=%s enabled=%s runtimeVisible=%s lastErr=%s", tostring(s.visible), tostring(s.enabled), tostring(s.runtimeVisible), tostring(s.lastError))) end',
                note = "Hide ActionPad UI via gui_settings + apply() and print state.",
            },
            {
                cmd =
                'lua do print("[dwverify-actionpad-gui] VISUAL CHECK: Hover buttons to see tooltip reason/detail. Click a DISABLED button and confirm it prints: [ActionPad] DISABLED (...) reason=<...> detail=<...>.") end',
                note = "Human UI surface check (disabled reasons must be visible).",
            },
        },
    },

    -- NEW: ActionPadService smoke (Objective: ActionPadService MVP)
    actionpad_service_smoke = {
        title = "actionpad_service_smoke",
        description =
        "ActionPadService smoke: seed owned_profiles + seed PresenceService roster deterministically, then recompute ActionPadService and assert online-only rows. Also validates planning helpers (PLAN ONLY, no sends).",
        delay = 0.25,
        steps = {
            {
                cmd =
                'lua do local O=require("dwkit.config.owned_profiles"); local ok,err=O.setMap({["Alpha"]="Profile-A",["Beta"]="Profile-B",["Healer"]="Profile-Heal"},{noSave=true}); if ok==false then error("owned_profiles.setMap failed: "..tostring(err)) end; local st=O.status(); print(string.format("[dwverify-actionpad] seeded owned_profiles count=%s", tostring(st.count))) end',
                note = "Seed deterministic owned_profiles (session-only).",
            },
            {
                cmd =
                'lua do local P=require("dwkit.services.presence_service"); local ok,err=P.setState({myProfilesOnline={"Alpha (Profile-A) [ONLINE] [HERE]","Beta (Profile-B) [ONLINE]"},myProfilesOffline={"Healer (Profile-Heal) [OFFLINE]"},myProfilesHere={"Alpha (Profile-A) [ONLINE] [HERE]"},otherPlayersInRoom={"OtherGuy"},mapping={count=3},roomTs=os.time(),whoTs=os.time()},{source="dwverify:actionpad:seed_presence"}); if ok==false then error("PresenceService.setState failed: "..tostring(err)) end; print("[dwverify-actionpad] seeded PresenceService roster") end',
                note = "Seed PresenceService roster (deterministic, SAFE).",
            },
            {
                cmd =
                'lua do local A=require("dwkit.services.actionpad_service"); local ok,err=A.recompute({source="dwverify:actionpad:recompute"}); if ok==false then error("ActionPadService.recompute failed: "..tostring(err)) end; local rows=A.getRowsOnlineOnly(); print(string.format("[dwverify-actionpad] rowsOnline count=%s", tostring(#rows))) local function has(n,label,here) for i=1,#rows do local r=rows[i]; if tostring(r.name)==n and tostring(r.profileLabel)==label then if here==nil then return true end; return (r.here==here) end end return false end; if has("Alpha","Profile-A",true)~=true then error("Expected Alpha online here") end; if has("Beta","Profile-B",false)~=true then error("Expected Beta online") end; print("[dwverify-actionpad] PASS online-only rows derived") end',
                note = "Recompute ActionPadService and assert expected online-only rows.",
            },
            {
                cmd =
                'lua do local A=require("dwkit.services.actionpad_service"); local plan,err=A.planSelfExec("Alpha","say hi",{source="dwverify:actionpad:plan"}); if not plan then error("planSelfExec failed: "..tostring(err)) end; print(string.format("[dwverify-actionpad] planSelfExec target=%s cmd=%s", tostring(plan.targetProfile), tostring(plan.cmd))) local plan2,err2=A.planAssistExec("Healer","Alpha","cast heal {target}",{source="dwverify:actionpad:plan2"}); if not plan2 then error("planAssistExec failed: "..tostring(err2)) end; print(string.format("[dwverify-actionpad] planAssistExec target=%s cmd=%s", tostring(plan2.targetProfile), tostring(plan2.cmd))) print("[dwverify-actionpad] NOTE: plans are PLAN ONLY (no send).") end',
                note = "Planning helpers only (no send).",
            },
        },
    },

    -- NEW: ActionPad UI smoke (Objective: ActionPad UI MVP)
    actionpad_ui_smoke = {
        title = "actionpad_ui_smoke",
        description =
        "ActionPad UI smoke: deterministic seed (owned_profiles + PresenceService + ActionPadService.recompute), then enable+show actionpad_ui via gui_settings and apply(); print state; then hide via gui_settings and apply() again. Console-first (no screenshots). Buttons remain PLAN-only (no sends).",
        delay = 0.25,
        steps = {
            {
                cmd =
                'lua do local O=require("dwkit.config.owned_profiles"); local ok,err=O.setMap({["Alpha"]="Profile-A",["Beta"]="Profile-B",["Healer"]="Profile-Heal"},{noSave=true}); if ok==false then error("owned_profiles.setMap failed: "..tostring(err)) end; local st=O.status(); print(string.format("[dwverify-actionpad-ui] seeded owned_profiles count=%s", tostring(st.count))) end',
                note = "Seed deterministic owned_profiles (session-only).",
            },
            {
                cmd =
                'lua do local P=require("dwkit.services.presence_service"); local ok,err=P.setState({myProfilesOnline={"Alpha (Profile-A) [ONLINE] [HERE]","Beta (Profile-B) [ONLINE]"},myProfilesOffline={"Healer (Profile-Heal) [OFFLINE]"},myProfilesHere={"Alpha (Profile-A) [ONLINE] [HERE]"},otherPlayersInRoom={"OtherGuy"},mapping={count=3},roomTs=os.time(),whoTs=os.time()},{source="dwverify:actionpad_ui:seed_presence"}); if ok==false then error("PresenceService.setState failed: "..tostring(err)) end; print("[dwverify-actionpad-ui] seeded PresenceService roster") end',
                note = "Seed PresenceService roster (deterministic, SAFE).",
            },
            {
                cmd =
                'lua do local A=require("dwkit.services.actionpad_service"); local ok,err=A.recompute({source="dwverify:actionpad_ui:recompute"}); if ok==false then error("ActionPadService.recompute failed: "..tostring(err)) end; local rows=A.getRowsOnlineOnly(); print(string.format("[dwverify-actionpad-ui] ActionPadService rowsOnline count=%s (expect 2)", tostring(#rows))) if #rows~=2 then error("Expected ActionPadService rowsOnline=2; got "..tostring(#rows)) end end',
                note = "Recompute ActionPadService; ASSERT online-only rows count=2.",
            },
            {
                cmd =
                'lua do local gs=require("dwkit.config.gui_settings"); gs.enableVisiblePersistence({noSave=true}); gs.setEnabled("actionpad_ui", true, {noSave=true}); gs.setVisible("actionpad_ui", true, {noSave=true}); local UI=require("dwkit.ui.actionpad_ui"); local ok,err=UI.apply({source="dwverify:actionpad_ui_smoke:show"}); if ok==false then error("actionpad_ui.apply failed: "..tostring(err)) end; local s=UI.getState(); local lr=s.lastRender or {}; print(string.format("[dwverify-actionpad-ui] SHOW visible=%s enabled=%s runtimeVisible=%s rows=%s lastErr=%s", tostring(s.visible), tostring(s.enabled), tostring(s.runtimeVisible), tostring(lr.rowsCount or lr.rowCount or "nil"), tostring(s.lastError))) end',
                note = "Enable+show ActionPad UI and print state (console-first).",
            },
            {
                cmd =
                'lua do local gs=require("dwkit.config.gui_settings"); gs.enableVisiblePersistence({noSave=true}); gs.setEnabled("actionpad_ui", true, {noSave=true}); gs.setVisible("actionpad_ui", false, {noSave=true}); local UI=require("dwkit.ui.actionpad_ui"); local ok,err=UI.apply({source="dwverify:actionpad_ui_smoke:hide"}); if ok==false then error("actionpad_ui.apply(hide) failed: "..tostring(err)) end; local s=UI.getState(); print(string.format("[dwverify-actionpad-ui] HIDE visible=%s enabled=%s runtimeVisible=%s lastErr=%s", tostring(s.visible), tostring(s.enabled), tostring(s.runtimeVisible), tostring(s.lastError))) end',
                note = "Hide ActionPad UI via gui_settings + apply() and print state.",
            },
            {
                cmd =
                'lua do print("[dwverify-actionpad-ui] VISUAL CHECK: ActionPad window appears, shows Alpha/Beta rows, and buttons are PLAN-only (no sends).") end',
                note = "Human visual PASS/FAIL gate.",
            },
        },
    },

    new_profile_prereq = {
        title = "new_profile_prereq",
        description =
        "New profile prereq: loader.init should load dwwho module (watcher autostart), so manual 'who' populates WhoStore without needing 'dwwho watch on'.",
        delay = 0.45,
        steps = {
            {
                cmd =
                'lua do package.loaded["dwkit.loader.init"]=nil; local L=require("dwkit.loader.init"); local kit=L.init(); print(string.format("[dwverify-prereq] init OK bootReadyEmitted=%s dwwhoLoadErr=%s cpcLoadErr=%s cpcInstallErr=%s", tostring(kit and kit._bootReadyEmitted), tostring(kit and kit._dwwhoLoadError), tostring(kit and kit._crossProfileCommServiceLoadError), tostring(kit and kit._crossProfileCommServiceInstallError))) end',
                note =
                "Init DWKit (single-line). Expect dwwhoLoadErr=nil; CPC load/install errors should be nil on a healthy install.",
            },
            { cmd = "dwwho watch status", note = "Expect enabled=true without running dwwho watch on." },
            { cmd = "who",                delay = 0.90,                                                note = "Manual WHO should be captured as dwwho:auto (watcher default-on)." },
            {
                cmd =
                'lua do local S=require("dwkit.services.whostore_service"); local st=S.getState(); if st.lastUpdatedTs==nil then error("Expected WhoStore lastUpdatedTs after manual who") end; if tostring(st.source)~="dwwho:auto" then error("Expected WhoStore source dwwho:auto after manual who; got "..tostring(st.source)) end; print(string.format("[dwverify-prereq] PASS WhoStore source=%s lastUpdatedTs=%s autoCaptureEnabled=%s", tostring(st.source), tostring(st.lastUpdatedTs), tostring(st.autoCaptureEnabled))) end',
                note = "ASSERT: manual who ingested as dwwho:auto.",
            },
        },
    },

    presence_live_inputs = {
        title = "presence_live_inputs",
        description =
        "Live inputs sanity (SAFE): print owned_profiles status, CPC status, RoomEntities V2 counts, and Presence derived lists. Use this on BOTH tabs when live room behavior looks wrong.",
        delay = 0.25,
        steps = {
            {
                cmd =
                'lua do local O=require("dwkit.config.owned_profiles"); local st=O.status(); print(string.format("[dwverify-live] owned_profiles loaded=%s count=%s relPath=%s lastErr=%s", tostring(st.loaded), tostring(st.count), tostring(st.relPath), tostring(st.lastError))) local m=O.getMap(); local n=0; for k,v in pairs(m) do n=n+1; print(string.format("[dwverify-live] owned %s -> %s", tostring(k), tostring(v))) end; if n==0 then print("[dwverify-live] owned_profiles map EMPTY") end end',
                note = "Owned profiles mapping (authoritative).",
            },
            {
                cmd =
                'lua do local C=require("dwkit.services.cross_profile_comm_service"); local st=C.status(); print(string.format("[dwverify-live] cpc installed=%s myProfile=%s instanceId=%s peerCount=%s", tostring(st.installed), tostring(st.myProfile), tostring(st.instanceId), tostring(st.peerCount))) if type(st.peers)=="table" then for k,p in pairs(st.peers) do print(string.format("[dwverify-live] cpc peer key=%s profile=%s instanceId=%s lastSeen=%s", tostring(k), tostring(p.profile), tostring(p.instanceId), tostring(p.lastSeenTs or "nil"))) end end end',
                note = "CPC local-online truth (same Mudlet instance).",
            },
            {
                cmd =
                'lua do local R=require("dwkit.services.roomentities_service"); local v=R.getSnapshotV2 and R.getSnapshotV2() or {}; local function cnt(t) local n=0; if type(t)=="table" then for _ in pairs(t) do n=n+1 end end; return n end; print(string.format("[dwverify-live] roomentities_v2 players=%s unknown=%s", tostring(cnt(v.players)), tostring(cnt(v.unknown)))) end',
                note = "RoomEntities V2 snapshot counts (Presence uses these via bridge).",
            },
            {
                cmd =
                'lua do local P=require("dwkit.services.presence_service"); local s=P.getState(); local function dump(tag,t) if type(t)~="table" then print(tag.."=nil") return end; print(tag..".count="..tostring(#t)); for i=1,#t do print(tag.."["..i.."]="..tostring(t[i])) end end; print(string.format("[dwverify-live] presence roomTs=%s whoTs=%s mappingCount=%s", tostring(s.roomTs or "nil"), tostring(s.whoTs or "nil"), tostring(s.mapping and s.mapping.count or "nil"))) dump("[dwverify-live] myProfilesOnline", s.myProfilesOnline or {}); dump("[dwverify-live] myProfilesOffline", s.myProfilesOffline or {}); dump("[dwverify-live] otherPlayersInRoom", s.otherPlayersInRoom or {}) end',
                note = "Presence derived lists (what UI should show).",
            },
        },
    },

    presence_ui_populates = {
        title = "presence_ui_populates",
        description =
        "Presence_UI: RoomEntities -> PresenceService bridge. Seed owned profiles mapping, seed WhoStore names deterministically, ingest deterministic snapshot via roomfeed_capture._testIngestSnapshot (SAFE; no sends), then show Presence_UI and assert split (My profiles vs Other players).",
        delay = 0.30,
        steps = {
            {
                cmd =
                'lua do local O=require("dwkit.config.owned_profiles"); local ok,err=O.setMap({["FixturePlayer"]="Ancient-Dev"},{noSave=true}); if ok==false then error("owned_profiles.setMap failed: "..tostring(err)) end; local st=O.status(); print(string.format("[dwverify-presence] seeded owned_profiles count=%s", tostring(st.count))) end',
                note = "Seed deterministic mapping (session-only): FixturePlayer -> Ancient-Dev.",
            },
            {
                cmd =
                'lua do local W=require("dwkit.services.whostore_service"); local ok1,err1=W.clear({source="dwverify:presence:whoclear"}); if ok1==false then error("WhoStore.clear failed: "..tostring(err1)) end; local ok2,err2=W.setState({players={FixturePlayer=true,OtherGuy=true}},{source="dwverify:presence:whoseed"}); if ok2==false then error("WhoStore.setState failed: "..tostring(err2)) end; local names=W.getAllNames(); print(string.format("[dwverify-presence] seeded WhoStore names=%s count=%s", tostring(table.concat(names,",")), tostring(#names))) end',
                note =
                "Seed WhoStore deterministically with BOTH names (authoritative snapshot): FixturePlayer + OtherGuy (SAFE; no gameplay sends).",
            },
            {
                cmd =
                'lua do local P=require("dwkit.services.presence_service"); local ok,err=P.clear({source="dwverify:presence:clear"}); if ok==false then error("PresenceService.clear failed: "..tostring(err)) end; print("[dwverify-presence] cleared PresenceService") end',
                note = "Clear Presence state to known baseline.",
            },
            {
                cmd =
                'lua do local R=require("dwkit.services.roomentities_service"); local ok,err=R.clear({source="dwverify:presence:roomclear",forceEmit=true}); if ok==false then error("RoomEntities.clear failed: "..tostring(err)) end; print("[dwverify-presence] cleared RoomEntities") end',
                note = "Clear RoomEntities state so we can deterministically ingest a snapshot.",
            },
            {
                cmd =
                'lua do local C=require("dwkit.capture.roomfeed_capture"); local ok,err=C._testIngestSnapshot({"The Board Room (#1204) [ INDOORS IMMROOM ]","FixturePlayer is here.","OtherGuy is standing here.","Obvious exits:","North - The Voting Booth"},{hasExits=true,startKind="strong"}); if ok==false then error("roomfeed _testIngestSnapshot failed: "..tostring(err)) end; print("[dwverify-presence] ingested deterministic snapshot via roomfeed_capture") end',
                note = "Ingest deterministic snapshot (SAFE; no sends). Presence consumes V2 unknown too.",
            },
            {
                cmd =
                'lua do local P=require("dwkit.services.presence_service"); local st=P.getState(); local my=st.myProfilesInRoom or {}; local ot=st.otherPlayersInRoom or {}; if type(my)~="table" or type(ot)~="table" then error("Expected myProfilesInRoom/otherPlayersInRoom tables") end; local hasMy=false; for i=1,#my do if tostring(my[i])=="FixturePlayer (Ancient-Dev)" then hasMy=true end end; local hasOther=false; for i=1,#ot do if tostring(ot[i])=="OtherGuy" then hasOther=true end end; if hasMy~=true then error("Expected FixturePlayer in My profiles as FixturePlayer (Ancient-Dev)") end; if hasOther~=true then error("Expected OtherGuy in Other players") end; print(string.format("[dwverify-presence] PASS presence split my=%s other=%s", tostring(#my), tostring(#ot))) end',
                note = "ASSERT: PresenceService computed split deterministically.",
            },
            {
                cmd =
                'lua do local gs=require("dwkit.config.gui_settings"); gs.enableVisiblePersistence({noSave=true}); gs.setEnabled("presence_ui", true, {noSave=true}); gs.setVisible("presence_ui", true, {noSave=true}); local UI=require("dwkit.ui.presence_ui"); local ok,err=UI.apply({source="dwverify:presence_ui_populates"}); if ok==false then error("presence_ui.apply failed: "..tostring(err)) end; local s=UI.getState(); local lr=s.lastRender or {}; print(string.format("[dwverify-presence] presence_ui visible=%s enabled=%s rows=%s my=%s myOnline=%s myOffline=%s other=%s", tostring(s.visible), tostring(s.enabled), tostring(lr.rowCount), tostring(lr.myCount), tostring(lr.myOnlineCount), tostring(lr.myOfflineCount), tostring(lr.otherCount))) end',
                note = "Show Presence_UI and print state.",
            },
            {
                cmd =
                'lua do print("[dwverify-presence] VISUAL CHECK: Presence UI is row-based, DWKit dark body background, and NO grey slab.") end',
                note = "Human visual PASS/FAIL gate.",
            },
        },
    },

    presence_ui_roster = {
        title = "presence_ui_roster",
        description =
        "Presence_UI roster: owned_profiles defines roster; CPC local online defines ONLINE for same-instance profiles; WhoStore remains secondary. RoomEntities occupants define HERE + Other players (Presence consumes V2 unknown too). Includes regression: titled player labels + object labels; Presence must match owned by candidate token and must ignore objects in Other players.",
        delay = 0.30,
        steps = {
            {
                cmd =
                'lua do local O=require("dwkit.config.owned_profiles"); local ok,err=O.setMap({["Alpha"]="Profile-A",["Beta"]="Profile-B"},{noSave=true}); if ok==false then error("owned_profiles.setMap failed: "..tostring(err)) end; local st=O.status(); print(string.format("[dwverify-roster] seeded owned_profiles count=%s", tostring(st.count))) end',
                note = "Seed owned roster Alpha + Beta (labels should match Mudlet profile names for CPC local online).",
            },
            {
                cmd =
                'lua do local C=require("dwkit.services.cross_profile_comm_service"); C._testClearPeers(); local ok,err=C._testNotePeer("Profile-B",{instanceId="TEST-1"}); if ok==false then error("CPC testNotePeer failed: "..tostring(err)) end; print("[dwverify-roster] injected CPC peer Profile-B as online (session-only)") end',
                note = "Deterministic CPC injection: treat Profile-B as locally online.",
            },
            {
                cmd =
                'lua do local W=require("dwkit.services.whostore_service"); W.clear({source="dwverify:roster:whoclear"}); local ok,err=W.setState({players={Alpha=true}},{source="dwverify:roster:whoAlpha"}); if ok==false then error("WhoStore.setState failed: "..tostring(err)) end; local names=W.getAllNames(); print(string.format("[dwverify-roster] WhoStore online=%s", tostring(table.concat(names,",")))) end',
                note = "Seed WhoStore so only Alpha is online (secondary signal).",
            },
            {
                cmd =
                'lua do local P=require("dwkit.services.presence_service"); P.clear({source="dwverify:roster:presenceclear"}); local R=require("dwkit.services.roomentities_service"); R.clear({source="dwverify:roster:roomclear",forceEmit=true}); local C=require("dwkit.capture.roomfeed_capture"); local ok,err=C._testIngestSnapshot({"Some Room (#1) [ INDOORS ]","Alpha is here.","Beta the adventurer is standing here.","A large keg of Killians Irish Red is here.","OtherGuy is standing here.","Obvious exits:","North - Somewhere"},{hasExits=true,startKind="strong"}); if ok==false then error("roomfeed _testIngestSnapshot failed: "..tostring(err)) end; print("[dwverify-roster] ingested room snapshot with Alpha + Beta(titled) + OtherGuy + object") end',
                note =
                "Room snapshot: Beta appears with title; object line present; Presence must match Beta by token and ignore object in Other players.",
            },
            {
                cmd =
                'lua do local P=require("dwkit.services.presence_service"); local st=P.getState(); local on=st.myProfilesOnline or {}; local off=st.myProfilesOffline or {}; local ot=st.otherPlayersInRoom or {}; local function has(arr, needle) for i=1,#arr do if tostring(arr[i])==needle then return true end end return false end; if has(on,"Alpha (Profile-A) [ONLINE] [HERE]")~=true then error("Expected Alpha online+here tagged; got online="..tostring(table.concat(on," | "))) end; if has(on,"Beta (Profile-B) [ONLINE] [HERE]")~=true then error("Expected Beta ONLINE+HERE via CPC + titled room label; got online="..tostring(table.concat(on," | "))) end; local hasOther=false; for i=1,#ot do if tostring(ot[i])=="OtherGuy" then hasOther=true end end; if hasOther~=true then error("Expected OtherGuy in otherPlayersInRoom; got other="..tostring(table.concat(ot," | "))) end; local bad=false; for i=1,#ot do local v=tostring(ot[i] or ""); if v:lower():find("keg",1,true) then bad=true end end; if bad==true then error("Expected object to be filtered from otherPlayersInRoom; got other="..tostring(table.concat(ot," | "))) end; print(string.format("[dwverify-roster] PASS online=%s offline=%s other=%s", tostring(#on), tostring(#off), tostring(#ot))) end',
                note =
                "ASSERT: Alpha/Beta recognized as owned (Beta via candidate token); OtherGuy appears; object filtered.",
            },
            {
                cmd =
                'lua do local gs=require("dwkit.config.gui_settings"); gs.enableVisiblePersistence({noSave=true}); gs.setEnabled("presence_ui", true, {noSave=true}); gs.setVisible("presence_ui", true, {noSave=true}); local UI=require("dwkit.ui.presence_ui"); local ok,err=UI.apply({source="dwverify:presence_ui_roster"}); if ok==false then error("presence_ui.apply failed: "..tostring(err)) end; local s=UI.getState(); local lr=s.lastRender or {}; print(string.format("[dwverify-roster] presence_ui rows=%s my=%s myOnline=%s myOffline=%s other=%s", tostring(lr.rowCount), tostring(lr.myCount), tostring(lr.myOnlineCount), tostring(lr.myOfflineCount), tostring(lr.otherCount))) end',
                note = "Show Presence UI and print counts (online/offline roster visible).",
            },
        },
    },

    roomentities_whostore_gate = {
        title = "roomentities_whostore_gate",
        description =
        "RoomEntities WhoStore gate regression: seed WhoStore as players set-map, ingest titled room lines via roomfeed_capture._testIngestSnapshot (SAFE; no sends), and assert titled labels promote to players (not stuck in unknown).",
        delay = 0.30,
        steps = {
            {
                cmd =
                'lua do local W=require("dwkit.services.whostore_service"); local ok1,err1=W.clear({source="dwverify:roomentities:whoclear"}); if ok1==false then error("WhoStore.clear failed: "..tostring(err1)) end; local ok2,err2=W.setState({players={Alpha=true,Beta=true}},{source="dwverify:roomentities:whoseed_players_set"}); if ok2==false then error("WhoStore.setState failed: "..tostring(err2)) end; local names=W.getAllNames(); print(string.format("[dwverify-roomentities] seeded WhoStore players-set names=%s count=%s", tostring(table.concat(names,",")), tostring(#names))) end',
                note =
                "Seed WhoStore using players set-map shape (this is the path that previously could not produce 'exact').",
            },
            {
                cmd =
                'lua do local R=require("dwkit.services.roomentities_service"); local ok,err=R.clear({source="dwverify:roomentities:clear",forceEmit=true}); if ok==false then error("RoomEntities.clear failed: "..tostring(err)) end; print("[dwverify-roomentities] cleared RoomEntities") end',
                note = "Clear RoomEntities to a known baseline.",
            },
            {
                cmd =
                'lua do local C=require("dwkit.capture.roomfeed_capture"); local ok,err=C._testIngestSnapshot({"Some Room (#1) [ INDOORS ]","Alpha the adventurer is standing here.","Beta is standing here.","A small bulletin board designed for Quests is here.","Obvious exits:","North - Somewhere"},{hasExits=true,startKind="strong"}); if ok==false then error("roomfeed _testIngestSnapshot failed: "..tostring(err)) end; print("[dwverify-roomentities] ingested deterministic snapshot via roomfeed_capture") end',
                note = "Ingest snapshot with titled + plain players and an object line.",
            },
            {
                cmd =
                'lua do local R=require("dwkit.services.roomentities_service"); local v=R.getSnapshotV2 and R.getSnapshotV2() or {}; local function cnt(t) local n=0; if type(t)=="table" then for _ in pairs(t) do n=n+1 end end; return n end; local function has(t,k) return (type(t)=="table" and t[k]~=nil) and true or false end; if cnt(v.players) < 2 then error("Expected at least 2 players in v2.players; got "..tostring(cnt(v.players))) end; if has(v.players,"Alpha the adventurer")~=true then error("Expected titled label in players: Alpha the adventurer") end; if has(v.players,"Beta")~=true then error("Expected Beta in players") end; if has(v.unknown,"A small bulletin board designed for Quests")~=true then error("Expected object line in unknown") end; print(string.format("[dwverify-roomentities] PASS v2.players=%s v2.unknown=%s", tostring(cnt(v.players)), tostring(cnt(v.unknown)))) end',
                note = "ASSERT: titled label promotes to players; object remains unknown.",
            },
        },
    },

    setup_smoke = {
        title = "setup_smoke",
        description = "dwsetup smoke: status + full run (one who refresh); then manual look instruction",
        delay = 0.35,
        steps = {
            { cmd = "dwsetup status", note = "Checklist only (no sends)." },
            { cmd = "dwsetup",        note = "Runs dwwho refresh once and prints next steps." },
            {
                cmd =
                'lua do print("[dwverify-setup] MANUAL: type look once now. This is required for RoomFeed/RoomEntities passive capture so Presence/RoomEntities UIs become correct.") end',
                note = "Manual step reminder (dwsetup does not send look).",
            },
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
                'lua do local gs=require("dwkit.config.gui_settings"); gs.enableVisiblePersistence({noSave=true}); gs.setEnabled("presence_ui", true, {noSave=true}); gs.setVisible("presence_ui", true, {noSave=true}); local UI=require("dwkit.ui.presence_ui"); local ok,err=UI.apply({}); if not ok then error(err) end; local s=UI.getState(); local lr=s.lastRender or {}; print(string.format("[dwverify-ui] presence_ui visible=%s enabled=%s hasContainer=%s hasListRoot=%s rows=%s my=%s myOnline=%s myOffline=%s other=%s", tostring(s.visible), tostring(s.enabled), tostring(s.widgets and s.widgets.hasContainer), tostring(s.widgets and s.widgets.hasListRoot), tostring(lr.rowCount), tostring(lr.myCount), tostring(lr.myOnlineCount), tostring(lr.myOfflineCount), tostring(lr.otherCount))) end',
                note = "Show presence_ui and print state.",
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

    practicestore_smoke = {
        title = "practicestore_smoke",
        description =
        "PracticeStore smoke: confirm service + capture installed; ingest fixture; then (manual) run practice once to validate passive capture ingestion.",
        delay = 0.30,
        steps = {
            {
                cmd =
                'lua do local S=require("dwkit.services.practice_store_service"); print(string.format("[dwverify-practice] service version=%s", tostring(S.getVersion()))) local C=require("dwkit.capture.practice_capture"); print(string.format("[dwverify-practice] capture version=%s", tostring(C.getVersion()))) end',
                note = "Print PracticeStore + PracticeCapture versions (proof modules load).",
            },
            {
                cmd =
                'lua do local S=require("dwkit.services.practice_store_service"); local ok,err=S.ingestFixture("basic",{source="dwverify:fixture"}); print(string.format("[dwverify-practice] ingestFixture ok=%s err=%s", tostring(ok==true), tostring(err))); local snap=S.getSnapshot(); if type(snap)~="table" then error("Expected snapshot after ingestFixture") end; local p=snap.parsed or {}; local function cnt(m) local n=0; if type(m)=="table" then for _ in pairs(m) do n=n+1 end end; return n end; print(string.format("[dwverify-practice] parsed counts skills=%s spells=%s race=%s weapon=%s", tostring(cnt(p.skills)), tostring(cnt(p.spells)), tostring(cnt(p.raceSkills)), tostring(cnt(p.weaponProfs)))) end',
                note = "Ingest fixture and assert snapshot exists + print parsed section counts.",
            },
            {
                cmd =
                'lua do print("[dwverify-practice] MANUAL: type practice now (in game). Expect passive capture to ingest and dwpracticestore to show updated snapshot. After you type practice, run: dwpracticestore status") end',
                note = "Manual step reminder (we do not send practice).",
            },
        },
    },

    command_registry_contract = {
        title = "command_registry_contract",
        description =
        "Command registry contract: validateAll strict=true PASS; enum errors for safety/mode are derived; sendsToGame<->safety coupling errors derived; required fields when sendsToGame=true are derived. No gameplay sends.",
        delay = 0.20,
        steps = {
            {
                cmd =
                'lua do local R=require("dwkit.bus.command_registry"); local ok,issues=R.validateAll({strict=true}); print(string.format("[dwverify-cr] validateAll ok=%s issues=%s", tostring(ok==true), tostring(type(issues)=="table" and #issues or "nil"))); if ok~=true then error("validateAll expected PASS") end end',
                note = "validateAll strict=true should pass.",
            },
            {
                cmd =
                'lua do local R=require("dwkit.bus.command_registry"); local name="__cr_bad_safety_"..tostring(os.time()); local ok,err=R.register({command=name,aliases={},ownerModule="x",description="x",syntax="x",examples={"x"},safety="SAFE2",mode="manual",sendsToGame=false,notes={}}); local exp="invalid: safety must be SAFE|COMBAT-SAFE|NOT SAFE"; print(string.format("[dwverify-cr] bad safety ok=%s err=%s", tostring(ok==true), tostring(err))); if ok==true then error("Expected bad safety to fail") end; if tostring(err)~=exp then error("Expected: "..exp.." got: "..tostring(err)) end end',
                note = "Derived safety enum error string (stable ordering).",
            },
            {
                cmd =
                'lua do local R=require("dwkit.bus.command_registry"); local name="__cr_bad_mode_"..tostring(os.time()); local ok,err=R.register({command=name,aliases={},ownerModule="x",description="x",syntax="x",examples={"x"},safety="SAFE",mode="AUTOX",sendsToGame=false,notes={}}); local exp="invalid: mode must be manual|opt-in|essential-default (legacy \'auto\' accepted)"; print(string.format("[dwverify-cr] bad mode ok=%s err=%s", tostring(ok==true), tostring(err))); if ok==true then error("Expected bad mode to fail") end; if tostring(err)~=exp then error("Expected: "..exp.." got: "..tostring(err)) end end',
                note = "Derived mode enum error string (includes legacy note).",
            },
            {
                cmd =
                'lua do local R=require("dwkit.bus.command_registry"); local name="__cr_couple_true_"..tostring(os.time()); local ok,err=R.register({command=name,aliases={},ownerModule="x",description="x",syntax="x",examples={"x"},safety="SAFE",mode="manual",sendsToGame=true,underlyingGameCommand="x",sideEffects="x",notes={}}); local exp="invalid: safety must be COMBAT-SAFE|NOT SAFE when sendsToGame=true"; print(string.format("[dwverify-cr] coupling true ok=%s err=%s", tostring(ok==true), tostring(err))); if ok==true then error("Expected coupling (sendsToGame=true safety=SAFE) to fail") end; if tostring(err)~=exp then error("Expected: "..exp.." got: "..tostring(err)) end end',
                note = "Derived sendsToGame=true safety coupling error (COMBAT-SAFE|NOT SAFE).",
            },
            {
                cmd =
                'lua do local R=require("dwkit.bus.command_registry"); local name="__cr_couple_false_"..tostring(os.time()); local ok,err=R.register({command=name,aliases={},ownerModule="x",description="x",syntax="x",examples={"x"},safety="COMBAT-SAFE",mode="manual",sendsToGame=false,notes={}}); local exp="invalid: safety must be SAFE when sendsToGame=false"; print(string.format("[dwverify-cr] coupling false ok=%s err=%s", tostring(ok==true), tostring(err))); if ok==true then error("Expected coupling (sendsToGame=false safety!=SAFE) to fail") end; if tostring(err)~=exp then error("Expected: "..exp.." got: "..tostring(err)) end end',
                note = "Derived sendsToGame=false safety coupling error (SAFE only).",
            },
            {
                cmd =
                'lua do local R=require("dwkit.bus.command_registry"); local name="__cr_missing_ugc_"..tostring(os.time()); local ok,err=R.register({command=name,aliases={},ownerModule="x",description="x",syntax="x",examples={"x"},safety="COMBAT-SAFE",mode="manual",sendsToGame=true,sideEffects="x",notes={}}); local exp="missing/invalid: underlyingGameCommand (required when sendsToGame=true)"; print(string.format("[dwverify-cr] missing ugc ok=%s err=%s", tostring(ok==true), tostring(err))); if ok==true then error("Expected missing underlyingGameCommand to fail") end; if tostring(err)~=exp then error("Expected: "..exp.." got: "..tostring(err)) end end',
                note = "Derived required-field error: underlyingGameCommand.",
            },
            {
                cmd =
                'lua do local R=require("dwkit.bus.command_registry"); local name="__cr_missing_se_"..tostring(os.time()); local ok,err=R.register({command=name,aliases={},ownerModule="x",description="x",syntax="x",examples={"x"},safety="COMBAT-SAFE",mode="manual",sendsToGame=true,underlyingGameCommand="x",notes={}}); local exp="missing/invalid: sideEffects (required when sendsToGame=true)"; print(string.format("[dwverify-cr] missing sideEffects ok=%s err=%s", tostring(ok==true), tostring(err))); if ok==true then error("Expected missing sideEffects to fail") end; if tostring(err)~=exp then error("Expected: "..exp.." got: "..tostring(err)) end end',
                note = "Derived required-field error: sideEffects.",
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
