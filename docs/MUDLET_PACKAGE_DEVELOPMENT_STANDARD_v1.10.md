============================================================
FULL ANCHOR PACK — MUDLET KIT GOVERNANCE (STORE IN PROJECT)
UPDATED: + Mudlet Input Line Paste Safety (single-line lua do...end)
UPDATED: + Command Surface Architecture Standard (Router + Handlers, Phase 2 triggers)
UPDATED: + Automation Policy: Passive Capture vs Active Polling + Essential Default Automation (declared, visible, controllable)
UPDATED: + Mudlet Verification Runner Standard: dwverify + verification.lua suites (scripted verification steps; Lua steps must be single-line)
UPDATED: + Verification Plan Split: verification.lua (stable runner) + verification_plan.lua (per-change suites)

GitHub PR Workflow via PowerShell (GitHub CLI “gh”)

Repo Hygiene: UTF-8 (NO BOM) + Versioned Git Hooks + LF enforcement

GitHub Branch Protection (solo repo) + gh merge policy notes (Section N.1)

AUTHORITATIVE INSTRUCTION — FOLLOW STRICTLY

This pack defines the mandatory development standard for this project.
It overrides all prior assumptions, habits, defaults, or stylistic choices.
Do not improvise. Do not refactor unless explicitly instructed.

NEW CHAT OPENER (PASTE THIS AS FIRST MESSAGE IN EVERY NEW CHAT)

Use the Project’s “Full Anchor Pack” as the authoritative reference for all work in this chat.
Do not deviate from its standards, contracts, naming, load order, and Definition of Done.
For every delivered item (new or changed), include Confidence + Assumptions + Verification Steps and do not proceed until I confirm PASS (or I paste logs for diagnosis).
If any requirement conflicts with the request, flag the conflict before implementing changes.

Workflow (Full-File Return Rule):

When requesting code changes, the user will paste the full current file(s).

The assistant MUST return the full updated file(s) in full (no patches/diffs).

If the assistant is unsure it has the latest file content, it MUST request the full file content first and provide the exact commands to collect it.

REFERENCE RULE (MANDATORY)

The Project’s “Full Anchor Pack” is the single source of truth for:

architecture, naming, module boundaries, load order

contracts and contract headers

event naming and payload rules (Event Registry requirement)

persistence and schema rules

UI governance (LaunchPad + GUI Settings + Generic GUI module rules)

testing requirements and self-test runner policy

release/packaging discipline and deprecation policy

verification gate / confidence policy (no blind progression)
- includes Mudlet verification automation via dwverify (verification suites) as mandatory baseline

command & alias registry policy (including gameplay wrappers)

iterative development/continuity and consistency lock/handoff policy

hallucination-risk handoff/reset policy

compatibility baseline policy (Mudlet + Lua)

FULL-FILE RETURN WORKFLOW (assistant returns full changed files; no patches)

Git/GitHub PR workflow discipline for this repo (PowerShell + gh CLI) (Section N.1)

Repo hygiene discipline (UTF-8 no BOM + versioned hooks + LF enforcement) (Section A.12)

All new modules, scripts, and changes MUST conform to this pack.

If a user request conflicts with this pack:

The conflict MUST be explicitly identified.

The resolution MUST be agreed in writing (in chat) before implementation.

If the pack must change, bump the standard version and record the change.

If any required identity fields or relevant contract sheets are missing:

Implementation must pause for clarification (do not guess).

PACKAGE IDENTITY (LOCKED — AUTHORITATIVE IN REPO)

Source of truth:

docs/PACKAGE_IDENTITY.md (repo)

Locked values (current):
PackageRootGlobal: DWKit
PackageId: dwkit
EventPrefix: DWKit:
DataFolderName: dwkit
VersionTagStyle: Calendar (format: vYYYY-MM-DDX)

Rule:

The Anchor Pack MUST match docs/PACKAGE_IDENTITY.md.

If identity values ever change, docs/PACKAGE_IDENTITY.md MUST be version-bumped and the decision recorded there.

==================================================
MUDLET PACKAGE DEVELOPMENT STANDARD v1.12 (FINALIZED)

Baseline additions included:

Compatibility Baseline (Mudlet 4.19.1 + Lua verification)

Command Surface Architecture Standard (thin alias router + handlers; Phase 2 triggers)

Section R Verification Gate + Confidence Policy

Section W Hallucination-Risk Handoff

Section S Command & Alias Registry (incl gameplay wrappers + runtime filters)

Section T Iterative Development + Continuity Policy

Section U Consistency Lock (no “new chef” drift)

Section V Chat Handoff Pack Template

Full-File Return Workflow (assistant returns full changed files; no patches)

Mudlet Input Line Paste Safety (single-line lua do...end)

GitHub PR Workflow via PowerShell (GitHub CLI “gh”) (Section N.1)

Repo Hygiene: UTF-8 NO BOM + versioned git hooks + LF enforcement (Section A.12)

GitHub Branch Protection (solo repo) + gh merge policy notes (Section N.1)

NEW: Automation Policy clarification:
Passive Capture (default-on allowed) vs Active Polling (timer automation),
and “Essential Default Automation” (declared, visible, controllable; small allowed list).

NEW: Mudlet Verification Runner Standard:
All changes MUST have Mudlet verification runnable via a single command: dwverify <suite>.
Verification sequences are stored as suites in src/dwkit/verify/verification_plan.lua (preferred),
with a stable runner in src/dwkit/verify/verification.lua.
Lua steps inside verification suites MUST be single-line only.

==================================================
ANCHOR PACK ALIGNMENT RECORD

2026-01-08: Aligned Anchor Pack to DWKit repo reality:

Identity fields are locked in docs/PACKAGE_IDENTITY.md (DWKit/dwkit/DWKit:/dwkit/Calendar).

Physical folder layout uses src/dwkit/<layer>.

Runtime command surface is dwcommands/dwhelp (not commands/help).

