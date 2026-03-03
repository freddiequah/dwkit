-- #########################################################################
-- Module Name : dwkit.capture.practice_capture
-- Owner       : Capture
-- Version     : v2026-03-03D
-- Purpose     :
--   - Passive capture of MUD "practice" output (no GMCP, no send()).
--   - When a practice block is detected, capture lines until prompt/noise indicates end,
--     then ingest raw block into DWKit.services.practiceStoreService.
--
-- End-of-block Strategy (prompt-agnostic, no timers):
--   - Start: detect practice headers / session line variants (skills/spells/race/weapon)
--   - End: after capture has started, finalize when a prompt/noise line appears
--          (Hp/Mp/Mv prompt or any line ending with '>') OR if runaway guard triggers.
--
-- Install behavior hardening:
--   - tempRegexTrigger IDs persist across reloads, so if the module updates its start regex list,
--     we must re-install triggers. We store root._installedVersion and reinstall when it differs.
--
-- IMPORTANT (section blank lines):
--   - Deathwish practice output uses blank lines BETWEEN sections (skills/race/weapon).
--   - Blank lines must NOT terminate capture, otherwise we ingest partial blocks and later sections
--     overwrite the snapshot (e.g., weapon-only).
--
-- Runaway Guard (SAFE, no timers):
--   - Defaults: maxLines=350, maxBytes=45000. Configurable via install(opts).
--   - Abort drops buffer and sets lastIngestOk=false with a guard reason.
--
-- NOTE (Mudlet trigger ordering):
--   - When we create the line trigger inside the start trigger callback, Mudlet can
--     fire the new line trigger on the SAME current line. We guard against this by
--     skipping exactly one callback invocation if it matches the start line.
--
-- Public API  :
--   - getVersion() -> string
--   - install(opts?) -> boolean ok, string|nil err
--   - uninstall() -> boolean ok, string|nil err
--   - status() -> table (SAFE diagnostics)
--
-- Events Emitted   : None (PracticeStore emits its own Updated event on ingest)
-- Events Consumed  : None
-- Persistence      : None (handled by PracticeStore service)
-- Automation Policy: Passive capture only (no send(), no timers)
-- Dependencies     : DWKit.services.practiceStoreService (must provide ingestFromText)
-- #########################################################################

local M = {}

M.VERSION = "v2026-03-03D"

local function _getRoot()
    local DW = (type(_G.DWKit) == "table") and _G.DWKit or nil
    if not DW then return nil end
    DW.capture = DW.capture or {}
    DW.capture.practiceCapture = DW.capture.practiceCapture or {}
    return DW.capture.practiceCapture
end

local function _isFn(name)
    return type(_G[name]) == "function"
end

local function _mkStartRegexList()
    -- Mudlet tempRegexTrigger patterns (PCRE)
    -- Support both legacy and current Deathwish formats.
    return {
        -- common leading line on Deathwish:
        "^You have \\d+ practice sessions remaining\\.$",

        -- current Deathwish sections:
        "^You can practice any of these skills:?$",
        "^You can practice any of these spells:?$",
        "^Your race grants you the following skills:?$",
        "^You can practice any of these weapon proficiencies:?$",

        -- legacy section headers:
        "^You have the following skills:?$",
        "^You have the following spells:?$",
        "^Race skills:?$",
        "^Weapon proficiencies:?$",

        -- explicit "none" variants (still count as a practice block; capture will be short)
        "^You do not know any skills\\.?$",
        "^You do not know any spells\\.?$",
        "^You haven't learned any skills\\.?$",
        "^You haven't learned any spells\\.?$",
    }
end

local function _mkGuardDefaults()
    return 350, 45000
end

local function _looksLikeHpMpMvPrompt(ln)
    if type(ln) ~= "string" then return false end
    return ln:match("^%d+%(%d+%)Hp%s+%d+%(%d+%)Mp%s+%d+%(%d+%)Mv>%s*$") ~= nil
end

local function _looksLikeAnglePrompt(ln)
    if type(ln) ~= "string" then return false end
    return ln:match(">%s*$") ~= nil
end

-- NOTE: blank lines are NOT end markers (section separators exist in practice output).
local function _isPromptNoiseLine(ln)
    if type(ln) ~= "string" then return false end
    if ln:match("^Opp:") then return true end
    if _looksLikeHpMpMvPrompt(ln) then return true end
    if _looksLikeAnglePrompt(ln) then return true end
    return false
end

