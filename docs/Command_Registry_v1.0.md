# docs/Command_Registry_v1.0.md
# Command Registry

## Version
v3.1

## Purpose
This document is the canonical registry of all user-facing commands.
If a command is not registered here, it does not exist.

## Rules
- All commands must be registered here first.
- Do not add aliases silently. Document them.
- Commands must have a single owner module.
- Runtime listing/help must derive from the same registry data structure:
  - Source of truth (code): dwkit.bus.command_registry
  - Runtime surface: DWKit.cmd (after loader init)
- Docs/runtime sync rule (required):
  - Any invocation variants, syntax, examples, safety/mode classification, SendsToGame flag, or behavioral notes recorded in this document MUST be mirrored in dwkit.bus.command_registry in the same change set (no drift).
- Naming scheme (locked):
  - Typed commands are prefixed with "dw" to avoid collisions with the MUD's own commands.
  - The canonical discovery surface is: dwcommands + dwhelp.
- Safety taxonomy (locked):
  - SAFE: no gameplay commands sent to the MUD
  - COMBAT-SAFE: sends to game, designed to be safe in combat, but still has side effects
  - NOT SAFE: sends to game and may have stronger side effects/spam risk

## Canonical Identity (Authoritative)
- Source of truth: docs/PACKAGE_IDENTITY.md
- PackageId (require prefix), EventPrefix, DataFolderName, and VersionTagStyle are locked there.

## Section S Compliance Notes
- Two command types are supported by this registry:
  A) Kit Commands (SAFE diagnostics, config, UI control, tests)
  B) Gameplay Command Wrappers (send commands to the MUD; must be explicitly labeled)
- Current status:
  - Gameplay Command Wrappers: PRESENT (as of v3.1)
  - Current wrapper(s): dwprompt (manual; COMBAT-SAFE; sendsToGame=YES)
- Any new gameplay wrapper MUST include the extra wrapper fields in the Command Template.

## Runtime Export (Docs Sync Helper) (SAFE)
The runtime can print a Markdown export derived from the same command registry data.

- Export full command registry Markdown:
  - dwcommands md

Notes:
- This is a copy/paste helper for maintaining docs sync. It does not change runtime behavior.
- Filtering views remain:
  - dwcommands
  - dwcommands safe
  - dwcommands game

## Drift-Lock Rules (Enforced by dwtest quiet)
These rules are enforced in runtime by the self-test runner in quiet mode (registry-only checks; no gameplay commands sent).

### SAFE command set (current expected set)
- Expected SAFE commands (26):
  - dwactions
  - dwboot
  - dwchat
  - dwcommands
  - dwdiag
  - dwgui
  - dwhelp
  - dwid
  - dwinfo
  - dwpresence
  - dwrelease
  - dwroom
  - dwscorestore
  - dwservices
  - dwsetup
  - dwskills
  - dwtest
  - dwui
  - dwversion
  - dwevent
  - dweventlog
  - dwevents
  - dweventsub
  - dweventtap
  - dweventunsub
  - dwwho

### SAFE command contract (required fields)
For each command in the SAFE set above, the command definition in dwkit.bus.command_registry MUST satisfy:
- command exists in registry
- SendsToGame == NO
- Safety == SAFE
- Mode is non-empty
- Owner Module is non-empty
- Syntax is non-empty
- Description is non-empty

Notes:
- dwtest quiet enforces this per-command contract and will FAIL if any are missing/incorrect.
- dwcommands safe output MUST be consistent with registry filtering (SendsToGame == NO).

### GAME wrapper drift-lock framework
The registry supports gameplay wrapper commands (SendsToGame == YES).

1) GAME list queryable:
- dwcommands game MUST run and list the current registry-filtered GAME set (SendsToGame == YES)
- When empty, it must print "(none)" and self-test must PASS.

2) GAME list consistency:
- The GAME list derived from dwcommands game MUST match the registry filter for SendsToGame == YES.
- If they differ, dwtest quiet MUST FAIL.

