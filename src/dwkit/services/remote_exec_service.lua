-- FILE: src/dwkit/services/remote_exec_service.lua
-- #########################################################################
-- Module Name : dwkit.services.remote_exec_service
-- Owner       : Services
-- Version     : v2026-03-03E
-- Purpose     :
--   - Owned-only remote execution transport across profiles in the SAME Mudlet instance.
--   - Manual-triggered only: does not create timers, does not poll, does not auto-send.
--   - String-only transport using raiseGlobalEvent (Mudlet compat: avoid table args).
--   - Provides SAFE "PING" (prints on target profile) and gated "SEND" (sendToMud) via allowlist.
--
-- IMPORTANT:
--   - This module does NOT reuse dwkit.services.cross_profile_comm_service decoding because CPC does not
--     expose message hooks/decoders publicly. RemoteExec therefore uses a dedicated global event name.
--   - This is still same-instance only (raiseGlobalEvent) and remains within Automation Policy.
--
-- Public API  :
--   - getVersion() -> string
--   - install(opts?) -> boolean ok, string|nil err
--   - isInstalled() -> boolean
--   - getState() -> table copy (SAFE)
--   - status() -> table copy (compat helper; stable keys)
--   - ping(targetProfile, opts?) -> boolean ok, string|nil err   (SAFE; prints on target)
--   - send(targetProfile, cmd, opts?) -> boolean ok, string|nil err
--       * cmd is a single-line string (no \n)
--       * sendToMud is allowlist-gated and default OFF
--   - allowPrefix(prefix, opts?) -> boolean ok, string|nil err
--   - clearAllowlist() -> boolean ok
--   - getAllowlist() -> string[] (sorted)
--
-- Test helpers (SAFE; session-only; deterministic receiver simulation):
--   - _testMakeWire(toProfile, action, cmd?, opts?) -> string wire
--   - _testInjectWire(wire) -> boolean ok, string|nil err
--
-- Events Emitted   : None (transport-level only)
-- Events Consumed  : Mudlet global event: DWKit:RemoteExec:Msg
-- Persistence      : None (session-only)
-- Automation Policy: Manual only (no timers; no polling; no hidden automation)
-- Dependencies     : dwkit.core.identity, dwkit.config.owned_profiles
-- #########################################################################

local M = {}

M.VERSION = "v2026-03-03E"

local ID = require("dwkit.core.identity")
local Owned = require("dwkit.config.owned_profiles")

local GLOBAL_EVENT_NAME = tostring(ID.eventPrefix or "DWKit:") .. "RemoteExec:Msg"

local STATE = {
    installed = false,
    myProfile = nil,
    handlerId = nil,

    stats = {
        sends = 0,
        recv = 0,
        rejected = 0,
        lastSendTs = nil,
        lastRecvTs = nil,
        lastReject = nil,
        lastErr = nil,
    },

    allow = {
        -- allow prefixes for SEND commands (string match startsWith)
        -- default empty: sendToMud is blocked until explicitly allowlisted.
        prefixes = {},
    },
}

local function _trim(s)
    s = tostring(s or "")
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function _normalizeUnicode(s)
    s = tostring(s or "")

    -- Normalize NBSP (U+00A0) into a real space.
    -- UTF-8 bytes for NBSP are C2 A0.
    s = s:gsub("\194\160", " ")

    -- Normalize common Unicode hyphens/dashes to ASCII '-'
    -- U+2010 Hyphen:              E2 80 90
    -- U+2011 Non-breaking hyphen: E2 80 91
    -- U+2012 Figure dash:         E2 80 92
    -- U+2013 En dash:             E2 80 93
    -- U+2014 Em dash:             E2 80 94
    s = s:gsub("\226\128\144", "-")
    s = s:gsub("\226\128\145", "-")
    s = s:gsub("\226\128\146", "-")
    s = s:gsub("\226\128\147", "-")
    s = s:gsub("\226\128\148", "-")

    return s
end

local function _collapseWs(s)
    s = tostring(s or "")
    -- collapse any ASCII whitespace runs into a single space
    s = s:gsub("%s+", " ")
    return s
end

local function _normLabel(s)
    s = tostring(s or "")
    s = _normalizeUnicode(s)
    s = _trim(s)
    s = _collapseWs(s)
    return s
end

local function _myProfileNameBestEffort()
    if type(getProfileName) == "function" then
        local ok, v = pcall(getProfileName)
        if ok and type(v) == "string" and v ~= "" then
            return _normLabel(v)
        end
    end
    return "unknown-profile"
end

local function _copyShallow(t)
    local out = {}
    if type(t) ~= "table" then return out end
    for k, v in pairs(t) do out[k] = v end
    return out
