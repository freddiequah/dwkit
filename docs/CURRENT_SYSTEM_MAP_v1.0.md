# docs/CURRENT_SYSTEM_MAP_v1.0.md

# CURRENT_SYSTEM_MAP v1.0
- Date: 2026-01-08
- Source input: Tester.zip (Mudlet profile export: Tester/current/2026-01-08#17-24-35.xml) + profile sidecar files
- Source counts (from XML):
  - Scripts: 55
  - Triggers: 12
  - Aliases: 71
  - Timers: 0

## Scope
- This document inventories what exists in the provided profile export.
- It does NOT attempt to inventory arbitrary third-party scripts other users may have in their own profiles.
- Goal: identify what we will migrate into DWKit, what is external, and where automation / gameplay side effects exist.

## High-level packages and groups found (script roots)
- Script root group: **gui-drop**
- Script root group: **deleteOldProfiles**
- Script root group: **generic_mapper**
- Script root group: **Deathwish Kit**

## Sidecar files in profile folder
- AdjustableContainer/HealerSelector_UI_Tester.lua (appears to be saved UI layout/state)
- AdjustableContainer/PresenceUI_Tester.lua (appears to be saved UI layout/state)
- log/errors.txt (empty)

## Triggers (inputs)

All triggers found are under `generic_mapper`.

- **generic_mapper/onNewLine Trigger** (active=yes)
  - type: line trigger (fires on each new line); Mudlet triggerType=0
  - action: `raiseEvent("onNewLine")`

- **generic_mapper/English Trigger Group/English Exits Trigger** (active=yes)
  - patterns: (?i)^\s*\[\s*Exits:\s*(.*)\]; ^\s*There (?:is|are) \w+ (?:visible|obvious) exit[s]?:\s*(.*); ^\s*The (?:only )?obvious exit[s]? (?:is|are):? (.*); ^\s*(?:There (?:is|are) )?(?:only )?(?:a|an|some )?exit[s]? (?:to the|are|is):? (.*); ^\s*The only obvious exit(?: to)? is: (.*); ^\s*Obvious exits are: (.*); ^\s*The obvious exits are: (.*)
  - script: `raiseEvent("onNewRoom",matches[2] or "")`

- **generic_mapper/English Trigger Group/English Failed Move Trigger** (active=yes)
  - patterns: ^(?:Alas, )?[Yy]ou can(?:no|')t (?:go|move) .*$; ^The .+ (?:is|seems to be) closed.$; .+ (?:is not going to|will not) let you pass.$; ^That exit is blocked.$; ^You are blocked by .*$; ^There is no exit in that direction.$; ^The .* is locked.$; ^Alas, you cannot go that way\.\.\.$
  - script: `raiseEvent("onNewRoom",matches[2] or "")`

- **generic_mapper/English Trigger Group/English Vision Fail Trigger** (active=yes)
  - patterns: ^It is pitch black...; ^It(?:'s| is) too dark
  - script: `raiseEvent("onNewRoom",matches[2] or "")`

- **generic_mapper/English Trigger Group/English Forced Move Trigger** (active=yes)
  - patterns: ^Carefully getting your bearings, you set off (\w+) toward your goal.
  - script: `raiseEvent("onNewRoom",matches[2] or "")`

- **generic_mapper/English Trigger Group/English Multi-Line Exits Trigger** (active=yes)
  - patterns: (?i:^(obvious|visible) exits:); ^([\w\s]+)\s*: [\w\s]+
  - script: `raiseEvent("onNewRoom",matches[2] or "")`

- **generic_mapper/English Trigger Group/English Multi-Line Exits Trigger/Exit Line Trigger** (active=yes)
  - patterns: ^([\w\s]+)\s*: [\w\s]+
  - script: `raiseEvent("onNewRoom",matches[2] or "")`

- **generic_mapper/Russian Trigger Group/Russian Exits Trigger** (active=yes)
  - patterns: ^\s*\[\s*Выходы:\s*(.*)\]
  - script: `raiseEvent("onNewRoom",matches[2] or "")`

- **generic_mapper/Russian Trigger Group/Russian Failed Move Trigger** (active=yes)
  - patterns: Извини, но ты не можешь туда идти.
  - script: `raiseEvent("onNewRoom",matches[2] or "")`

- **generic_mapper/Russian Trigger Group/Russian Vision Fail Trigger** (active=yes)
  - patterns: Здесь слишком темно ...
  - script: `raiseEvent("onNewRoom",matches[2] or "")`

- **generic_mapper/Chinese Trigger Group/Chinese Exits Trigger** (active=yes)
  - patterns: ^\s*这里明显的方向有 (.*)。; ^\s*这里明显的出口有 (.*)。; ^\s*这里明显的出口是 (.*)。; ^\s*这里唯一的出口是 (.*)。; ^\s*這裏明顯的出口是 (.*)。; ^\s*這裏唯一的出口是 (.*)。; ^\s*這裏明顯的方向有 (.*)。
  - script: `raiseEvent("onNewRoom",matches[2] or "")`

- **generic_mapper/Chinese Trigger Group/Chinese Failed Movement Trigger** (active=yes)
  - patterns: 你又渴又饿，浑身无力，根本就走不动路。; 这个方向没有出路。; ^看来(\w+)不打算让你过去。
  - script: `raiseEvent("onNewRoom",matches[2] or "")`

## Aliases (inputs)

Alias regex patterns are stored in the export’s `<regex>` field (not the `command` field).

### deleteOldProfiles
- **deleteOldProfiles/delete old profiles** (active=yes)
  - regex: `^delete old profiles$`
  - action: `deleteOldProfiles()`

### echo
- **echo/`cecho** (active=yes)
  - regex: `` `cecho (.+) ``
  - action: `local s = matches[2]`
- **echo/`decho** (active=yes)
  - regex: `` `decho (.+) ``
  - action: `local s = matches[2]`
- **echo/`echo** (active=yes)
  - regex: `` `echo (.+) ``
  - action: `local s = matches[2]`
- **echo/`hecho** (active=yes)
  - regex: `` `hecho (.+) ``
  - action: `local s = matches[2]`

### enable-accessibility
- **enable-accessibility/mudlet accessibility on** (active=yes)
  - regex: `^mudlet access(?:ibility)? on$`
  - action: `echo("Welcome to Mudlet!\n")`
- **enable-accessibility/mudlet accessibility reader** (active=yes)
  - regex: `^mudlet access(?:ibility)? reader$`
  - action: `echo("Welcome to Mudlet!\n")`

### run-lua-code
- **run-lua-code/run lua code** (active=yes)
  - regex: `^lua (.*)$`
  - action: `local f, e = loadstring("return "..matches[2])`

### generic_mapper
- **generic_mapper/Information Aliases/Map Basics Alias** (active=yes)
  - regex: `^map basics$`
  - action: `map.show_help("quick_start")`
- **generic_mapper/Information Aliases/Map Help Alias** (active=yes)
  - regex: `^map help(?: (.*))?$`
  - action: `map.show_help(matches[2])`
- **generic_mapper/Information Aliases/Map Quick Start Alias** (active=yes)
  - regex: `^map quick start$`
  - action: `map.show_help("quick_start")`
- **generic_mapper/Information Aliases/Map Window Help Alias** (active=yes)
  - regex: `^map window help$`
  - action: `map.window.show_help()`
- **generic_mapper/Information Aliases/Map Window Status Alias** (active=yes)
  - regex: `^map window status$`
  - action: `map.window.status()`
- **generic_mapper/Information Aliases/Map Window Toggle Alias** (active=yes)
  - regex: `^map window$`
  - action: `map.window.toggle()`
- **generic_mapper/Information Aliases/Map Window Toggle Small Alias** (active=yes)
  - regex: `^map window small$`
  - action: `map.window.toggleSmall()`
- **generic_mapper/Information Aliases/Map Window Toggle Big Alias** (active=yes)
  - regex: `^map window big$`
  - action: `map.window.toggleBig()`
- **generic_mapper/Information Aliases/Map Window Set Size Alias** (active=yes)
  - regex: `^map window size (\d+) (\d+)$`
  - action: `map.window.setSize(tonumber(matches[2]), tonumber(matches[3]))`
- **generic_mapper/Map Creation Aliases/Add Room Alias** (active=yes)
  - regex: `^map add room$`
  - action: `map.addRoom()`
- **generic_mapper/Map Creation Aliases/Connect Rooms Alias** (active=yes)
  - regex: `^map connect (.+) (.+)$`
  - action: `map.connectRooms(matches[2], matches[3])`
- **generic_mapper/Map Creation Aliases/Create Area Alias** (active=yes)
  - regex: `^map create area (.+)$`
  - action: `map.createArea(matches[2])`
- **generic_mapper/Map Creation Aliases/Create Room Alias** (active=yes)
  - regex: `^map create room$`
  - action: `map.createRoom()`
- **generic_mapper/Map Creation Aliases/Delete Room Alias** (active=yes)
  - regex: `^map delete room$`
  - action: `map.deleteRoom()`
- **generic_mapper/Map Creation Aliases/Delete Area Alias** (active=yes)
  - regex: `^map delete area (.+)$`
  - action: `map.deleteArea(matches[2])`
- **generic_mapper/Map Creation Aliases/Map Debug Alias** (active=yes)
  - regex: `^map debug$`
  - action: `map.toggleDebug()`
- **generic_mapper/Map Creation Aliases/Map Ignore Alias** (active=yes)
  - regex: `^map ignore(?: (.*))?$`
  - action: `if matches[2] then`
- **generic_mapper/Map Creation Aliases/Map Prompt Alias** (active=yes)
  - regex: `^map prompt(?: (.*))?$`
  - action: `if matches[2] then`
- **generic_mapper/Map Creation Aliases/Map Show Alias** (active=yes)
  - regex: `^map show$`
  - action: `map.showMap()`
- **generic_mapper/Map Creation Aliases/Map Update Alias** (active=yes)
  - regex: `^map update$`
  - action: `map.update()`
- **generic_mapper/Map Creation Aliases/Set Move Method Alias** (active=yes)
  - regex: `^map move(?: (.*))?$`
  - action: `map.setMoveMethod(matches[2])`
- **generic_mapper/Regular Use Aliases/Map Area Alias** (active=yes)
  - regex: `^map area(?: (.*))?$`
  - action: `map.setArea(matches[2])`
- **generic_mapper/Regular Use Aliases/Map Here Alias** (active=yes)
  - regex: `^map here$`
  - action: `map.here()`
- **generic_mapper/Regular Use Aliases/Map Locate Alias** (active=yes)
  - regex: `^map locate(?: (.*))?$`
  - action: `map.locate(matches[2])`
- **generic_mapper/Regular Use Aliases/Map Path Alias** (active=yes)
  - regex: `^map path (.+)$`
  - action: `map.path(matches[2])`
- **generic_mapper/Regular Use Aliases/Map Stop Alias** (active=yes)
  - regex: `^map stop$`
  - action: `map.stop()`
- **generic_mapper/Regular Use Aliases/Map Unpath Alias** (active=yes)
  - regex: `^map unpath$`
  - action: `map.unpath()`
- **generic_mapper/Regular Use Aliases/Map Walk Alias** (active=yes)
  - regex: `^map walk$`
  - action: `map.walk()`
- **generic_mapper/Setup Aliases/Map Config Alias** (active=yes)
  - regex: `^map config(?: (.*))?$`
  - action: `map.config(matches[2])`
- **generic_mapper/Setup Aliases/Map Config Prompt Alias** (active=yes)
  - regex: `^map config prompt(?: (.*))?$`
  - action: `map.config_prompt(matches[2])`
- **generic_mapper/Setup Aliases/Map Config Ignore Alias** (active=yes)
  - regex: `^map config ignore(?: (.*))?$`
  - action: `map.config_ignore(matches[2])`
- **generic_mapper/Setup Aliases/Map Window Config Alias** (active=yes)
  - regex: `^map window config(?: (.*))?$`
  - action: `map.window.config(matches[2])`
- **generic_mapper/Setup Aliases/Map Translation Config Alias** (active=yes)
  - regex: `^map translation(?: (.*))?$`
  - action: `map.translation(matches[2])`
- **generic_mapper/Setup Aliases/Map Set Prompt Alias** (active=yes)
  - regex: `^map set prompt$`
  - action: `map.find_prompt()`
- **generic_mapper/Map Sharing Aliases/Map Export Alias** (active=yes)
  - regex: `^map export(?: (.*))?$`
  - action: `map.export(matches[2])`
- **generic_mapper/Map Sharing Aliases/Map Import Alias** (active=yes)
  - regex: `^map import(?: (.*))?$`
  - action: `map.import(matches[2])`
- **generic_mapper/Map Sharing Aliases/Map Publish Alias** (active=yes)
  - regex: `^map publish(?: (.*))?$`
  - action: `map.publish(matches[2])`
- **generic_mapper/Map Sharing Aliases/Map Subscribe Alias** (active=yes)
  - regex: `^map subscribe(?: (.*))?$`
  - action: `map.subscribe(matches[2])`
- **generic_mapper/Map Sharing Aliases/Save Map Alias** (active=yes)
  - regex: `^map save(?: (.*))?$`
  - action: `map.save_map(matches[2])`
- **generic_mapper/Map Sharing Aliases/Load Map Alias** (active=yes)
  - regex: `^map load(?: (.*))?$`
  - action: `map.load_map(matches[2])`
- **generic_mapper/Map Sharing Aliases/Import Map Area Alias** (active=yes)
  - regex: `^map import area (.*)$`
  - action: `map.import_area(matches[2])`
- **generic_mapper/Map Sharing Aliases/Export Map Area Alias** (active=yes)
  - regex: `^map export area (.*)$`
  - action: `map.export_area(matches[2])`

> Note: `generic_mapper` contains many more aliases beyond the representative list above in some Mudlet distributions. This export contains exactly 71 aliases total; the non-generic_mapper aliases are fully enumerated above, and the generic_mapper section lists the active command surface patterns and their Lua call targets as they appear in this export.

## Scripts (inventory)

Legend tags used below:
- `sendsToGame: YES` means the script contains `send(` or `sendAll(` calls (gameplay side effects).
- `persistence: YES` means file I/O patterns detected (e.g., `io.open`, `lfs.*`, `table.save/load`, JSON file ops).
- `ui: YES` means UI frameworks detected (e.g., Geyser/EMCO/AdjustableContainer).
- `autoRisk: HIGH` indicates system events (sys*), temp triggers, or temp timers were detected (runs without explicit manual invocation).

### Deathwish Kit
- **BootSummary_Core**
  - purpose: Script Name: BootSummary_Core Purpose: Consolidate startup banners into a minimal login summary + on-demand menu Console output only (legacy script; details in script header)
  - events consumed: (none detected)
  - sendsToGame: NO | persistence: NO | ui: NO | autoRisk: HIGH
  - globals assigned (heuristic): BootSummary

### Deathwish Kit/00_Core
- **00_Bootstrap**
  - purpose: Healer_Core_SPLIT / 00_Bootstrap
  - events consumed: sysLoadEvent
  - sendsToGame: NO | persistence: NO | ui: NO | autoRisk: HIGH
  - globals assigned (heuristic): HC, Healer_Core, v
- **99_Init**
  - purpose: Healer_Core_SPLIT / 99_Init
  - events consumed: (none detected)
  - sendsToGame: NO | persistence: NO | ui: NO | autoRisk: LOW
  - globals assigned (heuristic): Healer_Core
- **CPC_Embedded**
  - purpose: Healer_Core_SPLIT / CPC_Embedded
  - events consumed: (none detected)
  - sendsToGame: YES | persistence: NO | ui: NO | autoRisk: LOW
  - globals assigned (heuristic): CPC, CPC_Embedded

### Deathwish Kit/10_Data
- **20_ClericSpells**
  - purpose: Healer_Core_SPLIT / 20_ClericSpells
  - events consumed: (none detected)
  - sendsToGame: NO | persistence: NO | ui: NO | autoRisk: LOW
  - globals assigned (heuristic): ClericSpells, Healer_Core

### Deathwish Kit/20_State_Capture
- **30_CharStatus_CharState**
  - purpose: Healer_Core_SPLIT / 30_CharStatus_CharState
  - events consumed: sysConnectionEvent
  - sendsToGame: YES | persistence: NO | ui: NO | autoRisk: HIGH
  - globals assigned (heuristic): CharState, CharStatus, Healer_Core
- **40_BuffHUD_Core**
  - purpose: Healer_Core_SPLIT / 40_BuffHUD_Core
  - events consumed: (none detected)
  - sendsToGame: YES | persistence: NO | ui: YES | autoRisk: HIGH
  - globals assigned (heuristic): BuffHUD, buffs, opts
- **50_BuffHUD_AffectsCapture**
  - purpose: Healer_Core_SPLIT / 50_BuffHUD_AffectsCapture
  - events consumed: sysConnectionEvent
  - sendsToGame: NO | persistence: NO | ui: NO | autoRisk: HIGH
  - globals assigned (heuristic): BuffHUD, opts
- **ScoreStore (No-GMCP)**
  - purpose: ScoreStore (No-GMCP)
  - events consumed: sysConnectionEvent
  - sendsToGame: YES | persistence: YES | ui: NO | autoRisk: HIGH
  - globals assigned (heuristic): ScoreStore, opts
- **WhoStore (No-GMCP)**
  - purpose: WhoStore (No-GMCP)
  - events consumed: sysConnectionEvent
  - sendsToGame: YES | persistence: YES | ui: NO | autoRisk: HIGH
  - globals assigned (heuristic): WhoStore, opts

### Deathwish Kit/25_StatusHUD
- **StatusHUD_TankOpp_Group_UI**
  - purpose: Healer_Core_SPLIT / StatusHUD_TankOpp_Group_UI
  - events consumed: sysConnectionEvent
  - sendsToGame: YES | persistence: NO | ui: YES | autoRisk: HIGH
  - globals assigned (heuristic): StatusHUD_TOG_UI
- **StatusHUD_TankSync**
  - purpose: Healer_Core_SPLIT / StatusHUD_TankSync
  - events consumed: (none detected)
  - sendsToGame: YES | persistence: NO | ui: NO | autoRisk: LOW
  - globals assigned (heuristic): TankSync

### Deathwish Kit/30_Logic_Kits
- **100_RoomHelpers_PresenceGate**
  - purpose: Healer_Core_SPLIT / 100_RoomHelpers_PresenceGate
  - events consumed: (none detected)
  - sendsToGame: NO | persistence: NO | ui: NO | autoRisk: LOW
  - globals assigned (heuristic): PresenceGate
- **110_MoveKit_RelocateThenSummon**
  - purpose: Healer_Core_SPLIT / 110_MoveKit_RelocateThenSummon
  - events consumed: (none detected)
  - sendsToGame: YES | persistence: NO | ui: NO | autoRisk: HIGH
  - globals assigned (heuristic): MoveKit
- **120_BuffKit_BuffMe_And_BuffTarget**
  - purpose: Healer_Core_SPLIT / 120_BuffKit_BuffMe_And_BuffTarget
  - events consumed: (none detected)
  - sendsToGame: YES | persistence: NO | ui: NO | autoRisk: HIGH
  - globals assigned (heuristic): BuffKit
- **130_FoodService_Kit**
  - purpose: Healer_Core_SPLIT / 130_FoodService_Kit
  - events consumed: (none detected)
  - sendsToGame: YES | persistence: NO | ui: NO | autoRisk: HIGH
  - globals assigned (heuristic): FoodService
- **140_GroupBuff_Kit**
  - purpose: Healer_Core_SPLIT / 140_GroupBuff_Kit
  - events consumed: (none detected)
  - sendsToGame: NO | persistence: NO | ui: NO | autoRisk: LOW
  - globals assigned (heuristic): GroupBuff
- **150_Movement_Recall_Kit**
  - purpose: Healer_Core_SPLIT / 150_Movement_Recall_Kit
  - events consumed: (none detected)
  - sendsToGame: YES | persistence: NO | ui: NO | autoRisk: LOW
  - globals assigned (heuristic): RecallKit
- **160_SummonRelocate_Smart_Kit**
  - purpose: Healer_Core_SPLIT / 160_SummonRelocate_Smart_Kit
  - events consumed: (none detected)
  - sendsToGame: YES | persistence: NO | ui: NO | autoRisk: HIGH
  - globals assigned (heuristic): SummonRelocate
- **170_Presence_Helper**
  - purpose: Healer_Core_SPLIT / 170_Presence_Helper
  - events consumed: (none detected)
  - sendsToGame: NO | persistence: NO | ui: NO | autoRisk: LOW
  - globals assigned (heuristic): Presence
- **180_ActionPad_MoveGate**
  - purpose: Healer_Core_SPLIT / 180_ActionPad_MoveGate
  - events consumed: (none detected)
  - sendsToGame: YES | persistence: NO | ui: NO | autoRisk: HIGH
  - globals assigned (heuristic): ActionPad_MoveGate
- **190_ActionPad_MoveHelpers_ApsuAprl**
  - purpose: Healer_Core_SPLIT / 190_ActionPad_MoveHelpers_ApsuAprl
  - events consumed: (none detected)
  - sendsToGame: YES | persistence: NO | ui: NO | autoRisk: LOW
  - globals assigned (heuristic): ActionPad_MoveHelpers
- **200_Offence_Kit_Smite**
  - purpose: Healer_Core_SPLIT / 200_Offence_Kit_Smite
  - events consumed: (none detected)
  - sendsToGame: YES | persistence: NO | ui: NO | autoRisk: LOW
  - globals assigned (heuristic): OffenceKit
- **210_Zombie_Manager**
  - purpose: Healer_Core_SPLIT / 210_Zombie_Manager
  - events consumed: (none detected)
  - sendsToGame: YES | persistence: NO | ui: NO | autoRisk: HIGH
  - globals assigned (heuristic): ZombieManager
- **60_HealerSelector_Logic**
  - purpose: Healer_Core_SPLIT / 60_HealerSelector_Logic
  - events consumed: (none detected)
  - sendsToGame: NO | persistence: NO | ui: NO | autoRisk: LOW
  - globals assigned (heuristic): HealerSelector
- **70_HealerSmart_XPC_Executor**
  - purpose: Healer_Core_SPLIT / 70_HealerSmart_XPC_Executor
  - events consumed: (none detected)
  - sendsToGame: NO | persistence: NO | ui: NO | autoRisk: LOW
  - globals assigned (heuristic): HealerSmart
- **80_HealerSmart_Unknown_Readycast**
  - purpose: Healer_Core_SPLIT / 80_HealerSmart_Unknown_Readycast
  - events consumed: sysDisconnectionEvent, sysLoadEvent
  - sendsToGame: YES | persistence: NO | ui: NO | autoRisk: HIGH
  - globals assigned (heuristic): HealerSmart
- **90_HealerSmart_Heals_And_Aliases**
  - purpose: Healer_Core_SPLIT / 90_HealerSmart_Heals_And_Aliases
  - events consumed: (none detected)
  - sendsToGame: YES | persistence: NO | ui: NO | autoRisk: HIGH
  - globals assigned (heuristic): HealerSmart

### Deathwish Kit/35_LateModules
- **000_HealerCore_Master**
  - purpose: Healer_Core_SPLIT / 000_HealerCore_Master
  - events consumed: (none detected)
  - sendsToGame: NO | persistence: NO | ui: NO | autoRisk: LOW
  - globals assigned (heuristic): Healer_Core
- **005_AutoLoad**
  - purpose: Healer_Core_SPLIT / 005_AutoLoad
  - events consumed: sysLoadEvent
  - sendsToGame: NO | persistence: NO | ui: NO | autoRisk: HIGH
  - globals assigned (heuristic): Healer_Core
- **05_Debug**
  - purpose: Healer_Core_SPLIT / 05_Debug
  - events consumed: (none detected)
  - sendsToGame: NO | persistence: NO | ui: NO | autoRisk: LOW
  - globals assigned (heuristic): Healer_Core
- **49_BuffHUD_Commands**
  - purpose: Healer_Core_SPLIT / 49_BuffHUD_Commands
  - events consumed: (none detected)
  - sendsToGame: YES | persistence: NO | ui: NO | autoRisk: LOW
  - globals assigned (heuristic): BuffHUD
- **51_BuffHUD_AutoRefresh**
  - purpose: Healer_Core_SPLIT / 51_BuffHUD_AutoRefresh
  - events consumed: (none detected)
  - sendsToGame: NO | persistence: NO | ui: NO | autoRisk: HIGH
  - globals assigned (heuristic): BuffHUD, Healer_Core

### Deathwish Kit/40_UI
- **EMCOChat_Integrator**
  - purpose: Healer_Core_SPLIT / EMCOChat_Integrator
  - events consumed: sysLoadEvent
  - sendsToGame: NO | persistence: NO | ui: YES | autoRisk: HIGH
  - globals assigned (heuristic): EMCO_Integrator
- **HealerSelector_UI**
  - purpose: HealerSelector_UI (legacy UI script; see header for details)
  - events consumed: sysConnectionEvent
  - sendsToGame: YES | persistence: NO | ui: YES | autoRisk: HIGH
  - globals assigned (heuristic): HealerSelectorUI
- **Presence_UI**
  - purpose: Presence_UI (legacy UI script; see header for details)
  - events consumed: PresenceUI_BEACON, PresenceUI_XROOM, gmcp.Char.Vitals, gmcp.Room.Info, gmcp.Room.Players, sysConnectedEvent, sysConnectionEvent, sysDisconnectedEvent, sysDisconnectionEvent, sysLoadEvent
  - gmcp usage detected: YES (must be optional; MUD may not support GMCP)
  - sendsToGame: YES | persistence: NO | ui: YES | autoRisk: HIGH
  - globals assigned (heuristic): PresenceUI
- **UI_LaunchPad_Buttons**
  - purpose: Healer_Core_SPLIT / UI_LaunchPad_Buttons
  - events consumed: sysLoadEvent
  - sendsToGame: NO | persistence: NO | ui: YES | autoRisk: HIGH
  - globals assigned (heuristic): UI_LaunchPad

### Deathwish Kit/40_UI/42_ActionPad
- **200_ActionPad_Core**
  - purpose: Healer_Core_SPLIT / 200_ActionPad_Core
  - events consumed: sysConnectionEvent
  - sendsToGame: YES | persistence: NO | ui: YES | autoRisk: HIGH
  - globals assigned (heuristic): ActionPadUI
- **210_ActionPad_PeerState**
  - purpose: Healer_Core_SPLIT / 210_ActionPad_PeerState
  - events consumed: sysConnectionEvent
  - sendsToGame: NO | persistence: NO | ui: YES | autoRisk: HIGH
  - globals assigned (heuristic): ActionPadUI
- **220_ActionPad_Actions**
  - purpose: Healer_Core_SPLIT / 220_ActionPad_Actions
  - events consumed: sysConnectionEvent
  - sendsToGame: NO | persistence: NO | ui: YES | autoRisk: HIGH
  - globals assigned (heuristic): ActionPadUI
- **230_ActionPad_UI_Builders**
  - purpose: Healer_Core_SPLIT / 230_ActionPad_UI_Builders
  - events consumed: (none detected)
  - sendsToGame: NO | persistence: NO | ui: YES | autoRisk: LOW
  - globals assigned (heuristic): ActionPadUI
- **235_ActionPad_ClassRemote**
  - purpose: Healer_Core_SPLIT / 235_ActionPad_ClassRemote
  - events consumed: (none detected)
  - sendsToGame: NO | persistence: NO | ui: YES | autoRisk: LOW
  - globals assigned (heuristic): ActionPadUI
- **240_ActionPad_UI**
  - purpose: Healer_Core_SPLIT / 240_ActionPad_UI
  - events consumed: sysConnectionEvent
  - sendsToGame: NO | persistence: NO | ui: YES | autoRisk: HIGH
  - globals assigned (heuristic): ActionPadUI

### Deathwish Kit/90_Tools_Debug
- **220_Debug_BuffMeta**
  - purpose: Healer_Core_SPLIT / 220_Debug_BuffMeta
  - events consumed: (none detected)
  - sendsToGame: NO | persistence: NO | ui: NO | autoRisk: LOW
  - globals assigned (heuristic): HealerSmart, Healer_Core
- **230_Help_ScriptHelp**
  - purpose: Healer_Core_SPLIT / 230_Help_ScriptHelp
  - events consumed: (none detected)
  - sendsToGame: NO | persistence: NO | ui: NO | autoRisk: LOW
  - globals assigned (heuristic): HealerSmart, Healer_Core
- **240_Boot_Banner**
  - purpose: Healer_Core_SPLIT / 240_Boot_Banner
  - events consumed: (none detected)
  - sendsToGame: NO | persistence: NO | ui: NO | autoRisk: LOW
  - globals assigned (heuristic): Healer_Core
- **250_Sanity_Diagnostics**
  - purpose: Healer_Core_SPLIT / 250_Sanity_Diagnostics
  - events consumed: (none detected)
  - sendsToGame: NO | persistence: NO | ui: NO | autoRisk: LOW
  - globals assigned (heuristic): Healer_Core

### deleteOldProfiles
- **deleteOldProfiles script**
  - purpose: (purpose not documented in script; legacy name: deleteOldProfiles script)
  - events consumed: (none detected)
  - sendsToGame: NO | persistence: YES | ui: NO | autoRisk: LOW

### generic_mapper
- **Map Script**
  - purpose: (purpose not documented in script; legacy name: Map Script)
  - events consumed: sysConnectionEvent
  - sendsToGame: YES | persistence: YES | ui: YES | autoRisk: HIGH
  - globals assigned (heuristic): areaList, map, mudlet

### gui-drop
- **AdjustableContainer Additions**
  - purpose: (purpose not documented in script; legacy name: AdjustableContainer Additions)
  - events consumed: (none detected)
  - sendsToGame: NO | persistence: YES | ui: YES | autoRisk: LOW
- **Global Variable Functions**
  - purpose: (purpose not documented in script; legacy name: Global Variable Functions)
  - events consumed: (none detected)
  - sendsToGame: NO | persistence: NO | ui: NO | autoRisk: LOW
- **ImageDrop**
  - purpose: (purpose not documented in script; legacy name: ImageDrop)
  - events consumed: (none detected)
  - sendsToGame: NO | persistence: YES | ui: YES | autoRisk: LOW
- **createDropManager**
  - purpose: (purpose not documented in script; legacy name: createDropManager)
  - events consumed: (none detected)
  - sendsToGame: NO | persistence: YES | ui: YES | autoRisk: LOW
- **createDropScript**
  - purpose: (purpose not documented in script; legacy name: createDropScript)
  - events consumed: (none detected)
  - sendsToGame: NO | persistence: NO | ui: NO | autoRisk: LOW
- **workaround for add**
  - purpose: (purpose not documented in script; legacy name: workaround for add)
  - events consumed: sysLoadEvent
  - sendsToGame: NO | persistence: NO | ui: NO | autoRisk: HIGH

## Automation risk highlights (review carefully before migration)
Scripts flagged as `autoRisk=HIGH` (system events, temp triggers, or timers detected):
- Deathwish Kit/00_Core/00_Bootstrap
- Deathwish Kit/20_State_Capture/30_CharStatus_CharState
- Deathwish Kit/20_State_Capture/40_BuffHUD_Core
- Deathwish Kit/20_State_Capture/50_BuffHUD_AffectsCapture
- Deathwish Kit/20_State_Capture/ScoreStore (No-GMCP)
- Deathwish Kit/20_State_Capture/WhoStore (No-GMCP)
- Deathwish Kit/25_StatusHUD/StatusHUD_TankOpp_Group_UI
- Deathwish Kit/30_Logic_Kits/110_MoveKit_RelocateThenSummon
- Deathwish Kit/30_Logic_Kits/120_BuffKit_BuffMe_And_BuffTarget
- Deathwish Kit/30_Logic_Kits/130_FoodService_Kit
- Deathwish Kit/30_Logic_Kits/160_SummonRelocate_Smart_Kit
- Deathwish Kit/30_Logic_Kits/180_ActionPad_MoveGate
- Deathwish Kit/30_Logic_Kits/210_Zombie_Manager
- Deathwish Kit/30_Logic_Kits/80_HealerSmart_Unknown_Readycast
- Deathwish Kit/30_Logic_Kits/90_HealerSmart_Heals_And_Aliases
- Deathwish Kit/35_LateModules/005_AutoLoad
- Deathwish Kit/35_LateModules/51_BuffHUD_AutoRefresh
- Deathwish Kit/40_UI/EMCOChat_Integrator
- Deathwish Kit/40_UI/HealerSelector_UI
- Deathwish Kit/40_UI/Presence_UI
- Deathwish Kit/40_UI/UI_LaunchPad_Buttons
- Deathwish Kit/40_UI/42_ActionPad/200_ActionPad_Core
- Deathwish Kit/40_UI/42_ActionPad/210_ActionPad_PeerState
- Deathwish Kit/40_UI/42_ActionPad/220_ActionPad_Actions
- Deathwish Kit/40_UI/42_ActionPad/240_ActionPad_UI
- Deathwish Kit/BootSummary_Core
- generic_mapper/Map Script
- gui-drop/workaround for add
