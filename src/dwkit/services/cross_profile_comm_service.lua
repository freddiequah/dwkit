-- FILE: src/dwkit/services/cross_profile_comm_service.lua
-- #########################################################################
-- Module Name : dwkit.services.cross_profile_comm_service
-- Owner       : Services
-- Version     : v2026-03-11C
-- Purpose     :
--   - SAFE cross-profile communication (same Mudlet instance) using raiseGlobalEvent.
--   - Data/event delivery only. Does NOT execute remote commands. No expandAlias.
--   - Provides HELLO/BYE presence signals and peer lastSeen tracking (session-only).
--   - Provides a narrow ROWFACTS transport/store for represented-row facts
--     (session-only; best-effort; compatibility-conscious addition).
--   - Provides publisher-side local row-facts composition/publication using
--     existing local ScoreStore + PracticeStore state, triggered by their
--     update events (manual/passive only; no timers, no send()).
--   - Emits a registered internal event when peer state changes.
--
-- IMPORTANT COMPAT FIX (v2026-02-26B):
--   - Some Mudlet builds only allow raiseGlobalEvent args of boolean/number/string/nil.
--     They reject tables (seen in your logs).
--   - Therefore CPC now encodes envelopes into a string for transport, and decodes on receive.
--
-- Fix v2026-02-26D:
--   - install() is idempotent but must support "re-announce HELLO" when called again.
--     This fixes the real-world case where Profile A installs first, Profile B installs later,
--     and B would otherwise not see A until A manually republishes HELLO.
--   - Behavior remains SAFE: no timers, no send(), no polling.
--
-- Add v2026-03-10A:
--   - Adds narrow ROWFACTS transport/store for represented-row facts.
--   - Adds read API for ActionPadService composition:
--       * getRowFactsByProfile(profileName) -> table|nil
--       * publishRowFacts(rowFacts, opts?) -> boolean ok, string|nil err
--   - Adds session-only test helpers:
--       * _testSetRowFacts(profileName, rowFacts, opts?) -> boolean ok, string|nil err
--       * _testClearRowFacts() -> boolean ok
--
-- Add v2026-03-11A:
--   - Adds publisher-side local row-facts composition/publication:
--       * getLocalRowFacts() -> table|nil
--       * publishLocalRowFacts(opts?) -> boolean ok, string|nil err
--   - Wires best-effort subscriptions to:
--       * DWKit:Service:ScoreStore:Updated
--       * DWKit:Service:PracticeStore:Updated
--     so local represented-row facts are republished when manual/passive
--     store updates occur.
--
-- Fix v2026-03-11C:
--   - Hardens publisher subscription state so false is NOT treated as a live handle.
--   - BUS.on(...) failures that return false no longer appear as hasScoreSub/hasPracticeSub=true.
--   - Repeated install() calls can now repair a previously failed score/practice subscription.
--
-- Public API  :
--   - getVersion() -> string
--   - getUpdatedEventName() -> string
--   - getState() -> table copy
--   - getStats() -> table
--   - status() -> table (compat helper; stable fields for diagnostics)
--   - install(opts?) -> boolean ok, string|nil err
--   - isInstalled() -> boolean
--   - publish(topic, payload?, opts?) -> boolean ok, string|nil err
--   - publishRowFacts(rowFacts, opts?) -> boolean ok, string|nil err
--   - publishLocalRowFacts(opts?) -> boolean ok, string|nil err
--   - isProfileOnline(profileName) -> boolean
--   - getRowFactsByProfile(profileName) -> table|nil
--   - getLocalRowFacts() -> table|nil
--
-- Test helpers (SAFE; session-only):
--   - _testNotePeer(profileName, opts?) -> boolean ok, string|nil err
--   - _testClearPeers() -> boolean ok
--   - _testSetRowFacts(profileName, rowFacts, opts?) -> boolean ok, string|nil err
--   - _testClearRowFacts() -> boolean ok
--
-- Events Emitted:
--   - DWKit:Service:CrossProfileComm:Updated
-- Events Consumed:
--   - DWKit:Service:ScoreStore:Updated (best-effort; publisher-side only)
--   - DWKit:Service:PracticeStore:Updated (best-effort; publisher-side only)
-- Automation Policy:
--   - Manual only. Uses Mudlet lifecycle events sysExitEvent (best-effort) and
--     passive/manual service update events; no timers, no send().
-- Dependencies     : dwkit.core.identity, dwkit.bus.event_bus
-- #########################################################################

local M = {}

M.VERSION = "v2026-03-11C"

local ID = require("dwkit.core.identity")
local BUS = require("dwkit.bus.event_bus")

local EV_UPDATED = tostring(ID.eventPrefix or "DWKit:") .. "Service:CrossProfileComm:Updated"
M.EV_UPDATED = EV_UPDATED