3) GAME wrapper contract (required when a wrapper exists)
For each command where SendsToGame == YES, the command definition MUST satisfy:
- command exists in registry
- SendsToGame == YES
- Safety is NOT "SAFE" (must be COMBAT-SAFE or NOT SAFE)
- underlyingGameCommand is non-empty
- sideEffects is non-empty
- Mode is non-empty
- Owner Module is non-empty
- Syntax is non-empty
- Description is non-empty

## Command List
- dwcommands
- dwhelp
- dwid
- dwinfo
- dwtest
- dwversion
- dwdiag
- dwgui
- dwevents
- dwevent
- dweventtap
- dweventsub
- dweventunsub
- dweventlog
- dwboot
- dwservices
- dwpresence
- dwwho
- dwprompt
- dwroom
- dwactions
- dwskills
- dwscorestore
- dwchat
- dwui
- dwrelease
- dwsetup

## Command Details

### dwactions
- Command: dwactions
- Aliases: (none)
- Owner Module: dwkit.commands.dwactions
- Description: Prints ActionModelService snapshot (best-effort, SAFE).
- Syntax: dwactions
- Safety: SAFE
- Mode: manual
- SendsToGame: NO
- Examples:
  - dwactions
- Notes:
  - Implemented as a Mudlet alias (local only).
  - Prefers ActionModelService.getState() if available; otherwise prints available API keys.

### dwboot
- Command: dwboot
- Aliases: (none)
- Owner Module: dwkit.commands.dwboot
- Description: Prints DWKit boot wiring/health status (SAFE diagnostics).
- Syntax: dwboot
- Safety: SAFE
- Mode: manual
- SendsToGame: NO
- Examples:
  - dwboot
- Notes:
  - Typed alias implemented by dwkit.services.command_aliases.
  - Reports which DWKit surfaces are attached and any loader/init load errors.
  - Does not emit gameplay commands.

### dwchat
- Command: dwchat
- Aliases: (none)
- Owner Module: dwkit.commands.dwchat
- Description: Controls the DWKit Chat UI (chat_ui): open/hide/toggle/status, enable/disable, tabs, clear, and SAFE input toggles (send/input).
- Syntax: dwchat [open|show|hide|close|toggle|status|enable|disable|tabs|tab <name>|clear|send on|off|input on|off]
- Safety: SAFE
- Mode: manual
- SendsToGame: NO
- Examples:
  - dwchat
  - dwchat status
  - dwchat hide
  - dwchat toggle
  - dwchat enable
  - dwchat disable
  - dwchat tabs
  - dwchat tab SAY
  - dwchat tab Other
  - dwchat clear
  - dwchat send on
  - dwchat send off
  - dwchat input off
  - dwchat input on
- Notes:
  - Phase 1 deterministic command surface for chat_ui.
  - Prefers ui_manager.applyOne("chat_ui") when available so dependency claims (chat_watch) are handled centrally.
  - Visible is session-only by default (noSave=true). Enabled is persisted when explicitly opened/enabled.
  - send on|off only flips chat_ui sendToMud flag; sending to MUD only occurs on explicit user Enter submit (still manual).
  - input on|off is best-effort and depends on chat_ui exposing setter APIs.

### dwcommands
- Command: dwcommands
- Aliases: (none)
- Owner Module: dwkit.commands.dwcommands
- Description: Lists registered DWKit commands (ALL, SAFE, GAME) or prints Markdown export (SAFE).
- Syntax: dwcommands [safe|game|md]
- Safety: SAFE
- Mode: manual
- SendsToGame: NO
- Examples:
  - dwcommands
  - dwcommands safe
  - dwcommands game
  - dwcommands md
- Notes:
  - Implemented as a Mudlet alias (local only).
  - Backed by DWKit.cmd.listAll/listSafe/listGame.
  - dwcommands safe uses registry filter: sendsToGame == false.
  - dwcommands game uses registry filter: sendsToGame == true.
  - Markdown export is backed by DWKit.cmd.toMarkdown().

