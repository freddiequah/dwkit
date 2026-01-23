-- #########################################################################
-- Module Name : dwkit.commands.dwtest
-- Owner       : Commands
-- Version     : v2026-01-23A
-- Purpose     :
--   - Command handler for `dwtest` alias (delegated from command_aliases.lua)
--   - Supports:
--       * dwtest
--       * dwtest quiet
--       * dwtest ui
--       * dwtest ui verbose
--       * dwtest room
--       * dwtest room verbose
--
-- Notes:
--   - SAFE command surface.
--   - No GMCP required.
--   - UI validator is optional; only used for `dwtest ui`.
--   - Room mini-test is optional; used for deterministic event pipeline checks.
--
-- Public API  :
--   - dispatch(ctx, testRunner, args) -> boolean ok
--     ctx:
--       - out(line)
--       - err(msg)
--       - ppTable(tbl, opts) (optional)
--       - callBestEffort(obj, fnName, ...) (optional)
--       - getUiValidator() -> table|nil (optional)
--     testRunner:
--       - run(opts?) function
--     args:
--       - mode: "" | "quiet" | "ui" | "room"
--       - verbose: boolean
-- #########################################################################

local M = {}
M.VERSION = "v2026-01-23A"

local function _out(ctx, line)
    if ctx and type(ctx.out) == "function" then
        ctx.out(line)
    else
        print(tostring(line or ""))
    end
end

local function _err(ctx, msg)
    if ctx and type(ctx.err) == "function" then
        ctx.err(msg)
    else
        _out(ctx, "[dwtest] ERROR: " .. tostring(msg))
    end
end

local function _pp(ctx, t, opts)
    if ctx and type(ctx.ppTable) == "function" then
        ctx.ppTable(t, opts)
    else
        -- best-effort minimal print
        _out(ctx, tostring(t))
    end
end

local function _callBestEffort(ctx, obj, fnName, ...)
    if ctx and type(ctx.callBestEffort) == "function" then
        return ctx.callBestEffort(obj, fnName, ...)
    end
    -- fallback direct call
    if type(obj) ~= "table" or type(obj[fnName]) ~= "function" then
        return false, nil, nil, nil, "missing function: " .. tostring(fnName)
    end
    local ok, a, b, c = pcall(obj[fnName], ...)
    if ok then return true, a, b, c, nil end
    return false, nil, nil, nil, tostring(a)
end

local function _isArrayLike(t)
    if type(t) ~= "table" then return false end
    local n = #t
    if n == 0 then return false end
    for i = 1, n do
        if t[i] == nil then return false end
    end
    return true
end

local function _firstMsgFrom(r)
    if type(r) ~= "table" then return nil end
    if type(r.errors) == "table" and #r.errors > 0 then return tostring(r.errors[1]) end
    if type(r.warnings) == "table" and #r.warnings > 0 then return tostring(r.warnings[1]) end
    if type(r.notes) == "table" and #r.notes > 0 then return tostring(r.notes[1]) end
    return nil
end

