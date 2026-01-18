# Architecture — Command Surface (Router + Handlers) v1.0

DWKit is expected to grow in the number of user-facing commands (kit commands and gameplay wrappers).
To avoid a “god module” and long-term maintenance risk, DWKit adopts a layered Command Surface design.

This document is descriptive and long-term reference. The authoritative rules are in:
- docs/MUDLET_PACKAGE_DEVELOPMENT_STANDARD_v1.10.md (Section S.0 + Section S)

---

## Goals

- Keep src/dwkit/services/command_aliases.lua small and stable
- Make each command implementation isolated and testable
- Maintain consistent help and safety classification over time
- Allow Phase 2 migration (metadata-backed registry) without a rewrite

Non-goals:
- Replacing DWKit’s current alias routing mechanism immediately
- Introducing auto-run or hidden automation on load

---

## Layering Model

### Layer A — Alias Router (transport)

**Location**
- src/dwkit/services/command_aliases.lua

**Responsibilities**
- install/uninstall tempAliases
- parse user input patterns (regex capture)
- route to command handlers
- store alias IDs for cleanup and re-install idempotence

**Constraints**
- No heavy business logic in this layer
- No subsystem implementations (no “mini frameworks” inside router)
- No large shared utilities inside this file

---

### Layer B — Command Handlers (application)

**Location**
- src/dwkit/commands/

**Responsibilities**
- implement command behavior
- call into services/bus/util layers as needed
- provide predictable output formatting
- keep each command focused, small, and readable

**Suggested handler shape**
- id / name
- description
- usage
- examples
- safety classification
- mode (manual / opt-in / auto)
- run(args, ctx)

Note: Phase 2 will formalize these fields via registry metadata.

---

### Layer C — Shared Utilities (foundation)

**Location**
- src/dwkit/util/ (or src/dwkit/core where appropriate)

**Responsibilities**
- safe printing helpers
- bounded pretty printing / table dumps
- formatting helpers
- defensive call wrappers (best-effort method invocations)

**Rule**
- Utilities must not be embedded inside command_aliases.lua.

---

## Phase Plan

### Phase 1 (current) — Router + Handlers
- Alias patterns route to handler modules
- Handlers own the implementation
- Router stays thin and stable

### Phase 2 (future) — Metadata-backed Command Registry
- Commands register metadata (id/description/usage/examples/safety/mode)
- dwhelp / dwcommands derive from the registry structure
- Docs/runtime output derive from the same metadata source

---

## Phase 2 Triggers (start migration when 2+ are true)

- 25+ user-facing commands exist
- dwhelp/dwcommands becomes painful to maintain manually
- safety classification / permission tiers become necessary (SAFE vs gameplay wrappers)
- argument parsing consistency becomes a recurring problem
- automatic docs/help generation is desired

---

## Definition of Done (Command Surface)

- New commands must be implemented as handler modules first
- command_aliases.lua must not grow with business logic
- Any gameplay-sending command must still comply with the Command & Alias Registry requirements
