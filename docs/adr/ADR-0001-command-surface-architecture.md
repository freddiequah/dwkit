# ADR-0001: Command Surface Architecture (Router + Handlers)

Date: 2026-01-18
Status: Accepted

## Context

DWKit uses user-facing commands for kit control (UI, diagnostics, tests, etc.) and may include gameplay command wrappers.
Early growth already shows pressure on a single monolithic command alias module, which risks becoming a “god module” with:

* mixed responsibilities (routing + business logic + utilities)
* higher regression risk per change
* poor testability and maintainability as command count grows

The project is in the early stage and is expected to expand significantly.

## Decision

Adopt a layered command surface architecture:

1. Alias Router Layer (transport)

* src/dwkit/services/command\_aliases.lua
* Responsibility: alias lifecycle + parsing + routing only

2. Command Handler Layer (application)

* src/dwkit/commands/
* Responsibility: implement command behaviors

3. Shared Utility Layer (foundation)

* src/dwkit/util/ (or src/dwkit/core where appropriate)
* Responsibility: reusable helper functions

This decision is enforced by the development standard:

* docs/MUDLET\_PACKAGE\_DEVELOPMENT\_STANDARD\_v1.10.md (Section S.0 + Section S)

## Options considered

### Option 1: Router + Handlers (chosen)

Pros:

* Best balance of maintainability and speed
* Prevents “god module” growth
* Isolates change risk per command
* Eases incremental testing and verification
* Forward-compatible with Phase 2 registry migration

Cons:

* Adds a small amount of file structure overhead

### Option 2: Full metadata-backed command registry immediately

Pros:

* Strongly consistent help/docs generation
* Clear metadata-driven safety enforcement

Cons:

* Heavier investment early, before final command framework needs are known

### Option 3: Extract only the largest offenders from command\_aliases.lua

Pros:

* Quick relief with minimal movement

Cons:

* Does not prevent future re-growth and responsibility creep

## Consequences

* command\_aliases.lua must remain thin (routing + lifecycle)
* New commands must ship as handler modules
* Utilities must be moved into util/core and reused rather than duplicated
* Phase 2 migration (registry metadata) can be introduced incrementally

## Phase 2 trigger checklist

Begin Phase 2 migration when 2+ conditions are true:

* 25+ user-facing commands
* dwhelp/dwcommands becomes painful to maintain manually
* safety classification / permission tiers required
* recurring argument parsing consistency problems
* automatic docs/help generation desired
