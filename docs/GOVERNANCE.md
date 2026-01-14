# Governance (Public Summary)

dwkit is built as a personal, product-grade Mudlet kit with a strict internal development standard.

## Key rules (summary)
- Baseline: Mudlet 4.19.1 + embedded Lua runtime
- Modular design (core/services/UI separation)
- Only one intentional global namespace
- Per-profile persistence only; no hardcoded profile names/absolute paths
- Event names are namespaced and treated as contracts
- UI is consumer-only; logic lives in services
- Changes are verification-gated (tests + expected results required)
- Docs/runtime sync (required):
  - Any invocation variants, syntax, examples, or behavioral notes recorded in docs/Command_Registry_v1.0.md MUST be mirrored in src/dwkit/bus/command_registry.lua in the same change set (no drift).
  - Checklist: docs/DOCS_SYNC_CHECKLIST.md

## Chat handoff template (internal workflow aid)
- Template file: docs/Chat_Handoff_Pack_Template_v1.0.md
- Purpose: standardized copy/paste handoffs between chats to reduce drift and missing artifacts.
- Note: this template does not define runtime behavior; it is an internal workflow aid.

## Contributions
This is a personal repo. PRs are not accepted. Please fork.

## Development standard (authoritative)
The full internal development standard is published in this repository.

Start here:
- docs/Development_Standard_Index.md

Current standard version:
- docs/MUDLET_PACKAGE_DEVELOPMENT_STANDARD_v1.10.md
