-- #########################################################################
-- Module Name : dwkit.services.prompt_detector_service
-- Owner       : Services
-- Version     : v2026-02-26B
-- Purpose     :
--   - Maintain per-profile prompt detection configuration for passive capture.
--   - Learn and persist prompt config from:
--       (A) 'prompt' command output ("Your prompt is currently: ...")  [manual]
--       (B) rendered prompt sequences observed passively in normal output  [passive]
--   - Provide prompt detection helpers for capture modules (eg roomfeed_capture).
-- Does NOT:
--   - Send any MUD commands (manual commands do that via command handlers).
--
-- Key behavior (v2026-02-26B):
--   - Baseline prompt heuristics are ALWAYS active, even if renderedSig/spec is learned.
--   - isPromptSequence() succeeds if ANY of:
--       * promptSpec-derived multi-line sequence matches
--       * rendered-learned multi-line sequence matches
--       * single-line baseline prompt line matches (eg Hp/Mp/Mv> style)
--   - This prevents a learned "<...>" signature from breaking other prompt styles.
--
-- Public API:
--   - getStatus(opts?) -> table
--   - getDebugRegexes() -> table
--   - isConfigured() -> boolean
--   - normalizeLine(line) -> string
--   - isPromptLineCandidate(lineClean) -> boolean
--   - isPromptSequence(tailLinesClean) -> boolean
--   - notePromptSpecFromOutput(specText, meta) -> boolean changed, string reason|nil
--   - noteRenderedPromptSequence(linesCleanOrRaw, meta) -> boolean changed, string reason|nil
--   - addUserRegex(pat) -> boolean ok, string err|nil
--   - setUserRegexes(list) -> boolean ok, string err|nil
--   - clearUserRegexes() -> boolean ok
--   - resetAll() -> boolean ok
--
-- Events Emitted:
--   - (optional) DWKit:Service:PromptDetector:Updated (best-effort; not required by current consumers)
-- Events Consumed:
--   - None (passive triggers are internal; no bus subscription required)
-- Persistence:
--   - File: <profile>/dwkit_prompt_spec.lua
--   - Schema: promptSpec.v1
--       { ts, promptSpecRaw, userRegexes, derivedRegexes, lineCountMin, lineCountMax,
--         renderedSig?, renderedSample? }  -- rendered* are optional extensions
-- Automation Policy:
--   - Passive capture only (trigger observes output; no timers; no sends).
-- Dependencies:
--   - dwkit.core.identity, dwkit.bus.event_bus (optional emit)
-- #########################################################################

local M = {}
M.VERSION = "v2026-02-26B"

local ID = require("dwkit.core.identity")
local BUS = require("dwkit.bus.event_bus")

M.EV_UPDATED = tostring(ID.eventPrefix or "DWKit:") .. "Service:PromptDetector:Updated"

