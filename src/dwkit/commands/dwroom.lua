-- FILE: src/dwkit/commands/dwroom.lua
-- #########################################################################
-- Module Name : dwkit.commands.dwroom
-- Owner       : Commands
-- Version     : v2026-01-27B
-- Purpose     :
--   - Command handler for "dwroom" alias (SAFE manual surface).
--   - Implements RoomEntities SAFE inspection + helpers:
--       * dwroom                -> status
--       * dwroom status         -> status
--       * dwroom clear          -> clear snapshot (service-defined)
--       * dwroom ingestclip     -> ingest look-like text from clipboard (SAFE)
--       * dwroom fixture [name] -> ingest fixture if service supports it (SAFE)
--       * dwroom refresh        -> SAFE refresh (NO gameplay sends)
--
-- IMPORTANT:
--   - MUST remain SAFE: no send(), no sendAll(), no gameplay commands.
--
-- FIX (v2026-01-23A):
--   - event_bus.emit requires meta (3rd arg) to deliver in this environment.
--   - fallback emit now passes meta as 3rd arg.
--   - dwroom fixture now calls ingestFixture(opts) in service-native shape.
--
-- FIX (v2026-01-23B):
--   - refresh now passes a minimal svcOpts table into service refresh/reclassify calls
--     (source only) instead of the richer meta object used for ensure-emits/logging.
--   - fixture now requests forceEmit=true so the deterministic seed always produces
--     an Updated event (useful for UI/pipeline validation).
--
-- FIX (v2026-01-27A):
--   - Added router-compatible dispatch signature:
--       dispatch(ctx, kit, tokens)
--     so command_router.dispatchGenericCommand can call split modules directly.
--
-- FIX (v2026-01-27B) [StepB/B3]:
--   - dwroom no longer depends on ctx.printRoomEntitiesStatus injection.
--   - Status now prints full counts using svc.getState() (best-effort).
--
-- Public API  :
--   - dispatch(ctx, roomEntitiesService, sub, arg) -> nil
--   - dispatch(ctx, kit, tokens)                  -> nil
--   - reset() -> nil
-- #########################################################################

local M = {}

M.VERSION = "v2026-01-27B"

local function _mkOut(ctx)
    if type(ctx) == "table" and type(ctx.out) == "function" then
        return ctx.out
    end
    return function(line) print(tostring(line or "")) end
end

local function _mkErr(ctx)
    if type(ctx) == "table" and type(ctx.err) == "function" then
        return ctx.err
    end
    return function(msg) print("[DWKit Room] ERROR: " .. tostring(msg or "")) end
end

local function _safeRequire(name)
    local ok, mod = pcall(require, name)
    if ok then return true, mod end
    return false, mod
end

local function _call(ctx, obj, fnName, ...)
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

local function _usage(out)
    out("[DWKit Room] Usage:")
    out("  dwroom")
    out("  dwroom status")
    out("  dwroom ui on|off|toggle")
    out("  dwroom ui status")
    out("  dwroom clear")
    out("  dwroom ingestclip")
    out("  dwroom fixture [name]")
    out("  dwroom refresh")
    out("")
    out("Notes:")
    out("  - SAFE only: does NOT send any gameplay commands.")
    out("  - refresh best-effort: reclassify/emitUpdated or eventBus.emit if available.")
end

local function _roomCountsFromState(state)
    state = (type(state) == "table") and state or {}
    local function cnt(t)
        if type(t) ~= "table" then return 0 end
        local n = 0
        for _ in pairs(t) do n = n + 1 end
        return n
    end
    return {
        players = cnt(state.players),
        mobs = cnt(state.mobs),
        items = cnt(state.items),
        unknown = cnt(state.unknown),
    }
end

