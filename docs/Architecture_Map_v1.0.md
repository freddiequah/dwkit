# Architecture Map

## Version
v1.0

## Purpose
High-level map of the DWKit layout: what each folder is for, and what depends on what.
This is a lightweight reference for contributors and for chat handoffs.

## Canonical Identity (Authoritative)
- PackageRootGlobal: DWKit
- PackageId (require prefix): dwkit
- EventPrefix: TBD (REQUIRED before events are introduced)
- DataFolderName: TBD (REQUIRED before package-owned persistence expands)
- VersionTagStyle: TBD (currently observed Calendar-style tags in code, not yet locked)

## Canonical Layout (Logical)
- src/core           (logging, safe calls, helpers)
- src/config         (config surface, defaults, profile overrides)
- src/persist        (paths, schema IO, migrations helpers)
- src/bus            (event registry, command registry)
- src/services       (parsers/stores/business logic)
- src/ui             (GUI modules, consumer-only)
- src/integrations   (optional external integrations; degrade gracefully)
- src/tests          (self-test runner helpers)
- src/loader         (thin bootstrap scripts / entrypoints)

## Layers (No Cycles)
Core -> Persist/Config -> Bus -> Services -> UI

Rules:
- Services MUST NOT depend on UI.
- UI may depend on services via APIs/events.
- No cyclic dependencies.

## Startup / Load Order (Contract)
1) Core utilities
2) Persist + Config
3) Bus (registry modules)
4) GUI Settings (before UI registration)
5) Services
6) UI modules register (gated by settings)
7) LaunchPad restores visibility (opt-in)

## Current Implemented Scope (as of this document)
- Loader init:
  - src/dwkit/loader/init.lua
  - Creates/returns global DWKit and attaches core modules.
  - Manual-only, no automation.

- Compatibility baseline:
  - src/dwkit/core/runtime_baseline.lua
  - Prints: packageId + Lua version + Mudlet version (safe formatting).

- Self-test runner (SAFE):
  - src/dwkit/tests/self_test_runner.lua
  - Smoke checks + prints compatibility baseline.

- Command registry runtime surface (SAFE):
  - src/dwkit/bus/command_registry.lua
  - Runtime list/help derived from registry data.

- Typed SAFE aliases:
  - src/dwkit/services/command_aliases.lua
  - dwcommands, dwhelp <cmd>, dwtest, dwinfo

## Guardrails (Important)
- Do NOT add events until EventPrefix is finalized and recorded in PACKAGE_IDENTITY.md.
- Do NOT expand package persistence until DataFolderName is finalized and recorded in PACKAGE_IDENTITY.md.
- Manual means manual: no timers, no auto-login, no gameplay commands unless explicitly introduced as wrappers.
