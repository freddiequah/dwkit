-- #########################################################################
-- Module Name : dwkit.commands.dwroom
-- Owner       : Commands
-- Version     : v2026-01-28A
-- Purpose     :
--   - Command surface for room utilities and room entity UI
-- #########################################################################

local M = {}

M.VERSION = "v2026-01-28A"

local U = require("dwkit.ui.ui_utils")

local function _safeRequire(moduleName)
    local ok, modOrErr = pcall(require, moduleName)
    if ok then
        return true, modOrErr
    end
    return false, nil
end

local function _mkOut(ctx)
    if type(ctx) == "table" and type(ctx.out) == "function" then
        return ctx.out
    end
    return function(s) cecho(tostring(s) .. "\n") end
end

local function _getRoomEntitiesService()
    local ok, svc = _safeRequire("dwkit.services.roomentities_service")
    if ok and type(svc) == "table" then
        return svc
    end
    return nil
end

local function _getRoomEntitiesUI()
    local ok, ui = _safeRequire("dwkit.ui.roomentities_ui")
    if ok and type(ui) == "table" then
        return ui
    end
    return nil
end

local function _getRoomFeedSvcBestEffort()
    local ok, mod = _safeRequire("dwkit.services.roomfeed_status_service")
    if ok and type(mod) == "table" then return mod end
    return nil
end

local function _printWatchStatus(ctx)
    local out = _mkOut(ctx)
    local rf = _getRoomFeedSvcBestEffort()
    if type(rf) ~= "table" or type(rf.getState) ~= "function" then
        out("[DWKit Room] watch status: RoomFeed status service not available.")
        return
    end
    local ok, st = pcall(rf.getState)
    if not ok or type(st) ~= "table" then
        out("[DWKit Room] watch status: getState failed.")
        return
    end
    out("[DWKit Room] watch status")
    out("  watchEnabled=" .. tostring(st.watchEnabled))
    out("  health=" .. tostring(st.health))
    out("  lastSnapshotTs=" .. tostring(st.lastSnapshotTs))
    out("  lastSnapshotSource=" .. tostring(st.lastSnapshotSource))
    if st.degraded == true then
        out("  degraded=true reason=" .. tostring(st.degradedReason or "unknown"))
    end
end

local function _setWatchEnabled(ctx, enabled)
    local out = _mkOut(ctx)
    local rf = _getRoomFeedSvcBestEffort()
    if type(rf) ~= "table" or type(rf.setWatchEnabled) ~= "function" then
        out("[DWKit Room] watch: RoomFeed status service not available.")
        return
    end

    local okT = pcall(function()
        rf.setWatchEnabled(enabled == true, { source = "cmd:dwroom:watch" })
    end)

    if not okT then
        out("[DWKit Room] watch: toggle failed.")
        return
    end

    out("[DWKit Room] watch " .. ((enabled == true) and "ON" or "OFF") .. " (status updated)")
    _printWatchStatus(ctx)
end

local function _usage(out)
    out("[DWKit Room] usage:")
    out("  dwroom status")
    out("  dwroom show")
    out("  dwroom hide")
    out("  dwroom refresh")
    out("  dwroom watch status")
    out("  dwroom watch on")
    out("  dwroom watch off")
end

local function _printStatus(ctx)
    local out = _mkOut(ctx)

    local svc = _getRoomEntitiesService()
    if type(svc) ~= "table" then
        out("[DWKit Room] status: roomentities service not available.")
        return
    end

    local c = svc.getCounts and svc.getCounts() or {}
    out("[DWKit Room] status")
    out("  players=" .. tostring(c.players))
    out("  mobs=" .. tostring(c.mobs))
    out("  items=" .. tostring(c.items))
    out("  unknown=" .. tostring(c.unknown))

    local rf = _getRoomFeedSvcBestEffort()
    if type(rf) == "table" and type(rf.getState) == "function" then
        local okS, st = pcall(rf.getState)
        if okS and type(st) == "table" then
            out("  roomWatchEnabled=" .. tostring(st.watchEnabled))
            out("  roomFeedHealth=" .. tostring(st.health))
        end
    end
end

local function _show(ctx)
    local out = _mkOut(ctx)
    local ui = _getRoomEntitiesUI()
    if type(ui) ~= "table" then
        out("[DWKit Room] show: roomentities ui not available.")
        return
    end
    ui.show({ source = "cmd:dwroom:show" })
    out("[DWKit Room] Room Entities UI shown.")
end

local function _hide(ctx)
    local out = _mkOut(ctx)
    local ui = _getRoomEntitiesUI()
    if type(ui) ~= "table" then
        out("[DWKit Room] hide: roomentities ui not available.")
        return
    end
    ui.hide({ source = "cmd:dwroom:hide" })
    out("[DWKit Room] Room Entities UI hidden.")
end

local function _refresh(ctx)
    local out = _mkOut(ctx)

    local svc = _getRoomEntitiesService()
    if type(svc) ~= "table" then
        out("[DWKit Room] refresh: roomentities service not available.")
        return
    end

    -- For now refresh is UI-side; capture pipeline (look/move triggers) will feed setState.
    local ui = _getRoomEntitiesUI()
    if type(ui) == "table" and type(ui.refresh) == "function" then
        ui.refresh({ source = "cmd:dwroom:refresh" })
    end

    out("[DWKit Room] refreshed.")
end

function M.getVersion()
    return tostring(M.VERSION)
end

function M.dispatch(ctx, tokens)
    tokens = (type(tokens) == "table") and tokens or {}
    local out = _mkOut(ctx)

    local sub = tostring(tokens[2] or ""):lower()
    local arg = tokens[3]

    if sub == "" or sub == "status" then
        _printStatus(ctx)
    elseif sub == "show" then
        _show(ctx)
    elseif sub == "hide" then
        _hide(ctx)
    elseif sub == "refresh" then
        _refresh(ctx)
    elseif sub == "watch" then
        local a1 = tostring(arg or ""):lower()
        if a1 == "" or a1 == "status" then
            _printWatchStatus(ctx)
        elseif a1 == "on" then
            _setWatchEnabled(ctx, true)
        elseif a1 == "off" then
            _setWatchEnabled(ctx, false)
        else
            out("[DWKit Room] watch: unknown argument (use: status|on|off)")
        end
    else
        _usage(out)
    end
end

return M
