-- #########################################################################
-- Module Name : dwkit.commands.dwpracticestore
-- Owner       : Commands
-- Version     : v2026-03-03A
-- Purpose     :
--   - Handler for dwpracticestore alias command (AUTO SAFE alias via registry).
--   - SAFE manual-only helper surface for PracticeStoreService.
--
-- Supported:
--   - dwpracticestore
--   - dwpracticestore status
--   - dwpracticestore persist on|off|status
--   - dwpracticestore fixture [basic]
--   - dwpracticestore clear
--   - dwpracticestore wipe [disk]
--   - dwpracticestore reset [disk]
--
-- Notes:
--   - clear = clears snapshot only (history preserved)
--   - wipe/reset = clears snapshot + history
--   - wipe/reset disk = also deletes persisted file (best-effort; requires store.delete support)
--
-- Public API:
--   - dispatch(ctx, svc, sub, arg) -> nil
--   - dispatch(ctx, tokens) -> nil            tokens={"dwpracticestore", ...}
--   - dispatch(ctx, kit, tokens) -> nil
--   - dispatch(tokens) -> nil                best-effort (requires resolver)
--   - reset() -> nil (best-effort)
-- #########################################################################

local M = {}

M.VERSION = "v2026-03-03A"

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
    _out(ctx, "[DWKit PracticeStore] ERROR: " .. tostring(msg))
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
    _out(ctx, "[DWKit PracticeStore] Usage:")
    _out(ctx, "  dwpracticestore")
    _out(ctx, "  dwpracticestore status")
    _out(ctx, "  dwpracticestore persist on|off|status")
    _out(ctx, "  dwpracticestore fixture [basic]")
    _out(ctx, "  dwpracticestore clear")
    _out(ctx, "  dwpracticestore wipe [disk]")
    _out(ctx, "  dwpracticestore reset [disk]")
    _out(ctx, "")
    _out(ctx, "Notes:")
    _out(ctx, "  - clear = clears snapshot only (history preserved)")
    _out(ctx, "  - wipe/reset = clears snapshot + history")
    _out(ctx, "  - wipe/reset disk = also deletes persisted file (best-effort)")
end

local function _printSummary(ctx, svc)
    local ok, _, _, _, err = _call(ctx, svc, "printSummary")
    if not ok then
        _err(ctx, "PracticeStoreService.printSummary failed: " .. tostring(err))
    end
end

local function _isArrayLike(t)
    if type(t) ~= "table" then return false end
    local n = #t
    if n == 0 then return false end
    for i = 1, n do
        if t[i] == nil then return false end
    end
    return true
end

local function _parseTokens(tokens)
    if not (_isArrayLike(tokens) and tostring(tokens[1] or "") == "dwpracticestore") then
        return "", ""
    end
    local sub = tostring(tokens[2] or "")
    local arg = tostring(tokens[3] or "")
    return sub, arg
end

local function _safeRequire(modName)
    local ok, mod = pcall(require, modName)
    if ok and type(mod) == "table" then
        return true, mod, nil
    end
    return false, nil, tostring(mod)
end

local function _looksLikePracticeStoreService(svc)
    if type(svc) ~= "table" then return false end
    if type(svc.printSummary) == "function" then return true end
    if type(svc.configurePersistence) == "function" then return true end
    if type(svc.ingestFixture) == "function" then return true end
    if type(svc.clear) == "function" then return true end
    if type(svc.wipe) == "function" then return true end
    return false
end

local function _resolveSvcFromKit(kit)
    if type(kit) ~= "table" then return nil end

    if _looksLikePracticeStoreService(kit.practiceStore) then
        return kit.practiceStore
    end

    if type(kit.services) == "table" and _looksLikePracticeStoreService(kit.services.practiceStore) then
        return kit.services.practiceStore
    end

    if type(kit.getPracticeStoreService) == "function" then
        local ok, svc = pcall(kit.getPracticeStoreService)
        if ok and _looksLikePracticeStoreService(svc) then
            return svc
        end
    end

    return nil
end

local function _resolvePracticeStoreService(ctx, svcOrKit)
    if _looksLikePracticeStoreService(svcOrKit) then
        return svcOrKit
    end

    local fromKit = _resolveSvcFromKit(svcOrKit)
    if _looksLikePracticeStoreService(fromKit) then
        return fromKit
    end

    if type(ctx) == "table" and type(ctx.getPracticeStoreService) == "function" then
        local ok, svc = pcall(ctx.getPracticeStoreService)
        if ok and _looksLikePracticeStoreService(svc) then
            return svc
        end
    end

    local okS, S = _safeRequire("dwkit.services.practice_store_service")
    if okS and _looksLikePracticeStoreService(S) then
        return S
    end

    return nil
end

function M.dispatch(a1, a2, a3, a4)
    local ctx = nil
    local svc = nil
    local sub = ""
    local arg = ""

    -- dispatch(tokens)
    if _isArrayLike(a1) and tostring(a1[1] or "") == "dwpracticestore" then
        sub, arg = _parseTokens(a1)
        ctx = nil
        svc = _resolvePracticeStoreService(nil, nil)
    else
        ctx = a1

        -- dispatch(ctx, tokens)
        if _isArrayLike(a2) and tostring(a2[1] or "") == "dwpracticestore" then
            sub, arg = _parseTokens(a2)
            svc = _resolvePracticeStoreService(ctx, nil)
            -- dispatch(ctx, kit, tokens)
        elseif _isArrayLike(a3) and tostring(a3[1] or "") == "dwpracticestore" then
            sub, arg = _parseTokens(a3)
            svc = _resolvePracticeStoreService(ctx, a2)
        else
            -- legacy: dispatch(ctx, svc, sub, arg)
            svc = _resolvePracticeStoreService(ctx, a2)
            sub = tostring(a3 or "")
            arg = tostring(a4 or "")
        end
    end

    if type(svc) ~= "table" then
        _err(ctx, "PracticeStoreService not available. Run loader.init() first.")
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
            _err(ctx, "PracticeStoreService.configurePersistence not available.")
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
            _err(ctx, "PracticeStoreService.ingestFixture not available.")
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
            _err(ctx, "PracticeStoreService.clear not available.")
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
            _err(ctx, "PracticeStoreService.wipe not available. Update dwkit.services.practice_store_service first.")
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
