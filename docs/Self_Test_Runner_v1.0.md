# Self-Test Runner (dwtest) - Specification

## Version
v1.0

## Purpose
This document defines the required output sections and PASS/FAIL criteria for the DWKit self-test runner.
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

## Regression Notes
- dwtest must remain SAFE as the project grows.
- Any change to dwtest observable sections or PASS/FAIL logic requires:
  - A version bump in this document
  - Explicit acknowledgement in chat before merging
