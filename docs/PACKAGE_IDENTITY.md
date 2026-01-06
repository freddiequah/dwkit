# Package Identity (Authoritative)

## Version
v1.2

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

## Code Mirror (Authoritative in code)
These identity values are mirrored in:
- src/dwkit/core/identity.lua

The code values MUST match this document. If either changes, bump this document version and record the decision.

## Decision Record
- 2026-01-06: Locked EventPrefix=DWKit:, DataFolderName=dwkit, VersionTagStyle=Calendar.
- 2026-01-06: Added canonical identity module mirror at src/dwkit/core/identity.lua.

## Guardrails
- All event names MUST start with EventPrefix (DWKit:).
- All package-owned persistence MUST use DataFolderName (dwkit) as the per-profile folder.
- Any change to identity fields requires a version bump and a recorded decision.
