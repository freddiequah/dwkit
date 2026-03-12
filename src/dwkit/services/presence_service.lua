-- FILE: src/dwkit/services/presence_service.lua
-- #########################################################################
-- Module Name : dwkit.services.presence_service
-- Owner       : Services
-- Version     : v2026-03-12A
-- Purpose     :
--   - SAFE, profile-portable PresenceService (data only).
--   - No GMCP dependency, no Mudlet events, no timers, no send().
--   - Emits a registered internal event when state changes.
--   - Service-layer bridge: listens to RoomEntities Updated (and WhoStore Updated)
--     and updates Presence state.
--   - CPC bridge hardening:
--     only peer-presence CPC actions may recompute Presence roster truth.
--     CPC ROWFACTS/non-roster updates must NOT rewrite Presence online/offline
--     state, because ROWFACTS are represented-row facts, not roster-composition truth.
--
-- Public API  :
--   - getVersion() -> string
--   - getState() -> table copy
--   - setState(newState, opts?) -> boolean ok, string|nil err
--   - update(delta, opts?) -> boolean ok, string|nil err
--   - clear(opts?) -> boolean ok, string|nil err
--   - onUpdated(handlerFn) -> boolean ok, number|nil token, string|nil err
--   - getStats() -> table
--   - getUpdatedEventName() -> string
--
-- Events Emitted:
--   - DWKit:Service:Presence:Updated
-- Automation Policy: Manual only (no gameplay commands). Bridge is internal event-driven (SAFE).
-- Dependencies     : dwkit.core.identity, dwkit.bus.event_bus, dwkit.config.owned_profiles (best-effort),
--                    dwkit.services.whostore_service (best-effort), dwkit.services.roomentities_service (best-effort),
--                    dwkit.services.cross_profile_comm_service (best-effort; same-instance local online truth)
--
-- Fix v2026-02-26C:
--   - Presence must match owned_profiles by candidate character token (e.g. "Scynox" from "Scynox the adventurer").
--   - Presence must NOT treat obvious objects ("A/An/The ...") as players in Other players list.
--
-- NEW v2026-02-26D:
--   - Presence roster should NOT show "self" (current profile) in My profiles list.
--     Self is inferred via CPC service myProfile == owned profileLabel.
--
-- Fix v2026-02-26E:
--   - Also hide "self" from backward-compat myProfilesInRoom field.
--     Some UIs may still fallback to myProfilesInRoom; self must never appear there.
--
-- Fix v2026-03-12A:
--   - CPC ROWFACTS updates must NOT trigger Presence roster recompute.
--   - Presence only recomputes from CPC when the CPC delta action is roster-related
--     (seen/bye/install/reannounce/testSeen).
-- #########################################################################

local M = {}

M.VERSION = "v2026-03-12A"

local ID = require("dwkit.core.identity")
local BUS = require("dwkit.bus.event_bus")

local EV_UPDATED = tostring(ID.eventPrefix or "DWKit:") .. "Service:Presence:Updated"

-- Expose event name for UIs and consumers (contract)
M.EV_UPDATED = EV_UPDATED

local STATE = {
    state = {},
    lastTs = nil,
    updates = 0,
}

local function _shallowCopy(t)
    local out = {}
    if type(t) ~= "table" then return out end
    for k, v in pairs(t) do out[k] = v end
    return out
end

local function _merge(dst, src)
    if type(dst) ~= "table" or type(src) ~= "table" then return end
    for k, v in pairs(src) do
        dst[k] = v
    end
end

local function _emit(stateCopy, deltaCopy, source)
    local payload = {
        ts = os.time(),
        state = stateCopy,
    }
    if type(deltaCopy) == "table" then payload.delta = deltaCopy end
    if type(source) == "string" and source ~= "" then payload.source = source end

    local ok, delivered, errs = BUS.emit(EV_UPDATED, payload)
    if not ok then
        local first = (type(errs) == "table" and errs[1]) and tostring(errs[1]) or "emit failed"
        return false, first
    end
    return true, nil
end

local function _safeRequire(modName)
    local ok, mod = pcall(require, modName)
    if ok then return true, mod end
    return false, mod
end

