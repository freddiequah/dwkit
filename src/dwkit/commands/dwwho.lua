-- FILE: src/dwkit/commands/dwwho.lua
-- #########################################################################
-- Module Name : dwkit.commands.dwwho
-- Owner       : Commands
-- Version     : v2026-01-27A
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
-- Phase 5B (v2026-01-21G):
--   - Dispatch supports optional separate arg string:
--       dispatch(ctx, svc, sub, arg)
--     to align with alias router (matches[] tokenization fixes).
--
-- Phase 5C (v2026-01-25A):
--   - Refresh capture start condition tightened:
--       REMOVE line:match("^%[") to avoid DWKit log lines starting capture.
--     Capture now starts only on WHO header lines:
--       "Players" or "Total players:"
--
-- Phase 5D (v2026-01-27A):
--   - Added router-compatible dispatch signature:
--       dispatch(ctx, kit, tokens)
--     so command_router.dispatchGenericCommand can call split modules directly.
--   - Ingest helpers are now internal (no longer require ctx.whoIngestTextBestEffort).
--
-- Public API  :
--   - dispatch(ctx, whoStoreSvc, sub, argOpt)
--   - dispatch(ctx, kit, tokens)  (router signature)
--   - reset()  (best-effort cancel pending capture session)
--
-- Notes:
--   - ctx should provide:
--       * out(line), err(msg)
--       * callBestEffort(obj, fnName, ...) -> ok, a, b, c, err   (optional; improves compatibility)
--       * getClipboardText() -> string|nil                       (optional; for ingestclip)
--       * resolveSendFn() -> function|nil                        (required for refresh)
--       * killTrigger(id), killTimer(id)                         (optional; best-effort cleanup)
--       * tempRegexTrigger(pattern, fn) -> id                    (required for refresh)
--       * tempTimer(seconds, fn) -> id                           (required for refresh)
--       * getService(name) -> svc                                (optional; for router signature)
-- #########################################################################

local M = {}
M.VERSION = "v2026-01-27A"

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

local function _fallbackOut(line)
    line = tostring(line or "")
    if type(cecho) == "function" then
        cecho(line .. "\n")
    elseif type(echo) == "function" then
        echo(line .. "\n")
    else
        print(line)
    end
end

local function _fallbackErr(msg)
    _fallbackOut("[DWKit Who] ERROR: " .. tostring(msg))
end

local function _getCtx(ctx)
    ctx = (type(ctx) == "table") and ctx or {}
    return {
        out = (type(ctx.out) == "function") and ctx.out or _fallbackOut,
        err = (type(ctx.err) == "function") and ctx.err or _fallbackErr,
        callBestEffort = (type(ctx.callBestEffort) == "function") and ctx.callBestEffort or nil,
        getClipboardText = (type(ctx.getClipboardText) == "function") and ctx.getClipboardText or nil,
        resolveSendFn = (type(ctx.resolveSendFn) == "function") and ctx.resolveSendFn or nil,
        killTrigger = (type(ctx.killTrigger) == "function") and ctx.killTrigger or nil,
        killTimer = (type(ctx.killTimer) == "function") and ctx.killTimer or nil,
        tempRegexTrigger = (type(ctx.tempRegexTrigger) == "function") and ctx.tempRegexTrigger or nil,
        tempTimer = (type(ctx.tempTimer) == "function") and ctx.tempTimer or nil,
        getService = (type(ctx.getService) == "function") and ctx.getService or nil,
    }
end

local function _callBestEffort(ctx, obj, fnName, ...)
    if type(ctx) == "table" and type(ctx.callBestEffort) == "function" then
        return ctx.callBestEffort(obj, fnName, ...)
    end

    if type(obj) ~= "table" then
        return false, nil, nil, nil, "svc not table"
    end
    local fn = obj[fnName]
    if type(fn) ~= "function" then
        return false, nil, nil, nil, "missing function: " .. tostring(fnName)
    end

    local ok1, a1, b1, c1 = pcall(fn, ...)
    if ok1 then
        return true, a1, b1, c1, nil
    end

    local ok2, a2, b2, c2 = pcall(fn, obj, ...)
    if ok2 then
        return true, a2, b2, c2, nil
    end

    return false, nil, nil, nil, "call failed: " .. tostring(a1) .. " | " .. tostring(a2)
