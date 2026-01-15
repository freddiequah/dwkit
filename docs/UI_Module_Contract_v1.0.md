# DWKit UI Module Contract (v1.1)

Version: **v1.1**  
Status: **Authoritative Contract**  
Scope: **DWKit SAFE UI modules** (Mudlet Geyser UI only)

This document defines the required contract for all UI modules under:

- `src/dwkit/ui/*.lua`

It ensures all UI modules behave consistently with DWKit governance:
- SAFE by default
- predictable lifecycle
- enabled/visible gating
- reload-safe behavior
- no gameplay output or automation

---

## 0) Terms (Normative)

**MUST / MUST NOT / SHOULD / MAY** are used as normative keywords.

**Enabled vs Visible**
- **enabled**: whether a UI module is allowed to register/apply at all (mandatory gate).
- **visible**: whether the UI should currently be shown (optional persistence gate).

**UI module**
- A consumer-only display layer for Geyser widgets.
- Owns no business logic, no persistence, and performs no automation.

---

## 1) Non-Negotiable SAFE Rules

All DWKit UI modules MUST remain **SAFE**:

✅ Allowed
- Creating/drawing UI widgets using Mudlet Geyser (Container/Label/etc)
- Reading config state (guiSettings) and showing/hiding UI accordingly
- Logging DWKit UI lifecycle messages (apply/dispose/reload)
- Calling SAFE helper modules (e.g., ui_base, guiSettings) to manage widgets and state

❌ Not allowed
- Sending gameplay commands (`send()`, `sendAll()`, etc)
- Timers, auto-triggers, background automation
- Auto-executing combat/heal/scripting actions
- Event emissions that cause automation behavior
- Writing persistence directly (UI must not write files)

A UI module MUST behave like a **display layer only**.

---

## 2) Mandatory Module Structure

Every UI module MUST export a module table `M`.

### Required fields
- `M.VERSION` (string)
- `M.UI_ID` (string)

Example:
```lua
local M = {}

M.VERSION = "vYYYY-MM-DDX"
M.UI_ID   = "some_ui_id"

return M
