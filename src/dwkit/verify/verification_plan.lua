-- #########################################################################
-- BEGIN FILE: src/dwkit/verify/verification_plan.lua
-- #########################################################################
-- Module Name : dwkit.verify.verification_plan
-- Owner       : Verify
-- Version     : v2026-01-28C
-- Purpose     :
--   - Defines verification suites (data only) for dwverify.
--   - Each suite is a named list of steps executed by verification.lua runner.
--
-- Public API  :
--   - getSuites() -> table suites
--   - getSuite(name) -> table|nil suite
--
-- Notes:
--   - This file SHOULD change frequently as features evolve.
--   - Keep verification.lua runner stable; update suites here instead.
--
-- Step format (suite.steps):
--   - String step: a command to execute (e.g., "dwwho", "who", "lua do ... end")
--   - Table step: { cmd="...", note="...", delay=0.4, expect="..." }
--
-- Hard rule:
--   - Any Lua command step MUST be single-line. (No '\n' allowed.)
-- #########################################################################

local M = {}

M.VERSION = "v2026-01-28C"

local SUITES = {
    -- Default suite (safe baseline)
    default = {
        title = "default",
        description = "Baseline sanity: dwwho refresh + watcher capture",
        delay = 0.40, -- default per-step delay (seconds)
        steps = {
            "dwwho",
            "dwwho watch status",
            "dwwho refresh",
            "dwwho",
            "who",
            "dwwho",
        },
    },

    -- WhoStore focused suite (alias convenience)
    whostore = {
        title = "whostore",
        description = "WhoStore sanity: trigger capture path + confirm status updates",
        delay = 0.40,
        steps = {
            "dwwho watch status",
            "dwwho refresh",
            "who",
            "dwwho",
        },
    },

    -- Fixture suite (NO MUD spam; validates parsing + snapshot update)
    whostore_fixture = {
        title = "whostore_fixture",
        description = "WhoStore fixture sanity: clear + ingest fixture + list + status (no who sends)",
        delay = 0.30,
        steps = {
            "dwwho clear",
            "dwwho fixture basic",
            "dwwho list",
            "dwwho status",
        },
    },

    -- Live clear (NO WHO send; asserts empty snapshot after clear)
    whostore_live_clear = {
        title = "whostore_live_clear",
        description = "WhoStore live clear: clear snapshot + assert empty + human confirm (no WHO send)",
        delay = 0.30,
        steps = {
            { cmd = "dwwho clear",  note = "Clear WhoStore snapshot (no WHO send)." },

            {
                cmd =
                'lua do local ok,S=pcall(require,"dwkit.services.whostore_service"); if not ok or type(S)~="table" then error("WhoStoreService require failed") end; local snap=(type(S.getSnapshot)=="function") and S.getSnapshot() or ((type(S.getState)=="function") and S.getState() or nil); if type(snap)~="table" then error("WhoStore snapshot/state missing") end; local byName=snap.byName or (snap.snapshot and snap.snapshot.byName) or nil; local entries=snap.entries or (snap.snapshot and snap.snapshot.entries) or nil; if type(byName)=="table" and next(byName)~=nil then error("WhoStore not empty: byName has entries") end; if type(entries)=="table" and next(entries)~=nil then error("WhoStore not empty: entries has records") end end',
                note = "Assert WhoStore is empty after clear (suite FAILs if not).",
            },

            { cmd = "dwwho status", note = "Human confirmation: expect empty/0 counts." },
        },
    },

    -- NEW: End-to-end controlled live run (guarded refresh + WHO capture)
    whostore_live_refresh_capture = {
        title = "whostore_live_refresh_capture",
        description =
        "E2E live: watcher ON + guarded refresh + single WHO send + verify capture + list/status (controlled)",
        delay = 0.45,
        steps = {
            { cmd = "dwwho watch status", note = "Ensure watcher is enabled before doing any live capture." },

            {
                cmd = "dwwho refresh",
                note = "Trigger a guarded refresh (may skip if cooldown is active).",
                expect = "refresh guard should show lastRefreshAttemptTs updated OR lastSkipReason set (cooldown).",
            },

            { cmd = "who",                note = "Single WHO send to feed watcher triggers and update WhoStore snapshot." },

            {
                cmd = "dwwho",
                note = "Expect WhoStore summary to reflect latest capture (players count may be 0 if nobody online).",
            },

            { cmd = "dwwho list",   note = "If players exist, expect parsed entries listed (names/classes/etc per contract)." },

            { cmd = "dwwho status", note = "Human confirmation: refresh guard + watcher lastErr=nil; source should reflect latest update." },
        },
    },

    -- Smoke suite (very short)
    smoke = {
        title = "smoke",
        description = "Very short smoke check (no who spam unless you choose)",
        delay = 0.20,
        steps = {
            "dwwho watch status",
            "dwwho",
        },
    },
}

function M.getSuites()
    return SUITES
end

function M.getSuite(name)
    if type(name) ~= "string" or name == "" then return nil end
    return SUITES[name]
end

return M

-- #########################################################################
-- END FILE: src/dwkit/verify/verification_plan.lua
-- #########################################################################
