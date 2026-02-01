-- #########################################################################
-- Module Name : dwkit.capture.roomfeed_capture
-- Owner       : Capture
-- Version     : v2026-02-02B
-- Purpose     :
--   - Passive capture of room output blocks (movement room header, look output)
--     without GMCP and without sending any commands.
--   - Detects a "room snapshot" start from a room header marker, buffers lines
--     until prompt-noise is seen, then ingests the block into RoomEntitiesService.
--   - Best-effort arrival/leave line inference (conservative): updates Unknown bucket
--     only for simple single-token names; otherwise marks room watch as DEGRADED.
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

M.VERSION = "v2026-02-02B"

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

local function _isPromptNoise(ln)
    ln = tostring(ln or "")
    if ln == "" then return false end
    if ln:find("<%d") and (ln:lower():find("hp") or ln:lower():find("mp") or ln:lower():find("mv")) then
        return true
    end
    return false
end

local function _isRoomHeader(ln)
    ln = tostring(ln or "")
    return (ln:find("%(#%d+%)") ~= nil)
end

local function _isExitsLine(ln)
    ln = tostring(ln or "")
    return (ln:lower():match("^%s*obvious exits:%s*$") ~= nil)
end

local function _tryParseArriveLeave(ln)
    ln = _trim(ln)
    if ln == "" then return nil end

    local lower = ln:lower()
    if lower:find("poof") then
        return { kind = "poof", name = nil }
    end

    local name = ln:match("^([%a][%w%-%']*)%s+arrives")
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
    snapStartLine = nil,
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
    ROOT.snapStartLine = nil
    ROOT.snapHasExits = false
    ROOT.snapSeenLines = 0
end

local function _beginSnap(ln)
    _resetSnap()
    ROOT.snapCapturing = true
    ROOT.snapStartTs = _nowTs()
    ROOT.snapStartLine = tostring(ln or "")
    ROOT.snapBuf[#ROOT.snapBuf + 1] = tostring(ln or "")
    ROOT.snapSeenLines = 1
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

local function _handleArriveLeave(ln)
    local parsed = _tryParseArriveLeave(ln)
    if not parsed then return end

    local okS, Status = _resolveStatusSvc()
    if parsed.kind == "poof" then
        ROOT.lastDegradedReason = "admin poof line seen, run look to resync"
        if okS then
            Status.noteDegraded(ROOT.lastDegradedReason, { ts = _nowTs() })
        end
        return
    end

    local name = tostring(parsed.name or "")
    if name == "" then
        ROOT.lastDegradedReason = "unrecognized arrive/leave line, run look to resync"
        if okS then
            Status.noteDegraded(ROOT.lastDegradedReason, { ts = _nowTs() })
        end
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
        local ln = (type(line) == "string") and line or tostring(line or "")

        if ROOT.snapCapturing ~= true then
            _handleArriveLeave(ln)
        end

        if ROOT.snapCapturing ~= true then
            if _isRoomHeader(ln) then
                _beginSnap(ln)
                return
            end
            return
        end

        if _isPromptNoise(ln) then
            _finalizeSnap()
            return
        end

        ROOT.snapSeenLines = (tonumber(ROOT.snapSeenLines or 0) or 0) + 1
        if ROOT.snapSeenLines > MAX_SNAP_LINES then
            _abortSnap("abort:max_lines")
            return
        end

        if _isRoomHeader(ln) and tostring(ln or "") ~= tostring(ROOT.snapStartLine or "") then
            _abortSnap("abort:restart_header_seen")
            _beginSnap(ln)
            return
        end

        if _isExitsLine(ln) then
            ROOT.snapHasExits = true
        end

        ROOT.snapBuf[#ROOT.snapBuf + 1] = ln
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
