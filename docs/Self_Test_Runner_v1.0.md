# Self-Test Runner (dwtest) - Specification

## Version
v1.2
## Purpose
This document defines the required output sections and PASS/FAIL criteria for the DWKit self-test runner.

This document is the authoritative observable-output contract for dwtest.
Any change to headings, section order, PASS/FAIL tokens, verdict wording, or other required observable output elements is a contract change and must follow Change Control.

It exists to enforce the Verification Gate (Section R) and the Self-Test Runner Standard (Section M).

This is a documentation-only spec. It does not define implementation details beyond observable outputs.

## Safety Classification
- SAFE: dwtest MUST NOT send gameplay commands to the MUD.
- Manual-only: dwtest is run only when the user invokes it.

## Invocation (Manual)
- Primary:
  - dwtest
- Alternate (Lua):
  - lua DWKit.test.run()
- Quiet (Lua):
  - lua local T=require("dwkit.tests.self_test_runner"); T.run({quiet=true})

## Preconditions
- loader init should have been invoked before dwtest, so test surfaces are attached:
  - lua local L=require("dwkit.loader.init"); L.init()

If dwtest is run before init, it may report missing surfaces and must fail clearly (no silent success).

## Required Output Sections (minimum)
dwtest output MUST be copy/paste friendly and include these sections in this order:

1) Header
- Includes:
  - DWKit label
  - self-test runner version (if available)
  - timestamp (human or epoch)
  - mode line (exact format): [DWKit Test] mode=quiet OR [DWKit Test] mode=verbose

2) Compatibility Baseline (Section A.0)
- Prints:
  - Mudlet version (if available)
  - _VERSION (Lua version string)
- Notes:
  - If Mudlet version is not available in runtime, print "Mudlet version: (unavailable)" explicitly.

3) Canonical Identity (from docs/PACKAGE_IDENTITY.md mirrored in code)
- Prints:
  - PackageRootGlobal
  - PackageId
  - EventPrefix
  - DataFolderName
  - VersionTagStyle

4) Core Surface Checks
- Reports PASS/FAIL for presence of required surfaces (examples):
  - DWKit global exists
  - DWKit.core.identity exists
  - DWKit.core.runtimeBaseline exists
- Any missing surface MUST be FAIL with a short reason.

5) Registry Checks (Docs-first compliance)
- Reports PASS/FAIL for:
  - Event registry present and listable
  - Command registry present and listable
- If registry exists, include a short count (events/commands) where available.

Quiet-mode behavior (required when mode=quiet):
- Registry checks MUST be count-only.
- Registry checks MUST NOT print full registry listing blocks (no list spam).
- Verbose mode may include list blocks, but must still print counts and PASS/FAIL lines.

5.5) Optional: Persistence Smoke Checks (SAFE)
If persistence subsystems exist, dwtest MAY include a persistence smoke checks section (SAFE) to verify:
- persist store save/load/delete (self-test envelope)
- ScoreStore persistence smoke (SAFE)

Notes:
- This section is optional and may be omitted until the persistence subsystem exists.
- If present, it should appear after Registry Checks and before Loader / Boot Wiring Checks.

6) Loader / Boot Wiring Checks (SAFE)
- Reports PASS/FAIL for:
  - loader init status known
  - any captured init errors are printed (if present)
- This section must not emit events or trigger UI.

7) Summary
- One final verdict line:
  - PASS: all required checks passed
  - FAIL: at least one required check failed
- Include a short list of failed checks (names only) if FAIL.

## PASS / FAIL Criteria
PASS:
- All required sections are present.
- No required check is FAIL.

FAIL:
- Any required section is missing.
- Any required check is FAIL.
- Any unexpected crash/stack trace.
- Any evidence of gameplay commands being sent.

## What to paste back to the assistant
When asked for verification, paste:
- The full dwtest output (entire block)
- If FAIL: also paste
  - lua local L=require("dwkit.loader.init"); L.init()
  - dwboot
  - dwversion

## Change Control / Contract Stability
The following are part of the dwtest observable-output contract:
- Section headings and the required section order listed above
- PASS/FAIL tokens and the final verdict line wording (PASS/FAIL)
- Required printed identity fields (PackageRootGlobal, PackageId, EventPrefix, DataFolderName, VersionTagStyle)
- Required baseline outputs (Mudlet version line behavior, _VERSION line)

Allowed without bumping this document version:
- Fixing typos or improving explanatory text that does not change required output
- Adding clearly optional lines that do not rename or reorder required sections, and do not change PASS/FAIL semantics

Requires a version bump in this document (contract change):
- Renaming headings, changing section order, or removing required sections
- Changing PASS/FAIL tokens or verdict wording
- Changing required printed fields or required baseline line behavior

When a contract change is made:
- Bump the Version in this document
- Record the change in the Changes section below
- Obtain explicit acknowledgement in chat before merge

## Regression Notes
- dwtest must remain SAFE as the project grows.
- Any change to dwtest observable sections or PASS/FAIL logic requires:
  - A version bump in this document
  - Explicit acknowledgement in chat before merging

## Changes
v1.2
- Added required header mode line (quiet/verbose).
- Defined quiet-mode registry behavior as count-only (no list spam).
v1.1
- Declared this spec as the authoritative observable-output contract for dwtest.
- Added Change Control / Contract Stability rules for contract modifications.