end

local function _sortedKeys(t)
    local keys = {}
    if type(t) ~= "table" then return keys end
    for k, _ in pairs(t) do
        if type(k) == "string" and k ~= "" then
            keys[#keys + 1] = k
        end
    end
    table.sort(keys)
    return keys
end

local function _startsWith(s, prefix)
    s = tostring(s or "")
    prefix = tostring(prefix or "")
    if prefix == "" then return false end
    return s:sub(1, #prefix) == prefix
end

-- -------------------------------------------------------------------------
-- Owned-only enforcement helpers
-- -------------------------------------------------------------------------

local function _ownedProfileLabelsSet()
    -- CRITICAL:
    -- Do NOT force Owned.load() every call, because that reloads from disk and will
    -- overwrite session-only noSave seeds used by dwverify (and any live overrides).
    -- Only load if not already loaded.
    if type(Owned) == "table" and type(Owned.isLoaded) == "function" then
        if Owned.isLoaded() ~= true then
            pcall(Owned.load, { quiet = true })
        end
    else
        -- Best-effort fallback (older interface): avoid forcing load repeatedly.
        -- Owned.getMap() already does best-effort load if needed.
    end

    local map = Owned.getMap()
    local set = {}

    if type(map) == "table" then
        for _, profileLabel in pairs(map) do
            if type(profileLabel) == "string" and profileLabel ~= "" then
                local norm = _normLabel(profileLabel)
                if norm ~= "" then
                    set[norm] = true
                end
            end
        end
    end

    return set
end

local function _isOwnedProfileLabel(profileLabel)
    profileLabel = _normLabel(profileLabel)
    if profileLabel == "" then return false end
    local set = _ownedProfileLabelsSet()
    return set[profileLabel] == true
end

-- -------------------------------------------------------------------------
-- Transport encoding (string-only)
-- -------------------------------------------------------------------------

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

local function _encodeKV(t)
    if type(t) ~= "table" then return "" end
    local parts = {}
    local keys = _sortedKeys(t)
    for i = 1, #keys do
        local k = keys[i]
        local v = t[k]
        if v ~= nil then
            parts[#parts + 1] = _esc(k) .. "=" .. _esc(v)
        end
    end
    return table.concat(parts, "|")
end

local function _decodeKV(s)
    if type(s) ~= "string" or s == "" then return nil end
    local t = {}
    for part in s:gmatch("([^|]+)") do
        local k, v = part:match("^([^=]+)=(.*)$")
        if k and v then
            t[_unesc(k)] = _unesc(v)
        end
    end
    if next(t) == nil then return nil end
    return t
end

-- Envelope fields:
--   v, ts, fromProfile, toProfile, action, cmd, nonce, source
local function _mkEnvelope(toProfile, action, cmd, opts)
    opts = (type(opts) == "table") and opts or {}

    local env = {
        v = "1",
        ts = tostring(os.time()),
        fromProfile = _normLabel(STATE.myProfile or _myProfileNameBestEffort()),
        toProfile = _normLabel(toProfile or ""),
        action = tostring(action or ""),
        cmd = tostring(cmd or ""),
        nonce = tostring(opts.nonce or ""),
        source = tostring(opts.source or ""),
    }

    return env
end

local function _looksValidEnvelope(env)
    if type(env) ~= "table" then return false, "bad envelope" end
    if type(env.fromProfile) ~= "string" or env.fromProfile == "" then return false, "missing fromProfile" end
    if type(env.toProfile) ~= "string" or env.toProfile == "" then return false, "missing toProfile" end
    if type(env.action) ~= "string" or env.action == "" then return false, "missing action" end
    if type(env.v) ~= "string" or env.v == "" then return false, "missing v" end
    return true, nil
end

-- -------------------------------------------------------------------------
-- Allowlist
-- -------------------------------------------------------------------------

local function _prefixesTable()
    if type(STATE.allow.prefixes) ~= "table" then
        STATE.allow.prefixes = {}
    end
    return STATE.allow.prefixes
end

local function _isCmdAllowed(cmd)
    cmd = tostring(cmd or "")
    if cmd == "" then return false end

    local prefixes = _prefixesTable()
    local keys = _sortedKeys(prefixes)
    for i = 1, #keys do
        local p = keys[i]
        if _startsWith(cmd, p) then
            return true
        end
    end

    return false
end

-- -------------------------------------------------------------------------
-- Receiver behavior
-- -------------------------------------------------------------------------

local function _print(line)
    line = tostring(line or "")
    if type(cecho) == "function" then
        cecho(line .. "\n")
    elseif type(echo) == "function" then
        echo(line .. "\n")
    else
        print(line)
    end
end

local function _reject(reason, env)
    STATE.stats.rejected = (tonumber(STATE.stats.rejected) or 0) + 1
    STATE.stats.lastReject = tostring(reason or "rejected")
    STATE.stats.lastErr = nil

    local fp = (type(env) == "table") and tostring(env.fromProfile or "") or ""
    local tp = (type(env) == "table") and tostring(env.toProfile or "") or ""
    local act = (type(env) == "table") and tostring(env.action or "") or ""
    _print(string.format("[DWKit RemoteExec] REJECT reason=%s from=%s to=%s action=%s", tostring(reason), fp, tp, act))

    return false
end

local function _handlePing(env)
    local fromP = tostring(env.fromProfile or "")
    _print(string.format("[DWKit RemoteExec] PING received from=%s (target=%s)", fromP, tostring(env.toProfile or "")))
    return true
end

local function _handleSend(env)
    local cmd = tostring(env.cmd or "")
    cmd = _trim(cmd)

    if cmd == "" then
        return _reject("send:cmd_empty", env)
    end

    -- Single-line enforcement
    if cmd:find("\n", 1, true) or cmd:find("\r", 1, true) then
        return _reject("send:cmd_multiline", env)
    end

    -- Allowlist enforcement (default OFF)
    if _isCmdAllowed(cmd) ~= true then
        return _reject("send:not_allowlisted", env)
    end

    if type(send) ~= "function" then
        return _reject("send:send_fn_missing", env)
    end

    send(cmd)
    _print(string.format("[DWKit RemoteExec] SEND executed cmd=%s", cmd))
    return true
end

local function _onGlobalEvent(_, wire)
    STATE.stats.recv = (tonumber(STATE.stats.recv) or 0) + 1
    STATE.stats.lastRecvTs = os.time()

    local env = nil
    if type(wire) == "string" then
        env = _decodeKV(wire)
    else
        env = nil
    end

    local okEnv, envErr = _looksValidEnvelope(env)
    if not okEnv then
        return _reject("bad_env:" .. tostring(envErr), env)
    end

    local myProfile = _normLabel(STATE.myProfile or _myProfileNameBestEffort())
    local toProfile = _normLabel(env.toProfile)
    if toProfile ~= myProfile then
        -- Not for me; ignore quietly (no reject spam)
        return true
    end

    -- Owned-only enforcement (sender and target must be owned profile labels)
    if _isOwnedProfileLabel(tostring(env.fromProfile)) ~= true then
        return _reject("not_owned_sender", env)
    end
    if _isOwnedProfileLabel(tostring(env.toProfile)) ~= true then
        return _reject("not_owned_target", env)
    end

    local action = tostring(env.action or "")
    if action == "PING" then
        return _handlePing(env)
    elseif action == "SEND" then
        return _handleSend(env)
    else
        return _reject("unknown_action", env)
    end
end

-- -------------------------------------------------------------------------
-- Public API
-- -------------------------------------------------------------------------

function M.getVersion()
    return tostring(M.VERSION)
end

function M.isInstalled()
    return (STATE.installed == true)
end

function M.getAllowlist()
    local prefixes = _prefixesTable()
    local keys = _sortedKeys(prefixes)
    return keys
end

function M.clearAllowlist()
    STATE.allow.prefixes = {}
    return true
end

function M.allowPrefix(prefix, opts)
    opts = (type(opts) == "table") and opts or {}
    prefix = _trim(prefix)

    if prefix == "" then
        return false, "prefix must be non-empty"
    end
    if prefix:find("\n", 1, true) or prefix:find("\r", 1, true) then
        return false, "prefix must be single-line"
    end

    local prefixes = _prefixesTable()
    prefixes[prefix] = true

    if opts.quiet ~= true then
        _print(string.format("[DWKit RemoteExec] allowPrefix added: %s", prefix))
    end

    return true, nil
end

function M.getState()
    return {
        version = M.VERSION,
        installed = (STATE.installed == true),
        globalEventName = GLOBAL_EVENT_NAME,
        myProfile = tostring(STATE.myProfile or ""),
        handlerId = STATE.handlerId,
        allow = {
            prefixes = M.getAllowlist(),
        },
        stats = _copyShallow(STATE.stats),
    }
end

function M.status()
    local st = M.getState()
    return {
        version = st.version,
        installed = st.installed,
        myProfile = st.myProfile,
        globalEventName = st.globalEventName,
        allowPrefixes = (st.allow and st.allow.prefixes) or {},
        stats = st.stats,
    }
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

    local okCall, idOrErr = pcall(registerAnonymousEventHandler, GLOBAL_EVENT_NAME, _onGlobalEvent)
    if not okCall or idOrErr == nil then
        return false, "Failed to register RemoteExec handler: " .. tostring(idOrErr)
    end

    STATE.handlerId = idOrErr
    STATE.installed = true
    STATE.stats.lastErr = nil

    if opts.quiet ~= true then
        _print(string.format("[DWKit RemoteExec] installed myProfile=%s event=%s", tostring(STATE.myProfile),
            tostring(GLOBAL_EVENT_NAME)))
        _print("[DWKit RemoteExec] NOTE: SEND is allowlist-gated and default OFF. Use dwremoteexec allow add <prefix>.")
    end

    return true, nil
end

local function _publishEnvelope(env)
    if type(raiseGlobalEvent) ~= "function" then
        return false, "raiseGlobalEvent() not available"
    end

    local wire = _encodeKV(env)
    if type(wire) ~= "string" or wire == "" then
        return false, "encode failed"
    end

    local okCall, errCall = pcall(raiseGlobalEvent, GLOBAL_EVENT_NAME, wire)
    if not okCall then
        return false, tostring(errCall)
    end

    STATE.stats.sends = (tonumber(STATE.stats.sends) or 0) + 1
    STATE.stats.lastSendTs = os.time()
    STATE.stats.lastErr = nil
    return true, nil
end

local function _preflightOwned(targetProfile)
    targetProfile = _normLabel(targetProfile or "")
    if targetProfile == "" then
        return false, "targetProfile required"
    end

    -- IMPORTANT: do NOT rely on cached STATE.myProfile for ownership checks.
    -- Use the live current profile label each call.
    local myProfileLive = _myProfileNameBestEffort()

    if _isOwnedProfileLabel(myProfileLive) ~= true then
        return false, "current profile is not an owned profile label (owned_profiles values)"
    end

    if _isOwnedProfileLabel(targetProfile) ~= true then
        return false, "targetProfile is not an owned profile label"
    end

    return true, nil
end

function M.ping(targetProfile, opts)
    opts = (type(opts) == "table") and opts or {}

    if STATE.installed ~= true then
        local okI, errI = M.install({ quiet = true })
        if not okI then return false, tostring(errI) end
    end

    -- keep sender label fresh (for envelope + receiver gating)
    STATE.myProfile = _myProfileNameBestEffort()

    local okOwn, errOwn = _preflightOwned(targetProfile)
    if not okOwn then return false, tostring(errOwn) end

    local env = _mkEnvelope(targetProfile, "PING", "", { source = opts.source or "ping" })
    return _publishEnvelope(env)
end

function M.send(targetProfile, cmd, opts)
    opts = (type(opts) == "table") and opts or {}

    if STATE.installed ~= true then
        local okI, errI = M.install({ quiet = true })
        if not okI then return false, tostring(errI) end
    end

    -- keep sender label fresh (for envelope + receiver gating)
    STATE.myProfile = _myProfileNameBestEffort()

    local okOwn, errOwn = _preflightOwned(targetProfile)
    if not okOwn then return false, tostring(errOwn) end

    cmd = tostring(cmd or "")
    cmd = _trim(cmd)

    if cmd == "" then return false, "cmd required" end
    if cmd:find("\n", 1, true) or cmd:find("\r", 1, true) then
        return false, "cmd must be single-line"
    end

    local env = _mkEnvelope(targetProfile, "SEND", cmd, { source = opts.source or "send" })
    return _publishEnvelope(env)
end

-- -------------------------------------------------------------------------
-- Test helpers (SAFE; deterministic receiver simulation)
-- -------------------------------------------------------------------------

function M._testMakeWire(toProfile, action, cmd, opts)
    opts = (type(opts) == "table") and opts or {}
    toProfile = _normLabel(toProfile or "")
    action = tostring(action or "")
    cmd = tostring(cmd or "")

    -- Ensure sender label is the live profile label (so tests don't depend on stale STATE.myProfile).
    STATE.myProfile = _myProfileNameBestEffort()

    local env = _mkEnvelope(toProfile, action, cmd, {
        source = tostring(opts.source or "test"),
        nonce = tostring(opts.nonce or ""),
    })

    return _encodeKV(env)
end

function M._testInjectWire(wire)
    if type(wire) ~= "string" or wire == "" then
        return false, "wire must be non-empty string"
    end

    -- Ensure receiver thinks "my profile" is the live profile label.
    STATE.myProfile = _myProfileNameBestEffort()

    local okCall, resOrErr = pcall(_onGlobalEvent, nil, wire)
    if not okCall then
        return false, tostring(resOrErr)
    end

    -- _onGlobalEvent returns true/false; for tests, treat false as ok (it means reject occurred).
    return true, nil
end

return M
-- END FILE: src/dwkit/services/remote_exec_service.lua