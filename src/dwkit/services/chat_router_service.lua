-- FILE: src/dwkit/services/chat_router_service.lua
-- #########################################################################
-- Module Name : dwkit.services.chat_router_service
-- Owner       : Services
-- Version     : v2026-02-10A
-- Purpose     :
--   - SAFE router for "incoming lines" into ChatLogService.
--   - Does NOT create triggers, does NOT poll, does NOT send commands.
--   - Caller decides how to obtain lines (passive capture surfaces / fixtures / manual).
--
-- Public API:
--   - getVersion() -> string
--   - ingestLine(text, opts?) -> boolean ok, string|nil err
--     opts:
--       - source: string (optional)  e.g. "capture:main"
--       - channel: string (optional) e.g. "say", "tell", "gossip", "system"
--       - speaker: string (optional)
--       - raw: any (optional)
--       - profileTag: string (optional)
--       - allow: function(text, opts)->boolean (optional)
--         If provided and returns false, line is ignored.
--
-- Dependencies     : dwkit.services.chat_log_service
-- #########################################################################

local M = {}

M.VERSION = "v2026-02-10A"

local Log = require("dwkit.services.chat_log_service")

local function _isNonEmptyString(s) return type(s) == "string" and s ~= "" end

function M.getVersion()
    return tostring(M.VERSION or "unknown")
end

function M.ingestLine(text, opts)
    opts = (type(opts) == "table") and opts or {}

    if not _isNonEmptyString(text) then
        return false, "ingestLine(text): text must be a non-empty string"
    end

    if type(opts.allow) == "function" then
        local okAllow, allowRes = pcall(opts.allow, text, opts)
        if okAllow and allowRes == false then
            return true, nil -- ignore, not an error
        end
    end

    return Log.addLine(text, {
        source = opts.source or "router",
        channel = opts.channel,
        speaker = opts.speaker,
        raw = opts.raw,
        ts = opts.ts,
        profileTag = opts.profileTag,
    })
end

return M
