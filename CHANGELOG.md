# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog, and versions follow the project's chosen version tag style.

## Unreleased

### Added
- Initial repository structure
- Governance documentation
- Baseline README, license, changelog
- Runtime baseline module and manual loader init:
  - dwkit.core.runtime_baseline
  - dwkit.loader.init
- Minimal SAFE self-test runner:
  - dwkit.tests.self_test_runner
- Runtime command registry (SAFE):
  - dwkit.bus.command_registry
- SAFE typed command aliases (local, no gameplay output):
  - dwkit.services.command_aliases
  - Commands: dwcommands, dwhelp, dwtest, dwinfo
- VS Code workspace files:
  - .vscode/settings.json
  - .vscode/extensions.json

### Changed
- .gitignore updated to ignore VS Code folder except shareable workspace files
- Documentation hygiene:
  - Filled Architecture Map, Event Registry, and Package Identity stubs
  - Synced Command Registry doc to match runtime registry + typed commands

### Fixed
- None

---

## v2026-01-12F - 2026-01-12 (MYT)

### Changed
- Self-test runner now executes the ScoreStore persistence smoke check (SAFE) instead of skipping it.

### Added
- SAFE ScoreStore persistence smoke check wiring:
  - self_test_runner now performs a controlled, manual-only persistence enable/save/load/disable flow for ScoreStore (no gameplay commands, no timers).

### Verified
- Manual verification executed:
  - loader init
  - dwtest quiet (PASS)
- Tag applied and pushed:
  - v2026-01-12F

---

## v2026-01-12E - 2026-01-12 (MYT)

### Changed
- Changelog synchronized to include release notes for:
  - v2026-01-12B
  - v2026-01-12C
  - v2026-01-12D

### Verified
- Tag applied and pushed:
  - v2026-01-12E

---

## v2026-01-12D - 2026-01-12 (MYT)

### Changed
- Event diagnostics output now prints the correct record kind for `dweventtap show`:
  - `kind=tap` for tap records
  - `kind=sub` for subscription records

### Fixed
- `dweventtap show` no longer hardcodes `kind=tap`; it now renders `rec.kind` (tap vs sub).

### Verified
- Manual verification executed:
  - dweventtap clear
  - dweventtap on
  - dweventsub DWKit:Boot:Ready
  - loader init (re-emit Boot:Ready)
  - dweventtap show (confirmed both tap + sub entries)
- Tag applied and pushed:
  - v2026-01-12D

---

## v2026-01-12C - 2026-01-12 (MYT)

### Changed
- `dwboot` health output now includes epoch-milliseconds timestamp for Boot:Ready when available:
  - `bootReadyTsMs`

### Verified
- Manual verification executed:
  - dwboot (confirmed bootReadyTsMs appears)
  - dwversion
  - dwtest quiet (PASS)
- Tag applied and pushed:
  - v2026-01-12C

---

## v2026-01-12B - 2026-01-12 (MYT)

### Added
- Persistence store helpers:
  - persist paths + store modules
  - enable manual ScoreStore persistence (SAFE; manual control)

### Changed
- Boot:Ready payload now includes a monotonic guard for `tsMs` to prevent non-increasing epoch-ms values across rapid emits.

### Fixed
- Self-test envelope load handling:
  - `loadEnvelope` multi-return handling corrected
- Persistence smoke checks added and passing for:
  - saveEnvelope / loadEnvelope / delete

### Verified
- Mudlet 4.19.1 + Lua 5.1 runtime verified
- Manual verification executed:
  - dwboot
  - dwversion
  - dwtest quiet (PASS)
  - dweventtap show (Boot:Ready payload includes ts + tsMs)
- Tag applied and pushed:
  - v2026-01-12B

---

## v2026-01-12A - 2026-01-12 (MYT)

### Added
- SAFE event diagnostics capability:
  - EventBus tap subscribers (tapOn / tapOff) for observing emitted events without affecting delivery semantics
- SAFE event diagnostics commands:
  - dweventtap (on | off | status | show | clear)
  - dweventsub <EventName>
  - dweventunsub <EventName | all>
  - dweventlog [n]

### Changed
- EventBus runtime statistics now include:
  - tapSubscribers
  - tapErrors

### Fixed
- None

### Verified
- Mudlet 4.19.1 + Lua 5.1 runtime verified
- Manual verification executed:
  - dwboot
  - dwversion
  - dwevents
  - dweventtap on/off
  - dweventlog
- Tag applied and pushed:
  - v2026-01-12A
