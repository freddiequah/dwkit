# Package Identity (Authoritative)

## Version
v1.2

## Purpose
This file locks the canonical package identity values.
Do not change these without an explicit version bump and recorded decision.

## Identity Fields (Locked)
| Field | Value | Status |
|------|-------|--------|
| PackageRootGlobal | DWKit | LOCKED |
| PackageId (require prefix) | dwkit | LOCKED |
| EventPrefix | DWKit: | LOCKED |
| DataFolderName | dwkit | LOCKED |
| VersionTagStyle | Calendar (format: vYYYY-MM-DDX) | LOCKED |

## Notes (Meaning)
- PackageRootGlobal:
  - The single intentional global namespace table: _G.DWKit
- PackageId:
  - Internal kit identifier string used by docs + code.
- EventPrefix:
  - All DWKit event names MUST start with this prefix (DWKit:).
- DataFolderName:
  - Per-profile persistence folder name under the Mudlet profile path.
- VersionTagStyle:
  - Calendar-style version tags, example: v2026-01-06F

## Code Mirror (Authoritative in code)
These identity values are mirrored in:
- src/dwkit/core/identity.lua

The code values MUST match this document.
If either changes, bump this document version and record the decision.

## Decision Record
- 2026-01-06: Locked EventPrefix=DWKit:, DataFolderName=dwkit, VersionTagStyle=Calendar.
- 2026-01-06: Added canonical identity module mirror at src/dwkit/core/identity.lua.

## Guardrails
- All event names MUST start with EventPrefix (DWKit:).
- All package-owned persistence MUST use DataFolderName (dwkit) as the per-profile folder.
- Any change to identity fields requires a version bump and a recorded decision.
