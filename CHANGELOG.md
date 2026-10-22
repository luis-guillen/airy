# Changelog

All notable changes to Airy are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [SemVer](https://semver.org/).

## [Unreleased]

### Added

- Cleanup: **Old temporary files**, one row with the entries of your user temporary folder that nothing changed
  in 3 days and no process has open (green in Aggressive, amber in Careful). `/private/tmp` stays protected.
- Cleanup: **Archives already extracted**, `.zip`, `.dmg`, `.tar`, `.7z` and `.rar` files over 200 MB in
  Downloads, Desktop and Documents next to a folder with the same name. Always "Your call".
- Cleanup: **Merged git worktrees**, extra worktrees of your projects whose branch is merged and that have no
  uncommitted changes. Never the main or a locked worktree. Always "Your call".
- Map: **What changed** card with what grew and shrank since the previous scan; click a row to reveal it in
  Finder. New read-only MCP tool `what_changed`.
- A notice when free space drops by more than 10 GB within 10 minutes, with the largest deleted-but-open files.
  `get_disk_summary` reports it as `recent_space_drop`. Airy never acts on it.

### Changed
- Performance: scans read folders with `getattrlistbulk` and fold small files while reading (about 2.5× faster and less than half the CPU on a 220k-item tree), tree nodes are smaller, and the index is written in a compact format about a third of the size (older indexes are read and converted). Only the Map is redrawn by the 30-second "Last scan" clock.
- Folders Airy protects only as a whole (`/Users`, your home, `~/Library`, `~/Documents`…) no longer show the red “Don't delete”: the Map card and the rows show a blue “Protected folder” and say that what's inside can still be cleaned. Locations sealed with their contents (`/System`, Mail, keychains, browser profiles…) keep “Don't delete” and say that nothing inside is touched either. `explain_path` gains `protection_scope` (`folder_only` / `folder_and_contents`) and `protection_scope_note`. Display only: what is protected doesn't change.

## [0.3.0] - 2026-10-21

### Added
- English localization. English is now the base language and Spanish a full translation; the app follows the macOS language.
- **Settings** section (last in the sidebar, also ⌘,): language with restart, animations, Full Disk Access status, automatic rescan and its age, default disk, excluded folders (never scanned), cleanup mode, Protected by you, agents and MCP, an AI switch, Airy's data (delete scan index, clear operation log, reset all settings) and About.

### Changed
- Airy is open source under the **GPL-3.0** license.
- Code comments, docs, design specs and repository content are in English.
- The MCP server always answers in English; AI prompts ask Claude to reply in your language.

### Fixed
- Browser per-profile caches (e.g. Chrome `*/Code Cache`) are cleanable again while profile data stays protected.

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

[Unreleased]: https://github.com/luis-guillen/airy/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/luis-guillen/airy/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/luis-guillen/airy/releases/tag/v0.2.0
