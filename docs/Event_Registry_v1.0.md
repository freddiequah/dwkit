# Event Registry

## Version
v1.4

## Purpose
This document is the canonical registry of all project events.
If an event is not registered here first, it does not exist.

## Rules
- All event names MUST start with EventPrefix.
- Events MUST be registered here before being introduced in code.
- Payload fields are contracts. Any payload change requires explicit acknowledgement.
- Producers/consumers should be recorded where known.

## Canonical Identity Status
- EventPrefix: DWKit: (LOCKED)

## Code Surface (SAFE)
- Registry mirror:
  - src/dwkit/bus/event_registry.lua
- Event bus skeleton (internal only):
  - src/dwkit/bus/event_bus.lua
  - Enforces: events must be registered in the registry before subscription or emit.

## Events

### DWKit:Boot:Ready
- Description:
  - Emitted once after loader.init attaches DWKit surfaces.
  - Indicates the kit is ready for manual use.
- PayloadSchema:
  - ts: number (os.time() epoch seconds)
- Producers:
  - dwkit.loader.init
- Consumers:
  - internal (services/ui/tests)
- Notes:
  - SAFE internal event (no gameplay commands).
  - Manual-only: emitted only when loader.init() is invoked.
  - Docs-first: registered here first, then mirrored in code registry.

## Notes
- Registry and bus skeleton exist to enforce "docs-first" event introduction.