local function _printStatus(ctx, svc)
    local out = _mkOut(ctx)
    local err = _mkErr(ctx)

    local function _looksLikeSvc(s)
        return type(s) == "table" and (
            type(s.getState) == "function" or
            type(s.ingestLookText) == "function" or
            type(s.reclassifyFromWhoStore) == "function" or
            s.VERSION ~= nil
        )
    end

    local loadErr = nil
    if not _looksLikeSvc(svc) then
        local ok, modOrErr = pcall(require, "dwkit.services.roomentities_service")
        if ok and _looksLikeSvc(modOrErr) then
            svc = modOrErr
        else
            loadErr = modOrErr
        end
    end

    local state = {}
    if type(svc) == "table" and type(svc.getState) == "function" then
        local ok, v, _, _, callErr = _call(ctx, svc, "getState")
        if ok and type(v) == "table" then
            state = v
        elseif callErr then
            out("[DWKit Room] getState failed: " .. tostring(callErr))
        end
    end

    local c = _roomCountsFromState(state)

    out("[DWKit Room] status (dwroom)")
    out("  serviceVersion=" .. tostring((type(svc) == "table" and svc.VERSION) or "unknown"))
    if loadErr ~= nil then
        out("  serviceLoadErr=" .. tostring(loadErr))
    elseif type(svc) ~= "table" then
        err("RoomEntitiesService not available.")
    end
    out("  players=" .. tostring(c.players))
    out("  mobs=" .. tostring(c.mobs))
    out("  items=" .. tostring(c.items))
    out("  unknown=" .. tostring(c.unknown))
end

local function _doClear(ctx, svc)
    local out = _mkOut(ctx)
    local err = _mkErr(ctx)

    if type(svc) ~= "table" then
        err("RoomEntitiesService not available.")
        return
    end

    if type(svc.clear) ~= "function" then
        err("RoomEntitiesService.clear not available.")
        return
    end

    local ok, a, b, c, callErr = _call(ctx, svc, "clear", { source = "cmd:dwroom:clear" })
    if not ok or a == false then
        err("clear failed: " .. tostring(b or c or callErr or "unknown"))
        return
    end

    out("[DWKit Room] clear OK")
    _printStatus(ctx, svc)
end

local function _doIngestClip(ctx, svc)
    local out = _mkOut(ctx)
    local err = _mkErr(ctx)

    if type(svc) ~= "table" then
        err("RoomEntitiesService not available.")
        return
    end

    if type(svc.ingestLookText) ~= "function" then
        err("RoomEntitiesService.ingestLookText not available.")
        return
    end

    local clip = nil
    if type(ctx) == "table" and type(ctx.getClipboardText) == "function" then
        clip = ctx.getClipboardText()
    end

    if type(clip) ~= "string" or clip == "" then
        err("Clipboard is empty or clipboard API not available.")
        return
    end

    local ok, a, b, c, callErr = _call(ctx, svc, "ingestLookText", clip, { source = "cmd:dwroom:ingestclip" })
    if not ok or a == false then
        err("ingestclip failed: " .. tostring(b or c or callErr or "unknown"))
        return
    end

    out("[DWKit Room] ingestclip OK")
    _printStatus(ctx, svc)
end

local function _doFixture(ctx, svc, name)
    local out = _mkOut(ctx)
    local err = _mkErr(ctx)

    if type(svc) ~= "table" then
        err("RoomEntitiesService not available.")
        return
    end

    name = tostring(name or "")
    if name == "" then name = "basic" end

    if type(svc.ingestFixture) ~= "function" then
        err("RoomEntitiesService.ingestFixture not available.")
        return
    end

    -- Service-native shape: ingestFixture(opts)
    -- NOTE: forceEmit=true so the deterministic seed always produces an Updated event (UI/pipeline validation).
    local opts = { source = "cmd:dwroom:fixture", name = name, forceEmit = true }

    local ok, a, b, c, callErr = _call(ctx, svc, "ingestFixture", opts)
    if not ok or a == false then
        err("fixture failed: " .. tostring(b or c or callErr or "unknown"))
        return
    end

    out("[DWKit Room] fixture OK name=" .. tostring(name))
    _printStatus(ctx, svc)
