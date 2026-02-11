-- FILE: src/dwkit/services/chat_router_service.lua
-- #########################################################################
-- Module Name : dwkit.services.chat_router_service
-- Owner       : Services
-- Version     : v2026-02-11B
-- Purpose     :
--   - SAFE router for "incoming lines" into ChatLogService.
--   - Caller decides how to obtain lines (passive capture surfaces / fixtures / manual).
--   - No triggers, no polling, no commands.
--
-- Public API:
--   - getVersion() -> string
--   - push(channel, text, meta?) -> boolean ok, string|nil err
--     meta (optional table):
--       - source: string
--       - speaker: string
--       - raw: any
--       - ts: number
--       - profileTag: string
--       - allow: function(channel, text, meta)->boolean
--         If provided and returns false, message is ignored (not an error).
--
--   - ingestLine(text, opts?) -> boolean ok, string|nil err   (back-compat)
--     opts:
--       - source: string
--       - channel: string
--       - speaker: string
--       - raw: any
--       - ts: number
--       - profileTag: string
--       - allow: function(text, opts)->boolean
--         If provided and returns false, line is ignored (not an error).
--
--   - ingestMudLine(line, meta?) -> boolean ok, string|nil err
--     Parses known MUD chat strings into channel/speaker/text then routes via push().
--     meta (optional table):
--       - source: string (default "capture:mud")
--       - ts: number
--       - profileTag: string
--       - allow: function(channel, text, meta)->boolean
--
-- Dependencies     : dwkit.services.chat_log_service
-- #########################################################################

local M = {}

M.VERSION = "v2026-02-11B"

local Log = require("dwkit.services.chat_log_service")

local function _isNonEmptyString(s) return type(s) == "string" and s ~= "" end