local GLOBAL_EVENT_NAME = tostring(ID.eventPrefix or "DWKit:") .. "CPC:Msg"

local STATE = {
    installed = false,
    instanceId = nil,
    myProfile = nil,

    handlerGlobalMsg = nil,
    handlerExit = nil,

    peers = {},             -- key -> { profile=..., instanceId=..., lastSeenTs=..., lastTopic=..., lastPayloadType=... }
    rowFactsByProfile = {}, -- profileName -> normalized rowFacts (session-only; peers only)
    localRowFacts = nil,    -- normalized rowFacts last composed/published locally

    publisher = {
        wired = false,
        scoreSub = nil,
        practiceSub = nil,
        lastPublishTs = nil,
        lastPublishOk = nil,
        lastPublishErr = nil,
        lastSource = nil,
    },

    stats = {
        emits = 0,
        receives = 0,
        ignoredSelf = 0,
        ignoredBad = 0,
        lastEmitTs = nil,
        lastRecvTs = nil,
        lastErr = nil,
    },
}

local function _shallowCopy(t)
    local out = {}
    if type(t) ~= "table" then return out end
    for k, v in pairs(t) do out[k] = v end
    return out
end

local function _deepCopy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, val in pairs(v) do
        out[k] = _deepCopy(val)
    end
    return out
end

local function _copyPeers(peers)
    local out = {}
    if type(peers) ~= "table" then return out end
    for k, v in pairs(peers) do
        if type(k) == "string" and type(v) == "table" then
            out[k] = {
                profile = tostring(v.profile or ""),
                instanceId = tostring(v.instanceId or ""),
                lastSeenTs = v.lastSeenTs,
                lastTopic = tostring(v.lastTopic or ""),
                lastPayloadType = tostring(v.lastPayloadType or ""),
            }
        end
    end
    return out
end

local function _copyRowFactsMap(src)
    local out = {}
    if type(src) ~= "table" then return out end
    for k, v in pairs(src) do
        if type(k) == "string" and type(v) == "table" then
            out[k] = _deepCopy(v)
        end
    end
    return out
end

local function _hasLiveSubscription(handle)
    return not (handle == nil or handle == false)
end

local function _copyPublisherStatus(src)
    src = (type(src) == "table") and src or {}
    return {
        wired = (src.wired == true),
        hasScoreSub = _hasLiveSubscription(src.scoreSub),
        hasPracticeSub = _hasLiveSubscription(src.practiceSub),
        lastPublishTs = src.lastPublishTs,
        lastPublishOk = src.lastPublishOk,
        lastPublishErr = src.lastPublishErr,
        lastSource = tostring(src.lastSource or ""),
    }
end

local function _trim(s)
    s = tostring(s or "")
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function _lowerCollapseSpaces(s)
    s = _trim(s):lower()
    s = s:gsub("%s+", " ")
    return s
end

local function _normalizePracticeKeyLocal(raw)
    return _lowerCollapseSpaces(raw)
end

local function _safeRequire(modName)
    local ok, mod = pcall(require, modName)
    if ok then return true, mod end
    return false, mod
end

local function _myProfileNameBestEffort()
    if type(getProfileName) == "function" then
        local ok, v = pcall(getProfileName)
        if ok and type(v) == "string" and v ~= "" then
            return v
        end
    end
    return "unknown-profile"
end

local function _ensureInstanceId()
    if type(STATE.instanceId) == "string" and STATE.instanceId ~= "" then
        return STATE.instanceId
    end

    local seed = os.time()
    local okRand = pcall(function()
        if type(math.randomseed) == "function" then
            math.randomseed(seed)
        end
        if type(math.random) == "function" then
            math.random()
            math.random()
        end
    end)

    local r = 0
    if okRand and type(math.random) == "function" then
        r = math.random(100000, 999999)
    else
        r = (seed % 900000) + 100000
    end

    STATE.instanceId = string.format("%d-%d", tonumber(seed) or 0, tonumber(r) or 0)
    return STATE.instanceId
end

local function _mkPeerKey(profile, instanceId)
    profile = tostring(profile or "")
    instanceId = tostring(instanceId or "")
    if profile == "" or instanceId == "" then return nil end
    return profile .. ":" .. instanceId
end

local function _emitUpdated(stateCopy, delta, source)
    local payload = {
        ts = os.time(),
        state = stateCopy,
    }
    if type(delta) == "table" then payload.delta = delta end
    if type(source) == "string" and source ~= "" then payload.source = source end

    local meta = {
        source = tostring(source or "CrossProfileCommService"),
        service = "dwkit.services.cross_profile_comm_service",
        ts = payload.ts,
    }

    local okCall, okEmit, delivered, errs = pcall(BUS.emit, EV_UPDATED, payload, meta)
    if okCall and okEmit == true then
        STATE.stats.emits = (tonumber(STATE.stats.emits) or 0) + 1
        STATE.stats.lastEmitTs = payload.ts
        STATE.stats.lastErr = nil
        return true, nil
    end

    local errMsg = nil
    if okCall ~= true then
        errMsg = tostring(okEmit)
    else
        if type(errs) == "table" and errs[1] ~= nil then
            errMsg = tostring(errs[1])
        else
            errMsg = "emit returned ok=false"
        end
    end

    STATE.stats.lastErr = errMsg
    return false, errMsg
end

-- #########################################################################
-- Transport encoding (string-only for raiseGlobalEvent)
-- #########################################################################

local function _esc(s)
    s = tostring(s or "")
    s = s:gsub("%%", "%%25")
    s = s:gsub("|", "%%7C")
    s = s:gsub("=", "%%3D")
    s = s:gsub("\n", "%%0A")
    s = s:gsub("\r", "%%0D")
    return s
end

local function _unesc(s)
    s = tostring(s or "")
    s = s:gsub("%%0D", "\r")
    s = s:gsub("%%0A", "\n")
    s = s:gsub("%%3D", "=")
    s = s:gsub("%%7C", "|")
    s = s:gsub("%%25", "%%")
    return s
end

local function _encodeEnvelope(env)
    if type(env) ~= "table" then
        return nil
    end

    local payloadType = type(env.payload)
    local payloadStr = ""
    if payloadType == "string" or payloadType == "number" or payloadType == "boolean" then
        payloadStr = tostring(env.payload)
    else
        payloadStr = ""
    end

    local parts = {
        "v=" .. _esc(env.v or 1),
        "ts=" .. _esc(env.ts or os.time()),
        "fromProfile=" .. _esc(env.fromProfile or ""),
        "fromInstanceId=" .. _esc(env.fromInstanceId or ""),
        "topic=" .. _esc(env.topic or ""),
        "source=" .. _esc(env.source or ""),
        "payloadType=" .. _esc(payloadType),
        "payload=" .. _esc(payloadStr),
    }

    return table.concat(parts, "|")
end

local function _decodeEnvelope(s)
    if type(s) ~= "string" or s == "" then
        return nil
    end

    local t = {}
    for part in s:gmatch("([^|]+)") do
        local k, v = part:match("^([^=]+)=(.*)$")
        if k and v then
            t[_unesc(k)] = _unesc(v)
        end
    end

    if next(t) == nil then
        return nil
    end

    local env = {
        v = tonumber(t.v) or 1,
        ts = tonumber(t.ts) or os.time(),
        fromProfile = tostring(t.fromProfile or ""),
        fromInstanceId = tostring(t.fromInstanceId or ""),
        topic = tostring(t.topic or ""),
        payload = nil,
        source = (t.source ~= "" and t.source) or nil,
    }

    local pt = tostring(t.payloadType or "")
    local pv = tostring(t.payload or "")
    if pt == "string" then
        env.payload = pv
    elseif pt == "number" then
        env.payload = tonumber(pv)
    elseif pt == "boolean" then
        env.payload = (pv == "true")
    else
        env.payload = nil
    end

    return env
end

local function _mkEnvelope(topic, payload, opts)
    opts = (type(opts) == "table") and opts or {}

    local env = {
        v = 1,
        ts = os.time(),
        fromProfile = STATE.myProfile or _myProfileNameBestEffort(),
        fromInstanceId = _ensureInstanceId(),
        topic = tostring(topic or ""),
        payload = payload,
    }

    if type(opts.source) == "string" and opts.source ~= "" then
        env.source = tostring(opts.source)
    end

    return env
end

local function _looksValidEnvelope(env)
    if type(env) ~= "table" then return false end
    if type(env.fromProfile) ~= "string" or env.fromProfile == "" then return false end
    if type(env.fromInstanceId) ~= "string" or env.fromInstanceId == "" then return false end
    if type(env.topic) ~= "string" or env.topic == "" then return false end
    return true
end

-- #########################################################################
-- Narrow ROWFACTS payload codec
-- #########################################################################

local function _normalizeLearnedMap(map)
    local out = {}
    if type(map) ~= "table" then return out end
    for k, v in pairs(map) do
        local pk = _normalizePracticeKeyLocal(k)
        if pk ~= "" and (v == true or v == false) then
            out[pk] = v
        end
    end
    return out
end