### dwdiag
- Command: dwdiag
- Aliases: (none)
- Owner Module: dwkit.commands.dwdiag
- Description: Prints a one-shot diagnostic bundle (dwversion + dwboot + dwservices + event diag status).
- Syntax: dwdiag
- Safety: SAFE
- Mode: manual
- SendsToGame: NO
- Examples:
  - dwdiag
- Notes:
  - Intended for copy/paste into issues or chat handovers.
  - MUST remain SAFE and manual-only (no timers, no auto-tap enable).
  - Implementation should call existing SAFE printers and keep output bounded.

### dwevent
- Command: dwevent
- Aliases: (none)
- Owner Module: dwkit.commands.dwevent
- Description: Shows detailed help for one DWKit event (SAFE).
- Syntax: dwevent <EventName>
- Safety: SAFE
- Mode: manual
- SendsToGame: NO
- Examples:
  - dwevent DWKit:Boot:Ready
- Notes:
  - Typed alias implemented by dwkit.services.command_aliases.
  - Backed by DWKit.bus.eventRegistry.help(eventName).
  - EventName must be the full registered name (must start with DWKit:).

### dweventlog
- Command: dweventlog
- Aliases: (none)
- Owner Module: dwkit.commands.dweventlog
- Description: Prints the bounded event diagnostics log (SAFE).
- Syntax: dweventlog [n]
- Safety: SAFE
- Mode: manual
- SendsToGame: NO
- Examples:
  - dweventlog
  - dweventlog 25
- Notes:
  - Implemented as a Mudlet alias (local only).
  - Prints the last n log entries (default 10, capped at 50).
  - Log includes entries from both tap and per-event subscriptions.

### dwevents
- Command: dwevents
- Aliases: (none)
- Owner Module: dwkit.commands.dwevents
- Description: Lists registered DWKit events (SAFE) or prints Markdown export (SAFE).
- Syntax: dwevents [md]
- Safety: SAFE
- Mode: manual
- SendsToGame: NO
- Examples:
  - dwevents
  - dwevents md
- Notes:
  - Typed alias implemented by dwkit.services.command_aliases.
  - Backed by DWKit.bus.eventRegistry.listAll().
  - Markdown export is backed by DWKit.bus.eventRegistry.toMarkdown().

### dweventsub
- Command: dweventsub
- Aliases: (none)
- Owner Module: dwkit.commands.dweventsub
- Description: Subscribes (SAFE) to one DWKit event and records occurrences into the bounded log (SAFE diagnostics).
- Syntax: dweventsub <EventName>
- Safety: SAFE
- Mode: manual
- SendsToGame: NO
- Examples:
  - dweventsub DWKit:Service:Presence:Updated
  - dweventsub DWKit:Boot:Ready
- Notes:
  - Implemented as a Mudlet alias (local only).
  - Backed by DWKit.bus.eventBus.on(eventName, fn).
  - EventName must be registered and must start with DWKit:.
  - Use dweventlog to inspect recorded payloads.

### dweventtap
- Command: dweventtap
- Aliases: (none)
- Owner Module: dwkit.commands.dweventtap
- Description: Controls a SAFE event bus tap (observe all events) and a bounded in-memory log (SAFE diagnostics).
- Syntax: dweventtap [on|off|status|show|clear] [n]
- Safety: SAFE
- Mode: manual
- SendsToGame: NO
- Examples:
  - dweventtap status
  - dweventtap on
  - dweventtap show 10
  - dweventtap clear
  - dweventtap off
- Notes:
  - Implemented as a Mudlet alias (local only).
  - Backed by DWKit.bus.eventBus.tapOn/tapOff (best-effort, SAFE).
  - Tap does not change delivery semantics for normal subscribers.
  - Log output is bounded; default show prints last 10 entries.

