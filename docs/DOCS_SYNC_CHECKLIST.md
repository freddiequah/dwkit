# Docs Sync Checklist (Required)

This document defines the REQUIRED docs-to-runtime sync checks for dwkit.
It exists to prevent drift between:
- Documentation contracts (docs/*.md)
- Runtime registries and observable outputs (src/*.lua)

This is a documentation-only checklist. It does not define new runtime behavior.

## Rule (No Drift)
If any item listed below changes in docs, the corresponding runtime file(s) MUST be updated in the SAME change set (same branch/PR) so that docs and runtime remain consistent.

## Docs-only PR verification policy (required)
A docs-only PR is a change set where `git diff` shows ONLY `docs/*` changes.

Minimum verification for docs-only PRs:
1) Confirm scope is truly docs-only:
   - `git diff --stat` shows only `docs/*`
2) Confirm no encoding corruption / mojibake:
   - `Select-String -Path .\docs\*.md -Pattern '[^\x00-\x7F]'`
     - Expected: no matches
3) Confirm files remain copy/paste friendly:
   - Headings render normally (no hidden leading characters)
   - Code fences are properly closed (if present)
4) If the docs change is a contract that must match runtime output (registry/spec docs),
   the corresponding runtime sync checklist item below still applies (no drift rule).

Notes:
- Mudlet runtime verification is NOT required for purely editorial docs changes.
- Mudlet runtime verification IS required if you changed a contract doc whose output must match runtime surfaces
  (for example: Command Registry, Self-Test Runner spec, Event Registry when runtime-visible).

## Checklist

### 1) Command Registry sync (required)
When modifying:
- docs/Command_Registry_v1.0.md

You MUST also verify/update:
- src/dwkit/bus/command_registry.lua

Scope of sync (must match):
- Invocation variants (typed command usage, Lua alternatives, quiet modes)
- Syntax strings
- Examples
- Behavioral notes that affect user expectations of output/behavior

Notes:
- docs/Command_Registry_v1.0.md is the canonical registry.
- src/dwkit/bus/command_registry.lua is the runtime source of truth for dwhelp/dwcommands output.
- No drift is allowed between the two.

Verification (minimum):
- Run: dwhelp <command>
- Confirm: Syntax/Examples/Notes match the docs entry for that command.

### 2) Self-test runner contract sync (required)
When modifying:
- docs/Self_Test_Runner_v1.0.md

You MUST also verify/update:
- src/dwkit/tests/self_test_runner.lua

Scope of sync (must match):
- Required output section order and headings
- Required header fields (including mode line if specified)
- PASS/FAIL token semantics
- Any required quiet/verbose behavior described as contract

Verification (minimum):
- lua local L=require("dwkit.loader.init"); L.init()
- dwtest
- lua local T=require("dwkit.tests.self_test_runner"); T.run({quiet=true})
- Confirm output matches the spec's required sections and rules.

### 3) Package identity contract sync (required)
When modifying:
- docs/PACKAGE_IDENTITY.md

You MUST also verify/update:
- src/dwkit/core/identity.lua (canonical identity fields)
- Any runtime outputs that print identity fields (for example: dwid, dwversion, dwtest)

Scope of sync (must match):
- PackageId
- EventPrefix
- DataFolderName
- VersionTagStyle
- Any printed formatting that is treated as a contract in docs

Verification (minimum):
- lua local L=require("dwkit.loader.init"); L.init()
- dwid
- dwversion
- dwtest
- Confirm printed identity fields match docs/PACKAGE_IDENTITY.md.

### 4) Event registry sync (required when it becomes runtime-visible)
When modifying:
- docs/Event_Registry_v1.0.md

You MUST also verify/update:
- src/dwkit/bus/event_registry.lua
- Any runtime surfaces that display event registry data (for example: dwevents, dwevent)

Scope of sync (must match):
- Event names
- Descriptions
- Any required categorization rules (SAFE/GAME) if introduced

Verification (minimum):
- lua local L=require("dwkit.loader.init"); L.init()
- dwevents
- dwevent <EventName>
- Confirm runtime output reflects the docs registry.

### 5) Chat handoff template sync (docs-only; required for continuity)
When modifying:
- docs/Chat_Handoff_Pack_Template_v1.0.md

You MUST also verify/update (docs-only cross-check):
- Ensure it still matches the current internal governance standard's Section V (Chat Handoff Pack) structure:
  - Required fields present (identity, objective, scope, verified working, known issues, last change, verification results, next steps, required artifacts).
  - Full-File Return workflow dump commands are correct for PowerShell.
  - Mudlet input line paste safety reminder remains correct (single-line lua do ... end).

Verification (minimum):
- Confirm the template is copy/paste ready (no placeholders missing that would block a handoff).
- Confirm the dump commands match your current repo paths and common workflow.

## Definition of Done (Docs Sync)
A docs change is DONE only when:
- The corresponding runtime surfaces display the same invocation variants/syntax/examples/notes (where applicable)
- Any contract-affecting observable output matches the spec (where applicable)
- The change set contains BOTH docs and runtime updates when required (no split PRs that create drift)

