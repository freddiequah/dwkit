-- #########################################################################
-- Module Name : dwkit.commands.dwwho
-- Owner       : Commands
-- Version     : v2026-01-20C
-- Purpose     :
--   - Implements dwwho command handler (SAFE + GAME refresh capture).
--   - Split out from dwkit.services.command_aliases (Phase 1 split).
--   - Expanded command surface:
--       SAFE:
--         - status / clear / ingestclip / fixture / set / add / remove / list
--       GAME:
--         - refresh (sends 'who' to MUD and captures output)
--
-- Phase 5A (v2026-01-20C):
--   - Add refresh guard:
--       * anti-overlap (skip if capture in-flight)
--       * cooldown (skip if called too soon)
--       * status shows refresh guard state/metadata
--
-- Public API  :
--   - dispatch(ctx, whoStoreSvc, sub)
--   - reset()  (best-effort cancel pending capture session)
--
-- Notes:
--   - ctx must provide:
--       * out(line), err(msg)
--       * callBestEffort(obj, fnName, ...) -> ok, a, b, c, err
--       * getClipboardText() -> string|nil
--       * resolveSendFn() -> function|nil
--       * killTrigger(id), killTimer(id)
--       * tempRegexTrigger(pattern, fn) -> id
--       * tempTimer(seconds, fn) -> id
--       * whoIngestTextBestEffort(svc, text, meta) -> ok, err|nil
--       * printWhoStatus(svc)
-- #########################################################################

local M = {}
M.VERSION = "v2026-01-20C"

local CAP = {
    active = false,
    started = false,
    lines = nil,
    trigAny = nil,
    timer = nil,
    startedAt = nil,
}

-- Phase 5A: refresh guard state (handler-local; does NOT persist)
local GUARD = {
    cooldownSec = 8,      -- default; safe anti-spam without being annoying
    lastAttemptTs = nil,  -- os.time()
    lastOk = nil,         -- boolean|nil
    lastOkTs = nil,       -- os.time()
    lastErr = nil,        -- string|nil
    lastSkipReason = nil, -- string|nil
}