end

local function _safeRequire(name)
    local ok, mod = pcall(require, name)
    if ok and type(mod) == "table" then return true, mod end
    return false, mod
end

local function _resolveSvcFromKitOrCtx(C, kit)
    if type(C.getService) == "function" then
        local s = C.getService("whoStoreService")
        if type(s) == "table" then return s end
    end

    if type(kit) == "table" and type(kit.services) == "table" and type(kit.services.whoStoreService) == "table" then
        return kit.services.whoStoreService
    end

    local ok, mod = _safeRequire("dwkit.services.whostore_service")
    if ok and type(mod) == "table" then
        return mod
    end

    return nil
end

local function _reset(C)
    CAP.active = false
    CAP.started = false
    CAP.lines = nil
    CAP.startedAt = nil

    if CAP.trigAny and type(C.killTrigger) == "function" then
        pcall(C.killTrigger, CAP.trigAny)
        CAP.trigAny = nil
    else
        CAP.trigAny = nil
    end

    if CAP.timer and type(C.killTimer) == "function" then
        pcall(C.killTimer, CAP.timer)
        CAP.timer = nil
    else
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

local function _usage(C)
    C.out("[DWKit Who] Usage:")
    C.out("  dwwho")
    C.out("  dwwho status")
    C.out("  dwwho list")
    C.out("  dwwho clear")
    C.out("  dwwho ingestclip")
    C.out("  dwwho fixture [basic|party]")
    C.out("  dwwho set <name1,name2,...>")
    C.out("  dwwho add <name>")
    C.out("  dwwho remove <name>")
    C.out("  dwwho refresh")
    C.out("")
    C.out("Notes:")
    C.out("  - ingestclip reads your clipboard and parses it as WHO output")
    C.out("  - SAFE: all except refresh (no gameplay sends)")
    C.out("  - GAME: refresh sends 'who' to the MUD and captures output")
end

local function _printRefreshGuardStatus(C)
    local inflight = (CAP.active == true)
    C.out("[DWKit Who] refresh guard")
    C.out("  refreshInFlight=" .. tostring(inflight))
    C.out("  cooldownSec=" .. tostring(GUARD.cooldownSec))
    C.out("  lastRefreshAttemptTs=" .. tostring(GUARD.lastAttemptTs or "nil"))
    C.out("  lastRefreshOk=" .. tostring(GUARD.lastOk))
    C.out("  lastRefreshOkTs=" .. tostring(GUARD.lastOkTs or "nil"))
    C.out("  lastRefreshErr=" .. tostring(GUARD.lastErr or "nil"))
    C.out("  lastSkipReason=" .. tostring(GUARD.lastSkipReason or "nil"))
end

local function _printStatusBestEffort(C, svc)
    -- fallback status printing (minimal)
    if type(svc) ~= "table" or type(svc.getState) ~= "function" then
        C.err("WhoStoreService not available (cannot print status)")
        _printRefreshGuardStatus(C)
        return
    end

    local ok, st = pcall(svc.getState)
    if not ok or type(st) ~= "table" then
        C.err("WhoStoreService.getState failed")
        _printRefreshGuardStatus(C)
        return
    end

    local players = (type(st.players) == "table") and st.players or {}
    local n = 0
    for _ in pairs(players) do n = n + 1 end

    C.out("[DWKit Who] status (dwwho)")
    C.out("  serviceVersion=" .. tostring(st.version or svc.VERSION or "?"))
    C.out("  players=" .. tostring(n))
    C.out("  lastUpdatedTs=" .. tostring(st.lastUpdatedTs or "nil"))
    C.out("  source=" .. tostring(st.source or "nil"))

    _printRefreshGuardStatus(C)
