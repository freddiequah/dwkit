# Command Registry

## Version
v2.6

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
  - Gameplay Command Wrappers: NONE (as of v2.6)
- Any new gameplay wrapper MUST include the extra wrapper fields in the Command Template.

## Drift-Lock Rules (Enforced by dwtest quiet)
These rules are enforced in runtime by the self-test runner in quiet mode (registry-only checks; no gameplay commands sent).

### SAFE command set (current expected set)
- Expected SAFE commands (14):
  - dwactions
  - dwboot
  - dwcommands
  - dwevent
  - dwevents
  - dwhelp
  - dwid
  - dwinfo
  - dwpresence
  - dwscorestore
  - dwservices
  - dwskills
  - dwtest
  - dwversion

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

### GAME wrapper drift-lock framework (even if empty today)
The registry supports gameplay wrapper commands (SendsToGame == YES). Even if the GAME list is empty today, the framework rules are locked:

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
- dwevents
- dwevent
- dwboot
- dwservices
- dwpresence
- dwactions
- dwskills
- dwscorestore

## Command Details

### dwcommands
- Command: dwcommands
- Aliases: (none)
- Owner Module: dwkit.services.command_aliases
- Description: Lists registered DWKit commands (ALL, SAFE, or GAME).
- Syntax: dwcommands [safe|game]
- Examples:
  - dwcommands
  - dwcommands safe
  - dwcommands game
- Safety: SAFE (no gameplay output sent)
- Mode: manual
- SendsToGame: NO
- Notes:
  - Implemented as a Mudlet alias (local only).
  - Backed by DWKit.cmd.listAll/listSafe/listGame.
  - dwcommands safe uses registry filter: SendsToGame == NO.
  - dwcommands game uses registry filter: SendsToGame == YES.

### dwhelp
- Command: dwhelp
- Aliases: (none)
- Owner Module: dwkit.services.command_aliases
- Description: Shows detailed help for one DWKit command.
- Syntax: dwhelp <cmd>
- Examples:
  - dwhelp dwtest
  - dwhelp dwinfo
- Safety: SAFE (no gameplay output sent)
- Mode: manual
- SendsToGame: NO
- Notes:
  - Implemented as a Mudlet alias (local only).
  - Backed by DWKit.cmd.help(name).

### dwid
- Command: dwid
- Aliases: (none)
- Owner Module: dwkit.core.identity
- Description: Prints canonical DWKit identity (packageId/eventPrefix/data folder/tag style).
- Syntax:
  - dwid
- Examples:
  - dwid
- Safety: SAFE (no gameplay output sent)
- Mode: manual
- SendsToGame: NO
- Notes:
  - Typed alias implemented by dwkit.services.command_aliases.
  - Prints the same locked identity fields as shown in dwtest.

### dwinfo
- Command: dwinfo
- Aliases: (none)
- Owner Module: dwkit.core.runtime_baseline
- Description: Prints runtime baseline info (Lua + Mudlet version) for verification and support.
- Syntax:
  - dwinfo
  - (or) lua DWKit.core.runtimeBaseline.printInfo()
- Examples:
  - dwinfo
  - lua DWKit.core.runtimeBaseline.printInfo()
- Safety: SAFE (no gameplay output sent)
- Mode: manual
- SendsToGame: NO
- Notes:
  - Typed alias implemented by dwkit.services.command_aliases.

### dwtest
- Command: dwtest
- Aliases: (none)
- Owner Module: dwkit.tests.self_test_runner
- Description: Runs DWKit self-test runner (smoke checks + compatibility baseline output).
- Syntax:
  - dwtest
  - (or) lua DWKit.test.run()
  - (quiet) lua local T=require("dwkit.tests.self_test_runner"); T.run({quiet=true})
- Examples:
  - dwtest
  - lua DWKit.test.run()
  - lua local T=require("dwkit.tests.self_test_runner"); T.run({quiet=true})
- Safety: SAFE (no gameplay output sent)
- Mode: manual
- SendsToGame: NO
- Notes:
  - Typed alias implemented by dwkit.services.command_aliases.
  - Requires loader init to have run (so DWKit.test.run is attached). If missing, check DWKit.test._selfTestLoadError.
  - Required output sections + PASS/FAIL criteria are specified in: docs/Self_Test_Runner_v1.0.md
  - Quiet mode MUST avoid full registry listing output and prefer count-only registry checks.
  - dwtest quiet enforces:
    - SAFE command set presence and per-command contract fields
    - GAME wrapper drift-lock framework (even when empty)
  - Docs/runtime sync reminder: the dwtest syntax/examples/notes in this document must match dwkit.bus.command_registry.

### dwversion
- Command: dwversion
- Aliases: (none)
- Owner Module: dwkit.services.command_aliases
- Description: Prints consolidated DWKit module versions + runtime baseline (SAFE diagnostics).
- Syntax:
  - dwversion
