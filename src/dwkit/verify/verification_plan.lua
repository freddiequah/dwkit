-- FILE: src/dwkit/verify/verification_plan.lua
-- #########################################################################
-- BEGIN FILE: src/dwkit/verify/verification_plan.lua
-- #########################################################################
-- Module Name : dwkit.verify.verification_plan
-- Owner       : Verify
-- Version     : v2026-02-27A
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

M.VERSION = "v2026-02-27A"

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
                note =
                "Ingest deterministic snapshot (SAFE; no sends). Presence consumes V2 unknown too.",
            },
            {
                cmd =
                'lua do local P=require("dwkit.services.presence_service"); local st=P.getState(); local my=st.myProfilesInRoom or {}; local ot=st.otherPlayersInRoom or {}; if type(my)~="table" or type(ot)~="table" then error("Expected myProfilesInRoom/otherPlayersInRoom tables") end; local hasMy=false; for i=1,#my do if tostring(my[i])=="FixturePlayer (Ancient-Dev)" then hasMy=true end end; local hasOther=false; for i=1,#ot do if tostring(ot[i])=="OtherGuy" then hasOther=true end end; if hasMy~=true then error("Expected FixturePlayer in My profiles as FixturePlayer (Ancient-Dev)") end; if hasOther~=true then error("Expected OtherGuy in Other players") end; print(string.format("[dwverify-presence] PASS presence split my=%s other=%s", tostring(#my), tostring(#ot))) end',
                note = "ASSERT: PresenceService computed split deterministically.",
            },
            {
                cmd =
                'lua do local gs=require("dwkit.config.gui_settings"); gs.enableVisiblePersistence({noSave=true}); gs.setEnabled("presence_ui", true, {noSave=true}); gs.setVisible("presence_ui", true, {noSave=true}); local UI=require("dwkit.ui.presence_ui"); local ok,err=UI.apply({source="dwverify:presence_ui_populates"}); if ok==false then error("presence_ui.apply failed: "..tostring(err)) end; local s=UI.getState(); local lr=s.lastRender or {}; print(string.format("[dwverify-presence] presence_ui visible=%s enabled=%s rows=%s my=%s myOnline=%s myOffline=%s other=%s", tostring(s.visible), tostring(s.enabled), tostring(lr.rowCount), tostring(lr.myCount), tostring(lr.myOnlineCount), tostring(lr.myOfflineCount), tostring(lr.otherCount))) end',
                note =
                "Show Presence_UI and print state.",
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
}

function M.getSuites()
    return SUITES
end

return M

-- #########################################################################
-- END FILE: src/dwkit/verify/verification_plan.lua
-- #########################################################################
