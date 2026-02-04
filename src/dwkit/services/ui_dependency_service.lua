-- #########################################################################
-- Module Name : dwkit.services.ui_dependency_service
-- Owner       : Services
-- Version     : v2026-02-04C
-- Purpose     :
--   - Dependency-safe lifecycle management for passive "providers" required by enabled UIs (Model A).
--   - Providers are SAFE passive capture watchers (triggers/hooks) and MUST NOT send gameplay commands.
--   - Ensures required providers are running when at least one enabled UI depends on them.
--   - Releases providers when no enabled dependents remain.
--   - Does NOT manage UI visibility. Dependencies are tied to "enabled", not "visible".
--
-- Providers (current):
--   - roomfeed_watch : dwkit.capture.roomfeed_capture install/uninstall (passive triggers)
--
-- Public API  :
--   - getVersion() -> string
--   - getState() -> table (debug/inspection)
--   - ensureUi(uiId, providers, opts?) -> boolean ok, string|nil err
--   - releaseUi(uiId, opts?) -> boolean ok, string|nil err
--
-- Notes:
--   - This service is in-memory only; it does not persist dependency claims.
--   - If a provider is already installed externally (e.g., user ran "dwroom watch on"),
--     we will treat it as external and will NOT uninstall it when dependents release.
-- #########################################################################

local M = {}

M.VERSION = "v2026-02-04C"

local ROOT = {
    uiClaims = {},  -- uiId -> { providerId=true, ... }
    refs = {},      -- providerId -> refcount
    providers = {}, -- providerId -> provider state
}

local function _nowTs()
    return (type(os) == "table" and type(os.time) == "function") and os.time() or 0
end

local function _isFn(name)
    return (type(_G) == "table" and type(_G[name]) == "function")
end

local function _safeRequire(modName)
    local ok, mod = pcall(require, modName)
    if ok then return true, mod end
    return false, mod
end

local function _out(msg, opts)
    opts = (type(opts) == "table") and opts or {}
    if opts.quiet == true then return end
    local s = tostring(msg or "")
    if _isFn("cecho") then
        cecho(s .. "\n")
    elseif _isFn("echo") then
        echo(s .. "\n")
    else
        print(s)
    end
end

local function _trim(s)
    s = tostring(s or "")
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function _asSet(list)
    local t = {}
    if type(list) ~= "table" then return t end
    for _, v in ipairs(list) do
        if type(v) == "string" and v ~= "" then
            t[v] = true
        end
    end
    return t
end

local function _providerState(providerId)
    local st = ROOT.providers[providerId]
    if type(st) ~= "table" then
        st = {
            id = tostring(providerId),
            startedByManager = false,
            externalInstalled = false,
            lastEnsureTs = nil,
            lastReleaseTs = nil,
            lastErr = nil,
        }
        ROOT.providers[providerId] = st
    end
    return st
end

local function _isProviderInstalled_roomfeed()
    local okC, capOrErr = _safeRequire("dwkit.capture.roomfeed_capture")
    if not okC or type(capOrErr) ~= "table" then
        return false, "RoomFeedCapture not available: " .. tostring(capOrErr)
    end
    local cap = capOrErr

    if type(cap.getDebugState) == "function" then
        local ok, st = pcall(cap.getDebugState)
        if ok and type(st) == "table" then
            return (st.installed == true), nil
        end
    end

    return false, nil
end

local function _startProvider_roomfeed(opts)
    opts = (type(opts) == "table") and opts or {}

    local okC, capOrErr = _safeRequire("dwkit.capture.roomfeed_capture")
    if not okC or type(capOrErr) ~= "table" then
        return false, "RoomFeedCapture not available: " .. tostring(capOrErr)
    end
    local cap = capOrErr

    local ok, err = pcall(cap.install, { quiet = true, source = opts.source or "ui_dep:roomfeed:start" })
    if not ok then
        return false, tostring(err)
    end
    return true, nil
end

local function _stopProvider_roomfeed(opts)
    opts = (type(opts) == "table") and opts or {}

    local okC, capOrErr = _safeRequire("dwkit.capture.roomfeed_capture")
    if not okC or type(capOrErr) ~= "table" then
        return false, "RoomFeedCapture not available: " .. tostring(capOrErr)
    end
    local cap = capOrErr

    local ok, err = pcall(cap.uninstall, { quiet = true, source = opts.source or "ui_dep:roomfeed:stop" })
    if not ok then
        return false, tostring(err)
    end
    return true, nil
end