local function _sortedStringKeys(t)
    local keys = {}
    if type(t) ~= "table" then return keys end
    for k, _ in pairs(t) do
        if type(k) == "string" and k ~= "" then
            keys[#keys + 1] = k
        end
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    return keys
end

local function _sortedStringsCaseInsensitive(arr)
    arr = (type(arr) == "table") and arr or {}
    local out = {}
    for i = 1, #arr do out[#out + 1] = tostring(arr[i] or "") end
    table.sort(out, function(a, b)
        local la = tostring(a or ""):lower()
        local lb = tostring(b or ""):lower()
        if la == lb then return tostring(a or "") < tostring(b or "") end
        return la < lb
    end)
    return out
end

local function _countMap(t)
    if type(t) ~= "table" then return 0 end
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

local function _dedupeAndSortStrings(arr)
    arr = (type(arr) == "table") and arr or {}
    local seen = {}
    local out = {}
    for i = 1, #arr do
        local s = tostring(arr[i] or "")
        if s ~= "" and seen[s] ~= true then
            seen[s] = true
            out[#out + 1] = s
        end
    end
    return _sortedStringsCaseInsensitive(out)
end

local function _trim(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- -------------------------------------------------------------------------
-- Owned profiles mapping (best-effort)
-- -------------------------------------------------------------------------

local function _getOwnedProfilesMapBestEffort()
    local okO, O = _safeRequire("dwkit.config.owned_profiles")
    if not okO or type(O) ~= "table" then
        return {}
    end
    if type(O.getMap) ~= "function" then
        return {}
    end
    local okM, m = pcall(O.getMap)
    if okM and type(m) == "table" then
        return m
    end
    return {}
end

local function _getOwnedNamesSorted(map)
    map = (type(map) == "table") and map or {}
    local names = {}
    for name, label in pairs(map) do
        if type(name) == "string" and name ~= "" and type(label) == "string" and label ~= "" then
            names[#names + 1] = name
        end
    end
    return _sortedStringsCaseInsensitive(names)
end

-- -------------------------------------------------------------------------
-- WhoStore online set (best-effort)
-- -------------------------------------------------------------------------

local function _getWhoStoreStatsBestEffort(W, payload)
    local whoTs = nil
    local whoCount = nil

    if type(W) == "table" then
        if type(W.getState) == "function" then
            local okS, st = pcall(W.getState)
            if okS and type(st) == "table" then
                whoTs = st.lastUpdatedTs
                if type(st.snapshot) == "table" and type(st.snapshot.byName) == "table" then
                    whoCount = _countMap(st.snapshot.byName)
                elseif type(st.players) == "table" then
                    whoCount = _countMap(st.players)
                end
            end
        end

        if whoTs == nil and type(W.getSnapshot) == "function" then
            local okSnap, snap = pcall(W.getSnapshot)
            if okSnap and type(snap) == "table" then
                whoTs = snap.ts
                if type(snap.byName) == "table" then
                    whoCount = _countMap(snap.byName)
                end
            end
        end
    end

    if whoTs == nil and type(payload) == "table" then
        whoTs = payload.ts
    end

    return whoTs, whoCount
end

local function _isOnlineBestEffort(W, name)
    if type(name) ~= "string" or name == "" then return false end
    if type(W) ~= "table" then return false end

    if type(W.hasPlayer) == "function" then
        local ok, v = pcall(W.hasPlayer, name)
        if ok then return (v == true) end
    end

    if type(W.getEntry) == "function" then
        local ok, e = pcall(W.getEntry, name)
        if ok and type(e) == "table" then
            return true
        end
    end

    return false
end

local function _resolveWhoStoreUpdatedEventNameBestEffort()
    local okW, W = _safeRequire("dwkit.services.whostore_service")
    if okW and type(W) == "table" then
        if type(W.getUpdatedEventName) == "function" then
            local ok, v = pcall(W.getUpdatedEventName)
            if ok and type(v) == "string" and v ~= "" then
                return v
            end
        end
        if type(W.EV_UPDATED) == "string" and W.EV_UPDATED ~= "" then
            return W.EV_UPDATED
        end
    end

    return tostring(ID.eventPrefix or "DWKit:") .. "Service:WhoStore:Updated"
end

-- -------------------------------------------------------------------------
-- Cross-profile comm (best-effort) local online truth (same instance)
-- -------------------------------------------------------------------------

local function _resolveCpcUpdatedEventNameBestEffort()
    local okC, C = _safeRequire("dwkit.services.cross_profile_comm_service")
    if okC and type(C) == "table" then
        if type(C.getUpdatedEventName) == "function" then
            local ok, v = pcall(C.getUpdatedEventName)
            if ok and type(v) == "string" and v ~= "" then
                return v
            end
        end
        if type(C.EV_UPDATED) == "string" and C.EV_UPDATED ~= "" then
            return C.EV_UPDATED
        end
    end

    return tostring(ID.eventPrefix or "DWKit:") .. "Service:CrossProfileComm:Updated"
end

local function _isLocalProfileOnlineBestEffort(profileLabelOrName)
    profileLabelOrName = tostring(profileLabelOrName or "")
    if profileLabelOrName == "" then return false end

    local okC, C = _safeRequire("dwkit.services.cross_profile_comm_service")
    if not okC or type(C) ~= "table" then
        return false
    end

    if type(C.isProfileOnline) == "function" then
        local ok, v = pcall(C.isProfileOnline, profileLabelOrName)
        if ok then return (v == true) end
    end

    return false
end

local function _getLocalProfileNameBestEffort()
    local okC, C = _safeRequire("dwkit.services.cross_profile_comm_service")
    if okC and type(C) == "table" then
        if type(C.getState) == "function" then
            local okS, st = pcall(C.getState)
            if okS and type(st) == "table" then
                local p = tostring(st.myProfile or "")
                if p ~= "" then
                    return p
                end
            end
        end
        if type(C.getStats) == "function" then
            local okT, st = pcall(C.getStats)
            if okT and type(st) == "table" then
                local p = tostring(st.myProfile or "")
                if p ~= "" then
                    return p
                end
            end
        end
    end

    if type(getProfileName) == "function" then
        local ok, v = pcall(getProfileName)
        if ok and type(v) == "string" and v ~= "" then
            return v
        end
    end

    return ""
end

local function _extractCpcAction(payload)
    payload = (type(payload) == "table") and payload or {}

    if type(payload.delta) == "table" then
        local action = _trim(tostring(payload.delta.action or ""))
        if action ~= "" then
            return action
        end
    end

    local action = _trim(tostring(payload.action or ""))
    if action ~= "" then
        return action
    end

    return ""
end

local function _shouldRecomputeForCpcPayload(payload)
    local action = _extractCpcAction(payload)

    if action == "seen" then return true end
    if action == "bye" then return true end
    if action == "install" then return true end
    if action == "reannounce" then return true end
    if action == "testSeen" then return true end

    if action == "rowfacts" then return false end
    if action == "rowfacts_clear" then return false end
    if action == "local_rowfacts_publish" then return false end

    if action ~= "" then
        return false
    end

    return false
end

-- -------------------------------------------------------------------------
-- Room occupant -> candidate name token (Presence-owned matching)
-- -------------------------------------------------------------------------

local _ARTICLES = {
    ["a"] = true,
    ["an"] = true,
    ["the"] = true,
}

local function _extractCandidateNameToken(label)
    label = tostring(label or "")
    label = _trim(label)
    if label == "" then return nil end

    -- Hard reject obvious objects: "A ...", "An ...", "The ..."
    do
        local firstWord = label:match("^([A-Za-z]+)")
        if firstWord and _ARTICLES[firstWord:lower()] then
            return nil
        end
    end

    -- Candidate token is first word-like token (supports apostrophe)
    local tok = label:match("^([A-Za-z][A-Za-z0-9']*)")
    tok = tostring(tok or "")
    if tok == "" then return nil end

    if _ARTICLES[tok:lower()] then
        return nil
    end

    return tok
end

-- -------------------------------------------------------------------------
-- RoomEntities -> Presence bridge (SAFE, event-driven)
-- -------------------------------------------------------------------------

local _bridge = {
    subscribedRoom = false,
    tokenRoom = nil,
    eventNameRoom = nil,

    subscribedWho = false,
    tokenWho = nil,
    eventNameWho = nil,

    subscribedCpc = false,
    tokenCpc = nil,
    eventNameCpc = nil,

    lastErr = nil,
    running = false,

    lastRoomTs = nil,
    lastRoomPlayers = {},

    lastWhoTs = nil,
    lastWhoCount = nil,
}

local function _extractRoomPlayersBestEffort(payload)
    payload = (type(payload) == "table") and payload or {}

    do
        local okR, R = _safeRequire("dwkit.services.roomentities_service")
        if okR and type(R) == "table" and type(R.getState) == "function" then
            local okS, st = pcall(R.getState)
            if okS and type(st) == "table"
                and type(st.entitiesV2) == "table"
            then
                local roomTs = nil

                if type(R.getStats) == "function" then
                    local okG, stats = pcall(R.getStats)
                    if okG and type(stats) == "table" then
                        roomTs = stats.lastTs
                    end
                end

                if roomTs == nil then
                    roomTs = payload.ts
                end

                local names = {}
                if type(st.entitiesV2.players) == "table" then
                    local ks = _sortedStringKeys(st.entitiesV2.players)
                    for i = 1, #ks do names[#names + 1] = ks[i] end
                end
                if type(st.entitiesV2.unknown) == "table" then
                    local ks = _sortedStringKeys(st.entitiesV2.unknown)
                    for i = 1, #ks do names[#names + 1] = ks[i] end
                end

                return _dedupeAndSortStrings(names), roomTs
            end
        end
    end

    if type(payload.entitiesV2) == "table" then
        local names = {}
        if type(payload.entitiesV2.players) == "table" then
            local ks = _sortedStringKeys(payload.entitiesV2.players)
            for i = 1, #ks do names[#names + 1] = ks[i] end
        end
        if type(payload.entitiesV2.unknown) == "table" then
            local ks = _sortedStringKeys(payload.entitiesV2.unknown)
            for i = 1, #ks do names[#names + 1] = ks[i] end
        end
        if #names > 0 then
            return _dedupeAndSortStrings(names), payload.ts
        end
    end

    if type(payload.state) == "table" then
        local names = {}
        if type(payload.state.players) == "table" then
            local ks = _sortedStringKeys(payload.state.players)
            for i = 1, #ks do names[#names + 1] = ks[i] end
        end
        if type(payload.state.unknown) == "table" then
            local ks = _sortedStringKeys(payload.state.unknown)
            for i = 1, #ks do names[#names + 1] = ks[i] end
        end
        if #names > 0 then
            return _dedupeAndSortStrings(names), payload.ts
        end
    end

    return {}, payload.ts
end

local function _fmtOwned(name, label, tags)
    name = tostring(name or "")
    label = tostring(label or "")
    if name == "" or label == "" then return nil end

    local base = name .. " (" .. label .. ")"
    tags = (type(tags) == "table") and tags or {}

    if #tags <= 0 then
        return base
    end

    local out = base
    for i = 1, #tags do
        local t = tostring(tags[i] or "")
        if t ~= "" then
            out = out .. " [" .. t .. "]"
        end
    end
    return out
end

local function _isSelfOwnedProfile(map, ownedName, profileLabel)
    if type(map) ~= "table" then return false end
    ownedName = tostring(ownedName or "")
    profileLabel = tostring(profileLabel or "")
    if ownedName == "" or profileLabel == "" then return false end

    local selfProfile = _getLocalProfileNameBestEffort()
    if selfProfile == "" then return false end

    return (tostring(profileLabel) == tostring(selfProfile))
end

local function _computePresenceSnapshot(roomPlayers, roomTs, whoPayload, source)
    roomPlayers = (type(roomPlayers) == "table") and roomPlayers or {}
    roomTs = roomTs

    local map = _getOwnedProfilesMapBestEffort()
    local mapCount = _countMap(map)
    local mappingMissing = (mapCount <= 0)

    -- Room membership set for quick "HERE" (keyed by candidate character token)
    local inRoom = {}
    local otherPlayersInRoom = {}

    for i = 1, #roomPlayers do
        local label = tostring(roomPlayers[i] or "")
        label = _trim(label)
        if label ~= "" then
            local cand = _extractCandidateNameToken(label)
            if cand then
                inRoom[cand] = true

                if type(map[cand]) ~= "string" or map[cand] == "" then
                    otherPlayersInRoom[#otherPlayersInRoom + 1] = cand
                end
            end
        end
    end

    otherPlayersInRoom = _dedupeAndSortStrings(otherPlayersInRoom)

    -- WhoStore (best-effort)
    local okW, W = _safeRequire("dwkit.services.whostore_service")
    if not okW or type(W) ~= "table" then
        W = nil
    end

    local whoTs, whoCount = _getWhoStoreStatsBestEffort(W, whoPayload)
    _bridge.lastWhoTs = whoTs
    _bridge.lastWhoCount = whoCount

    -- Backward compat field: My profiles in room (NO TAGS)
    -- Fix v2026-02-26E: hide self here as well.
    local myProfilesInRoom = {}
    do
        for cand, _ in pairs(inRoom) do
            local prof = map[cand]
            if type(prof) == "string" and prof ~= "" then
                if _isSelfOwnedProfile(map, cand, prof) then
                    -- skip self
                else
                    myProfilesInRoom[#myProfilesInRoom + 1] = cand .. " (" .. prof .. ")"
                end
            end
        end
        myProfilesInRoom = _dedupeAndSortStrings(myProfilesInRoom)
    end

    -- New: roster across all owned profiles (online/offline/here)
    local ownedNames = _getOwnedNamesSorted(map)
    local myProfilesOnline = {}
    local myProfilesOffline = {}
    local myProfilesHere = {}

    for i = 1, #ownedNames do
        local name = tostring(ownedNames[i] or "")
        local label = map[name]
        if type(label) == "string" and label ~= "" then
            -- hide self from roster
            if _isSelfOwnedProfile(map, name, label) then
                -- skip
            else
                local localOnline = _isLocalProfileOnlineBestEffort(label)
                local whoOnline = _isOnlineBestEffort(W, name)

                local online = (localOnline == true) or (whoOnline == true)

                if online then
                    local tags = { "ONLINE" }
                    if inRoom[name] == true then
                        tags[#tags + 1] = "HERE"
                    end
                    local line = _fmtOwned(name, label, tags)
                    if line then
                        myProfilesOnline[#myProfilesOnline + 1] = line
                        if inRoom[name] == true then
                            myProfilesHere[#myProfilesHere + 1] = line
                        end
                    end
                else
                    local line = _fmtOwned(name, label, { "OFFLINE" })
                    if line then
                        myProfilesOffline[#myProfilesOffline + 1] = line
                    end
                end
            end
        end
    end

    local hasRoomSnapshot = (roomTs ~= nil)
    local stale = (hasRoomSnapshot ~= true)
    local staleReason = nil
    if stale then
        staleReason = "no room snapshot yet"
    end

    return {
        ts = os.time(),
        source = tostring(source or "presence_bridge"),
        roomTs = roomTs,
        whoTs = whoTs,
        whoCount = whoCount,

        roomPlayerCount = #roomPlayers,
        roomPlayers = roomPlayers, -- raw labels (debug)

        -- Backward compat fields
        myProfilesInRoom = myProfilesInRoom,
        otherPlayersInRoom = otherPlayersInRoom,

        -- New roster fields
        myProfilesOnline = myProfilesOnline,
        myProfilesOffline = myProfilesOffline,
        myProfilesHere = myProfilesHere,

        mapping = {
            count = mapCount,
            missing = mappingMissing,
            hint = mappingMissing and
                "Configure owned profiles mapping (characterName -> profileLabel) in dwkit.config.owned_profiles." or nil,
        },

        stale = stale,
        staleReason = staleReason,
    }
end

local function _applyPresenceSnapshot(snapshot, source)
    if type(snapshot) ~= "table" then
        return false, "snapshot must be table"
    end
    return M.setState(snapshot, { source = source or snapshot.source or "presence_bridge:setState" })
end

local function _recomputeFromLastKnown(source, whoPayload)
    local roomPlayers = (type(_bridge.lastRoomPlayers) == "table") and _bridge.lastRoomPlayers or {}
    local roomTs = _bridge.lastRoomTs
    local snap = _computePresenceSnapshot(roomPlayers, roomTs, whoPayload, source or "presence_bridge:recompute")
    local ok, err = _applyPresenceSnapshot(snap, source or "presence_bridge:recompute")
    if ok ~= true then
        _bridge.lastErr = tostring(err)
        return false, _bridge.lastErr
    end
    _bridge.lastErr = nil
    return true, nil
end

local function _onRoomEntitiesUpdated(payload)
    if _bridge.running == true then
        return
    end
    _bridge.running = true

    local roomPlayers, roomTs = _extractRoomPlayersBestEffort(payload)

    _bridge.lastRoomPlayers = roomPlayers
    _bridge.lastRoomTs = roomTs

    local snap = _computePresenceSnapshot(roomPlayers, roomTs, nil, "presence_bridge:roomentities")
    local ok, err = _applyPresenceSnapshot(snap, "presence_bridge:roomentities")
    if ok ~= true then
        _bridge.lastErr = tostring(err)
    else
        _bridge.lastErr = nil
    end

    _bridge.running = false
end

local function _onWhoStoreUpdated(payload)
    if _bridge.running == true then
        return
    end
    _bridge.running = true

    local ok, err = _recomputeFromLastKnown("presence_bridge:whostore", payload)
    if ok ~= true then
        _bridge.lastErr = tostring(err)
    end

    _bridge.running = false
end

local function _onCpcUpdated(payload)
    if _shouldRecomputeForCpcPayload(payload) ~= true then
        return
    end

    if _bridge.running == true then
        return
    end
    _bridge.running = true

    local ok, err = _recomputeFromLastKnown("presence_bridge:cpc", nil)
    if ok ~= true then
        _bridge.lastErr = tostring(err)
    end

    _bridge.running = false
end

local function _resolveRoomEntitiesUpdatedEventNameBestEffort()
    local okR, R = _safeRequire("dwkit.services.roomentities_service")
    if okR and type(R) == "table" then
        if type(R.getUpdatedEventName) == "function" then
            local ok, v = pcall(R.getUpdatedEventName)
            if ok and type(v) == "string" and v ~= "" then
                return v
            end
        end
        if type(R.EV_UPDATED) == "string" and R.EV_UPDATED ~= "" then
            return R.EV_UPDATED
        end
    end

    return tostring(ID.eventPrefix or "DWKit:") .. "Service:RoomEntities:Updated"
end

local function _ensureRoomEntitiesSubscription()
    if _bridge.subscribedRoom == true then
        return true, nil
    end

    if type(BUS) ~= "table" or type(BUS.on) ~= "function" then
        _bridge.lastErr = "event bus .on not available"
        return false, _bridge.lastErr
    end

    local evName = _resolveRoomEntitiesUpdatedEventNameBestEffort()
    if type(evName) ~= "string" or evName == "" then
        _bridge.lastErr = "RoomEntities updated event name not available"
        return false, _bridge.lastErr
    end

    local okSub, tokenOrErr, maybeErr = BUS.on(evName, _onRoomEntitiesUpdated)
    if okSub ~= true then
        _bridge.lastErr = tostring(maybeErr or tokenOrErr or "RoomEntities subscribe failed")
        return false, _bridge.lastErr
    end

    _bridge.subscribedRoom = true
    _bridge.tokenRoom = tokenOrErr
    _bridge.eventNameRoom = evName
    _bridge.lastErr = nil
    return true, nil
end

local function _ensureWhoStoreSubscription()
    if _bridge.subscribedWho == true then
        return true, nil
    end

    if type(BUS) ~= "table" or type(BUS.on) ~= "function" then
        _bridge.lastErr = "event bus .on not available"
        return false, _bridge.lastErr
    end

    local evName = _resolveWhoStoreUpdatedEventNameBestEffort()
    if type(evName) ~= "string" or evName == "" then
        _bridge.lastErr = "WhoStore updated event name not available"
        return false, _bridge.lastErr
    end

    local okSub, tokenOrErr, maybeErr = BUS.on(evName, _onWhoStoreUpdated)
    if okSub ~= true then
        _bridge.lastErr = tostring(maybeErr or tokenOrErr or "WhoStore subscribe failed")
        return false, _bridge.lastErr
    end

    _bridge.subscribedWho = true
    _bridge.tokenWho = tokenOrErr
    _bridge.eventNameWho = evName
    _bridge.lastErr = nil
    return true, nil
end

local function _ensureCpcSubscription()
    if _bridge.subscribedCpc == true then
        return true, nil
    end

    if type(BUS) ~= "table" or type(BUS.on) ~= "function" then
        _bridge.lastErr = "event bus .on not available"
        return false, _bridge.lastErr
    end

    local evName = _resolveCpcUpdatedEventNameBestEffort()
    if type(evName) ~= "string" or evName == "" then
        _bridge.lastErr = "CrossProfileComm updated event name not available"
        return false, _bridge.lastErr
    end

    local okSub, tokenOrErr, maybeErr = BUS.on(evName, _onCpcUpdated)
    if okSub ~= true then
        _bridge.lastErr = tostring(maybeErr or tokenOrErr or "CrossProfileComm subscribe failed")
        return false, _bridge.lastErr
    end

    _bridge.subscribedCpc = true
    _bridge.tokenCpc = tokenOrErr
    _bridge.eventNameCpc = evName
    _bridge.lastErr = nil
    return true, nil
end

local function _armSubscriptionsBestEffort()
    local ok1 = true
    local ok2 = true
    local ok3 = true

    local o1, e1 = _ensureRoomEntitiesSubscription()
    if o1 ~= true then ok1 = false end

    local o2, e2 = _ensureWhoStoreSubscription()
    if o2 ~= true then ok2 = false end

    local o3, e3 = _ensureCpcSubscription()
    if o3 ~= true then ok3 = false end

    if ok1 ~= true or ok2 ~= true or ok3 ~= true then
        _bridge.lastErr = tostring(e1 or e2 or e3 or _bridge.lastErr or "subscribe failed")
    else
        _bridge.lastErr = nil
    end
end

function M.getVersion()
    return tostring(M.VERSION)
end

function M.getUpdatedEventName()
    return tostring(EV_UPDATED)
end

function M.getState()
    return _shallowCopy(STATE.state)
end

function M.setState(newState, opts)
    opts = opts or {}
    if type(newState) ~= "table" then
        return false, "setState(newState): newState must be a table"
    end

    STATE.state = _shallowCopy(newState)
    STATE.lastTs = os.time()
    STATE.updates = STATE.updates + 1

    local okEmit, errEmit = _emit(_shallowCopy(STATE.state), nil, opts.source)
    if not okEmit then
        return false, errEmit
    end

    return true, nil
end

function M.update(delta, opts)
    opts = opts or {}
    if type(delta) ~= "table" then
        return false, "update(delta): delta must be a table"
    end

    _merge(STATE.state, delta)
    STATE.lastTs = os.time()
    STATE.updates = STATE.updates + 1

    local okEmit, errEmit = _emit(_shallowCopy(STATE.state), _shallowCopy(delta), opts.source)
    if not okEmit then
        return false, errEmit
    end

    return true, nil
end

function M.clear(opts)
    opts = opts or {}
    STATE.state = {}
    STATE.lastTs = os.time()
    STATE.updates = STATE.updates + 1

    local okEmit, errEmit = _emit(_shallowCopy(STATE.state), { cleared = true }, opts.source)
    if not okEmit then
        return false, errEmit
    end

    return true, nil
end

function M.onUpdated(handlerFn)
    return BUS.on(EV_UPDATED, handlerFn)
end

function M.getStats()
    local map = _getOwnedProfilesMapBestEffort()

    return {
        version = M.VERSION,
        lastTs = STATE.lastTs,
        updates = STATE.updates,
        keys = (function()
            local n = 0
            for _ in pairs(STATE.state) do n = n + 1 end
            return n
        end)(),
        bridge = {
            room = {
                subscribed = (_bridge.subscribedRoom == true),
                eventName = _bridge.eventNameRoom,
                hasToken = (_bridge.tokenRoom ~= nil),
            },
            whostore = {
                subscribed = (_bridge.subscribedWho == true),
                eventName = _bridge.eventNameWho,
                hasToken = (_bridge.tokenWho ~= nil),
            },
            cpc = {
                subscribed = (_bridge.subscribedCpc == true),
                eventName = _bridge.eventNameCpc,
                hasToken = (_bridge.tokenCpc ~= nil),
            },
            lastErr = _bridge.lastErr,
            lastRoomTs = _bridge.lastRoomTs,
            lastWhoTs = _bridge.lastWhoTs,
            lastWhoCount = _bridge.lastWhoCount,
        },
        mapping = {
            count = _countMap(map),
        },
    }
end

_armSubscriptionsBestEffort()

return M
