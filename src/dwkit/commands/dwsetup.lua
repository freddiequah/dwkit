-- #########################################################################
-- Module Name : dwkit.commands.dwsetup
-- Owner       : Commands
-- Version     : v2026-02-27B
-- Purpose     :
--   - Handler for "dwsetup" onboarding/bootstrap checklist for a fresh Mudlet profile.
--   - SAFE: visible, one-shot, self-terminating (manual batch sequence).
--   - DOES:
--       - Print identity/version pointers (best-effort).
--       - Check owned_profiles mapping status; if empty, print explicit next actions (no guessing).
--       - Check WhoStore status (players count, lastUpdatedTs, source, autoCaptureEnabled, persistence diag when available).
--       - Optionally run ONE who refresh via existing dwwho refresh (approved pathway).
--       - Instruct user to type "look" once (passive capture; dwsetup does NOT send look).
--       - Best-effort trigger Presence + RoomEntities refresh emissions so UIs re-render.
--       - Option B improvement: after dwwho refresh, do a one-shot delayed re-check so output reflects
--         the async watcher capture result (no persistent timers; self-terminating).
--   - DOES NOT:
--       - Start/enable polling jobs.
--       - Persist any config or mapping.
--       - Guess profile roster or seed owned_profiles automatically.
--       - Send gameplay commands directly (except via dwwho refresh when invoked in default run).
--
-- Public API  :
--   - dispatch(ctx, kit, tokens)
--
-- Events Emitted   : None (directly). May call services that emit their own updated events.
-- Events Consumed  : None
-- Persistence      : None
-- Automation Policy: Manual only
-- Dependencies     :
--   - dwkit.config.owned_profiles
--   - dwkit.services.whostore_service
--   - dwkit.bus.command_router (optional, best-effort)
--   - dwkit.services.presence_service (best-effort refresh)
--   - dwkit.services.roomentities_service (best-effort refresh)
-- #########################################################################

local M = {}
M.VERSION = "v2026-02-27B"

-- One-shot timer id (to avoid duplicate delayed prints if dwsetup run repeatedly quickly)
local _POST_REFRESH_TIMER_ID = nil

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
    _fallbackOut("[DWKit Setup] ERROR: " .. tostring(msg))
end

