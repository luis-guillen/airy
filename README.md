<p align="center">
  <img src="Resources/Airy-1024.png" width="128" height="128" alt="Airy icon">
</p>

<h1 align="center">Airy</h1>

<p align="center">
  <b>See what fills your Mac, and free space without deleting anything you shouldn't.</b><br>
  Disk map, safe cleanup, performance and an MCP server for AI agents. Native SwiftUI.
</p>

<p align="center">
  <a href="https://github.com/luis-guillen/airy/actions/workflows/ci.yml"><img src="https://github.com/luis-guillen/airy/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/luis-guillen/airy/releases/latest"><img src="https://img.shields.io/github/v/release/luis-guillen/airy?color=2f8bff" alt="Latest release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0-blue" alt="GPL-3.0"></a>
  <img src="https://img.shields.io/badge/macOS-15%2B-0b1b3f?logo=apple" alt="macOS 15+">
  <img src="https://img.shields.io/badge/Swift-6.3%2B-F05138?logo=swift&logoColor=white" alt="Swift 6.3+">
</p>

<p align="center">
  <a href="README.es.md">Leer en español</a>
</p>

---

> [!NOTE]
> The app's interface is in **Spanish** for now. Translations are welcome; see [Contributing](CONTRIBUTING.md).

## Contents

