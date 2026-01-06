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

## Contributions
This is a personal repo. PRs are not accepted. Please fork.

## Full standard
The full internal standard exists but is not published in this repository.
