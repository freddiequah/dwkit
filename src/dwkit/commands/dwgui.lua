-- #########################################################################
-- Module Name : dwkit.commands.dwgui
-- Owner       : Commands
-- Version     : v2026-01-19A
-- Purpose     :
--   - Command handler for "dwgui" (SAFE)
--   - Delegated by dwkit.services.command_aliases
--   - Supports gui settings control + optional UI lifecycle helpers:
--       * status / list
--       * enable <uiId> / disable <uiId>
--       * visible <uiId> on|off
--       * validate [enabled|<uiId>] [verbose]
--       * apply [<uiId>]
--       * dispose <uiId>
--       * reload [<uiId>]
--       * state <uiId>
--
-- Public API  :
--   - dispatch(ctx, gs, sub, uiId, arg3)
--   - dispatch(ctx, sub, uiId, arg3)      (gs resolved from ctx.getGuiSettings())
--   - reset()                             (best-effort; no persisted state)
-- #########################################################################

local M = {}

M.VERSION = "v2026-01-19A"

function M.reset()
    -- no state kept in this module (reserved for future)
end

local function _out(ctx, line)
    if type(ctx) == "table" and type(ctx.out) == "function" then
        ctx.out(line)
        return
    end
    if type(cecho) == "function" then
        cecho(tostring(line or "") .. "\n")
    elseif type(echo) == "function" then
        echo(tostring(line or "") .. "\n")
    else
        print(tostring(line or ""))
    end
end

local function _err(ctx, msg)
    if type(ctx) == "table" and type(ctx.err) == "function" then
        ctx.err(msg)
        return
    end
    _out(ctx, "[DWKit GUI] ERROR: " .. tostring(msg))
end

local function _usage(ctx)
    _out(ctx, "[DWKit GUI] Usage:")
    _out(ctx, "  dwgui")
    _out(ctx, "  dwgui status")
    _out(ctx, "  dwgui list")
    _out(ctx, "  dwgui enable <uiId>")
    _out(ctx, "  dwgui disable <uiId>")
    _out(ctx, "  dwgui visible <uiId> on|off")
    _out(ctx, "  dwgui validate")
    _out(ctx, "  dwgui validate enabled")
    _out(ctx, "  dwgui validate <uiId>")
    _out(ctx, "  dwgui apply")
    _out(ctx, "  dwgui apply <uiId>")
    _out(ctx, "  dwgui dispose <uiId>")
    _out(ctx, "  dwgui reload")
    _out(ctx, "  dwgui reload <uiId>")
    _out(ctx, "  dwgui state <uiId>")
end

local function _getGuiSettingsFromCtx(ctx)
    if type(ctx) == "table" and type(ctx.getGuiSettings) == "function" then
        local ok, gs = pcall(ctx.getGuiSettings)
        if ok and type(gs) == "table" then
            return gs
        end
    end
    return nil
end

local function _requireUiManager(ctx)
    if type(ctx) == "table" and type(ctx.safeRequire) == "function" then
        local ok, mod = ctx.safeRequire("dwkit.ui.ui_manager")
        if ok and type(mod) == "table" then
            return mod
        end
        return nil
    end
    local ok, mod = pcall(require, "dwkit.ui.ui_manager")
    if ok and type(mod) == "table" then return mod end
    return nil
end

local function _callAny(ctx, um, fnNames, ...)
    if type(um) ~= "table" then return false end
    for _, fn in ipairs(fnNames or {}) do
        if type(um[fn]) == "function" then
            local okCall, errOrNil = pcall(um[fn], ...)
            if not okCall then
                _err(ctx, "ui_manager." .. tostring(fn) .. " failed: " .. tostring(errOrNil))
            end
            return true
        end
    end
    return false
end

