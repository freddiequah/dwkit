-- #########################################################################
-- Module Name : dwkit.bus.command_registry
-- Owner       : Bus
-- Version     : v2026-01-14D
-- Purpose     :
--   - Single source of truth for user-facing commands (kit + gameplay wrappers).
--   - Provides SAFE runtime listing + help output derived from the same registry data.
--   - Provides Markdown export derived from the same registry data (docs sync helper).
--   - DOES NOT send gameplay commands (registry only).
--   - DOES NOT start timers or automation.
--   - Gameplay wrappers (sendsToGame=true) MUST declare:
--       - underlyingGameCommand
--       - sideEffects
--
-- Public API  :
--   - listAll(opts?)  -> table list
--   - listSafe(opts?) -> table list
--   - listGame(opts?) -> table list
--   - help(name, opts?) -> boolean ok, table|nil cmdOrNil, string|nil errOrNil
--   - register(def) -> boolean ok, string|nil errOrNil   (runtime-only, not persisted)
--   - getAll() -> table copy (name -> def)
--   - getRegistryVersion() -> string   (docs registry version, e.g. v2.9)
--   - getModuleVersion()   -> string   (code module version tag)
--   - toMarkdown(opts?) -> string   (docs copy helper; SAFE)
--   - validateAll(opts?) -> boolean pass, table issues
--     opts:
--       - strict: boolean (default true)
--       - requireDescription: boolean (default true)
--   - count() -> number   (SAFE, no output)
--   - has(name) -> boolean (SAFE, no output)
--
-- Events Emitted   : None
-- Events Consumed  : None
-- Persistence      : None
-- Automation Policy: Manual only
-- Dependencies     : None
-- #########################################################################

local M = {}

