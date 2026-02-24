-- #########################################################################
-- Module Name : dwkit.ui.ui_theme
-- Owner       : UI
-- Version     : v2026-02-24A
-- Purpose     :
--   - Centralized DWKit UI theme styles (Qt stylesheet strings).
--   - Mirrors the proven dwkit.txt aesthetic:
--       * Dark header background + blue accent border
--       * Muted secondary text
--       * ActionPad-style buttons and labels
--
-- Public API  :
--   - headerStyle() -> string
--   - closeStyle() -> string
--   - frameStyle() -> string
--   - bodyStyle() -> string
--   - nameStyle(active:boolean) -> string
--   - stateStyle() -> string
--   - infoStyle() -> string
--   - buttonStyle(enabled:boolean) -> string
--
-- Events Emitted   : None
-- Events Consumed  : None
-- Automation Policy: Manual only
-- Dependencies     : None
-- #########################################################################

local M = {}

M.VERSION = "v2026-02-24A"

-- Header: dark + bottom accent line (dwkit.txt: themeHeaderStyle)
function M.headerStyle()
    return [[
        background-color: #18222f;
        border: 0px;
        border-bottom: 1px solid #4a6fa5;
        color: #e5e9f0;
        padding-left: 8px;
        qproperty-alignment: 'AlignVCenter | AlignLeft';
    ]]
end

-- Close button: dark + red text (dwkit.txt: themeCloseStyle)
function M.closeStyle()
    return [[
        background-color: #18222f;
        border: 0px;
        color: #e06c75;
        qproperty-alignment: 'AlignCenter';
    ]]
end

-- Frame: transparent background + blue border
function M.frameStyle()
    return [[
        background-color: rgba(0,0,0,0);
        border: 1px solid #4a6fa5;
    ]]
end

-- Body/container default:
-- IMPORTANT (v2026-02-24A):
-- Use an OPAQUE dark body background to prevent Mudlet/Qt default grey bleed-through on some builds.
-- This aligns with the proven dwkit.txt look where the "inside" paint surface is explicitly forced dark.
function M.bodyStyle()
    return [[
        background-color: rgba(10,12,16,230);
        border: 1px solid #2a2f3a;
        border-radius: 6px;
        color: #e5e9f0;
    ]]
end

-- ActionPad label/button styles (ported from dwkit.txt helper table H.*Style)
function M.nameStyle(active)
    if active then
        return [[
            background-color: rgba(30,59,90,200);
            border: 1px solid #4a6fa5;
            border-radius: 6px;
            color: #ffffff;
            padding-left: 8px;
            font-size: 9pt;
            qproperty-alignment: 'AlignVCenter | AlignLeft';
        ]]
    end

    return [[
        background-color: #14181f;
        border: 1px solid #2a2f3a;
        border-radius: 6px;
        color: #8b93a6;
        padding-left: 8px;
        font-size: 9pt;
        qproperty-alignment: 'AlignVCenter | AlignLeft';
    ]]
end

function M.stateStyle()
    return [[
        background-color: rgba(0,0,0,0);
        border: 0px;
        color: #8b93a6;
        padding-left: 8px;
        font-size: 8pt;
        qproperty-alignment: 'AlignVCenter | AlignLeft';
    ]]
end

function M.infoStyle()
    return [[
        background-color: rgba(0,0,0,0);
        border: 0px;
        color: #e5e9f0;
        padding-left: 2px;
        font-size: 9pt;
        qproperty-alignment: 'AlignVCenter | AlignLeft';
    ]]
end

function M.buttonStyle(enabled)
    if enabled then
        return [[
            background-color: #1e3b5a;
            border: 1px solid #88c0ff;
            border-radius: 6px;
            color: #ffffff;
            font-size: 7pt;
            qproperty-alignment: 'AlignCenter';
        ]]
    end

    return [[
        background-color: #14181f;
        border: 1px solid #2a2f3a;
        border-radius: 6px;
        color: #8b93a6;
        font-size: 7pt;
        qproperty-alignment: 'AlignCenter';
    ]]
end

return M