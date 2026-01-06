# dwkit

A personal, modular Mudlet kit for the Deathwish MUD.

This repository is public so others can download and use it, but it is maintained primarily for my own workflow and preferences.

## Status
- Development: active (personal)
- Support level: best-effort, no guarantees
- Contributions: not accepting PRs (please fork)

## Compatibility
- Mudlet baseline: 4.19.1
- Lua runtime: Mudlet embedded Lua (verified at runtime)

## What you get
- Modular structure (core, services, UI) designed to stay maintainable
- Per-profile persistence (no hardcoded profile names or absolute paths)
- UI designed to be controllable (show/hide) from a single control surface
- Safe-by-default behavior (no hidden automation unless explicitly enabled)

## Install (recommended)
1. Go to Releases and download the latest package file.
2. In Mudlet: Package Manager → Install Package
3. Restart Mudlet.

### Install from source (advanced)
If you clone this repo, you are expected to package it yourself for Mudlet. Releases are the easiest route.

## Quick start
After installing:
1. Enable the modules you want (via the kit controls, if present in your version).
2. Run diagnostics/self-test (if present) to confirm your environment.
3. Use the command listing/help (if present) to discover available commands.

## Documentation
- Governance and development standard: docs/GOVERNANCE.md
- Changelog: CHANGELOG.md

## Safety notes
This kit aims to avoid surprising behavior:
- No gameplay commands should run automatically unless explicitly enabled.
- Any gameplay command wrappers should be clearly labeled and manual by default.

## Support policy
You are welcome to use and fork this project.

I do not promise support. If you open an issue, please include:
- Mudlet version
- OS
- steps to reproduce
- relevant logs/output/screenshots

## License
MIT License. See LICENSE.
