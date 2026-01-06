# Event Registry

## Version
v1.2

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
None.

Reason:
- No events have been introduced yet.
- Registry and bus skeleton exist to enforce “docs-first” event introduction.