- Examples:
  - dwversion
- Safety: SAFE (no gameplay output sent)
- Mode: manual
- SendsToGame: NO
- Notes:
  - Typed alias implemented by dwkit.services.command_aliases.
  - Prints versions for identity/runtimeBaseline/self_test_runner/command registry where available.
  - Also prints eventRegistry/eventBus versions when present.

### dwevents
- Command: dwevents
- Aliases: (none)
- Owner Module: dwkit.services.command_aliases
- Description: Lists registered DWKit events (SAFE).
- Syntax:
  - dwevents
- Examples:
  - dwevents
- Safety: SAFE (no gameplay output sent)
- Mode: manual
- SendsToGame: NO
- Notes:
  - Typed alias implemented by dwkit.services.command_aliases.
  - Backed by DWKit.bus.eventRegistry.listAll().

### dwevent
- Command: dwevent
- Aliases: (none)
- Owner Module: dwkit.services.command_aliases
- Description: Shows detailed help for one DWKit event (SAFE).
- Syntax:
  - dwevent <EventName>
- Examples:
  - dwevent DWKit:Boot:Ready
- Safety: SAFE (no gameplay output sent)
- Mode: manual
- SendsToGame: NO
- Notes:
  - Typed alias implemented by dwkit.services.command_aliases.
  - Backed by DWKit.bus.eventRegistry.help(eventName).
  - EventName must be the full registered name (must start with DWKit:).

### dwboot
- Command: dwboot
- Aliases: (none)
- Owner Module: dwkit.services.command_aliases
- Description: Prints DWKit boot wiring/health status (SAFE diagnostics).
- Syntax:
  - dwboot
- Examples:
  - dwboot
- Safety: SAFE (no gameplay output sent)
- Mode: manual
- SendsToGame: NO
- Notes:
  - Typed alias implemented by dwkit.services.command_aliases.
  - Reports which DWKit surfaces are attached and any loader/init load errors.
  - Does not emit gameplay commands.

### dwservices
- Command: dwservices
- Aliases: (none)
- Owner Module: dwkit.services.command_aliases
- Description: Lists attached DWKit services + versions + load errors (SAFE diagnostics).
- Syntax:
  - dwservices
- Examples:
  - dwservices
- Safety: SAFE (no gameplay output sent)
- Mode: manual
- SendsToGame: NO
- Notes:
  - Implemented as a Mudlet alias (local only).
  - Inspection only; no gameplay output; no automation.

### dwpresence
- Command: dwpresence
- Aliases: (none)
- Owner Module: dwkit.services.command_aliases
- Description: Prints PresenceService snapshot (best-effort, SAFE).
- Syntax:
  - dwpresence
- Examples:
  - dwpresence
- Safety: SAFE (no gameplay output sent)
- Mode: manual
- SendsToGame: NO
- Notes:
  - Implemented as a Mudlet alias (local only).
  - Prefers PresenceService.getState() if available; otherwise prints available API keys.

### dwactions
- Command: dwactions
- Aliases: (none)
- Owner Module: dwkit.services.command_aliases
- Description: Prints ActionModelService snapshot (best-effort, SAFE).
- Syntax:
  - dwactions
- Examples:
  - dwactions
- Safety: SAFE (no gameplay output sent)
- Mode: manual
- SendsToGame: NO
- Notes:
  - Implemented as a Mudlet alias (local only).
  - Prefers ActionModelService.getState() if available; otherwise prints available API keys.

### dwskills
- Command: dwskills
- Aliases: (none)
- Owner Module: dwkit.services.command_aliases
- Description: Prints SkillRegistryService snapshot (best-effort, SAFE).
- Syntax:
  - dwskills
- Examples:
  - dwskills
- Safety: SAFE (no gameplay output sent)
- Mode: manual
- SendsToGame: NO
- Notes:
  - Implemented as a Mudlet alias (local only).
  - Prefers SkillRegistryService.getState() or getAll() if available; otherwise prints available API keys.

### dwscorestore
- Command: dwscorestore
- Aliases: (none)
- Owner Module: dwkit.services.command_aliases
- Description: Prints ScoreStoreService snapshot summary (best-effort, SAFE).
- Syntax:
  - dwscorestore
  - (or) lua DWKit.services.scoreStoreService.printSummary()
- Examples:
  - dwscorestore
  - lua DWKit.services.scoreStoreService.ingestFromText("SCORE TEST",{source="manual"})
  - lua DWKit.services.scoreStoreService.printSummary()
- Safety: SAFE (no gameplay output sent)
- Mode: manual
- SendsToGame: NO
- Notes:
  - Backed by dwkit.services.score_store_service (ScoreStoreService).
  - In case the alias is stale/cached, you can use the lua fallback above after loader init.
  - Ingest is manual-only and does not send gameplay commands.

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
