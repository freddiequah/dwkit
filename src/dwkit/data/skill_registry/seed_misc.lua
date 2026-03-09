-- #########################################################################
-- Module Name : dwkit.data.skill_registry.seed_misc
-- Owner       : Data
-- Version     : v2026-03-09D
-- Purpose     :
--   - Data-only transitional SkillRegistry raw declarations for non-split seed
--     and placeholder entries.
--   - Holds remaining baseline content that is not yet promoted into a real
--     class-specific module.
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
    ["anti-paladin example"] = {
        id = "anti-paladin example",
        displayName = "Anti-Paladin Example",
        practiceKey = "anti-paladin example",
        classKey = "anti-paladin",
        kind = "skill",
        minLevel = 1,
        tags = { "seed" },
        notes = "Seed used only to assert hyphen-preserving classKey handling.",
    },
    ["ranger example"] = {
        id = "ranger example",
        displayName = "Ranger Example",
        practiceKey = "ranger example",
        classKey = "ranger",
        kind = "skill",
        minLevel = 1,
        tags = { "seed", "remort" },
    },
    ["monk example"] = {
        id = "monk example",
        displayName = "Monk Example",
        practiceKey = "monk example",
        classKey = "monk",
        kind = "skill",
        minLevel = 1,
        tags = { "seed", "remort" },
    },
    ["bard example"] = {
        id = "bard example",
        displayName = "Bard Example",
        practiceKey = "bard example",
        classKey = "bard",
        kind = "skill",
        minLevel = 1,
        tags = { "seed", "remort" },
    },
    ["pirate example"] = {
        id = "pirate example",
        displayName = "Pirate Example",
        practiceKey = "pirate example",
        classKey = "pirate",
        kind = "skill",
        minLevel = 1,
        tags = { "seed", "remort" },
    },
    ["race example"] = {
        id = "race example",
        displayName = "Race Example",
        practiceKey = "race example",
        classKey = "warrior",
        kind = "race",
        minLevel = 0,
        tags = { "race", "seed" },
        notes = "Race skills are not class-learned; classKey is used as grouping only (seed).",
    },
    sword = {
        id = "sword",
        displayName = "Sword",
        practiceKey = "sword",
        classKey = "warrior",
        kind = "weapon",
        minLevel = 0,
        tags = { "weapon" },
        notes = "Weapon prof example; classKey grouping is seed-level.",
    },
    dagger = {
        id = "dagger",
        displayName = "Dagger",
        practiceKey = "dagger",
        classKey = "thief",
        kind = "weapon",
        minLevel = 0,
        tags = { "weapon" },
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