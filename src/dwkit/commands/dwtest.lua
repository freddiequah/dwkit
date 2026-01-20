-- #########################################################################
-- Module Name : dwkit.commands.dwtest
-- Owner       : Commands
-- Version     : v2026-01-20A
-- Purpose     :
--   - Command handler for `dwtest` alias (delegated from command_aliases.lua)
--   - Supports:
--       * dwtest
--       * dwtest quiet
--       * dwtest ui
--       * dwtest ui verbose
--
-- Notes:
--   - SAFE command surface.
--   - No GMCP required.
--   - UI validator is optional; only used for `dwtest ui`.
--
-- Public API  :
--   - dispatch(ctx, testRunner, args) -> boolean ok
--     ctx:
--       - out(line)
--       - err(msg)
--       - ppTable(tbl, opts) (optional)
--       - callBestEffort(obj, fnName, ...) (optional)
--       - getUiValidator() -> table|nil (optional)
--     testRunner:
--       - run(opts?) function
--     args:
--       - mode: "" | "quiet" | "ui"
--       - verbose: boolean
-- #########################################################################

local M = {}
M.VERSION = "v2026-01-20A"

local function _out(ctx, line)
    if ctx and type(ctx.out) == "function" then
        ctx.out(line)
    else
        print(tostring(line or ""))
    end
end

local function _err(ctx, msg)
    if ctx and type(ctx.err) == "function" then
        ctx.err(msg)
    else
        _out(ctx, "[dwtest] ERROR: " .. tostring(msg))
    end
end

local function _pp(ctx, t, opts)
    if ctx and type(ctx.ppTable) == "function" then
        ctx.ppTable(t, opts)
    else
        -- best-effort minimal print
        _out(ctx, tostring(t))
    end
end

local function _callBestEffort(ctx, obj, fnName, ...)
    if ctx and type(ctx.callBestEffort) == "function" then
        return ctx.callBestEffort(obj, fnName, ...)
    end
    -- fallback direct call
    if type(obj) ~= "table" or type(obj[fnName]) ~= "function" then
        return false, nil, nil, nil, "missing function: " .. tostring(fnName)
    end
    local ok, a, b, c = pcall(obj[fnName], ...)
    if ok then return true, a, b, c, nil end
    return false, nil, nil, nil, tostring(a)
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

local function _firstMsgFrom(r)
    if type(r) ~= "table" then return nil end
    if type(r.errors) == "table" and #r.errors > 0 then return tostring(r.errors[1]) end
    if type(r.warnings) == "table" and #r.warnings > 0 then return tostring(r.warnings[1]) end
    if type(r.notes) == "table" and #r.notes > 0 then return tostring(r.notes[1]) end
    return nil
end

local function _summarizeValidateAll(details)
    if type(details) ~= "table" then
        return { pass = 0, warn = 0, fail = 0, skip = 0, count = 0, list = {} }
    end

    local resArr = nil
    if type(details.results) == "table" and _isArrayLike(details.results) then
        resArr = details.results
    elseif type(details.details) == "table"
        and type(details.details.results) == "table"
        and _isArrayLike(details.details.results) then
        resArr = details.details.results
    end

    local counts = { pass = 0, warn = 0, fail = 0, skip = 0, count = 0, list = {} }
    if type(resArr) ~= "table" then return counts end

    counts.count = #resArr
    for _, r in ipairs(resArr) do
        local st = (type(r) == "table" and type(r.status) == "string") and r.status or "UNKNOWN"
        if st == "PASS" then
            counts.pass = counts.pass + 1
        elseif st == "WARN" then
            counts.warn = counts.warn + 1
            counts.list[#counts.list + 1] = r
        elseif st == "FAIL" then
            counts.fail = counts.fail + 1
            counts.list[#counts.list + 1] = r
        elseif st == "SKIP" then
            counts.skip = counts.skip + 1
        else
            counts.warn = counts.warn + 1
            counts.list[#counts.list + 1] = r
        end
    end

    return counts
end

local function _printNoUiNote(ctx)
    _out(ctx, "  NOTE: No UI modules found for this profile (dwtest ui).")
    _out(ctx, "  Tips:")
    _out(ctx, "    - dwgui list")
    _out(ctx, "    - dwgui enable <uiId>")
    _out(ctx, "    - dwgui apply")
end

function M.dispatch(ctx, testRunner, args)
    args = (type(args) == "table") and args or {}
    local mode = tostring(args.mode or "")
    local verbose = (args.verbose == true)

    if type(testRunner) ~= "table" or type(testRunner.run) ~= "function" then
        _err(ctx, "DWKit.test.run not available. Run loader.init() first.")
        return false
    end

    if mode == "quiet" then
        testRunner.run({ quiet = true })
        return true
    end

    if mode == "ui" then
        local v = nil
        if ctx and type(ctx.getUiValidator) == "function" then
            v = ctx.getUiValidator()
        end

        if type(v) ~= "table" then
            _err(ctx, "dwkit.ui.ui_validator not available. Create src/dwkit/ui/ui_validator.lua first.")
            return false
        end
        if type(v.validateAll) ~= "function" then
            _err(ctx, "ui_validator.validateAll not available.")
            return false
        end

        _out(ctx, "[DWKit Test] UI Safety Gate (dwtest ui)")
        _out(ctx, "  validator=" .. tostring(v.VERSION or "unknown"))
        _out(ctx, "  mode=" .. (verbose and "verbose" or "compact"))
        _out(ctx, "")

        local okCall, a, b, c, err = _callBestEffort(ctx, v, "validateAll", { source = "dwtest" })
        if not okCall then
            _err(ctx, "validateAll failed: " .. tostring(err))
            return false
        end
        if a ~= true then
            _err(ctx, tostring(b or c or err or "validateAll failed"))
            return false
        end

        if verbose then
            _out(ctx, "[DWKit Test] UI validateAll details (bounded)")
            _pp(ctx, b, { maxDepth = 3, maxItems = 40 })
            if type(b) == "table" and tonumber(b.count or 0) == 0 then
                _out(ctx, "")
                _printNoUiNote(ctx)
            end
            return true
        end

        local cts = _summarizeValidateAll(b)
        _out(ctx, string.format("[DWKit Test] UI summary: PASS=%d WARN=%d FAIL=%d SKIP=%d total=%d",
            cts.pass, cts.warn, cts.fail, cts.skip, cts.count))

        if cts.count == 0 then
            _out(ctx, "")
            _printNoUiNote(ctx)
            return true
        end

        if #cts.list > 0 then
            _out(ctx, "")
            _out(ctx, "[DWKit Test] UI WARN/FAIL (compact)")
            local limit = math.min(#cts.list, 25)
            for i = 1, limit do
                local r = cts.list[i]
                local st = tostring(r.status or "UNKNOWN")
                local id = tostring(r.uiId or "?")
                local msg = _firstMsgFrom(r) or ""
                if msg ~= "" then
                    _out(ctx, string.format("  - %s  uiId=%s  msg=%s", st, id, msg))
                else
                    _out(ctx, string.format("  - %s  uiId=%s", st, id))
                end
            end
            if #cts.list > limit then
                _out(ctx, "  ... (" .. tostring(#cts.list - limit) .. " more)")
            end
        end

        return true
    end

    -- default
    testRunner.run()
    return true
end

return M
