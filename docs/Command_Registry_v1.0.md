# Command Registry

## Version
v1.7

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
- Typed commands are prefixed with "dw" to avoid collisions with the MUD's own commands.

## Command List
- dwcommands
- dwhelp
- dwid
- dwinfo
- dwtest
- dwversion
- dwevents
- dwevent

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
- Examples:
  - dwtest
  - lua DWKit.test.run()
- Safety: SAFE (no gameplay output sent)
- Mode: manual
- SendsToGame: NO
- Notes:
  - Typed alias implemented by dwkit.services.command_aliases.
  - Requires loader init to have run (so DWKit.test.run is attached). If missing, check DWKit.test._selfTestLoadError.

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

## Command Template (copy/paste)
- Command:
- Aliases:
- Owner Module:
- Description:
- Syntax:
- Examples:
- Safety:
- Mode:
- SendsToGame:
- Notes:
