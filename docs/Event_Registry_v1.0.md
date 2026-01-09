# Event Registry

## Version
v1.6

## Purpose
This document is the canonical registry of all project events.
If an event is not registered here first, it does not exist.

## Rules
- All event names MUST start with EventPrefix.
- EventPrefix is locked in docs/PACKAGE_IDENTITY.md (authoritative).
- Events MUST be registered here before being introduced in code.
- Payload fields are contracts. Any payload change requires explicit acknowledgement.
- Producers/consumers should be recorded where known.

## Canonical Identity (Authoritative)
- Source of truth: docs/PACKAGE_IDENTITY.md
- EventPrefix MUST be used for all events in this registry.

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

## Service Spine Events (Gate 2)

### DWKit:Service:Presence:Updated
- Description:
  - Emitted when PresenceService state is updated.
  - SAFE-only; no gameplay commands.
- PayloadSchema:
  - ts: number (os.time() epoch seconds)
  - source: string ("manual" | "integration" | "test")
  - presence: table
    - isOnline: boolean
    - roomName: string|nil
    - roomId: string|nil
    - zone: string|nil
    - partyCount: number|nil
- Producers:
  - dwkit.services.presence_service (future)
- Consumers:
  - (none yet; future UI consumers may subscribe)
- Notes:
  - Contract: payload fields above are stable.
  - Any future additions must be additive or versioned.

### DWKit:Service:ActionModel:Updated
- Description:
  - Emitted when ActionModelService updates the action model snapshot.
  - SAFE-only; no gameplay commands.
- PayloadSchema:
  - ts: number (os.time() epoch seconds)
  - source: string ("manual" | "test")
  - actions: table (list)
    - id: string
    - label: string
    - enabled: boolean
    - cooldownSec: number|nil
- Producers:
  - dwkit.services.action_model_service (future)
- Consumers:
  - (none yet; future UI consumers may subscribe)
- Notes:
  - Contract: this event represents a snapshot update.

### DWKit:Service:SkillRegistry:Updated
- Description:
  - Emitted when SkillRegistryService updates the registry state (data loaded or modified).
  - SAFE-only; no gameplay commands.
- PayloadSchema:
  - ts: number (os.time() epoch seconds)
  - source: string ("manual" | "test")
  - skillsCount: number
  - classesCount: number
- Producers:
  - dwkit.services.skill_registry_service (future)
- Consumers:
  - (none yet; future UI consumers may subscribe)
- Notes:
  - Counts are used for sanity checks and UI summaries.

## Notes
- Registry and bus skeleton exist to enforce "docs-first" event introduction.
