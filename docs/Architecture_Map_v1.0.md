# Architecture Map

## Version
v1.4

## Purpose
High-level map of the DWKit layout: what each folder is for, and what depends on what.
This is a lightweight reference for contributors and for chat handoffs.

## Authoritative Contracts (Docs)
These documents define the current locked contracts and required sync rules:
- docs/PACKAGE_IDENTITY.md
- docs/Command_Registry_v1.0.md
- docs/Event_Registry_v1.0.md
- docs/Self_Test_Runner_v1.0.md
- docs/DOCS_SYNC_CHECKLIST.md
- docs/GOVERNANCE.md

## Canonical Identity (Authoritative)
Source of truth:
- docs/PACKAGE_IDENTITY.md

Locked fields (current):
- PackageRootGlobal: DWKit
- PackageId (require prefix): dwkit
- EventPrefix: DWKit:
- DataFolderName: dwkit
- VersionTagStyle: Calendar (format: vYYYY-MM-DDX)

## Canonical Layout (Logical)
- src/dwkit/core           (logging, safe calls, helpers, identity, runtime baseline)
- src/dwkit/config         (config surface, defaults, profile overrides)
- src/dwkit/persist        (paths, schema IO, migration helpers)
- src/dwkit/bus            (event registry, event bus, command registry)
- src/dwkit/services       (parsers/stores/business logic)
- src/dwkit/ui             (GUI modules, consumer-only)
- src/dwkit/integrations   (optional external integrations; degrade gracefully)
- src/dwkit/tests          (self-test runner helpers)
- src/dwkit/loader         (thin bootstrap scripts / entrypoints)

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
  - Creates/returns global DWKit and attaches core/bus/services surfaces.
  - Manual-only, no automation.

- Canonical identity module:
  - src/dwkit/core/identity.lua
  - Mirrors docs/PACKAGE_IDENTITY.md (values MUST match).

- Compatibility baseline:
  - src/dwkit/core/runtime_baseline.lua
  - Prints: packageId + Lua version + Mudlet version (safe formatting).
  - packageId is sourced from dwkit.core.identity.

- Event registry (SAFE, registry only):
  - src/dwkit/bus/event_registry.lua
  - Code mirror of docs/Event_Registry_v1.0.md.
  - Current registered events (runtime-visible):
    - DWKit:Boot:Ready

- Event bus skeleton (SAFE, internal only):
  - src/dwkit/bus/event_bus.lua
  - In-process publish/subscribe.
  - Enforces: event MUST be registered in event_registry before use.

- Self-test runner (SAFE):
  - src/dwkit/tests/self_test_runner.lua
  - Smoke checks + prints compatibility baseline + canonical identity fields.
  - Supports quiet mode for count-only registry checks (no list spam) per docs/Self_Test_Runner_v1.0.md.

- Command registry runtime surface (SAFE):
  - src/dwkit/bus/command_registry.lua
  - Runtime list/help derived from registry data.
  - Exposes registry version accessor (getRegistryVersion) for SAFE diagnostics.
  - dwtest includes quiet invocation variant in runtime help output.

- Typed SAFE aliases:
  - src/dwkit/services/command_aliases.lua
  - dwcommands [safe|game]
  - dwhelp <cmd>
  - dwid
  - dwinfo
  - dwtest
  - dwversion
  - dwevents
  - dwevent <EventName>
  - dwboot

## Guardrails (Important)
- Do NOT add events unless the event is registered first in docs/Event_Registry_v1.0.md and complies with EventPrefix (DWKit:).
- Do NOT change identity fields unless docs/PACKAGE_IDENTITY.md is version-bumped and a decision is recorded.
- Do NOT expand package persistence unless it is per-profile under DataFolderName (dwkit) and includes explicit schema/versioning per the standard.
- Manual means manual: no timers, no auto-login, no gameplay commands unless explicitly introduced as wrappers.

## Docs/Runtime Sync (No Drift)
- If any invocation variants, syntax, examples, or behavioral notes change in docs/Command_Registry_v1.0.md,
  they MUST be mirrored in src/dwkit/bus/command_registry.lua in the same change set.
- See: docs/DOCS_SYNC_CHECKLIST.md