local _state = {
    promptSpec = {
        ts = nil,
        source = nil,
        promptSpecRaw = nil, -- string (may include newlines if wrapped)

        -- Rendered prompt passive-learning (no 'prompt' command required):
        renderedSig = nil,   -- string signature derived from rendered prompt sequence
        renderedSample = {}, -- last accepted rendered prompt lines (normalized)

        -- Primary bounds (for status/debug). Multi-profile matching uses its own bounds.
        lineCountMin = 0,
        lineCountMax = 0,

        -- Bounds per profile:
        specLineCountMin = 0,
        specLineCountMax = 0,
        renderedLineCount = 0,

        -- User patterns (single-line candidates)
        userRegexes = {},

        -- Derived patterns:
        --   derivedRegexes: from promptSpecRaw (ordered sequence)
        --   renderedRegexes: from renderedSample (ordered sequence)
        --   baselineRegexes: always-on heuristics (single-line)
        derivedRegexes = {},
        renderedRegexes = {},
        baselineRegexes = {},
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

    -- Passive rendered-prompt drift detector (no gameplay sends):
    renderedWatch = {
        enabled = true,
        installed = false,
        triggerId = nil,
        lastErr = nil,

        tailMax = 10,
        tail = {},

        pendingSig = nil,
        pendingCount = 0,
        acceptAfter = 3, -- require N matching sequences before accepting drift
        lastSeenSig = nil,
        lastSeenTs = nil,
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
    s = s:gsub("%s+", " ")
    return _trim(s)
end

local function _stripAnsi(s)
    s = tostring(s or "")
    s = s:gsub("\r", "")
    s = s:gsub("\27%][^\7]*\7", "")
    s = s:gsub("\27%[[0-9;]*[%a]", "")
    s = s:gsub("\27", "")
    return s
end

local function _isWindows()
    local sep = package and package.config and package.config:sub(1, 1) or "/"
    return sep == "\\"
end

local function _escapeLuaPatternForGsubLiteral(s)
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

    dir = dir:gsub("\\", "/")

    local profile = nil
    if type(getProfileName) == "function" then
        local ok, pn = pcall(getProfileName)
        if ok and type(pn) == "string" and pn ~= "" then
            profile = pn
        end
    end

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
    path = _normalizeProfileDir(path)
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

        if remainder:match("^%a%:/") then
            prefix = remainder:sub(1, 3)
            remainder = remainder:sub(4)
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
    lines[#lines + 1] = "  renderedSig = " .. _quoteLuaString(p.renderedSig or "") .. ","

    do
        local rs = (type(p.renderedSample) == "table") and p.renderedSample or {}
        lines[#lines + 1] = "  renderedSample = {"
        for i = 1, #rs do
            lines[#lines + 1] = "    " .. _quoteLuaString(rs[i] or "") .. ","
        end
        lines[#lines + 1] = "  },"
    end

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

    -- NOTE: baseline/rendered regexes are derived; we don't persist them to keep schema stable.

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

    local rsig = tostring(data.renderedSig or "")
    p.renderedSig = (rsig ~= "") and rsig or nil
    p.renderedSample = (type(data.renderedSample) == "table") and data.renderedSample or {}

    p.lineCountMin = tonumber(data.lineCountMin or 0) or 0
    p.lineCountMax = tonumber(data.lineCountMax or 0) or 0
    p.userRegexes = (type(data.userRegexes) == "table") and data.userRegexes or {}
    p.derivedRegexes = (type(data.derivedRegexes) == "table") and data.derivedRegexes or {}

    _state.persist.lastLoadErr = nil
    return true, nil
end

local function _escapeLuaPatternLiteral(s)
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

local function _removePromptColorCodes(spec)
    spec = tostring(spec or "")
    spec = spec:gsub("&[%a]", "")
    return spec
end

local function _stripConditionals(spec)
    spec = tostring(spec or "")
    spec = spec:gsub("%%C[%a]", "%%C")
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
        minLines = 1
        maxLines = rCount + 1
    end

    return minLines, maxLines
end

local function _patternForPromptSpecLine(lineSpec)
    local spec = tostring(lineSpec or "")
    spec = _removePromptColorCodes(spec)
    spec = _stripConditionals(spec)

    spec = _escapeLuaPatternLiteral(spec)

    local function rep(code, patReplacement)
        spec = spec:gsub("%%%%" .. code, patReplacement)
    end

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

    rep("z", ".*")
    rep("D", ".*")

    rep("o", ".*")
    rep("t", ".*")
    rep("T", ".*")

    rep("r", ".*")

    spec = spec:gsub("%%%%[%a]", ".*")

    spec = spec:gsub("%s+", "%%s*")

    return "^%s*" .. spec .. "%s*$"
end

local function _patternFromRenderedLine(lineClean)
    local s = tostring(lineClean or "")
    s = s:gsub("\r", "")
    s = _trim(s)
    if s == "" then return nil end

    s = _escapeLuaPatternLiteral(s)
    s = s:gsub("%d+", "%%d+")
    s = s:gsub("%s+", "%%s*")

    return "^%s*" .. s .. "%s*$"
end

local function _renderedSigFromLines(linesClean)
    linesClean = (type(linesClean) == "table") and linesClean or {}
    local parts = {}
    for i = 1, #linesClean do
        local ln = _collapseSpaces(_trim(tostring(linesClean[i] or "")))
        if ln ~= "" then
            ln = ln:gsub("%d+", "<N>")
            ln = ln:gsub("%s+", " ")
            parts[#parts + 1] = ln
        end
    end
    if #parts == 0 then return "" end
    return table.concat(parts, " | ")
end

local function _rebuildBaselineRegexes()
    local p = _state.promptSpec
    p.baselineRegexes = {}

    -- Baseline prompt heuristics (always on):
    --  - <...> prompts (common)
    --  - Hp/Mp/Mv> style prompts (includes digits + parenthesized max, flexible text before it)
    p.baselineRegexes[#p.baselineRegexes + 1] = "^%s*%b<>%s*$"
    p.baselineRegexes[#p.baselineRegexes + 1] = "^%s*.*%d+%(%d+%)Hp%s+%d+%(%d+%)Mp%s+%d+%(%d+%)Mv>%s*$"
end

local function _rebuildSpecDerivedRegexes()
    local p = _state.promptSpec
    p.derivedRegexes = {}
    p.specLineCountMin = 0
    p.specLineCountMax = 0

    if type(p.promptSpecRaw) ~= "string" or p.promptSpecRaw == "" then
        return
    end

    local spec = p.promptSpecRaw:gsub("\r", "")
    local minL, maxL = _deriveLineCountBoundsFromSpec(spec)
    p.specLineCountMin = minL
    p.specLineCountMax = maxL

    local collapsed = spec:gsub("\n", " ")
    local parts = {}
    local last = 1
    local needle = "%r"

    while true do
        local s1, e1 = collapsed:find(needle, last, true)
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
        p.specLineCountMin = 0
        p.specLineCountMax = 0
    end
end

local function _rebuildRenderedRegexes()
    local p = _state.promptSpec
    p.renderedRegexes = {}
    p.renderedLineCount = 0

    if type(p.renderedSig) ~= "string" or p.renderedSig == "" then
        return
    end
    if type(p.renderedSample) ~= "table" or #p.renderedSample == 0 then
        return
    end

    p.renderedLineCount = #p.renderedSample
    for i = 1, #p.renderedSample do
        local pat = _patternFromRenderedLine(p.renderedSample[i])
        if pat and pat ~= "" then
            p.renderedRegexes[#p.renderedRegexes + 1] = pat
        end
    end

    if #p.renderedRegexes == 0 then
        p.renderedRegexes = {}
        p.renderedLineCount = 0
    end
end

local function _recomputePrimaryBounds()
    local p = _state.promptSpec

    if type(p.promptSpecRaw) == "string" and p.promptSpecRaw ~= "" and #p.derivedRegexes > 0 then
        p.lineCountMin = tonumber(p.specLineCountMin or 1) or 1
        p.lineCountMax = tonumber(p.specLineCountMax or p.lineCountMin) or p.lineCountMin
        return
    end

    if type(p.renderedSig) == "string" and p.renderedSig ~= "" and #p.renderedRegexes > 0 then
        p.lineCountMin = tonumber(p.renderedLineCount or 1) or 1
        p.lineCountMax = tonumber(p.renderedLineCount or p.lineCountMin) or p.lineCountMin
        return
    end

    p.lineCountMin = 1
    p.lineCountMax = 1
end

local function _rebuildDerivedRegexes(reason)
    _rebuildBaselineRegexes()
    _rebuildSpecDerivedRegexes()
    _rebuildRenderedRegexes()
    _recomputePrimaryBounds()
    if reason then
        -- no output
    end
end

local function _normalizeForCompare(specText)
    specText = tostring(specText or "")
    specText = specText:gsub("\r", "")
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
    if type(p.renderedSig) == "string" and p.renderedSig ~= "" then
        return true
    end
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
    addAll(p.renderedRegexes)
    addAll(p.baselineRegexes)

    return out
end

function M.getDebugRegexes()
    local p = _state.promptSpec
    return {
        userRegexes = (type(p.userRegexes) == "table") and p.userRegexes or {},
        derivedRegexes = (type(p.derivedRegexes) == "table") and p.derivedRegexes or {},
        renderedRegexes = (type(p.renderedRegexes) == "table") and p.renderedRegexes or {},
        baselineRegexes = (type(p.baselineRegexes) == "table") and p.baselineRegexes or {},
        allRegexes = _allRegexes(),

        lineCountMin = tonumber(p.lineCountMin or 0) or 0,
        lineCountMax = tonumber(p.lineCountMax or 0) or 0,
        specLineCountMin = tonumber(p.specLineCountMin or 0) or 0,
        specLineCountMax = tonumber(p.specLineCountMax or 0) or 0,
        renderedLineCount = tonumber(p.renderedLineCount or 0) or 0,

        promptSpecRaw = p.promptSpecRaw,
        renderedSig = p.renderedSig,
        renderedSample = (type(p.renderedSample) == "table") and p.renderedSample or {},
        source = p.source,
        ts = p.ts,
    }
end

function M.isPromptLineCandidate(lineClean)
    local ln = tostring(lineClean or "")
    if ln == "" then return false end

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

local function _matchesSequenceOrdered(tailLinesClean, regexes, minL, maxL)
    tailLinesClean = (type(tailLinesClean) == "table") and tailLinesClean or {}
    regexes = (type(regexes) == "table") and regexes or {}

    if #regexes == 0 then
        return nil
    end

    minL = tonumber(minL or 0) or 0
    maxL = tonumber(maxL or 0) or 0
    if minL <= 0 then minL = 1 end
    if maxL <= 0 then maxL = 1 end
    if maxL < minL then maxL = minL end
    if maxL > #regexes then maxL = #regexes end
    if minL > #regexes then return nil end

    local function matchesN(n)
        if n <= 0 then return false end
        if #tailLinesClean < n then return false end
        if #regexes < n then return false end

        local startIdx = #tailLinesClean - n + 1
        for i = 1, n do
            local ln = tostring(tailLinesClean[startIdx + i - 1] or "")
            local pat = tostring(regexes[i] or "")
            if pat == "" then return false end
            if ln:match(pat) == nil then
                return false
            end
        end
        return true
    end

    for n = maxL, minL, -1 do
        if matchesN(n) then
            return n
        end
    end

    return nil
end

local function _matchesAnySingleLine(tailLinesClean, pats)
    tailLinesClean = (type(tailLinesClean) == "table") and tailLinesClean or {}
    pats = (type(pats) == "table") and pats or {}
    if #tailLinesClean < 1 then return false end
    local ln = tostring(tailLinesClean[#tailLinesClean] or "")
    if ln == "" then return false end

    for i = 1, #pats do
        local pat = tostring(pats[i] or "")
        if pat ~= "" then
            local ok, m = pcall(function()
                return (ln:match(pat) ~= nil)
            end)
            if ok and m then
                return true
            end
        end
    end

    return false
end

local function _matchPromptSequenceN(tailLinesClean)
    local p = _state.promptSpec

    -- Ensure regexes exist even if early boot
    if type(p.baselineRegexes) ~= "table" or #p.baselineRegexes == 0 then
        _rebuildDerivedRegexes("sequence:init_baseline")
    end

    -- A) Spec-derived multi-line sequence (strongest)
    if type(p.promptSpecRaw) == "string" and p.promptSpecRaw ~= "" and type(p.derivedRegexes) == "table" and #p.derivedRegexes > 0 then
        local nSpec = _matchesSequenceOrdered(tailLinesClean, p.derivedRegexes, p.specLineCountMin, p.specLineCountMax)
        if nSpec then return nSpec end
    end

    -- B) Rendered-learned multi-line sequence
    if type(p.renderedSig) == "string" and p.renderedSig ~= "" and type(p.renderedRegexes) == "table" and #p.renderedRegexes > 0 then
        local nR = _matchesSequenceOrdered(tailLinesClean, p.renderedRegexes, p.renderedLineCount, p.renderedLineCount)
        if nR then return nR end
    end

    -- C) Single-line fallback: last line matches baseline/user/spec/rendered prompt line candidates.
    -- This is what allows "Opp/Tank" 2-line prompts to finalize on the Hp/Mp/Mv> line.
    local singlePats = {}
    local function add(list)
        list = (type(list) == "table") and list or {}
        for i = 1, #list do
            local v = tostring(list[i] or "")
            if v ~= "" then singlePats[#singlePats + 1] = v end
        end
    end
    add(p.baselineRegexes)
    add(p.userRegexes)
    add(p.renderedRegexes)
    add(p.derivedRegexes)

    if _matchesAnySingleLine(tailLinesClean, singlePats) then
        return 1
    end

    return nil
end

function M.isPromptSequence(tailLinesClean)
    local n = _matchPromptSequenceN(tailLinesClean)
    return (n ~= nil) and true or false
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
    p.renderedSig = nil
    p.renderedSample = {}

    p.lineCountMin = 0
    p.lineCountMax = 0
    p.specLineCountMin = 0
    p.specLineCountMax = 0
    p.renderedLineCount = 0

    p.userRegexes = {}
    p.derivedRegexes = {}
    p.renderedRegexes = {}
    p.baselineRegexes = {}

    _state.renderedWatch.pendingSig = nil
    _state.renderedWatch.pendingCount = 0
    _state.renderedWatch.lastSeenSig = nil
    _state.renderedWatch.lastSeenTs = nil

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

    _state.renderedWatch.pendingSig = nil
    _state.renderedWatch.pendingCount = 0

    _rebuildDerivedRegexes("notePromptSpecFromOutput")

    _persistSaveBestEffort({ source = p.source })
    _emitUpdated({ source = p.source })

    return true, "updated"
end

function M.noteRenderedPromptSequence(linesCleanOrRaw, meta)
    meta = (type(meta) == "table") and meta or {}
    linesCleanOrRaw = (type(linesCleanOrRaw) == "table") and linesCleanOrRaw or {}

    local clean = {}
    for i = 1, #linesCleanOrRaw do
        local ln = tostring(linesCleanOrRaw[i] or "")
        ln = M.normalizeLine(ln)
        ln = _collapseSpaces(ln)
        if ln ~= "" then
            clean[#clean + 1] = ln
        end
    end

    if #clean == 0 then
        return false, "empty_rendered"
    end

    local sig = _renderedSigFromLines(clean)
    sig = tostring(sig or "")
    if sig == "" then
        return false, "empty_sig"
    end

    local rw = _state.renderedWatch
    rw.lastSeenSig = sig
    rw.lastSeenTs = _nowTs()

    local p = _state.promptSpec
    local currentSig = tostring(p.renderedSig or "")

    if currentSig ~= "" and currentSig == sig then
        rw.pendingSig = nil
        rw.pendingCount = 0
        return false, "no_change"
    end

    if rw.pendingSig ~= sig then
        rw.pendingSig = sig
        rw.pendingCount = 1
        return false, "pending(1)"
    end

    rw.pendingCount = (tonumber(rw.pendingCount or 0) or 0) + 1
    local need = tonumber(rw.acceptAfter or 3) or 3
    if need < 2 then need = 2 end
    if need > 8 then need = 8 end

    if rw.pendingCount < need then
        return false, "pending(" .. tostring(rw.pendingCount) .. "/" .. tostring(need) .. ")"
    end

    p.renderedSig = sig
    p.renderedSample = clean
    p.ts = _nowTs()
    p.source = tostring(meta.source or "rendered_output")

    _rebuildDerivedRegexes("noteRenderedPromptSequence")

    rw.pendingSig = nil
    rw.pendingCount = 0

    _persistSaveBestEffort({ source = p.source })
    _emitUpdated({ source = p.source })

    return true, "updated"
end

function M.getStatus(opts)
    opts = (type(opts) == "table") and opts or {}
    local p = _state.promptSpec
    local out = {
        serviceVersion = M.VERSION,
        configured = (M.isConfigured() == true),
        ts = p.ts,
        source = p.source,
        promptSpecRaw = p.promptSpecRaw,
        renderedSig = p.renderedSig,
        renderedSampleLines = (type(p.renderedSample) == "table") and #p.renderedSample or 0,

        lineCountMin = p.lineCountMin,
        lineCountMax = p.lineCountMax,
        specLineCountMin = p.specLineCountMin,
        specLineCountMax = p.specLineCountMax,
        renderedLineCount = p.renderedLineCount,

        userRegexCount = (type(p.userRegexes) == "table") and #p.userRegexes or 0,
        derivedRegexCount = (type(p.derivedRegexes) == "table") and #p.derivedRegexes or 0,
        renderedRegexCount = (type(p.renderedRegexes) == "table") and #p.renderedRegexes or 0,
        baselineRegexCount = (type(p.baselineRegexes) == "table") and #p.baselineRegexes or 0,

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

        renderedWatch = {
            enabled = _state.renderedWatch.enabled,
            installed = _state.renderedWatch.installed,
            triggerId = _state.renderedWatch.triggerId,
            lastErr = _state.renderedWatch.lastErr,
            tailMax = _state.renderedWatch.tailMax,
            pendingSig = _state.renderedWatch.pendingSig,
            pendingCount = _state.renderedWatch.pendingCount,
            acceptAfter = _state.renderedWatch.acceptAfter,
            lastSeenSig = _state.renderedWatch.lastSeenSig,
            lastSeenTs = _state.renderedWatch.lastSeenTs,
        },
    }

    if opts.includeRegexes == true then
        out.userRegexes = (type(p.userRegexes) == "table") and p.userRegexes or {}
        out.derivedRegexes = (type(p.derivedRegexes) == "table") and p.derivedRegexes or {}
        out.renderedRegexes = (type(p.renderedRegexes) == "table") and p.renderedRegexes or {}
        out.baselineRegexes = (type(p.baselineRegexes) == "table") and p.baselineRegexes or {}
    end

    return out
end

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
    local CAP_MAX_LINES = 12

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

        capCount = capCount + 1
        if capCount > CAP_MAX_LINES then
            capturing = false
            bufLines = nil
            return
        end

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

local function _installRenderedPromptWatcher()
    if _state.renderedWatch.installed == true then
        return true, nil
    end
    if _state.renderedWatch.enabled ~= true then
        return true, nil
    end
    if not _isFn("tempRegexTrigger") then
        _state.renderedWatch.lastErr = "tempRegexTrigger unavailable"
        return false, _state.renderedWatch.lastErr
    end

    _state.renderedWatch.triggerId = tempRegexTrigger("^(.*)$", function()
        local raw = (type(_G.line) == "string") and _G.line or tostring(_G.line or "")
        local ln = M.normalizeLine(raw)
        ln = _collapseSpaces(ln)

        if ln == "" then
            return
        end

        if ln:find("Your prompt is currently:", 1, true) then
            return
        end

        local rw = _state.renderedWatch
        rw.tail = (type(rw.tail) == "table") and rw.tail or {}
        rw.tail[#rw.tail + 1] = ln

        local maxN = tonumber(rw.tailMax or 10) or 10
        if maxN < 4 then maxN = 4 end
        if maxN > 24 then maxN = 24 end
        while #rw.tail > maxN do
            table.remove(rw.tail, 1)
        end

        if type(_state.promptSpec.baselineRegexes) ~= "table" or #_state.promptSpec.baselineRegexes == 0 then
            _rebuildDerivedRegexes("renderedWatch:init_derived")
        end

        local n = _matchPromptSequenceN(rw.tail)
        if not n then
            return
        end

        local seq = {}
        local startIdx = #rw.tail - n + 1
        for i = 1, n do
            seq[#seq + 1] = tostring(rw.tail[startIdx + i - 1] or "")
        end

        M.noteRenderedPromptSequence(seq, { source = "rendered_output" })
    end)

    if type(_state.renderedWatch.triggerId) ~= "number" then
        _state.renderedWatch.lastErr = "failed to install tempRegexTrigger"
        _state.renderedWatch.installed = false
        _state.renderedWatch.triggerId = nil
        return false, _state.renderedWatch.lastErr
    end

    _state.renderedWatch.installed = true
    _state.renderedWatch.lastErr = nil
    return true, nil
end

function M.init()
    _persistLoadBestEffort()
    _rebuildDerivedRegexes("init")
    _installPromptSpecWatcher()
    _installRenderedPromptWatcher()
    return true, nil
end

pcall(function() M.init() end)

return M
