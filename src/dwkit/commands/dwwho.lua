-- FILE: src/dwkit/commands/dwwho.lua
-- #########################################################################
-- Module Name : dwkit.commands.dwwho
-- Owner       : Commands
-- Version     : v2026-01-29C
-- Purpose     :
--   - Implements dwwho command handler (SAFE + GAME refresh capture).
--   - Split out from dwkit.services.command_aliases (Phase 1 split).
--   - Expanded command surface:
--       SAFE:
--         - status / clear / ingestclip / fixture / set / add / remove / list / watch
--       GAME:
--         - refresh (sends 'who' to MUD and captures output)
--
-- NEW (v2026-01-28E):
--   - Auto-capture watcher: when YOU type "who" manually and WHO output appears,
--     DWKit captures the WHO block and ingests into WhoStoreService automatically.
--   - refresh reuses watcher capture when watcher is enabled (avoids duplicate triggers).
--   - Commands:
--       dwwho watch status
--       dwwho watch on
--       dwwho watch off
--
-- FIX (v2026-01-28G):
--   - Capture filtering to avoid ingesting prompt / DWKit output / blank noise.
--   - Footer detection now tolerates trailing text so capture finalizes reliably.
--
-- FIX (v2026-01-28H):
--   - Refresh expectations now EXPIRE quickly, so manual "who" typed later does NOT
--     get mislabeled as dwwho:refresh / verbose output.
--
-- FIX (v2026-01-29A):
--   - Watcher is now a SINGLETON across reloads:
--       * kills orphaned triggers from older module instances
--       * prevents duplicate captures and wrong refresh source tagging
--
-- FIX (v2026-01-29B):
--   - Capture cleanup leak patched:
--       * ensure finalize/reset ALWAYS kills CAP triggers/timer even when verbose
--         capture context lacks killTrigger/killTimer (watcher + refresh expectations path)
--
-- FIX (v2026-01-29C):
--   - Watcher ON/OFF now toggles WhoStoreService auto-capture gate, so orphaned
--     triggers cannot update snapshot when watcher is OFF.
-- #########################################################################

local M = {}
M.VERSION = "v2026-01-29C"

-- GLOBAL singleton key for watcher trigger IDs (survives reloads)
local WATCH_SINGLETON_KEY = "DWKit_WHO_WATCH_SINGLETON"

-- Capture session state (shared by refresh + watcher)
local CAP = {
    active = false,
    started = false,
    lines = nil,
    trigAny = nil,
    timer = nil,
    startedAt = nil,

    -- expectations set by refresh; watcher consumes these (if present)
    expectSource = nil,     -- string|nil (e.g. "dwwho:refresh")
    expectVerbose = false,  -- boolean (refresh prints status; watcher default quiet)
    expectTimeoutSec = nil, -- number|nil
    expectSetTs = nil,      -- os.time() when expectations were set (for expiry)
    expectTtlSec = 2,       -- how long refresh expectations are valid (seconds)
}

