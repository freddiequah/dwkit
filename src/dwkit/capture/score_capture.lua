-- #########################################################################
-- Module Name : dwkit.capture.score_capture
-- Owner       : Capture
-- Version     : v2026-01-13B
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

M.VERSION = "v2026-01-13B"

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

local function _mkPromptRegex()
    -- Your prompt line contains "... Mv> "
    -- Match any line that ends with "Mv>" (optional trailing spaces).
    return "Mv>%s*$"
end

local function _mkStartRegexList()
    -- Start lines for score variants:
    -- A) table short/long begins with "+-=-=-=-=-=-=-=-=-....-+"
    -- B) report begins with "You are a 270 year-old male."
    return {
        "^%+%-%=.+%+$", -- FIX: allow '-' and any content between, must end with '+'
        "^You are a %d+ year%-old .+%.$",
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
        promptRegex = root._promptRegex,
        lastCaptureTs = root._lastCaptureTs,
        lastIngestOk = root._lastIngestOk,
        lastIngestErr = root._lastIngestErr,
        lastCapturedLen = root._lastCapturedLen,
    }
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
            local line = (type(line) == "string") and line or tostring(line or "")
            local pr = tostring(root._promptRegex or _mkPromptRegex())

            if line:match(pr) then
                local text = table.concat(root._buf, "\n")
                root._buf = nil
                root._capturing = false
                root._lastCaptureTs = os.time()
                root._lastCapturedLen = #text

                _safeKill(root._lineTriggerId)
                root._lineTriggerId = nil

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

            root._buf[#root._buf + 1] = line
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

    root._promptRegex = (type(opts.promptRegex) == "string" and opts.promptRegex ~= "")
        and opts.promptRegex or _mkPromptRegex()

    root._startTriggerIds = {}

    if not _isFn("tempRegexTrigger") then
        _setInstalled(false)
        return false, "tempRegexTrigger not available (Mudlet API missing)"
    end

    local starters = _mkStartRegexList()
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
