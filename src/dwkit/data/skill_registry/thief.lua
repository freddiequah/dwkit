-- #########################################################################
-- Module Name : dwkit.data.skill_registry.thief
-- Owner       : Data
-- Version     : v2026-03-09C
-- Purpose     :
--   - Data-only SkillRegistry raw declarations for Thief entries.
--   - Owns raw entry tables only.
--   - No validation, no normalization, no indexes, no events, no persistence.
--   - No UI, no timers, no send().
--
-- Public API  :
--   - getEntries() -> table copy
--
-- Events Emitted:
--   - None
-- Automation Policy: None
-- Dependencies     : None
-- #########################################################################

local M = {}

M.VERSION = "v2026-03-09C"

local ENTRIES = {
    circle = {
        id = "circle",
        displayName = "Circle",
        practiceKey = "circle",
        classKey = "thief",
        kind = "skill",
        minLevel = 1,
        tags = { "actionpad", "combat", "fightOnly" },
    },
}

local function _copyEntries(src)
    local out = {}
    for k, def in pairs(src or {}) do
        if type(def) == "table" then
            local row = {}
            for dk, dv in pairs(def) do
                row[dk] = dv
            end
            out[k] = row
        else
            out[k] = def
        end
    end
    return out
end

function M.getEntries()
    return _copyEntries(ENTRIES)
end

return M