local function _trim(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function _reset(ctx)
    CAP.active = false
    CAP.started = false
    CAP.lines = nil
    CAP.startedAt = nil

    if CAP.trigAny then
        pcall(ctx.killTrigger, CAP.trigAny)
        CAP.trigAny = nil
    end
    if CAP.timer then
        pcall(ctx.killTimer, CAP.timer)
        CAP.timer = nil
    end
end

function M.reset()
    CAP.active = false
    CAP.started = false
    CAP.lines = nil
    CAP.startedAt = nil
    CAP.trigAny = nil
    CAP.timer = nil
end

local function _usage(ctx)
    ctx.out("[DWKit Who] Usage:")
    ctx.out("  dwwho")
    ctx.out("  dwwho status")
    ctx.out("  dwwho list")
    ctx.out("  dwwho clear")
    ctx.out("  dwwho ingestclip")
    ctx.out("  dwwho fixture [basic|party]")
    ctx.out("  dwwho set <name1,name2,...>")
    ctx.out("  dwwho add <name>")
    ctx.out("  dwwho remove <name>")
    ctx.out("  dwwho refresh")
    ctx.out("")
    ctx.out("Notes:")
    ctx.out("  - ingestclip reads your clipboard and parses it as WHO output")
    ctx.out("  - SAFE: all except refresh (no gameplay sends)")
    ctx.out("  - GAME: refresh sends 'who' to the MUD and captures output")
end

local function _printRefreshGuardStatus(ctx)
    local inflight = (CAP.active == true)
    ctx.out("[DWKit Who] refresh guard")
    ctx.out("  refreshInFlight=" .. tostring(inflight))
    ctx.out("  cooldownSec=" .. tostring(GUARD.cooldownSec))
    ctx.out("  lastRefreshAttemptTs=" .. tostring(GUARD.lastAttemptTs or "nil"))
    ctx.out("  lastRefreshOk=" .. tostring(GUARD.lastOk))
    ctx.out("  lastRefreshOkTs=" .. tostring(GUARD.lastOkTs or "nil"))
    ctx.out("  lastRefreshErr=" .. tostring(GUARD.lastErr or "nil"))
    ctx.out("  lastSkipReason=" .. tostring(GUARD.lastSkipReason or "nil"))
end

local function _printStatusBestEffort(ctx, svc)
    if type(ctx.printWhoStatus) == "function" then
        ctx.printWhoStatus(svc)
        _printRefreshGuardStatus(ctx)
        return
    end

    -- fallback status printing (minimal)
    if type(svc) ~= "table" or type(svc.getState) ~= "function" then
        ctx.err("WhoStoreService not available (cannot print status)")
        _printRefreshGuardStatus(ctx)
        return
    end

    local ok, st = pcall(svc.getState)
    if not ok or type(st) ~= "table" then
        ctx.err("WhoStoreService.getState failed")
        _printRefreshGuardStatus(ctx)
        return
    end

    local players = (type(st.players) == "table") and st.players or {}
    local n = 0
    for _ in pairs(players) do n = n + 1 end

    ctx.out("[DWKit Who] status (fallback)")
    ctx.out("  serviceVersion=" .. tostring(st.version or "?"))
    ctx.out("  players=" .. tostring(n))
    ctx.out("  lastUpdatedTs=" .. tostring(st.lastUpdatedTs or "nil"))
    ctx.out("  source=" .. tostring(st.source or "nil"))

    _printRefreshGuardStatus(ctx)
end

local function _finalize(ctx, ok, reason, svc)
    local lines = CAP.lines or {}
    _reset(ctx)

    if not ok then
        GUARD.lastOk = false
        GUARD.lastErr = tostring(reason or "unknown")
        ctx.out("[DWKit Who] refresh FAILED reason=" .. tostring(reason or "unknown"))
        return
    end

    if type(svc) ~= "table" then
        GUARD.lastOk = false
        GUARD.lastErr = "WhoStoreService not available"
        ctx.out("[DWKit Who] refresh FAILED: WhoStoreService not available")
        return
    end

    local text = table.concat(lines, "\n")

    if type(ctx.whoIngestTextBestEffort) ~= "function" then
        GUARD.lastOk = false
        GUARD.lastErr = "whoIngestTextBestEffort ctx helper missing"
        ctx.out("[DWKit Who] refresh ingest FAILED err=whoIngestTextBestEffort ctx helper missing")
        return
    end

    local okIngest, err = ctx.whoIngestTextBestEffort(svc, text, { source = "dwwho:refresh" })
    if okIngest then
        GUARD.lastOk = true
        GUARD.lastOkTs = os.time()
        GUARD.lastErr = nil

        ctx.out("[DWKit Who] refresh OK lines=" .. tostring(#lines))
        _printStatusBestEffort(ctx, svc)
    else
        GUARD.lastOk = false
        GUARD.lastErr = tostring(err or "ingest failed")
        ctx.out("[DWKit Who] refresh ingest FAILED err=" .. tostring(err))
    end
end

local function _shouldSkipRefresh(ctx)
    -- Anti-overlap: never cancel old session automatically; SKIP instead.
    if CAP.active == true then
        GUARD.lastSkipReason = "inflight"
        ctx.out("[DWKit Who] refresh skipped (already running)")
        return true
    end

    local now = os.time()

    -- Cooldown: prevent spam / accidental double-enter.
    if GUARD.lastAttemptTs ~= nil then
        local delta = now - tonumber(GUARD.lastAttemptTs or 0)
        if delta >= 0 and delta < GUARD.cooldownSec then
            local wait = GUARD.cooldownSec - delta
            GUARD.lastSkipReason = "cooldown(" .. tostring(wait) .. "s)"
            ctx.out("[DWKit Who] refresh blocked by cooldown (wait " .. tostring(wait) .. "s)")
            return true
        end
    end

    return false
end

local function _startCapture(ctx, svc, opts)
    opts = opts or {}
    local timeoutSec = tonumber(opts.timeoutSec or 5) or 5
    if timeoutSec < 2 then timeoutSec = 2 end
    if timeoutSec > 10 then timeoutSec = 10 end

    if _shouldSkipRefresh(ctx) then
        return
    end

    local sendFn = ctx.resolveSendFn()
    if type(sendFn) ~= "function" then
        GUARD.lastOk = false
        GUARD.lastErr = "send/sendAll not available"
        ctx.out("[DWKit Who] refresh FAILED: send/sendAll not available in this Mudlet environment")
        return
    end

    GUARD.lastAttemptTs = os.time()
    GUARD.lastSkipReason = nil
    -- Clear previous error when we begin a new attempt (results will be set in finalize).
    GUARD.lastErr = nil

    CAP.active = true
    CAP.started = false
    CAP.lines = {}
    CAP.startedAt = GUARD.lastAttemptTs

    CAP.trigAny = ctx.tempRegexTrigger([[^(.*)$]], function()
        if not CAP.active then return end
        local line = (matches and matches[2]) and tostring(matches[2]) or ""

        if not CAP.started then
            if line == "Players" or line:match("^%[") or line:match("^Total players:") then
                CAP.started = true
            else
                return
            end
        end

        CAP.lines[#CAP.lines + 1] = line

        if line:match("^%s*%d+%s+characters displayed%.%s*$") then
            _finalize(ctx, true, nil, svc)
        end
    end)

    CAP.timer = ctx.tempTimer(timeoutSec, function()
        if not CAP.active then return end
        _finalize(ctx, false, "timeout(" .. tostring(timeoutSec) .. "s)", svc)
    end)

    ctx.out("[DWKit Who] refresh: sending 'who' + capturing output...")
    pcall(sendFn, "who")
end

-- Parse "sub" into: verb + rest
-- Examples:
--   "add Bob" -> verb="add", rest="Bob"
--   "set Bob,Alice" -> verb="set", rest="Bob,Alice"
--   "" -> verb=""
local function _parseVerb(sub)
    sub = _trim(tostring(sub or ""))
    if sub == "" then
        return "", ""
    end
    local v, r = sub:match("^(%S+)%s*(.-)%s*$")
    v = tostring(v or "")
    r = tostring(r or "")
    return v:lower(), r
end

local function _splitNamesCSV(rest)
    rest = _trim(tostring(rest or ""))
    if rest == "" then return {} end

    -- allow "Bob Alice" as well as "Bob,Alice"
    rest = rest:gsub("%s+", " ")

    local names = {}

    -- If commas exist, treat comma as primary delimiter
    if rest:find(",", 1, true) then
        for part in rest:gmatch("([^,]+)") do
            local n = _trim(part)
            if n ~= "" then
                names[#names + 1] = n
            end
        end
        return names
    end

    -- otherwise split by spaces
    for part in rest:gmatch("([^%s]+)") do
        local n = _trim(part)
        if n ~= "" then
            names[#names + 1] = n
        end
    end

    return names
end

local function _svcSetNames(ctx, svc, names, source)
    if type(svc) ~= "table" then
        ctx.err("WhoStoreService not available")
        return
    end

    local payload = { players = names }

    local okCall, _, _, _, err = ctx.callBestEffort(svc, "setState", payload, { source = source or "cmd:dwwho:set" })
    if not okCall then
        ctx.err("setState failed: " .. tostring(err))
        return
    end

    ctx.out("[DWKit Who] set OK count=" .. tostring(#names))
    _printStatusBestEffort(ctx, svc)
end

local function _svcAddName(ctx, svc, name, source)
    if type(svc) ~= "table" then
        ctx.err("WhoStoreService not available")
        return
    end

    local payload = { players = { name } }

    local okCall, _, _, _, err = ctx.callBestEffort(svc, "update", payload, { source = source or "cmd:dwwho:add" })
    if not okCall then
        ctx.err("update(add) failed: " .. tostring(err))
        return
    end

    ctx.out("[DWKit Who] add OK name=" .. tostring(name))
    _printStatusBestEffort(ctx, svc)
end

local function _svcRemoveName(ctx, svc, name, source)
    if type(svc) ~= "table" then
        ctx.err("WhoStoreService not available")
        return
    end

    local payload = { remove = { name } }

    local okCall, _, _, _, err = ctx.callBestEffort(svc, "update", payload, { source = source or "cmd:dwwho:remove" })
    if not okCall then
        ctx.err("update(remove) failed: " .. tostring(err))
        return
    end

    ctx.out("[DWKit Who] remove OK name=" .. tostring(name))
    _printStatusBestEffort(ctx, svc)
end

local function _svcClear(ctx, svc)
    local okCall, _, _, _, err = ctx.callBestEffort(svc, "clear", { source = "cmd:dwwho:clear" })
    if not okCall then
        ctx.err("clear failed: " .. tostring(err))
        return
    end
    ctx.out("[DWKit Who] clear OK")
    _printStatusBestEffort(ctx, svc)
end

local function _svcList(ctx, svc)
    if type(svc) ~= "table" then
        ctx.err("WhoStoreService not available")
        return
    end

    if type(svc.getAllPlayers) == "function" then
        local ok, arr = pcall(svc.getAllPlayers)
        if ok and type(arr) == "table" then
            ctx.out("[DWKit Who] list count=" .. tostring(#arr))
            for i = 1, #arr do
                ctx.out("  - " .. tostring(arr[i]))
            end
            return
        end
    end

    -- fallback: use getState().players map
    if type(svc.getState) ~= "function" then
        ctx.err("WhoStoreService.getState not available")
        return
    end

    local ok, st = pcall(svc.getState)
    if not ok or type(st) ~= "table" then
        ctx.err("WhoStoreService.getState failed")
        return
    end

    local p = (type(st.players) == "table") and st.players or {}
    local keys = {}
    for k, v in pairs(p) do
        if v == true then
            keys[#keys + 1] = k
        end
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)

    ctx.out("[DWKit Who] list count=" .. tostring(#keys))
    for i = 1, #keys do
        ctx.out("  - " .. tostring(keys[i]))
    end
end

local function _fixtureText(which)
    which = tostring(which or "basic"):lower()

    if which == "" or which == "basic" then
        return table.concat({
            "Zeq",
            "Vzae",
            "Xi",
            "Scynox",
        }, "\n"), "basic"
    end

    if which == "party" then
        return table.concat({
            "Zeq",
            "Vzae",
            "Xi",
            "Scynox",
            "Borai",
            "Merec",
            "Kiyomi",
            "Ragna",
            "Eymel",
            "Hnin", -- harmless extra
        }, "\n"), "party"
    end

    -- unknown fixture name -> fallback basic
    return table.concat({
        "Zeq",
        "Vzae",
        "Xi",
        "Scynox",
    }, "\n"), "basic"
end

function M.dispatch(ctx, svc, sub)
    ctx = ctx or {}
    if type(ctx.out) ~= "function" or type(ctx.err) ~= "function" then
        return
    end

    local verb, rest = _parseVerb(sub)

    -- default: status
    if verb == "" or verb == "status" then
        _printStatusBestEffort(ctx, svc)
        return
    end

    if verb == "clear" then
        _svcClear(ctx, svc)
        return
    end

    if verb == "list" then
        _svcList(ctx, svc)
        return
    end

    if verb == "ingestclip" then
        local text = ctx.getClipboardText()
        if type(text) ~= "string" or text:gsub("%s+", "") == "" then
            ctx.err("clipboard is empty (copy WHO output first).")
            return
        end

        if type(ctx.whoIngestTextBestEffort) ~= "function" then
            ctx.err("whoIngestTextBestEffort ctx helper missing")
            return
        end

        local okIngest, err = ctx.whoIngestTextBestEffort(svc, text, { source = "dwwho:clipboard" })
        if okIngest then
            ctx.out("[DWKit Who] ingestclip OK")
            _printStatusBestEffort(ctx, svc)
            return
        end

        ctx.err("ingestclip failed: " .. tostring(err))
        return
    end

    if verb == "fixture" then
        local fixtureName = _trim(rest)
        local fixture, which = _fixtureText(fixtureName)

        if type(ctx.whoIngestTextBestEffort) ~= "function" then
            ctx.err("whoIngestTextBestEffort ctx helper missing")
            return
        end

        local okIngest, err = ctx.whoIngestTextBestEffort(svc, fixture, { source = "dwwho:fixture:" .. tostring(which) })
        if okIngest then
            ctx.out("[DWKit Who] fixture OK name=" .. tostring(which))
            _printStatusBestEffort(ctx, svc)
            return
        end

        ctx.err("fixture ingest failed: " .. tostring(err))
        return
    end

    if verb == "set" then
        local names = _splitNamesCSV(rest)
        if #names == 0 then
            ctx.err("set requires names. Example: dwwho set Bob,Alice")
            return
        end
        _svcSetNames(ctx, svc, names, "cmd:dwwho:set")
        return
    end

    if verb == "add" then
        local name = _trim(rest)
        if name == "" then
            ctx.err("add requires a name. Example: dwwho add Bob")
            return
        end
        _svcAddName(ctx, svc, name, "cmd:dwwho:add")
        return
    end

    if verb == "remove" or verb == "rm" or verb == "del" then
        local name = _trim(rest)
        if name == "" then
            ctx.err("remove requires a name. Example: dwwho remove Bob")
            return
        end
        _svcRemoveName(ctx, svc, name, "cmd:dwwho:remove")
        return
    end

    if verb == "refresh" then
        _startCapture(ctx, svc, { timeoutSec = 5 })
        return
    end

    _usage(ctx)
end

return M
