-- #########################################################################
-- Module Name : dwkit.data.skill_registry.warrior
-- Owner       : Data
-- Version     : v2026-03-09D
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

M.VERSION = "v2026-03-09D"

local ENTRIES = {
    kick = {
        id = "kick",
        displayName = "Kick",
        practiceKey = "kick",
        classKey = "warrior",
        kind = "skill",
        minLevel = 1,
        tags = { "actionpad", "combat" },
        notes = "ActionPad baseline preserved. Dump confirms actionable combat skill, but no explicit warrior level is shown in the current source dump.",
    },
    bash = {
        id = "bash",
        displayName = "Bash",
        practiceKey = "bash",
        classKey = "warrior",
        kind = "skill",
        minLevel = 4,
        tags = { "actionpad", "combat", "fightOnly" },
        notes = "Dump-backed warrior level and usage.",
    },
    assist = {
        id = "assist",
        displayName = "Assist",
        practiceKey = "assist",
        classKey = "warrior",
        kind = "skill",
        minLevel = 1,
        tags = { "actionpad", "combat", "fightOnly" },
        notes = "ActionPad baseline preserved. Not present in current uploaded warrior dump.",
    },
    rescue = {
        id = "rescue",
        displayName = "Rescue",
        practiceKey = "rescue",
        classKey = "warrior",
        kind = "skill",
        minLevel = 1,
        tags = { "actionpad", "combat", "fightOnly" },
        notes = "Dump-backed warrior level and usage.",
    },
    pummel = {
        id = "pummel",
        displayName = "Pummel",
        practiceKey = "pummel",
        classKey = "warrior",
        kind = "skill",
        minLevel = 8,
        tags = { "actionpad", "combat", "fightOnly" },
        notes = "Dump-backed warrior level and usage.",
    },
    dodge = {
        id = "dodge",
        displayName = "Dodge",
        practiceKey = "dodge",
        classKey = "warrior",
        kind = "skill",
        minLevel = 10,
        tags = { "passive", "combat" },
        notes = "Dump-backed automatic warrior skill.",
    },
    double = {
        id = "double",
        displayName = "Double",
        practiceKey = "double",
        classKey = "warrior",
        kind = "skill",
        minLevel = 13,
        tags = { "passive", "combat", "progression" },
        notes = "Dump-backed automatic warrior progression skill. Separate canonical entry, not an alias of triple.",
    },
    grapple = {
        id = "grapple",
        displayName = "Grapple",
        practiceKey = "grapple",
        classKey = "warrior",
        kind = "skill",
        minLevel = 1,
        tags = { "combat", "fightOnly" },
        notes = "Dump confirms actionable skill, but no explicit warrior level is shown in the current source dump.",
    },
    guard = {
        id = "guard",
        displayName = "Guard",
        practiceKey = "guard",
        classKey = "warrior",
        kind = "skill",
        minLevel = 1,
        tags = { "passive", "combat" },
        notes = "Dump-backed automatic guard behavior with guard command usage described, but no explicit warrior level is shown in the current source dump.",
    },
    block = {
        id = "block",
        displayName = "Block",
        practiceKey = "block",
        classKey = "warrior",
        kind = "skill",
        minLevel = 28,
        tags = { "combat", "fightOnly" },
        notes = "Dump-backed warrior level and usage.",
    },
    berserk = {
        id = "berserk",
        displayName = "Berserk",
        practiceKey = "berserk",
        classKey = "warrior",
        kind = "skill",
        minLevel = 33,
        tags = { "combat", "fightOnly" },
        notes = "Dump-backed warrior level and usage.",
    },
    parry = {
        id = "parry",
        displayName = "Parry",
        practiceKey = "parry",
        classKey = "warrior",
        kind = "skill",
        minLevel = 40,
        tags = { "passive", "combat" },
        notes = "Dump-backed automatic warrior skill.",
    },
    triple = {
        id = "triple",
        displayName = "Triple",
        practiceKey = "triple",
        classKey = "warrior",
        kind = "skill",
        minLevel = 22,
        tags = { "passive", "combat", "progression" },
        notes = "Dump-backed automatic warrior progression skill. Separate canonical entry, not an alias of double.",
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