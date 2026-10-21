# Changelog

All notable changes to Airy are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [SemVer](https://semver.org/).

## [Unreleased]

### Added
- English localization. English is now the base language and Spanish a full translation; the app follows the macOS language.

### Changed
- Airy is open source under the **MIT License**.
- Code comments, docs, design specs and repository content are in English.

## [0.2.0] - 2026-10-21

### Added
- New identity: DiskMap is now **Airy**, with a new logo, a cool-blue palette and wind animations (breeze, leaves, gusts).
- **Aggressive cleanup**:
  - Aggressive and Careful modes, and the labels *Safe to remove* / *Your call* / *Don't delete*.
  - Multi-select and *Delete all* with a single confirmation, with amber items kept apart.
  - Cleanup for Docker, Node, Xcode and app caches.
  - Duplicate toolchain versions for pyenv, conda, rustup and Homebrew. The version in use is always red.
- **Performance** section:
  - Memory, CPU, thermal state and battery.
  - Quit apps with a confirmation, and a second confirmation to force quit.
  - Reversible maintenance, and an optional AI answer to *Why is it slow?*
- **Uninstaller** (leftovers, orphans, broken links), **Large & old**, **Duplicates** and **File types** sections.
- `airy-mcp` **MCP server**, with read tools, `airy://` proposals and green-only cleanup.
- Hard protection for browser profile data (Safari, Chrome, Brave, Firefox, Arc, Opera, Edge, Vivaldi, Chromium) and for Signal.

### Changed
- The scanner caps its worker threads and runs at lower priority.
- Automatic detection waits for the saved index and reuses it, so CPU is near 0 % after launch.
- Background animations are frame-rate capped and pause when the window isn't visible.

### Fixed
- The window froze during a full scan, because the progress ring used a spring animation every 100 ms.
- The lower sidebar rows didn't receive clicks.
- Performance crashed from a constraint loop in system checkboxes and buttons.
- Homebrew uninstalls never use `--zap`. The cask is checked first, and if it touches anything protected, the app goes to the Trash instead.

## [0.1.0] - 2026-10-20

### Added
- First version (DiskMap): disk map, incremental index, basic catalog-driven cleanup to the Trash.

[Unreleased]: https://github.com/luis-guillen/airy/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/luis-guillen/airy/releases/tag/v0.2.0
