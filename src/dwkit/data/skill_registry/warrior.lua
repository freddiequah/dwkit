-- #########################################################################
-- Module Name : dwkit.data.skill_registry.warrior
-- Owner       : Data
-- Version     : v2026-03-09C
-- Purpose     :
--   - Data-only SkillRegistry raw declarations for Warrior entries.
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
    kick = {
        id = "kick",
        displayName = "Kick",
        practiceKey = "kick",
        classKey = "warrior",
        kind = "skill",
        minLevel = 1,
        tags = { "actionpad", "combat" },
    },
    bash = {
        id = "bash",
        displayName = "Bash",
        practiceKey = "bash",
        classKey = "warrior",
        kind = "skill",
        minLevel = 1,
        tags = { "actionpad", "combat", "fightOnly" },
    },
    assist = {
        id = "assist",
        displayName = "Assist",
        practiceKey = "assist",
        classKey = "warrior",
        kind = "skill",
        minLevel = 1,
        tags = { "actionpad", "combat", "fightOnly" },
    },
    rescue = {
        id = "rescue",
        displayName = "Rescue",
        practiceKey = "rescue",
        classKey = "warrior",
        kind = "skill",
        minLevel = 1,
        tags = { "actionpad", "combat", "fightOnly" },
        notes = "ActionPad will gate fightOnly by state later.",
    },
    pummel = {
        id = "pummel",
        displayName = "Pummel",
        practiceKey = "pummel",
        classKey = "warrior",
        kind = "skill",
        minLevel = 1,
        tags = { "actionpad", "combat", "fightOnly" },
        notes = "Baseline warrior example (minLevel may be refined later).",
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