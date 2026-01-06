# Command Registry

## Version
v1.3

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

## Runtime Usage (dev harness / Mudlet input line)
- List all:  lua DWKit.cmd.listAll()
- List SAFE: lua DWKit.cmd.listSafe()
- List GAME: lua DWKit.cmd.listGame()
- Help:      lua DWKit.cmd.help("dwtest")

## Typed SAFE Commands (avoid collision with MUD "commands")
- dwcommands [safe|game]
- dwhelp <cmd>

## Command List
- dwcommands
- dwhelp
- dwinfo
- dwtest

## Command Details

### dwcommands
- Command: dwcommands
- Aliases: (none)
- Owner Module: dwkit.services.command_aliases
- Description: Lists registered DWKit commands (ALL, SAFE, or GAME).
- Usage: dwcommands [safe|game]
- Example: dwcommands safe
- Notes:
  - SAFE (no gameplay output sent)
  - Manual only
  - Implemented as a Mudlet alias (local only), installed by loader.init()
  - Backed by DWKit.cmd.listAll/listSafe/listGame

### dwhelp
- Command: dwhelp
- Aliases: (none)
- Owner Module: dwkit.services.command_aliases
- Description: Shows detailed help for one DWKit command.
- Usage: dwhelp <cmd>
- Example: dwhelp dwtest
- Notes:
  - SAFE (no gameplay output sent)
  - Manual only
  - Implemented as a Mudlet alias (local only), installed by loader.init()
  - Backed by DWKit.cmd.help(name)

### dwinfo
- Command: dwinfo
- Aliases: (none)
- Owner Module: dwkit.core.runtime_baseline
- Description: Prints runtime baseline info (Lua + Mudlet version) for verification and support.
- Usage: lua DWKit.core.runtimeBaseline.printInfo()
- Example: lua DWKit.core.runtimeBaseline.printInfo()
- Notes:
  - SAFE (no gameplay output sent)
  - Manual only
  - This is currently a dev helper invoked via Mudlet's `lua ...` input line. It will be wired into the package command system later.

### dwtest
- Command: dwtest
- Aliases: (none)
- Owner Module: dwkit.tests.self_test_runner
- Description: Runs DWKit self-test runner (smoke checks + compatibility baseline output).
- Usage: lua DWKit.test.run()
- Example: lua DWKit.test.run()
- Notes:
  - SAFE (no gameplay output sent)
  - Manual only
  - Requires loader init to have run (so DWKit.test.run is attached). If missing, check DWKit.test._selfTestLoadError.

## Command Template (copy/paste)
- Command:
- Aliases:
- Owner Module:
- Description:
- Usage:
- Example:
- Notes:
