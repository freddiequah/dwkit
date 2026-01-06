-- #########################################################################
-- Module Name : dwkit.bus.command_registry
-- Owner       : Bus
-- Version     : v2026-01-06B
-- Purpose     :
--   - Single source of truth for user-facing commands (kit + gameplay wrappers).
--   - Provides SAFE runtime listing + help output derived from the same registry data.
--   - DOES NOT send gameplay commands (registry only).
--   - DOES NOT start timers or automation.
--
-- Public API  :
--   - listAll(opts?)  -> table list
--   - listSafe(opts?) -> table list
--   - listGame(opts?) -> table list
--   - help(name, opts?) -> boolean ok, table|nil cmdOrNil, string|nil errOrNil
--   - register(def) -> boolean ok, string|nil errOrNil   (runtime-only, not persisted)
--   - getAll() -> table copy (name -> def)
--
-- Events Emitted   : None
-- Events Consumed  : None
-- Persistence      : None
-- Automation Policy: Manual only
-- Dependencies     : None
-- #########################################################################

local M = {}

-- -------------------------
-- Output helper (copy/paste friendly)
-- -------------------------
local function _out(line)
    line = tostring(line or "")
    if type(cecho) == "function" then
        cecho(line .. "\n")
    elseif type(echo) == "function" then
        echo(line .. "\n")
    else
        print(line)
    end
end

-- -------------------------
-- Registry (single source of truth)
-- -------------------------
local REG = {
    version = "v2026-01-06B",
    commands = {
        dwinfo = {
            command     = "dwinfo",
            aliases     = {},
            ownerModule = "dwkit.core.runtime_baseline",
            description = "Prints runtime baseline info (Lua + Mudlet version) for verification and support.",
            syntax      = "lua DWKit.core.runtimeBaseline.printInfo()",
            examples    = {
                "lua DWKit.core.runtimeBaseline.printInfo()",
            },
            safety      = "SAFE",   -- SAFE | COMBAT-SAFE | NOT SAFE
            mode        = "manual", -- manual | opt-in | auto
            sendsToGame = false,
            notes       = {
                "Dev helper invoked via Mudlet input line. Will be wired into command system later.",
            },
        },

        dwtest = {
            command     = "dwtest",
            aliases     = {},
            ownerModule = "dwkit.tests.self_test_runner",
            description = "Runs DWKit self-test runner (smoke checks + compatibility baseline output).",
            syntax      = "lua DWKit.test.run()",
            examples    = {
                "lua DWKit.test.run()",
            },
            safety      = "SAFE",
            mode        = "manual",
            sendsToGame = false,
            notes       = {
                "Requires loader init to have run (so DWKit.test.run is attached).",
                "If missing, check DWKit.test._selfTestLoadError.",
            },
        },

        dwcommands = {
            command     = "dwcommands",
            aliases     = {},
            ownerModule = "dwkit.services.command_aliases",
            description = "Lists registered DWKit commands (ALL, SAFE, or GAME).",
            syntax      = "dwcommands [safe|game]",
            examples    = {
                "dwcommands",
                "dwcommands safe",
                "dwcommands game",
            },
            safety      = "SAFE",
            mode        = "manual",
            sendsToGame = false,
            notes       = {
                "Implemented as a Mudlet alias (local only).",
                "Backed by DWKit.cmd.listAll/listSafe/listGame.",
            },
        },

        dwhelp = {
            command     = "dwhelp",
            aliases     = {},
            ownerModule = "dwkit.services.command_aliases",
            description = "Shows detailed help for one DWKit command.",
            syntax      = "dwhelp <cmd>",
            examples    = {
                "dwhelp dwtest",
                "dwhelp dwinfo",
            },
            safety      = "SAFE",
            mode        = "manual",
            sendsToGame = false,
            notes       = {
                "Implemented as a Mudlet alias (local only).",
                "Backed by DWKit.cmd.help(name).",
            },
        },
    }
}

-- -------------------------
-- Validation (minimal, strict)
-- -------------------------
local function _isNonEmptyString(s) return type(s) == "string" and s ~= "" end

local function _validateDef(def)
    if type(def) ~= "table" then return false, "def must be a table" end
    if not _isNonEmptyString(def.command) then return false, "missing/invalid: command" end
    if not _isNonEmptyString(def.ownerModule) then return false, "missing/invalid: ownerModule" end
    if not _isNonEmptyString(def.description) then return false, "missing/invalid: description" end
    if not _isNonEmptyString(def.syntax) then return false, "missing/invalid: syntax" end
    if not _isNonEmptyString(def.safety) then return false, "missing/invalid: safety" end
    if not _isNonEmptyString(def.mode) then return false, "missing/invalid: mode" end

    if type(def.aliases) ~= "table" then return false, "invalid: aliases must be a table" end
    if type(def.examples) ~= "table" then return false, "invalid: examples must be a table" end

    if type(def.sendsToGame) ~= "boolean" then return false, "invalid: sendsToGame must be boolean" end
    if def.sendsToGame then
        if not _isNonEmptyString(def.underlyingGameCommand) then
            return false, "missing/invalid: underlyingGameCommand (required when sendsToGame=true)"
        end
        if not _isNonEmptyString(def.sideEffects) then
            return false, "missing/invalid: sideEffects (required when sendsToGame=true)"
        end
    end

    return true, nil
