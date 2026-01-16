# DWKit WhoStore Service Contract (v1.0)

Version: **v1.0**
Status: **Authoritative Contract**
Scope: **DWKit SAFE WhoStore snapshot + parsing rules**

This document defines the canonical WhoStore schema and parsing contract.

WhoStore exists to support:
- differentiating players vs non-players in room logic (future)
- UI display (future Presence_UI / RoomEntities_UI)
- cross-profile coordination logic that depends on "who is online" (future)
- preventing future drift in assumptions about WHO output and fields

This is a SAFE, passive data service.
It MUST NOT send gameplay commands and MUST NOT automate actions.

---

## 0) Terms (Normative)

**MUST / MUST NOT / SHOULD / MAY** are used as normative keywords.

**WHO output line**
- A single line from the MUD "who" output.
- Captured by a passive trigger or manual fixture ingestion.
- Stored as a raw string for debug and re-parsing.

**Entry**
- A parsed representation of a WHO line (schema below).

**Snapshot**
- A full WhoStore state update, including parsed entries and raw lines.

---

## 1) Non-Negotiable SAFE Rules

WhoStore MUST remain SAFE.

Allowed:
- Capture and parse WHO output text
- Store snapshot state in memory
- Emit internal SAFE events for UI/service consumption (docs-first event)
- Provide read APIs to retrieve current snapshot

Not allowed:
- Sending gameplay commands (send/sendAll/etc)
- Timers, background automation, combat automation
- Auto-refresh WHO without explicit manual trigger from user
- Writing persistence directly (unless explicitly approved in a future objective)

---

## 2) Canonical Data Model

WhoStore stores the following per WHO entry:

### 2.1 Entry schema (authoritative)

Fields stored:

- `name`
  - Type: string
  - Rule: **first token after the closing bracket**
  - Example: if line is `[48 War] Vzae AFK`, `name = "Vzae"`

- `rankTag`
  - Type: string
  - Rule: **inside bracket, trimmed**
  - Examples:
    - `"48 War"`
    - `"IMPL"`
    - `"MGOD"`

- `level`
  - Type: number | nil
  - Rule:
    - Extract a number if present in the bracket content
    - Otherwise nil
  - Example:
    - `[48 War]` -> `level = 48`
    - `[IMPL]` -> `level = nil`

- `class`
  - Type: string | nil
  - Rule:
    - Extract class token if present in the bracket content
    - Otherwise nil
  - Examples:
    - `[48 War]` -> `class = "War"`
    - `[50 Cle]` -> `class = "Cle"`
    - `[IMPL]` -> `class = nil`

- `flags`
  - Type: table (array of strings)
  - Rule:
    - Detect known flags from text after the name
    - Store as a list (no duplicates)
  - Known flags (v1.0):
    - `AFK`
    - `NH`
    - `idle`
    - `down`

- `extraText`
  - Type: string
  - Rule:
    - Everything after `name`, cleaned and trimmed
    - May contain title/notes and/or the raw flag words
    - MUST NOT remove meaning, only normalize spacing

- `rawLine`
  - Type: string
  - Rule:
    - Original raw line stored for debug, replay, and future parsing improvements

### 2.2 rankTag meaning rules (authoritative)

- If `rankTag` looks like `"48 War"`:
  - It represents a **player**
  - It encodes player `level` + `class`

- If `rankTag` is something like `"IMPL"`, `"MGOD"`:
  - It represents a **MUD admin staff**
  - `level = nil`, `class = nil` unless the MUD format changes in the future

This rule is REQUIRED so future logic does not incorrectly assume IMPL/MGOD lines are normal player rank lines.

---

## 3) Parsing Rules

### 3.1 Basic format assumption (v1.0)

Most lines follow:
`[<rankTag>] <name> <optional extra text>`

Minimum requirements to parse:
- A bracket section exists at the start
- A name token exists after the bracket

If parsing fails:
- The entry SHOULD NOT be created
- The raw line MUST still be kept in snapshot rawLines
- A parse warning MAY be logged (SAFE logging only)

### 3.2 Field extraction

1) `rankTag`
- Take first bracket group
- Trim spaces inside

2) `level`
- If the bracket contains a number, parse it as level
- If no number found, level is nil

3) `class`
- If bracket contains a second token after the number, use it
- Else nil

4) `name`
- First token after bracket

5) `flags`
- Search remaining text for any known flags (exact word match)
- Store list of flags present

6) `extraText`
- Remaining text after name (trim, normalize internal whitespace)
- It is ok if it still contains the flag words
- This is a presentation/debug field, not a strict structured type

7) `rawLine`
- Original raw input line

---

## 4) Snapshot Contract

WhoStore MUST expose snapshot data with the following structure:

### 4.1 Snapshot schema (authoritative)

- `ts`
  - Type: number
  - Unix seconds or ms timestamp (project standard)
- `source`
  - Type: string | nil
  - Example: `"capture"`, `"fixture"`, `"manual"`
- `rawLines`
  - Type: table (array of strings)
- `entries`
  - Type: table (array of Entry)

### 4.2 Update semantics

- A WhoStore update SHOULD be treated as a full snapshot replace.
- The snapshot MUST be self-contained and valid on its own.

---

## 5) Event Contract (Docs-First)

When WhoStore updates snapshot state, it MUST emit the registered event:

`DWKit:Service:WhoStore:Updated`

Payload schema:
- `snapshot`: table (Snapshot schema above)
- `source`: string (optional)
- `ts`: number

Event registry location:
- docs/Event_Registry_v1.0.md (v1.9+)

---

## 6) UI Consumption Rules

UI modules MUST NOT parse WHO raw lines directly.

UI modules MUST:
- Consume WhoStore snapshot from service API, or
- React to `DWKit:Service:WhoStore:Updated`

This prevents duplicated parsing logic across UI modules and avoids drift.

---

## 7) Future Extensions (Non-Binding)

Future work may extend this contract to support:
- role classification: player vs admin vs unknown
- normalized name casing rules
- correlation with room entities
- persistence and cross-profile propagation

Any extension MUST:
- be docs-first
- preserve existing fields as stable where possible
- version bump this contract

End of document.
