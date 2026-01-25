-- #########################################################################
-- Module Name : dwkit.commands.dwrelease
-- Owner       : Commands
-- Version     : v2026-01-25A
-- Purpose     :
--   - Handler for "dwrelease" command surface.
--   - SAFE: prints a release workflow checklist (manual steps only).
--   - No gameplay sends. No timers.
--
-- Public API  :
--   - dispatch(ctx, kit) -> boolean ok, string|nil err
--   - reset() -> nil
-- #########################################################################

local M = {}
M.VERSION = "v2026-01-25A"

local function _fallbackOut(line)
  line = tostring(line or "")
  if type(cecho) == "function" then
    cecho(line .. "\n")
  elseif type(echo) == "function" then
    echo(line .. "\n")
  else
    print(line)
  end
end

local function _fallbackErr(msg)
  _fallbackOut("[DWKit Release] ERROR: " .. tostring(msg))
end

local function _getCtx(ctx)
  ctx = (type(ctx) == "table") and ctx or {}
  return {
    out = (type(ctx.out) == "function") and ctx.out or _fallbackOut,
    err = (type(ctx.err) == "function") and ctx.err or _fallbackErr,
  }
end

local function _resolveKit(kit)
  if type(kit) == "table" then return kit end
  if type(_G) == "table" and type(_G.DWKit) == "table" then return _G.DWKit end
  if type(DWKit) == "table" then return DWKit end
  return nil
end

local function _safeRequire(modName)
  local ok, mod = pcall(require, modName)
  if ok and type(mod) == "table" then return true, mod, nil end
  return false, nil, tostring(mod)
end

local function _tryDispatch(C, modName, ...)
  local okM, mod, errM = _safeRequire(modName)
  if not okM or type(mod.dispatch) ~= "function" then
    C.err("Missing " .. tostring(modName) .. " (" .. tostring(errM) .. ")")
    return false
  end
  local okCall, a, b = pcall(mod.dispatch, C, ...)
  if not okCall or a == false then
    C.err("dispatch failed for " .. tostring(modName) .. ": " .. tostring(b or a))
    return false
  end
  return true
end

function M.dispatch(ctx, kit)
  local C = _getCtx(ctx)
  local K = _resolveKit(kit)

  C.out("[DWKit Release] checklist (dwrelease)")
  C.out("  NOTE: SAFE + manual-only. This does not run git/gh commands.")
  C.out("")

  C.out("== versions (best-effort) ==")
  C.out("")
  _tryDispatch(C, "dwkit.commands.dwversion", K, "(via dwrelease)")
  C.out("")

  C.out("== PR workflow (PowerShell + gh) ==")
  C.out("")
  C.out("  1) Start clean:")
  C.out("     - git checkout main")
  C.out("     - git pull")
  C.out("     - git status -sb")
  C.out("")
  C.out("  2) Create topic branch:")
  C.out("     - git checkout -b <topic/name>")
  C.out("")
  C.out("  3) Commit changes (scope small):")
  C.out("     - git status")
  C.out("     - git add <paths...>")
  C.out("     - git commit -m \"<message>\"")
  C.out("")
  C.out("  4) Push branch:")
  C.out("     - git push --set-upstream origin <topic/name>")
  C.out("")
  C.out("  5) Create PR:")
  C.out("     - gh pr create --base main --head <topic/name> --title \"<title>\" --body \"<body>\"")
  C.out("")
  C.out("  6) Review + merge (preferred: squash + delete branch):")
  C.out("     - gh pr status")
  C.out("     - gh pr view")
  C.out("     - gh pr diff")
  C.out("     - gh pr checks    (if configured)")
  C.out("     - gh pr merge <PR_NUMBER> --squash --delete-branch")
  C.out("")
  C.out("  7) Sync local main AFTER merge:")
  C.out("     - git checkout main")
  C.out("     - git pull")
  C.out("     - git log -1 --oneline --decorate")
  C.out("")

  C.out("== release tagging discipline (annotated tag on main HEAD) ==")
  C.out("")
  C.out("  1) Verify main HEAD is correct:")
  C.out("     - git checkout main")
  C.out("     - git pull")
  C.out("     - git log -1 --oneline --decorate")
  C.out("")
  C.out("  2) Create annotated tag (after merge):")
  C.out("     - git tag -a vYYYY-MM-DDX -m \"<tag message>\"")
  C.out("     - git push origin vYYYY-MM-DDX")
  C.out("")
  C.out("  3) Verify tag targets origin/main:")
  C.out("     - git rev-parse --verify origin/main")
  C.out("     - git rev-parse --verify 'vYYYY-MM-DDX^{}'")
  C.out("     - (expected: hashes match)")
  C.out("")
  C.out("  4) If you tagged wrong commit (fix safely):")
  C.out("     - git tag -d vYYYY-MM-DDX")
  C.out("     - git push origin :refs/tags/vYYYY-MM-DDX")
  C.out("     - (then recreate on correct main HEAD)")

  return true, nil
end

function M.reset()
  -- no persistent state
end

return M
