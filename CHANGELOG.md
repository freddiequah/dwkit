# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog, and versions follow the project's chosen version tag style.

## Unreleased

### Added
- Initial repository structure
- Governance documentation
- Baseline README, license, changelog
- Runtime baseline module and manual loader init:
  - dwkit.core.runtime_baseline
  - dwkit.loader.init
- Minimal SAFE self-test runner:
  - dwkit.tests.self_test_runner
- Runtime command registry (SAFE):
  - dwkit.bus.command_registry
- SAFE typed command aliases (local, no gameplay output):
  - dwkit.services.command_aliases
  - Commands: dwcommands, dwhelp, dwtest, dwinfo
- VS Code workspace files:
  - .vscode/settings.json
  - .vscode/extensions.json

### Changed
- .gitignore updated to ignore VS Code folder except shareable workspace files
- Documentation hygiene:
  - Filled Architecture Map, Event Registry, and Package Identity stubs
  - Synced Command Registry doc to match runtime registry + typed commands

### Fixed
- None
