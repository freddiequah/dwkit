-- #########################################################################
-- Module Name : dwkit.commands.dwroom
-- Owner       : Commands
-- Version     : v2026-01-20F
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
--   - refresh MUST NOT capture output or fire triggers/timers.
--   - refresh is best-effort: it calls whichever SAFE refresh/reclassify APIs exist.
--   - After successful refresh/reclassify, attempt to ensure UI refresh:
--       1) svc.emitUpdated(meta) if available
--       2) fallback to eventBus.emit(updatedEventName, payload) if available
--
-- Public API  :
--   - dispatch(ctx, roomEntitiesService, sub, arg) -> nil
--   - reset() -> nil
-- #########################################################################

local M = {}

M.VERSION = "v2026-01-20F"

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

    -- fallback: try obj.fn(...) then obj:fn(...)
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
    out("  dwroom clear")
    out("  dwroom ingestclip")
    out("  dwroom fixture [name]")
    out("  dwroom refresh")
    out("")
    out("Notes:")
    out("  - SAFE only: does NOT send any gameplay commands.")
    out("  - refresh best-effort: reclassify/emitUpdated or eventBus.emit if available.")
end

local function _printStatus(ctx, svc)
    if type(ctx) == "table" and type(ctx.printRoomEntitiesStatus) == "function" then
        ctx.printRoomEntitiesStatus(svc)
        return
    end

    local out = _mkOut(ctx)
    out("[DWKit Room] status (dwroom)")
    out("  serviceVersion=" .. tostring((type(svc) == "table" and svc.VERSION) or "unknown"))
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

    local ok, a, b, c, callErr = _call(ctx, svc, "ingestFixture", name, { source = "cmd:dwroom:fixture" })
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

local function _resolveUpdatedEventNameBestEffort(svc)
    if type(svc) == "table" then
        if type(svc.getUpdatedEventName) == "function" then
            local ok, v = pcall(svc.getUpdatedEventName)
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

    -- enrich meta so the service can embed it if it supports it
    meta.method = meta.method or methodName
    meta.note = meta.note or "dwroom refresh ensure emit"

    -- 1) preferred: service owns the event emission
    if type(svc) == "table" and type(svc.emitUpdated) == "function" then
        local ok, a, b, c, callErr = _call(ctx, svc, "emitUpdated", meta)
        if ok and a ~= false then
            out("  emitUpdated=OK (svc.emitUpdated)")
            return true
        end
        out("  emitUpdated=FAILED (svc.emitUpdated) err=" .. tostring(b or c or callErr or "unknown"))
        -- continue to fallback
    else
        out("  emitUpdated=SKIP (svc.emitUpdated missing)")
    end

    -- 2) fallback: emit directly via eventBus
    local eb = _getEventBusBestEffort()
    if type(eb) ~= "table" then
        out("  emitUpdated=SKIP (eventBus not available)")
        return false
    end

    local evName = _resolveUpdatedEventNameBestEffort(svc)
    local payload = {
        source = meta.source or "cmd:dwroom:refresh",
        method = meta.method or methodName,
        note = meta.note or "fallback eventBus.emit",
        ts = os.time(),
    }

    local ok1, a1, b1, c1, err1 = _call(ctx, eb, "emit", evName, payload)
    if ok1 and a1 ~= false then
        out("  emitUpdated=OK (eventBus.emit fallback)")
        return true
    end

    out("  emitUpdated=FAILED (eventBus.emit fallback) err=" .. tostring(b1 or c1 or err1 or "unknown"))
    return false
end

-- SAFE refresh:
--  - no gameplay commands
--  - best-effort call chain
--  - ensure Updated event is emitted (svc.emitUpdated OR eventBus.emit fallback)
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

    -- Preferred: explicit SAFE refresh API (if service provides it)
    do
        local ok = tryCall("refresh", meta)
        if ok then
            success("refresh")
            return
        end
    end

    -- Next: reclassify using WhoStore (if service provides it)
    do
        local ok = tryCall("reclassifyFromWhoStore", meta)
        if ok then
            success("reclassifyFromWhoStore")
            return
        end
    end

    -- Next: generic reclassify hooks (naming variations)
    do
        local ok = tryCall("reclassify", meta)
        if ok then
            success("reclassify")
            return
        end
    end

    do
        local ok = tryCall("reclassifyAll", meta)
        if ok then
            success("reclassifyAll")
            return
        end
    end

    -- Last: explicit emitUpdated hook only
    do
        local ok = tryCall("emitUpdated", meta)
        if ok then
            success("emitUpdated")
            return
        end
    end

    err("No SAFE refresh API found on RoomEntitiesService.")
    out("  Expected one of:")
    out("    - refresh(meta)")
    out("    - reclassifyFromWhoStore(meta)")
    out("    - reclassify(meta) / reclassifyAll(meta)")
    out("    - emitUpdated(meta)")
    out("")
    out("  Tip: run dwroom status to confirm available APIs.")
end

function M.dispatch(ctx, svc, sub, arg)
    local out = _mkOut(ctx)

    sub = tostring(sub or "")
    arg = tostring(arg or "")

    if sub == "" or sub == "status" then
        _printStatus(ctx, svc)
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

function M.reset()
    -- No internal persistent state kept here (SAFE).
end

return M