local function _trim(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function _safeRequire(modName)
    local ok, mod = pcall(require, modName)
    if ok and type(mod) == "table" then return true, mod, nil end
    return false, nil, tostring(mod)
end

local function _getKit(kit)
    if type(kit) == "table" then return kit end
    if type(_G) == "table" and type(_G.DWKit) == "table" then return _G.DWKit end
    if type(DWKit) == "table" then return DWKit end
    return nil
end

local function _getCtx(ctx)
    ctx = (type(ctx) == "table") and ctx or {}
    return {
        out = (type(ctx.out) == "function") and ctx.out or _fallbackOut,
        err = (type(ctx.err) == "function") and ctx.err or _fallbackErr,
        safeRequire = (type(ctx.safeRequire) == "function") and ctx.safeRequire or _safeRequire,
        callBestEffort = (type(ctx.callBestEffort) == "function") and ctx.callBestEffort or nil,
        getKit = (type(ctx.getKit) == "function") and ctx.getKit or nil,
        getService = (type(ctx.getService) == "function") and ctx.getService or nil,
    }
end

local function _parseTokens(tokens)
    tokens = (type(tokens) == "table") and tokens or {}
    local sub = tostring(tokens[2] or "")
    sub = _trim(sub):lower()
    return sub
end

local function _usage(C)
    C.out("[DWKit Setup] Usage:")
    C.out("  dwsetup")
    C.out("  dwsetup status")
    C.out("  dwsetup help")
    C.out("")
    C.out("What it does (dwsetup):")
    C.out("  - Prints checklist (owned_profiles + WhoStore).")
    C.out("  - Runs ONE who refresh via: dwwho refresh (approved path).")
    C.out("  - Asks you to type: look  (dwsetup does NOT send look).")
    C.out("  - Triggers best-effort Presence/RoomEntities refresh emissions so UIs re-render.")
    C.out("  - After refresh: waits briefly and re-checks WhoStore once (handles async capture).")
    C.out("")
    C.out("What it does NOT do:")
    C.out("  - No hidden automation, no polling/timers.")
    C.out("  - Does not guess or auto-seed owned_profiles.")
    C.out("  - Does not persist any mapping/config.")
end

local function _printHeader(C, kit)
    C.out("==================================================")
    C.out("[DWKit Setup] dwsetup (manual bootstrap checklist)")
    C.out("  moduleVersion=" .. tostring(M.VERSION))
    local K = _getKit(kit)
    if type(K) == "table" then
        if type(K.identity) == "table" and type(K.identity.get) == "function" then
            local ok, id = pcall(K.identity.get)
            if ok and type(id) == "table" then
                C.out("  identity.packageId=" .. tostring(id.packageId or "nil"))
                C.out("  identity.eventPrefix=" .. tostring(id.eventPrefix or "nil"))
                C.out("  identity.dataFolder=" .. tostring(id.dataFolderName or "nil"))
                C.out("  identity.tagStyle=" .. tostring(id.versionTagStyle or "nil"))
            end
        end
        if type(K.VERSION) == "string" and K.VERSION ~= "" then
            C.out("  kit.VERSION=" .. tostring(K.VERSION))
        end
    end
    C.out("==================================================")
end

local function _ownedProfilesStatus(C)
    local okO, O, errO = C.safeRequire("dwkit.config.owned_profiles")
    if not okO or type(O) ~= "table" then
        C.err("owned_profiles not available: " .. tostring(errO))
        return {
            ok = false,
            count = 0,
            loaded = false,
        }
    end

    if type(O.status) ~= "function" then
        C.err("owned_profiles.status() missing")
        return {
            ok = false,
            count = 0,
            loaded = false,
        }
    end

    local okS, st = pcall(O.status)
    if not okS or type(st) ~= "table" then
        C.err("owned_profiles.status() failed")
        return {
            ok = false,
            count = 0,
            loaded = false,
        }
    end

    C.out("[DWKit Setup] owned_profiles")
    C.out("  loaded=" .. tostring(st.loaded))
    C.out("  count=" .. tostring(st.count))
    C.out("  relPath=" .. tostring(st.relPath or "nil"))
    C.out("  lastError=" .. tostring(st.lastError or "nil"))

    local count = tonumber(st.count or 0) or 0

    if count <= 0 then
        C.out("[DWKit Setup] owned_profiles is EMPTY (MISSING)")
        C.out("  Next action (example, explicit):")
        C.out(
            '  lua do local O=require("dwkit.config.owned_profiles"); local ok,err=O.setMap({["YourCharName"]="YourProfileLabel"},{noSave=false}); print(string.format("[dwsetup] owned_profiles setMap ok=%s err=%s", tostring(ok==true), tostring(err))) end')
        C.out("  Notes:")
        C.out("  - Left side is character name (as seen in room/who).")
        C.out("  - Right side is your Mudlet profile label used by CPC for local-online truth.")
        C.out("  - Replace values explicitly; DWKit will not guess them for you.")
    end

    return {
        ok = true,
        count = count,
        loaded = (st.loaded == true),
    }
end

local function _getWhoStoreService(C, kit)
    if type(C.getService) == "function" then
        local s = C.getService("whoStoreService")
        if type(s) == "table" then return s end
    end

    local K = _getKit(kit)
    if type(K) == "table" and type(K.services) == "table" and type(K.services.whoStoreService) == "table" then
        return K.services.whoStoreService
    end

    local okW, W = C.safeRequire("dwkit.services.whostore_service")
    if okW and type(W) == "table" then return W end

    return nil
end

local function _printWhoStoreStatus(C, svc)
    if type(svc) ~= "table" or type(svc.getState) ~= "function" then
        C.err("WhoStoreService not available (cannot print status)")
        return {
            ok = false,
            playersCount = 0,
            lastUpdatedTs = nil,
        }
    end

    local okS, st = pcall(svc.getState)
    if not okS or type(st) ~= "table" then
        C.err("WhoStoreService.getState failed")
        return {
            ok = false,
            playersCount = 0,
            lastUpdatedTs = nil,
        }
    end

    local players = (type(st.players) == "table") and st.players or {}
    local n = 0
    for _, v in pairs(players) do
        if v == true then n = n + 1 end
    end

    C.out("[DWKit Setup] WhoStore")
    C.out("  serviceVersion=" .. tostring(st.version or svc.VERSION or "?"))
    C.out("  players=" .. tostring(n))
    C.out("  lastUpdatedTs=" .. tostring(st.lastUpdatedTs or "nil"))
    C.out("  source=" .. tostring(st.source or "nil"))
    C.out("  autoCaptureEnabled=" .. tostring(st.autoCaptureEnabled))

    if type(st.persist) == "table" then
        C.out("[DWKit Setup] WhoStore persist")
        C.out("  enabled=" .. tostring(st.persist.enabled))
        C.out("  path=" .. tostring(st.persist.path or "nil"))
        C.out("  lastLoadErr=" .. tostring(st.persist.lastLoadErr or "nil"))
        C.out("  lastSaveErr=" .. tostring(st.persist.lastSaveErr or "nil"))
    end

    return {
        ok = true,
        playersCount = n,
        lastUpdatedTs = st.lastUpdatedTs,
        source = st.source,
        autoCaptureEnabled = st.autoCaptureEnabled,
    }
end

local function _runWhoRefreshBestEffort(C, kit)
    C.out("[DWKit Setup] Step: dwwho refresh (ONE who send via approved path)")

    local okR, Router = C.safeRequire("dwkit.bus.command_router")
    if okR and type(Router) == "table" and type(Router.dispatchGenericCommand) == "function" then
        local okCall, err = pcall(Router.dispatchGenericCommand, C, kit, "dwwho", { "dwwho", "refresh" })
        if okCall then
            return true, nil
        end
        return false, tostring(err)
    end

    local okW, W = C.safeRequire("dwkit.commands.dwwho")
    if okW and type(W) == "table" and type(W.dispatch) == "function" then
        local okCall, err = pcall(W.dispatch, C, kit, { "dwwho", "refresh" })
        if okCall and err ~= false then
            return true, nil
        end
        return false, tostring(err)
    end

    return false, "No router and cannot require dwkit.commands.dwwho"
end

local function _triggerUiRefreshBestEffort(C)
    C.out("[DWKit Setup] Step: trigger Presence/RoomEntities refresh (best-effort, SAFE)")

    do
        local okP, P = C.safeRequire("dwkit.services.presence_service")
        if okP and type(P) == "table" and type(P.update) == "function" then
            local okCall, a, b = pcall(P.update, {}, { source = "dwsetup" })
            if okCall and a ~= false then
                C.out("  presence_service.update OK")
            else
                C.out("  presence_service.update FAILED err=" .. tostring(b or a))
            end
        else
            C.out("  presence_service not available (skip)")
        end
    end

    do
        local okR, R = C.safeRequire("dwkit.services.roomentities_service")
        if okR and type(R) == "table" and type(R.emitUpdated) == "function" then
            local okCall, err = pcall(R.emitUpdated, { source = "dwsetup" })
            if okCall and err ~= false then
                C.out("  roomentities_service.emitUpdated OK")
            else
                C.out("  roomentities_service.emitUpdated FAILED err=" .. tostring(err))
            end
        else
            C.out("  roomentities_service not available (skip)")
        end
    end
end

local function _printSummary(C, owned, who)
    owned = (type(owned) == "table") and owned or { ok = false, count = 0 }
    who = (type(who) == "table") and who or { ok = false, playersCount = 0, lastUpdatedTs = nil }

    local missing = {}

    if owned.ok ~= true or (tonumber(owned.count or 0) or 0) <= 0 then
        missing[#missing + 1] = "owned_profiles mapping (required for Presence 'My profiles' split)"
    end

    if who.ok ~= true or (tonumber(who.playersCount or 0) or 0) <= 0 then
        missing[#missing + 1] = "WhoStore snapshot (run dwwho refresh or type who manually)"
    end

    C.out("--------------------------------------------------")
    if #missing == 0 then
        C.out("[DWKit Setup] READY: baseline prerequisites present.")
    else
        C.out("[DWKit Setup] MISSING: prerequisites not complete.")
        for i = 1, #missing do
            C.out("  - " .. tostring(missing[i]))
        end
    end
    C.out("")
    C.out("[DWKit Setup] Next actions (manual, explicit):")
    C.out("  1) If owned_profiles was empty: set it (see printed example).")
    C.out("  2) Type: look   (required once so RoomFeed/RoomEntities passive capture ingests room snapshot)")
    C.out("  3) Optional: run dwverify ui_smoke to confirm UIs apply cleanly.")
    C.out("--------------------------------------------------")
end

local function _runStatus(C, kit)
    _printHeader(C, kit)

    local owned = _ownedProfilesStatus(C)

    local svc = _getWhoStoreService(C, kit)
    local who = _printWhoStoreStatus(C, svc)

    _printSummary(C, owned, who)

    return owned, who
end

local function _killPostRefreshTimerBestEffort()
    if _POST_REFRESH_TIMER_ID == nil then return end
    if type(killTimer) == "function" then
        pcall(killTimer, _POST_REFRESH_TIMER_ID)
    end
    _POST_REFRESH_TIMER_ID = nil
end

local function _schedulePostRefreshRecheck(C, kit, owned, delaySec)
    delaySec = tonumber(delaySec or 0.60) or 0.60
    if delaySec < 0.10 then delaySec = 0.10 end
    if delaySec > 2.00 then delaySec = 2.00 end

    if type(tempTimer) ~= "function" then
        C.out("[DWKit Setup] Note: tempTimer not available; cannot do delayed WhoStore re-check.")
        return false
    end

    _killPostRefreshTimerBestEffort()

    C.out(string.format("[DWKit Setup] Waiting %.2fs for WhoStore capture to finalize (one-shot)...", delaySec))

    _POST_REFRESH_TIMER_ID = tempTimer(delaySec, function()
        _POST_REFRESH_TIMER_ID = nil
        local okRun, errRun = pcall(function()
            local svc = _getWhoStoreService(C, kit)
            local who = _printWhoStoreStatus(C, svc)

            C.out("[DWKit Setup] Step: you must now type: look")
            C.out("  (dwsetup does NOT send look; RoomFeed capture is passive)")

            _triggerUiRefreshBestEffort(C)
            _printSummary(C, owned, who)
        end)
        if not okRun then
            C.err("post-refresh recheck failed: " .. tostring(errRun))
        end
    end)

    return true
end

local function _runFull(C, kit)
    local owned, _ = _runStatus(C, kit)

    local okRefresh, errRefresh = _runWhoRefreshBestEffort(C, kit)
    if not okRefresh then
        C.out("[DWKit Setup] dwwho refresh FAILED err=" .. tostring(errRefresh))

        -- If refresh fails, proceed immediately with current state (no delayed recheck).
        local svcFail = _getWhoStoreService(C, kit)
        local whoFail = _printWhoStoreStatus(C, svcFail)

        C.out("[DWKit Setup] Step: you must now type: look")
        C.out("  (dwsetup does NOT send look; RoomFeed capture is passive)")

        _triggerUiRefreshBestEffort(C)
        _printSummary(C, owned, whoFail)

        return true
    end

    -- Option B: one-shot delayed re-check so WhoStore status reflects async watcher capture result.
    -- We do NOT print WhoStore immediately here (avoids race showing stale persist:load snapshot).
    if _schedulePostRefreshRecheck(C, kit, owned, 0.60) then
        return true
    end

    -- Fallback if timer APIs unavailable: print immediate snapshot + reminder that capture is async.
    C.out("[DWKit Setup] Note: WhoStore capture is async; if snapshot looks stale, run: dwwho status")
    local svc = _getWhoStoreService(C, kit)
    local who = _printWhoStoreStatus(C, svc)

    C.out("[DWKit Setup] Step: you must now type: look")
    C.out("  (dwsetup does NOT send look; RoomFeed capture is passive)")

    _triggerUiRefreshBestEffort(C)
    _printSummary(C, owned, who)

    return true
end

-- Dispatch compatibility:
--   - dispatch(ctx, kit, tokens)
--   - dispatch(tokens)
--   - dispatch(ctx, tokens)
--   - dispatch(ctx, kit)
function M.dispatch(ctx, a, b)
    local C = _getCtx(ctx)

    local kit, tokens

    if type(a) == "table" and type(b) == "table" then
        kit = a
        tokens = b
    elseif type(a) == "table" and type(b) ~= "table" then
        kit = a
        tokens = {}
    elseif type(a) == "table" and type(a[1]) == "string" then
        kit = _getKit(nil)
        tokens = a
    else
        kit = _getKit(nil)
        tokens = {}
    end

    local sub = _parseTokens(tokens)

    if sub == "" then
        return _runFull(C, kit)
    end

    if sub == "status" then
        _runStatus(C, kit)
        return true
    end

    if sub == "help" or sub == "h" or sub == "?" then
        _usage(C)
        return true
    end

    C.err("Unknown subcommand: " .. tostring(sub))
    _usage(C)
    return true
end

return M
