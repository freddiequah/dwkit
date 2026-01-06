# Command Registry

## Version
v1.0

## Purpose
This document is the canonical registry of all user-facing commands.
If a command is not registered here, it does not exist.

## Rules
- All commands must be registered here first.
- Do not add aliases silently. Document them.
- Commands must have a single owner module.

## Command List
- dwinfo

## Command Details

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

## Command Template (copy/paste)
- Command:
- Aliases:
- Owner Module:
- Description:
- Usage:
- Example:
- Notes:
