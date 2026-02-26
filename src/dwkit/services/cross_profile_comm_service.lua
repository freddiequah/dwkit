-- FILE: src/dwkit/services/cross_profile_comm_service.lua
-- #########################################################################
-- Module Name : dwkit.services.cross_profile_comm_service
-- Owner       : Services
-- Version     : v2026-02-26A
-- Purpose     :
--   - SAFE cross-profile communication (same Mudlet instance) using raiseGlobalEvent.
--   - Data/event delivery only. Does NOT execute remote commands. No expandAlias.
--   - Provides HELLO/BYE presence signals and peer lastSeen tracking (session-only).
--   - Emits a registered internal event when peer state changes.
--
-- Public API  :
--   - getVersion() -> string
--   - getUpdatedEventName() -> string
--   - getState() -> table copy
--   - getStats() -> table
--   - install(opts?) -> boolean ok, string|nil err
--   - isInstalled() -> boolean
--   - publish(topic, payload?, opts?) -> boolean ok, string|nil err
--   - isProfileOnline(profileName) -> boolean
--
-- Test helpers (SAFE; session-only):
--   - _testNotePeer(profileName, opts?) -> boolean ok, string|nil err
--   - _testClearPeers() -> boolean ok
--
-- Events Emitted:
--   - DWKit:Service:CrossProfileComm:Updated
-- Automation Policy:
--   - Manual only. Uses Mudlet lifecycle events sysExitEvent (best-effort) but no timers, no send().
-- Dependencies     : dwkit.core.identity, dwkit.bus.event_bus
-- #########################################################################

local M = {}

M.VERSION = "v2026-02-26A"

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

    peers = {}, -- key -> { profile=..., instanceId=..., lastSeenTs=..., lastTopic=..., lastPayloadType=... }

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

local function _receiveEnvelope(env, source)
    source = tostring(source or "cpc:recv")

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
            local okEmit, errEmit = _emitUpdated(M.getState(), { peer = k, action = "bye" }, source)
            if not okEmit then return false, errEmit end
        end
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
    }
end

function M.getStats()
    local peerCount = 0
    for _ in pairs(STATE.peers or {}) do peerCount = peerCount + 1 end

    return {
        version = M.VERSION,
        installed = (STATE.installed == true),
        myProfile = tostring(STATE.myProfile or ""),
        instanceId = tostring(STATE.instanceId or ""),
        peerCount = peerCount,
        stats = _shallowCopy(STATE.stats),
        handlers = {
            globalMsg = STATE.handlerGlobalMsg,
            exit = STATE.handlerExit,
        },
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

    local okCall, errCall = pcall(raiseGlobalEvent, GLOBAL_EVENT_NAME, env)
    if okCall then
        return true, nil
    end

    return false, tostring(errCall)
end

function M.isProfileOnline(profileName)
    profileName = tostring(profileName or "")
    if profileName == "" then return false end

    -- Self is always "online" when this service is installed (local instance truth)
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

function M.install(opts)
    opts = (type(opts) == "table") and opts or {}

    if STATE.installed == true then
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

    -- Receive cross-profile envelope messages
    local handlerId = nil
    do
        local okCall, idOrErr = pcall(registerAnonymousEventHandler, GLOBAL_EVENT_NAME, function(_, env)
            _receiveEnvelope(env, "cpc:recv")
        end)
        if okCall and idOrErr ~= nil then
            handlerId = idOrErr
        else
            return false, "Failed to register global CPC handler: " .. tostring(idOrErr)
        end
    end

    STATE.handlerGlobalMsg = handlerId

    -- Best-effort BYE on sysExitEvent (immediate close detection)
    local exitId = nil
    do
        local okCall, idOrErr = pcall(registerAnonymousEventHandler, "sysExitEvent", function()
            -- best-effort: do not error on exit
            pcall(function()
                M.publish("BYE", { profile = STATE.myProfile, instanceId = STATE.instanceId },
                    { source = "sysExitEvent" })
            end)
        end)
        if okCall and idOrErr ~= nil then
            exitId = idOrErr
        end
    end
    STATE.handlerExit = exitId

    STATE.installed = true

    -- Send HELLO immediately when installed (start detection)
    pcall(function()
        M.publish("HELLO", { profile = STATE.myProfile, instanceId = STATE.instanceId }, { source = "install" })
    end)

    -- Emit local Updated once (so consumers can recompute immediately)
    _emitUpdated(M.getState(), { action = "install", myProfile = STATE.myProfile }, "install")

    return true, nil
end

return M