end

local function _getEventBusBestEffort()
    if type(_G.DWKit) == "table" and type(_G.DWKit.bus) == "table" and type(_G.DWKit.bus.eventBus) == "table" then
        return _G.DWKit.bus.eventBus
    end
    local ok, mod = _safeRequire("dwkit.bus.event_bus")
    if ok and type(mod) == "table" then
        return mod
    end
    return nil
end

local function _resolveUpdatedEventNameBestEffort(ctx, svc)
    if type(svc) == "table" then
        if type(svc.getUpdatedEventName) == "function" then
            local ok, v = _call(ctx, svc, "getUpdatedEventName")
            if ok and type(v) == "string" and v ~= "" then
                return v
            end
        end
        if type(svc.EV_UPDATED) == "string" and svc.EV_UPDATED ~= "" then
            return svc.EV_UPDATED
        end
    end
    return "DWKit:Service:RoomEntities:Updated"
end

local function _emitUpdatedEnsure(ctx, svc, meta, methodName)
    local out = _mkOut(ctx)

    meta = (type(meta) == "table") and meta or {}
    methodName = tostring(methodName or "unknown")

    meta.method = meta.method or methodName
    meta.note = meta.note or "dwroom refresh ensure emit"

    if type(svc) == "table" and type(svc.emitUpdated) == "function" then
        local ok, a, b, c, callErr = _call(ctx, svc, "emitUpdated", meta)
        if ok and a ~= false then
            out("  emitUpdated=OK (svc.emitUpdated)")
            return true
        end
        out("  emitUpdated=FAILED (svc.emitUpdated) err=" .. tostring(b or c or callErr or "unknown"))
    else
        out("  emitUpdated=SKIP (svc.emitUpdated missing)")
    end

    local eb = _getEventBusBestEffort()
    if type(eb) ~= "table" then
        out("  emitUpdated=SKIP (eventBus not available)")
        return false
    end

    local evName = _resolveUpdatedEventNameBestEffort(ctx, svc)
    local payload = {
        source = meta.source or "cmd:dwroom:refresh",
        method = meta.method or methodName,
        note = meta.note or "fallback eventBus.emit",
        ts = os.time(),
    }

    -- REQUIRED in this environment: emit(eventName, payload, meta)
    local ebMeta = {
        source = tostring(payload.source or "cmd:dwroom:refresh"),
        service = "dwkit.commands.dwroom",
        ts = payload.ts,
        method = tostring(payload.method or ""),
    }

    local ok1, a1, b1, c1, err1 = _call(ctx, eb, "emit", evName, payload, ebMeta)
    if ok1 and a1 ~= false then
        out("  emitUpdated=OK (eventBus.emit fallback)")
        return true
    end

    out("  emitUpdated=FAILED (eventBus.emit fallback) err=" .. tostring(b1 or c1 or err1 or "unknown"))
    return false
end