local function _normalizeRowFacts(rowFacts, profileName)
    if type(rowFacts) ~= "table" then
        return nil, "rowFacts must be a table"
    end

    local out = {
        name = _trim(rowFacts.name),
        class = _trim(rowFacts.class),
        classKey = _trim(rowFacts.classKey),
        level = tonumber(rowFacts.level),
        practiceStale = (rowFacts.practiceStale == true),
        scoreStale = (rowFacts.scoreStale == true),
        learnedByPracticeKey = _normalizeLearnedMap(rowFacts.learnedByPracticeKey or rowFacts.practiceKeysLearned),
        sourceProfile = _trim(profileName),
        sourceTs = os.time(),
    }

    return out, nil
end

local function _encodeRowFactsPayload(rowFacts)
    local rf, err = _normalizeRowFacts(rowFacts, rowFacts and rowFacts.sourceProfile or nil)
    if type(rf) ~= "table" then
        return nil, tostring(err or "normalizeRowFacts failed")
    end

    local parts = {
        "v=1",
        "name=" .. _esc(rf.name or ""),
        "class=" .. _esc(rf.class or ""),
        "classKey=" .. _esc(rf.classKey or ""),
        "level=" .. _esc(rf.level or ""),
        "practiceStale=" .. _esc(rf.practiceStale == true and "1" or "0"),
        "scoreStale=" .. _esc(rf.scoreStale == true and "1" or "0"),
    }

    local learnedKeys = {}
    for k in pairs(rf.learnedByPracticeKey or {}) do
        learnedKeys[#learnedKeys + 1] = tostring(k)
    end
    table.sort(learnedKeys)

    for i = 1, #learnedKeys do
        local pk = learnedKeys[i]
        local val = rf.learnedByPracticeKey[pk]
        parts[#parts + 1] = "learned:" .. _esc(pk) .. "=" .. (val == true and "1" or "0")
    end

    return table.concat(parts, "|"), nil
end

local function _decodeRowFactsPayload(s, profileName)
    if type(s) ~= "string" or s == "" then
        return nil, "rowFacts payload empty"
    end

    local raw = {
        learnedByPracticeKey = {},
    }

    for part in s:gmatch("([^|]+)") do
        local learnedKey, learnedVal = part:match("^learned:(.-)=(.*)$")
        if learnedKey ~= nil then
            local pk = _normalizePracticeKeyLocal(_unesc(learnedKey))
            if pk ~= "" then
                raw.learnedByPracticeKey[pk] = (tostring(learnedVal) == "1")
            end
        else
            local k, v = part:match("^([^=]+)=(.*)$")
            if k and v then
                k = _unesc(k)
                v = _unesc(v)
                if k == "name" then
                    raw.name = v
                elseif k == "class" then
                    raw.class = v
                elseif k == "classKey" then
                    raw.classKey = v
                elseif k == "level" then
                    raw.level = tonumber(v)
                elseif k == "practiceStale" then
                    raw.practiceStale = (v == "1")
                elseif k == "scoreStale" then
                    raw.scoreStale = (v == "1")
                end
            end
        end
    end

    return _normalizeRowFacts(raw, profileName)
end

local function _storeRowFacts(profileName, rowFacts, source)
    profileName = _trim(profileName)
    if profileName == "" then
        return false, "profileName required"
    end

    local rf, err = _normalizeRowFacts(rowFacts, profileName)
    if type(rf) ~= "table" then
        return false, tostring(err or "normalizeRowFacts failed")
    end

    STATE.rowFactsByProfile[profileName] = rf

    local okEmit, errEmit = _emitUpdated(M.getState(), {
        action = "rowfacts",
        profile = profileName,
    }, source or "rowfacts:store")
    if not okEmit then
        return false, errEmit
    end

    return true, nil
end

-- #########################################################################
-- Local publisher helpers (ScoreStore + PracticeStore -> ROWFACTS)
-- #########################################################################

local function _normalizeClassKeyBestEffort(raw)
    raw = _trim(raw)
    if raw == "" then return "" end

    local okS, S = _safeRequire("dwkit.services.skill_registry_service")
    if okS and type(S) == "table" and type(S.normalizeClassKey) == "function" then
        local ok, ck = pcall(S.normalizeClassKey, raw)
        if ok and type(ck) == "string" and ck ~= "" then
            return ck
        end
    end

    return _lowerCollapseSpaces(raw)
end

local function _getLocalScoreCoreBestEffort()
    local okS, S = _safeRequire("dwkit.services.score_store_service")
    if not okS or type(S) ~= "table" or type(S.getCore) ~= "function" then
        return {
            ok = false,
            reason = "unknown_stale",
        }
    end

    local ok, core = pcall(S.getCore)
    if not ok or type(core) ~= "table" then
        return {
            ok = false,
            reason = "unknown_stale",
        }
    end

    return core
end

local function _getLocalPracticeSnapshotBestEffort()
    local okP, P = _safeRequire("dwkit.services.practice_store_service")
    if not okP or type(P) ~= "table" or type(P.getSnapshot) ~= "function" then
        return nil
    end

    local ok, snap = pcall(P.getSnapshot)
    if not ok or type(snap) ~= "table" then
        return nil
    end

    return snap
end

local function _buildLearnedMapFromPracticeSnapshot(snap)
    local out = {}

    if type(snap) ~= "table" or type(snap.parsed) ~= "table" then
        return out
    end

    local parsed = snap.parsed
    local sections = { "skills", "spells", "raceSkills", "weaponProfs" }

    for i = 1, #sections do
        local secName = sections[i]
        local sec = parsed[secName]
        if type(sec) == "table" then
            for k, v in pairs(sec) do
                local pk = ""
                if type(v) == "table" then
                    pk = _normalizePracticeKeyLocal(v.key or v.practiceKey or k)
                    if pk ~= "" then
                        out[pk] = (v.learned == true)
                    end
                else
                    pk = _normalizePracticeKeyLocal(k)
                    if pk ~= "" then
                        out[pk] = false
                    end
                end
            end
        end
    end

    return out
end

local function _composeLocalRowFacts()
    local core = _getLocalScoreCoreBestEffort()
    local snap = _getLocalPracticeSnapshotBestEffort()

    local learnedMap = {}
    local practiceStale = true
    if type(snap) == "table" and type(snap.parsed) == "table" then
        learnedMap = _buildLearnedMapFromPracticeSnapshot(snap)
        practiceStale = false
    end

    local name = ""
    local classDisplay = ""
    local classKey = ""
    local level = nil
    local scoreStale = true

    if type(core) == "table" and core.ok == true and tostring(core.reason or "") == "ok" then
        name = _trim(core.name)
        classDisplay = _trim(core.class)
        classKey = _trim(core.classKey)
        if classKey == "" and classDisplay ~= "" then
            classKey = _normalizeClassKeyBestEffort(classDisplay)
        end
        level = tonumber(core.level)
        scoreStale = false
    end

    return _normalizeRowFacts({
        name = name,
        class = classDisplay,
        classKey = classKey,
        level = level,
        practiceStale = practiceStale,
        scoreStale = scoreStale,
        learnedByPracticeKey = learnedMap,
    }, STATE.myProfile or _myProfileNameBestEffort())
end

local function _setLocalRowFacts(rowFacts)
    if type(rowFacts) ~= "table" then
        STATE.localRowFacts = nil
        return
    end
    STATE.localRowFacts = _deepCopy(rowFacts)
end

local function _publishLocalRowFactsOnUpdate(source)
    local ok, err = pcall(function()
        local okPub, errPub = M.publishLocalRowFacts({ source = source })
        if okPub ~= true then
            STATE.publisher.lastPublishOk = false
            STATE.publisher.lastPublishErr = tostring(errPub or "publishLocalRowFacts failed")
            STATE.publisher.lastPublishTs = os.time()
            STATE.publisher.lastSource = tostring(source or "")
        end
    end)

    if ok ~= true then
        STATE.publisher.lastPublishOk = false
        STATE.publisher.lastPublishErr = tostring(err)
        STATE.publisher.lastPublishTs = os.time()
        STATE.publisher.lastSource = tostring(source or "")
    end
end

local function _wirePublisherBestEffort()
    local haveScoreSub = _hasLiveSubscription(STATE.publisher.scoreSub)
    local havePracticeSub = _hasLiveSubscription(STATE.publisher.practiceSub)

    if haveScoreSub and havePracticeSub then
        STATE.publisher.wired = true
        STATE.publisher.lastPublishErr = nil
        return true, nil
    end

    local scoreEvent = nil
    if not haveScoreSub then
        local okS, S = _safeRequire("dwkit.services.score_store_service")
        if okS and type(S) == "table" and type(S.getUpdatedEventName) == "function" then
            local ok, ev = pcall(S.getUpdatedEventName)
            if ok and type(ev) == "string" and ev ~= "" then
                scoreEvent = ev
            end
        end
    end

    local practiceEvent = nil
    if not havePracticeSub then
        local okP, P = _safeRequire("dwkit.services.practice_store_service")
        if okP and type(P) == "table" and type(P.getUpdatedEventName) == "function" then
            local ok, ev = pcall(P.getUpdatedEventName)
            if ok and type(ev) == "string" and ev ~= "" then
                practiceEvent = ev
            end
        end
    end

    if not haveScoreSub and type(scoreEvent) == "string" and scoreEvent ~= "" and type(BUS.on) == "function" then
        local okCall, subHandle, regErr = pcall(BUS.on, scoreEvent, function(payload, meta)
            _publishLocalRowFactsOnUpdate("publisher:score_updated")
        end)
        if okCall and _hasLiveSubscription(subHandle) then
            STATE.publisher.scoreSub = subHandle
        else
            STATE.publisher.scoreSub = nil
        end
    end

    if not havePracticeSub and type(practiceEvent) == "string" and practiceEvent ~= "" and type(BUS.on) == "function" then
        local okCall, subHandle, regErr = pcall(BUS.on, practiceEvent, function(payload, meta)
            _publishLocalRowFactsOnUpdate("publisher:practice_updated")
        end)
        if okCall and _hasLiveSubscription(subHandle) then
            STATE.publisher.practiceSub = subHandle
        else
            STATE.publisher.practiceSub = nil
        end
    end

    haveScoreSub = _hasLiveSubscription(STATE.publisher.scoreSub)
    havePracticeSub = _hasLiveSubscription(STATE.publisher.practiceSub)
    STATE.publisher.wired = (haveScoreSub and havePracticeSub)

    if STATE.publisher.wired == true then
        STATE.publisher.lastPublishErr = nil
        return true, nil
    end

    STATE.publisher.lastPublishErr = string.format(
        "publisher wiring incomplete (scoreSub=%s, practiceSub=%s)",
        tostring(haveScoreSub),
        tostring(havePracticeSub)
    )
    return false, STATE.publisher.lastPublishErr
end

local function _receiveEnvelope(envOrString, source)
    source = tostring(source or "cpc:recv")

    local env = nil
    if type(envOrString) == "table" then
        env = envOrString
    elseif type(envOrString) == "string" then
        env = _decodeEnvelope(envOrString)
    else
        env = nil
    end

    if not _looksValidEnvelope(env) then
        STATE.stats.ignoredBad = (tonumber(STATE.stats.ignoredBad) or 0) + 1
        return false, "bad envelope"
    end

    local selfProfile = STATE.myProfile or _myProfileNameBestEffort()
    local selfId = _ensureInstanceId()

    if tostring(env.fromProfile) == tostring(selfProfile) and tostring(env.fromInstanceId) == tostring(selfId) then
        STATE.stats.ignoredSelf = (tonumber(STATE.stats.ignoredSelf) or 0) + 1
        return true, nil
    end

    local k = _mkPeerKey(env.fromProfile, env.fromInstanceId)
    if not k then
        STATE.stats.ignoredBad = (tonumber(STATE.stats.ignoredBad) or 0) + 1
        return false, "bad peer key"
    end

    local before = STATE.peers[k]
    local nowTs = os.time()

    if tostring(env.topic) == "BYE" then
        if before ~= nil then
            STATE.peers[k] = nil
        end
        STATE.rowFactsByProfile[tostring(env.fromProfile)] = nil

        local okEmit, errEmit = _emitUpdated(M.getState(), {
            peer = k,
            action = "bye",
            profile = tostring(env.fromProfile),
        }, source)
        if not okEmit then return false, errEmit end

        STATE.stats.receives = (tonumber(STATE.stats.receives) or 0) + 1
        STATE.stats.lastRecvTs = nowTs
        return true, nil
    end

    local payloadType = type(env.payload)
    STATE.peers[k] = {
        profile = tostring(env.fromProfile),
        instanceId = tostring(env.fromInstanceId),
        lastSeenTs = nowTs,
        lastTopic = tostring(env.topic),
        lastPayloadType = tostring(payloadType),
    }

    if tostring(env.topic) == "ROWFACTS" then
        local rf, errRf = _decodeRowFactsPayload(tostring(env.payload or ""), tostring(env.fromProfile))
        if type(rf) ~= "table" then
            STATE.stats.ignoredBad = (tonumber(STATE.stats.ignoredBad) or 0) + 1
            return false, "bad ROWFACTS payload: " .. tostring(errRf)
        end

        STATE.rowFactsByProfile[tostring(env.fromProfile)] = rf

        local okEmit, errEmit = _emitUpdated(M.getState(), {
            peer = k,
            action = "rowfacts",
            profile = tostring(env.fromProfile),
        }, source)
        if not okEmit then return false, errEmit end

        STATE.stats.receives = (tonumber(STATE.stats.receives) or 0) + 1
        STATE.stats.lastRecvTs = nowTs
        return true, nil
    end

    local changed = false
    if before == nil then
        changed = true
    else
        if tostring(before.lastTopic or "") ~= tostring(env.topic) then changed = true end
        if tonumber(before.lastSeenTs) ~= tonumber(nowTs) then changed = true end
    end

    if changed then
        local okEmit, errEmit = _emitUpdated(M.getState(), { peer = k, action = "seen", topic = tostring(env.topic) },
            source)
        if not okEmit then return false, errEmit end
    end

    STATE.stats.receives = (tonumber(STATE.stats.receives) or 0) + 1
    STATE.stats.lastRecvTs = nowTs
    return true, nil
end

local function _reannounceHelloBestEffort(source)
    source = tostring(source or "install:reannounce")
    STATE.myProfile = STATE.myProfile or _myProfileNameBestEffort()
    _ensureInstanceId()

    pcall(function()
        M.publish("HELLO", "", { source = source })
    end)

    pcall(function()
        M.publishLocalRowFacts({ source = source .. ":rowfacts" })
    end)

    pcall(function()
        _emitUpdated(M.getState(), { action = "reannounce", myProfile = STATE.myProfile }, source)
    end)

    return true, nil
end

function M.getVersion()
    return tostring(M.VERSION)
end

function M.getUpdatedEventName()
    return tostring(EV_UPDATED)
end

function M.isInstalled()
    return (STATE.installed == true)
end

function M.getState()
    return {
        version = M.VERSION,
        installed = (STATE.installed == true),
        globalEventName = GLOBAL_EVENT_NAME,
        myProfile = tostring(STATE.myProfile or ""),
        instanceId = tostring(STATE.instanceId or ""),
        peers = _copyPeers(STATE.peers),
        rowFactsByProfile = _copyRowFactsMap(STATE.rowFactsByProfile),
        localRowFacts = _deepCopy(STATE.localRowFacts),
        publisher = _copyPublisherStatus(STATE.publisher),
    }
end

function M.getStats()
    local peerCount = 0
    for _ in pairs(STATE.peers or {}) do peerCount = peerCount + 1 end

    local rowFactsCount = 0
    for _ in pairs(STATE.rowFactsByProfile or {}) do rowFactsCount = rowFactsCount + 1 end

    return {
        version = M.VERSION,
        installed = (STATE.installed == true),
        myProfile = tostring(STATE.myProfile or ""),
        instanceId = tostring(STATE.instanceId or ""),
        peerCount = peerCount,
        rowFactsCount = rowFactsCount,
        localRowFactsPresent = (type(STATE.localRowFacts) == "table"),
        stats = _shallowCopy(STATE.stats),
        publisher = _copyPublisherStatus(STATE.publisher),
        handlers = {
            globalMsg = STATE.handlerGlobalMsg,
            exit = STATE.handlerExit,
        },
    }
end

function M.status()
    local st = M.getStats()
    return {
        myProfile = st.myProfile,
        instanceId = st.instanceId,
        peerCount = st.peerCount,
        peers = M.getState().peers,
        rowFactsCount = st.rowFactsCount,
        localRowFactsPresent = st.localRowFactsPresent,
        publisherWired = (type(st.publisher) == "table" and st.publisher.wired == true),
        installed = st.installed,
        version = st.version,
    }
end

function M.publish(topic, payload, opts)
    opts = (type(opts) == "table") and opts or {}

    if type(raiseGlobalEvent) ~= "function" then
        return false, "raiseGlobalEvent() not available"
    end

    topic = tostring(topic or "")
    if topic == "" then
        return false, "topic must be non-empty"
    end

    STATE.myProfile = STATE.myProfile or _myProfileNameBestEffort()
    _ensureInstanceId()

    local env = _mkEnvelope(topic, payload, opts)

    local wire = _encodeEnvelope(env)
    if type(wire) ~= "string" or wire == "" then
        return false, "failed to encode envelope"
    end

    local okCall, errCall = pcall(raiseGlobalEvent, GLOBAL_EVENT_NAME, wire)
    if okCall then
        return true, nil
    end

    return false, tostring(errCall)
end

function M.publishRowFacts(rowFacts, opts)
    opts = (type(opts) == "table") and opts or {}

    local rf, errRf = _normalizeRowFacts(rowFacts, STATE.myProfile or _myProfileNameBestEffort())
    if type(rf) ~= "table" then
        return false, tostring(errRf or "normalizeRowFacts failed")
    end

    local payload, errPayload = _encodeRowFactsPayload(rf)
    if type(payload) ~= "string" or payload == "" then
        return false, tostring(errPayload or "encodeRowFactsPayload failed")
    end

    return M.publish("ROWFACTS", payload, { source = tostring(opts.source or "publishRowFacts") })
end

function M.publishLocalRowFacts(opts)
    opts = (type(opts) == "table") and opts or {}
    local source = tostring(opts.source or "publishLocalRowFacts")

    STATE.myProfile = STATE.myProfile or _myProfileNameBestEffort()
    _ensureInstanceId()

    local rf, errRf = _composeLocalRowFacts()
    if type(rf) ~= "table" then
        STATE.publisher.lastPublishOk = false
        STATE.publisher.lastPublishErr = tostring(errRf or "composeLocalRowFacts failed")
        STATE.publisher.lastPublishTs = os.time()
        STATE.publisher.lastSource = source
        return false, STATE.publisher.lastPublishErr
    end

    _setLocalRowFacts(rf)

    local okPub, errPub = M.publishRowFacts(rf, { source = source })
    STATE.publisher.lastPublishOk = (okPub == true)
    STATE.publisher.lastPublishErr = errPub
    STATE.publisher.lastPublishTs = os.time()
    STATE.publisher.lastSource = source

    pcall(function()
        _emitUpdated(M.getState(), {
            action = "local_rowfacts_publish",
            profile = tostring(STATE.myProfile or ""),
            ok = (okPub == true),
        }, source)
    end)

    if okPub ~= true then
        return false, tostring(errPub or "publishLocalRowFacts failed")
    end

    return true, nil
end

function M.isProfileOnline(profileName)
    profileName = tostring(profileName or "")
    if profileName == "" then return false end

    if profileName == tostring(STATE.myProfile or "") then
        return (STATE.installed == true)
    end

    for _, rec in pairs(STATE.peers or {}) do
        if type(rec) == "table" and tostring(rec.profile or "") == profileName then
            return true
        end
    end

    return false
end

function M.getRowFactsByProfile(profileName)
    profileName = _trim(profileName)
    if profileName == "" then return nil end
    local rf = STATE.rowFactsByProfile[profileName]
    if type(rf) ~= "table" then return nil end
    return _deepCopy(rf)
end

function M.getLocalRowFacts()
    if type(STATE.localRowFacts) ~= "table" then return nil end
    return _deepCopy(STATE.localRowFacts)
end

function M._testClearPeers()
    STATE.peers = {}
    return true
end

function M._testNotePeer(profileName, opts)
    opts = (type(opts) == "table") and opts or {}

    profileName = tostring(profileName or "")
    if profileName == "" then return false, "profileName required" end

    local fakeId = tostring(opts.instanceId or "TEST-1")
    local key = _mkPeerKey(profileName, fakeId)
    if not key then return false, "peer key failed" end

    STATE.peers[key] = {
        profile = profileName,
        instanceId = fakeId,
        lastSeenTs = os.time(),
        lastTopic = "HELLO",
        lastPayloadType = "table",
    }

    local okEmit, errEmit = _emitUpdated(M.getState(), { peer = key, action = "testSeen" }, "test:notePeer")
    if not okEmit then return false, errEmit end

    return true, nil
end

function M._testSetRowFacts(profileName, rowFacts, opts)
    opts = (type(opts) == "table") and opts or {}
    return _storeRowFacts(profileName, rowFacts, tostring(opts.source or "test:setRowFacts"))
end

function M._testClearRowFacts()
    STATE.rowFactsByProfile = {}
    local okEmit, errEmit = _emitUpdated(M.getState(), { action = "rowfacts_clear" }, "test:clearRowFacts")
    if not okEmit then return false, errEmit end
    return true
end

function M.install(opts)
    opts = (type(opts) == "table") and opts or {}

    if STATE.installed == true then
        _wirePublisherBestEffort()

        local allowReannounce = (opts.reannounce ~= false)
        if allowReannounce then
            _reannounceHelloBestEffort("install:reannounce")
        end
        return true, nil
    end

    if type(registerAnonymousEventHandler) ~= "function" then
        return false, "registerAnonymousEventHandler() not available"
    end
    if type(raiseGlobalEvent) ~= "function" then
        return false, "raiseGlobalEvent() not available"
    end

    STATE.myProfile = _myProfileNameBestEffort()
    _ensureInstanceId()

    local handlerId = nil
    do
        local okCall, idOrErr = pcall(registerAnonymousEventHandler, GLOBAL_EVENT_NAME, function(_, wire)
            _receiveEnvelope(wire, "cpc:recv")
        end)
        if okCall and idOrErr ~= nil then
            handlerId = idOrErr
        else
            return false, "Failed to register global CPC handler: " .. tostring(idOrErr)
        end
    end

    STATE.handlerGlobalMsg = handlerId

    local exitId = nil
    do
        local okCall, idOrErr = pcall(registerAnonymousEventHandler, "sysExitEvent", function()
            pcall(function()
                M.publish("BYE", "", { source = "sysExitEvent" })
            end)
        end)
        if okCall and idOrErr ~= nil then
            exitId = idOrErr
        end
    end
    STATE.handlerExit = exitId

    STATE.installed = true

    _wirePublisherBestEffort()

    pcall(function()
        M.publish("HELLO", "", { source = "install" })
    end)

    _emitUpdated(M.getState(), { action = "install", myProfile = STATE.myProfile }, "install")

    pcall(function()
        M.publishLocalRowFacts({ source = "install:init" })
    end)

    return true, nil
end

return M