local function _ensureProvider(providerId, opts)
    opts = (type(opts) == "table") and opts or {}
    providerId = tostring(providerId or "")

    if providerId == "roomfeed_watch" then
        local st = _providerState(providerId)

        local installed, e = _isProviderInstalled_roomfeed()
        if e then
            st.lastErr = e
            return false, e
        end

        if installed == true then
            if st.startedByManager ~= true then
                st.externalInstalled = true
            end
            st.lastEnsureTs = _nowTs()
            return true, nil
        end

        local ok, err = _startProvider_roomfeed(opts)
        if not ok then
            st.lastErr = err
            return false, err
        end
        st.startedByManager = true
        st.externalInstalled = false
        st.lastEnsureTs = _nowTs()
        return true, nil
    end

    return false, "unknown providerId: " .. tostring(providerId)
end

local function _releaseProviderIfUnused(providerId, opts)
    opts = (type(opts) == "table") and opts or {}
    providerId = tostring(providerId or "")

    local rc = tonumber(ROOT.refs[providerId] or 0) or 0
    if rc > 0 then
        return true, nil
    end

    local st = _providerState(providerId)

    if st.externalInstalled == true and st.startedByManager ~= true then
        st.lastReleaseTs = _nowTs()
        return true, nil
    end

    if providerId == "roomfeed_watch" then
        local installed, e = _isProviderInstalled_roomfeed()
        if e then
            st.lastErr = e
            return false, e
        end

        if installed ~= true then
            st.lastReleaseTs = _nowTs()
            st.startedByManager = false
            return true, nil
        end

        local ok, err = _stopProvider_roomfeed(opts)
        if not ok then
            st.lastErr = err
            return false, err
        end

        st.lastReleaseTs = _nowTs()
        st.startedByManager = false
        st.externalInstalled = false
        return true, nil
    end

    return false, "unknown providerId: " .. tostring(providerId)
end

function M.getVersion()
    return tostring(M.VERSION)
end

function M.getState()
    local uiClaimsCopy = {}
    for uiId, set in pairs(ROOT.uiClaims) do
        local t = {}
        if type(set) == "table" then
            for pid, v in pairs(set) do
                if v == true then t[#t + 1] = pid end
            end
        end
        uiClaimsCopy[uiId] = t
    end

    local refsCopy = {}
    for pid, v in pairs(ROOT.refs) do
        refsCopy[pid] = tonumber(v or 0) or 0
    end

    local providersCopy = {}
    for pid, st in pairs(ROOT.providers) do
        if type(st) == "table" then
            providersCopy[pid] = {
                id = st.id,
                startedByManager = (st.startedByManager == true),
                externalInstalled = (st.externalInstalled == true),
                lastEnsureTs = st.lastEnsureTs,
                lastReleaseTs = st.lastReleaseTs,
                lastErr = st.lastErr,
            }
        end
    end

    return {
        uiClaims = uiClaimsCopy,
        refs = refsCopy,
        providers = providersCopy,
    }
end

function M.ensureUi(uiId, providers, opts)
    opts = (type(opts) == "table") and opts or {}
    uiId = _trim(uiId)
    if uiId == "" then
        return false, "uiId invalid"
    end

    local nextSet = _asSet(providers)
    if next(nextSet) == nil then
        return M.releaseUi(uiId, opts)
    end

    local prevSet = ROOT.uiClaims[uiId]
    if type(prevSet) ~= "table" then prevSet = {} end

    for pid, v in pairs(nextSet) do
        if v == true and prevSet[pid] ~= true then
            ROOT.refs[pid] = (tonumber(ROOT.refs[pid] or 0) or 0) + 1
        end
    end

    for pid, v in pairs(prevSet) do
        if v == true and nextSet[pid] ~= true then
            ROOT.refs[pid] = (tonumber(ROOT.refs[pid] or 0) or 0) - 1
            if (tonumber(ROOT.refs[pid] or 0) or 0) < 0 then
                ROOT.refs[pid] = 0
            end
        end
    end

    ROOT.uiClaims[uiId] = nextSet

    for pid, v in pairs(nextSet) do
        if v == true then
            local ok, err = _ensureProvider(pid, opts)
            if not ok then
                return false, tostring(err)
            end
        end
    end

    return true, nil
end

function M.releaseUi(uiId, opts)
    opts = (type(opts) == "table") and opts or {}
    uiId = _trim(uiId)
    if uiId == "" then
        return false, "uiId invalid"
    end

    local prevSet = ROOT.uiClaims[uiId]
    if type(prevSet) ~= "table" then
        ROOT.uiClaims[uiId] = nil
        return true, nil
    end

    for pid, v in pairs(prevSet) do
        if v == true then
            ROOT.refs[pid] = (tonumber(ROOT.refs[pid] or 0) or 0) - 1
            if (tonumber(ROOT.refs[pid] or 0) or 0) < 0 then
                ROOT.refs[pid] = 0
            end
        end
    end

    ROOT.uiClaims[uiId] = nil

    for pid, _ in pairs(prevSet) do
        local ok, err = _releaseProviderIfUnused(pid, opts)
        if not ok then
            return false, tostring(err)
        end
    end

    return true, nil
end

return M
