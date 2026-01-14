# Chat Handoff Pack Template v1.0 (DWKit)

Purpose:
This file is a copy/paste template to carry verified facts and required artifacts into a new chat,
reducing drift and missing inputs. It is docs-only and does not define runtime behavior.

Date: <YYYY-MM-DD (MYT)>
============================================================
SECTION V — HANDOFF PACK (DWKit)  [for next chat]
============================================================

1) New Chat Opener (paste at top of new chat)
------------------------------------------------------------
Use the Project’s “Full Anchor Pack” as the authoritative reference for all work in this chat.
Do not deviate from its standards, contracts, naming, load order, and Definition of Done.
For every delivered item (new or changed), include Confidence + Assumptions + Verification Steps and do not proceed until I confirm PASS (or I paste logs for diagnosis).
If any requirement conflicts with the request, flag the conflict before implementing changes.

Workflow (Full-File Return Rule):
- When requesting code changes, I will paste the full current file(s).
- The assistant MUST return the full updated file(s) in full (no patches/diffs).
- If the assistant is unsure it has the latest file content, it MUST request the full file content first and provide the exact commands to collect it.
------------------------------------------------------------

2) Identity (confirm unchanged)
- PackageRootGlobal: DWKit
- PackageId:         dwkit
- EventPrefix:       DWKit:
- DataFolderName:    dwkit
- VersionTagStyle:   Calendar (format: vYYYY-MM-DDX)

3) Repo + Branch
- Repo URL: <e.g. https://github.com/<user>/dwkit.git>
- Local path: <e.g. C:\Projects\dwkit>
- Branch: <e.g. main>
- Working tree: <CLEAN / DIRTY> (list files if DIRTY)

4) Current objective (single sentence)
- Objective: <one sentence only>

5) Scope
- In-scope modules/files (WILL change):
  - <path 1>
  - <path 2>
- Out-of-scope modules/files (MUST NOT change):
  - <path 1>
  - <path 2>

6) Current status
- Verified Working (PASS):
  - <item 1 (what exactly was verified)>
  - <item 2>
- Known Issues (OPEN):
  - <issue 1 (symptom + where seen)>
  - <issue 2>

7) Last change delivered (what was modified)
- Module(s)/Doc(s) changed:
  - <path list>
- Version tags:
  - Latest tag: <vYYYY-MM-DDX>
  - Tag commit: <hash>
- Summary of change (1–3 bullets):
  - <bullet>
- PR link (if any): <url or NONE>

8) Verification results (most recent)
- Tests executed:
  - <command 1>
  - <command 2>
- Outputs/logs:
  - <paste key outputs or attach logs>
- PASS/FAIL verdict:
  - <PASS or FAIL>

9) Next gated steps (do NOT start until current step is PASS)
- Next step 1:
- Next step 2:

10) Required artifacts for next change (Full-File Return Workflow)

A) Repo state (PowerShell)
```powershell
cd <repo-root>
git status -sb
git log -1 --decorate --oneline
git rev-parse HEAD
git branch --show-current
git remote -v

```

B) Full file dumps for any file to be changed (PowerShell)
```powershell
Get-Content -Raw .\<path-to-file>
```

C) Optional proofs (committed vs working tree)
```powershell
git show HEAD:<path-to-file>
git diff -- <path-to-file>
git diff --staged -- <path-to-file>
```

D) Optional PR workflow context (if relevant)
```powershell
gh pr status
gh pr view
gh pr view --comments
gh pr diff
gh pr checks
```

11) Mudlet verification reminders (paste safety + common gates)
- Mudlet input line paste safety:
  - When running Lua from the Mudlet INPUT LINE, use a SINGLE LINE:
    lua do ... end
  - Do NOT paste multi-line Lua into the input line. Use the Lua Console if needed.

- Common SAFE gates (examples):
  - dwtest quiet
  - dwcommands safe
  - dwhelp <cmd>

End of template.
