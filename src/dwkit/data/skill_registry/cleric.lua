-- #########################################################################
-- Module Name : dwkit.data.skill_registry.cleric
-- Owner       : Data
-- Version     : v2026-03-09C
-- Purpose     :
--   - Data-only SkillRegistry raw declarations for Cleric entries.
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
    heal = {
        id = "heal",
        displayName = "Heal",
        practiceKey = "heal",
        classKey = "cleric",
        kind = "spell",
        minLevel = 1,
        tags = { "actionpad", "service" },
        notes = "Baseline cleric heal spell.",
    },
    ["power heal"] = {
        id = "power heal",
        displayName = "Power Heal",
        practiceKey = "power heal",
        classKey = "cleric",
        kind = "spell",
        minLevel = 1,
        tags = { "actionpad", "service" },
        aliases = { "ph", "pheal", "powerheal" },
        notes = "Exact minLevel may be refined later.",
    },
    refresh = {
        id = "refresh",
        displayName = "Refresh",
        practiceKey = "refresh",
        classKey = "cleric",
        kind = "spell",
        minLevel = 1,
        tags = { "actionpad", "service" },
        aliases = { "ref" },
        notes = "Common cleric service spell (baseline).",
    },
    feed = {
        id = "feed",
        displayName = "Feed",
        practiceKey = "feed",
        classKey = "cleric",
        kind = "spell",
        minLevel = 1,
        tags = { "actionpad", "service" },
        notes = "Baseline service spell for ActionPad Feed button.",
    },
    restore = {
        id = "restore",
        displayName = "Restore",
        practiceKey = "restore",
        classKey = "cleric",
        kind = "spell",
        minLevel = 1,
        tags = { "actionpad", "service" },
        aliases = { "rst" },
        notes = "Baseline cleric restore spell.",
    },
    rejuvenate = {
        id = "rejuvenate",
        displayName = "Rejuvenate",
        practiceKey = "rejuvenate",
        classKey = "cleric",
        kind = "spell",
        minLevel = 1,
        tags = { "actionpad", "service" },
        aliases = { "rej" },
        notes = "Baseline cleric rejuvenate spell.",
    },
    bless = {
        id = "bless",
        displayName = "Bless",
        practiceKey = "bless",
        classKey = "cleric",
        kind = "spell",
        minLevel = 1,
        tags = { "actionpad", "buff" },
        aliases = { "buff" },
        notes = "Mapped as baseline buff spell for ActionPad.",
    },
    calm = {
        id = "calm",
        displayName = "Calm",
        practiceKey = "calm",
        classKey = "cleric",
        kind = "spell",
        minLevel = 1,
        tags = { "actionpad", "utility" },
    },
    summon = {
        id = "summon",
        displayName = "Summon",
        practiceKey = "summon",
        classKey = "cleric",
        kind = "spell",
        minLevel = 1,
        tags = { "actionpad", "movement" },
        notes = "Baseline move-action spell for ActionPad coverage.",
    },
    relocate = {
        id = "relocate",
        displayName = "Relocate",
        practiceKey = "relocate",
        classKey = "cleric",
        kind = "spell",
        minLevel = 1,
        tags = { "actionpad", "movement" },
        notes = "Baseline move-action spell for ActionPad coverage.",
    },
    ["group armor"] = {
        id = "group armor",
        displayName = "Group Armor",
        practiceKey = "group armor",
        classKey = "cleric",
        kind = "spell",
        minLevel = 1,
        tags = { "actionpad", "group", "buff" },
        aliases = { "garm", "g armor", "garmor" },
        notes = "Baseline group support spell for ActionPad group utility coverage.",
    },
    ["group recall"] = {
        id = "group recall",
        displayName = "Group Recall",
        practiceKey = "group recall",
        classKey = "cleric",
        kind = "spell",
        minLevel = 1,
        tags = { "actionpad", "group", "utility" },
        aliases = { "grec", "grecall", "g recall" },
        notes = "Baseline group utility spell for ActionPad GRec coverage.",
    },
    ["group heal"] = {
        id = "group heal",
        displayName = "Group Heal",
        practiceKey = "group heal",
        classKey = "cleric",
        kind = "spell",
        minLevel = 1,
        tags = { "actionpad", "group", "service" },
        aliases = { "gh", "gheal", "g heal" },
        notes = "Baseline group healing spell.",
    },
    ["group rejuvenate"] = {
        id = "group rejuvenate",
        displayName = "Group Rejuvenate",
        practiceKey = "group rejuvenate",
        classKey = "cleric",
        kind = "spell",
        minLevel = 1,
        tags = { "actionpad", "group", "service" },
        aliases = { "grej", "g rej", "grejuvenate" },
        notes = "Baseline group rejuvenate spell.",
    },
    ["group power heal"] = {
        id = "group power heal",
        displayName = "Group Power Heal",
        practiceKey = "group power heal",
        classKey = "cleric",
        kind = "spell",
        minLevel = 1,
        tags = { "actionpad", "group", "service" },
        aliases = { "gph", "gpheal", "g power heal", "gpowerheal" },
        notes = "Baseline group power-heal spell.",
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