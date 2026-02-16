-- FILE: src/dwkit/services/chat_router_service.lua
-- #########################################################################
-- Module Name : dwkit.services.chat_router_service
-- Owner       : Services
-- Version     : v2026-02-15B
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
--       - target: string                 (first-class target; stored downstream)
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
--       - target: string                 (first-class target; stored downstream)
--       - raw: any
--       - ts: number
--       - profileTag: string
--       - allow: function(text, opts)->boolean
--         If provided and returns false, line is ignored (not an error).
--
--   - ingestMudLine(line, meta?) -> boolean ok, string|nil err
--     Parses known MUD chat strings into channel/speaker/target/text then routes via push().
--     IMPORTANT (chat-only milestone): non-chat lines are DROPPED (ignored), not routed to Other.
--     meta (optional table):
--       - source: string (default "capture:mud")
--       - ts: number
--       - profileTag: string
--       - allow: function(channel, text, meta)->boolean
--
-- Dependencies     : dwkit.services.chat_log_service
-- #########################################################################

local M = {}

M.VERSION = "v2026-02-15B"

local Log = require("dwkit.services.chat_log_service")

local function _isNonEmptyString(s) return type(s) == "string" and s ~= "" end

local function _trim(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Best-effort strip ANSI escape codes (common in MUD output).
local function _stripAnsi(s)
    if type(s) ~= "string" then return "" end
    -- CSI sequences like ESC[ ... letter
    s = s:gsub("\27%[[0-9;?]*[A-Za-z]", "")
    -- OSC sequences like ESC] ... BEL or ESC\
    s = s:gsub("\27%][^\7]*\7", "")
    s = s:gsub("\27%][^\27]*\27\\", "")
    return s
end

local function _normChannel(ch)
    if type(ch) ~= "string" then return "" end
    ch = _trim(ch):upper()
    return ch
end

local function _normSpeaker(sp)
    sp = _trim(_stripAnsi(tostring(sp or "")))
    if sp == "" then return nil end
    return sp
end

local function _normTarget(tg)
    tg = _trim(_stripAnsi(tostring(tg or "")))
    if tg == "" then return nil end

    -- Normalize common target casing for consistent UI/logging:
    -- "you" / "You" / "YOU" -> "You"
    if tg:lower() == "you" then
        return "You"
    end

    return tg
end

local function _normText(t)
    if type(t) ~= "string" then return "" end
    t = t:gsub("\r", ""):gsub("\n", "")
    t = _stripAnsi(t)
    t = _trim(t)
    return t
end

local function _looksLikePrompt(line)
    line = tostring(line or "")
    line = _stripAnsi(line)
    line = _trim(line)
    if line == "" then return false end

    -- Common Deathwish-ish prompt: <716(716)Hp 100(100)Mp 82(82)Mv>
    if line:match("^<%s*%d+%(%d+%)Hp%s+%d+%(%d+%)Mp%s+%d+%(%d+%)Mv%s*>%s*$") then
        return true
    end

    -- Sometimes two prompts appear on one line:
    if line:find("Hp", 1, true) and line:find("Mp", 1, true) and line:find("Mv", 1, true) then
        -- if the whole line is basically prompt-ish (angle brackets + stats), drop it
        if line:match("^<.*Hp.*Mp.*Mv.*>$") then
            return true
        end
        -- or repeated prompts:
        if line:match("^<.*Hp.*Mv.*>%s*<.*Hp.*Mv.*>$") then
            return true
        end
    end

    return false
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

    local normText = _normText(text)
    if normText == "" then
        return false, "push(channel, text): text is empty after normalization"
    end

    -- channel: prefer explicit arg; fall back to meta.channel
    local ch = _normChannel(channel)
    if ch == "" and _isNonEmptyString(meta.channel) then
        ch = _normChannel(meta.channel)
    end

    local speaker = _normSpeaker(meta.speaker)
    local target = _normTarget(meta.target)

    -- Allow filter should see normalized inputs (but still receives raw/meta for advanced logic)
    local allowMeta = {}
    for k, v in pairs(meta) do allowMeta[k] = v end
    allowMeta.channel = ch
    allowMeta.speaker = speaker
    allowMeta.target = target
    allowMeta.text = normText

    if type(meta.allow) == "function" then
        local okAllow, allowRes = pcall(meta.allow, ch, normText, allowMeta)
        if okAllow and allowRes == false then
            return true, nil -- ignore, not an error
        end
    end

    return Log.addLine(normText, {
        source = meta.source or "router",
        channel = (ch ~= "" and ch or nil),
        speaker = speaker,
        target = target, -- first-class field
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

    local normText = _normText(text)
    if normText == "" then
        return false, "ingestLine(text): text is empty after normalization"
    end

    if type(opts.allow) == "function" then
        local okAllow, allowRes = pcall(opts.allow, normText, opts)
        if okAllow and allowRes == false then
            return true, nil -- ignore, not an error
        end
    end

    return M.push(opts.channel, normText, {
        source = opts.source or "router",
        speaker = opts.speaker,
        target = opts.target,
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
    -- normalize and strip ANSI first (critical for real capture)
    line = _normText(tostring(line or ""))
    if line == "" then return nil end

    local speaker, verb, target, text

    -- 1) You <verb>, 'text'
    verb, text = line:match("^You%s+(%w+),%s+'(.*)'$")
    if verb and text then
        local ch = _mapVerbToChannel(verb)
        if ch ~= "" then
            return {
                speaker = "You",
                channel = ch,
                target = nil,
                text = _normText(text),
                rawVerb = verb,
            }
        end
        return nil
    end

    -- 2) <Name> <verb>, 'text'  (says/gossips/shouts/yells/congrats/asks)
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
            target = _normTarget(target),
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
                target = "You",
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
            target = _normTarget(target),
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
                target = "You",
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
            target = _normTarget(target),
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
                target = "You",
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

    -- Chat-only milestone:
    -- Drop prompts / empty / non-chat lines so Chat UI remains chat-focused.
    if _looksLikePrompt(line) then
        return true, nil
    end

    local parsed = _parseMudLine(line)
    if not parsed then
        -- Non-chat: ignore (SAFE, not an error).
        return true, nil
    end

    -- If parse produced an unmapped channel, treat as non-chat.
    if type(parsed.channel) ~= "string" or parsed.channel == "" then
        return true, nil
    end

    -- Route parsed chat line. UI will add [CHANNEL] when needed.
    return M.push(parsed.channel, parsed.text, {
        source = meta.source or "capture:mud",
        speaker = parsed.speaker,
        raw = meta.raw or line,
        ts = meta.ts,
        profileTag = meta.profileTag,
        allow = meta.allow,
        target = parsed.target,
    })
end

return M
