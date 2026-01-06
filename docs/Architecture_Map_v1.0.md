# Architecture Map

## Version
v1.3

## Purpose
High-level map of the DWKit layout: what each folder is for, and what depends on what.
This is a lightweight reference for contributors and for chat handoffs.

## Canonical Identity (Authoritative)
- PackageRootGlobal: DWKit
- PackageId (require prefix): dwkit
- EventPrefix: DWKit:
- DataFolderName: dwkit
- VersionTagStyle: Calendar (vYYYY-MM-DDX)

## Canonical Layout (Logical)
- src/core           (logging, safe calls, helpers)
- src/config         (config surface, defaults, profile overrides)
- src/persist        (paths, schema IO, migrations helpers)
- src/bus            (event registry, event bus, command registry)
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

- Canonical identity module:
  - src/dwkit/core/identity.lua
  - Single authoritative identity values (must match docs/PACKAGE_IDENTITY.md).

- Compatibility baseline:
  - src/dwkit/core/runtime_baseline.lua
  - Prints: packageId + Lua version + Mudlet version (safe formatting).
  - packageId is sourced from dwkit.core.identity (output unchanged).

- Event registry (SAFE, registry only):
  - src/dwkit/bus/event_registry.lua
  - Code mirror of docs/Event_Registry_v1.0.md.
  - No events exist yet (registry is empty).

- Event bus skeleton (SAFE, internal only):
  - src/dwkit/bus/event_bus.lua
  - In-process publish/subscribe.
  - Enforces: event MUST be registered in event_registry before use.

- Self-test runner (SAFE):
  - src/dwkit/tests/self_test_runner.lua
  - Smoke checks + prints compatibility baseline.
  - Prints canonical identity fields for verification.

- Command registry runtime surface (SAFE):
  - src/dwkit/bus/command_registry.lua
  - Runtime list/help derived from registry data.
  - Exposes registry version accessor (getRegistryVersion) for SAFE diagnostics.

- Typed SAFE aliases:
  - src/dwkit/services/command_aliases.lua
  - dwcommands, dwhelp <cmd>, dwtest, dwinfo, dwid, dwversion

## Guardrails (Important)
- Do NOT add events unless the event is registered first in docs/Event_Registry_v1.0.md and complies with EventPrefix (DWKit:).
- Do NOT expand package persistence unless it is per-profile under DataFolderName (dwkit) and includes explicit schema/versioning per the standard.
- Manual means manual: no timers, no auto-login, no gameplay commands unless explicitly introduced as wrappers.
