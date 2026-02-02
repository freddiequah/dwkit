-- #########################################################################
-- Module Name : dwkit.capture.roomfeed_capture
-- Owner       : Capture
-- Version     : v2026-02-02F
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
--     Fallback title detection requires at least one uppercase letter and rejects "dw*/lua*" lines.
--   - "appears out of thin air." is standard player relocation, treat as ARRIVE (not admin-only).
--   - Admin poof lines are customizable, so we do NOT attempt to special-case "poof" anymore.
--   - IMPORTANT: MUD output may include ANSI/control characters. We strip ANSI + \r for parsing
--     decisions (header/exits/prompt/arrive/leave), while keeping raw lines for ingestion.
--   - Defensive: if a snapshot starts on the exits line, we set snapHasExits immediately.
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
-- Events Emitted   : None (delegates to services)
-- Events Consumed  : MUD output via tempRegexTrigger line hook
-- Persistence      : None
-- Automation Policy: Passive Capture (SAFE). No gameplay commands, no timers.
-- Dependencies     :
--   - dwkit.services.roomentities_service
--   - dwkit.services.roomfeed_status_service
-- #########################################################################

local M = {}

M.VERSION = "v2026-02-02F"

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

    return s
end

local function _cleanLine(ln)
    return _stripAnsi(tostring(ln or ""))
end

local function _isPromptNoise(lnClean)
    local ln = tostring(lnClean or "")
    if ln == "" then return false end
    if ln:find("<%d") and (ln:lower():find("hp") or ln:lower():find("mp") or ln:lower():find("mv")) then
        return true
    end
    return false
end

-- Strong header: room line includes "(#12345)"
local function _isRoomHeaderStrong(lnClean)
    local ln = tostring(lnClean or "")
    return (ln:find("%(#%d+%)") ~= nil)
end

local function _isExitsLine(lnClean)
    local ln = tostring(lnClean or "")
    return (ln:lower():match("^%s*obvious exits:%s*$") ~= nil)
end

