-- #########################################################################
-- BEGIN FILE: src/dwkit/verify/verification.lua
-- #########################################################################
-- Module Name : dwkit.verify.verification
-- Owner       : Verify
-- Version     : v2026-01-28B
-- Purpose     :
--   - Stable dwverify runner.
--   - Executes a named suite from verification_plan.lua as a one-shot manual batch.
--   - Uses temporary pacing timers that self-terminate.
--
-- Public API  :
--   - run(suiteName?, opts?) -> boolean started, string|nil err
--   - stop(reason?) -> boolean stopped
--   - getState() -> table copy
--
-- Automation Policy:
--   - Manual batch sequence ONLY (user-invoked).
--   - Any timers used are short-lived pacing timers and MUST self-terminate.
--   - MUST NOT enable polling, triggers, or recurring jobs.
--
-- Hard rules:
--   - Lua steps MUST be single-line (no newline characters).
--   - Runner MUST NOT crash Mudlet on suite errors; print FAIL and stop.
-- #########################################################################

local M = {}

M.VERSION = "v2026-01-28B"

local STATE = {
    running = false,
    suite = nil,
    idx = 0,
    total = 0,
    timerId = nil,
    lastErr = nil,
    lastStartTs = nil,
}

local function _now()
    return os.time()
end

local function _c(tag, s)
    -- Optional Mudlet color tags. If not supported, just return text.
    -- We keep this minimal; user logs show <green>/<yellow>/<cyan> already.
    return (tag and ("<" .. tag .. ">") or "") .. tostring(s)
end

local function _print(msg)
    if type(cecho) == "function" then
        cecho(tostring(msg) .. "\n")
    else
        print(tostring(msg))
    end
end

local function _err(msg)
    _print(_c("red", "[dwverify] ") .. tostring(msg))
end

local function _out(msg)
    _print(_c("cyan", "[dwverify] ") .. tostring(msg))
end

local function _ok(msg)
    _print(_c("green", "[dwverify] ") .. tostring(msg))
end

local function _warn(msg)
    _print(_c("yellow", "[dwverify] ") .. tostring(msg))
end

local function _killTimerBestEffort()
    if STATE.timerId and type(killTimer) == "function" then
        pcall(killTimer, STATE.timerId)
    end
    STATE.timerId = nil
end

local function _normalizeStep(step, defaultDelay)
    if type(step) == "string" then
        return { cmd = step, delay = defaultDelay }
    end
    if type(step) == "table" then
        local cmd = step.cmd or step[1]
        local delay = step.delay
        if type(delay) ~= "number" then delay = defaultDelay end
        return {
            cmd = cmd,
            delay = delay,
            note = step.note,
            expect = step.expect,
        }
    end
    return nil
end

local function _isSingleLine(s)
    if type(s) ~= "string" then return false end
    return (not s:find("\n")) and (not s:find("\r"))
end

local function _trim(s)
    if type(s) ~= "string" then return "" end
    return (s:match("^%s*(.-)%s*$") or "")
end

local function _isLuaStep(cmd)
    if type(cmd) ~= "string" then return false end
    local s = _trim(cmd)
    return s:sub(1, 3) == "lua"
end

local function _runLuaStep(cmd)
    -- cmd must start with "lua"
    -- Enforced single-line elsewhere.
    local s = _trim(cmd)
    local code = _trim(s:sub(4)) -- after "lua"
    if code == "" then
        return false, "empty lua step"
    end

    -- Execute safely. Prefer Mudlet native doLuaCode if present.
    if type(doLuaCode) == "function" then
        local ok, err = pcall(doLuaCode, code)
        if ok then return true end
        return false, tostring(err)
    end

    -- Fallback: loadstring
    local fn, loadErr = loadstring(code)
    if not fn then
        return false, "lua load error: " .. tostring(loadErr)
    end
    local ok, runErr = pcall(fn)
    if ok then return true end
    return false, tostring(runErr)
end

local function _execStep(cmd)
    -- CRITICAL:
    -- - Prefer expandAlias() so DWKit commands route through Mudlet aliases/router.
    -- - Only fallback to send() for raw MUD commands when alias expansion isn't available.
    -- - Never send() lua steps.

    if type(cmd) ~= "string" or cmd == "" then
        return false, "empty command"
    end

    if _isLuaStep(cmd) then
        return _runLuaStep(cmd)
    end

    if type(expandAlias) == "function" then
        -- This will run aliases (DWKit commands) and still send raw commands when no alias matches.
        local ok, err = pcall(expandAlias, cmd)
        if ok then return true end
        return false, tostring(err)
    end

    if type(send) == "function" then
        local ok, err = pcall(send, cmd)
        if ok then return true end
        return false, tostring(err)
    end

    return false, "no expandAlias() or send() available"
end

function M.getState()
    return {
        running = STATE.running and true or false,
        suite = STATE.suite,
        idx = STATE.idx,
        total = STATE.total,
        lastErr = STATE.lastErr,
        lastStartTs = STATE.lastStartTs,
    }
end

function M.stop(reason)
    if not STATE.running then
        _killTimerBestEffort()
        return true
    end

    _killTimerBestEffort()
    STATE.running = false
    STATE.suite = nil
    STATE.idx = 0
    STATE.total = 0
    STATE.lastErr = reason and tostring(reason) or "stopped"
    _warn("Stopped. reason=" .. tostring(STATE.lastErr))
    return true
end

local function _stepTick()
    if not STATE.running then
        _killTimerBestEffort()
        return
    end

    local suite = STATE.suite
    if type(suite) ~= "table" or type(suite.steps) ~= "table" then
        STATE.lastErr = "suite missing/invalid during run"
        _err("FAIL: " .. STATE.lastErr)
        return M.stop("suite-invalid")
    end

    STATE.idx = STATE.idx + 1
    if STATE.idx > STATE.total then
        _killTimerBestEffort()
        STATE.running = false
        _ok("Sequence complete.")
        _warn("Visually confirm expected behavior/output and report PASS/FAIL.")
        return
    end

    local defaultDelay = tonumber(suite.delay) or 0.35
    local rawStep = suite.steps[STATE.idx]
    local st = _normalizeStep(rawStep, defaultDelay)

    if not st or type(st.cmd) ~= "string" or st.cmd == "" then
        STATE.lastErr = "invalid step at index " .. tostring(STATE.idx)
        _err("FAIL: " .. STATE.lastErr)
        return M.stop("bad-step")
    end

    local cmd = st.cmd

    -- Hard rule: single-line lua
    if _isLuaStep(cmd) and not _isSingleLine(cmd) then
        STATE.lastErr = "Lua step must be single-line (index " .. tostring(STATE.idx) .. ")"
        _err("FAIL: " .. STATE.lastErr)
        return M.stop("lua-multiline")
    end

    -- Print optional note/expect (lightweight)
    if st.note then
        _out("Step " .. tostring(STATE.idx) .. "/" .. tostring(STATE.total) .. " note: " .. tostring(st.note))
    end

    -- Echo the command and execute it (via alias/router first)
    _print(tostring(cmd))

    local okExec, execErr = _execStep(cmd)
    if not okExec then
        STATE.lastErr = "step exec failed (index " .. tostring(STATE.idx) .. "): " .. tostring(execErr)
        _err("FAIL: " .. STATE.lastErr)
        return M.stop("exec-failed")
    end

    -- schedule next tick with this step's delay (self-terminating chain)
    local delay = tonumber(st.delay) or defaultDelay
    if delay < 0 then delay = 0 end

    if type(tempTimer) == "function" then
        STATE.timerId = tempTimer(delay, _stepTick)
    else
        -- If tempTimer isn't available, we can't pace. Fail fast to avoid tight loops.
        STATE.lastErr = "tempTimer() not available (cannot pace verification)"
        _err("FAIL: " .. STATE.lastErr)
        return M.stop("no-timer")
    end
end

function M.run(suiteName, opts)
    opts = opts or {}

    if STATE.running then
        return false, "dwverify already running"
    end

    local suiteKey = suiteName
    if type(suiteKey) ~= "string" or suiteKey == "" then suiteKey = "default" end
    suiteKey = _trim(suiteKey)

    local okPlan, Plan = pcall(require, "dwkit.verify.verification_plan")
    if not okPlan or type(Plan) ~= "table" then
        STATE.lastErr = "verification_plan not available"
        return false, STATE.lastErr
    end

    local suite = nil
    if type(Plan.getSuite) == "function" then
        suite = Plan.getSuite(suiteKey)
    else
        local suites = (type(Plan.getSuites) == "function") and Plan.getSuites() or nil
        if type(suites) == "table" then suite = suites[suiteKey] end
    end

    if type(suite) ~= "table" or type(suite.steps) ~= "table" then
        STATE.lastErr = "Unknown suite: " .. tostring(suiteKey)
        return false, STATE.lastErr
    end

    -- pre-validate lua single-line rule for entire suite
    for i, raw in ipairs(suite.steps) do
        local st = _normalizeStep(raw, tonumber(suite.delay) or 0.35)
        if st and type(st.cmd) == "string" and _isLuaStep(st.cmd) and not _isSingleLine(st.cmd) then
            STATE.lastErr = "Suite contains multi-line lua step at index " .. tostring(i)
            return false, STATE.lastErr
        end
    end

    STATE.running = true
    STATE.suite = suite
    STATE.idx = 0
    STATE.total = #suite.steps
    STATE.lastErr = nil
    STATE.lastStartTs = _now()

    local delay = tonumber(suite.delay) or 0.35
    _out("Running suite: " ..
        tostring(suiteKey) .. " (" .. tostring(STATE.total) .. " steps, delay " .. string.format("%.2fs", delay) .. ")")

    _killTimerBestEffort()
    if type(tempTimer) ~= "function" then
        STATE.lastErr = "tempTimer() not available"
        STATE.running = false
        return false, STATE.lastErr
    end

    -- start immediately (0 delay), next steps pace themselves
    STATE.timerId = tempTimer(0, _stepTick)
    return true, nil
end

return M

-- #########################################################################
-- END FILE: src/dwkit/verify/verification.lua
-- #########################################################################
