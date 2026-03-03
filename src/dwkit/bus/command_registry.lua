-- #########################################################################
-- Module Name : dwkit.bus.command_registry
-- Owner       : Bus
-- Version     : v2026-03-03B
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
--   - getAllNames()  -> string[] (SAFE, no output)
--   - getSafeNames() -> string[] (SAFE, no output)
--   - getGameNames() -> string[] (SAFE, no output)
--   - help(name, opts?) -> boolean ok, table|nil cmdOrNil, string|nil errOrNil
--   - register(def) -> boolean ok, string|nil errOrNil   (runtime-only, not persisted)
--   - getAll() -> table copy (name -> def)
--   - getRegistryVersion() -> string   (docs registry version, e.g. v3.1)
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

M.VERSION = "v2026-03-03B"

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
    version = "v3.1",
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
                "dwtest ui",
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
                "Upcoming scope: dwtest ui runs UI Safety Gate checks (validator wiring + contract compliance).",
            },
        },

        dwversion = {
            command     = "dwversion",
            aliases     = {},
            ownerModule = "dwkit.commands.dwversion",
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
            ownerModule = "dwkit.commands.dwdiag",
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

        dwgui = {
            command     = "dwgui",
            aliases     = {},
            ownerModule = "dwkit.commands.dwgui",
            description = "Manage GUI settings flags (enabled/visible) per UI id (SAFE config only; no UI actions).",
            syntax      = "dwgui [status|list|enable <uiId>|disable <uiId>|visible <uiId> on|off]",
            examples    = {
                "dwgui",
                "dwgui status",
                "dwgui list",
                "dwgui enable test_ui",
                "dwgui disable test_ui",
                "dwgui visible test_ui on",
                "dwgui visible test_ui off",
            },
            safety      = "SAFE",
            mode        = "manual",
            sendsToGame = false,
            notes       = {
                "Typed alias implemented by dwkit.services.command_aliases.",
                "Backed by DWKit.config.guiSettings (dwkit.config.gui_settings).",
                "This command only changes stored flags; it does NOT show/hide UI elements directly.",
                "Visible control requires visible persistence to be enabled in guiSettings; dwgui enables it on-demand for visible subcommands.",
            },
        },

        -- NEW (Phase 1): chat command surface
        dwchat = {
            command     = "dwchat",
            aliases     = {},
            ownerModule = "dwkit.commands.dwchat",
            description =
            "Controls the DWKit Chat UI (chat_ui): open/hide/toggle/status, enable/disable, tabs, clear, and SAFE input toggles (send/input).",
            syntax      =
            "dwchat [open|show|hide|close|toggle|status|enable|disable|tabs|tab <name>|clear|send on|off|input on|off]",
            examples    = {
                "dwchat",
                "dwchat status",
                "dwchat hide",
                "dwchat toggle",
                "dwchat enable",
                "dwchat disable",
                "dwchat tabs",
                "dwchat tab SAY",
                "dwchat tab Other",
                "dwchat clear",
                "dwchat send on",
                "dwchat send off",
                "dwchat input off",
                "dwchat input on",
            },
            safety      = "SAFE",
            mode        = "manual",
            sendsToGame = false,
            notes       = {
                "Phase 1 deterministic command surface for chat_ui.",
                "Prefers ui_manager.applyOne(\"chat_ui\") when available so dependency claims (chat_watch) are handled centrally.",
                "Visible is session-only by default (noSave=true). Enabled is persisted when explicitly opened/enabled.",
                "send on|off only flips chat_ui sendToMud flag; sending to MUD only occurs on explicit user Enter submit (still manual).",
                "input on|off is best-effort and depends on chat_ui exposing setter APIs (implemented in your current build).",
            },
        },

        dwui = {
            command     = "dwui",
            aliases     = {},
            ownerModule = "dwkit.commands.dwui",
            description = "Opens the UI Manager UI surface (ui_manager_ui).",
            syntax      = "dwui  (or: dwui open)",
            examples    = {
                "dwui",
                "dwui open",
            },
            safety      = "SAFE",
            mode        = "manual",
            sendsToGame = false,
            notes       = {
                "Typed alias implemented by dwkit.services.command_aliases.",
                "Ensures ui_manager_ui enabled=ON (persisted) and visible=ON (session-only) then applies via ui_manager if available.",
            },
        },

        dwevents = {
            command     = "dwevents",
            aliases     = {},
            ownerModule = "dwkit.commands.dwevents",
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
            ownerModule = "dwkit.commands.dwevent",
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
            ownerModule = "dwkit.commands.dweventtap",
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
            ownerModule = "dwkit.commands.dweventsub",
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
            ownerModule = "dwkit.commands.dweventunsub",
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
            ownerModule = "dwkit.commands.dweventlog",
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
            ownerModule = "dwkit.commands.dwboot",
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
            ownerModule = "dwkit.commands.dwservices",
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
            ownerModule = "dwkit.commands.dwpresence",
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

        dwwho = {
            command     = "dwwho",
            aliases     = {},
            ownerModule = "dwkit.commands.dwwho",
            description = "Shows and manages WhoStore state (SAFE diagnostics and fixtures; no gameplay commands).",
            syntax      = "dwwho",
            examples    = {
                "dwwho",
            },
            safety      = "SAFE",
            mode        = "manual",
            sendsToGame = false,
            notes       = {
                "Implemented as a Mudlet alias (local only).",
                "Backed by WhoStoreService (dwkit.services.whostore_service) and SAFE helpers.",
                "Intended for inspection, fixtures, and state debug; no automation.",
            },
        },

        -- NEW: prompt discovery + prompt detector seeding (manual gameplay wrapper)
        dwprompt = {
            command               = "dwprompt",
            aliases               = {},
            ownerModule           = "dwkit.commands.dwprompt",
            description           =
            "Prompt utilities: refresh captures current MUD prompt (supports multi-line) and updates PromptDetector stored prompt.",
            syntax                = "dwprompt [status|refresh]",
            examples              = {
                "dwprompt",
                "dwprompt status",
                "dwprompt refresh",
            },
            safety                = "COMBAT-SAFE",
            mode                  = "manual",
            sendsToGame           = true,
            underlyingGameCommand = "prompt",
            sideEffects           =
            "Sends 'prompt' to the MUD and prints current prompt (may be multi-line). No gameplay state change expected.",
            notes                 = {
                "This is a manual gameplay wrapper (sendsToGame=true) used to seed PromptDetector so passive captures can detect custom prompts.",
                "Typed alias implemented by dwkit.services.command_aliases.",
                "If PromptDetector is unconfigured, roomfeed passive capture may fail to finalize (abort:max_lines) for non-<...> prompts.",
            },
        },

        dwroom = {
            command     = "dwroom",
            aliases     = {},
            ownerModule = "dwkit.commands.dwroom",
            description =
            "Shows and manages RoomEntities state (SAFE diagnostics/fixtures/refresh; no gameplay commands).",
            syntax      = "dwroom",
            examples    = {
                "dwroom",
            },
            safety      = "SAFE",
            mode        = "manual",
            sendsToGame = false,
            notes       = {
                "Implemented as a Mudlet alias (local only).",
                "Backed by RoomEntitiesService (dwkit.services.roomentities_service) and SAFE helpers.",
                "Used for fixture/ingest/refresh workflows; no gameplay commands are sent.",
            },
        },

        dwactions = {
            command     = "dwactions",
            aliases     = {},
            ownerModule = "dwkit.commands.dwactions",
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
            ownerModule = "dwkit.commands.dwskills",
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
            ownerModule = "dwkit.commands.dwscorestore",
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

        -- NEW: PracticeStore command surface (SAFE)
        dwpracticestore = {
            command     = "dwpracticestore",
            aliases     = {},
            ownerModule = "dwkit.commands.dwpracticestore",
            description = "Shows and manages PracticeStoreService state + persistence (SAFE).",
            syntax      =
            "dwpracticestore [status|persist on|off|status|fixture [basic]|clear|wipe [disk]|reset [disk]]  (or: lua DWKit.services.practiceStoreService.printSummary())",
            examples    = {
                "dwpracticestore",
                "dwpracticestore status",
                "dwpracticestore persist status",
                "dwpracticestore fixture basic",
                "lua DWKit.services.practiceStoreService.ingestFromText(\"PRACTICE TEST\",{source=\"manual\"})",
                "lua DWKit.services.practiceStoreService.printSummary()",
            },
            safety      = "SAFE",
            mode        = "manual",
            sendsToGame = false,
            notes       = {
                "Backed by dwkit.services.practice_store_service (PracticeStoreService).",
                "Subcommands are implemented by dwkit.services.alias_factory auto SAFE alias generation and call PracticeStoreService methods (still SAFE; no gameplay commands sent).",
                "Practice snapshots may be ingested via passive capture installed during loader.init (capture is SAFE; it only reacts to your practice output).",
                "In case the alias is stale/cached, you can use the lua fallback above after loader init.",
            },
        },

        -- NEW: RemoteExec (SAFE command surface; owned-only remote execution transport)
        dwremoteexec = {
            command     = "dwremoteexec",
            aliases     = {},
            ownerModule = "dwkit.commands.dwremoteexec",
            description = "RemoteExec controls: status, allowlist management, and SAFE ping across owned profiles (same Mudlet instance).",
            syntax      = "dwremoteexec [status|ping <targetProfile>|allow list|allow add <prefix>|allow clear]",
            examples    = {
                "dwremoteexec status",
                "dwremoteexec ping Profile-B",
                "dwremoteexec allow list",
                "dwremoteexec allow add say ",
                "dwremoteexec allow clear",
            },
            safety      = "SAFE",
            mode        = "manual",
            sendsToGame = false,
            notes       = {
                "Backed by dwkit.services.remote_exec_service (RemoteExecService).",
                "Owned-only enforcement uses owned_profiles values (profile labels).",
                "Transport is same-instance only (raiseGlobalEvent).",
                "SEND is allowlist-gated and default OFF (Objective B stays SAFE by default).",
            },
        },

        dwcommands = {
            command     = "dwcommands",
            aliases     = {},
            ownerModule = "dwkit.commands.dwcommands",
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
            ownerModule = "dwkit.commands.dwhelp",
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

        dwrelease = {
            command     = "dwrelease",
            aliases     = {},
            ownerModule = "dwkit.commands.dwrelease",
            description = "Prints a bounded release checklist + version pointers + tag workflow reminder (SAFE).",
            syntax      = "dwrelease",
            examples    = {
                "dwrelease",
            },
            safety      = "SAFE",
            mode        = "manual",
            sendsToGame = false,
            notes       = {
                "SAFE/manual only: prints guidance, does not run git or create tags.",
                "Intended as a copy/paste friendly reminder for PR + tag discipline.",
                "Typed alias implemented by dwkit.services.command_aliases.",
            },
        },

        -- NEW: dwsetup (one-command bootstrap checklist)
        dwsetup = {
            command     = "dwsetup",
            aliases     = {},
            ownerModule = "dwkit.commands.dwsetup",
            description =
            "Runs a one-shot bootstrap checklist for fresh profiles (owned_profiles + WhoStore + next actions).",
            syntax      = "dwsetup [status|help]",
            examples    = {
                "dwsetup",
                "dwsetup status",
                "dwsetup help",
            },
            safety      = "SAFE",
            mode        = "manual",
            sendsToGame = false,
            notes       = {
                "Typed alias auto-generated from registry (dwkit.services.alias_factory).",
                "Default run calls dwwho refresh once (approved pathway) then instructs you to type 'look' once (passive capture).",
                "Does not guess or auto-seed owned_profiles; prints explicit example only.",
                "Best-effort triggers Presence + RoomEntities refresh emissions so UIs re-render.",
            },
        },
    }
}

-- -------------------------
-- Validation (minimal, strict)
-- -------------------------
local function _isNonEmptyString(s) return type(s) == "string" and s ~= "" end

-- Generic enum helpers:
-- - spec.allowed (array) is canonical and drives error string ordering
-- - spec.legacy  (array) is accepted but noted as legacy in the error string
local function _enumSetFromSpec(spec)
    local set = {}
    spec = (type(spec) == "table") and spec or {}

    local function _add(list)
        if type(list) ~= "table" then return end
        for i = 1, #list do
            local v = list[i]
            if type(v) == "string" and v ~= "" then
                set[v] = true
            end
        end
    end

    _add(spec.allowed)
    _add(spec.legacy)
    return set
end

local function _formatEnumError(fieldName, spec, legacyNoteSingleFmt)
    fieldName = tostring(fieldName or "field")
    spec = (type(spec) == "table") and spec or {}
    local allowed = (type(spec.allowed) == "table") and spec.allowed or {}
    local legacy = (type(spec.legacy) == "table") and spec.legacy or {}

    local allowedStr = table.concat(allowed, "|")
    if allowedStr == "" then allowedStr = "(none)" end

    if #legacy > 0 then
        if #legacy == 1 then
            local fmt = legacyNoteSingleFmt or "(legacy '%s' accepted)"
            return "invalid: " ..
                fieldName .. " must be " .. allowedStr .. " " .. string.format(fmt, tostring(legacy[1]))
        end
        return "invalid: " ..
            fieldName .. " must be " .. allowedStr .. " (legacy accepted: " .. table.concat(legacy, ", ") .. ")"
    end

    return "invalid: " .. fieldName .. " must be " .. allowedStr
end

local function _safetySpec()
    return {
        allowed = { "SAFE", "COMBAT-SAFE", "NOT SAFE" },
        legacy = {},
    }
end

local SAFETY_SPEC = _safetySpec()
local SAFETY_SET = _enumSetFromSpec(SAFETY_SPEC)

local function _isAllowedSafety(s)
    if type(s) ~= "string" or s == "" then return false end
    return SAFETY_SET[s] == true
end

-- Derive safety coupling rules from the safety spec so text cannot go stale.
-- Policy:
--   sendsToGame=false -> safety must be SAFE
--   sendsToGame=true  -> safety must be one of SAFETY_SPEC.allowed excluding SAFE
local function _allowedSafetyForSendsToGame(sendsToGame)
    local allowed = (type(SAFETY_SPEC.allowed) == "table") and SAFETY_SPEC.allowed or {}

    if sendsToGame == true then
        local out = {}
        for i = 1, #allowed do
            local v = allowed[i]
            if v ~= "SAFE" then
                out[#out + 1] = v
            end
        end
        return out
    end

    return { "SAFE" }
end

local function _formatSafetyCouplingError(sendsToGame)
    local list = _allowedSafetyForSendsToGame(sendsToGame == true)
    local allowedStr = table.concat(list, "|")
    if allowedStr == "" then allowedStr = "(none)" end

    if sendsToGame == true then
        return "invalid: safety must be " .. allowedStr .. " when sendsToGame=true"
    end
    return "invalid: safety must be " .. allowedStr .. " when sendsToGame=false"
end

-- Derive required-fields (when sendsToGame=true) from a spec so text cannot go stale.
-- Note:
-- - Currently used for error string generation only; validation still checks fields explicitly.
local function _requiredWhenSendsToGameSpec()
    return {
        required = { "underlyingGameCommand", "sideEffects" },
    }
end

local REQUIRED_WHEN_SENDSTOGAME_SPEC = _requiredWhenSendsToGameSpec()

local function _isRequiredWhenSendsToGame(fieldName)
    fieldName = tostring(fieldName or "")
    if fieldName == "" then return false end
    local req = (type(REQUIRED_WHEN_SENDSTOGAME_SPEC.required) == "table") and REQUIRED_WHEN_SENDSTOGAME_SPEC.required or
        {}
    for i = 1, #req do
        if tostring(req[i]) == fieldName then
            return true
        end
    end
    return false
end

local function _formatRequiredWhenSendsToGameError(fieldName)
    fieldName = tostring(fieldName or "")
    if fieldName == "" then fieldName = "(field)" end
    return "missing/invalid: " .. fieldName .. " (required when sendsToGame=true)"
end

-- Anchor Pack mode policy:
--   manual | opt-in | essential-default
-- Back-compat:
--   accept "auto" as an alias of "essential-default" (deprecated) so older defs don't fail.
local function _modeSpec()
    return {
        allowed = { "manual", "opt-in", "essential-default" },
        legacy = { "auto" }, -- deprecated alias of essential-default
    }
end

local MODE_SPEC = _modeSpec()
local MODE_SET = _enumSetFromSpec(MODE_SPEC)

local function _isAllowedMode(s)
    if type(s) ~= "string" or s == "" then return false end
    return MODE_SET[s] == true
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
    if not _isAllowedSafety(def.safety) then
        return false, _formatEnumError("safety", SAFETY_SPEC)
    end
    if not _isNonEmptyString(def.mode) then return false, "missing/invalid: mode" end
    if not _isAllowedMode(def.mode) then
        return false, _formatEnumError("mode", MODE_SPEC, "(legacy '%s' accepted)")
    end

    if type(def.aliases) ~= "table" then return false, "invalid: aliases must be a table" end
    if type(def.examples) ~= "table" then return false, "invalid: examples must be a table" end

    if type(def.sendsToGame) ~= "boolean" then return false, "invalid: sendsToGame must be boolean" end

    if def.sendsToGame then
        if def.safety == "SAFE" then
            return false, _formatSafetyCouplingError(true)
        end
        if not _isNonEmptyString(def.underlyingGameCommand) then
            -- derived error string (field is part of REQUIRED_WHEN_SENDSTOGAME_SPEC)
            if _isRequiredWhenSendsToGame("underlyingGameCommand") then
                return false, _formatRequiredWhenSendsToGameError("underlyingGameCommand")
            end
            return false, "missing/invalid: underlyingGameCommand (required when sendsToGame=true)"
        end
        if not _isNonEmptyString(def.sideEffects) then
            -- derived error string (field is part of REQUIRED_WHEN_SENDSTOGAME_SPEC)
            if _isRequiredWhenSendsToGame("sideEffects") then
                return false, _formatRequiredWhenSendsToGameError("sideEffects")
            end
            return false, "missing/invalid: sideEffects (required when sendsToGame=true)"
        end
    else
        if def.safety ~= "SAFE" then
            return false, _formatSafetyCouplingError(false)
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

-- NEW: name-only helpers (SAFE, no output)
local function _collectNames(filterFn)
    local names = {}
    for _, def in pairs(REG.commands) do
        if not filterFn or filterFn(def) then
            names[#names + 1] = tostring(def.command or "")
        end
    end
    table.sort(names, function(a, b) return tostring(a) < tostring(b) end)
    return names
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

-- NEW: name-only helpers (SAFE, no output)
function M.getAllNames()
    return _collectNames(nil)
end

function M.getSafeNames()
    return _collectNames(function(def) return def.sendsToGame == false end)
end

function M.getGameNames()
    return _collectNames(function(def) return def.sendsToGame == true end)
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