-- Fallback header: conservative "room title" detection for rooms that do NOT print "(#id)".
-- We keep this strict so we don't accidentally start snapshots on random one-liners or command echoes.
local function _isRoomTitleCandidate(lnClean)
    local ln = tostring(lnClean or "")
    if ln == "" then return false end
    if _isPromptNoise(ln) then return false end

    -- must be unindented
    if ln:match("^%s") then return false end

    local t = _trim(ln)
    if t == "" then return false end

    -- avoid bracket/system lines: "[ X has connected. ]"
    if t:match("^%[") then return false end

    local lower = t:lower()

    -- never treat exits line as a title
    if _isExitsLine(t) then return false end

    -- avoid command echo lines / kit invocations
    if lower:match("^dw[%w_%-]") then return false end
    if lower:match("^lua%s") then return false end

    -- avoid obvious non-title lines
    if lower:match("^you are ") then return false end
    if lower:match("^at the ") then return false end
    if lower:find(" has connected") or lower:find(" has quit") or lower:find(" un%-renting") then return false end

    -- avoid arrive/leave chatter being mistaken as title
    if lower:find(" arrives") or lower:find(" leaves") or lower:find(" appears") then return false end

    -- typical room title should not end with punctuation (most of your room titles don't)
    if t:match("[%:%.%!%?]$") then return false end

    -- length bounds (title-ish)
    local len = #t
    if len < 4 or len > 72 then return false end

    -- must contain at least one letter
    if not t:match("[%a]") then return false end

    -- critical: require at least one uppercase letter to avoid matching command echos (usually lowercase)
    if not t:match("%u") then return false end

    return true
end

local function _isRoomHeaderAny(lnClean)
    return _isRoomHeaderStrong(lnClean) or _isRoomTitleCandidate(lnClean)
end

local function _tryParseArriveLeave(lnClean)
    local ln = _trim(lnClean)
    if ln == "" then return nil end

    -- ARRIVE (standard)
    local name = ln:match("^([%a][%w%-%']*)%s+arrives")
    if name then
        return { kind = "arrive", name = name }
    end

    -- ARRIVE (teleport/relocation styles seen in your logs)
    name = ln:match("^([%a][%w%-%']*)%s+appears%s+out%s+of%s+thin%s+air%.$")
    if name then
        return { kind = "arrive", name = name }
    end

    -- (optional but common) "X arrives suddenly."
    name = ln:match("^([%a][%w%-%']*)%s+arrives%s+suddenly%.$")
    if name then
        return { kind = "arrive", name = name }
    end

    -- LEAVE
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

local function _copyBuckets(state)
    state = (type(state) == "table") and state or {}
    local out = { players = {}, mobs = {}, items = {}, unknown = {} }
    for _, k in ipairs({ "players", "mobs", "items", "unknown" }) do
        local t = state[k]
        if type(t) == "table" then
            for i = 1, #t do out[k][i] = tostring(t[i]) end
        end
    end
    return out
end

local function _removeFromBuckets(buckets, name)
    name = tostring(name or "")
    if name == "" then return false end
    local changed = false

    for _, k in ipairs({ "players", "mobs", "items", "unknown" }) do
        local t = buckets[k]
        if type(t) == "table" then
            local nextT = {}
            for i = 1, #t do
                if tostring(t[i]) ~= name then
                    nextT[#nextT + 1] = t[i]
                else
                    changed = true
                end
            end
            buckets[k] = nextT
        end
    end

    return changed
end

local function _addToUnknown(buckets, name)
    name = tostring(name or "")
    if name == "" then return false end

    for _, k in ipairs({ "players", "mobs", "items", "unknown" }) do
        local t = buckets[k]
        if type(t) == "table" then
            for i = 1, #t do
                if tostring(t[i]) == name then
                    return false
                end
            end
        end
    end

    buckets.unknown = (type(buckets.unknown) == "table") and buckets.unknown or {}
    buckets.unknown[#buckets.unknown + 1] = name
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

local function _beginSnap(lnRaw, lnClean)
    _resetSnap()
    ROOT.snapCapturing = true
    ROOT.snapStartTs = _nowTs()
    ROOT.snapStartLineRaw = tostring(lnRaw or "")
    ROOT.snapStartLineClean = tostring(lnClean or "")
    ROOT.snapBuf[#ROOT.snapBuf + 1] = tostring(lnRaw or "")
    ROOT.snapSeenLines = 1

    -- defensive: if snapshot begins on exits line, mark it immediately
    if _isExitsLine(ROOT.snapStartLineClean) then
        ROOT.snapHasExits = true
    end
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

local function _finalizeSnap()
    local buf = ROOT.snapBuf
    local hasExits = (ROOT.snapHasExits == true)

    local okS, Status = _resolveStatusSvc()
    local ts = _nowTs()

    if hasExits ~= true then
        ROOT.lastAbortReason = "end:prompt_before_exits"
        _resetSnap()
        if okS then
            Status.noteAbort("end:prompt_before_exits", { ts = ts })
        end
        return
    end

    local okR, RoomSvc = _resolveRoomSvc()
    if okR then
        RoomSvc.ingestLookLines(buf, { source = "roomfeed_capture", ts = ts })
    end

    ROOT.lastOkTs = ts
    _resetSnap()

    if okS then
        Status.noteSnapshot({ source = "roomfeed_capture", ts = ts })
    end
end

local function _handleArriveLeave(lnClean)
    local parsed = _tryParseArriveLeave(lnClean)
    if not parsed then return end

    local name = tostring(parsed.name or "")
    if name == "" then
        -- Keep conservative: do not spam DEGRADED for unknown chatter.
        return
    end

    local okR, RoomSvc = _resolveRoomSvc()
    if not okR then return end

    local current = RoomSvc.getState()
    local buckets = _copyBuckets(current)
    local changed = false

    if parsed.kind == "arrive" then
        changed = _addToUnknown(buckets, name)
    elseif parsed.kind == "leave" then
        changed = _removeFromBuckets(buckets, name)
    end

    if changed then
        RoomSvc.update(buckets, { forceEmit = true, source = "roomfeed_arriveleave", ts = _nowTs() })
    end
end

function M.getVersion()
    return tostring(M.VERSION)
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

        if ROOT.snapCapturing ~= true then
            _handleArriveLeave(lnClean)
        end

        if ROOT.snapCapturing ~= true then
            if _isRoomHeaderAny(lnClean) then
                _beginSnap(lnRaw, lnClean)
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

        -- If a new header/title starts mid-capture, restart (best-effort).
        if _isRoomHeaderAny(lnClean) and tostring(lnClean or "") ~= tostring(ROOT.snapStartLineClean or "") then
            _abortSnap("abort:restart_header_seen")
            _beginSnap(lnRaw, lnClean)
            return
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
    }

    if opts.quiet ~= true then
        _out("status (roomfeed capture)")
        for _, k in ipairs({
            "installed", "lineTriggerId", "snapCapturing", "snapHasExits", "snapBufLen",
            "lastOkTs", "lastAbortReason", "lastDegradedReason",
        }) do
            _out(string.format("  %s=%s", k, tostring(s[k])))
        end
    end

    return s
end

-- compat helper used by your already-installed dwroom.lua
function M.getDebugState()
    local s = M.status({ quiet = true })
    s.installedAtTs = s.installTs
    s.installNote = (s.installed == true) and "subscribed" or "not_installed"
    return s
end

return M
