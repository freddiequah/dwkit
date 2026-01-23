-- #########################################################################
-- Module Name : dwkit.commands.dwscorestore
-- Owner       : Commands
-- Version     : v2026-01-21A
-- Purpose     :
--   - Handler for dwscorestore alias command (delegated from command_aliases)
--   - SAFE manual-only helper surface for ScoreStoreService
--
-- Supported:
--   - dwscorestore
--   - dwscorestore status
--   - dwscorestore persist on|off|status
--   - dwscorestore fixture [basic]
--   - dwscorestore clear
--   - dwscorestore wipe [disk]
--   - dwscorestore reset [disk]
--
-- Notes:
--   - clear = clears snapshot only (history preserved)
--   - wipe/reset = clears snapshot + history
--   - wipe/reset disk = also deletes persisted file (best-effort; requires store.delete support)
--
-- Public API:
--   - dispatch(ctx, svc, sub, arg) -> nil
--   - reset() -> nil (best-effort)
-- #########################################################################

local M = {}

M.VERSION = "v2026-01-21A"

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
    _out(ctx, "[DWKit ScoreStore] ERROR: " .. tostring(msg))
end

local function _call(ctx, obj, fnName, ...)
    if type(ctx) == "table" and type(ctx.callBestEffort) == "function" then
        return ctx.callBestEffort(obj, fnName, ...)
    end

    -- fallback (best-effort)
    if type(obj) ~= "table" then
        return false, nil, nil, nil, "obj not table"
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

    return false, nil, nil, nil, "call failed"
end

local function _usage(ctx)
    _out(ctx, "[DWKit ScoreStore] Usage:")
    _out(ctx, "  dwscorestore")
    _out(ctx, "  dwscorestore status")
    _out(ctx, "  dwscorestore persist on|off|status")
    _out(ctx, "  dwscorestore fixture [basic]")
    _out(ctx, "  dwscorestore clear")
    _out(ctx, "  dwscorestore wipe [disk]")
    _out(ctx, "  dwscorestore reset [disk]")
    _out(ctx, "")
    _out(ctx, "Notes:")
    _out(ctx, "  - clear = clears snapshot only (history preserved)")
    _out(ctx, "  - wipe/reset = clears snapshot + history")
    _out(ctx, "  - wipe/reset disk = also deletes persisted file (best-effort)")
end

local function _printSummary(ctx, svc)
    local ok, _, _, _, err = _call(ctx, svc, "printSummary")
    if not ok then
        _err(ctx, "ScoreStoreService.printSummary failed: " .. tostring(err))
    end
end

function M.dispatch(ctx, svc, sub, arg)
    if type(svc) ~= "table" then
        _err(ctx, "ScoreStoreService not available. Run loader.init() first.")
        return
    end

    sub = tostring(sub or "")
    arg = tostring(arg or "")

    if sub == "" or sub == "status" then
        _printSummary(ctx, svc)
        return
    end

    if sub == "persist" then
        if arg ~= "on" and arg ~= "off" and arg ~= "status" then
            _usage(ctx)
            return
        end

        if arg == "status" then
            _printSummary(ctx, svc)
            return
        end

        if type(svc.configurePersistence) ~= "function" then
            _err(ctx, "ScoreStoreService.configurePersistence not available.")
            return
        end

        local enable = (arg == "on")
        local ok, _, _, _, err = _call(ctx, svc, "configurePersistence", { enabled = enable, loadExisting = true })
        if not ok then
            _err(ctx, "configurePersistence failed: " .. tostring(err))
            return
        end

        _printSummary(ctx, svc)
        return
    end

    if sub == "fixture" then
        local name = (arg ~= "" and arg) or "basic"
        if type(svc.ingestFixture) ~= "function" then
            _err(ctx, "ScoreStoreService.ingestFixture not available.")
            return
        end

        local ok, _, _, _, err = _call(ctx, svc, "ingestFixture", name, { source = "fixture" })
        if not ok then
            _err(ctx, "ingestFixture failed: " .. tostring(err))
            return
        end

        _printSummary(ctx, svc)
        return
    end

    if sub == "clear" then
        if type(svc.clear) ~= "function" then
            _err(ctx, "ScoreStoreService.clear not available.")
            return
        end

        local ok, _, _, _, err = _call(ctx, svc, "clear", { source = "manual" })
        if not ok then
            _err(ctx, "clear failed: " .. tostring(err))
            return
        end

        _printSummary(ctx, svc)
        return
    end

    if sub == "wipe" or sub == "reset" then
        if arg ~= "" and arg ~= "disk" then
            _usage(ctx)
            return
        end

        if type(svc.wipe) ~= "function" then
            _err(ctx, "ScoreStoreService.wipe not available. Update dwkit.services.score_store_service first.")
            return
        end

        local meta = { source = "manual" }
        if arg == "disk" then
            meta.deleteFile = true
        end

        local ok, _, _, _, err = _call(ctx, svc, "wipe", meta)
        if not ok then
            _err(ctx, sub .. " failed: " .. tostring(err))
            return
        end

        _printSummary(ctx, svc)
        return
    end

    _usage(ctx)
end

function M.reset()
    -- currently stateless; placeholder for future reload-safe needs
end

return M
