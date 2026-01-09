# docs/DECOMPOSITION_PLAN_v1.0.md

# DECOMPOSITION_PLAN v1.0
- Date: 2026-01-08
- Goal: migrate legacy Deathwish Kit style scripts into DWKit architecture (services-first, UI consumer-only, optional integrations), while remaining safe for use in a brand-new profile and portable to other users’ profiles.

## Guiding constraints (from Anchor Pack)
- DWKit must be self-contained and must not assume any other scripts exist in a user profile.
- No hidden automation: anything that runs on load/connect or via timers must be opt-in and documented.
- Gameplay output must only happen through explicit wrappers (future DWKit command registry surface `dw*`).
- No GMCP assumptions (if any GMCP exists in legacy scripts, it must become optional and degrade gracefully).

## What we have today (summary)
- External/non-DWKit groups present in the export: `generic_mapper`, `gui-drop`, `deleteOldProfiles`.
- Legacy `Deathwish Kit` group contains logic, UI, persistence, and gameplay sends mixed together.
- Many scripts create their own globals (e.g., `Healer_Core`, `BuffHUD`, `PresenceUI`, `ActionPadUI`, etc). These will not be allowed in DWKit target state (only `DWKit` global).
- At least one legacy UI script references GMCP event names (e.g., `gmcp.Room.*`). This must not become a dependency in DWKit.

## Target decomposition (high level)

### 1) Core and identity spine (DWKit)
- `src/dwkit/core`: identity, logging, safe_call, runtime baseline, helpers.
- `src/dwkit/bus`: event registry + command registry (docs and runtime derived from same data).
- `src/dwkit/config`: one config surface, per-profile overrides.
- `src/dwkit/persist`: path helpers and schema IO, per-module ownership.

### 2) Services (logic owners, no UI)
Create services that own state, parsing, persistence, and event emission. UI only subscribes.

Recommended first "spine" services (SAFE-only):
- `PresenceService`
  - Inputs: state updates (later from triggers/parsers), optional integrations
  - Outputs: emits DWKit presence/state events
- `ActionModelService`
  - Owns: structured action definitions (not UI), cooldowns, availability
  - Outputs: emits DWKit action model updates
- `SkillRegistryService`
  - Owns: data-driven skill/spell registry (multi-class ready)
  - Outputs: provides query APIs, emits registry-changed events

Second wave services (derived from current scripts):
- `ScoreStoreService` (from `ScoreStore (No-GMCP)`)
- `WhoStoreService` (from `WhoStore (No-GMCP)`)
- `CharStateService` (from `30_CharStatus_CharState`)
- `BuffService` (from legacy BuffHUD core + affects capture + auto-refresh pieces)
- `MovementService` (from movement kits, but logic only, no send)

### 3) UI consumers (toggleable, no logic/persistence ownership)
UI modules subscribe to service events and render state. They must be disabled safely.

Candidate consumers mapped from legacy:
- `Presence_UI` consumer (from `Presence_UI`) -> `src/dwkit/ui/presence_ui.lua` (view only)
- `HealerSelector_UI` consumer -> `src/dwkit/ui/healer_selector_ui.lua` (view only)
- `BuffHUD_UI` consumer -> `src/dwkit/ui/buffhud_ui.lua` (view only)
- `StatusHUD_UI` consumer -> `src/dwkit/ui/statushud_ui.lua` (view only)
- `ActionPad_UI` consumer -> `src/dwkit/ui/actionpad_ui.lua` (view only)
- LaunchPad remains the single UI control surface (show/hide/toggle).

### 4) Gameplay wrappers (explicit, documented, kill-switch)
Any legacy script that currently calls `send()` must become either:
- a SAFE service (no send), or
- a documented wrapper command (sendsToGame=YES) recorded in the Command Registry.

Wrappers likely needed (based on scripts that sendToGame=YES in this export):
- HealerSmart (readycast/heals/executor)
- Buff kits (buff self, buff target, group buff)
- Movement kits (relocate, summon, recall, move helpers, ActionPad move gate)
- Offence kits (smite, etc)
- Food service kit
- Zombie manager (if still desired)
- Any UI button actions that currently call `send()` directly (must be routed through wrappers)

Policy:
- Default mode: manual only.
- Optional automation (timers/on-connect hooks) can be added later ONLY if explicitly chosen and documented with opt-in.

### 5) Integrations (optional, degrade gracefully)
External packages should be treated as optional integrations:
- `generic_mapper` integration:
  - Today it emits/uses non-namespaced events like `onNewRoom` / `onNewLine`.
  - DWKit should not depend on those events directly in services.
  - If we keep it, implement an integration module that listens to those events and re-emits DWKit namespaced events after the Event Registry is updated.
- `EMCOChat` integration:
  - Keep as opt-in. If absent, DWKit must still work.
- `gui-drop` / AdjustableContainer:
  - Treat as UI tooling only; not part of DWKit core. If used, wrap behind optional UI modules or keep out of DWKit entirely.

## Removal / risk reduction plan (no code yet, planning only)
1) Identify all autoRisk=HIGH scripts and decide:
   - keep as manual-only
   - convert to opt-in automation
   - delete/replace
2) Identify all global tables created by legacy scripts and define their DWKit ownership:
   - move state into a service module local state
   - expose only via public API + events
3) Identify persistence files used today (ScoreStore/WhoStore/map/gui-drop) and plan schema ownership + migration notes.

## Gate 1 verification checklist (docs-only)
- CURRENT_SYSTEM_MAP covers all script roots and their scripts, plus triggers and aliases.
- For Deathwish Kit scripts, each entry is tagged with sendsToGame/persistence/ui/autoRisk and key event hooks.
- DECOMPOSITION_PLAN clearly states what becomes services vs UI vs integrations vs wrappers.
- No refactor or runtime code changes done in this gate.