function M.dispatch(ctx, a, b, c, d)
    -- Signature tolerance:
    --   dispatch(ctx, gs, sub, uiId, arg3)
    --   dispatch(ctx, sub, uiId, arg3)
    local gs, sub, uiId, arg3

    if type(a) == "table" and (type(a.status) == "function" or type(a.list) == "function") then
        gs = a
        sub = tostring(b or "")
        uiId = tostring(c or "")
        arg3 = tostring(d or "")
    else
        gs = _getGuiSettingsFromCtx(ctx)
        sub = tostring(a or "")
        uiId = tostring(b or "")
        arg3 = tostring(c or "")
    end

    if type(gs) ~= "table" then
        _err(ctx, "guiSettings not available. Run loader.init() first.")
        return
    end

    -- Default behavior: show status + list (NOT usage)
    if sub == "" or sub == "status" or sub == "list" then
        if type(ctx) == "table" and type(ctx.printGuiStatusAndList) == "function" then
            local okCall, errOrNil = pcall(ctx.printGuiStatusAndList, gs)
            if not okCall then
                _err(ctx, "printGuiStatusAndList failed: " .. tostring(errOrNil))
            end
        else
            -- Fallback if ctx helper missing
            local okS, st = pcall(gs.status)
            if okS and type(st) == "table" then
                _out(ctx, "[DWKit GUI] status (dwgui)")
                _out(ctx, "  version=" .. tostring(gs.VERSION or "unknown"))
                _out(ctx, "  loaded=" .. tostring(st.loaded == true))
                _out(ctx, "  relPath=" .. tostring(st.relPath or ""))
                _out(ctx, "  uiCount=" .. tostring(st.uiCount or 0))
            end

            local okL, uiMap = pcall(gs.list)
            if okL and type(uiMap) == "table" then
                _out(ctx, "")
                _out(ctx, "[DWKit GUI] list (uiId -> enabled/visible)")
                for k, v in pairs(uiMap) do
                    local en = (type(v) == "table" and v.enabled == true) and "ON" or "OFF"
                    local vis = "(unset)"
                    if type(v) == "table" then
                        if v.visible == true then vis = "ON"
                        elseif v.visible == false then vis = "OFF" end
                    end
                    _out(ctx, "  - " .. tostring(k) .. "  enabled=" .. en .. "  visible=" .. vis)
                end
            end
        end
        return
    end

    if sub == "enable" or sub == "disable" then
        if uiId == "" then
            _usage(ctx)
            return
        end
        if type(gs.setEnabled) ~= "function" then
            _err(ctx, "guiSettings.setEnabled not available.")
            return
        end
        local enable = (sub == "enable")
        local okCall, errOrNil = pcall(gs.setEnabled, uiId, enable)
        if not okCall then
            _err(ctx, "setEnabled failed: " .. tostring(errOrNil))
            return
        end
        _out(ctx, string.format("[DWKit GUI] setEnabled uiId=%s enabled=%s", tostring(uiId), enable and "ON" or "OFF"))
        return
    end

    if sub == "visible" then
        if uiId == "" or (arg3 ~= "on" and arg3 ~= "off") then
            _usage(ctx)
            return
        end
        if type(gs.setVisible) ~= "function" then
            _err(ctx, "guiSettings.setVisible not available.")
            return
        end
        local vis = (arg3 == "on")
        local okCall, errOrNil = pcall(gs.setVisible, uiId, vis)
        if not okCall then
            _err(ctx, "setVisible failed: " .. tostring(errOrNil))
            return
        end
        _out(ctx, string.format("[DWKit GUI] setVisible uiId=%s visible=%s", tostring(uiId), vis and "ON" or "OFF"))
        return
    end

    if sub == "validate" then
        local v = nil
        if type(ctx) == "table" and type(ctx.getUiValidator) == "function" then
            local okV, vv = pcall(ctx.getUiValidator)
            if okV and type(vv) == "table" then v = vv end
        end
        if type(v) ~= "table" then
            _err(ctx, "dwkit.ui.ui_validator not available.")
            return
        end

        local target = uiId
        local verbose = (arg3 == "verbose" or uiId == "verbose")

        if uiId == "enabled" then
            target = "enabled"
        end

        local function pp(x)
            if verbose and type(ctx) == "table" and type(ctx.ppTable) == "function" then
                pcall(ctx.ppTable, x, { maxDepth = 3, maxItems = 40 })
            end
        end

        if target == "" then
            if type(v.validateAll) ~= "function" then
                _err(ctx, "ui_validator.validateAll not available.")
                return
            end
            local ok, a, b, c = pcall(v.validateAll, { source = "dwgui" })
            if not ok or a ~= true then
                _err(ctx, "validateAll failed: " .. tostring(b or c))
                return
            end
            if verbose then
                pp(b)
            else
                _out(ctx, "[DWKit GUI] validateAll OK")
            end
            return
        end

        if target == "enabled" and type(v.validateEnabled) == "function" then
            local ok, a, b, c = pcall(v.validateEnabled, { source = "dwgui" })
            if not ok or a ~= true then
                _err(ctx, "validateEnabled failed: " .. tostring(b or c))
                return
            end
            if verbose then
                pp(b)
            else
                _out(ctx, "[DWKit GUI] validateEnabled OK")
            end
            return
        end

        if target ~= "" and type(v.validateOne) == "function" then
            local ok, a, b, c = pcall(v.validateOne, target, { source = "dwgui" })
            if not ok or a ~= true then
                _err(ctx, "validateOne failed: " .. tostring(b or c))
                return
            end
            if verbose then
                pp(b)
            else
                _out(ctx, "[DWKit GUI] validateOne OK uiId=" .. tostring(target))
            end
            return
        end

        _err(ctx, "validate target unsupported (missing validateEnabled/validateOne)")
        return
    end

    if sub == "apply" or sub == "dispose" or sub == "reload" or sub == "state" then
        local um = _requireUiManager(ctx)
        if type(um) ~= "table" then
            _err(ctx, "dwkit.ui.ui_manager not available.")
            return
        end

        if sub == "apply" then
            if uiId == "" then
                if _callAny(ctx, um, { "applyAll" }, { source = "dwgui" }) then return end
            else
                if _callAny(ctx, um, { "applyOne" }, uiId, { source = "dwgui" }) then return end
            end
            _err(ctx, "ui_manager apply not supported")
            return
        end

        if sub == "dispose" then
            if uiId == "" then
                _usage(ctx)
                return
            end
            if _callAny(ctx, um, { "disposeOne" }, uiId, { source = "dwgui" }) then return end
            _err(ctx, "ui_manager.disposeOne not supported")
            return
        end

        if sub == "reload" then
            if uiId == "" then
                if _callAny(ctx, um, { "reloadAllEnabled", "reloadAll" }, { source = "dwgui" }) then return end
            else
                if _callAny(ctx, um, { "reloadOne" }, uiId, { source = "dwgui" }) then return end
            end
            _err(ctx, "ui_manager reload not supported")
            return
        end

        if sub == "state" then
            if uiId == "" then
                _usage(ctx)
                return
            end
            if _callAny(ctx, um, { "printState", "stateOne" }, uiId) then return end
            _err(ctx, "ui_manager state not supported")
            return
        end
    end

    _usage(ctx)
end

return M
