-- #########################################################################
-- Module Name : dwkit.services.prompt_detector_service
-- Owner       : Services
-- Version     : v2026-02-25F
-- Purpose     :
--   - Maintain per-profile prompt detection configuration for passive capture.
--   - Learn and persist the current MUD prompt spec when the user runs 'prompt'.
--   - Provide prompt detection helpers for capture modules (eg roomfeed_capture).
-- Does NOT:
--   - Send any MUD commands (manual commands do that via command handlers).
--
-- Public API:
--   - getStatus() -> table
--   - isConfigured() -> boolean
--   - normalizeLine(line) -> string
--   - isPromptLineCandidate(lineClean) -> boolean
--   - isPromptSequence(tailLinesClean) -> boolean
--   - notePromptSpecFromOutput(specText, meta) -> boolean changed, string reason|nil
--   - addUserRegex(pat) -> boolean ok, string err|nil
--   - setUserRegexes(list) -> boolean ok, string err|nil
--   - clearUserRegexes() -> boolean ok
--   - resetAll() -> boolean ok
-- Events Emitted:
--   - (optional) DWKit:Service:PromptDetector:Updated (best-effort; not required by current consumers)
-- Events Consumed:
--   - None (passive triggers are internal; no bus subscription required)
-- Persistence:
--   - File: <profile>/dwkit_prompt_spec.lua
--   - Schema: promptSpec.v1 { ts, promptSpecRaw, userRegexes, derivedRegexes, lineCountMin, lineCountMax }
-- Automation Policy:
--   - Passive capture only (trigger observes output; no timers; no sends).
-- Dependencies:
--   - dwkit.core.identity, dwkit.bus.event_bus (optional emit)
-- #########################################################################

local M = {}
M.VERSION = "v2026-02-25F"

local ID = require("dwkit.core.identity")
local BUS = require("dwkit.bus.event_bus")

M.EV_UPDATED = tostring(ID.eventPrefix or "DWKit:") .. "Service:PromptDetector:Updated"

local _state = {
    promptSpec = {
        ts = nil,
        source = nil,
        promptSpecRaw = nil, -- string (may include newlines if wrapped)
        lineCountMin = 0,
        lineCountMax = 0,
        userRegexes = {},    -- list of lua patterns (strings)
        derivedRegexes = {}, -- list of lua patterns (strings)
    },

    persist = {
        enabled = true,
        fileName = "dwkit_prompt_spec.lua",
        lastLoadErr = nil,
        lastSaveErr = nil,
    },

    watcher = {
        enabled = true, -- passive output watcher for 'Your prompt is currently:' line
        installed = false,
        triggerId = nil,
        lastErr = nil,
    },
}

local function _nowTs()
    return os.time()
end

local function _safeString(s)
    s = tostring(s or "")
    s = s:gsub("\r", "")
    return s
end

local function _trim(s)
    s = tostring(s or "")
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function _collapseSpaces(s)
    s = tostring(s or "")
    -- collapse internal runs of whitespace
    s = s:gsub("%s+", " ")
    return _trim(s)
end

