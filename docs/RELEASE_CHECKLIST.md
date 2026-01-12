# Release Checklist (Required)

This document defines the REQUIRED steps to ship a DWKit release.
It is aligned to the project's governance pack and is intentionally copy/paste friendly.

Rule:
- A release is not "done" until this checklist is completed and the release tag exists on origin.

==================================================
Release Checklist (per release)
==================================================

1) Version tag applied:
- Tag:
- Date (MYT):

2) Changelog updated:
- Added:
- Changed:
- Fixed:
- Deprecated:
- Removed:

3) Tested list recorded:
- Core load:
- Persist/config load:
- Event registry sanity:
- Service smoke tests:
- LaunchPad commands:
- UI idempotence:
- Self-test runner PASS:
- Compatibility baseline verified (Mudlet/Lua string outputs):
- Cross-profile (if applicable):

4) Migration notes included (if any schema/contract changes):
- Schemas changed:
- Migration steps:
- Backward compatibility:
- Breaking changes:

5) Packaging validated:
- Fresh profile install test:
- Upgrade install test:
- No hardcoded paths/profile names:

==================================================
Completed Releases
==================================================

## v2026-01-12A (2026-01-12 MYT)

1) Version tag applied:
- Tag: v2026-01-12A
- Date (MYT): 2026-01-12

2) Changelog updated:
- Added:
  - SAFE event diagnostics commands: dweventtap / dweventsub / dweventunsub / dweventlog
  - EventBus tap subscriber observation (tapOn/tapOff) and tap log capture (no impact to delivery semantics)
- Changed:
  - EventBus stats now include tapSubscribers and tapErrors
- Fixed:
  - None
- Deprecated:
  - None
- Removed:
  - None

3) Tested list recorded:
- Core load: PASS (lua do ... L.init ... end)
- Persist/config load: PASS (dwboot shows identity/runtimeBaseline OK)
- Event registry sanity: PASS (dwevents, dwevent DWKit:Boot:Ready)
- Service smoke tests: PASS (dwboot shows services.commandAliases OK)
- LaunchPad commands: N/A (not introduced yet)
- UI idempotence: N/A (not introduced yet)
- Self-test runner PASS: dwboot + dwversion validated; (self-test runner optional execution not required for this release)
- Compatibility baseline verified: PASS (dwversion shows Lua 5.1, Mudlet 4.19.1)
- Cross-profile: N/A (not introduced)

4) Migration notes included:
- Schemas changed: None
- Migration steps: None
- Backward compatibility: N/A
- Breaking changes: None

5) Packaging validated:
- Fresh profile install test: Not recorded for this release
- Upgrade install test: PASS (re-init succeeded; no load errors)
- No hardcoded paths/profile names: Assumed PASS (no reports; maintain as ongoing rule)