end

-- -------------------------
-- Safe copy helpers (no shared mutable state)
-- -------------------------
local function _shallowCopy(t)
    local out = {}
    for k, v in pairs(t) do out[k] = v end
    return out
end

local function _copyDef(def)
    local c    = _shallowCopy(def)
    c.aliases  = _shallowCopy(def.aliases or {})
    c.examples = _shallowCopy(def.examples or {})
    c.notes    = _shallowCopy(def.notes or {})
    return c
end

local function _collectList(filterFn)
    local list = {}
    for _, def in pairs(REG.commands) do
        if not filterFn or filterFn(def) then
            table.insert(list, _copyDef(def))
        end
    end
    table.sort(list, function(a, b) return tostring(a.command) < tostring(b.command) end)
    return list
end

-- -------------------------
-- Public API
-- -------------------------
function M.getAll()
    local out = {}
    for name, def in pairs(REG.commands) do
        out[name] = _copyDef(def)
    end
    return out
end

local function _printList(title, list)
    _out("[DWKit Commands] " .. title .. " (source: dwkit.bus.command_registry " .. REG.version .. ")")
    if #list == 0 then
        _out("  (none)")
        return
    end
    for _, def in ipairs(list) do
        _out(string.format("  - %s  | %s  | %s  | %s",
            tostring(def.command),
            tostring(def.ownerModule),
            tostring(def.safety),
            tostring(def.description)
        ))
    end
end

function M.listAll(opts)
    opts = opts or {}
    local list = _collectList(nil)
    if not opts.quiet then _printList("ALL", list) end
    return list
end

function M.listSafe(opts)
    opts = opts or {}
    local list = _collectList(function(def) return def.sendsToGame == false end)
    if not opts.quiet then _printList("SAFE", list) end
    return list
end

function M.listGame(opts)
    opts = opts or {}
    local list = _collectList(function(def) return def.sendsToGame == true end)
    if not opts.quiet then _printList("GAME", list) end
    return list
end

function M.help(name, opts)
    opts = opts or {}
    if not _isNonEmptyString(name) then
        return false, nil, "help(name): name must be a non-empty string"
    end

    local def = REG.commands[name]
    if not def then
        return false, nil, "Unknown command: " .. tostring(name)
    end

    local c = _copyDef(def)

    if not opts.quiet then
        _out("[DWKit Help] " .. tostring(c.command) .. " (source: dwkit.bus.command_registry " .. REG.version .. ")")
        _out("  Owner   : " .. tostring(c.ownerModule))
        _out("  Safety  : " .. tostring(c.safety))
        _out("  Mode    : " .. tostring(c.mode))
        _out("  SendsToGame: " .. (c.sendsToGame and "YES" or "NO"))
        _out("  Desc    : " .. tostring(c.description))
        _out("  Syntax  : " .. tostring(c.syntax))
        if c.aliases and #c.aliases > 0 then
            _out("  Aliases : " .. table.concat(c.aliases, ", "))
        else
            _out("  Aliases : (none)")
        end
        if c.examples and #c.examples > 0 then
            _out("  Examples:")
            for _, ex in ipairs(c.examples) do _out("    - " .. tostring(ex)) end
        end
        if c.sendsToGame then
            _out("  UnderlyingGameCommand: " .. tostring(c.underlyingGameCommand))
            _out("  SideEffects          : " .. tostring(c.sideEffects))
            if _isNonEmptyString(c.rateLimit) then
                _out("  RateLimit            : " .. tostring(c.rateLimit))
            end
            if _isNonEmptyString(c.wrapperOf) then
                _out("  WrapperOf            : " .. tostring(c.wrapperOf))
            end
        end
        if c.notes and #c.notes > 0 then
            _out("  Notes:")
            for _, n in ipairs(c.notes) do _out("    - " .. tostring(n)) end
        end
    end

    return true, c, nil
end

-- Runtime-only registration (NOT persisted)
function M.register(def)
    local ok, err = _validateDef(def)
    if not ok then return false, err end

    local name = def.command
    if REG.commands[name] then
        return false, "Command already exists: " .. tostring(name)
    end

    REG.commands[name] = _copyDef(def)
    return true, nil
end

return M