end

local function _ingestTextBestEffort(C, svc, text, meta)
    meta = (type(meta) == "table") and meta or {}
    text = tostring(text or "")

    if type(svc) ~= "table" then
        return false, "svc not available"
    end

    if type(svc.ingestWhoText) == "function" then
        local okCall, a, b, c, err = _callBestEffort(C, svc, "ingestWhoText", text, meta)
        if okCall and a ~= false then
            return true, nil
        end
        return false, tostring(b or c or err or "ingestWhoText failed")
    end

    if type(svc.ingestWhoLines) == "function" then
        local lines = {}
        text = text:gsub("\r", "")
        for line in text:gmatch("([^\n]+)") do
            lines[#lines + 1] = line
        end
        local okCall, a, b, c, err = _callBestEffort(C, svc, "ingestWhoLines", lines, meta)
        if okCall and a ~= false then
            return true, nil
        end
        return false, tostring(b or c or err or "ingestWhoLines failed")
    end

    return false, "WhoStoreService ingestWhoText/ingestWhoLines not available"
end

local function _finalize(C, ok, reason, svc)
    local lines = CAP.lines or {}
    _reset(C)

    if not ok then
        GUARD.lastOk = false
        GUARD.lastErr = tostring(reason or "unknown")
        C.out("[DWKit Who] refresh FAILED reason=" .. tostring(reason or "unknown"))
        return
    end

    if type(svc) ~= "table" then
        GUARD.lastOk = false
        GUARD.lastErr = "WhoStoreService not available"
        C.out("[DWKit Who] refresh FAILED: WhoStoreService not available")
        return
    end

    local text = table.concat(lines, "\n")

    local okIngest, err = _ingestTextBestEffort(C, svc, text, { source = "dwwho:refresh" })
    if okIngest then
        GUARD.lastOk = true
        GUARD.lastOkTs = os.time()
        GUARD.lastErr = nil

        C.out("[DWKit Who] refresh OK lines=" .. tostring(#lines))
        _printStatusBestEffort(C, svc)
    else
        GUARD.lastOk = false
        GUARD.lastErr = tostring(err or "ingest failed")
        C.out("[DWKit Who] refresh ingest FAILED err=" .. tostring(err))
    end
end

local function _shouldSkipRefresh(C)
    -- Anti-overlap: never cancel old session automatically; SKIP instead.
    if CAP.active == true then
        GUARD.lastSkipReason = "inflight"
        C.out("[DWKit Who] refresh skipped (already running)")
        return true
    end

    local now = os.time()

    -- Cooldown: prevent spam / accidental double-enter.
    if GUARD.lastAttemptTs ~= nil then
        local delta = now - tonumber(GUARD.lastAttemptTs or 0)
        if delta >= 0 and delta < GUARD.cooldownSec then
            local wait = GUARD.cooldownSec - delta
            GUARD.lastSkipReason = "cooldown(" .. tostring(wait) .. "s)"
            C.out("[DWKit Who] refresh blocked by cooldown (wait " .. tostring(wait) .. "s)")
            return true
        end
    end

    return false
end

local function _startCapture(C, svc, opts)
    opts = opts or {}
    local timeoutSec = tonumber(opts.timeoutSec or 5) or 5
    if timeoutSec < 2 then timeoutSec = 2 end
    if timeoutSec > 10 then timeoutSec = 10 end

    if _shouldSkipRefresh(C) then
        return
    end

    if type(C.resolveSendFn) ~= "function" then
        GUARD.lastOk = false
        GUARD.lastErr = "resolveSendFn ctx helper missing"
        C.out("[DWKit Who] refresh FAILED: resolveSendFn ctx helper missing")
        return
    end

    local sendFn = C.resolveSendFn()
    if type(sendFn) ~= "function" then
        GUARD.lastOk = false
        GUARD.lastErr = "send/sendAll not available"
        C.out("[DWKit Who] refresh FAILED: send/sendAll not available in this Mudlet environment")
        return
    end

    if type(C.tempRegexTrigger) ~= "function" or type(C.tempTimer) ~= "function" then
        GUARD.lastOk = false
        GUARD.lastErr = "tempRegexTrigger/tempTimer ctx helpers missing"
        C.out("[DWKit Who] refresh FAILED: tempRegexTrigger/tempTimer ctx helpers missing")
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

    CAP.trigAny = C.tempRegexTrigger([[^(.*)$]], function()
        if not CAP.active then return end
        local line = (matches and matches[2]) and tostring(matches[2]) or ""

        if not CAP.started then
            -- Start capture ONLY when WHO output begins (avoid DWKit log lines).
            if line == "Players" or line:match("^Total players:") then
                CAP.started = true
            else
                return
            end
        end

        CAP.lines[#CAP.lines + 1] = line

        if line:match("^%s*%d+%s+characters displayed%.%s*$") then
            _finalize(C, true, nil, svc)
        end
    end)

    CAP.timer = C.tempTimer(timeoutSec, function()
        if not CAP.active then return end
        _finalize(C, false, "timeout(" .. tostring(timeoutSec) .. "s)", svc)
    end)

    C.out("[DWKit Who] refresh: sending 'who' + capturing output...")
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

local function _mergeRestWithArg(rest, arg)
    rest = _trim(tostring(rest or ""))
    arg = _trim(tostring(arg or ""))

    if arg == "" then
        return rest
    end

    -- If caller provided a separate arg, prefer it when rest is empty.
    if rest == "" then
        return arg
    end

    -- If both exist, append (conservative, avoids dropping info).
    return rest .. " " .. arg
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

local function _svcSetNames(C, svc, names, source)
    if type(svc) ~= "table" then
        C.err("WhoStoreService not available")
        return
    end

    local payload = { players = names }

    local okCall, _, _, _, err = _callBestEffort(C, svc, "setState", payload, { source = source or "cmd:dwwho:set" })
    if not okCall then
        C.err("setState failed: " .. tostring(err))
        return
    end

    C.out("[DWKit Who] set OK count=" .. tostring(#names))
    _printStatusBestEffort(C, svc)
end

local function _svcAddName(C, svc, name, source)
    if type(svc) ~= "table" then
        C.err("WhoStoreService not available")
        return
    end

    local payload = { players = { name } }

    local okCall, _, _, _, err = _callBestEffort(C, svc, "update", payload, { source = source or "cmd:dwwho:add" })
    if not okCall then
        C.err("update(add) failed: " .. tostring(err))
        return
    end

    C.out("[DWKit Who] add OK name=" .. tostring(name))
    _printStatusBestEffort(C, svc)
end

local function _svcRemoveName(C, svc, name, source)
    if type(svc) ~= "table" then
        C.err("WhoStoreService not available")
        return
    end

    local payload = { remove = { name } }

    local okCall, _, _, _, err = _callBestEffort(C, svc, "update", payload, { source = source or "cmd:dwwho:remove" })
    if not okCall then
        C.err("update(remove) failed: " .. tostring(err))
        return
    end

    C.out("[DWKit Who] remove OK name=" .. tostring(name))
    _printStatusBestEffort(C, svc)
end

local function _svcClear(C, svc)
    local okCall, _, _, _, err = _callBestEffort(C, svc, "clear", { source = "cmd:dwwho:clear" })
    if not okCall then
        C.err("clear failed: " .. tostring(err))
        return
    end
    C.out("[DWKit Who] clear OK")
    _printStatusBestEffort(C, svc)
end

local function _svcList(C, svc)
    if type(svc) ~= "table" then
        C.err("WhoStoreService not available")
        return
    end

    if type(svc.getAllPlayers) == "function" then
        local ok, arr = pcall(svc.getAllPlayers)
        if ok and type(arr) == "table" then
            C.out("[DWKit Who] list count=" .. tostring(#arr))
            for i = 1, #arr do
                C.out("  - " .. tostring(arr[i]))
            end
            return
        end
    end

    -- fallback: use getState().players map
    if type(svc.getState) ~= "function" then
        C.err("WhoStoreService.getState not available")
        return
    end

    local ok, st = pcall(svc.getState)
    if not ok or type(st) ~= "table" then
        C.err("WhoStoreService.getState failed")
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

    C.out("[DWKit Who] list count=" .. tostring(#keys))
    for i = 1, #keys do
        C.out("  - " .. tostring(keys[i]))
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

local function _dispatchCore(ctx, svc, sub, arg)
    local C = _getCtx(ctx)

    if type(C.out) ~= "function" or type(C.err) ~= "function" then
        return
    end

    local verb, rest = _parseVerb(sub)
    rest = _mergeRestWithArg(rest, arg)

    -- default: status
    if verb == "" or verb == "status" then
        _printStatusBestEffort(C, svc)
        return
    end

    if verb == "clear" then
        _svcClear(C, svc)
        return
    end

    if verb == "list" then
        _svcList(C, svc)
        return
    end

    if verb == "ingestclip" then
        local text = (type(C.getClipboardText) == "function") and C.getClipboardText() or nil
        if type(text) ~= "string" or text:gsub("%s+", "") == "" then
            C.err("clipboard is empty (copy WHO output first).")
            return
        end

        local okIngest, err = _ingestTextBestEffort(C, svc, text, { source = "dwwho:clipboard" })
        if okIngest then
            C.out("[DWKit Who] ingestclip OK")
            _printStatusBestEffort(C, svc)
            return
        end

        C.err("ingestclip failed: " .. tostring(err))
        return
    end

    if verb == "fixture" then
        local fixtureName = _trim(rest)
        local fixture, which = _fixtureText(fixtureName)

        local okIngest, err = _ingestTextBestEffort(C, svc, fixture, { source = "dwwho:fixture:" .. tostring(which) })
        if okIngest then
            C.out("[DWKit Who] fixture OK name=" .. tostring(which))
            _printStatusBestEffort(C, svc)
            return
        end

        C.err("fixture ingest failed: " .. tostring(err))
        return
    end

    if verb == "set" then
        local names = _splitNamesCSV(rest)
        if #names == 0 then
            C.err("set requires names. Example: dwwho set Bob,Alice")
            return
        end
        _svcSetNames(C, svc, names, "cmd:dwwho:set")
        return
    end

    if verb == "add" then
        local name = _trim(rest)
        if name == "" then
            C.err("add requires a name. Example: dwwho add Bob")
            return
        end
        _svcAddName(C, svc, name, "cmd:dwwho:add")
        return
    end

    if verb == "remove" or verb == "rm" or verb == "del" then
        local name = _trim(rest)
        if name == "" then
            C.err("remove requires a name. Example: dwwho remove Bob")
            return
        end
        _svcRemoveName(C, svc, name, "cmd:dwwho:remove")
        return
    end

    if verb == "refresh" then
        _startCapture(C, svc, { timeoutSec = 5 })
        return
    end

    _usage(C)
end

function M.dispatch(ctx, a, b, c)
    -- Router signature: dispatch(ctx, kit, tokens)
    if type(b) == "table" and type(b[1]) == "string" then
        local C = _getCtx(ctx)
        local kit = a
        local tokens = b

        local svc = _resolveSvcFromKitOrCtx(C, kit)
        if type(svc) ~= "table" then
            C.err("WhoStoreService not available. Run loader.init() first.")
            return
        end

        local sub = tostring(tokens[2] or "")
        local arg = ""
        if #tokens >= 3 then
            arg = table.concat(tokens, " ", 3)
        end

        _dispatchCore(ctx, svc, sub, arg)
        return
    end

    -- Legacy signature: dispatch(ctx, svc, sub, arg)
    _dispatchCore(ctx, a, b, c)
end

return M

-- END FILE: src/dwkit/commands/dwwho.lua
