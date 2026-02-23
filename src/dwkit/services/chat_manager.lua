-- FILE: src/dwkit/services/chat_manager.lua
-- #########################################################################
-- Module Name : dwkit.services.chat_manager
-- Owner       : Services
-- Version     : v2026-02-23A
-- Purpose     :
--   - Chat subsystem feature manager (policy + toggles), Phase 2.
--   - Owns feature flags and defaults (toggle-first rule; defaults OFF).
--   - Provides a SAFE API for UI and commands to enable/disable features.
--   - Best-effort applies changes to chat_ui (consumer UI) without owning UI logic.
--
-- Public API:
--   - getVersion() -> string
--   - listFeatures() -> table[] { key, title, description, default, kind, min, max }
--   - getConfig() -> table { features = { [key]=bool|number|string }, defaultsApplied=true }
--   - getFeature(key) -> value|nil
--   - setFeature(key, value, opts?) -> boolean ok, string|nil err
--   - resetDefaults(opts?) -> boolean ok, string|nil err
--   - applyBestEffort(opts?) -> boolean ok
--
-- Events Emitted   : None (intentionally omitted to avoid registry changes here)
-- Events Consumed  : None
-- Persistence      : Session-only by default in this version.
--                   (Best-effort future persistence may be added via chat_store once confirmed.)
-- Automation Policy: Manual only (no timers, no polling)
-- Dependencies     : dwkit.ui.chat_ui (best-effort apply)
-- #########################################################################

local M = {}

M.VERSION = "v2026-02-23A"

local FEATURES = {
    {
        key = "all_unread_badge",
        title = "All Unread Badge",
        description = "Optionally show unread count on All tab (v1 default is OFF).",
        kind = "bool",
        default = false,
    },
    {
        key = "auto_scroll_follow",
        title = "Auto-scroll Follow",
        description = "When enabled, best-effort keep active tab view at bottom on new lines (no yank guarantees).",
        kind = "bool",
        default = false,
    },
    {
        key = "per_tab_line_limit",
        title = "Per-tab Line Limit",
        description = "When enabled, limits rendered lines per tab to the last N items (store remains unchanged).",
        kind = "bool",
        default = false,
    },
    {
        key = "per_tab_line_limit_n",
        title = "Per-tab Line Limit N",
        description = "Line limit used when per_tab_line_limit is ON. Recommended 200-800.",
        kind = "number",
        default = 500,
        min = 50,
        max = 3000,
    },
    {
        key = "timestamp_prefix",
        title = "Timestamp Prefix",
        description = "Prefix each rendered line with [HH:MM:SS] using item.ts when available (best-effort).",
        kind = "bool",
        default = false,
    },
    {
        key = "debug_overlay",
        title = "Debug Overlay",
        description = "Show a small debug line in chat_ui (active tab, lastRenderedId, unread summary).",
        kind = "bool",
        default = false,
    },
}

local st = {
    features = {},
    defaultsApplied = false,
}

local function _buildDefaultMap()
    local m = {}
    for _, f in ipairs(FEATURES) do
        m[f.key] = f.default
    end
    return m
end

local function _ensureDefaults()
    if st.defaultsApplied == true then
        return
    end
    local d = _buildDefaultMap()
    for k, v in pairs(d) do
        if st.features[k] == nil then
            st.features[k] = v
        end
    end
    st.defaultsApplied = true
end

local function _findFeature(key)
    key = tostring(key or "")
    if key == "" then return nil end
    for _, f in ipairs(FEATURES) do
        if f.key == key then return f end
    end
    return nil
end

local function _coerceValue(feat, value)
    if type(feat) ~= "table" then
        return nil, "unknown feature"
    end

    if feat.kind == "bool" then
        if value == true or value == false then
            return value, nil
        end
        local s = tostring(value or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
        if s == "on" or s == "true" or s == "1" or s == "yes" then return true, nil end
        if s == "off" or s == "false" or s == "0" or s == "no" then return false, nil end
        return nil, "expected bool (on/off)"
    end

    if feat.kind == "number" then
        local n = tonumber(value)
        if not n then return nil, "expected number" end
        n = math.floor(n)
        if type(feat.min) == "number" and n < feat.min then n = feat.min end
        if type(feat.max) == "number" and n > feat.max then n = feat.max end
        return n, nil
    end

    if feat.kind == "string" then
        return tostring(value or ""), nil
    end

    return nil, "unknown feature kind"
end

local function _applyToChatUiBestEffort(source)
    local okUI, UI = pcall(require, "dwkit.ui.chat_ui")
    if not okUI or type(UI) ~= "table" then
        return false
    end

    -- Best-effort: if chat_ui supports setting features, use it.
    if type(UI.setFeatureConfig) == "function" then
        pcall(UI.setFeatureConfig, M.getConfig(), { source = source or "chat_manager:apply" })
    end

    -- Force a redraw if visible.
    if type(UI.refresh) == "function" then
        pcall(UI.refresh, { source = source or "chat_manager:apply", force = true })
    end

    return true
end

function M.getVersion()
    return M.VERSION
end

function M.listFeatures()
    local out = {}
    for i = 1, #FEATURES do
        local f = FEATURES[i]
        out[i] = {
            key = f.key,
            title = f.title,
            description = f.description,
            kind = f.kind,
            default = f.default,
            min = f.min,
            max = f.max,
        }
    end
    return out
end

function M.getConfig()
    _ensureDefaults()
    local copy = {}
    for k, v in pairs(st.features or {}) do
        copy[k] = v
    end
    return {
        features = copy,
        defaultsApplied = (st.defaultsApplied == true),
        version = M.VERSION,
    }
end

function M.getFeature(key)
    _ensureDefaults()
    key = tostring(key or "")
    if key == "" then return nil end
    return st.features[key]
end

function M.setFeature(key, value, opts)
    _ensureDefaults()
    opts = (type(opts) == "table") and opts or {}

    key = tostring(key or "")
    if key == "" then
        return false, "feature key required"
    end

    local feat = _findFeature(key)
    if not feat then
        return false, "unknown feature: " .. key
    end

    local coerced, err = _coerceValue(feat, value)
    if coerced == nil and err then
        return false, key .. ": " .. tostring(err)
    end

    st.features[key] = coerced

    if opts.apply ~= false then
        _applyToChatUiBestEffort(opts.source or "chat_manager:setFeature")
    end

    return true, nil
end

function M.resetDefaults(opts)
    opts = (type(opts) == "table") and opts or {}
    local d = _buildDefaultMap()
    st.features = d
    st.defaultsApplied = true

    if opts.apply ~= false then
        _applyToChatUiBestEffort(opts.source or "chat_manager:resetDefaults")
    end

    return true, nil
end

function M.applyBestEffort(opts)
    opts = (type(opts) == "table") and opts or {}
    return _applyToChatUiBestEffort(opts.source or "chat_manager:apply")
end

return M