- [Why Airy](#why-airy)
- [Features](#features)
- [Safety model](#safety-model)
- [Install](#install)
- [Connect an AI agent (MCP)](#connect-an-ai-agent-mcp)
- [Build from source](#build-from-source)
- [Architecture](#architecture)
- [Testing](#testing)
- [Releasing](#releasing)
- [Privacy](#privacy)
- [Contributing](#contributing)
- [Credits](#credits)
- [License](#license)

## Why Airy

Most cleaners either do too little or delete too much. Airy scans your disk and shows it as an
interactive treemap. Every item it can remove gets one of three labels:

- **Sin problema** (safe): regenerates on its own.
- **Tú decides** (your call): it's yours to decide.
- **No borrar** (never): Airy won't touch it.

Every decision is made locally, from a closed catalog, behind hard protections. Nothing is deleted
without your confirmation.

It also ships `airy-mcp`, a stdio [MCP](https://modelcontextprotocol.io) server, so Claude Code, Codex or
any MCP client can inspect your disk and *propose* cleanups. Agents never act on anything that isn't
safe.

## Features

| Section | What it does |
|---|---|
| **Map** | Zoomable disk treemap with color categories, real allocated sizes and an incremental saved index. |
| **Cleanup** | Caches, logs and developer artifacts (`node_modules`, DerivedData, Docker…). Duplicate toolchain versions: pyenv, conda, rustup, Homebrew. Aggressive and Careful modes, multi-select and «Borrar todo» (delete all) with a single confirmation. |
| **Performance** | Memory, CPU, thermal state and battery, plus the heaviest apps. Quit apps with confirmation, run reversible maintenance, and get an optional AI answer to «¿Por qué va lento?» (why is it slow?). |
| **AI assistant** | Report and chat about your disk through Claude. Metadata only, never file contents. |
| **Uninstaller** | Removes apps and their leftovers. Uses Homebrew only when its uninstall steps are verifiably safe, otherwise the Trash. Also finds orphaned leftovers and broken symlinks. |
| **Large & old** | Big files you haven't opened in a while, with filters. |
| **Duplicates** | Byte-identical copies, verified again before trashing. The copy you keep is never selected. |
| **File types** | Space per kind (video, photos, code…) with drill-down to the files. |

The wind animations pause when the window isn't visible, respect *Reduce Motion* and are frame-rate
capped. Airy uses no CPU at rest.

## Safety model

Protection is layered, and the layers run in this order. No later layer can lower the risk set by an
earlier one.

1. **Hard protections.** These are never selected and never trashed:
   - personal folders;
   - system locations: `/System`, `/Library`, `/usr`, `/Applications`, `/opt/homebrew`;
   - personal data: iCloud Drive, Mail, Messages, Keychains, Photos and Contacts;
   - Docker volumes;
   - SSH and GPG keys;
   - browser profile data: Safari, Chrome, Brave, Firefox, Arc, Opera, Edge, Vivaldi and Chromium;
   - data of Signal, password managers and other sensitive apps.

   Caches inside those apps stay cleanable, but only at the exact paths the catalog declares.
2. **Closed catalog.** Every cleanable item is an entry in `catalog.json` with its paths, risk and
   official command, if it has one. `CommandPolicy` checks each command again right before it runs. It
   forbids, among others, `docker volume prune`, `--volumes` and `brew --zap`.
3. **In use.** Nothing open, owned by a running process or required by a project is touched. If Airy
   can't verify this in time, it leaves the item alone.
4. **Single funnel.** Every destructive action goes through `ConfirmSheet → AppModel → CleanupExecutor`.
   Quitting apps has its own confirmed path, `QuitExecutor`. Items go to the Trash whenever possible, and
   every operation is logged.
5. **Agents are bounded.**
   - Over MCP, agents can run only what is green in the current mode.
   - Amber and red items can only be *proposed*, never run.
   - Agents never quit apps, never uninstall and never empty the Trash.
   - If the agent switch is off, or the settings can't be read, every action is blocked, `dry_run`
     included.

Found a way around any of this? See [SECURITY.md](SECURITY.md).

## Install

### From a release

1. Download `Airy-<version>.zip` from [Releases](https://github.com/luis-guillen/airy/releases) and unzip it.
2. Move **Airy.app** to `/Applications`.
3. The app is signed with a local identity and isn't notarized. The first time, right-click → **Open**,
   or run:
   ```bash
   xattr -dr com.apple.quarantine /Applications/Airy.app
   ```
4. Turn on Airy in **System Settings → Privacy & Security → Full Disk Access**. Without it, the scan is
   partial.

Requirements: macOS 15 or later on Apple Silicon. Release builds are `arm64`; on Intel, build from
source.

## Connect an AI agent (MCP)

The server is bundled inside the app at `Airy.app/Contents/MacOS/airy-mcp`. **Asistente IA → Conectar
agente** generates and exports the config. To set it up by hand:

```bash
# Claude Code
claude mcp add -s user airy -- /Applications/Airy.app/Contents/MacOS/airy-mcp
```

```json
{
  "mcpServers": {
    "airy": { "command": "/Applications/Airy.app/Contents/MacOS/airy-mcp", "args": [] }
  }
}
```

Tools:

- **Read:** `get_disk_summary`, `list_largest`, `explain_path`, `list_cleanup_items`,
  `get_performance`, `list_apps`, `explain_app`, `list_orphans`, `list_large_old`, `list_duplicates`,
  `scan_status`.
- **Act:** `run_safe_cleanup`, `run_safe_cleanup_all` (green only, supports `dry_run`),
  `propose_cleanup`, `propose_quit_app`, `propose_uninstall`, `show_in_app`.

Proposals open Airy through an `airy://…` URL. You always confirm.

## Build from source

The Xcode Command Line Tools are enough; full Xcode isn't required.

```bash
git clone https://github.com/luis-guillen/airy.git && cd airy
swift build                           # debug
swift test --no-parallel              # ~950 tests
bash scripts/build-app.sh             # signed build/Airy.app
bash scripts/build-app.sh --install   # also installs into /Applications
```

`build-app.sh` creates a local signing identity, **"Airy Local Signing"**, in your login keychain once.
Because every build is signed with it, macOS keeps the Full Disk Access grant across rebuilds.

DEBUG-only environment variables let you develop without touching your real disk:

| Variable | Effect |
|---|---|
| `AIRY_SUPPORT_DIR` | Alternative data folder for the index, settings and log. |
| `AIRY_SCAN_ROOTS` | Scan only these folders, separated by `:`. |
| `AIRY_APP_ROOTS` | Fake app folders for the Uninstaller. |
| `AIRY_REDUCE_MOTION` | Force *Reduce Motion*. |
| `AIRY_MOTION_GALLERY` | Animation gallery. |

## Architecture

```
Sources/
├── DiskMapCore/      UI-free logic (this is what the tests cover)
│   ├── Scan/         Concurrent scanner with a bounded worker pool and incremental index
│   ├── Catalog/      Cleanup catalog (Resources/catalog.json)
│   ├── Cleanup/      Detection sources, CleanupExecutor, toolchains, Docker, app caches…
│   ├── Safety/       HardProtections, CommandPolicy, ProcessGuard, time budgets
│   ├── Performance/  Process, memory, thermal and battery probes
│   ├── Apps/         App inventory, Homebrew casks, receipts, orphans
│   ├── Sections/     Large & old, duplicates, file types
│   ├── AI/           Locked-down Claude CLI invocation (metadata only)
│   └── MCP/          Protocol and server tools
├── Airy/             SwiftUI app (sections, design system, wind animations)
└── AiryMCP/          airy-mcp executable (stdio)
Tests/DiskMapCoreTests/   Swift Testing
docs/superpowers/         Design specs and implementation plans (Spanish)
```

## Testing

```bash
swift test --no-parallel
```

Tests use temporary folders and fake processes. They never delete real files or run real cleanups.
Some tests check timing, so run them serially (`--no-parallel`) to avoid flakes on a busy machine. CI
runs on every push and pull request.

## Releasing

```bash
bash scripts/release.sh 0.3.0
```

The script:

1. bumps the version in `Info.plist`;
2. runs the tests;
3. builds and signs the app;
4. packages `Airy-<version>.zip` with its SHA-256;
5. tags `v<version>` and publishes a GitHub release with the notes from `CHANGELOG.md`.

## Privacy

- Airy has no telemetry and talks to no server of its own.
- AI is opt-in. It uses your own Claude CLI with tools disabled, no MCP and no saved session, and it
  only receives metadata: paths, sizes and process names. It never receives file contents.

## Contributing

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) and our
[Code of Conduct](CODE_OF_CONDUCT.md). Bug reports and ideas can be written in English or Spanish.

## Credits

Airy adapts ideas and path lists from [Mole](https://github.com/tw93/Mole) (GPL-3.0). It contains no Mole
code. The credit also appears in **About Airy**.

## License

[GPL-3.0-or-later](LICENSE) © 2026 Luis Guillén and Airy contributors.
