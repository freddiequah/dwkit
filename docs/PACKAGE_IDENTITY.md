# Package Identity (Authoritative)

## Version
v1.0

## Purpose
This file locks the canonical package identity values.
Do not change these without an explicit version bump and recorded decision.

## Identity Fields (Current)
| Field | Value | Status |
|------|-------|--------|
| PackageRootGlobal | DWKit | LOCKED |
| PackageId (require prefix) | dwkit | LOCKED |
| EventPrefix | TBD | REQUIRED (must be set before events) |
| DataFolderName | TBD | REQUIRED (must be set before persistence expands) |
| VersionTagStyle | TBD (observed Calendar-style in code) | DECISION PENDING |

## Guardrails
- Until EventPrefix is set: do not introduce any package events.
- Until DataFolderName is set: do not expand package-owned persistence beyond the minimal current scope.
- Any change to identity fields requires a version bump and a recorded decision.
