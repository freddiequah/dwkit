# DWKit UI Module Contract (v1.0)

Version: **v1.0**  
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

## 1) Non-Negotiable SAFE Rules

All DWKit UI modules MUST remain **SAFE**:

✅ Allowed
- Creating/drawing UI widgets using Mudlet Geyser (Container/Label/etc)
- Reading config state (guiSettings) and showing/hiding UI accordingly
- Logging DWKit UI lifecycle messages (apply/dispose/reload)

❌ Not allowed
- Sending gameplay commands (`send()`, `sendAll()`, etc)
- Timers, auto-triggers, background automation
- Auto-executing combat/heal/scripting actions
- Event emissions that cause automation behavior

A UI module MUST behave like a *display layer only*.

---

## 2) Mandatory Module Structure

Every UI module MUST export a module table `M`:

### Required fields

- `M.VERSION` (string)
- `M.UI_ID` (string)

Example:
```lua
local M = {}

M.VERSION = "vYYYY-MM-DDX"
M.UI_ID   = "some_ui_id"
