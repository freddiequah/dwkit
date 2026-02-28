# Event Registry

## Version
v1.12

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
  - Enforces: events must be registered in the registry before subscription or emit (docs-first discipline).

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
  - tsMs: number (epoch ms; monotonic)
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
  - ts: number
  - model: table
  - changed: table (optional)
  - source: string (optional)
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
  - ts: number
  - state: table
  - delta: table (optional)
  - source: string (optional)
- Producers:
  - dwkit.services.presence_service
- Consumers:
  - internal (ui/tests/integrations)
- Notes:
  - SAFE internal event (no gameplay commands).
  - Manual-only: emitted only when service API is invoked.

### DWKit:Service:RoomEntities:Updated
- Description:
  - Emitted when RoomEntitiesService updates its room entity classification state (SAFE; data only).
- PayloadSchema:
  - ts: number
  - state: table
  - delta: table (optional)
  - source: string (optional)
- Producers:
  - dwkit.services.roomentities_service
- Consumers:
  - internal (ui/tests/integrations)
- Notes:
  - SAFE internal event (no gameplay commands).
  - Manual-only: emitted only when service API is invoked.
  - Primary consumer is ui_autorefresh and RoomEntities UI modules.

### DWKit:Service:ScoreStore:Updated
- Description:
  - Emitted when ScoreStoreService ingests a score-like text snapshot (SAFE; no gameplay sends).
- PayloadSchema:
  - ts: number
  - snapshot: table
  - source: string (optional)
- Producers:
  - dwkit.services.score_store_service
- Consumers:
  - internal (future ui/services/tests)
- Notes:
  - SAFE internal event (no gameplay commands).
  - Emitted when ScoreStoreService ingest API is invoked (may be triggered by passive capture during loader.init, or manual/fixture ingestion).
  - Parsing is optional; raw capture is the stable core contract.

### DWKit:Service:SkillRegistry:Updated
- Description:
  - Emitted when SkillRegistryService updates skill/spell registry data (SAFE; data only).
- PayloadSchema:
  - ts: number
  - registry: table
  - changed: table (optional)
  - source: string (optional)
- Producers:
  - dwkit.services.skill_registry_service
- Consumers:
  - internal (ui/tests)
- Notes:
  - SAFE internal event (no gameplay commands).
  - Manual-only: emitted only when service API is invoked.

### DWKit:Service:WhoStore:Updated
- Description:
  - Emitted when WhoStoreService updates its authoritative player-name set derived from WHO parsing (SAFE; no gameplay sends).
- PayloadSchema:
  - ts: number
  - state: table
  - delta: table (optional)
  - source: string (optional)
- Producers:
  - dwkit.services.whostore_service
- Consumers:
  - internal (roomentities_service/ui/tests/integrations)
- Notes:
  - SAFE internal event (no gameplay commands).
  - Manual-only: emitted only when service API is invoked.
  - Primary consumer is RoomEntitiesService for best-effort player reclassification.

### DWKit:Service:RoomFeedStatus:Updated
- Description:
  - Emitted when RoomFeedStatusService changes watch/health state (SAFE; no gameplay sends).
- PayloadSchema:
  - ts: number
  - state: table
  - delta: table (optional)
  - source: string (optional)
- Producers:
  - dwkit.services.roomfeed_status_service
- Consumers:
  - internal (ui/tests/integrations)
- Notes:
  - SAFE internal event (no gameplay commands).
  - Manual-only: emitted on watch on/off, capture OK/abort, and state transitions.
  - Primary consumer is UI modules that need to show Room Watch Health.

### DWKit:Service:ChatLog:Updated
- Description:
  - Emitted when ChatLogService appends/clears chat lines (SAFE; data only).
- PayloadSchema:
  - ts: number
  - state: table
  - delta: table (optional)
  - source: string (optional)
- Producers:
  - dwkit.services.chat_log_service
- Consumers:
  - internal (chat_ui/tests/integrations)
- Notes:
  - SAFE internal event (no gameplay commands).
  - Manual-only: emitted only when ChatLogService API is invoked.
  - Primary consumer is dwkit.ui.chat_ui (event-driven refresh while visible).

### DWKit:Service:CrossProfileComm:Updated
- Description:
  - Emitted when CrossProfileCommService peer state changes (HELLO/BYE/seen). SAFE; no gameplay sends; same-instance transport only.
- PayloadSchema:
  - ts: number
  - state: table
  - delta: table (optional)
  - source: string (optional)
- Producers:
  - dwkit.services.cross_profile_comm_service
- Consumers:
  - internal (presence_service/ui/tests)
- Notes:
  - SAFE internal event (no gameplay commands).
  - Manual-only: service is installed during loader.init and reacts to Mudlet lifecycle events best-effort.

## Notes
- Registry and bus skeleton exist to enforce "docs-first" event introduction.

## Changes
v1.12
- Synced docs to runtime event_registry.lua mirror:
  - Bumped registry version to v1.12.
  - Added events: DWKit:Service:RoomFeedStatus:Updated, DWKit:Service:ChatLog:Updated, DWKit:Service:CrossProfileComm:Updated.
  - Updated DWKit:Service:WhoStore:Updated payload schema/notes to match code mirror (state/delta/source/ts).