local function _getPracticeStore()
    local DW = (type(_G.DWKit) == "table") and _G.DWKit or nil
    local svc = (DW and type(DW.services) == "table") and DW.services.practiceStoreService or nil
    if type(svc) == "table" and type(svc.ingestFromText) == "function" then
        return true, svc, nil
    end
    return false, nil, "practiceStoreService not available (DWKit.services.practiceStoreService.ingestFromText missing)"
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
        installedVersion = root._installedVersion,
        capturing = (root._capturing == true),
        startTriggers = root._startTriggerIds,
        lineTrigger = root._lineTriggerId,
        startRegexList = root._startRegexList,

        -- guard
        maxLines = root._maxLines,
        maxBytes = root._maxBytes,
        seenLines = root._seenLines,
        seenBytes = root._seenBytes,

        lastCaptureTs = root._lastCaptureTs,
        lastIngestOk = root._lastIngestOk,
        lastIngestErr = root._lastIngestErr,
        lastCapturedLen = root._lastCapturedLen,
        lastEndReason = root._lastEndReason,
    }
end

local function _trimTrailingPromptNoise(buf)
    while #buf > 0 do
        local last = tostring(buf[#buf] or "")
        if _isPromptNoiseLine(last) or last:match("^%s*$") then
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

    _trimTrailingPromptNoise(buf)

    local text = table.concat(buf, "\n")
    root._lastCapturedLen = #text

    if type(text) ~= "string" or text == "" then
        root._lastIngestOk = false
        root._lastIngestErr = "capture ended but buffer was empty (dropped)"
        return
    end

    local okSvc, svc, err = _getPracticeStore()
    if not okSvc then
        root._lastIngestOk = false
        root._lastIngestErr = tostring(err)
        return
    end

    local ok, ingErr = svc.ingestFromText(text, { source = "practice" })
    root._lastIngestOk = ok
    root._lastIngestErr = ingErr
end

local function _beginCapture(firstLine)
    local root = _getRoot()
    if not root then return end
    if root._capturing then
        return
    end

    root._capturing = true
    root._buf = {}
    root._buf[#root._buf + 1] = tostring(firstLine or "")

    root._startLine = tostring(firstLine or "")
    root._skipLineOnce = true

    root._lastIngestOk = nil
    root._lastIngestErr = nil
    root._lastCapturedLen = nil
    root._lastEndReason = nil

    -- guard counters
    root._seenLines = 0
    root._seenBytes = 0

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

            -- buffer everything EXCEPT prompt noise (avoid polluting)
            if not _isPromptNoiseLine(ln) then
                local buf = root._buf
                if type(buf) == "table" then
                    buf[#buf + 1] = ln
                end
            end

            -- finalize only on real prompt/noise (NOT blank lines)
            if _isPromptNoiseLine(ln) then
                _finalizeCapture(root, "promptnoise")
                return
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
    root._startLine = nil
    root._skipLineOnce = nil

    root._maxLines = nil
    root._maxBytes = nil
    root._seenLines = nil
    root._seenBytes = nil

    root._startRegexList = nil
    root._installedVersion = nil

    _setInstalled(false)
    return true, nil
end

function M.install(opts)
    opts = (type(opts) == "table") and opts or {}

    local root = _getRoot()
    if not root then
        return false, "DWKit not available"
    end

    -- If already installed, ensure triggers match this module version.
    if _isInstalled() then
        if tostring(root._installedVersion or "") == tostring(M.VERSION or "") then
            return true, nil
        end
        pcall(M.uninstall)
    end

    -- runaway guard defaults (SAFE)
    local dLines, dBytes = _mkGuardDefaults()
    root._maxLines = (type(opts.maxLines) == "number" and opts.maxLines > 0) and math.floor(opts.maxLines) or dLines
    root._maxBytes = (type(opts.maxBytes) == "number" and opts.maxBytes > 0) and math.floor(opts.maxBytes) or dBytes

    root._startTriggerIds = {}

    if not _isFn("tempRegexTrigger") then
        _setInstalled(false)
        root._installedVersion = nil
        return false, "tempRegexTrigger not available (Mudlet API missing)"
    end

    local starters = _mkStartRegexList()
    root._startRegexList = starters

    for _, pat in ipairs(starters) do
        local id = tempRegexTrigger(pat, function()
            local firstLine = (type(line) == "string") and line or tostring(line or "")
            _beginCapture(firstLine)
        end)
        root._startTriggerIds[#root._startTriggerIds + 1] = id
    end

    root._installedVersion = tostring(M.VERSION or "")
    _setInstalled(true)
    return true, nil
end

return M
