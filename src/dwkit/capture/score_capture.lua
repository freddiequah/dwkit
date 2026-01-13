-- #########################################################################
-- Module Name : dwkit.capture.score_capture
-- Owner       : Capture
-- Version     : v2026-01-13C
-- Purpose     :
--   - Passive capture of MUD "score" output variants (score / score -l / score -r)
--     without GMCP and without sending any commands.
--   - When a score block is detected, capture until prompt returns, then ingest
--     the raw block into DWKit.services.scoreStoreService.
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

M.VERSION = "v2026-01-13C"

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
    -- NOTE: We use line:match() (Lua patterns) for prompt detection.
    -- Your prompt line contains "... Mv> "
    -- Match any line that ends with "Mv>" (optional trailing spaces).
    return "Mv>%s*$"
end

local function _mkStartRegexList()
    -- NOTE: These are Mudlet trigger REGEX patterns (PCRE), not Lua patterns.
    -- Start lines for score variants:
    -- A) table short/long begins with "+-=-=-=-=-=-=-=-=-....-+"
    -- B) report begins with "You are a 270 year-old male."
    return {
        "^\\+[\\-=]+\\+$",                 -- matches "+-=-=...-+"
        "^You are a \\d+ year-old .+\\.$", -- report start
    }
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
        startTriggers = root._startTriggerIds,
        lineTrigger = root._lineTriggerId,
        promptLuaPattern = root._promptLuaPattern,
        startRegexList = root._startRegexList,
        lastCaptureTs = root._lastCaptureTs,
        lastIngestOk = root._lastIngestOk,
        lastIngestErr = root._lastIngestErr,
        lastCapturedLen = root._lastCapturedLen,
    }
end

local function _looksLikeScoreBlock(text)
    if type(text) ~= "string" or text == "" then return false end

    -- Table variants contain these fields
    if text:find("| Name:", 1, true) and text:find("| Class:", 1, true) and text:find("Level:", 1, true) then
        return true
    end

    -- Report variant contains these fields
    if text:find("movement points", 1, true) and text:find("Current stats:", 1, true) and text:find("You have scored", 1, true) then
        return true
    end

    return false
end

local function _trimTrailingPromptNoise(buf)
    -- Remove trailing blanks and "Opp:" line that appears before the "...Mv>" prompt line.
    while #buf > 0 do
        local last = tostring(buf[#buf] or "")
        if last:match("^%s*$") or last:match("^Opp:") then
            table.remove(buf, #buf)
        else
            break
        end
    end
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
    root._lastIngestOk = nil
    root._lastIngestErr = nil
    root._lastCapturedLen = nil

    if _isFn("tempRegexTrigger") then
        root._lineTriggerId = tempRegexTrigger("^(.*)$", function()
            local ln = (type(line) == "string") and line or tostring(line or "")
            local pr = tostring(root._promptLuaPattern or _mkPromptLuaPattern())

            if ln:match(pr) then
                _safeKill(root._lineTriggerId)
                root._lineTriggerId = nil

                local buf = root._buf or {}
                root._buf = nil
                root._capturing = false
                root._lastCaptureTs = os.time()

                _trimTrailingPromptNoise(buf)

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
                return
            end

            buf = root._buf
            if type(buf) == "table" then
                buf[#buf + 1] = ln
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

    -- Prompt detection uses Lua patterns (line:match()).
    root._promptLuaPattern = (type(opts.promptLuaPattern) == "string" and opts.promptLuaPattern ~= "")
        and opts.promptLuaPattern or _mkPromptLuaPattern()

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
            _beginCapture(firstLine)
        end)
        root._startTriggerIds[#root._startTriggerIds + 1] = id
    end

    _setInstalled(true)
    return true, nil
end

return M