local function _stripAnsi(s)
    s = tostring(s or "")
    s = s:gsub("\r", "")
    -- OSC sequences: ESC ] ... BEL
    s = s:gsub("\27%][^\7]*\7", "")
    -- CSI sequences: ESC [ ... letter
    s = s:gsub("\27%[[0-9;]*[%a]", "")
    -- bare ESC
    s = s:gsub("\27", "")
    return s
end

local function _isWindows()
    local sep = package and package.config and package.config:sub(1, 1) or "/"
    return sep == "\\"
end

local function _escapeLuaPatternForGsubLiteral(s)
    -- Escape pattern magic so gsub treats s as literal.
    -- magic: ( ) . % + - * ? [ ^ $
    s = tostring(s or "")
    s = s:gsub("%%", "%%%%")
    s = s:gsub("%(", "%%(")
    s = s:gsub("%)", "%%)")
    s = s:gsub("%.", "%%.")
    s = s:gsub("%+", "%%+")
    s = s:gsub("%-", "%%-")
    s = s:gsub("%*", "%%*")
    s = s:gsub("%?", "%%?")
    s = s:gsub("%[", "%%[")
    s = s:gsub("%]", "%%]")
    s = s:gsub("%^", "%%^")
    s = s:gsub("%$", "%%$")
    return s
end

local function _gsubLiteral(hay, needle, repl)
    hay = tostring(hay or "")
    needle = tostring(needle or "")
    repl = tostring(repl or "")
    if needle == "" then return hay end
    return hay:gsub(_escapeLuaPatternForGsubLiteral(needle), repl)
end

local function _normalizeProfileDir(dir)
    dir = tostring(dir or "")
    if dir == "" then return dir end

    -- Normalize slashes (Mudlet often uses / even on Windows; keep /)
    dir = dir:gsub("\\", "/")

    local profile = nil
    if type(getProfileName) == "function" then
        local ok, pn = pcall(getProfileName)
        if ok and type(pn) == "string" and pn ~= "" then
            profile = pn
        end
    end

    -- Collapse any repeated /profiles/<name>/profiles/<name> sequences (repeat until stable)
    if profile and profile ~= "" then
        local needle = "/profiles/" .. profile .. "/profiles/" .. profile
        local repl = "/profiles/" .. profile
        local guard = 0
        while dir:find(needle, 1, true) do
            dir = _gsubLiteral(dir, needle, repl)
            guard = guard + 1
            if guard > 12 then break end
        end
    end

    -- Trim trailing slash
    dir = dir:gsub("/+$", "")

    return dir
end

local function _getProfileDirBestEffort()
    if type(getProfilePath) == "function" then
        local ok, v = pcall(getProfilePath)
        if ok and type(v) == "string" and v ~= "" then
            return _normalizeProfileDir(v)
        end
    end

    if type(getMudletHomeDir) == "function" then
        local ok, home = pcall(getMudletHomeDir)
        if ok and type(home) == "string" and home ~= "" then
            local profile = (type(getProfileName) == "function") and getProfileName() or nil
            profile = tostring(profile or "")
            if profile ~= "" then
                return _normalizeProfileDir(home .. "/profiles/" .. profile)
            end
        end
    end

    return nil
end

local function _getPersistPathBestEffort()
    local dir = _getProfileDirBestEffort()
    if type(dir) ~= "string" or dir == "" then
        return nil, "profile dir unavailable"
    end
    dir = _normalizeProfileDir(dir)
    local path = tostring(dir) .. "/" .. tostring(_state.persist.fileName)
    path = _normalizeProfileDir(path) -- defensive: also collapses dup profiles if present
    return path, nil
end

local function _quoteLuaString(s)
    s = _safeString(s)
    s = s:gsub("\\", "\\\\")
    s = s:gsub("\n", "\\n")
    s = s:gsub("\"", "\\\"")
    return "\"" .. s .. "\""
end

local function _emitUpdated(meta)
    meta = (type(meta) == "table") and meta or {}
    local payload = {
        ts = _nowTs(),
        source = tostring(meta.source or "prompt_detector_service"),
        configured = (M.isConfigured() == true),
        lineCountMin = tonumber(_state.promptSpec.lineCountMin or 0) or 0,
        lineCountMax = tonumber(_state.promptSpec.lineCountMax or 0) or 0,
    }
    pcall(function()
        BUS.emit(M.EV_UPDATED, payload)
    end)
end

local function _isFn(name)
    return type(_G[name]) == "function"
end

local function _ensureDirBestEffort(dir)
    dir = tostring(dir or "")
    if dir == "" then return false, "empty dir" end
    dir = dir:gsub("\\", "/")
    dir = dir:gsub("/+$", "")

    -- Try LuaFileSystem if present
    local okL, lfs = pcall(require, "lfs")
    if okL and type(lfs) == "table" and type(lfs.mkdir) == "function" then
        local function exists(p)
            if type(lfs.attributes) ~= "function" then return false end
            local okA, a = pcall(lfs.attributes, p)
            if okA and type(a) == "table" and a.mode == "directory" then return true end
            return false
        end

        if exists(dir) then return true, nil end

        local prefix = ""
        local remainder = dir

        -- Windows drive style: C:/...
        if remainder:match("^%a%:/") then
            prefix = remainder:sub(1, 3) -- "C:/"
            remainder = remainder:sub(4) -- after "C:/"
        elseif remainder:sub(1, 1) == "/" then
            prefix = "/"
            remainder = remainder:sub(2)
        end

        local parts = {}
        for part in tostring(remainder):gmatch("[^/]+") do
            parts[#parts + 1] = part
        end

        local cur = prefix
        for i = 1, #parts do
            if cur == "" or cur:sub(-1) == "/" then
                cur = cur .. parts[i]
            else
                cur = cur .. "/" .. parts[i]
            end
            if not exists(cur) then
                pcall(lfs.mkdir, cur)
            end
        end

        if exists(dir) then return true, nil end
        return false, "lfs mkdir failed"
    end

    -- Fallback to os.execute
    local cmd = nil
    if _isWindows() then
        cmd = 'mkdir "' .. dir:gsub("/", "\\") .. '"'
    else
        cmd = 'mkdir -p "' .. dir .. '"'
    end
    local ok = pcall(function() os.execute(cmd) end)
    if ok then
        return true, nil
    end
    return false, "os.execute mkdir failed"
end

local function _persistSaveBestEffort(meta)
    if _state.persist.enabled ~= true then
        return true, nil
    end

    local path, err = _getPersistPathBestEffort()
    if not path then
        _state.persist.lastSaveErr = tostring(err or "persist path unavailable")
        return false, _state.persist.lastSaveErr
    end

    -- Ensure parent directory exists (best-effort)
    local parent = path:match("^(.*)/[^/]+$")
    if parent and parent ~= "" then
        local okDir, dirErr = _ensureDirBestEffort(parent)
        if not okDir then
            _state.persist.lastSaveErr = tostring(dirErr or "persist parent mkdir failed")
            return false, _state.persist.lastSaveErr
        end
    end

    local p = _state.promptSpec
    local lines = {}
    lines[#lines + 1] = "-- DWKit Prompt Detector snapshot (SAFE; per-profile)"
    lines[#lines + 1] = "return {"
    lines[#lines + 1] = "  schema = " .. _quoteLuaString("promptSpec.v1") .. ","
    lines[#lines + 1] = "  ts = " .. tostring(p.ts or "nil") .. ","
    lines[#lines + 1] = "  source = " .. _quoteLuaString(p.source or "") .. ","
    lines[#lines + 1] = "  promptSpecRaw = " .. _quoteLuaString(p.promptSpecRaw or "") .. ","
    lines[#lines + 1] = "  lineCountMin = " .. tostring(p.lineCountMin or 0) .. ","
    lines[#lines + 1] = "  lineCountMax = " .. tostring(p.lineCountMax or 0) .. ","

    local function _serializeList(key, list)
        list = (type(list) == "table") and list or {}
        lines[#lines + 1] = "  " .. key .. " = {"
        for i = 1, #list do
            lines[#lines + 1] = "    " .. _quoteLuaString(list[i] or "") .. ","
        end
        lines[#lines + 1] = "  },"
    end

    _serializeList("userRegexes", p.userRegexes)
    _serializeList("derivedRegexes", p.derivedRegexes)

    lines[#lines + 1] = "}"
    lines[#lines + 1] = ""

    local ok, werr = pcall(function()
        local f = assert(io.open(path, "wb"))
        f:write(table.concat(lines, "\n"))
        f:close()
    end)
    if not ok then
        _state.persist.lastSaveErr = tostring(werr or "persist save failed")
        return false, _state.persist.lastSaveErr
    end

    _state.persist.lastSaveErr = nil
    return true, nil
end

local function _persistLoadBestEffort()
    if _state.persist.enabled ~= true then
        return true, nil
    end

    local path, err = _getPersistPathBestEffort()
    if not path then
        _state.persist.lastLoadErr = tostring(err or "persist path unavailable")
        return false, _state.persist.lastLoadErr
    end

    local ok, data = pcall(function()
        return dofile(path)
    end)

    if not ok then
        -- first-run is OK (file missing); only record real parse errors
        local msg = tostring(data or "")
        if msg:find("No such file", 1, true) or msg:find("cannot open", 1, true) then
            _state.persist.lastLoadErr = nil
            return true, nil
        end
        _state.persist.lastLoadErr = msg
        return false, msg
    end

    if type(data) ~= "table" then
        _state.persist.lastLoadErr = "persist: expected table"
        return false, _state.persist.lastLoadErr
    end

    local schema = tostring(data.schema or "")
    if schema ~= "promptSpec.v1" then
        _state.persist.lastLoadErr = "persist: unsupported schema=" .. schema
        return false, _state.persist.lastLoadErr
    end

    local p = _state.promptSpec
    p.ts = tonumber(data.ts or 0) or nil
    if p.ts == 0 then p.ts = nil end
    p.source = tostring(data.source or "")
    local raw = tostring(data.promptSpecRaw or "")
    p.promptSpecRaw = (raw ~= "") and raw or nil
    p.lineCountMin = tonumber(data.lineCountMin or 0) or 0
    p.lineCountMax = tonumber(data.lineCountMax or 0) or 0
    p.userRegexes = (type(data.userRegexes) == "table") and data.userRegexes or {}
    p.derivedRegexes = (type(data.derivedRegexes) == "table") and data.derivedRegexes or {}

    _state.persist.lastLoadErr = nil
    return true, nil
end

local function _escapeLuaPatternLiteral(s)
    s = tostring(s or "")
    -- Escape Lua pattern magic characters: ( ) . % + - * ? [ ^ $
    s = s:gsub("%%", "%%%%")
    s = s:gsub("%(", "%%(")
    s = s:gsub("%)", "%%)")
    s = s:gsub("%.", "%%.")
    s = s:gsub("%+", "%%+")
    s = s:gsub("%-", "%%-")
    s = s:gsub("%*", "%%*")
    s = s:gsub("%?", "%%?")
    s = s:gsub("%[", "%%[")
    s = s:gsub("%]", "%%]")
    s = s:gsub("%^", "%%^")
    s = s:gsub("%$", "%%$")
    return s
end

local function _removePromptColorCodes(spec)
    -- Deathwish prompt color codes are &<letter> and &n etc. They do not appear literally in rendered prompt.
    spec = tostring(spec or "")
    spec = spec:gsub("&[%a]", "")
    return spec
end

local function _stripConditionals(spec)
    -- Remove %C<arg> and %C end markers for pattern derivation (best-effort).
    -- Keep the inner literal/text; conditionals will be handled via min/max line matching.
    spec = tostring(spec or "")
    -- remove %C<arg>
    spec = spec:gsub("%%C[%a]", "%%C") -- normalize
    -- remove all %C tokens (both start and end)
    spec = spec:gsub("%%C", "")
    return spec
end

local function _deriveLineCountBoundsFromSpec(specRaw)
    local spec = tostring(specRaw or "")
    local rCount = 0
    spec:gsub("%%r", function() rCount = rCount + 1 end)

    local hasConditional = (spec:find("%%C", 1, true) ~= nil)
    local minLines = rCount + 1
    local maxLines = rCount + 1

    if hasConditional and rCount > 0 then
        -- If %r might be conditional, allow fewer lines (best-effort).
        minLines = 1
        maxLines = rCount + 1
    end

    return minLines, maxLines
end

local function _patternForPromptSpecLine(lineSpec)
    local spec = tostring(lineSpec or "")
    spec = _removePromptColorCodes(spec)
    spec = _stripConditionals(spec)

    -- Escape literal text first
    spec = _escapeLuaPatternLiteral(spec)

    -- Replace known prompt codes with broad matches
    local function rep(code, pat)
        spec = spec:gsub("%%%%" .. code, pat)
    end

    -- Numeric-ish
    rep("h", "(%%d+)")
    rep("H", "(%%d+)")
    rep("m", "(%%d+)")
    rep("M", "(%%d+)")
    rep("v", "(%%d+)")
    rep("V", "(%%d+)")
    rep("a", "%%-?%%d+")
    rep("A", "%%-?%%d+")
    rep("x", "(%%d+)")
    rep("X", "(%%d+)")
    rep("g", "(%%d+)")

    -- Time codes (loose)
    rep("z", ".*")
    rep("D", ".*")

    -- Combat/assist fields are free-form
    rep("o", ".*")
    rep("t", ".*")
    rep("T", ".*")

    -- Newline marker removed by split; keep loose if any remain
    rep("r", ".*")

    -- Any remaining %<letter> treat loosely
    spec = spec:gsub("%%%%[%a]", ".*")

    -- Collapse spaces in pattern to allow flexible whitespace
    -- FIX v2026-02-25F: was %s+ (too strict when %o/%t empty or spacing varies)
    spec = spec:gsub("%s+", "%%s*")

    return "^%s*" .. spec .. "%s*$"
end

local function _rebuildDerivedRegexes(reason)
    local p = _state.promptSpec
    p.derivedRegexes = {}

    -- If prompt spec known, derive patterns from it (possibly multi-line)
    if type(p.promptSpecRaw) == "string" and p.promptSpecRaw ~= "" then
        local spec = p.promptSpecRaw
        spec = spec:gsub("\r", "")
        -- Use the spec string (may include wrapped newlines); we only care about %r tokens
        local minL, maxL = _deriveLineCountBoundsFromSpec(spec)
        p.lineCountMin = minL
        p.lineCountMax = maxL

        local collapsed = spec:gsub("\n", " ")
        local parts = {}
        local last = 1
        while true do
            local s1, e1 = collapsed:find("%%r", last, true)
            if not s1 then
                parts[#parts + 1] = collapsed:sub(last)
                break
            end
            parts[#parts + 1] = collapsed:sub(last, s1 - 1)
            last = e1 + 1
        end

        for i = 1, #parts do
            local pat = _patternForPromptSpecLine(_trim(parts[i]))
            if pat and pat ~= "" then
                p.derivedRegexes[#p.derivedRegexes + 1] = pat
            end
        end

        if #p.derivedRegexes == 0 then
            p.derivedRegexes = {}
        end
        return
    end

    -- Fallback heuristics (broad) for unknown prompt
    -- Covers:
    --   <...hp...mp...mv...>
    --   Opp: ... 514(514)Hp ... Mv>
    p.lineCountMin = 1
    p.lineCountMax = 1
    p.derivedRegexes[#p.derivedRegexes + 1] = "^%s*%b<>%s*$"
    p.derivedRegexes[#p.derivedRegexes + 1] = "^%s*.*%d+%(%d+%)Hp%s+%d+%(%d+%)Mp%s+%d+%(%d+%)Mv>%s*$"

    if reason then
        -- no output; reason kept for caller
    end
end

local function _normalizeForCompare(specText)
    specText = tostring(specText or "")
    specText = specText:gsub("\r", "")
    -- Preserve newlines only as separators, but normalize whitespace
    specText = specText:gsub("\n", " ")
    specText = _collapseSpaces(specText)
    return specText
end

function M.normalizeLine(line)
    line = _safeString(line)
    line = _stripAnsi(line)
    return _trim(line)
end

function M.isConfigured()
    local p = _state.promptSpec
    if type(p.promptSpecRaw) == "string" and p.promptSpecRaw ~= "" then
        return true
    end
    -- Even if prompt spec unknown, we still have fallback derived regexes
    return false
end

local function _allRegexes()
    local p = _state.promptSpec
    local out = {}

    local function addAll(list)
        list = (type(list) == "table") and list or {}
        for i = 1, #list do
            local v = tostring(list[i] or "")
            if v ~= "" then out[#out + 1] = v end
        end
    end

    addAll(p.userRegexes)
    addAll(p.derivedRegexes)

    return out
end

function M.isPromptLineCandidate(lineClean)
    local ln = tostring(lineClean or "")
    if ln == "" then return false end

    -- If it looks like the MUD 'Your prompt is currently:' line, do not treat as rendered prompt.
    if ln:find("Your prompt is currently:", 1, true) then
        return false
    end

    local regs = _allRegexes()
    for i = 1, #regs do
        local pat = regs[i]
        local ok, m = pcall(function()
            return (ln:match(pat) ~= nil)
        end)
        if ok and m then
            return true
        end
    end

    return false
end

function M.isPromptSequence(tailLinesClean)
    tailLinesClean = (type(tailLinesClean) == "table") and tailLinesClean or {}
    local p = _state.promptSpec

    local minL = tonumber(p.lineCountMin or 0) or 0
    local maxL = tonumber(p.lineCountMax or 0) or 0

    if minL <= 0 then minL = 1 end
    if maxL <= 0 then maxL = 1 end
    if maxL < minL then maxL = minL end

    local regs = _allRegexes()
    if #regs == 0 then
        _rebuildDerivedRegexes("sequence:empty_regexes")
        regs = _allRegexes()
    end

    -- Sequence match: last N lines must match the first N regexes (best-effort).
    -- For conditional prompts, accept any N within [minL, maxL] that matches suffix.
    local function matchesN(n)
        if n <= 0 then return false end
        if #tailLinesClean < n then return false end
        if #regs < n then return false end

        local startIdx = #tailLinesClean - n + 1
        for i = 1, n do
            local ln = tostring(tailLinesClean[startIdx + i - 1] or "")
            local pat = tostring(regs[i] or "")
            if pat == "" then return false end
            if ln:match(pat) == nil then
                return false
            end
        end
        return true
    end

    for n = maxL, minL, -1 do
        if matchesN(n) then
            return true
        end
    end

    return false
end

function M.addUserRegex(pat)
    pat = tostring(pat or "")
    pat = _trim(pat)
    if pat == "" then return false, "empty pattern" end
    _state.promptSpec.userRegexes[#_state.promptSpec.userRegexes + 1] = pat
    _state.promptSpec.ts = _nowTs()
    _state.promptSpec.source = "dwprompt:add"
    _persistSaveBestEffort({ source = "dwprompt:add" })
    _emitUpdated({ source = "dwprompt:add" })
    return true, nil
end

function M.setUserRegexes(list)
    list = (type(list) == "table") and list or {}
    local out = {}
    for i = 1, #list do
        local v = _trim(list[i])
        if v ~= "" then out[#out + 1] = v end
    end
    _state.promptSpec.userRegexes = out
    _state.promptSpec.ts = _nowTs()
    _state.promptSpec.source = "dwprompt:set"
    _persistSaveBestEffort({ source = "dwprompt:set" })
    _emitUpdated({ source = "dwprompt:set" })
    return true, nil
end

function M.clearUserRegexes()
    _state.promptSpec.userRegexes = {}
    _state.promptSpec.ts = _nowTs()
    _state.promptSpec.source = "dwprompt:clear_regex"
    _persistSaveBestEffort({ source = "dwprompt:clear_regex" })
    _emitUpdated({ source = "dwprompt:clear_regex" })
    return true, nil
end

function M.resetAll()
    local p = _state.promptSpec
    p.ts = nil
    p.source = nil
    p.promptSpecRaw = nil
    p.lineCountMin = 0
    p.lineCountMax = 0
    p.userRegexes = {}
    p.derivedRegexes = {}
    _rebuildDerivedRegexes("resetAll")
    _persistSaveBestEffort({ source = "dwprompt:resetAll" })
    _emitUpdated({ source = "dwprompt:resetAll" })
    return true, nil
end

function M.notePromptSpecFromOutput(specText, meta)
    meta = (type(meta) == "table") and meta or {}
    specText = _safeString(specText)
    specText = specText:gsub("\r", "")
    specText = _trim(specText)

    if specText == "" then
        return false, "empty_spec"
    end

    local p = _state.promptSpec
    local oldNorm = _normalizeForCompare(p.promptSpecRaw or "")
    local newNorm = _normalizeForCompare(specText)

    if oldNorm ~= "" and oldNorm == newNorm then
        return false, "no_change"
    end

    p.promptSpecRaw = specText
    p.ts = _nowTs()
    p.source = tostring(meta.source or "prompt_output")

    _rebuildDerivedRegexes("notePromptSpecFromOutput")

    _persistSaveBestEffort({ source = p.source })
    _emitUpdated({ source = p.source })

    return true, "updated"
end

function M.getStatus()
    local p = _state.promptSpec
    return {
        serviceVersion = M.VERSION,
        configured = (M.isConfigured() == true),
        ts = p.ts,
        source = p.source,
        promptSpecRaw = p.promptSpecRaw,
        lineCountMin = p.lineCountMin,
        lineCountMax = p.lineCountMax,
        userRegexCount = (type(p.userRegexes) == "table") and #p.userRegexes or 0,
        derivedRegexCount = (type(p.derivedRegexes) == "table") and #p.derivedRegexes or 0,

        persist = {
            enabled = _state.persist.enabled,
            path = (select(1, _getPersistPathBestEffort())),
            lastLoadErr = _state.persist.lastLoadErr,
            lastSaveErr = _state.persist.lastSaveErr,
        },

        watcher = {
            enabled = _state.watcher.enabled,
            installed = _state.watcher.installed,
            triggerId = _state.watcher.triggerId,
            lastErr = _state.watcher.lastErr,
        },
    }
end

-- Passive watcher: learn prompt spec from MUD output when user runs 'prompt'.
-- IMPORTANT:
--   Use a broad line trigger + state machine (multi-line capable).
--   Do NOT rely on callback args (Mudlet provides line/matches globals).
local function _installPromptSpecWatcher()
    if _state.watcher.installed == true then
        return true, nil
    end
    if _state.watcher.enabled ~= true then
        return true, nil
    end
    if not _isFn("tempRegexTrigger") then
        _state.watcher.lastErr = "tempRegexTrigger unavailable"
        return false, _state.watcher.lastErr
    end

    local bufLines = nil
    local capturing = false
    local capCount = 0
    local CAP_MAX_LINES = 8

    _state.watcher.triggerId = tempRegexTrigger("^(.*)$", function()
        local raw = (type(_G.line) == "string") and _G.line or tostring(_G.line or "")
        local ln = M.normalizeLine(raw)

        if capturing ~= true then
            if ln ~= "" and ln:find("Your prompt is currently:", 1, true) then
                local spec = ln:match("^%s*Your prompt is currently:%s*(.*)%s*$")
                spec = _trim(spec or "")
                capturing = true
                capCount = 1
                bufLines = {}

                if spec ~= "" then
                    bufLines[#bufLines + 1] = spec
                end

                return
            end
            return
        end

        -- capturing == true:
        capCount = capCount + 1
        if capCount > CAP_MAX_LINES then
            capturing = false
            bufLines = nil
            return
        end

        -- Stop capture when the rendered prompt appears (do NOT include it in spec).
        if ln == "" or M.isPromptLineCandidate(ln) then
            local specText = ""
            if type(bufLines) == "table" and #bufLines > 0 then
                specText = table.concat(bufLines, "\n")
                specText = _trim(specText)
            end

            if specText ~= "" then
                local changed = M.notePromptSpecFromOutput(specText, { source = "prompt_output" })
                if changed then
                    if type(cecho) == "function" then
                        cecho("[DWKit Prompt] learned prompt spec (updated)\n")
                    end
                end
            end

            capturing = false
            bufLines = nil
            return
        end

        -- Continuation wrapped line: append
        if type(bufLines) ~= "table" then bufLines = {} end
        bufLines[#bufLines + 1] = ln
    end)

    if type(_state.watcher.triggerId) ~= "number" then
        _state.watcher.lastErr = "failed to install tempRegexTrigger"
        _state.watcher.installed = false
        _state.watcher.triggerId = nil
        return false, _state.watcher.lastErr
    end

    _state.watcher.installed = true
    _state.watcher.lastErr = nil
    return true, nil
end

function M.init()
    -- Load persisted state (best-effort)
    _persistLoadBestEffort()

    -- Ensure derived regexes exist (even if prompt unknown)
    _rebuildDerivedRegexes("init")

    -- Install passive watcher
    _installPromptSpecWatcher()

    return true, nil
end

-- Init on require (safe best-effort; does not send any commands)
pcall(function() M.init() end)

return M