local function _doRefreshSafe(ctx, svc)
    local out = _mkOut(ctx)
    local err = _mkErr(ctx)

    if type(svc) ~= "table" then
        err("RoomEntitiesService not available.")
        return
    end

    local meta = {
        source = "cmd:dwroom:refresh",
        note = "manual SAFE refresh (dwroom refresh)",
    }

    -- Minimal opts passed into service APIs (avoid leaking meta-only keys into svc calls).
    local svcOpts = { source = meta.source }

    out("[DWKit Room] refresh (SAFE)")
    out("  NOTE: No gameplay sends; best-effort internal refresh/reclassify.")
    out("  NOTE: Will ensure RoomEntities Updated event is emitted (svc.emitUpdated OR eventBus.emit fallback).")

    local tried = {}

    local function tryCall(fnName, ...)
        if tried[fnName] then return false, "skipped (already tried)" end
        tried[fnName] = true

        if type(svc[fnName]) ~= "function" then
            return false, "missing"
        end

        local ok, a, b, c, callErr = _call(ctx, svc, fnName, ...)
        if not ok or a == false then
            return false, tostring(b or c or callErr or "failed")
        end
        return true, nil
    end

    local function success(methodName)
        methodName = tostring(methodName or "unknown")
        meta.method = methodName

        out("  method=" .. tostring(methodName) .. " OK")
        _emitUpdatedEnsure(ctx, svc, meta, methodName)
        _printStatus(ctx, svc)
    end

    do
        local ok = tryCall("reclassifyFromWhoStore", svcOpts)
        if ok then
            success("reclassifyFromWhoStore")
            return
        end
    end

    do
        local ok = tryCall("reclassify", svcOpts)
        if ok then
            success("reclassify")
            return
        end
    end

    do
        local ok = tryCall("reclassifyAll", svcOpts)
        if ok then
            success("reclassifyAll")
            return
        end
    end

    do
        local ok = tryCall("refreshSafe", svcOpts)
        if ok then
            success("refreshSafe")
            return
        end
    end

    do
        local ok = tryCall("refresh", svcOpts)
        if ok then
            success("refresh")
            return
        end
    end

    do
        local ok = tryCall("emitUpdated", meta) -- emitUpdated expects meta shape; keep as-is
        if ok then
            success("emitUpdated")
            return
        end
    end

    err("No SAFE refresh API found on RoomEntitiesService.")
    out("  Expected one of:")
    out("    - reclassifyFromWhoStore(opts)")
    out("    - reclassify(opts) / reclassifyAll(opts)")
    out("    - refreshSafe(opts)")
    out("    - refresh(opts)  (LAST: name is ambiguous)")
    out("    - emitUpdated(meta)")
    out("")
    out("  Tip: run dwroom status to confirm available APIs.")
end

local function _resolveSvcFromKitOrCtx(ctx, kit)
    local function _looksLikeSvc(s)
        return type(s) == "table" and (
            type(s.getState) == "function" or
            type(s.ingestLookText) == "function" or
            type(s.reclassifyFromWhoStore) == "function" or
            s.VERSION ~= nil
        )
    end

    if type(ctx) == "table" and type(ctx.getService) == "function" then
        local s = ctx.getService("roomEntitiesService")
        if _looksLikeSvc(s) then return s end
    end

    if type(kit) == "table" and type(kit.services) == "table" and type(kit.services.roomEntitiesService) == "table" then
        if _looksLikeSvc(kit.services.roomEntitiesService) then
            return kit.services.roomEntitiesService
        end
    end

    local ok, mod = _safeRequire("dwkit.services.roomentities_service")
    if ok and _looksLikeSvc(mod) then return mod end

    return nil
end