-- Auto watcher install state
local WATCH = {
    enabled = false,
    trigPlayers = nil, -- header trigger: "Players"
    trigTotal = nil,   -- header trigger: "Total players:"
    lastErr = nil,
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

local function _noop() end

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

local function _mudletKillTrigger(id)
    if id and type(killTrigger) == "function" then pcall(killTrigger, id) end
end

local function _mudletKillTimer(id)
    if id and type(killTimer) == "function" then pcall(killTimer, id) end
end

local function _mudletTempRegexTrigger(pat, fn)
    if type(tempRegexTrigger) == "function" then
        return tempRegexTrigger(pat, fn)
    end
    return nil
end

local function _mudletTempTimer(sec, fn)
    if type(tempTimer) == "function" then
        return tempTimer(sec, fn)
    end
    return nil
end

local function _clearExpectations()
    CAP.expectSource = nil
    CAP.expectVerbose = false
    CAP.expectTimeoutSec = nil
    CAP.expectSetTs = nil
end

local function _expireExpectationsIfStale()
    if CAP.expectSource == nil and CAP.expectTimeoutSec == nil and CAP.expectVerbose ~= true then
        return
    end
    local ttl = tonumber(CAP.expectTtlSec or 2) or 2
    if ttl < 1 then ttl = 1 end
    if ttl > 10 then ttl = 10 end

    local now = os.time()
    local setTs = tonumber(CAP.expectSetTs or 0) or 0
    if setTs <= 0 then
        -- if somehow set without timestamp, treat as stale and clear
        _clearExpectations()
        return
    end

    if (now - setTs) > ttl then
        _clearExpectations()
    end
end

local function _reset(C)
    C = (type(C) == "table") and C or {}

    CAP.active = false
    CAP.started = false
    CAP.lines = nil
    CAP.startedAt = nil

    -- FIX (v2026-01-29B): always have a killer path, even if ctx lacks killTrigger/killTimer
    local killTrig = (type(C.killTrigger) == "function") and C.killTrigger or _mudletKillTrigger
    local killTim = (type(C.killTimer) == "function") and C.killTimer or _mudletKillTimer

    if CAP.trigAny then
        pcall(killTrig, CAP.trigAny)
        CAP.trigAny = nil
    else
        CAP.trigAny = nil
    end

    if CAP.timer then
        pcall(killTim, CAP.timer)
        CAP.timer = nil
    else
        CAP.timer = nil
    end

    -- consume expectations after any session ends
    _clearExpectations()
end

function M.reset()
    CAP.active = false
    CAP.started = false
    CAP.lines = nil
    CAP.startedAt = nil

    if CAP.trigAny then _mudletKillTrigger(CAP.trigAny) end
    if CAP.timer then _mudletKillTimer(CAP.timer) end

    CAP.trigAny = nil
    CAP.timer = nil
    _clearExpectations()
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
    C.out("  dwwho watch status")
    C.out("  dwwho watch on")
    C.out("  dwwho watch off")
    C.out("")
    C.out("Notes:")
    C.out(
        "  - AUTO: when you type 'who' manually, watcher captures and ingests quietly (no output). Confirm via dwwho status/list.")
    C.out("  - ingestclip reads your clipboard and parses it as WHO output (optional)")
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

local function _printWatchStatus(C)
    C.out("[DWKit Who] watcher")
    C.out("  enabled=" .. tostring(WATCH.enabled))
    C.out("  trigPlayers=" .. tostring(WATCH.trigPlayers or "nil"))
    C.out("  trigTotal=" .. tostring(WATCH.trigTotal or "nil"))
    C.out("  lastErr=" .. tostring(WATCH.lastErr or "nil"))

    -- show singleton info (debugging duplicates)
    local g = _G and _G[WATCH_SINGLETON_KEY] or nil
    if type(g) == "table" then
        C.out("[DWKit Who] watcher singleton")
        C.out("  key=" .. tostring(WATCH_SINGLETON_KEY))
        C.out("  installedBy=" .. tostring(g.installedBy or "nil"))
        C.out("  trigPlayers=" .. tostring(g.trigPlayers or "nil"))
        C.out("  trigTotal=" .. tostring(g.trigTotal or "nil"))
        C.out("  installedAtTs=" .. tostring(g.installedAtTs or "nil"))
    end
end

local function _printStatusBestEffort(C, svc)
    if type(svc) ~= "table" or type(svc.getState) ~= "function" then
        C.err("WhoStoreService not available (cannot print status)")
        _printWatchStatus(C)
        _printRefreshGuardStatus(C)
        return
    end

    local ok, st = pcall(svc.getState)
    if not ok or type(st) ~= "table" then
        C.err("WhoStoreService.getState failed")
        _printWatchStatus(C)
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
    C.out("  autoCaptureEnabled=" .. tostring(st.autoCaptureEnabled))

    _printWatchStatus(C)
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

local function _getPlayersCountBestEffort(svc)
    if type(svc) ~= "table" then return nil end
    if type(svc.getAllPlayers) == "function" then
        local ok, arr = pcall(svc.getAllPlayers)
        if ok and type(arr) == "table" then
            return #arr
        end
    end
    if type(svc.getState) == "function" then
        local ok, st = pcall(svc.getState)
        if ok and type(st) == "table" and type(st.players) == "table" then
            local n = 0
            for _, v in pairs(st.players) do
                if v == true then n = n + 1 end
            end
            return n
        end
    end
    return nil
end

local function _looksLikeWhoFooter(line)
    if type(line) ~= "string" then return false end
    local t = _trim(line):lower()
    -- tolerate trailing text after the footer (e.g. if console prints append same line)
    return (t:match("^%d+%s+characters%s+displayed%.?") ~= nil)
end

local function _isLikelyPromptLine(t)
    -- Common Mudlet prompt shapes:
    --   (i54) <812hp 100mp 83mv>
    --   <812hp 100mp 83mv>
    if type(t) ~= "string" then return false end
    if t:match("^%(%w+%d*%)%s*<%d+hp") then return true end
    if t:match("^<%d+hp") then return true end
    return false
end

local function _isNoiseLine(line)
    line = tostring(line or "")
    local t = _trim(line)
    if t == "" then return true end
    if t:lower() == "who" then return true end
    if _isLikelyPromptLine(t) then return true end
    if t:match("^%[DWKit") then return true end
    if t:match("^%[dwverify") then return true end
    return false
end

local function _normalizeCapturedLine(line)
    line = tostring(line or ""):gsub("\r", "")
    local t = _trim(line)

    -- If footer line has trailing text, keep only the canonical footer sentence.
    if t:lower():match("^%d+%s+characters%s+displayed") then
        local foot = t:match("^(%d+%s+characters%s+displayed%.?)")
        if foot and foot ~= "" then
            return foot
        end
    end

    return line
end

local function _extractWhoFromText(text)
    text = tostring(text or "")
    text = text:gsub("\r", "")

    local rawLines = {}
    for line in text:gmatch("([^\n]+)") do
        rawLines[#rawLines + 1] = tostring(line or "")
    end

    local started = false
    local captured = {}
    local foundHeader = false
    local foundFooter = false

    for i = 1, #rawLines do
        local line = rawLines[i]
        local t = _trim(line)

        if not started then
            if t == "Players" or t:match("^Total players:") then
                started = true
                foundHeader = true
                captured[#captured + 1] = t
            end
        else
            captured[#captured + 1] = line
            if _looksLikeWhoFooter(line) then
                foundFooter = true
                break
            end
        end
    end

    if foundHeader then
        return table.concat(captured, "\n"), {
            rawLineCount = #rawLines,
            keptLineCount = #captured,
            mode = foundFooter and "header+footer" or "headerOnly",
        }
    end

    captured = {}
    for i = 1, #rawLines do
        local line = rawLines[i]
        local t = _trim(line)
        if t:sub(1, 1) == "[" then
            captured[#captured + 1] = line
        end
        if _looksLikeWhoFooter(line) then
            foundFooter = true
            break
        end
    end

    return table.concat(captured, "\n"), {
        rawLineCount = #rawLines,
        keptLineCount = #captured,
        mode = foundFooter and "entries+footer" or "entriesOnly",
    }
end

local function _finalize(C, ok, reason, svc, meta)
    meta = (type(meta) == "table") and meta or {}
    local verbose = (meta.verbose == true)
    local source = tostring(meta.source or "dwwho:auto")

    local lines = CAP.lines or {}
    _reset(C)

    if not ok then
        -- timeout/abort
        if verbose then
            GUARD.lastOk = false
            GUARD.lastErr = tostring(reason or "unknown")
            C.out("[DWKit Who] capture FAILED reason=" .. tostring(reason or "unknown"))
        end
        return
    end

    if type(svc) ~= "table" then
        if verbose then
            GUARD.lastOk = false
            GUARD.lastErr = "WhoStoreService not available"
            C.out("[DWKit Who] capture FAILED: WhoStoreService not available")
        end
        return
    end

    local text = table.concat(lines, "\n")
    local okIngest, err = _ingestTextBestEffort(C, svc, text, { source = source })

    if okIngest then
        if verbose then
            GUARD.lastOk = true
            GUARD.lastOkTs = os.time()
            GUARD.lastErr = nil
            C.out("[DWKit Who] capture OK source=" .. source .. " lines=" .. tostring(#lines))
            _printStatusBestEffort(C, svc)
        end
        -- watcher mode stays quiet on success
        return
    end

    if verbose then
        GUARD.lastOk = false
        GUARD.lastErr = tostring(err or "ingest failed")
        C.out("[DWKit Who] capture ingest FAILED err=" .. tostring(err))
    else
        -- quiet mode: record error for watch status, but do not spam
        WATCH.lastErr = tostring(err or "ingest failed")
    end
end

local function _shouldSkipRefresh(C)
    if CAP.active == true then
        GUARD.lastSkipReason = "inflight"
        C.out("[DWKit Who] refresh skipped (capture already running)")
        return true
    end

    local now = os.time()

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

-- Start capture session assuming HEADER line already seen and should be included.
local function _beginCaptureWithHeaderLine(svc, headerLine, opts)
    opts = (type(opts) == "table") and opts or {}
    if CAP.active == true then
        return false, "capture inflight"
    end

    -- If refresh expectations are stale, clear them so manual WHO stays quiet.
    _expireExpectationsIfStale()

    local timeoutSec = tonumber(opts.timeoutSec or CAP.expectTimeoutSec or 5) or 5
    if timeoutSec < 2 then timeoutSec = 2 end
    if timeoutSec > 10 then timeoutSec = 10 end

    local source = tostring(opts.source or CAP.expectSource or "dwwho:auto")
    local verbose = (opts.verbose == true) or (CAP.expectVerbose == true)

    -- Build ctx that ALWAYS has killer functions (prevents orphan trigger/timer leak)
    local C = _getCtx({})
    C.killTrigger = _mudletKillTrigger
    C.killTimer = _mudletKillTimer
    if not verbose then
        C.out = _noop
        C.err = _noop
    end

    -- hard dependency: need Mudlet trigger/timer APIs
    if type(tempRegexTrigger) ~= "function" or type(tempTimer) ~= "function" or type(killTrigger) ~= "function" or type(killTimer) ~= "function" then
        WATCH.lastErr = "Mudlet trigger/timer APIs missing (cannot auto-capture)"
        return false, WATCH.lastErr
    end

    CAP.active = true
    CAP.started = true
    CAP.lines = { _trim(tostring(headerLine or "")) }
    CAP.startedAt = os.time()

    CAP.trigAny = tempRegexTrigger([[^(.*)$]], function()
        if not CAP.active then return end
        local line = (matches and matches[2]) and tostring(matches[2]) or ""
        line = _normalizeCapturedLine(line)

        if _isNoiseLine(line) then
            return
        end

        CAP.lines[#CAP.lines + 1] = line

        if _looksLikeWhoFooter(line) then
            _finalize(C, true, nil, svc, { source = source, verbose = verbose })
        end
    end)

    CAP.timer = tempTimer(timeoutSec, function()
        if not CAP.active then return end
        _finalize(C, false, "timeout(" .. tostring(timeoutSec) .. "s)", svc, { source = source, verbose = verbose })
    end)

    -- consume expectations once capture begins
    _clearExpectations()

    return true, nil
end

-- Kill orphaned watcher triggers from older module instances (singleton enforcement)
local function _singletonKillOrphans()
    if type(_G) ~= "table" then return end
    local g = _G[WATCH_SINGLETON_KEY]
    if type(g) ~= "table" then return end

    local tp = g.trigPlayers
    local tt = g.trigTotal

    if tp then _mudletKillTrigger(tp) end
    if tt then _mudletKillTrigger(tt) end

    _G[WATCH_SINGLETON_KEY] = nil
end

local function _singletonRecord(trigPlayers, trigTotal)
    if type(_G) ~= "table" then return end
    _G[WATCH_SINGLETON_KEY] = {
        installedBy = tostring(M.VERSION or "?"),
        installedAtTs = os.time(),
        trigPlayers = trigPlayers,
        trigTotal = trigTotal,
    }
end

-- Install/Uninstall watcher triggers
local function _watchEnable()
    if WATCH.enabled == true then
        return true, nil
    end

    if type(tempRegexTrigger) ~= "function" or type(killTrigger) ~= "function" or type(tempTimer) ~= "function" or type(killTimer) ~= "function" then
        WATCH.lastErr = "Mudlet trigger/timer APIs missing (cannot enable watcher)"
        return false, WATCH.lastErr
    end

    -- SINGLETON: kill any orphan triggers left behind by older module instances
    _singletonKillOrphans()

    -- Resolve service now; if it fails later, we'll attempt again on header.
    local okSvc, svc = _safeRequire("dwkit.services.whostore_service")
    if not okSvc or type(svc) ~= "table" then
        -- still enable watcher; it will try require() again on capture start
        svc = nil
    end

    -- Open the service gate for dwwho:auto ingests
    if type(svc) == "table" then
        _callBestEffort(_getCtx({}), svc, "setAutoCaptureEnabled", true, { source = "cmd:dwwho:watch:on" })
    end

    WATCH.enabled = true
    WATCH.lastErr = nil

    WATCH.trigPlayers = tempRegexTrigger([[^Players$]], function()
        if CAP.active == true then return end
        local ok2, svc2 = _safeRequire("dwkit.services.whostore_service")
        svc2 = (ok2 and type(svc2) == "table") and svc2 or svc
        if type(svc2) ~= "table" then
            WATCH.lastErr = "WhoStoreService not available (auto-capture skipped)"
            return
        end
        -- IMPORTANT: do NOT override CAP.expectSource / CAP.expectVerbose (refresh sets these)
        _beginCaptureWithHeaderLine(svc2, "Players", {})
    end)

    WATCH.trigTotal = tempRegexTrigger([[^Total players:.*$]], function()
        if CAP.active == true then return end
        local line = (matches and matches[1]) and tostring(matches[1]) or "Total players:"
        local ok2, svc2 = _safeRequire("dwkit.services.whostore_service")
        svc2 = (ok2 and type(svc2) == "table") and svc2 or svc
        if type(svc2) ~= "table" then
            WATCH.lastErr = "WhoStoreService not available (auto-capture skipped)"
            return
        end
        -- IMPORTANT: do NOT override CAP.expectSource / CAP.expectVerbose (refresh sets these)
        _beginCaptureWithHeaderLine(svc2, line, {})
    end)

    if not WATCH.trigPlayers or not WATCH.trigTotal then
        WATCH.lastErr = "failed to install watcher triggers"
        return false, WATCH.lastErr
    end

    -- Record singleton ownership so future reloads can kill these triggers
    _singletonRecord(WATCH.trigPlayers, WATCH.trigTotal)

    return true, nil
end

local function _watchDisable()
    -- Close the service gate so orphan triggers can't update snapshot
    local okSvc, svc = _safeRequire("dwkit.services.whostore_service")
    if okSvc and type(svc) == "table" then
        _callBestEffort(_getCtx({}), svc, "setAutoCaptureEnabled", false, { source = "cmd:dwwho:watch:off" })
    end

    if WATCH.trigPlayers then _mudletKillTrigger(WATCH.trigPlayers) end
    if WATCH.trigTotal then _mudletKillTrigger(WATCH.trigTotal) end
    WATCH.trigPlayers = nil
    WATCH.trigTotal = nil
    WATCH.enabled = false

    -- clear global singleton record (if it points at our triggers or any record exists)
    if type(_G) == "table" and type(_G[WATCH_SINGLETON_KEY]) == "table" then
        _G[WATCH_SINGLETON_KEY] = nil
    end

    return true, nil
end

-- Auto-enable watcher when running inside Mudlet (best-effort, silent)
local function _autoEnableWatcherBestEffort()
    if WATCH.enabled == true then return end
    if type(tempRegexTrigger) ~= "function" or type(tempTimer) ~= "function" then
        return
    end
    _watchEnable()
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

    -- If watcher is enabled, reuse it: set expectations and just send "who"
    if WATCH.enabled == true then
        GUARD.lastAttemptTs = os.time()
        GUARD.lastSkipReason = nil
        GUARD.lastErr = nil

        CAP.expectSource = "dwwho:refresh"
        CAP.expectVerbose = true
        CAP.expectTimeoutSec = timeoutSec
        CAP.expectSetTs = os.time()

        C.out("[DWKit Who] refresh: sending 'who' (watcher will capture output)...")
        pcall(sendFn, "who")
        return
    end

    -- Fallback (legacy): install per-refresh capture triggers
    if type(C.tempRegexTrigger) ~= "function" or type(C.tempTimer) ~= "function" then
        GUARD.lastOk = false
        GUARD.lastErr = "tempRegexTrigger/tempTimer ctx helpers missing"
        C.out("[DWKit Who] refresh FAILED: tempRegexTrigger/tempTimer ctx helpers missing")
        return
    end

    GUARD.lastAttemptTs = os.time()
    GUARD.lastSkipReason = nil
    GUARD.lastErr = nil

    CAP.active = true
    CAP.started = false
    CAP.lines = {}
    CAP.startedAt = GUARD.lastAttemptTs

    CAP.trigAny = C.tempRegexTrigger([[^(.*)$]], function()
        if not CAP.active then return end
        local line = (matches and matches[2]) and tostring(matches[2]) or ""
        line = _normalizeCapturedLine(line)

        if _isNoiseLine(line) then
            return
        end

        if not CAP.started then
            local t = _trim(line)
            if t == "Players" or t:match("^Total players:") then
                CAP.started = true
            else
                return
            end
        end

        CAP.lines[#CAP.lines + 1] = line

        if _looksLikeWhoFooter(line) then
            _finalize(C, true, nil, svc, { source = "dwwho:refresh", verbose = true })
        end
    end)

    CAP.timer = C.tempTimer(timeoutSec, function()
        if not CAP.active then return end
        _finalize(C, false, "timeout(" .. tostring(timeoutSec) .. "s)", svc, { source = "dwwho:refresh", verbose = true })
    end)

    C.out("[DWKit Who] refresh: sending 'who' + capturing output...")
    pcall(sendFn, "who")
end

-- Parse "sub" into: verb + rest
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

    if rest == "" then
        return arg
    end

    return rest .. " " .. arg
end

local function _splitNamesCSV(rest)
    rest = _trim(tostring(rest or ""))
    if rest == "" then return {} end

    rest = rest:gsub("%s+", " ")

    local names = {}

    if rest:find(",", 1, true) then
        for part in rest:gmatch("([^,]+)") do
            local n = _trim(part)
            if n ~= "" then
                names[#names + 1] = n
            end
        end
        return names
    end

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

local function _buildFixtureWhoText(names)
    names = (type(names) == "table") and names or {}
    local lines = {}
    lines[#lines + 1] = "Players"
    lines[#lines + 1] = "-------"
    for i = 1, #names do
        local n = tostring(names[i] or "")
        if n ~= "" then
            lines[#lines + 1] = "[50 War] " .. n
        end
    end
    lines[#lines + 1] = tostring(#names) .. " characters displayed."
    return table.concat(lines, "\n")
end

local function _fixtureText(which)
    which = tostring(which or "basic"):lower()

    if which == "" or which == "basic" then
        local txt = _buildFixtureWhoText({ "Zeq", "Vzae", "Xi", "Scynox" })
        return txt, "basic"
    end

    if which == "party" then
        local txt = _buildFixtureWhoText({
            "Zeq", "Vzae", "Xi", "Scynox", "Borai", "Merec", "Kiyomi", "Ragna", "Eymel", "Hnin",
        })
        return txt, "party"
    end

    local txt = _buildFixtureWhoText({ "Zeq", "Vzae", "Xi", "Scynox" })
    return txt, "basic"
end

local function _dispatchCore(ctx, svc, sub, arg)
    local C = _getCtx(ctx)

    if type(C.out) ~= "function" or type(C.err) ~= "function" then
        return
    end

    local verb, rest = _parseVerb(sub)
    rest = _mergeRestWithArg(rest, arg)

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

    if verb == "watch" then
        local v2, r2 = _parseVerb(rest)
        if v2 == "" or v2 == "status" then
            _printWatchStatus(C)
            return
        end
        if v2 == "on" or v2 == "enable" then
            local ok, err = _watchEnable()
            if ok then
                C.out("[DWKit Who] watcher enabled (auto-captures manual 'who')")
            else
                C.err("watcher enable failed: " .. tostring(err))
            end
            _printWatchStatus(C)
            return
        end
        if v2 == "off" or v2 == "disable" then
            _watchDisable()
            C.out("[DWKit Who] watcher disabled")
            _printWatchStatus(C)
            return
        end
        C.err("watch usage: dwwho watch [status|on|off]")
        return
    end

    if verb == "ingestclip" then
        local text = (type(C.getClipboardText) == "function") and C.getClipboardText() or nil
        if type(text) ~= "string" or text:gsub("%s+", "") == "" then
            C.err("clipboard is empty (copy WHO output first).")
            return
        end

        local extracted, info = _extractWhoFromText(text)
        extracted = tostring(extracted or "")
        info = (type(info) == "table") and info or {}

        if extracted:gsub("%s+", "") == "" then
            C.err("clipboard does not appear to contain WHO lines (no entries found).")
            C.out("[DWKit Who] ingestclip note: copy from 'Players' down to 'X characters displayed.'")
            return
        end

        local beforeN = _getPlayersCountBestEffort(svc)
        local okIngest, err = _ingestTextBestEffort(C, svc, extracted, { source = "dwwho:clipboard" })
        if not okIngest then
            C.err("ingestclip failed: " .. tostring(err))
            return
        end

        local afterN = _getPlayersCountBestEffort(svc)

        if afterN == 0 then
            C.out("[DWKit Who] ingestclip WARNING: parsed 0 entries from clipboard")
            C.out("  hint: clipboard likely includes prompt/noise before '['. Re-copy WHO block.")
            C.out("  extractMode=" .. tostring(info.mode or "unknown")
                .. " rawLines=" .. tostring(info.rawLineCount or "?")
                .. " keptLines=" .. tostring(info.keptLineCount or "?"))
            _printStatusBestEffort(C, svc)
            return
        end

        if beforeN ~= nil and afterN ~= nil and beforeN == afterN then
            C.out("[DWKit Who] ingestclip OK (no change) players=" .. tostring(afterN))
        else
            C.out("[DWKit Who] ingestclip OK players=" .. tostring(afterN))
        end

        _printStatusBestEffort(C, svc)
        return
    end

    if verb == "fixture" then
        local fixtureName = _trim(rest)
        local fixture, which = _fixtureText(fixtureName)

        local okIngest, err = _ingestTextBestEffort(C, svc, fixture, { source = "dwwho:fixture:" .. tostring(which) })
        if not okIngest then
            C.err("fixture ingest failed: " .. tostring(err))
            return
        end

        local afterN = _getPlayersCountBestEffort(svc)
        if afterN == 0 then
            C.out("[DWKit Who] fixture WARNING: parsed 0 entries name=" .. tostring(which))
            _printStatusBestEffort(C, svc)
            return
        end

        C.out("[DWKit Who] fixture OK name=" .. tostring(which))
        _printStatusBestEffort(C, svc)
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

-- Best-effort: enable watcher automatically when running inside Mudlet
_autoEnableWatcherBestEffort()

return M

-- END FILE: src/dwkit/commands/dwwho.lua
