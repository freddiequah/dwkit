# Event Registry

## Version
v1.8

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

## Runtime Export (Docs Sync Helper) (SAFE)
The runtime can print a Markdown export derived from the same event registry data.

- Export full event registry Markdown:
  - dwevents md

Notes:
- This is a copy/paste helper for maintaining docs sync. It does not emit events.
- Normal list and help remain:
  - dwevents
  - dwevent <EventName>

## Events

### DWKit:Boot:Ready
- Description:
  - Emitted once after loader.init attaches DWKit surfaces; indicates kit is ready for manual use.
- PayloadSchema:
  - ts: number
- Producers:
  - dwkit.loader.init
- Consumers:
  - internal (services/ui/tests)
- Notes:
  - SAFE internal event (no gameplay commands).
  - Manual-only: emitted only when loader.init() is invoked.
  - Docs-first: registered in docs/Event_Registry_v1.0.md, mirrored here.

### DWKit:Service:ActionModel:Updated
- Description:
  - Emitted when ActionModelService updates the action model (SAFE; data only).
- PayloadSchema:
  - changed: table (optional)
  - model: table
  - source: string (optional)
  - ts: number
- Producers:
  - dwkit.services.action_model_service
- Consumers:
  - internal (ui/tests)
- Notes:
  - SAFE internal event (no gameplay commands).
  - Manual-only: emitted only when service API is invoked.

### DWKit:Service:Presence:Updated
- Description:
  - Emitted when PresenceService updates its state (SAFE; no gameplay sends).
- PayloadSchema:
  - delta: table (optional)
  - source: string (optional)
  - state: table
  - ts: number
- Producers:
  - dwkit.services.presence_service
- Consumers:
  - internal (ui/tests/integrations)
- Notes:
  - SAFE internal event (no gameplay commands).
  - Manual-only: emitted only when service API is invoked.

### DWKit:Service:ScoreStore:Updated
- Description:
  - Emitted when ScoreStoreService ingests a score-like text snapshot (SAFE; no gameplay sends).
- PayloadSchema:
  - snapshot: table
  - source: string (optional)
  - ts: number
- Producers:
  - dwkit.services.score_store_service
- Consumers:
  - internal (future ui/services/tests)
- Notes:
  - SAFE internal event (no gameplay commands).
  - Manual-only: emitted only when service ingest API is invoked.
  - Parsing is optional; raw capture is the stable core contract.

### DWKit:Service:SkillRegistry:Updated
- Description:
  - Emitted when SkillRegistryService updates skill/spell registry data (SAFE; data only).
- PayloadSchema:
  - changed: table (optional)
  - registry: table
  - source: string (optional)
  - ts: number
- Producers:
  - dwkit.services.skill_registry_service
- Consumers:
  - internal (ui/tests)
- Notes:
  - SAFE internal event (no gameplay commands).
  - Manual-only: emitted only when service API is invoked.

## Notes
- Registry and bus skeleton exist to enforce "docs-first" event introduction.