local function _uiCommand(ctx, arg)
    local gs = require("dwkit.config.gui_settings")
    local ui = require("dwkit.ui.roomentities_ui")

    -- "visible" is only meaningful when gui_settings visibility persistence is enabled.
    -- dwverify ui_smoke calls this explicitly; dwroom ui should do the same.
    if type(gs) == "table" and type(gs.enableVisiblePersistence) == "function" then
        pcall(function() gs.enableVisiblePersistence({}) end)
    end

    -- Ensure UI module has registered settings/subscriptions (idempotent).
    if type(ui) == "table" and type(ui.init) == "function" then pcall(ui.init) end

    local action = tostring(arg or ""):match("^%s*(.-)%s*$"):lower()
    if action == "" or action == "status" then
        local enabled = gs.getEnabledOrDefault("roomentities_ui", false)
        local visible = gs.getVisibleOrDefault("roomentities_ui", false)
        local st = (type(ui)=="table" and type(ui.getState)=="function") and ui.getState() or {}
        print(string.format("[DWKit Room UI] roomentities_ui enabled=%s visible=%s", tostring(enabled), tostring(visible)))
        if type(st) == "table" then
            if st.lastError ~= nil then print("[DWKit Room UI] lastError=" .. tostring(st.lastError)) end
            if st.lastUpdateTs ~= nil then print("[DWKit Room UI] lastUpdateTs=" .. tostring(st.lastUpdateTs)) end
        end
        return true
    end

    local function _apply()
        if type(ui)=="table" and type(ui.apply)=="function" then
            local ok, err = ui.apply()
            if ok == false then print("[DWKit Room UI] apply failed: " .. tostring(err)) end
        end
    end

    if action == "on" or action == "show" then
        gs.setEnabled("roomentities_ui", true)
        gs.setVisible("roomentities_ui", true)
        _apply()
        print(string.format(
            "[DWKit Room UI] roomentities_ui enabled=%s visible=%s",
            tostring(gs.getEnabledOrDefault("roomentities_ui", false)),
            tostring(gs.getVisibleOrDefault("roomentities_ui", false))
        ))
        return true
    end

    if action == "off" then
        gs.setVisible("roomentities_ui", false)
        gs.setEnabled("roomentities_ui", false)
        _apply()
        print(string.format(
            "[DWKit Room UI] roomentities_ui enabled=%s visible=%s",
            tostring(gs.getEnabledOrDefault("roomentities_ui", false)),
            tostring(gs.getVisibleOrDefault("roomentities_ui", false))
        ))
        return true
    end

    if action == "hide" then
        gs.setVisible("roomentities_ui", false)
        _apply()
        print(string.format(
            "[DWKit Room UI] roomentities_ui enabled=%s visible=%s",
            tostring(gs.getEnabledOrDefault("roomentities_ui", false)),
            tostring(gs.getVisibleOrDefault("roomentities_ui", false))
        ))
        return true
    end

    if action == "toggle" then
        local enabled = gs.getEnabledOrDefault("roomentities_ui", false)
        if enabled then
            gs.setVisible("roomentities_ui", false)
            gs.setEnabled("roomentities_ui", false)
            _apply()
            print(string.format(
                "[DWKit Room UI] roomentities_ui enabled=%s visible=%s",
                tostring(gs.getEnabledOrDefault("roomentities_ui", false)),
                tostring(gs.getVisibleOrDefault("roomentities_ui", false))
            ))
        else
            gs.setEnabled("roomentities_ui", true)
            gs.setVisible("roomentities_ui", true)
            _apply()
            print(string.format(
                "[DWKit Room UI] roomentities_ui enabled=%s visible=%s",
                tostring(gs.getEnabledOrDefault("roomentities_ui", false)),
                tostring(gs.getVisibleOrDefault("roomentities_ui", false))
            ))
        end
        return true
    end

    print("[DWKit Room UI] Unknown ui action: " .. tostring(arg))
    _usage(ctx)
    return false
end

local function _dispatchCore(ctx, svc, sub, arg)
    local out = _mkOut(ctx)

    sub = tostring(sub or "")
    arg = tostring(arg or "")

    if sub == "" or sub == "status" then
        _printStatus(ctx, svc)
        return
    end


    if sub == "ui" then
        _uiCommand(ctx, arg)
        return
    end

    if sub == "clear" then
        _doClear(ctx, svc)
        return
    end

    if sub == "ingestclip" then
        _doIngestClip(ctx, svc)
        return
    end

    if sub == "fixture" then
        _doFixture(ctx, svc, arg)
        return
    end

    if sub == "refresh" then
        _doRefreshSafe(ctx, svc)
        return
    end

    _usage(out)
end

function M.dispatch(ctx, a, b, c)
    -- Router signature: dispatch(ctx, kit, tokens)
    if type(b) == "table" and type(b[1]) == "string" then
        local kit = a
        local tokens = b

        local svc = _resolveSvcFromKitOrCtx(ctx, kit)
        if type(svc) ~= "table" then
            local err = _mkErr(ctx)
            err("RoomEntitiesService not available. Run loader.init() first.")
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

function M.reset()
    -- No internal persistent state kept here (SAFE).
end

return M

-- END FILE: src/dwkit/commands/dwroom.lua