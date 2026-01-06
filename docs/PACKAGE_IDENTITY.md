# Package Identity (Authoritative)

## Version
v1.1

## Purpose
This file locks the canonical package identity values.
Do not change these without an explicit version bump and recorded decision.

## Identity Fields (Current)
| Field | Value | Status |
|------|-------|--------|
| PackageRootGlobal | DWKit | LOCKED |
| PackageId (require prefix) | dwkit | LOCKED |
| EventPrefix | DWKit: | LOCKED |
| DataFolderName | dwkit | LOCKED |
| VersionTagStyle | Calendar (vYYYY-MM-DDX) | LOCKED |

## Decision Record
- 2026-01-06: Locked EventPrefix=DWKit:, DataFolderName=dwkit, VersionTagStyle=Calendar.

## Guardrails
- All event names MUST start with EventPrefix (DWKit:).
- All package-owned persistence MUST use DataFolderName (dwkit) as the per-profile folder.
- Any change to identity fields requires a version bump and a recorded decision.