M.VERSION = "v2026-01-14D"

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
-- Notes:
-- - REG.version mirrors docs/Command_Registry_v1.0.md "## Version"
-- - M.VERSION is the code module version tag (calendar style)
-- -------------------------
local REG = {
    version = "v2.9",
    moduleVersion = M.VERSION,
    commands = {
        dwid = {
            command     = "dwid",
            aliases     = {},
            ownerModule = "dwkit.core.identity",
            description = "Prints canonical DWKit identity (packageId/eventPrefix/data folder/tag style).",
            syntax      = "dwid",
            examples    = {
                "dwid",
            },
            safety      = "SAFE",
            mode        = "manual",
            sendsToGame = false,
            notes       = {
                "Typed alias implemented by dwkit.services.command_aliases.",
                "Prints the same locked identity fields as shown in dwtest.",
            },
        },

        dwinfo = {
            command     = "dwinfo",
            aliases     = {},
            ownerModule = "dwkit.core.runtime_baseline",
            description = "Prints runtime baseline info (Lua + Mudlet version) for verification and support.",
            syntax      = "dwinfo  (or: lua DWKit.core.runtimeBaseline.printInfo())",
            examples    = {
                "dwinfo",
                "lua DWKit.core.runtimeBaseline.printInfo()",
            },
            safety      = "SAFE",
            mode        = "manual",
            sendsToGame = false,
            notes       = {
                "Typed alias implemented by dwkit.services.command_aliases.",
                "Dev helper also works via Mudlet input line with lua prefix.",
            },
        },

        dwtest = {
            command     = "dwtest",
            aliases     = {},
            ownerModule = "dwkit.tests.self_test_runner",
            description = "Runs DWKit self-test runner (smoke checks + compatibility baseline output).",
            syntax      =
            "dwtest  (or: lua DWKit.test.run())  (quiet: lua local T=require(\"dwkit.tests.self_test_runner\"); T.run({quiet=true}))",
            examples    = {
                "dwtest",
                "lua DWKit.test.run()",
                "lua local T=require(\"dwkit.tests.self_test_runner\"); T.run({quiet=true})",
            },
            safety      = "SAFE",
            mode        = "manual",
            sendsToGame = false,
            notes       = {
                "Typed alias implemented by dwkit.services.command_aliases.",
                "Requires loader init to have run (so DWKit.test.run is attached).",
                "If missing, check DWKit.test._selfTestLoadError.",
                "Quiet mode MUST avoid full registry listing output and prefer count-only registry checks (no list spam).",
            },
        },

        dwversion = {
            command     = "dwversion",
            aliases     = {},
            ownerModule = "dwkit.services.command_aliases",
            description = "Prints consolidated DWKit module versions + runtime baseline (SAFE diagnostics).",
            syntax      = "dwversion",
            examples    = {
                "dwversion",
            },
            safety      = "SAFE",
            mode        = "manual",
            sendsToGame = false,
            notes       = {
                "Typed alias implemented by dwkit.services.command_aliases.",
                "Prints identity/runtimeBaseline/self_test_runner/command registry versions where available.",
                "Also prints eventRegistry/eventBus versions when present.",
            },
        },

        dwdiag = {
            command     = "dwdiag",
            aliases     = {},
            ownerModule = "dwkit.services.command_aliases",
            description = "Prints a one-shot diagnostic bundle (dwversion + dwboot + dwservices + event diag status).",
            syntax      = "dwdiag",
            examples    = {
                "dwdiag",
            },
            safety      = "SAFE",
            mode        = "manual",
            sendsToGame = false,
            notes       = {
                "Intended for copy/paste into issues or chat handovers.",
                "MUST remain SAFE and manual-only (no timers, no auto-tap enable).",
                "Implementation should call existing SAFE printers and keep output bounded.",
            },
        },

        dwevents = {
            command     = "dwevents",
            aliases     = {},
            ownerModule = "dwkit.services.command_aliases",
            description = "Lists registered DWKit events (SAFE) or prints Markdown export (SAFE).",
            syntax      = "dwevents [md]",
            examples    = {
                "dwevents",
                "dwevents md",
            },
            safety      = "SAFE",
            mode        = "manual",
            sendsToGame = false,
            notes       = {
                "Typed alias implemented by dwkit.services.command_aliases.",
                "Backed by DWKit.bus.eventRegistry.listAll().",
                "Markdown export is backed by DWKit.bus.eventRegistry.toMarkdown().",
            },
        },

        dwevent = {
            command     = "dwevent",
            aliases     = {},
            ownerModule = "dwkit.services.command_aliases",
            description = "Shows detailed help for one DWKit event (SAFE).",
            syntax      = "dwevent <EventName>",
            examples    = {
                "dwevent DWKit:Boot:Ready",
            },
            safety      = "SAFE",
            mode        = "manual",
            sendsToGame = false,
            notes       = {
                "Typed alias implemented by dwkit.services.command_aliases.",
                "Backed by DWKit.bus.eventRegistry.help(eventName).",
                "EventName must be the full registered name (must start with DWKit:).",
            },
        },

        dweventtap = {
            command     = "dweventtap",
            aliases     = {},
            ownerModule = "dwkit.services.command_aliases",
            description =
            "Controls a SAFE event bus tap (observe all events) and a bounded in-memory log (SAFE diagnostics).",
            syntax      = "dweventtap [on|off|status|show|clear] [n]",
            examples    = {
                "dweventtap status",
                "dweventtap on",
                "dweventtap show 10",
                "dweventtap clear",
                "dweventtap off",
            },
            safety      = "SAFE",
            mode        = "manual",
            sendsToGame = false,
            notes       = {
                "Implemented as a Mudlet alias (local only).",
                "Backed by DWKit.bus.eventBus.tapOn/tapOff (best-effort, SAFE).",
                "Tap does not change delivery semantics for normal subscribers.",
                "Log output is bounded; default show prints last 10 entries.",
            },
        },

        dweventsub = {
            command     = "dweventsub",
            aliases     = {},
            ownerModule = "dwkit.services.command_aliases",
            description =
            "Subscribes (SAFE) to one DWKit event and records occurrences into the bounded log (SAFE diagnostics).",
            syntax      = "dweventsub <EventName>",
            examples    = {
                "dweventsub DWKit:Service:Presence:Updated",
                "dweventsub DWKit:Boot:Ready",
            },
            safety      = "SAFE",
            mode        = "manual",
            sendsToGame = false,
            notes       = {
                "Implemented as a Mudlet alias (local only).",
                "Backed by DWKit.bus.eventBus.on(eventName, fn).",
                "EventName must be registered and must start with DWKit:.",
                "Use dweventlog to inspect recorded payloads.",
            },
        },

        dweventunsub = {
            command     = "dweventunsub",
            aliases     = {},
            ownerModule = "dwkit.services.command_aliases",
            description = "Unsubscribes (SAFE) from one DWKit event or all subscriptions (SAFE diagnostics).",
            syntax      = "dweventunsub <EventName|all>",
            examples    = {
                "dweventunsub DWKit:Service:Presence:Updated",
                "dweventunsub all",
            },
            safety      = "SAFE",
            mode        = "manual",
            sendsToGame = false,
            notes       = {
                "Implemented as a Mudlet alias (local only).",
                "Backed by DWKit.bus.eventBus.off(token).",
                "Does not affect event tap; use dweventtap off for that.",
            },
        },

        dweventlog = {
            command     = "dweventlog",
            aliases     = {},
            ownerModule = "dwkit.services.command_aliases",
            description = "Prints the bounded event diagnostics log (SAFE).",
            syntax      = "dweventlog [n]",
            examples    = {
                "dweventlog",
                "dweventlog 25",
            },
            safety      = "SAFE",
            mode        = "manual",
            sendsToGame = false,
            notes       = {
                "Implemented as a Mudlet alias (local only).",
                "Prints the last n log entries (default 10, capped at 50).",
                "Log includes entries from both tap and per-event subscriptions.",
            },
        },

        dwboot = {
            command     = "dwboot",
            aliases     = {},
            ownerModule = "dwkit.services.command_aliases",
            description = "Prints DWKit boot wiring/health status (SAFE diagnostics).",
            syntax      = "dwboot",
            examples    = {
                "dwboot",
            },
            safety      = "SAFE",
            mode        = "manual",
            sendsToGame = false,
            notes       = {
                "Typed alias implemented by dwkit.services.command_aliases.",
                "Reports which DWKit surfaces are attached and any loader/init load errors.",
                "Does not emit gameplay commands.",
            },
        },

        dwservices = {
            command     = "dwservices",
            aliases     = {},
            ownerModule = "dwkit.services.command_aliases",
            description = "Lists attached DWKit services + versions + load errors (SAFE diagnostics).",
            syntax      = "dwservices",
            examples    = {
                "dwservices",
            },
            safety      = "SAFE",
            mode        = "manual",
            sendsToGame = false,
            notes       = {
                "Implemented as a Mudlet alias (local only).",
                "Inspection only; no gameplay output; no automation.",
            },
        },

        dwpresence = {
            command     = "dwpresence",
            aliases     = {},
            ownerModule = "dwkit.services.command_aliases",
            description = "Prints PresenceService snapshot (best-effort, SAFE).",
            syntax      = "dwpresence",
            examples    = {
                "dwpresence",
            },
            safety      = "SAFE",
            mode        = "manual",
            sendsToGame = false,
            notes       = {
                "Implemented as a Mudlet alias (local only).",
                "Prefers PresenceService.getState() if available; otherwise prints available API keys.",
            },
        },

        dwactions = {
            command     = "dwactions",
            aliases     = {},
            ownerModule = "dwkit.services.command_aliases",
            description = "Prints ActionModelService snapshot (best-effort, SAFE).",
            syntax      = "dwactions",
            examples    = {
                "dwactions",
            },
            safety      = "SAFE",
            mode        = "manual",
            sendsToGame = false,
            notes       = {
                "Implemented as a Mudlet alias (local only).",
                "Prefers ActionModelService.getState() if available; otherwise prints available API keys.",
            },
        },

        dwskills = {
            command     = "dwskills",
            aliases     = {},
            ownerModule = "dwkit.services.command_aliases",
            description = "Prints SkillRegistryService snapshot (best-effort, SAFE).",
            syntax      = "dwskills",
            examples    = {
                "dwskills",
            },
            safety      = "SAFE",
            mode        = "manual",
            sendsToGame = false,
            notes       = {
                "Implemented as a Mudlet alias (local only).",
                "Prefers SkillRegistryService.getState() or getAll() if available; otherwise prints available API keys.",
            },
        },

        dwscorestore = {
            command     = "dwscorestore",
            aliases     = {},
            ownerModule = "dwkit.services.command_aliases",
            description = "Shows and manages ScoreStoreService state + persistence (SAFE).",
            syntax      =
            "dwscorestore [status|persist on|off|status|fixture [basic]|clear|wipe [disk]|reset [disk]]  (or: lua DWKit.services.scoreStoreService.printSummary())",
            examples    = {
                "dwscorestore",
                "dwscorestore status",
                "dwscorestore persist status",
                "dwscorestore fixture basic",
                "lua DWKit.services.scoreStoreService.ingestFromText(\"SCORE TEST\",{source=\"manual\"})",
                "lua DWKit.services.scoreStoreService.printSummary()",
            },
            safety      = "SAFE",
            mode        = "manual",
            sendsToGame = false,
            notes       = {
                "Backed by dwkit.services.score_store_service (ScoreStoreService).",
                "Subcommands are implemented by dwkit.services.command_aliases and call ScoreStoreService methods (still SAFE; no gameplay commands sent).",
                "Score snapshots may be ingested via passive capture installed during loader.init (capture is SAFE; it only reacts to your score output).",
                "In case the alias is stale/cached, you can use the lua fallback above after loader init.",
            },
        },

        dwcommands = {
            command     = "dwcommands",
            aliases     = {},
            ownerModule = "dwkit.services.command_aliases",
            description = "Lists registered DWKit commands (ALL, SAFE, GAME) or prints Markdown export (SAFE).",
            syntax      = "dwcommands [safe|game|md]",
            examples    = {
                "dwcommands",
                "dwcommands safe",
                "dwcommands game",
                "dwcommands md",
            },
            safety      = "SAFE",
            mode        = "manual",
            sendsToGame = false,
            notes       = {
                "Implemented as a Mudlet alias (local only).",
                "Backed by DWKit.cmd.listAll/listSafe/listGame.",
                "dwcommands safe uses registry filter: sendsToGame == false.",
                "dwcommands game uses registry filter: sendsToGame == true.",
                "Markdown export is backed by DWKit.cmd.toMarkdown().",
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

local function _isAllowedSafety(s)
    return s == "SAFE" or s == "COMBAT-SAFE" or s == "NOT SAFE"
end

local function _isAllowedMode(s)
    return s == "manual" or s == "opt-in" or s == "auto"
end

local function _validateDef(def, opts)
    opts = opts or {}
    local requireDescription = (opts.requireDescription ~= false)

    if type(def) ~= "table" then return false, "def must be a table" end
    if not _isNonEmptyString(def.command) then return false, "missing/invalid: command" end
    if not _isNonEmptyString(def.ownerModule) then return false, "missing/invalid: ownerModule" end
    if requireDescription and (not _isNonEmptyString(def.description)) then return false, "missing/invalid: description" end
    if not _isNonEmptyString(def.syntax) then return false, "missing/invalid: syntax" end
    if not _isNonEmptyString(def.safety) then return false, "missing/invalid: safety" end
    if not _isAllowedSafety(def.safety) then return false, "invalid: safety must be SAFE|COMBAT-SAFE|NOT SAFE" end
    if not _isNonEmptyString(def.mode) then return false, "missing/invalid: mode" end
    if not _isAllowedMode(def.mode) then return false, "invalid: mode must be manual|opt-in|auto" end

    if type(def.aliases) ~= "table" then return false, "invalid: aliases must be a table" end
    if type(def.examples) ~= "table" then return false, "invalid: examples must be a table" end

    if type(def.sendsToGame) ~= "boolean" then return false, "invalid: sendsToGame must be boolean" end

    if def.sendsToGame then
        if def.safety == "SAFE" then
            return false, "invalid: safety must be COMBAT-SAFE or NOT SAFE when sendsToGame=true"
        end
        if not _isNonEmptyString(def.underlyingGameCommand) then
            return false, "missing/invalid: underlyingGameCommand (required when sendsToGame=true)"
        end
        if not _isNonEmptyString(def.sideEffects) then
            return false, "missing/invalid: sideEffects (required when sendsToGame=true)"
        end
    else
        if def.safety ~= "SAFE" then
            return false, "invalid: safety must be SAFE when sendsToGame=false"
        end
    end

    return true, nil
end

local function _isArrayLike(t)
    if type(t) ~= "table" then return false end
    local n = #t
    if n == 0 then
        for k, _ in pairs(t) do
            if type(k) ~= "number" then return false end
        end
        return true
    end
    for i = 1, n do
        if t[i] == nil then return false end
    end
    for k, _ in pairs(t) do
        if type(k) ~= "number" then return false end
    end
    return true
end

local function _validateStringArray(fieldName, t, allowEmpty)
    if t == nil then
        return true, nil
    end
    if type(t) ~= "table" then
        return false, fieldName .. " must be a table (array)"
    end
    if not _isArrayLike(t) then
        return false, fieldName .. " must be an array-like table"
    end
    if (not allowEmpty) and (#t == 0) then
        return false, fieldName .. " must be non-empty"
    end
    for i, v in ipairs(t) do
        if not _isNonEmptyString(v) then
            return false, fieldName .. "[" .. tostring(i) .. "] must be a non-empty string"
        end
    end
    return true, nil
end

local function _mkIssue(cmdName, message)
    return { name = tostring(cmdName or ""), error = tostring(message or "") }
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
-- Markdown export (docs helper; SAFE)
-- -------------------------
local function _mdEscape(s)
    s = tostring(s or "")
    s = s:gsub("\r\n", "\n")
    s = s:gsub("\r", "\n")
    return s
end

local function _mdLine(lines, s)
    lines[#lines + 1] = tostring(s or "")
end

local function _mdBullet(lines, s)
    _mdLine(lines, "- " .. _mdEscape(s))
end

local function _mdIndentBullet(lines, s)
    _mdLine(lines, "  - " .. _mdEscape(s))
end

local function _mdSection(lines, title)
    _mdLine(lines, "")
    _mdLine(lines, "### " .. _mdEscape(title))
end

local function _mdValueLine(lines, label, value)
    _mdLine(lines, "- " .. _mdEscape(label) .. ": " .. _mdEscape(value))
end

function M.toMarkdown(opts)
    opts = opts or {}
    local includeGame = (opts.includeGame == nil) and true or (opts.includeGame == true)
    local includeSafe = (opts.includeSafe == nil) and true or (opts.includeSafe == true)

    local lines = {}
    _mdLine(lines, "# Command Registry (Runtime Export)")
    _mdLine(lines, "")
    _mdLine(lines, "## Source")
    _mdBullet(lines,
        "Generated from code registry mirror: dwkit.bus.command_registry " .. tostring(M.VERSION or "unknown"))
    _mdBullet(lines, "Registry version (docs): " .. tostring(REG.version or "unknown"))
    _mdBullet(lines, "Generated at ts: " .. tostring(os.time()))
    _mdLine(lines, "")
    _mdLine(lines, "## Notes")
    _mdBullet(lines, "This is a copy/paste helper. It does not change runtime behavior.")
    _mdBullet(lines, "For filtering views, use: dwcommands / dwcommands safe / dwcommands game.")
    _mdLine(lines, "")
    _mdLine(lines, "## Commands")

    local all = _collectList(nil)

    for _, def in ipairs(all) do
        if def.sendsToGame and not includeGame then
            -- skip
        elseif (def.sendsToGame == false) and not includeSafe then
            -- skip
        else
            _mdSection(lines, def.command)

            _mdValueLine(lines, "Command", tostring(def.command))
            if def.aliases and #def.aliases > 0 then
                _mdValueLine(lines, "Aliases", table.concat(def.aliases, ", "))
            else
                _mdValueLine(lines, "Aliases", "(none)")
            end
            _mdValueLine(lines, "Owner Module", tostring(def.ownerModule))
            _mdValueLine(lines, "Description", tostring(def.description))
            _mdValueLine(lines, "Syntax", tostring(def.syntax))
            _mdValueLine(lines, "Safety", tostring(def.safety))
            _mdValueLine(lines, "Mode", tostring(def.mode))
            _mdValueLine(lines, "SendsToGame", def.sendsToGame and "YES" or "NO")

            if def.examples and #def.examples > 0 then
                _mdLine(lines, "- Examples:")
                for _, ex in ipairs(def.examples) do
                    _mdIndentBullet(lines, tostring(ex))
                end
            else
                _mdLine(lines, "- Examples: (none)")
            end

            if def.sendsToGame then
                if type(def.underlyingGameCommand) == "string" and def.underlyingGameCommand ~= "" then
                    _mdValueLine(lines, "underlyingGameCommand", def.underlyingGameCommand)
                end
                if type(def.sideEffects) == "string" and def.sideEffects ~= "" then
                    _mdValueLine(lines, "sideEffects", def.sideEffects)
                end
                if type(def.rateLimit) == "string" and def.rateLimit ~= "" then
                    _mdValueLine(lines, "rateLimit", def.rateLimit)
                end
                if type(def.wrapperOf) == "string" and def.wrapperOf ~= "" then
                    _mdValueLine(lines, "wrapperOf", def.wrapperOf)
                end
            end

            if def.notes and #def.notes > 0 then
                _mdLine(lines, "- Notes:")
                for _, n in ipairs(def.notes) do
                    _mdIndentBullet(lines, tostring(n))
                end
            else
                _mdLine(lines, "- Notes: (none)")
            end
        end
    end

    return table.concat(lines, "\n")
end

-- -------------------------
-- Public API
-- -------------------------
function M.getRegistryVersion()
    return tostring(REG.version or "unknown")
end

function M.getModuleVersion()
    return tostring(M.VERSION or "unknown")
end

function M.count()
    local n = 0
    for _ in pairs(REG.commands) do n = n + 1 end
    return n
end

function M.has(name)
    if type(name) ~= "string" or name == "" then return false end
    return REG.commands[name] ~= nil
end

function M.getAll()
    local out = {}
    for name, def in pairs(REG.commands) do
        out[name] = _copyDef(def)
    end
    return out
end

local function _printList(title, list)
    _out("[DWKit Commands] " .. title ..
        " (source: dwkit.bus.command_registry " ..
        tostring(REG.version or "unknown") ..
        " / " .. tostring(M.VERSION or "unknown") .. ")")
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
        _out("[DWKit Help] " ..
            tostring(c.command) ..
            " (source: dwkit.bus.command_registry " ..
            tostring(REG.version or "unknown") ..
            " / " .. tostring(M.VERSION or "unknown") .. ")")
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
    local ok, err = _validateDef(def, { requireDescription = true })
    if not ok then return false, err end

    local name = def.command
    if REG.commands[name] then
        return false, "Command already exists: " .. tostring(name)
    end

    REG.commands[name] = _copyDef(def)
    return true, nil
end

-- SAFE validation for the static registry content (no printing by default).
-- Returns pass, issues[] where each issue = {name=<commandName>, error=<string>}
function M.validateAll(opts)
    opts = opts or {}
    local strict = (opts.strict ~= false)

    local issues = {}

    if not _isNonEmptyString(REG.version) then
        table.insert(issues, _mkIssue("(registry)", "REG.version must be a non-empty string"))
    end

    if type(REG.commands) ~= "table" then
        table.insert(issues, _mkIssue("(registry)", "REG.commands must be a table"))
        return false, issues
    end

    for k, def in pairs(REG.commands) do
        local keyName = tostring(k or "")
        local okDef, errDef = _validateDef(def, opts)
        if not okDef then
            table.insert(issues, _mkIssue(keyName, errDef))
        else
            local defName = tostring(def.command or "")
            if keyName ~= defName then
                table.insert(issues,
                    _mkIssue(defName ~= "" and defName or keyName, "registry key must equal def.command"))
            end

            -- strictness: arrays must be well-formed; allow empty arrays but entries must be non-empty strings
            local okA, errA = _validateStringArray("aliases", def.aliases, true)
            if not okA then table.insert(issues, _mkIssue(defName, errA)) end

            local okE, errE = _validateStringArray("examples", def.examples, not strict)
            if not okE then table.insert(issues, _mkIssue(defName, errE)) end

            local okN, errN = _validateStringArray("notes", def.notes, true)
            if not okN then table.insert(issues, _mkIssue(defName, errN)) end
        end
    end

    return (#issues == 0), issues
end

return M