### dweventunsub
- Command: dweventunsub
- Aliases: (none)
- Owner Module: dwkit.commands.dweventunsub
- Description: Unsubscribes (SAFE) from one DWKit event or all subscriptions (SAFE diagnostics).
- Syntax: dweventunsub <EventName|all>
- Safety: SAFE
- Mode: manual
- SendsToGame: NO
- Examples:
  - dweventunsub DWKit:Service:Presence:Updated
  - dweventunsub all
- Notes:
  - Implemented as a Mudlet alias (local only).
  - Backed by DWKit.bus.eventBus.off(token).
  - Does not affect event tap; use dweventtap off for that.

### dwgui
- Command: dwgui
- Aliases: (none)
- Owner Module: dwkit.commands.dwgui
- Description: Manage GUI settings flags (enabled/visible) per UI id (SAFE config only; no UI actions).
- Syntax: dwgui [status|list|enable <uiId>|disable <uiId>|visible <uiId> on|off]
- Safety: SAFE
- Mode: manual
- SendsToGame: NO
- Examples:
  - dwgui
  - dwgui status
  - dwgui list
  - dwgui enable test_ui
  - dwgui disable test_ui
  - dwgui visible test_ui on
  - dwgui visible test_ui off
- Notes:
  - Typed alias implemented by dwkit.services.command_aliases.
  - Backed by DWKit.config.guiSettings (dwkit.config.gui_settings).
  - This command only changes stored flags; it does NOT show/hide UI elements directly.
  - Visible control requires visible persistence to be enabled in guiSettings; dwgui enables it on-demand for visible subcommands.

### dwhelp
- Command: dwhelp
- Aliases: (none)
- Owner Module: dwkit.commands.dwhelp
- Description: Shows detailed help for one DWKit command.
- Syntax: dwhelp <cmd>
- Safety: SAFE
- Mode: manual
- SendsToGame: NO
- Examples:
  - dwhelp dwtest
  - dwhelp dwinfo
- Notes:
  - Implemented as a Mudlet alias (local only).
  - Backed by DWKit.cmd.help(name).

### dwid
- Command: dwid
- Aliases: (none)
- Owner Module: dwkit.core.identity
- Description: Prints canonical DWKit identity (packageId/eventPrefix/data folder/tag style).
- Syntax: dwid
- Safety: SAFE
- Mode: manual
- SendsToGame: NO
- Examples:
  - dwid
- Notes:
  - Typed alias implemented by dwkit.services.command_aliases.
  - Prints the same locked identity fields as shown in dwtest.

### dwinfo
- Command: dwinfo
- Aliases: (none)
- Owner Module: dwkit.core.runtime_baseline
- Description: Prints runtime baseline info (Lua + Mudlet version) for verification and support.
- Syntax: dwinfo  (or: lua DWKit.core.runtimeBaseline.printInfo())
- Safety: SAFE
- Mode: manual
- SendsToGame: NO
- Examples:
  - dwinfo
  - lua DWKit.core.runtimeBaseline.printInfo()
- Notes:
  - Typed alias implemented by dwkit.services.command_aliases.
  - Dev helper also works via Mudlet input line with lua prefix.

### dwpresence
- Command: dwpresence
- Aliases: (none)
- Owner Module: dwkit.commands.dwpresence
- Description: Prints PresenceService snapshot (best-effort, SAFE).
- Syntax: dwpresence
- Safety: SAFE
- Mode: manual
- SendsToGame: NO
- Examples:
  - dwpresence
- Notes:
  - Implemented as a Mudlet alias (local only).
  - Prefers PresenceService.getState() if available; otherwise prints available API keys.

### dwprompt
- Command: dwprompt
- Aliases: (none)
- Owner Module: dwkit.commands.dwprompt
- Description: Prompt utilities: refresh captures current MUD prompt (supports multi-line) and updates PromptDetector stored prompt.
- Syntax: dwprompt [status|refresh]
- Safety: COMBAT-SAFE
- Mode: manual
- SendsToGame: YES
- Examples:
  - dwprompt
  - dwprompt status
  - dwprompt refresh
