-- #########################################################################
-- Module Name : dwkit.data.skill_registry.thief
-- Owner       : Data
-- Version     : v2026-03-09D
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

M.VERSION = "v2026-03-09D"

local ENTRIES = {
    backstab = {
        id = "backstab",
        displayName = "Backstab",
        practiceKey = "backstab",
        classKey = "thief",
        kind = "skill",
        minLevel = 1,
        tags = { "combat" },
        notes = "Dump-backed thief skill with usage.",
    },
    ["detect traps"] = {
        id = "detect traps",
        displayName = "Detect Traps",
        practiceKey = "detect traps",
        classKey = "thief",
        kind = "skill",
        minLevel = 2,
        tags = { "passive", "utility" },
        aliases = { "detecttraps" },
        notes = "Dump-backed automatic thief skill.",
    },
    ["pick lock"] = {
        id = "pick lock",
        displayName = "Pick Lock",
        practiceKey = "pick lock",
        classKey = "thief",
        kind = "skill",
        minLevel = 4,
        tags = { "utility" },
        aliases = { "pick locks", "picklock", "picklocks" },
        notes = "Dump-backed thief skill. Help title uses PICK LOCKS; canonical practiceKey remains pick lock.",
    },
    pickpocket = {
        id = "pickpocket",
        displayName = "Pickpocket",
        practiceKey = "pickpocket",
        classKey = "thief",
        kind = "skill",
        minLevel = 7,
        tags = { "utility" },
        aliases = { "pick pocket", "pickpocket" },
        notes = "Dump-backed thief skill. Help notes that command usage is via steal gold.",
    },
    ["avoid traps"] = {
        id = "avoid traps",
        displayName = "Avoid Traps",
        practiceKey = "avoid traps",
        classKey = "thief",
        kind = "skill",
        minLevel = 9,
        tags = { "utility" },
        aliases = { "avoidtraps" },
        notes = "Dump-backed thief skill with usage via avoid toggle.",
    },
    haggle = {
        id = "haggle",
        displayName = "Haggle",
        practiceKey = "haggle",
        classKey = "thief",
        kind = "skill",
        minLevel = 1,
        tags = { "passive", "utility" },
        notes = "Dump-backed automatic thief skill. Current uploaded dump excerpt confirms automatic behavior but not explicit thief level.",
    },
    sneak = {
        id = "sneak",
        displayName = "Sneak",
        practiceKey = "sneak",
        classKey = "thief",
        kind = "skill",
        minLevel = 12,
        tags = { "utility" },
        aliases = { "silentwalk" },
        notes = "Dump-backed thief skill. SILENTWALK is alternate name in help text.",
    },
    hide = {
        id = "hide",
        displayName = "Hide",
        practiceKey = "hide",
        classKey = "thief",
        kind = "skill",
        minLevel = 15,
        tags = { "utility" },
        aliases = { "camouflage" },
        notes = "Dump-backed thief skill.",
    },
    trip = {
        id = "trip",
        displayName = "Trip",
        practiceKey = "trip",
        classKey = "thief",
        kind = "skill",
        minLevel = 18,
        tags = { "combat", "fightOnly" },
        notes = "Dump-backed thief skill with usage.",
    },
    ["dual wield"] = {
        id = "dual wield",
        displayName = "Dual Wield",
        practiceKey = "dual wield",
        classKey = "thief",
        kind = "skill",
        minLevel = 22,
        tags = { "passive", "combat" },
        aliases = { "dualwield" },
        notes = "Dump-backed passive thief capability. Valid registry entry, not an ActionPad-trigger action by default.",
    },
    dodge = {
        id = "dodge",
        displayName = "Dodge",
        practiceKey = "dodge",
        classKey = "thief",
        kind = "skill",
        minLevel = 25,
        tags = { "passive", "combat" },
        notes = "Dump-backed automatic thief skill.",
    },
    steal = {
        id = "steal",
        displayName = "Steal",
        practiceKey = "steal",
        classKey = "thief",
        kind = "skill",
        minLevel = 28,
        tags = { "utility" },
        notes = "Dump-backed thief skill with explicit Level 28 Thief entry.",
    },
    circle = {
        id = "circle",
        displayName = "Circle",
        practiceKey = "circle",
        classKey = "thief",
        kind = "skill",
        minLevel = 32,
        tags = { "actionpad", "combat", "fightOnly" },
        notes = "Dump-backed thief level and usage.",
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