local function _summarizeValidateAll(details)
    if type(details) ~= "table" then
        return { pass = 0, warn = 0, fail = 0, skip = 0, count = 0, list = {} }
    end

    local resArr = nil
    if type(details.results) == "table" and _isArrayLike(details.results) then
        resArr = details.results
    elseif type(details.details) == "table"
        and type(details.details.results) == "table"
        and _isArrayLike(details.details.results) then
        resArr = details.details.results
    end

    local counts = { pass = 0, warn = 0, fail = 0, skip = 0, count = 0, list = {} }
    if type(resArr) ~= "table" then return counts end

    counts.count = #resArr
    for _, r in ipairs(resArr) do
        local st = (type(r) == "table" and type(r.status) == "string") and r.status or "UNKNOWN"
        if st == "PASS" then
            counts.pass = counts.pass + 1
        elseif st == "WARN" then
            counts.warn = counts.warn + 1
            counts.list[#counts.list + 1] = r
        elseif st == "FAIL" then
            counts.fail = counts.fail + 1
            counts.list[#counts.list + 1] = r
        elseif st == "SKIP" then
            counts.skip = counts.skip + 1
        else
            counts.warn = counts.warn + 1
            counts.list[#counts.list + 1] = r
        end
    end

    return counts
end

local function _printNoUiNote(ctx)
    _out(ctx, "  NOTE: No UI modules found for this profile (dwtest ui).")
    _out(ctx, "  Tips:")
    _out(ctx, "    - dwgui list")
    _out(ctx, "    - dwgui enable <uiId>")
    _out(ctx, "    - dwgui apply")
end

local function _safeRequire(modName)
    local ok, mod = pcall(require, modName)
    if ok and type(mod) == "table" then
        return true, mod, nil
    end
    return false, nil, tostring(mod)
end

local function _hasKey(t, k)
    return (type(t) == "table" and type(k) == "string" and t[k] == true)
end

local function _countMap(t)
    if type(t) ~= "table" then return 0 end
    local n = 0
    for _, v in pairs(t) do
        if v == true then n = n + 1 end
    end
    return n
end

local function _runRoomMiniTest(ctx, verbose)
    _out(ctx, "[DWKit Test] RoomEntities pipeline mini-test (dwtest room)")
    _out(ctx, "  goal=WhoStore update triggers RoomEntities reclassify + emits Updated")
    _out(ctx, "  mode=" .. (verbose and "verbose" or "compact"))
    _out(ctx, "")

    local okR, Room, errR = _safeRequire("dwkit.services.roomentities_service")
    if not okR then
        _err(ctx, "require roomentities_service failed: " .. tostring(errR))
        return false
    end

    local okW, Who, errW = _safeRequire("dwkit.services.whostore_service")
    if not okW then
        _err(ctx, "require whostore_service failed: " .. tostring(errW))
        return false
    end

    local okE, Watcher, errE = _safeRequire("dwkit.services.event_watcher_service")
    if not okE then
        _err(ctx, "require event_watcher_service failed: " .. tostring(errE))
        return false
    end

    -- Best-effort ensure watcher installed (should already be installed by init).
    if type(Watcher.install) == "function" then
        pcall(Watcher.install, { quiet = true })
    end

    local evRoomUpdated = nil
    if type(Room.getUpdatedEventName) == "function" then
        local okEv, v = pcall(Room.getUpdatedEventName)
        if okEv and type(v) == "string" and v ~= "" then
            evRoomUpdated = v
        end
    end
    evRoomUpdated = tostring(evRoomUpdated or (Room.EV_UPDATED or "DWKit:Service:RoomEntities:Updated"))

    local st0 = nil
    if type(Watcher.getState) == "function" then
        local okS, s = pcall(Watcher.getState)
        if okS and type(s) == "table" then
            st0 = s
        end
    end
    st0 = st0 or { receivedCount = 0, lastEventName = nil, installed = nil, subscribedCount = 0 }

    if verbose then
        _out(ctx, "[DWKit Test] pre-state (watcher)")
        _pp(ctx, st0, { maxDepth = 2, maxItems = 40 })
        _out(ctx, "")
    end

    -- Seed RoomEntities with an "unknown" entry that should reclassify to player "Borai"
    -- once WhoStore publishes Borai as known player.
    local seed = {
        players = {},
        mobs = {},
        items = {},
        unknown = { ["Borai hates bugs"] = true },
    }

    if type(Room.setState) ~= "function" then
        _err(ctx, "RoomEntitiesService.setState not available")
        return false
    end

    local okSeed, errSeed = Room.setState(seed, { source = "dwtest:room:seed", forceEmit = true })
    if okSeed ~= true then
        _err(ctx, "RoomEntitiesService.setState failed: " .. tostring(errSeed))
        return false
    end

    if type(Who.setState) ~= "function" then
        _err(ctx, "WhoStoreService.setState not available")
        return false
    end

    -- Publish WhoStore snapshot: Borai is a known player name.
    local okWho, errWho = Who.setState({ players = { "Borai" } }, { source = "dwtest:room:seedWho" })
    if okWho ~= true then
        _err(ctx, "WhoStoreService.setState failed: " .. tostring(errWho))
        return false
    end

    -- Now validate RoomEntities was reclassified (unknown -> players) by WhoStore Updated event.
    if type(Room.getState) ~= "function" then
        _err(ctx, "RoomEntitiesService.getState not available")
        return false
    end

    local roomState = Room.getState()
    roomState = (type(roomState) == "table") and roomState or {}
    local players = (type(roomState.players) == "table") and roomState.players or {}
    local unknown = (type(roomState.unknown) == "table") and roomState.unknown or {}

    local okMoved = _hasKey(players, "Borai")
    local stillUnknown = _hasKey(unknown, "Borai hates bugs")

    local st1 = nil
    if type(Watcher.getState) == "function" then
        local okS, s = pcall(Watcher.getState)
        if okS and type(s) == "table" then
            st1 = s
        end
    end
    st1 = st1 or { receivedCount = st0.receivedCount, lastEventName = st0.lastEventName }

    local rc0 = tonumber(st0.receivedCount) or 0
    local rc1 = tonumber(st1.receivedCount) or 0
    local lastEv = tostring(st1.lastEventName or "")

    -- We expect the final event observed to be RoomEntities Updated (WhoStore emits first, then RoomEntities emits).
    local okWatcherSawRoom = (rc1 > rc0) and (lastEv == evRoomUpdated)

    if verbose then
        _out(ctx, "[DWKit Test] post-state (roomentities buckets)")
        _out(ctx, "  players=" .. tostring(_countMap(players)) .. " mobs=" .. tostring(_countMap(roomState.mobs)) ..
            " items=" .. tostring(_countMap(roomState.items)) .. " unknown=" .. tostring(_countMap(unknown)))
        _out(ctx, "  players.has(Borai)=" .. tostring(okMoved))
        _out(ctx, "  unknown.has('Borai hates bugs')=" .. tostring(stillUnknown))
        _out(ctx, "")
        _out(ctx, "[DWKit Test] post-state (watcher)")
        _pp(ctx, st1, { maxDepth = 2, maxItems = 40 })
        _out(ctx, "")
        _out(ctx, "  expectedLastEvent=" .. tostring(evRoomUpdated))
        _out(ctx, "  observedLastEvent=" .. tostring(lastEv))
        _out(ctx, "  receivedCount " .. tostring(rc0) .. " -> " .. tostring(rc1))
        _out(ctx, "")
    end

    local okAll = true
    local fails = {}

    if okMoved ~= true then
        okAll = false
        fails[#fails + 1] = "reclassify check failed: players['Borai'] not present"
    end
    if stillUnknown == true then
        okAll = false
        fails[#fails + 1] = "reclassify check failed: unknown['Borai hates bugs'] still present"
    end
    if okWatcherSawRoom ~= true then
        okAll = false
        fails[#fails + 1] = "event watcher did not end on RoomEntities Updated (lastEvent=" .. tostring(lastEv) .. ")"
    end

    if okAll then
        _out(ctx, "[DWKit Test] PASS (room)")
        _out(ctx, "  reclassify=OK (unknown -> players)")
        _out(ctx, "  watcherLastEvent=OK (" .. tostring(evRoomUpdated) .. ")")
        return true
    end

    _out(ctx, "[DWKit Test] FAIL (room)")
    for _, f in ipairs(fails) do
        _out(ctx, "  - " .. tostring(f))
    end
    _out(ctx, "")
    _out(ctx, "Tips (diagnostics):")
    _out(ctx, "  - Run: dwroom status")
    _out(ctx, "  - Run: dwwho status")
    _out(ctx, "  - Run: dwevent " .. tostring(evRoomUpdated))
    _out(ctx, "  - Run: dwevent " .. tostring(Who.EV_UPDATED or "DWKit:Service:WhoStore:Updated"))

    return false
end

function M.dispatch(ctx, testRunner, args)
    args = (type(args) == "table") and args or {}
    local mode = tostring(args.mode or "")
    local verbose = (args.verbose == true)

    if type(testRunner) ~= "table" or type(testRunner.run) ~= "function" then
        _err(ctx, "DWKit.test.run not available. Run loader.init() first.")
        return false
    end

    if mode == "quiet" then
        testRunner.run({ quiet = true })
        return true
    end

    if mode == "room" then
        return _runRoomMiniTest(ctx, verbose)
    end

    if mode == "ui" then
        local v = nil
        if ctx and type(ctx.getUiValidator) == "function" then
            v = ctx.getUiValidator()
        end

        if type(v) ~= "table" then
            _err(ctx, "dwkit.ui.ui_validator not available. Create src/dwkit/ui/ui_validator.lua first.")
            return false
        end
        if type(v.validateAll) ~= "function" then
            _err(ctx, "ui_validator.validateAll not available.")
            return false
        end

        _out(ctx, "[DWKit Test] UI Safety Gate (dwtest ui)")
        _out(ctx, "  validator=" .. tostring(v.VERSION or "unknown"))
        _out(ctx, "  mode=" .. (verbose and "verbose" or "compact"))
        _out(ctx, "")

        local okCall, a, b, c, err = _callBestEffort(ctx, v, "validateAll", { source = "dwtest" })
        if not okCall then
            _err(ctx, "validateAll failed: " .. tostring(err))
            return false
        end
        if a ~= true then
            _err(ctx, tostring(b or c or err or "validateAll failed"))
            return false
        end

        if verbose then
            _out(ctx, "[DWKit Test] UI validateAll details (bounded)")
            _pp(ctx, b, { maxDepth = 3, maxItems = 40 })
            if type(b) == "table" and tonumber(b.count or 0) == 0 then
                _out(ctx, "")
                _printNoUiNote(ctx)
            end
            return true
        end

        local cts = _summarizeValidateAll(b)
        _out(ctx, string.format("[DWKit Test] UI summary: PASS=%d WARN=%d FAIL=%d SKIP=%d total=%d",
            cts.pass, cts.warn, cts.fail, cts.skip, cts.count))

        if cts.count == 0 then
            _out(ctx, "")
            _printNoUiNote(ctx)
            return true
        end

        if #cts.list > 0 then
            _out(ctx, "")
            _out(ctx, "[DWKit Test] UI WARN/FAIL (compact)")
            local limit = math.min(#cts.list, 25)
            for i = 1, limit do
                local r = cts.list[i]
                local st = tostring(r.status or "UNKNOWN")
                local id = tostring(r.uiId or "?")
                local msg = _firstMsgFrom(r) or ""
                if msg ~= "" then
                    _out(ctx, string.format("  - %s  uiId=%s  msg=%s", st, id, msg))
                else
                    _out(ctx, string.format("  - %s  uiId=%s", st, id))
                end
            end
            if #cts.list > limit then
                _out(ctx, "  ... (" .. tostring(#cts.list - limit) .. " more)")
            end
        end

        return true
    end

    -- default
    testRunner.run()
    return true
end

return M