- Notes:
  - This is a manual gameplay wrapper (sendsToGame=true) used to seed PromptDetector so passive captures can detect custom prompts.
  - Typed alias implemented by dwkit.services.command_aliases.
  - If PromptDetector is unconfigured, roomfeed passive capture may fail to finalize (abort:max_lines) for non-<...> prompts.
- underlyingGameCommand:
  - prompt
- sideEffects:
  - Sends 'prompt' to the MUD and prints current prompt (may be multi-line). No gameplay state change expected.

### dwrelease
- Command: dwrelease
- Aliases: (none)
- Owner Module: dwkit.commands.dwrelease
- Description: Prints a bounded release checklist + version pointers + tag workflow reminder (SAFE).
- Syntax: dwrelease
- Safety: SAFE
- Mode: manual
- SendsToGame: NO
- Examples:
  - dwrelease
- Notes:
  - SAFE/manual only: prints guidance, does not run git or create tags.
  - Intended as a copy/paste friendly reminder for PR + tag discipline.
  - Typed alias implemented by dwkit.services.command_aliases.

### dwroom
- Command: dwroom
- Aliases: (none)
- Owner Module: dwkit.commands.dwroom
- Description: Shows and manages RoomEntities state (SAFE diagnostics/fixtures/refresh; no gameplay commands).
- Syntax: dwroom
- Safety: SAFE
- Mode: manual
- SendsToGame: NO
- Examples:
  - dwroom
- Notes:
  - Implemented as a Mudlet alias (local only).
  - Backed by RoomEntitiesService (dwkit.services.roomentities_service) and SAFE helpers.
  - Used for fixture/ingest/refresh workflows; no gameplay commands are sent.

### dwscorestore
- Command: dwscorestore
- Aliases: (none)
- Owner Module: dwkit.commands.dwscorestore
- Description: Shows and manages ScoreStoreService state + persistence (SAFE).
- Syntax: dwscorestore [status|persist on|off|status|fixture [basic]|clear|wipe [disk]|reset [disk]]  (or: lua DWKit.services.scoreStoreService.printSummary())
- Safety: SAFE
- Mode: manual
- SendsToGame: NO
- Examples:
  - dwscorestore
  - dwscorestore status
  - dwscorestore persist status
  - dwscorestore fixture basic
  - lua DWKit.services.scoreStoreService.ingestFromText("SCORE TEST",{source="manual"})
  - lua DWKit.services.scoreStoreService.printSummary()
- Notes:
  - Backed by dwkit.services.score_store_service (ScoreStoreService).
  - Subcommands are implemented by dwkit.services.command_aliases and call ScoreStoreService methods (still SAFE; no gameplay commands sent).
  - Score snapshots may be ingested via passive capture installed during loader.init (capture is SAFE; it only reacts to your score output).
  - In case the alias is stale/cached, you can use the lua fallback above after loader init.

### dwservices
- Command: dwservices
- Aliases: (none)
- Owner Module: dwkit.commands.dwservices
- Description: Lists attached DWKit services + versions + load errors (SAFE diagnostics).
- Syntax: dwservices
- Safety: SAFE
- Mode: manual
- SendsToGame: NO
- Examples:
  - dwservices
- Notes:
  - Implemented as a Mudlet alias (local only).
  - Inspection only; no gameplay output; no automation.

### dwsetup
- Command: dwsetup
- Aliases: (none)
- Owner Module: dwkit.commands.dwsetup
- Description: Runs a one-shot bootstrap checklist for fresh profiles (owned_profiles + WhoStore + next actions).
- Syntax: dwsetup [status|help]
- Safety: SAFE
- Mode: manual
- SendsToGame: NO
- Examples:
  - dwsetup
  - dwsetup status
  - dwsetup help