local function _trim(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function _normChannel(ch)
    if type(ch) ~= "string" then return "" end
    ch = _trim(ch):upper()
    return ch
end

local function _normSpeaker(sp)
    sp = _trim(sp)
    if sp == "" then return nil end
    return sp
end

local function _normText(t)
    if type(t) ~= "string" then return "" end
    t = t:gsub("\r", ""):gsub("\n", "")
    return t
end

local function _mapVerbToChannel(verbUpper)
    verbUpper = tostring(verbUpper or ""):upper()

    if verbUpper == "SAY" or verbUpper == "SAYS" then return "SAY" end
    if verbUpper == "GOSSIP" or verbUpper == "GOSSIPS" then return "GOSSIP" end
    if verbUpper == "SHOUT" or verbUpper == "SHOUTS" then return "SHOUT" end
    if verbUpper == "YELL" or verbUpper == "YELLS" then return "YELL" end

    -- Your samples show both "congrat" and "congrats"
    if verbUpper == "CONGRAT" or verbUpper == "CONGRATS" or verbUpper == "CONGRATULATE" or verbUpper == "CONGRATULATES" then
        return "GRATS"
    end

    if verbUpper == "TELL" or verbUpper == "TELLS" then return "TELL" end
    if verbUpper == "WHISPER" or verbUpper == "WHISPERS" then return "WHISPER" end
    if verbUpper == "ASK" or verbUpper == "ASKS" then return "ASK" end

    return ""
end

function M.getVersion()
    return tostring(M.VERSION or "unknown")
end

function M.push(channel, text, meta)
    meta = (type(meta) == "table") and meta or {}

    if not _isNonEmptyString(text) then
        return false, "push(channel, text): text must be a non-empty string"
    end

    local ch = _normChannel(channel)

    if type(meta.allow) == "function" then
        local okAllow, allowRes = pcall(meta.allow, ch, text, meta)
        if okAllow and allowRes == false then
            return true, nil -- ignore, not an error
        end
    end

    return Log.addLine(text, {
        source = meta.source or "router",
        channel = (ch ~= "" and ch or meta.channel),
        speaker = meta.speaker,
        raw = meta.raw,
        ts = meta.ts,
        profileTag = meta.profileTag,
    })
end

-- Back-compat entrypoint (older callers)
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

    return M.push(opts.channel, text, {
        source = opts.source or "router",
        speaker = opts.speaker,
        raw = opts.raw,
        ts = opts.ts,
        profileTag = opts.profileTag,
    })
end

-- -------------------------------------------------------------------------
-- MUD line parsing helper (for your provided samples)
--
-- Supported examples:
--   You say, 'hi'
--   Vzae says, 'hi'
--   You gossip, 'Test'
--   Vzae gossips, 'Test'
--   You shout, 'test'
--   Xi shouts, 'test'
--   You yell, 'test'
--   Xi yells, 'test'
--   You congrat, 'test'
--   Vzae congrats, 'test'
--   You tell Xi, 'hi'
--   Vzae tells you, 'hi'
--   You whisper to Xi, 'hi'
--   Vzae whispers to you, 'hi'
--   You ask Vzae, 'hi'
--   Xi asks you, 'hi'
-- -------------------------------------------------------------------------
local function _parseMudLine(line)
    line = _trim(tostring(line or ""))
    if line == "" then return nil end

    local speaker, verb, target, text

    -- 1) You <verb>, 'text'
    verb, text = line:match("^You%s+(%w+),%s+'(.*)'$")
    if verb and text then
        return {
            speaker = "You",
            channel = _mapVerbToChannel(verb),
            target = nil,
            text = _normText(text),
            rawVerb = verb,
        }
    end

    -- 2) <Name> <verb>s, 'text'  (says/gossips/shouts/yells/congrats/asks)
    speaker, verb, text = line:match("^(.-)%s+(%w+),%s+'(.*)'$")
    if speaker and verb and text then
        speaker = _normSpeaker(speaker)
        local ch = _mapVerbToChannel(verb)
        if speaker and ch ~= "" then
            return {
                speaker = speaker,
                channel = ch,
                target = nil,
                text = _normText(text),
                rawVerb = verb,
            }
        end
    end

    -- 3) You tell <Target>, 'text'
    target, text = line:match("^You%s+tell%s+(.+),%s+'(.*)'$")
    if target and text then
        return {
            speaker = "You",
            channel = "TELL",
            target = _trim(target),
            text = _normText(text),
            rawVerb = "tell",
        }
    end

    -- 4) <Speaker> tells you, 'text'
    speaker, text = line:match("^(.-)%s+tells%s+you,%s+'(.*)'$")
    if speaker and text then
        speaker = _normSpeaker(speaker)
        if speaker then
            return {
                speaker = speaker,
                channel = "TELL",
                target = "you",
                text = _normText(text),
                rawVerb = "tells",
            }
        end
    end

    -- 5) You whisper to <Target>, 'text'
    target, text = line:match("^You%s+whisper%s+to%s+(.+),%s+'(.*)'$")
    if target and text then
        return {
            speaker = "You",
            channel = "WHISPER",
            target = _trim(target),
            text = _normText(text),
            rawVerb = "whisper",
        }
    end

    -- 6) <Speaker> whispers to you, 'text'
    speaker, text = line:match("^(.-)%s+whispers%s+to%s+you,%s+'(.*)'$")
    if speaker and text then
        speaker = _normSpeaker(speaker)
        if speaker then
            return {
                speaker = speaker,
                channel = "WHISPER",
                target = "you",
                text = _normText(text),
                rawVerb = "whispers",
            }
        end
    end

    -- 7) You ask <Target>, 'text'
    target, text = line:match("^You%s+ask%s+(.+),%s+'(.*)'$")
    if target and text then
        return {
            speaker = "You",
            channel = "ASK",
            target = _trim(target),
            text = _normText(text),
            rawVerb = "ask",
        }
    end

    -- 8) <Speaker> asks you, 'text'
    speaker, text = line:match("^(.-)%s+asks%s+you,%s+'(.*)'$")
    if speaker and text then
        speaker = _normSpeaker(speaker)
        if speaker then
            return {
                speaker = speaker,
                channel = "ASK",
                target = "you",
                text = _normText(text),
                rawVerb = "asks",
            }
        end
    end

    return nil
end

function M.ingestMudLine(line, meta)
    meta = (type(meta) == "table") and meta or {}

    if not _isNonEmptyString(line) then
        return false, "ingestMudLine(line): line must be a non-empty string"
    end

    local parsed = _parseMudLine(line)
    if not parsed then
        -- Unknown format: safe ignore or route to Other? Here we route as Other by leaving channel blank.
        -- Caller can provide meta.allow to filter if preferred.
        return M.push(meta.channel or "", line, {
            source = meta.source or "capture:mud",
            speaker = meta.speaker,
            raw = meta.raw or line,
            ts = meta.ts,
            profileTag = meta.profileTag,
            allow = meta.allow,
        })
    end

    -- Route text (no channel prefix here). UI will add [CHANNEL] when needed.
    return M.push(parsed.channel, parsed.text, {
        source = meta.source or "capture:mud",
        speaker = parsed.speaker,
        raw = meta.raw or line,
        ts = meta.ts,
        profileTag = meta.profileTag,
        allow = meta.allow,
        target = parsed.target, -- optional, stored in meta.raw only unless your log/UI uses it later
    })
end

return M
