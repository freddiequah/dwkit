-- FILE: src/dwkit/capture/roomfeed_capture.lua
-- #########################################################################
-- Module Name : dwkit.capture.roomfeed_capture
-- Owner       : Capture
-- Version     : v2026-02-09B
-- Purpose     :
--   - Passive capture of room output blocks (movement room header, look output)
--     without GMCP and without sending any commands.
--   - Detects a "room snapshot" start from a room header marker, buffers lines
--     until prompt-noise is seen, then ingests the block into RoomEntitiesService.
--   - Best-effort arrival/leave line inference (conservative): updates Unknown bucket
--     only for simple single-token names; otherwise ignored (no disruption).
--
-- Notes (Feb 2026 update):
--   - Some rooms do NOT print "(#12345)" in the first line (e.g. "The Adventurer's Meeting Room").
--     We support a conservative "room title" fallback to start snapshot capture.
--   - IMPORTANT: command echo lines (e.g. "dwroom watch status") must NOT be treated as titles.
--   - IMPORTANT: MUD output may include ANSI/control characters. We strip ANSI + \r for parsing
--     decisions (header/exits/prompt/arrive/leave), while keeping raw lines for ingestion.
--   - Defensive: if a snapshot starts on the exits line, we set snapHasExits immediately.
--   - Tightened: fallback title detection rejects exit-entry lines (e.g. "East - ...") and
--     common look-description lines like "hangs here", "is here", "mounted on", etc.
--
-- Feb 2026 fix (v2026-02-03B):
--   - Add silent debug fields (queried via status({quiet=true})) to confirm whether
--     headers are being recognized and whether snapshots begin.
--   - Strong header matches one-or-more [ ... ] flag blocks, with optional (#id).
--
-- Feb 2026 fix (v2026-02-03C):
--   - Some servers/clients include non-ANSI invisible control chars / NBSP that survive ANSI stripping.
--     These break header matching. We now normalize NBSP -> space and strip remaining ASCII control chars
--     (0x00-0x1F, 0x7F) after ANSI removal, for parsing decisions only.
--
-- Feb 2026 fix (v2026-02-03E):
--   - Header detection was still not matching in live output (lines are seen, but no header recognized).
--     Replace brittle single-pattern header matching with a stepwise approach:
--       * require trailing one-or-more [ ... ] flag blocks
--       * strip flag blocks and optional (#id)
--       * sanity-check remaining title text
--   - Add "seenLineCount/lastLineSeen*" silent diagnostics to confirm the trigger is receiving output.
--
-- Feb 2026 fix (v2026-02-04A):
--   - Mudlet can print prompt + room header on the same line, e.g.:
--       (i54) <812hp 100mp 83mv> The Board Room (#1204) [ INDOORS IMMROOM ]
--     Previously, prompt-noise detection rejected this line entirely.
--     We now:
--       * treat prompt as "noise" only when the line is essentially just the prompt (no trailing content)
--       * strip a leading prompt segment for parsing decisions when trailing content exists
--       * record lastHeaderSeenKind + lastHeaderSeenEffectiveClean for diagnostics
--
-- Feb 2026 fix (v2026-02-04B):
--   - Prevent mid-capture false restarts from wrapped room description lines:
--       * tighten fallback title: must start with uppercase; reject any '.' in line
--       * during capture, only restart on STRONG headers (never fallback titles)
--   - Clear lastAbortReason on successful finalize (avoid stale abort in debugState)
--
-- Feb 2026 fix (v2026-02-04C):
--   - IMPORTANT: Keep arrive/leave updates in the SAME bucket shape as RoomEntitiesService.
--     RoomEntities buckets are SET-MAPS: { ["Name"]=true }.
--     We now copy/modify/apply arrive/leave using set-maps (defensive conversion from arrays if needed),
--     and apply via RoomSvc.setState(...,{forceEmit=true,...}) to avoid poisoning state shape.
--
-- Feb 2026 update (v2026-02-09B):
--   - Partial snapshot finalize:
--       If prompt arrives before "Obvious exits:", ingest buffered lines as a PARTIAL snapshot
--       (instead of aborting), and mark RoomWatch as DEGRADED while still updating snapshot freshness.
--       This prevents UI from going stale when some rooms omit exits or output is truncated.
--   - Adds verification-only helper: _testIngestSnapshot(buf, opts) to deterministically validate
--     full vs partial finalize behavior without requiring live MUD output.
--
-- Public API  :
--   - getVersion() -> string
--   - install(opts?) -> boolean ok, string|nil err
--   - uninstall(opts?) -> boolean ok, string|nil err
--   - status(opts?) -> table state  (also prints unless opts.quiet=true)
--
-- Compatibility (for dwroom.lua that is already applied):
--   - getDebugState() -> table (alias of status({quiet=true}) with extra keys)
--
-- Verification/Test API (safe; no MUD sends):
--   - _testIngestSnapshot(bufLinesRaw, opts?) -> boolean ok, string|nil err
--       opts.hasExits=true|false (default false)
--
-- Events Emitted   : None (delegates to services)
-- Events Consumed  : MUD output via tempRegexTrigger line hook
-- Persistence      : None
-- Automation Policy: Passive Capture (SAFE). No gameplay commands, no timers.
-- Dependencies     :
--   - dwkit.services.roomentities_service
--   - dwkit.services.roomfeed_status_service
-- #########################################################################

local M = {}

M.VERSION = "v2026-02-09B"

local function _nowTs()
    return os.time()
end

local function _out(line)
    line = tostring(line or "")
    if line == "" then return end
    if _G.echo then
        _G.echo("[DWKit RoomFeed] " .. line .. "\n")
    else
        print("[DWKit RoomFeed] " .. line)
    end
end

local function _isFn(name)
    return type(_G[name]) == "function"
end

local function _trim(s)
    s = tostring(s or "")
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    return s
end

-- Strip common ANSI escape sequences + carriage returns for parsing decisions.
-- Keep raw lines for RoomSvc ingestion.
--
-- Important: some clients use private mode sequences like ESC[?25h.
-- We strip:
--  - CSI: ESC[ ... final byte (broad)
--  - OSC: ESC] ... BEL
--  - Charset designations: ESC(  / ESC)
--  - Any remaining single ESC + char leftovers
--
-- Additional hardening:
--  - Normalize NBSP (0xC2 0xA0) -> space
--  - Strip remaining ASCII control chars (0x00-0x1F, 0x7F)
local function _stripAnsi(s)
    s = tostring(s or "")

    -- strip CR
    s = s:gsub("\r", "")

    -- OSC sequences: ESC ] ... BEL
    s = s:gsub("\27%][^\7]*\7", "")

    -- CSI sequences (broad): ESC [ digits/;/?, optional intermediates, final byte
    -- This catches things like: ESC[0m, ESC[1;36m, ESC[?25h, ESC[2J, ESC[K, etc.
    s = s:gsub("\27%[[%d%;%?]*[@-~]", "")
    s = s:gsub("\27%[[%d%;%?]*[%s%-/]*[@-~]", "") -- extra-safe for odd intermediates

    -- Charset / other 2-byte escapes: ESC( X or ESC) X
    s = s:gsub("\27%([%w]", "")
    s = s:gsub("\27%)%w", "")

    -- Any remaining ESC + one char (defensive)
    s = s:gsub("\27.", "")

    -- Normalize NBSP -> space (UTF-8 C2 A0)
    s = s:gsub("\194\160", " ")

    -- Strip remaining ASCII control chars (keep output readable; parsing-only)
    -- Includes NUL..US and DEL.
    s = s:gsub("[%z\1-\31\127]", "")

    return s
end

local function _cleanLine(ln)
    return _stripAnsi(tostring(ln or ""))
end

-- Detect and optionally strip a leading prompt segment for parsing decisions.
-- Supports optional "(iNN)" prefix, then "<...hp ...mp ...mv>" prompt, then trailing content.
--
-- Returns:
--   hasPromptPrefix (bool), effectiveLineClean (string), promptOnly (bool)
local function _splitPromptPrefix(lnClean)
    local ln = tostring(lnClean or "")
    if ln == "" then
        return false, ln, false
    end

    -- Optional "(i54)" style prefix, then prompt
    local _, inside, rest = ln:match("^%s*(%(%a%d+%))%s*<([^>]*)>%s*(.*)$")
    if inside then
        local low = tostring(inside):lower()
        if low:find("hp", 1, true) or low:find("mp", 1, true) or low:find("mv", 1, true) then
            rest = tostring(rest or "")
            rest = _trim(rest)
            local promptOnly = (rest == "")
            return true, rest, promptOnly
        end
    end

    -- Prompt without "(iNN)" prefix
    inside, rest = ln:match("^%s*<([^>]*)>%s*(.*)$")
    if inside then
        local low = tostring(inside):lower()
        if low:find("hp", 1, true) or low:find("mp", 1, true) or low:find("mv", 1, true) then
            rest = tostring(rest or "")
            rest = _trim(rest)
            local promptOnly = (rest == "")
            return true, rest, promptOnly
        end
    end

    return false, ln, false
end

local function _isPromptNoise(lnClean)
    local has, _, promptOnly = _splitPromptPrefix(lnClean)
    if has and promptOnly then
        return true
    end
    return false
end

local function _isExitsLine(lnClean)
    local ln = tostring(lnClean or "")
    return (ln:lower():match("^%s*obvious exits:%s*$") ~= nil)
end

-- Reject exit-entry lines like:
--   East      - The Adventurer's Meeting Room
--   North     - The Voting Booth
local function _isExitEntryLine(lnClean)
    local t = _trim(lnClean)
    if t == "" then return false end
    local lower = t:lower()

    -- must have a dash separator in the typical exits style
    if not lower:find("%s%-%s") then return false end

    -- direction token at start
    local dir = lower:match("^(%a+)")
    if not dir then return false end

    local okDir = {
        north = true,
        south = true,
        east = true,
        west = true,
        up = true,
        down = true,
        northeast = true,
        northwest = true,
        southeast = true,
        southwest = true,
    }

    if okDir[dir] ~= true then
        return false
    end

    return true
end

-- Strong header detection (see prior notes).
local function _isRoomHeaderStrong(lnClean)
    local t = _trim(lnClean)
    if t == "" then return false end
    if _isPromptNoise(t) then return false end

    if t:match("^%[") then return false end
    if t:find('"', 1, true) then return false end
    if _isExitEntryLine(t) then return false end

    local lower = t:lower()
    if lower:match("^dw[%w_%-]") then return false end
    if lower:match("^lua%s") then return false end

    if not t:match("%b[]%s*$") then
        return false
    end

    local base = t
    local guard = 0
    while base:match("%s*%b[]%s*$") do
        base = base:gsub("%s*%b[]%s*$", "")
        guard = guard + 1
        if guard > 8 then break end
    end
    base = _trim(base)
    if base == "" then return false end

    base = base:gsub("%s*%(%#%d+%)%s*$", "")
    base = _trim(base)
    if base == "" then return false end

    if base:match("[%:%.%!%?]$") then return false end
    local len = #base
    if len < 4 or len > 72 then return false end
    if not base:match("[%a]") then return false end
    if not base:match("%u") then return false end

    local baseLower = base:lower()
    if baseLower:match("^you are ") then return false end
    if baseLower:match("^at the ") then return false end
    if baseLower:find(" has connected") or baseLower:find(" has quit") or baseLower:find(" un%-renting") then return false end

    return true
end

-- Fallback title detection: tightened to avoid wrapped description lines.
local function _isRoomTitleCandidate(lnClean)
    local ln = tostring(lnClean or "")
    if ln == "" then return false end
    if _isPromptNoise(ln) then return false end

    -- must be unindented
    if ln:match("^%s") then return false end

    local t = _trim(ln)
    if t == "" then return false end

    if t:match("^%[") then return false end

    local lower = t:lower()

    if _isExitsLine(t) then return false end
    if _isExitEntryLine(t) then return false end

    if lower:match("^dw[%w_%-]") then return false end
    if lower:match("^lua%s") then return false end

    if lower:match("^you are ") then return false end
    if lower:match("^at the ") then return false end
    if lower:find(" has connected") or lower:find(" has quit") or lower:find(" un%-renting") then return false end

    if lower:find(" hangs here") then return false end
    if lower:find(" is here") then return false end
    if lower:find(" are here") then return false end
    if lower:find(" is mounted") then return false end
    if lower:find(" are mounted") then return false end

    if lower:find(" arrives") or lower:find(" leaves") or lower:find(" appears") then return false end

    if t:match("[%:%.%!%?]$") then return false end

    -- tighten: room titles should start with uppercase
    if not t:match("^%u") then return false end

    -- tighten: reject any '.' anywhere (wrapped description lines frequently contain periods)
    if t:find("%.", 1, true) then return false end

    local len = #t
    if len < 4 or len > 72 then return false end
    if not t:match("[%a]") then return false end
    if not t:match("%u") then return false end

    return true
end

-- Header classification with prompt-prefix stripping (for parsing decisions only).
-- Returns: ok(bool), kind(string|nil), effectiveClean(string)
local function _classifyRoomHeader(lnClean)
    local original = tostring(lnClean or "")
    local hasPrompt, effective, promptOnly = _splitPromptPrefix(original)

    if hasPrompt and promptOnly then
        return false, nil, effective
    end

    local eff = effective
    local usedStripped = (hasPrompt and eff ~= original)

    if _isRoomHeaderStrong(eff) then
        return true, usedStripped and "strong_stripped" or "strong", eff
    end
    if _isRoomTitleCandidate(eff) then
        return true, usedStripped and "fallback_stripped" or "fallback", eff
    end

    return false, nil, eff
end

local function _tryParseArriveLeave(lnClean)
    local ln = _trim(lnClean)
    if ln == "" then return nil end

    local name = ln:match("^([%a][%w%-%']*)%s+arrives")
    if name then
        return { kind = "arrive", name = name }
    end

    name = ln:match("^([%a][%w%-%']*)%s+appears%s+out%s+of%s+thin%s+air%.$")
    if name then
        return { kind = "arrive", name = name }
    end

    name = ln:match("^([%a][%w%-%']*)%s+arrives%s+suddenly%.$")
    if name then
        return { kind = "arrive", name = name }
    end

    name = ln:match("^([%a][%w%-%']*)%s+leaves")
    if name then
        return { kind = "leave", name = name }
    end

    return nil
end

local function _resolveRoomSvc()
    local ok, modOrErr = pcall(require, "dwkit.services.roomentities_service")
    if ok and type(modOrErr) == "table"
        and type(modOrErr.getState) == "function"
        and type(modOrErr.ingestLookLines) == "function"
        and type(modOrErr.update) == "function"
        and type(modOrErr.setState) == "function"
    then
        return true, modOrErr, nil
    end
    return false, nil, tostring(modOrErr)
end

local function _resolveStatusSvc()
    local ok, modOrErr = pcall(require, "dwkit.services.roomfeed_status_service")
    if ok and type(modOrErr) == "table"
        and type(modOrErr.noteSnapshot) == "function"
        and type(modOrErr.noteAbort) == "function"
        and type(modOrErr.noteDegraded) == "function"
    then
        return true, modOrErr, nil
    end
    return false, nil, tostring(modOrErr)
end

-- #########################################################################
-- Bucket-shape helpers (v2026-02-04C)
-- RoomEntitiesService buckets are SET-MAPS: { ["Name"]=true }.
-- We defensively accept array-shaped buckets and normalize them into set-maps.
-- #########################################################################

local function _newBucketSet()
    return {}
end

local function _normalizeBucketToSet(src)
    local out = _newBucketSet()
    if type(src) ~= "table" then return out end

    for k, v in pairs(src) do
        -- canonical set-map shape: ["Name"]=true
        if type(k) == "string" and v == true then
            out[k] = true

            -- array of strings: { "Name", "Other" }
        elseif type(k) == "number" and type(v) == "string" and v ~= "" then
            out[v] = true

            -- array of objects with .name: { {name="X"}, ... }
        elseif type(k) == "number" and type(v) == "table" and type(v.name) == "string" and v.name ~= "" then
            out[v.name] = true
        end
    end

    return out
end

local function _copyBuckets(state)
    state = (type(state) == "table") and state or {}
    return {
        players = _normalizeBucketToSet(state.players),
        mobs    = _normalizeBucketToSet(state.mobs),
        items   = _normalizeBucketToSet(state.items),
        unknown = _normalizeBucketToSet(state.unknown),
    }
end

local function _ensureBucketsPresent(buckets)
    buckets = (type(buckets) == "table") and buckets or {}
    if type(buckets.players) ~= "table" then buckets.players = {} end
    if type(buckets.mobs) ~= "table" then buckets.mobs = {} end
    if type(buckets.items) ~= "table" then buckets.items = {} end
    if type(buckets.unknown) ~= "table" then buckets.unknown = {} end
    return buckets
end

local function _hasNameAnywhere(buckets, name)
    buckets = _ensureBucketsPresent(buckets)
    name = tostring(name or "")
    if name == "" then return false end

    if buckets.players[name] == true then return true end
    if buckets.mobs[name] == true then return true end
    if buckets.items[name] == true then return true end
    if buckets.unknown[name] == true then return true end

    -- defensive: if any bucket still has array remnants, scan values
    for _, k in ipairs({ "players", "mobs", "items", "unknown" }) do
        local tt = buckets[k]
        if type(tt) == "table" then
            for kk, vv in pairs(tt) do
                if type(kk) == "number" and tostring(vv) == name then
                    return true
                end
            end
        end
    end

    return false
end

local function _removeFromBuckets(buckets, name)
    buckets = _ensureBucketsPresent(buckets)
    name = tostring(name or "")
    if name == "" then return false end

    local changed = false

    for _, k in ipairs({ "players", "mobs", "items", "unknown" }) do
        local tt = buckets[k]
        if type(tt) == "table" then
            if tt[name] == true then
                tt[name] = nil
                changed = true
            end

            -- defensive: remove any array remnants that match
            for kk, vv in pairs(tt) do
                if type(kk) == "number" and tostring(vv) == name then
                    tt[kk] = nil
                    changed = true
                end
            end
        end
    end

    return changed
end

local function _addToUnknown(buckets, name)
    buckets = _ensureBucketsPresent(buckets)
    name = tostring(name or "")
    if name == "" then return false end

    if _hasNameAnywhere(buckets, name) then
        return false
    end

    buckets.unknown[name] = true
    return true
end

local ROOT = {
    installed = false,
    installTs = nil,
    lineTriggerId = nil,

    snapCapturing = false,
    snapBuf = {},
    snapStartTs = nil,
    snapStartLineRaw = nil,
    snapStartLineClean = nil,
    snapHasExits = false,
    snapSeenLines = 0,

    lastOkTs = nil,
    lastAbortReason = nil,
    lastDegradedReason = nil,

    -- silent diagnostics (no prints)
    lastHeaderSeenTs = nil,
    lastHeaderSeenClean = nil,
    lastHeaderSeenEffectiveClean = nil,
    lastHeaderSeenKind = nil,
    lastSnapStartTs = nil,
    lastSnapStartClean = nil,

    -- line receipt diagnostics (no prints)
    seenLineCount = 0,
    lastLineSeenTs = nil,
    lastLineSeenClean = nil,
}

local MAX_SNAP_LINES = 140

local function _resetSnap()
    ROOT.snapCapturing = false
    ROOT.snapBuf = {}
    ROOT.snapStartTs = nil
    ROOT.snapStartLineRaw = nil
    ROOT.snapStartLineClean = nil
    ROOT.snapHasExits = false
    ROOT.snapSeenLines = 0
end

local function _beginSnap(lnRaw, lnCleanEffective)
    _resetSnap()
    ROOT.snapCapturing = true
    ROOT.snapStartTs = _nowTs()
    ROOT.snapStartLineRaw = tostring(lnRaw or "")
    ROOT.snapStartLineClean = tostring(lnCleanEffective or "")
    ROOT.snapBuf[#ROOT.snapBuf + 1] = tostring(lnRaw or "")
    ROOT.snapSeenLines = 1

    -- silent diagnostics
    ROOT.lastSnapStartTs = ROOT.snapStartTs
    ROOT.lastSnapStartClean = ROOT.snapStartLineClean
end

local function _abortSnap(reason)
    reason = tostring(reason or "abort")
    ROOT.lastAbortReason = reason
    _resetSnap()

    local okS, Status = _resolveStatusSvc()
    if okS then
        Status.noteAbort(reason, { ts = _nowTs() })
    end
end

-- Internal: ingest snapshot buffer, optionally marking partial/degraded.
local function _ingestSnapshot(buf, ts, meta)
    meta = (type(meta) == "table") and meta or {}
    buf = (type(buf) == "table") and buf or {}

    local okR, RoomSvc = _resolveRoomSvc()
    if okR then
        local src = tostring(meta.source or "roomfeed_capture")
        local ingestMeta = {
            source = src,
            ts = ts,
        }
        if meta.partial == true then
            ingestMeta.partial = true
            ingestMeta.reason = tostring(meta.reason or "partial")
        end
        RoomSvc.ingestLookLines(buf, ingestMeta)
    end
end

local function _finalizeSnap()
    local buf = ROOT.snapBuf
    local hasExits = (ROOT.snapHasExits == true)

    local okS, Status = _resolveStatusSvc()
    local ts = _nowTs()

    if hasExits ~= true then
        -- v2026-02-09B: Partial finalize instead of abort.
        local reason = "partial:prompt_before_exits"

        _ingestSnapshot(buf, ts, {
            source = "roomfeed_capture_partial",
            partial = true,
            reason = reason,
        })

        ROOT.lastOkTs = ts
        ROOT.lastAbortReason = nil
        ROOT.lastDegradedReason = reason
        _resetSnap()

        -- Keep freshness updated AND keep degraded latched.
        if okS then
            -- noteSnapshot clears degradedReason; so do snapshot first, then degraded.
            Status.noteSnapshot({ source = "roomfeed_capture_partial", ts = ts })
            Status.noteDegraded(reason, { ts = ts })
        end

        return
    end

    _ingestSnapshot(buf, ts, { source = "roomfeed_capture" })

    ROOT.lastOkTs = ts
    ROOT.lastAbortReason = nil -- IMPORTANT: clear stale abort after successful finalize
    ROOT.lastDegradedReason = nil
    _resetSnap()

    if okS then
        Status.noteSnapshot({ source = "roomfeed_capture", ts = ts })
    end
end

local function _handleArriveLeave(lnClean)
    local parsed = _tryParseArriveLeave(lnClean)
    if not parsed then return end

    local name = tostring(parsed.name or "")
    if name == "" then return end

    local okR, RoomSvc = _resolveRoomSvc()
    if not okR then return end

    -- IMPORTANT: normalize current state into set-maps, and keep it as set-maps.
    local current = RoomSvc.getState()
    local buckets = _copyBuckets(current)
    local changed = false

    if parsed.kind == "arrive" then
        changed = _addToUnknown(buckets, name)
    elseif parsed.kind == "leave" then
        changed = _removeFromBuckets(buckets, name)
    end

    if changed then
        -- Prefer setState to apply the whole normalized bucket set (avoid poisoning shape).
        RoomSvc.setState(buckets, { forceEmit = true, source = "roomfeed_arriveleave" })
    end
end

function M.getVersion()
    return tostring(M.VERSION)
end

-- Verification-only helper: deterministically ingest a supplied snapshot buffer.
-- SAFE: no timers, no sends, no triggers. Intended for dwverify suites.
-- opts:
--   - hasExits=true|false (default false)
function M._testIngestSnapshot(bufLinesRaw, opts)
    opts = (type(opts) == "table") and opts or {}
    if type(bufLinesRaw) ~= "table" then
        return false, "_testIngestSnapshot(bufLinesRaw): bufLinesRaw must be table"
    end

    local hasExits = (opts.hasExits == true)

    -- Pretend we are mid-capture.
    ROOT.snapCapturing = true
    ROOT.snapBuf = {}
    for i = 1, #bufLinesRaw do
        ROOT.snapBuf[i] = tostring(bufLinesRaw[i] or "")
    end
    ROOT.snapSeenLines = #ROOT.snapBuf
    ROOT.snapHasExits = hasExits

    -- Finalize as if prompt arrived.
    _finalizeSnap()
    return true, nil
end

function M.install(opts)
    opts = (type(opts) == "table") and opts or {}

    if ROOT.installed == true then
        return true, nil
    end

    if not _isFn("tempRegexTrigger") then
        return false, "tempRegexTrigger not available (Mudlet API)"
    end

    ROOT.installed = true
    ROOT.installTs = _nowTs()

    ROOT.lineTriggerId = tempRegexTrigger("^(.*)$", function()
        local lnRaw = (type(line) == "string") and line or tostring(line or "")
        local lnClean = _cleanLine(lnRaw)

        -- line receipt diagnostics (silent)
        ROOT.seenLineCount = (tonumber(ROOT.seenLineCount or 0) or 0) + 1
        ROOT.lastLineSeenTs = _nowTs()
        ROOT.lastLineSeenClean = _trim(lnClean)

        if ROOT.snapCapturing ~= true then
            _handleArriveLeave(lnClean)
        end

        if ROOT.snapCapturing ~= true then
            local okHeader, kind, eff = _classifyRoomHeader(lnClean)
            if okHeader then
                ROOT.lastHeaderSeenTs = _nowTs()
                ROOT.lastHeaderSeenClean = _trim(lnClean)
                ROOT.lastHeaderSeenEffectiveClean = _trim(eff)
                ROOT.lastHeaderSeenKind = tostring(kind or "unknown")

                _beginSnap(lnRaw, eff)
                return
            end
            return
        end

        if _isPromptNoise(lnClean) then
            _finalizeSnap()
            return
        end

        ROOT.snapSeenLines = (tonumber(ROOT.snapSeenLines or 0) or 0) + 1
        if ROOT.snapSeenLines > MAX_SNAP_LINES then
            _abortSnap("abort:max_lines")
            return
        end

        -- During capture: restart ONLY on STRONG headers (fallback titles are too risky mid-block).
        local okHeader, kind, eff = _classifyRoomHeader(lnClean)
        if okHeader then
            local k = tostring(kind or "")
            local isStrong = (k:find("^strong", 1, true) == 1)
            if isStrong and tostring(eff or "") ~= tostring(ROOT.snapStartLineClean or "") then
                _abortSnap("abort:restart_header_seen")
                _beginSnap(lnRaw, eff)
                return
            end
        end

        if _isExitsLine(lnClean) then
            ROOT.snapHasExits = true
        end

        ROOT.snapBuf[#ROOT.snapBuf + 1] = lnRaw
    end)

    if type(ROOT.lineTriggerId) ~= "number" then
        ROOT.installed = false
        ROOT.lineTriggerId = nil
        return false, "failed to install tempRegexTrigger"
    end

    if opts.quiet ~= true then
        _out("install OK lineTriggerId=" .. tostring(ROOT.lineTriggerId))
    end

    return true, nil
end

function M.uninstall(opts)
    opts = (type(opts) == "table") and opts or {}

    if ROOT.installed ~= true then
        return true, nil
    end

    if type(ROOT.lineTriggerId) == "number" and _isFn("killTrigger") then
        pcall(function() killTrigger(ROOT.lineTriggerId) end)
    end

    ROOT.installed = false
    ROOT.lineTriggerId = nil
    _resetSnap()

    if opts.quiet ~= true then
        _out("uninstall OK")
    end

    return true, nil
end

function M.status(opts)
    opts = (type(opts) == "table") and opts or {}
    local s = {
        installed = (ROOT.installed == true),
        installTs = ROOT.installTs,
        lineTriggerId = ROOT.lineTriggerId,
        snapCapturing = (ROOT.snapCapturing == true),
        snapHasExits = (ROOT.snapHasExits == true),
        snapBufLen = (type(ROOT.snapBuf) == "table") and #ROOT.snapBuf or 0,
        lastOkTs = ROOT.lastOkTs,
        lastAbortReason = ROOT.lastAbortReason,
        lastDegradedReason = ROOT.lastDegradedReason,

        lastHeaderSeenTs = ROOT.lastHeaderSeenTs,
        lastHeaderSeenClean = ROOT.lastHeaderSeenClean,
        lastHeaderSeenEffectiveClean = ROOT.lastHeaderSeenEffectiveClean,
        lastHeaderSeenKind = ROOT.lastHeaderSeenKind,
        lastSnapStartTs = ROOT.lastSnapStartTs,
        lastSnapStartClean = ROOT.lastSnapStartClean,

        seenLineCount = ROOT.seenLineCount,
        lastLineSeenTs = ROOT.lastLineSeenTs,
        lastLineSeenClean = ROOT.lastLineSeenClean,
    }

    if opts.quiet ~= true then
        _out("status (roomfeed capture)")
        for _, k in ipairs({
            "installed", "lineTriggerId", "snapCapturing", "snapHasExits", "snapBufLen",
            "lastOkTs", "lastAbortReason", "lastDegradedReason",
            "lastHeaderSeenTs", "lastHeaderSeenClean", "lastHeaderSeenEffectiveClean", "lastHeaderSeenKind",
            "lastSnapStartTs", "lastSnapStartClean",
            "seenLineCount", "lastLineSeenTs", "lastLineSeenClean",
        }) do
            _out(string.format("  %s=%s", k, tostring(s[k])))
        end
    end

    return s
end

function M.getDebugState()
    local s = M.status({ quiet = true })
    s.installedAtTs = s.installTs
    s.installNote = (s.installed == true) and "subscribed" or "not_installed"
    return s
end

return M