- Notes:
  - Typed alias auto-generated from registry (dwkit.services.alias_factory).
  - Default run calls dwwho refresh once (approved pathway) then instructs you to type 'look' once (passive capture).
  - Does not guess or auto-seed owned_profiles; prints explicit example only.
  - Best-effort triggers Presence + RoomEntities refresh emissions so UIs re-render.

### dwskills
- Command: dwskills
- Aliases: (none)
- Owner Module: dwkit.commands.dwskills
- Description: Prints SkillRegistryService snapshot (best-effort, SAFE).
- Syntax: dwskills
- Safety: SAFE
- Mode: manual
- SendsToGame: NO
- Examples:
  - dwskills
- Notes:
  - Implemented as a Mudlet alias (local only).
  - Prefers SkillRegistryService.getState() or getAll() if available; otherwise prints available API keys.

### dwtest
- Command: dwtest
- Aliases: (none)
- Owner Module: dwkit.tests.self_test_runner
- Description: Runs DWKit self-test runner (smoke checks + compatibility baseline output).
- Syntax: dwtest  (or: lua DWKit.test.run())  (quiet: lua local T=require("dwkit.tests.self_test_runner"); T.run({quiet=true}))
- Safety: SAFE
- Mode: manual
- SendsToGame: NO
- Examples:
  - dwtest
  - dwtest ui
  - lua DWKit.test.run()
  - lua local T=require("dwkit.tests.self_test_runner"); T.run({quiet=true})
- Notes:
  - Typed alias implemented by dwkit.services.command_aliases.
  - Requires loader init to have run (so DWKit.test.run is attached).
  - If missing, check DWKit.test._selfTestLoadError.
  - Quiet mode MUST avoid full registry listing output and prefer count-only registry checks (no list spam).
  - Upcoming scope: dwtest ui runs UI Safety Gate checks (validator wiring + contract compliance).

### dwui
- Command: dwui
- Aliases: (none)
- Owner Module: dwkit.commands.dwui
- Description: Opens the UI Manager UI surface (ui_manager_ui).
- Syntax: dwui  (or: dwui open)
- Safety: SAFE
- Mode: manual
- SendsToGame: NO
- Examples:
  - dwui
  - dwui open
- Notes:
  - Typed alias implemented by dwkit.services.command_aliases.
  - Ensures ui_manager_ui enabled=ON (persisted) and visible=ON (session-only) then applies via ui_manager if available.

### dwversion
- Command: dwversion
- Aliases: (none)
- Owner Module: dwkit.commands.dwversion
- Description: Prints consolidated DWKit module versions + runtime baseline (SAFE diagnostics).
- Syntax: dwversion
- Safety: SAFE
- Mode: manual
- SendsToGame: NO
- Examples:
  - dwversion
- Notes:
  - Typed alias implemented by dwkit.services.command_aliases.
  - Prints identity/runtimeBaseline/self_test_runner/command registry versions where available.
  - Also prints eventRegistry/eventBus versions when present.

### dwwho
- Command: dwwho
- Aliases: (none)
- Owner Module: dwkit.commands.dwwho
- Description: Shows and manages WhoStore state (SAFE diagnostics and fixtures; no gameplay commands).
- Syntax: dwwho
- Safety: SAFE
- Mode: manual
- SendsToGame: NO
- Examples:
  - dwwho
- Notes:
  - Implemented as a Mudlet alias (local only).
  - Backed by WhoStoreService (dwkit.services.whostore_service) and SAFE helpers.
  - Intended for inspection, fixtures, and state debug; no automation.

## Command Template (copy/paste)
- Command:
- Aliases:
- Owner Module:
- Description:
- Syntax:
- Examples:
- Safety: (SAFE | COMBAT-SAFE | NOT SAFE)
- Mode: (manual | opt-in | auto)
- SendsToGame: (YES | NO)
- Notes:

### Gameplay Wrapper Fields (required when SendsToGame=YES)
- underlyingGameCommand:
- sideEffects:
- rateLimit:
- wrapperOf: