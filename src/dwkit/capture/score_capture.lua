-- #########################################################################
-- Module Name : dwkit.capture.score_capture
-- Owner       : Capture
-- Version     : v2026-01-13R
-- Purpose     :
--   - Passive capture of MUD "score" output variants (score / score -l / score -r)
--     without GMCP and without sending any commands.
--   - When a score block is detected, capture until an end-of-block marker is seen,
--     then ingest the raw block into DWKit.services.scoreStoreService.
--
-- End-of-block Strategy (prompt-agnostic, no timers):
--   - Table variants (score / score -l): end on the 2nd border line "+-=-=-...-+"
--   - Report variant (score -r): end only AFTER we see the "position/state" line
--     (e.g. "You are standing."), then stop when the next non-report line arrives
--     OR when prompt-noise arrives (common end-of-output condition).
--     This supports extra lines after "You are standing." (hunger/thirst/etc).
--
-- Lag / prompt-mix robustness:
--   - Prompts can sometimes appear interleaved within the output due to lag.
--   - We treat prompt-ish lines as NOISE and ignore them (do not buffer them),
--     but we do NOT use prompt format as a required end marker.
--
-- Back-to-back report hardening:
--   - If a new report header ("You are a <n> year-old ...") arrives immediately after
--     terminalSeen (no prompt gap), we finalize the current report and begin a new one.
--     This prevents merged double-report ingests.
--
-- Runaway Guard (SAFE, no timers):
--   - If capture runs too long due to unexpected output ordering, abort safely.
--   - Defaults: maxLines=250, maxBytes=25000. Configurable via install(opts).
--   - Abort drops buffer and sets lastIngestOk=false with a guard reason.
--
-- NOTE (Mudlet trigger ordering):
--   - When we create the line trigger inside the start trigger callback, Mudlet can
--     fire the new line trigger on the SAME current line. We guard against this by
--     skipping exactly one callback invocation if it matches the start line.
--
-- Optional Fallback:
--   - Prompt fallback end can be enabled via opts.enablePromptFallback=true, but is
--     OFF by default (prompt is not a reliable marker across users).
--
-- Public API  :
--   - getVersion() -> string
--   - install(opts?) -> boolean ok, string|nil err
--   - uninstall() -> boolean ok, string|nil err
--   - status() -> table (SAFE diagnostics)
--
-- Events Emitted   : None (ScoreStore emits its own Updated event on ingest)
-- Events Consumed  : None
-- Persistence      : None (handled by ScoreStore service)
-- Automation Policy: Passive capture only (no send(), no timers)
-- Dependencies     : DWKit.services.scoreStoreService (must provide ingestFromText)
-- #########################################################################

local M = {}

M.VERSION = "v2026-01-13R"

local function _getRoot()
    local DW = (type(_G.DWKit) == "table") and _G.DWKit or nil
    if not DW then return nil end
    DW.capture = DW.capture or {}
    DW.capture.scoreCapture = DW.capture.scoreCapture or {}
    return DW.capture.scoreCapture
end

local function _isFn(name)
    return type(_G[name]) == "function"
end

local function _mkPromptLuaPattern()
    -- NOTE: Lua pattern for optional prompt detection/fallback.
    -- Default still matches your "... Mv>" style prompt, but prompt differs per user.
    return "Mv>%s*$"
end

local function _mkStartRegexList()
    -- NOTE: Mudlet trigger REGEX patterns (PCRE), not Lua patterns.
    return {
        "^\\+[\\-=]+\\+$",                 -- table border "+-=-=...-+"
        "^You are a \\d+ year-old .+\\.$", -- report start
    }
end

local function _mkBorderLuaPattern()
    -- Lua pattern for a border line like "+-=-=-=-=-=-=-+-+"
    return "^%+[%-=]+%+$"
end

local function _mkGuardDefaults()
    return 250, 25000
end

local function _looksLikeHpMpMvPrompt(ln)
    -- Generic heuristic prompt used by many Deathwish players.
    -- Example: "716(716)Hp 100(100)Mp 82(82)Mv>"
    if type(ln) ~= "string" then return false end
    return ln:match("^%d+%(%d+%)Hp%s+%d+%(%d+%)Mp%s+%d+%(%d+%)Mv>%s*$") ~= nil
end

local function _looksLikeAnglePrompt(ln)
    -- Very broad heuristic: a line that ends with ">" is often a prompt.
    -- We only use this for NOISE filtering, not for mandatory capture termination.
    if type(ln) ~= "string" then return false end
    return ln:match(">%s*$") ~= nil
end

local function _isPromptNoiseLine(ln, root)
    if type(ln) ~= "string" then return false end

    -- common pre-prompt helper line in your client
    if ln:match("^Opp:") then return true end
    if ln:match("^%s*$") then return true end

    if _looksLikeHpMpMvPrompt(ln) then return true end

    -- optional configured prompt pattern (Lua)
    local pr = tostring((root and root._promptLuaPattern) or "")
    if pr ~= "" and ln:match(pr) then return true end

    -- broad fallback: "....>"
    if _looksLikeAnglePrompt(ln) then return true end

    return false
end

local function _isReportLine(ln)
    -- Accept lines that look like the "score -r" report output.
    -- Keep this broad so it supports hunger/thirst/etc lines too.
    if type(ln) ~= "string" then return false end

    if ln:match("^%s*$") then
        return true
    end

    if ln:match("^You%s") then return true end
    if ln:match("^Your%s") then return true end
    if ln:match("^Current stats:") then return true end
    if ln:match("^Original stats:") then return true end
    if ln:match("^Deaths:") then return true end
    if ln:match("^Saves vs:") then return true end
    if ln:match("^This ranks you") then return true end

    return false
end

local function _isReportStartLine(ln)
    -- Score -r header start line (Lua pattern)
    -- Example: "You are a 270 year-old male."
    if type(ln) ~= "string" then return false end
    return ln:match("^You are a %d+ year%-old .+%.$") ~= nil
end

local function _isReportTerminalStateLine(ln)
    -- Terminal "state/position" line is typically: "You are standing."
    -- But allow multi-word states, e.g. "You are mortally wounded."
    -- Explicitly exclude report header-ish lines: "You are a ...", "You are an ...", "You are the ..."
    if type(ln) ~= "string" then return false end
    if not ln:match("^You are .+%.$") then return false end
    if ln:match("^You are a%s") then return false end
    if ln:match("^You are an%s") then return false end
    if ln:match("^You are the%s") then return false end
    return true
end

local function _getScoreStore()
    local DW = (type(_G.DWKit) == "table") and _G.DWKit or nil
    local svc = (DW and type(DW.services) == "table") and DW.services.scoreStoreService or nil
    if type(svc) == "table" and type(svc.ingestFromText) == "function" then
        return true, svc, nil
    end
    return false, nil, "scoreStoreService not available (DWKit.services.scoreStoreService.ingestFromText missing)"
end

local function _safeKill(id)
    if id ~= nil and _isFn("killTrigger") then
        pcall(killTrigger, id)
    end
end

local function _setInstalled(flag)
    local root = _getRoot()
    if root then
        root._installed = (flag == true)
    end
end

local function _isInstalled()
    local root = _getRoot()
    return (root and root._installed == true) or false
end

local function _status()
    local root = _getRoot() or {}
    return {
        installed = (root._installed == true),
        capturing = (root._capturing == true),
        captureMode = root._captureMode,
        startTriggers = root._startTriggerIds,
        lineTrigger = root._lineTriggerId,

        enablePromptFallback = (root._enablePromptFallback == true),
        promptLuaPattern = root._promptLuaPattern,
        startRegexList = root._startRegexList,
        borderLuaPattern = root._borderLuaPattern,

        -- guard
        maxLines = root._maxLines,
        maxBytes = root._maxBytes,
        seenLines = root._seenLines,
        seenBytes = root._seenBytes,

        borderSeen = root._borderSeen,
        reportTerminalSeen = (root._reportTerminalSeen == true),

        lastCaptureTs = root._lastCaptureTs,
        lastIngestOk = root._lastIngestOk,
        lastIngestErr = root._lastIngestErr,
        lastCapturedLen = root._lastCapturedLen,
        lastEndReason = root._lastEndReason,
    }
end

local function _looksLikeScoreBlock(text)
    if type(text) ~= "string" or text == "" then return false end

    if text:find("| Name:", 1, true) and text:find("| Class:", 1, true) and text:find("Level:", 1, true) then
        return true
    end

    if text:find("movement points", 1, true) and text:find("Current stats:", 1, true) and text:find("You have scored", 1, true) then
        return true
    end

    return false
end

local function _trimTrailingPromptNoise(buf, root)
    while #buf > 0 do
        local last = tostring(buf[#buf] or "")
        if _isPromptNoiseLine(last, root) then
            table.remove(buf, #buf)
        else
            break
        end
    end
end

local function _abortCapture(root, reason, errMsg)
    if not root or root._capturing ~= true then
        return
    end

    _safeKill(root._lineTriggerId)
    root._lineTriggerId = nil

    root._buf = nil
    root._capturing = false
    root._lastCaptureTs = os.time()

    root._lastEndReason = tostring(reason or "abort")
    root._lastIngestOk = false
    root._lastIngestErr = tostring(errMsg or "capture aborted")
    root._lastCapturedLen = nil
end

local function _finalizeCapture(root, reason)
    if not root or root._capturing ~= true then
        return
    end

    _safeKill(root._lineTriggerId)
    root._lineTriggerId = nil

    local buf = root._buf or {}
    root._buf = nil
    root._capturing = false
    root._lastCaptureTs = os.time()
    root._lastEndReason = tostring(reason or "unknown")

    _trimTrailingPromptNoise(buf, root)

    local text = table.concat(buf, "\n")
    root._lastCapturedLen = #text

    if not _looksLikeScoreBlock(text) then
        root._lastIngestOk = false
        root._lastIngestErr = "capture ended but block did not look like score output (dropped)"
        return
    end

    local okSvc, svc, err = _getScoreStore()
    if not okSvc then
        root._lastIngestOk = false
        root._lastIngestErr = tostring(err)
        return
    end

    local ok, ingErr = svc.ingestFromText(text, { source = "score" })
    root._lastIngestOk = ok
    root._lastIngestErr = ingErr
end

local function _beginCapture(firstLine, mode)
    local root = _getRoot()
    if not root then return end
    if root._capturing then
        return
    end

    root._capturing = true
    root._captureMode = tostring(mode or "unknown")
    root._buf = {}
    root._buf[#root._buf + 1] = tostring(firstLine or "")

    root._startLine = tostring(firstLine or "")
    root._skipLineOnce = true

    root._lastIngestOk = nil
    root._lastIngestErr = nil
    root._lastCapturedLen = nil
    root._lastEndReason = nil

    root._borderSeen = 0
    root._reportTerminalSeen = false

    -- guard counters
    root._seenLines = 0
    root._seenBytes = 0

    if root._captureMode == "table" then
        root._borderSeen = 1
    end

    if _isFn("tempRegexTrigger") then
        root._lineTriggerId = tempRegexTrigger("^(.*)$", function()
            local ln = (type(line) == "string") and line or tostring(line or "")

            -- one-shot guard against "same line" re-fire
            if root._skipLineOnce == true then
                root._skipLineOnce = false
                if ln == tostring(root._startLine or "") then
                    return
                end
            end

            -- update runaway guard counters (count what we SEE, not only what we buffer)
            root._seenLines = (tonumber(root._seenLines) or 0) + 1
            root._seenBytes = (tonumber(root._seenBytes) or 0) + (#tostring(ln or "") + 1)

            local maxLines = tonumber(root._maxLines) or 0
            local maxBytes = tonumber(root._maxBytes) or 0
            if maxLines > 0 and (tonumber(root._seenLines) or 0) > maxLines then
                _abortCapture(root, "guard:maxlines", "capture aborted: exceeded maxLines=" .. tostring(maxLines))
                return
            end
            if maxBytes > 0 and (tonumber(root._seenBytes) or 0) > maxBytes then
                _abortCapture(root, "guard:maxbytes", "capture aborted: exceeded maxBytes=" .. tostring(maxBytes))
                return
            end

            -- noise filtering (prompt mixed into output due to lag)
            if _isPromptNoiseLine(ln, root) then
                -- do not buffer noise; do not terminate just because it happened
            else
                local buf = root._buf
                if type(buf) == "table" then
                    buf[#buf + 1] = ln
                end
            end

            local borderPat = tostring(root._borderLuaPattern or _mkBorderLuaPattern())

            if root._captureMode == "table" then
                if ln:match(borderPat) then
                    root._borderSeen = (tonumber(root._borderSeen) or 0) + 1
                    if (tonumber(root._borderSeen) or 0) >= 2 then
                        _finalizeCapture(root, "table:border")
                        return
                    end
                end

            elseif root._captureMode == "report" then
                if _isReportTerminalStateLine(ln) then
                    root._reportTerminalSeen = true
                end

                if root._reportTerminalSeen == true then
                    -- HARDEN: if a new report starts immediately, split captures (avoid merged double-report)
                    if _isReportStartLine(ln) then
                        local buf = root._buf
                        if type(buf) == "table" and #buf > 0 and tostring(buf[#buf]) == ln then
                            table.remove(buf, #buf)
                        end
                        _finalizeCapture(root, "report:nextreport")
                        _beginCapture(ln, "report")
                        return
                    end

                    -- If a new border appears, it's clearly a new block/prompt situation
                    if ln:match(borderPat) then
                        local buf = root._buf
                        if type(buf) == "table" and #buf > 0 and tostring(buf[#buf]) == ln then
                            table.remove(buf, #buf)
                        end
                        _finalizeCapture(root, "report:nextborder")
                        return
                    end

                    -- After terminal seen, first truly non-report line ends capture
                    if (not _isPromptNoiseLine(ln, root)) and (not _isReportLine(ln)) then
                        local buf = root._buf
                        if type(buf) == "table" and #buf > 0 and tostring(buf[#buf]) == ln then
                            table.remove(buf, #buf)
                        end
                        _finalizeCapture(root, "report:nonreport")
                        return
                    end

                    -- Common end: prompt noise
                    if _isPromptNoiseLine(ln, root) then
                        _finalizeCapture(root, "report:promptnoise")
                        return
                    end
                end
            end

            -- Optional prompt fallback (OFF by default).
            if root._enablePromptFallback == true then
                local pr = tostring(root._promptLuaPattern or _mkPromptLuaPattern())
                if pr ~= "" and ln:match(pr) then
                    _finalizeCapture(root, "fallback:prompt")
                    return
                end
            end
        end)
    else
        root._capturing = false
        root._buf = nil
        root._lastIngestOk = false
        root._lastIngestErr = "tempRegexTrigger not available"
    end
end

function M.getVersion()
    return tostring(M.VERSION or "unknown")
end

function M.status()
    return _status()
end

function M.uninstall()
    local root = _getRoot()
    if not root then
        return false, "DWKit not available"
    end

    if type(root._startTriggerIds) == "table" then
        for _, id in ipairs(root._startTriggerIds) do
            _safeKill(id)
        end
    end
    root._startTriggerIds = nil

    _safeKill(root._lineTriggerId)
    root._lineTriggerId = nil

    root._capturing = false
    root._buf = nil
    root._captureMode = nil
    root._borderSeen = nil
    root._reportTerminalSeen = nil
    root._startLine = nil
    root._skipLineOnce = nil

    root._maxLines = nil
    root._maxBytes = nil
    root._seenLines = nil
    root._seenBytes = nil

    _setInstalled(false)
    return true, nil
end

function M.install(opts)
    opts = (type(opts) == "table") and opts or {}

    local root = _getRoot()
    if not root then
        return false, "DWKit not available"
    end

    if _isInstalled() then
        return true, nil
    end

    root._enablePromptFallback = (opts.enablePromptFallback == true)

    root._promptLuaPattern = (type(opts.promptLuaPattern) == "string" and opts.promptLuaPattern ~= "")
        and opts.promptLuaPattern or _mkPromptLuaPattern()

    root._borderLuaPattern = _mkBorderLuaPattern()

    -- runaway guard defaults (SAFE)
    local dLines, dBytes = _mkGuardDefaults()
    root._maxLines = (type(opts.maxLines) == "number" and opts.maxLines > 0) and math.floor(opts.maxLines) or dLines
    root._maxBytes = (type(opts.maxBytes) == "number" and opts.maxBytes > 0) and math.floor(opts.maxBytes) or dBytes

    root._startTriggerIds = {}

    if not _isFn("tempRegexTrigger") then
        _setInstalled(false)
        return false, "tempRegexTrigger not available (Mudlet API missing)"
    end

    local starters = _mkStartRegexList()
    root._startRegexList = starters

    for _, pat in ipairs(starters) do
        local id = tempRegexTrigger(pat, function()
            local firstLine = (type(line) == "string") and line or tostring(line or "")

            if firstLine:match(_mkBorderLuaPattern()) then
                _beginCapture(firstLine, "table")
            else
                _beginCapture(firstLine, "report")
            end
        end)
        root._startTriggerIds[#root._startTriggerIds + 1] = id
    end

    _setInstalled(true)
    return true, nil
end

return M
