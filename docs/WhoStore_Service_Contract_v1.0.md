# DWKit WhoStore Service Contract (v1.1)

Version: **v1.1**
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
- Keyed by `name` for lookup, but retains raw line and derived fields for validation.

**Snapshot**
- A full WhoStore state update, including parsed entries, a by-name index, and raw lines.

**Title text**
- The portion of an Entry that represents the player’s visible title or descriptive text (derived).
- Used for best-effort validation when correlating WHO with room lines.

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

WhoStore stores the following per WHO entry.

### 2.1 Entry schema (authoritative)

Fields stored:

- `name`
  - Type: string
  - Rule: **first token after the closing bracket**
  - Example: if line is `[48 War] Vzae the adventurer`, `name = "Vzae"`

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
  - Known flags (v1.1):
    - `AFK`
    - `NH`
    - `idle` (including patterns like `(idle:19)`; details may vary)
    - `down` (including patterns like `<-- down`)

- `extraText`
  - Type: string
  - Rule:
    - Everything after `name`, cleaned and trimmed
    - May contain title/notes and/or the raw flag tokens
    - MUST NOT remove meaning, only normalize spacing

- `titleText`
  - Type: string | nil
  - Rule:
    - Derived from `extraText` by removing only known flag tokens/markers and normalizing whitespace.
    - If the derived title becomes empty after removal, set to nil.
  - Purpose:
    - Best-effort validation when matching a room line to a WHO entry.
    - Example WHO line:
      - `[50 Cle] Snorrin ZZZZZVo tezzzz of Snert Industries (AFK) (NH)`
      - `name = "Snorrin"`
      - `extraText = "ZZZZZVo tezzzz of Snert Industries (AFK) (NH)"`
      - `titleText = "ZZZZZVo tezzzz of Snert Industries"`
    - Example room line:
      - `Snorrin ZZZZZVo tezzzz of Snert Industries (AFK) is standing here.`
      - A consumer MAY compare the `name` and `titleText` to validate it is the same player.

- `rawLine`
  - Type: string
  - Rule:
    - Original raw line stored for debug, replay, and future parsing improvements

Notes:
- WhoStore MUST treat `name` as the primary lookup key.
- WhoStore MUST update stored fields when new WHO snapshots show changed values (including `titleText`).

### 2.2 rankTag meaning rules (authoritative)

- If `rankTag` looks like `"48 War"`:
  - It represents a **player**
  - It encodes player `level` + `class`

- If `rankTag` is something like `"IMPL"`, `"MGOD"`, `"HGOD"`:
  - It represents **MUD admin staff**
  - `level = nil`, `class = nil` unless the MUD format changes in the future

This rule is REQUIRED so future logic does not incorrectly assume staff lines are normal player rank lines.

---

## 3) Parsing Rules

### 3.1 Basic format assumption (v1.1)

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

Given a WHO line `line`:

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
- Search remaining text for any known flags (exact word match, best-effort)
- Store list of flags present
- Examples:
  - `(AFK)` -> `AFK`
  - `(NH)` -> `NH`
  - `(idle:19)` -> `idle`
  - `<-- down` -> `down`

6) `extraText`
- Remaining text after name (trim, normalize internal whitespace)
- It is ok if it still contains the flag tokens
- This is a presentation/debug field, not a strict structured type

7) `titleText` (derived)
- Start from `extraText`
- Remove only known flag markers/tokens (best-effort), then normalize whitespace
- If empty after removal, set nil
- MUST NOT remove non-flag meaning content

8) `rawLine`
- Original raw input line

---

## 4) Snapshot Contract

WhoStore MUST expose snapshot data with the following structure.

### 4.1 Snapshot schema (authoritative)

- `ts`
  - Type: number
  - Unix seconds or ms timestamp (project standard)

- `source`
  - Type: string | nil
  - Example: `"capture"`, `"fixture"`, `"manual"`

- `rawLines`
  - Type: table (array of strings)
  - The raw WHO lines used for the snapshot (as captured)

- `entries`
  - Type: table (array of Entry)
  - Parsed entries for lines that successfully match the schema

- `byName`
  - Type: table (map: string -> Entry)
  - A lookup index for fast retrieval by player name
  - MUST be consistent with `entries`
  - If duplicate names occur in `entries`, the last parsed occurrence MAY win in `byName`

### 4.2 Update semantics (authoritative)

- A WhoStore update SHOULD be treated as a full snapshot replace by default.
- The snapshot MUST be self-contained and valid on its own.
- Implementations MAY support an explicit merge mode, but replace remains the default.

Title change rule (normative):
- If a player’s `name` is present in both previous and new snapshot, and the newly derived `titleText` differs from the prior stored `titleText`, WhoStore MUST update the stored Entry for that player to the new value as part of the snapshot replace.
- Consumers MUST assume titles can change and MUST treat WhoStore as authoritative for the latest observed title.

---

## 5) Public API Contract (Docs-First)

WhoStore MUST provide read access without exposing internal mutable tables.

Minimum required APIs (v1.1):
- `getSnapshot() -> Snapshot copy`
- `getEntry(name) -> Entry|nil` (copy)
- `getAllNames() -> array of string` (sorted, stable order)

Notes:
- `getEntry(name)` MUST retrieve from the canonical by-name index, not by scanning entries each time.
- Returned tables MUST be defensive copies (or immutable views), so callers cannot mutate internal state.

---

## 6) Event Contract (Docs-First)

When WhoStore updates snapshot state, it MUST emit the registered event:

`DWKit:Service:WhoStore:Updated`

Payload schema (minimum):
- `snapshot`: table (Snapshot schema above)
- `source`: string (optional)
- `ts`: number

Optional payload fields (non-binding):
- `delta`: summary table (added/removed/changed counts), if the implementation tracks it safely

Event registry location:
- docs/Event_Registry_v1.0.md (v1.9+)

---

## 7) UI Consumption Rules

UI modules MUST NOT parse WHO raw lines directly.

UI modules MUST:
- Consume WhoStore snapshot from service API, or
- React to `DWKit:Service:WhoStore:Updated`

This prevents duplicated parsing logic across UI modules and avoids drift.

---

## 8) Future Extensions (Non-Binding)

Future work may extend this contract to support:
- stronger role classification: player vs staff vs unknown
- normalized name casing rules
- correlation with room entities and room-line parsing
- persistence and cross-profile propagation
- structured idle minutes and other structured attributes

Any extension MUST:
- be docs-first
- preserve existing fields as stable where possible
- version bump this contract

End of document.