Docs are markdown in docs/*.md (per repo canonical files).

Self-test checks may be staged until subsystems exist (no premature blocking).

2026-01-10: Added Full-File Return Workflow:

For code changes, user pastes full file(s); assistant returns full updated file(s) (no patches).

If assistant is unsure the file is current, assistant must request file contents and provide exact dump commands.

2026-01-11: Added Mudlet Input Line Paste Safety:

Prevents stray multi-line pastes being sent to the MUD (Huh?!?) and accidental gameplay commands.

Locks single-line lua do...end for reload/init commands when using the input line.

2026-01-13: Added GitHub PR Workflow via PowerShell (gh CLI):

PR creation/review/merge can be done from PowerShell (minimize browser usage).

Tagging discipline updated: create annotated release tags on main HEAD after merge.

2026-01-14: Added Repo Hygiene Discipline:

Enforce UTF-8 NO BOM for docs and repo config files.

Versioned git hooks via .githooks and core.hooksPath.

Enforce LF for hooks and docs via .gitattributes.

Pre-commit must block BOM regressions and direct commits to main.

2026-01-14: Added Branch Protection + gh merge policy notes.

2026-01-18: Added Command Surface Architecture Standard (Router + Handlers) to prevent command_aliases.lua becoming a “god module”,
and to provide a Phase 2 trigger checklist for registry migration.

Solo-repo protection settings can block merges due to “review required” or “auto-merge disabled”.

Anchor Pack now defines the exact branch protection settings + the gh CLI merge commands to avoid being forced into browser UI.

2026-01-28: Clarified “Manual means manual” vs explicit automation:

Manual commands remain one-shot only.
Hidden automation is forbidden.

2026-01-28: Added “Passive Capture vs Active Polling” and “Essential Default Automation”:

Passive capture services (parsers/stores) may be enabled by default (SAFE: no command emission).
Active polling (timers/interval command emission) is automation.
A minimal, declared “Essential Default Automation” list may be enabled by default when required by core kit functionality (e.g., Presence/UI freshness),
but it must be visible, controllable, auditable, and never hidden.

2026-01-28: Added Mudlet Verification Runner Standard (dwverify + verification suites):

For every delivered change, Mudlet verification MUST be runnable via a single command:
dwverify <suite>.

Verification sequences live as named suites (preferred in verification_plan.lua).
The runner (verification.lua) remains stable; per-change suite edits should land in verification_plan.lua whenever possible.
Lua steps in suites MUST be single-line (lua do ... end).
PowerShell verification remains manual and is still provided in chat, but does not replace Mudlet verification gate.

==================================================
SECTION A — BOOTSTRAP (ALWAYS APPLIES)

COMPATIBILITY BASELINE (MANDATORY)

Target client baseline: Mudlet 4.19.1

Target runtime: Mudlet embedded Lua (verify at runtime; do not assume 5.2/5.3+ features)

Rules:
a) Do not use Lua features which may not exist in Mudlet’s Lua runtime unless a compatibility shim is provided.
b) Provide (or require) a simple runtime check command (later) that prints:

Mudlet version (if available)

_VERSION (Lua version string)
c) If any feature depends on runtime-specific behavior, it is "unverified" until tested in the user’s Mudlet 4.19.1 environment.

This work is product-grade Mudlet package development, not ad-hoc scripting.

All reusable logic MUST be implemented as modules that return a table.

Only ONE intentional global namespace is allowed: PackageRootGlobal.

Cross-module interaction is allowed ONLY via documented APIs or events.

No hardcoded profile names or absolute paths are permitted.

Manual means manual — and no hidden automation.

UI modules are consumers only; they own no logic or persistence.

No refactors, cleanups, or unrelated edits unless explicitly requested.

Every change must include test commands and expected results.

Stability and contract preservation take priority over new features.

AUTOMATION POLICY (LOCKED) — MANUAL VS PASSIVE CAPTURE VS ACTIVE POLLING (NO HIDDEN AUTOMATION)

Purpose:
Support reliable data-driven UI (Presence_UI, future ActionPad, etc.) that needs fresh snapshots (who, score, etc.)
without violating “Manual means manual”.

A) Definitions (LOCKED)
1) Manual action:
- Runs only as a direct result of a user-invoked command (alias/button/menu).
- Does NOT continue running after completion.
- Does NOT create persistent timers/triggers/schedulers.

1.1) Manual batch sequence (allowed):
- A one-shot verification or convenience batch that runs multiple commands as a direct result of one user invocation (example: dwverify).
- Any internal pacing timers used to sequence the batch MUST self-terminate and MUST NOT persist or re-schedule future actions.
- The batch MUST be visible by virtue of user invocation and its printed output; it must not be hidden.

2) Passive Capture (SAFE data processing):
- The kit parses/captures output ONLY when that output appears (e.g., user manually types “who”, or some other explicit action triggers it).
- Passive Capture MUST NOT issue MUD commands by itself.
- Passive Capture may be enabled by default because it is not timer automation and does not emit gameplay commands.

3) Active Polling (Automation):
- Any recurring timer, scheduled action, or autonomous trigger that can run without the user typing each time,
  including periodically issuing MUD commands (example: “who”, future “score”) and capturing/parsing outputs.

4) Hidden automation (FORBIDDEN):
Any Active Polling that:
- is not explicitly declared by governance/config,
- has no visible status,
- has no immediate stop control,
- or re-enables itself without the user’s instruction.

B) Non-negotiable rules (LOCKED)
1) Manual means manual:
- Manual commands MUST NOT create persistent timers/triggers,
  MUST NOT silently schedule future actions,
  and MUST NOT implicitly enable automation.

2) No hidden automation:
- Active Polling MUST NEVER be “surprise behavior”.
- If it runs, it MUST be discoverable, controllable, and auditable.

C) Automation modes (LOCKED)
DWKit classifies “automation mode” for any behavior that could run repeatedly:

1) manual
- No timers.
- Only direct user invocation.

2) opt-in
- Timers allowed ONLY after explicit user enabling via command and/or explicit config toggle.

3) essential-default
- Timers may be enabled by default ONLY if the job is explicitly listed in the “Essential Default Automation List” (Section A.E).
- Essential-default is allowed only for core kit functionality dependencies (e.g., Presence_UI requiring fresh WhoStore).
- Essential-default MUST still satisfy visibility + control + auditability + safe pacing.

Note:
- “essential-default” is not “hidden”.
- It is a declared baseline, with explicit startup declaration and a kill switch.

D) Allowed Active Polling requirements (MUST satisfy ALL) (LOCKED)
Active Polling (opt-in or essential-default) is allowed only if all are true:

1) Explicit governance and config:
- All polling jobs MUST be registered in a single automation manager (scheduler owner).
- Jobs MUST NOT be created ad-hoc by services.
- Default state MUST be driven by a visible config surface, not hardcoded surprises.
- Essential-default is allowed only for jobs in Section A.E.

2) Visibility:
- A status command MUST exist (e.g., dwauto status or dwservices status) that shows:
  job name, enabled state, interval, last-run, next-run (if available).
- Enabling/disabling MUST produce a clear, user-visible confirmation line.

3) Control / kill switch:
- A single global kill switch MUST exist (e.g., dwauto off) that cancels all timers/triggers and prevents further autonomous commands.
- Per-job stop MUST exist (e.g., dwauto off who).

4) Auditability:
- Each automated run MUST be traceable via logs at controlled verbosity (quiet by default),
  including job name, interval, and last-run timestamp.
- Audit logs MUST avoid spam; use summary style unless debug is explicitly enabled.

5) Safe-by-default pacing:
- Defaults MUST be conservative (no spam).
- Rate limits MUST be respected.
- If the MUD enforces flood limits, the kit must stay well below them.

6) No self-revive:
- Active Polling MUST NOT re-enable itself on reload/install unless enabled in visible config.
- If autostart exists (opt-in remembered state or essential-default baseline), startup MUST print one clear line stating what is running.

E) Essential Default Automation List (LOCKED)
Rule:
Only the following jobs are allowed to be “essential-default” ON.

Essential Default Jobs (current agreed baseline):
1) WhoPoll (purpose: keep WhoStore reasonably fresh for Presence/UI dependency)
- Mode: essential-default
- Default: ON
- Notes:
  - Must remain conservative and quiet.
  - Must be visible + controllable (status + kill switch).
  - Must be safe to disable (UI shows “stale” state rather than breaking).

Non-essential jobs:
- MUST be opt-in and default OFF unless this Anchor Pack is updated and version-bumped.

Explicitly NOT essential-default (current agreement):
- ScorePoll (future) default OFF until ActionPad actually requires it and the user explicitly enables it.
- Any other polling jobs default OFF (opt-in).

F) Service vs Scheduler separation (LOCKED)
- Parsing/capture services (e.g., WhoStore, future ScoreStore) may passively process output when it appears (Passive Capture).
- Active command emission on intervals MUST be owned by a dedicated scheduler/automation manager and MUST follow this Automation Policy.
- Services MUST NOT silently create timers. Schedulers MUST be explicitly controlled.

G) UI dependency rule (LOCKED)
- UI modules MUST tolerate missing or stale data (show “stale/unknown” state) instead of forcing hidden automation.
- If a UI feature requires Active Polling to be useful, that dependency MUST be documented in:
  - the module contract sheet, and
  - the relevant service/automation job contract.

MUDLET INPUT LINE PASTE SAFETY (LOCKED)

Problem: Multi-line Lua pasted into the Mudlet input line can send stray lines to the MUD, causing “Huh?!?” and accidental gameplay commands.

Rules:
a) When running Lua from the Mudlet INPUT LINE, always use a SINGLE-LINE: lua do ... end
b) Do NOT paste multi-line Lua into the input line.
c) If multi-line Lua is needed, use the Mudlet Lua Console (or an editor-driven script file), not the input line.

Canonical reload/init pattern (single line):
lua do package.loaded["dwkit.tests.self_test_runner"]=nil; local L=require("dwkit.loader.init"); L.init(); print("[DWKit] init OK") end
Then run:
dwtest quiet

REPO HYGIENE: ENCODING + HOOKS + LF (LOCKED)
Goal:
Prevent hidden encoding characters (UTF-8 BOM / mojibake) and cross-PC line-ending drift from breaking hooks, docs, and copy/paste reliability.

Rules (MANDATORY):
A) UTF-8 BOM policy

docs/*.md MUST be UTF-8 (NO BOM).

.gitattributes MUST be UTF-8 (NO BOM) and MUST end with a newline.

Any template/spec doc intended for copy/paste MUST be kept free of hidden leading characters.

B) Versioned hooks policy

Hooks MUST be versioned in repo under: .githooks/

Git MUST be configured to use them:

git config core.hooksPath .githooks

pre-commit MUST enforce:

Block direct commits to main

Block UTF-8 BOM in docs/*.md

Block UTF-8 BOM in .gitattributes

C) LF enforcement (docs + hooks)

.githooks/* MUST be LF line endings (shell compatibility).

docs/*.md MUST be LF line endings to reduce cross-editor drift.

.gitattributes MUST enforce these rules.

Required smoke checks (run before/after docs hygiene changes, and once per new machine):

Confirm hooks path:
git config --show-origin --get core.hooksPath
Expected: .githooks

Confirm pre-commit exists and is used:

Attempt a commit on main; it MUST be blocked with a clear error.

BOM scan (docs):

PowerShell BOM scan loop over docs/*.md (checks EF BB BF).

Mojibake scan (docs):
Select-String -Path .\docs*.md -Pattern 'ÃƒÂ¢|ÃƒÆ’|Ã¯Â¿Â½' -SimpleMatch
Expected: no matches

.gitattributes check (BOM + newline):

First 3 bytes must NOT be EF BB BF

File must end with newline

PowerShell foot-gun rule (LOCKED):

Never type .gitattributes lines directly into the PowerShell prompt.
They are file rules, not commands.
Always edit .gitattributes using an editor or Set-Content / WriteAllText.

==================================================
SECTION B — CANONICAL PACKAGE IDENTITY (MANDATORY)

Rules:

Event names MUST start with EventPrefix.

Require paths MUST start with PackageId.

Persistence folder MUST use DataFolderName.

No module may invent its own prefixes or naming conventions.

If identity fields are missing or inconsistent, implementation must pause.

Source of truth:

docs/PACKAGE_IDENTITY.md (repo authoritative)

==================================================
SECTION C — FILE/FOLDER NAMING & LAYOUT (MANDATORY)

Canonical layout (physical repo paths):

src/dwkit/core (logging, safe calls, helpers, identity, runtime baseline)

src/dwkit/config (config surface, defaults, profile overrides)

src/dwkit/persist (paths, schema IO, migrations helpers)

src/dwkit/bus (event registry, event bus, command registry)

src/dwkit/services (parsers/stores/business logic)

src/dwkit/ui (GUI modules, consumer-only)

src/dwkit/integrations (optional external integrations; degrade gracefully)

src/dwkit/tests (tests and self-test runner helpers)

src/dwkit/loader (thin bootstrap scripts / entrypoints)

Verification runner path (locked):
src/dwkit/verify (Mudlet verification runner modules; dwverify suites)

Verification module split (preferred standard):
- src/dwkit/verify/verification.lua (stable runner engine; rarely changes)
- src/dwkit/verify/verification_plan.lua (per-change suites/steps; changes frequently)

Repo hygiene files (canonical):

.githooks/pre-commit

.gitattributes

Naming rules:

Filenames: choose one style and remain consistent (snake_case recommended).

UI modules live under src/dwkit/ui and comply with UI contract rules.

Services live under src/dwkit/services and MUST NOT depend on UI.

Integrations live under src/dwkit/integrations and must degrade gracefully.

Documentation files (repo canonical, markdown):

docs/GOVERNANCE.md

docs/Architecture_Map_v1.0.md

docs/PACKAGE_IDENTITY.md

docs/Command_Registry_v1.0.md

docs/Event_Registry_v1.0.md

docs/Self_Test_Runner_v1.0.md

docs/DOCS_SYNC_CHECKLIST.md

docs/MUDLET_PACKAGE_DEVELOPMENT_STANDARD_v1.10.md (this file; versioned by content header)

==================================================
SECTION D — CORE DEVELOPMENT STANDARD

PURPOSE
Ensure correctness, stability, predictability, and long-term maintainability under the Compatibility Baseline.

MODULE DESIGN RULES

All reusable code MUST live in modules.

Modules MUST return a table defining their public API.

Internal state MUST remain local to the module.

No module may read or mutate another module’s internal tables.

NAMESPACE & GLOBAL RULES

Only PackageRootGlobal may be global.

Subsystems must be accessed through PackageRootGlobal or require().

Never leak globals unintentionally.

All filesystem access must be per-profile and runtime-derived.

CONTRACT-FIRST DEVELOPMENT
Before implementing or modifying behavior, the module contract must be clear:

What the module owns

What it exposes

What it emits

What it persists

What must never change silently
If unclear, pause for clarification.

CONTRACT HEADER (MANDATORY FOR CORE MODULES)
Each core module MUST declare, in a header comment:

Module Owner

Purpose (does / does not do)

Public API

Events Emitted (names + payload shape)

Events Consumed

Persistence (path rule + schema version)

Automation Policy (manual / opt-in / essential-default) — must align with Section A Automation Policy
If not applicable, state “None”.

EVENTS & DATA CONTRACTS

Event names are namespaced (EventPrefix).

Event payloads are contracts.

Payload changes REQUIRE explicit acknowledgement.

Breaking changes REQUIRE version or schema bumps.

No silent behavioral or data changes.

PERSISTENCE RULES

Per-profile and package-owned only.

Stored data includes schema version + timestamp.

Modules access only their own persistence files.

Migrations are explicit when schemas change.

CHANGE DISCIPLINE

Identify exact modules involved.

State contract preserved/modified.

Minimal code changes only.

One objective per change.

FULL-FILE RETURN RULE:

For any changed file, the assistant MUST return the FULL updated file content (no diffs/patches).

The assistant MUST NOT propose edits against partial/uncertain file content.

If the assistant is not certain it has the latest file, it MUST request the full file content first and provide exact dump commands.

Bump version identifiers with meaningful suffixes.

TESTING REQUIREMENT
Every change MUST include:

Mudlet verification runnable via dwverify <suite> (Section R)
- if verification_plan.lua suites must be updated/created, include it as part of the delivery
- the runner (verification.lua) should NOT be churned unless new runner capability is required

Manual test command(s)

Expected observable behavior

Regression checklist
If it cannot be tested, it is incomplete.

==================================================
SECTION E — CENTRAL EVENT REGISTRY (SINGLE SOURCE OF TRUTH)

One Event Registry (module or doc).

All event names MUST be declared there.

Contract sheets reference event names from the registry.

No module invents event strings without updating the registry.

Registry includes:

eventName

payload fields + meaning

producer module

consumers (if known)

payload version/schema (if applicable)

==================================================
SECTION F — LOAD ORDER & STARTUP BEHAVIOR (MANDATORY)

Load order is a contract:

Core utilities

Persist + Config

Bus/Event Registry

GUI Settings (before any UI registration)

Services

UI modules register (gated by settings)

LaunchPad restore visibility (opt-in) after registration window

Rules:

No module assumes others unless earlier in order.

UI tolerates events before being shown (cache then refresh).

No gameplay commands during load unless explicitly opt-in.

No Active Polling during load unless explicitly enabled by config (opt-in or essential-default),
and if autostart is supported, it MUST be visible + declared at startup (Section A Automation Policy).

==================================================
SECTION G — NO CYCLIC DEPENDENCY POLICY

Dependencies flow downward only:
Core -> Persist/Config -> Bus -> Services -> UI

Rules:

Services MUST NEVER depend on UI.

UI may depend on services (events/APIs) only.

LaunchPad may call UI handlers; UI must not depend on LaunchPad internals
beyond registration boundary.
If a cycle appears, redesign is required.

==================================================
SECTION H — LOGGING & ERROR POLICY

Consistent log prefix with PackageId/ModuleName.

Boundary errors are caught and returned (no crash).

User-facing errors are copy/paste friendly and include:
module, action, error text.

Silent failures not allowed.

LaunchPad wraps UI handler calls and emits namespaced error events.

==================================================
SECTION I — CONFIG POLICY (ONE CONFIG SURFACE)

One config surface (single owner module).

Supports defaults + per-profile overrides + schema versioning.

No random per-module config globals/files.

Provide a status/dump method.

==================================================
SECTION J — CROSS-PROFILE / BROADCAST BOUNDARY (OPTIONAL)

If cross-profile exists:

One Broadcast Owner module.

Only broadcast-allowed events may be sent.

Payload includes version + sender identity.

Disabled by default; must not break single-profile use.

==================================================
SECTION K — UI STABILITY + LAUNCHPAD POLICY (REQUIRED)

Single UI control surface: LaunchPad.

UI registration includes: id, label, show, hide, isVisible.

UI modules are idempotent, reload-safe, dependency-safe, consumer-only.

New UI is incomplete until controllable via LaunchPad and passes smoke tests.

==================================================
SECTION L — GUI SETTINGS (PER-PROFILE) (REQUIRED)

Per-profile persistent settings under package-owned data dir.

Distinguish enabled vs visible.

Enabled persistence mandatory. Visible persistence optional (opt-in).

LaunchPad must obey GUI Settings.

No surprise windows by default (restore visible is opt-in).

==================================================
SECTION M — TESTING ESCALATION (SELF-TEST RUNNER STANDARD)

Provide a safe self-test runner command (no gameplay commands unless explicitly opted in by config/policy).

Reports PASS/FAIL for:
core loaded, config loaded, event registry present, GUI settings loaded,
LaunchPad registry status, services health, optional UI checks,
AND compatibility baseline info (Mudlet/Lua environment string outputs).

Copy/paste friendly summary.

New modules add at least one self-test check.

Implementation staging rule:

If a subsystem is not yet introduced (e.g., GUI Settings, LaunchPad, UI),
the self-test runner may omit those checks until implemented, but MUST add them
once the subsystem exists.

==================================================
SECTION N — RELEASE / PACKAGING DISCIPLINE

Release Checklist (mandatory for each release):

Version tag applied:

Tag:

Date:

Changelog updated:

Added:

Changed:

Fixed:

Deprecated:

Removed:

Tested list recorded:

Core load:

Persist/config load:

Event registry sanity:

Service smoke tests:

LaunchPad commands:

UI idempotence:

Self-test runner PASS:

Compatibility baseline verified (Mudlet/Lua string outputs):

Automation manager status (if present):
- essential-default jobs declared at startup
- status command shows expected enabled/disabled

Mudlet dwverify suites executed (record which suites):
- dwverify <suite> results (PASS/FAIL) captured

Cross-profile (if applicable):

Migration notes included (if any schema/contract changes):

Schemas changed:

Migration steps:

Backward compatibility:

Breaking changes:

Packaging validated:

Fresh profile install test:

Upgrade install test:

No hardcoded paths/profile names:

PR + merge discipline (repo workflow):

Changes must land in main via PR (not direct push to main), unless explicitly agreed.

Preferred workflow is gh CLI from PowerShell (Section N.1).

SECTION N.1 — GITHUB PR WORKFLOW (POWERSHELL + GH CLI) (LOCKED)

Goal:
Do PR creation, review, and merge from PowerShell using GitHub CLI (“gh”),
instead of relying on the browser UI.

A) One-time setup per machine

Install / upgrade GitHub CLI:
winget install --id GitHub.cli -e

Verify:
gh --version

Authenticate (recommended default):
gh auth login

Notes:

gh may use a device-code flow that opens a browser once for the login step.
After that, PR actions can be fully done from PowerShell.

Alternative (advanced): gh auth login --with-token (uses a PAT).
Only use if you already manage tokens securely.

Enable versioned hooks for this repo (MANDATORY):
git config core.hooksPath .githooks

Verify hooks path:
git config --show-origin --get core.hooksPath
Expected: .githooks

B) GitHub branch protection policy (SOLO REPO, NO BROWSER WORKFLOW)

Goal:
Keep “Require a pull request before merging” ON (so main stays protected),
but ensure gh CLI merges never get blocked by impossible requirements (self-approval, missing CI, auto-merge disabled).

Mandatory settings (recommended for this repo):

Branch protection for main:

Require a pull request before merging: ON

Require approvals: OFF

Require status checks: OFF (until CI exists)

Require conversation resolution: OFF (optional; turn ON only if you use reviewers)

Require signed commits: OFF (optional; only if you already use signing)

Require linear history: optional (OFF is fine; squash merges already linearize)

Do not allow bypassing the above settings: OFF (owner must be able to merge)

Allow auto-merge: optional (can be OFF; gh merge works without it)

Restrict who can push to matching branches: optional (ON if available; add yourself)

Allow force pushes: OFF

Allow deletions: OFF

Automatically delete head branches: ON (nice-to-have)

Policy rule:
If “Require a pull request before merging” is ON, then gh merge MUST succeed without:

approvals (since solo)

CI checks (since none)

auto-merge (since may be disabled)

If gh merge reports “base branch policy prohibits the merge”, it means the branch protection has at least one requirement still ON that cannot be satisfied in a solo/no-CI repo (usually approvals or required checks).

C) Standard PR workflow (start to end)
(Assume you are inside repo root: C:\Projects\dwkit)

Confirm you start from clean main:
git checkout main
git pull
git status -sb

Create a branch (use meaningful name):
git checkout -b <branch-name>

Do work (edit files), then verify locally:

run your Mudlet verification steps (Section R) as required (dwverify <suite>)

keep scope minimal and objective single

Stage and commit:
git status
git add <paths...>
git commit -m "<message>"

Push branch and set upstream:
git push --set-upstream origin <branch-name>

Create PR:
gh pr create --base main --head <branch-name> --title "<title>" --body "<body>"

After this, gh prints the PR URL and PR number.

Review PR from PowerShell (no browser required):

See status:
gh pr status

View details (title/body/metadata):
gh pr view <PR_NUMBER>

View comments:
gh pr view <PR_NUMBER> --comments

View diff:
gh pr diff <PR_NUMBER>

View checks (if your repo has CI):
gh pr checks <PR_NUMBER>

Merge PR (preferred: squash + delete branch):
gh pr merge <PR_NUMBER> --squash --delete-branch

Notes (locked behavior expectations):

gh pr merge may update origin/main and may switch you back to main, but DO NOT assume.

Always run the “After merge sync + verify” block below.

If merge fails with policy error:

Do NOT attempt self-approve (GitHub blocks approving your own PR).

Fix branch protection to match “Solo repo policy” in Section N.1.B (approvals OFF, checks OFF).

Retry: gh pr merge <PR_NUMBER> --squash --delete-branch

Avoid these flags unless you explicitly intend it:

--auto requires “Allow auto-merge” enabled on GitHub (often OFF by default).

--admin bypasses protections (works only if you are admin/owner and bypass is allowed).

After merge sync + verify (MANDATORY):
git status -sb
git checkout main
git pull
git status -sb
git log -1 --oneline --decorate
git rev-parse HEAD
git rev-parse origin/main
Expected:

status shows main...origin/main (no ahead/behind)

HEAD hash == origin/main hash

D) Release tagging discipline (IMPORTANT)
Rule:

Create the release tag on main HEAD AFTER the PR is merged, so the tag points
at the permanent main history (not a branch commit that may disappear via squash).

Verify current HEAD is what you want:
git checkout main
git pull
git log -1 --oneline --decorate

Create annotated tag:
git tag -a <tag> -m "<tag message>"

Push tag:
git push origin <tag>

Verify tag target equals origin/main:
git rev-parse --verify origin/main
git rev-parse --verify '<tag>^{}'

Expected: both hashes match.

E) If you accidentally tagged the wrong commit (fix tag safely)

Delete local tag (ok if it exists):
git tag -d <tag>

Delete remote tag:
git push origin :refs/tags/<tag>

Recreate annotated tag on current main HEAD:
git checkout main
git pull
git tag -a <tag> -m "<tag message>"

Push tag:
git push origin <tag>

F) PowerShell note (caret braces in tag deref)
PowerShell may misparse:
git show -s --oneline <tag>^{}
Use one of these instead:

Use PowerShell stop-parsing:
git --% show -s --oneline <tag>^{}

Or use rev-parse verification:
git rev-parse --verify '<tag>^{}'

This rule avoids the “fatal: ambiguous argument 'xml'” style errors seen before.

==================================================
SECTION O — DEPRECATION POLICY

Deprecate in vX, remove in vY (Y later than X).

Deprecations documented in changelog + contract sheet + event registry.

Deprecated API/event keeps working or provides compatibility shim.

Emit non-spam warning log when deprecated API is used.

Provide replacement in same release as deprecation.

Removal requires migration notes and internal consumers updated first.

Immediate removal only in explicit breaking-change release.

==================================================
SECTION P — DEFINITION OF DONE

A change is not “done” unless:

scope + single objective defined

contracts respected and updated

event registry updated if event changes

minimal edits only

tests + expected results provided

regression checklist passed

version bumped

“not touched” list stated

Mudlet verification gate satisfied:
- dwverify <suite> executed
- PASS confirmed by user (or logs provided for diagnosis)

==================================================
SECTION Q — MODULE CONTRACT SHEET TEMPLATE

MODULE CONTRACT SHEET

Module Name:

Version:

Owner Responsibility:

Purpose (does / does not):

Public API:

Events Emitted:

Events Consumed:

Persistence:

Automation Policy:

Dependencies:

Invariants:

Test Commands:

==================================================
SECTION R — VERIFICATION GATE + CONFIDENCE POLICY (NO BLIND PROGRESSION)

Problem:
Assistants may assume a change or new item works and proceed without proof.

Rule (Mandatory):
For ANY delivered item (new module, new feature, design, integration, bug fix,
refactor, config change, or guidance that affects implementation), the assistant
MUST require verification before moving to the next item.

No “100% working” claims:

The assistant MUST NOT claim anything is “100% working/correct” unless it can be
logically proven from the provided code/spec alone AND does not depend on runtime.

Anything depending on Mudlet runtime, profile state, installed packages,
triggers, load order, timers, or external systems is always “unverified”
until the user runs validation steps and reports results.

R.1 — Mandatory Mudlet Verification Runner (dwverify) (LOCKED)

Goal:
Make verification repeatable and one-command runnable inside Mudlet, instead of manual multi-step typing.

Rule (Always-On):
Every delivered change MUST include Mudlet verification runnable via:
dwverify <suite>

Implementation Standard (LOCKED):
1) Repo must contain:
src/dwkit/verify/verification.lua
- stable verification runner engine that executes named suites.

2) Repo should contain (preferred):
src/dwkit/verify/verification_plan.lua
- per-change suite definitions and steps (frequently updated).
- The runner loads this plan module (best-effort) and merges/overrides suites.

3) Mudlet must provide an alias/command:
dwverify [suite]
- typing dwverify triggers the runner and runs the suite steps.
- dwverify MUST be installed from code (tempAlias created by DWKit install path), not stored manually in Mudlet UI.

4) For every delivered change, the assistant MUST provide:
- the suite name to run (example: dwverify whostore)
- updated suite steps (prefer updating verification_plan.lua; update runner only if new runner capability is required)
- expected observable output/behavior (PASS/FAIL criteria)

5) PowerShell verification:
- still provided in chat as manual steps
- complements Mudlet verification but does not replace it

Safety and Automation Policy alignment:
- dwverify is a Manual batch sequence (Section A.1.1).
- It may run multiple commands, but MUST be user-invoked, one-shot, and self-terminate.
- It MUST NOT enable or create persistent polling jobs.
- Any internal pacing timers used to sequence steps must self-cancel and must not schedule future runs.

R.2 — Verification Steps Format (LOCKED)

Verification steps MUST be explicit commands the user can run and observe.

For Mudlet verification via dwverify:
- steps are stored as a list under the suite inside verification_plan.lua (preferred) or verification.lua (fallback).

Allowed step types:
A) DWKit commands/aliases (example: dwwho, dwwho refresh, dwservices status)
B) Raw MUD commands when needed (example: who)
C) Mudlet Lua commands ONLY if single-line (see R.3)

R.3 — Single-line Lua Rule in Verification (LOCKED)

Because multi-line Lua pasted/typed can be accidentally sent to the MUD (Huh?!?) and violates paste safety:

Any Lua command included in verification suites MUST be single-line only.

Approved patterns (examples):
lua do <...> end
lua <single-line expression>

Forbidden:
- any multi-line Lua block in a verification step
- any verification step that contains newline characters

If multi-line Lua is required for a complex check:
- implement it as a module function and call it via a single-line lua do ... end
- OR run it in the Mudlet Lua Console (not as a step)

R.4 — What the assistant MUST provide (every time)

Confidence Statement: HIGH / MEDIUM / LOW + short reason

Assumptions: list assumptions; if unknown, require user confirmation

Verification Steps:
- Mudlet: dwverify <suite> + expected behavior
- (Optional) additional direct commands if needed
- PowerShell: manual commands (as required) to verify repo hygiene or git state

Success/Fail Criteria: PASS + FAIL conditions

Output Collection: what logs/output/screenshots user should paste back

Regression Checks: 1–3 quick checks

Proceeding Rule:

The assistant MUST NOT move on until user confirms PASS or provides output for diagnosis.

User override:

If user explicitly says “Proceed without verification”, assistant may proceed,
but must label subsequent work as “unverified chain”.

==================================================
SECTION W — HALLUCINATION-RISK HANDOFF (RESET RULE)

Goal:
When hallucination risk is high, stop, reset scope, and carry forward only
verified facts and required artifacts into a new chat.

Trigger conditions (any one triggers a handoff recommendation):

Confidence is LOW, or

More than 3 critical assumptions are required, or

Required artifacts (scripts/logs/identity/events) are missing, or

The change spans 3+ modules at once, or

The current chat is too long/bloated to safely reference prior details.

Assistant behavior when triggered:

Declare: "High hallucination risk" and why (one short paragraph).

Do NOT propose further implementation changes.

Produce a complete Chat Handoff Pack (Section V) filled with:

identity fields

objective (single sentence)

scope (in/out)

verified working list

known issues list

last verified PASS test outputs (including dwverify suite results if applicable)

required artifacts to paste (exact dump commands / files needed next)

Stop and wait for the user to start the new chat and paste the handoff.

Note:
A new chat does not replace verification. Section R still applies.

==================================================
SECTION S — COMMAND & ALIAS REGISTRY (SINGLE SOURCE OF TRUTH)

SECTION S.0 — COMMAND SURFACE ARCHITECTURE STANDARD (PHASE 1 -> PHASE 2)

Problem:
As DWKit grows, a single monolithic alias/command file becomes a “god module” that is hard to maintain, hard to test, and high risk to change.

Decision (LOCKED):
DWKit uses a two-layer Command Surface architecture:

A) Alias Router Layer (transport)
- File: src/dwkit/services/command_aliases.lua
- Responsibilities (allowed):
  - install/uninstall tempAliases
  - parse user input patterns
  - route to command handlers
  - store alias IDs for cleanup
- Responsibilities (NOT allowed):
  - no heavy business logic
  - no subsystem implementations
  - no large shared utilities

B) Command Handler Layer (application)
- Location: src/dwkit/commands/
- Responsibilities:
  - implement command behavior (logic, formatting, calls into services)
  - keep each command focused and small
  - provide stable public handler API surface

C) Shared Utility Layer (foundation)
- Location: src/dwkit/util/ (or src/dwkit/core where appropriate)
- Responsibilities:
  - reusable helpers (safe printing, bounded table dump, formatting helpers)
  - must NOT live inside command_aliases.lua

Phase plan (forward compatible):
PHASE 1 (NOW): Router + Handlers
- Aliases route to handler modules.
- Handler modules own implementation.
- command_aliases.lua stays thin and stable.

PHASE 2 (LATER): Metadata-backed Command Registry
- Commands register metadata (id/description/usage/examples/safety/mode).
- dwhelp/dwcommands output derives from registry data.
- Docs sync is enforced from the same metadata structure.

Phase 2 triggers (start migration when 2+ are true):
- 25+ user-facing commands exist
- dwhelp/dwcommands becomes painful to maintain manually
- safety classification / permission tiers become necessary (SAFE vs gameplay wrappers)
- argument parsing consistency becomes a recurring problem
- automatic docs/help generation is desired

Definition of Done (Command Surface):
- New commands MUST be implemented as a handler module first.
- command_aliases.lua MUST NOT grow with business logic.
- Any new gameplay-sending command MUST still comply with Section S registry requirements.

Problem:
Large kits accumulate many aliases. Without a master list, usage becomes
inconsistent and different chats create divergent commands.

Rule (Mandatory):
There MUST be a single Command & Alias Registry for all user-facing commands,
including kit commands AND gameplay command wrappers.

Two command types:
A) Kit Commands:

UI control, config, debug, diagnostics, tests, verification

Must not send gameplay actions unless explicitly a wrapper
B) Gameplay Command Wrappers:

Aliases/commands which send text to the MUD (skills/spells/practice/score/look/etc)

Must be clearly labeled to prevent accidental execution

Must be manual by default unless explicitly opt-in

Automation note (LOCKED):
If any gameplay wrapper is ever executed on a timer/interval, it becomes Active Polling (Automation)
and MUST comply with Section A Automation Policy (visibility, kill switch, auditability, safe pacing, no hidden behavior).
Essential-default automation is only allowed if explicitly listed in Section A.E and version-bumped.

Registry requirements (all commands):
Each command MUST be recorded with:

command name

owner module

purpose (one line)

syntax

examples (at least 1)

safety classification:

SAFE (no gameplay output sent)

COMBAT-SAFE (sends to game but designed to be safe in combat)

NOT SAFE (sends to game and may have side effects or spam)

mode:

manual / opt-in / essential-default

expected output/behavior

Additional required fields for Gameplay Command Wrappers:

sendsToGame: YES

underlyingGameCommand: <string> (e.g. "practice", "cast 'heal'", "score -l")

sideEffects: <text> (mana use, spam output, changes state, etc.)

rateLimit: <optional> (if applicable)

wrapperOf: <optional> (if wrapper calls another wrapper)

Naming policy:

DWKit user-facing typed commands MUST use the "dw" prefix to avoid collisions
with the MUD's own commands.

This "dw" prefix is the approved namespacing scheme for this project.

Internally, modules/services may also use subsystem prefixes in code, but the
user-facing command namespace remains "dw*".

Runtime help (REQUIRED):

The package MUST provide runtime commands to list and inspect commands sourced
from the same registry data.

DWKit canonical discovery surface:

dwcommands

Lists all registered commands (kit + gameplay wrappers)

Shows: name + short purpose + owner module + safety

dwcommands safe

Lists only SAFE commands (no gameplay commands)

dwcommands game

Lists only gameplay command wrappers (sendsToGame: YES)

dwhelp <cmd>

Shows full detail for one command:
syntax, examples, safety, mode, owner, side effects (if gameplay), notes

Consistency rule:
Docs and runtime output MUST derive from the same registry data structure.
No command may be added unless it is added to the registry first.

Note:
Alternative command names (e.g., commands/help) may be added later ONLY as
compatibility aliases pointing to the same underlying registry/runtime surface.

Deprecation integration:
Deprecated commands MUST remain documented with:

replacement command

deprecate version (vX)

remove version (vY)

==================================================
SECTION T — ITERATIVE DEVELOPMENT + CONTINUITY POLICY (REAL-WORLD MODE)

Reality:
The user and assistant are not perfect. Complex kits require iteration across
multiple chats. Issues will appear during integration and must be ironed out.

Rule (Mandatory):
Work MUST be planned and executed as iterative cycles, not single-pass delivery.

Iteration Cycle (required):

Define Scope (single objective) + In-scope modules + Out-of-scope modules.

Implement smallest safe change.

Provide Confidence + Assumptions + Verification Steps (Section R).

User runs tests and pastes output/logs:
- includes dwverify <suite> results as the default Mudlet verification gate.

Diagnose and patch until PASS.

Only then proceed to the next objective.

Continuity Requirements (carry-forward across chats):
For every new chat, the user will provide:

New Chat Opener

current objective

current known issues

current versions/tags of involved modules

last known PASS tests (what has been confirmed working; include dwverify suite results if applicable)

any failing logs since last step

Assistant responsibilities in every chat:

Re-state current objective and scope at the start of work.

Maintain a “Known Issues” list and close items only after PASS verification.

Maintain a “Verified Working” list (features/modules confirmed PASS).

Maintain a “Next Steps” list that is gated by verification (no skipping).

Rollback discipline:

When a fix risks regression, prefer small, reversible patches.

If uncertainty is high, provide a rollback plan or revert patch.

Definition:
A feature is not considered “done” until it has been verified PASS in the user’s
environment, and recorded in the “Verified Working” list.

==================================================
SECTION U — CONSISTENCY LOCK (NO “NEW CHEF” DRIFT)

Problem:
Different chats can drift in style, standards, naming, and assumptions, causing
inconsistent design and regressions.

Rule (Mandatory):
This project runs under a single standard (this Anchor Pack). The assistant must
behave as if it is the same developer across all chats.

Consistency Requirements (must remain stable):

Same governance:

Use this Anchor Pack as source of truth (Reference Rule).

Respect load order, no cycles, module boundaries, UI governance.

Same output discipline:

Minimal edits, one objective per change.

Provide Confidence + Assumptions + Verification Steps.

Do not proceed until PASS (unless user explicitly overrides).

FULL-FILE RETURN RULE: assistant returns full updated file(s) only; no patches.

Same naming discipline:

Use PackageRootGlobal/PackageId/EventPrefix/DataFolderName exactly.

Use the canonical folder layout.

Use the command naming policy (user-facing namespace is dw*).

Same documentation discipline:

Maintain Command & Alias Registry.

Maintain Event Registry.

Maintain module contract headers.

Maintain docs sync checklist discipline (docs/DOCS_SYNC_CHECKLIST.md).

Same decision process:

If uncertain, do not guess.

Ask for the missing inputs required by the pack.

Prefer small reversible changes.

Keep a running “Known Issues” list and “Verified Working” list.

If any assistant response conflicts with these requirements:

The user should treat it as non-compliant.

The assistant must correct course immediately using the Anchor Pack.

==================================================
SECTION V — CHAT HANDOFF PACK (PASTE INTO NEW CHAT)

New Chat Opener:

<PASTE THE NEW CHAT OPENER FROM THIS ANCHOR PACK>

Identity (confirm unchanged):
PackageRootGlobal: DWKit
PackageId: dwkit
EventPrefix: DWKit:
DataFolderName: dwkit
VersionTagStyle: Calendar (format: vYYYY-MM-DDX)

Current objective (single sentence):

Objective:

Scope:

In-scope modules/files:

Out-of-scope modules/files (must NOT change):

Current status:

Verified Working (PASS):

Item 1:

Item 2:

Known Issues (OPEN):

Issue 1:

Issue 2:

Last change delivered (what was modified):

Module(s) changed:

Version tags:

Summary of change:

PR link (if any):

Tag (if any):

Verification results:

Mudlet suite executed:
dwverify <suite>

Outputs/logs (paste):

PASS/FAIL verdict:

Next gated steps (do NOT start until current step is PASS):

Next step 1:

Next step 2:

Required artifacts for next change (Full-File Return Workflow):

Repo state:

git status

git rev-parse HEAD

git branch --show-current

Full file dumps for any file to be changed:

PowerShell: Get-Content -Raw .<path-to-file>

Optional (to prove committed vs working tree):

git show HEAD:<path-to-file>

git diff -- <path-to-file>

Optional (PR workflow context if relevant):

gh pr status

gh pr view

==================================================
ONE-PAGE ARCHITECTURE MAP v1.1

CANONICAL IDENTITY:

One package root global (only allowed global).

One require prefix (PackageId).

One event prefix (EventPrefix).

One per-profile data folder name (DataFolderName).

CANONICAL LAYOUT (DWKit repo physical paths):

src/dwkit/core

src/dwkit/config

src/dwkit/persist

src/dwkit/bus

src/dwkit/services

src/dwkit/ui

src/dwkit/integrations

src/dwkit/tests

src/dwkit/loader

src/dwkit/verify

LAYERS (NO CYCLES):

Core

Persist + Config

Bus / Event Registry

Services (parsers/stores; own persistence; emit events; getters)

GUI Settings (enabled mandatory; visible optional)

LaunchPad (registry + control; gated by settings; restore visible opt-in)

UI Modules (consumer-only; idempotent; reload-safe; register if enabled)

STARTUP ORDER:
Core -> Persist/Config -> Bus -> GUI Settings -> Services -> UI register -> LaunchPad restore (opt-in)

DATA FLOW:
Game Output -> Services parse -> Services update -> Services emit -> UI refresh

CONTROL FLOW:
User -> LaunchPad -> UI show/hide/toggle
User -> Service manual command -> Service update -> emit
User -> dwverify -> scripted verification sequence -> observe output

TESTING MODEL:
Per-change manual tests + regression list.
Mudlet dwverify suites for one-command verification gate.
Kit-level self-test runner for PASS/FAIL.
Release checklist required for packaging.

DEPRECATION MODEL:
Deprecate in vX, remove in vY, with changelog + registry + migration notes.

============================================================
END OF FULL ANCHOR PACK (FINALIZED)
