-- #########################################################################
-- Module Name : dwkit.core.runtime_baseline
-- Owner       : Core
-- Version     : v2026-01-06F
-- Purpose     :
--   - Provide manual runtime baseline info (Mudlet + Lua runtime strings).
--   - DOES NOT send gameplay commands.
--   - DOES NOT start timers or automation.
--
-- Public API  :
--   - getInfo() -> table
--   - printInfo() -> table (also prints lines to console)
--
-- Events Emitted   : None
-- Events Consumed  : None
-- Persistence      : None
-- Automation Policy: Manual only
-- Dependencies     : dwkit.core.identity
-- #########################################################################

local M = {}

M.VERSION = "v2026-01-06F"

local ID = require("dwkit.core.identity")

local function safeToString(v)
    if v == nil then return "nil" end
    if type(v) == "table" then return "table" end
    return tostring(v)
end

local function detectMudletVersion()
    if type(mudlet) == "table" and mudlet.version ~= nil then
        -- If it's already a simple value, return it.
        if type(mudlet.version) == "string" or type(mudlet.version) == "number" then
            return safeToString(mudlet.version)
        end

        -- Some Mudlet builds expose version as a table. Try common fields.
        if type(mudlet.version) == "table" then
            local v = mudlet.version
            if v.string then return safeToString(v.string) end
            if v.version then return safeToString(v.version) end
            if v.major and v.minor and v.patch then
                return string.format("%s.%s.%s", safeToString(v.major), safeToString(v.minor), safeToString(v.patch))
            end

            -- Fall back to "table" rather than a memory address like "table: 0x...."
            return "table"
        end

        return safeToString(mudlet.version)
    end

    if type(getMudletVersion) == "function" then
        local ok, v = pcall(getMudletVersion)
        if ok and v then
            if type(v) == "table" then
                local major = v.major
                local minor = v.minor
                local rev   = v.revision
                local build = v.build

                if major ~= nil and minor ~= nil and rev ~= nil then
                    if build ~= nil and tostring(build) ~= "" then
                        return string.format("%s.%s.%s+%s", tostring(major), tostring(minor), tostring(rev),
                            tostring(build))
                    end
                    return string.format("%s.%s.%s", tostring(major), tostring(minor), tostring(rev))
                end

                return "table"
            end

            return safeToString(v)
        end
    end

    return "unknown"
end

function M.getInfo()
    return {
        packageId     = ID.packageId,
        luaVersion    = safeToString(_VERSION),
        mudletVersion = detectMudletVersion(),
    }
end

function M.printInfo()
    local info = M.getInfo()

    local line1 = string.format("[DWKit] packageId=%s", info.packageId)
    local line2 = string.format("[DWKit] lua=%s mudlet=%s", info.luaVersion, info.mudletVersion)

    if type(cecho) == "function" then
        cecho(line1 .. "\n")
        cecho(line2 .. "\n")
    else
        print(line1)
        print(line2)
    end

    return info
end

return M
