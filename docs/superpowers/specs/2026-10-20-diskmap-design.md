# DiskMap — Design

Date: 2026-10-20
Status: ready for approval

## 1. What it is and why

DiskMap is a native macOS app that analyzes the user's disk, shows it as an **interactive block map** (treemap), and helps them **actually free up space**: it explains in plain language what each item is, recommends with AI what to delete and what not to, and deletes it safely by itself.

It grew out of a manual cleanup session (2026-10-20) in which ~60 GB were recovered by deleting forgotten AI models, Docker/uv/cargo/Homebrew/conda/Spotify/Brave caches, half-uninstalled apps (Ollama, Whisky) and app leftovers. Every step required knowing **what each folder was, whether anything was using it, and how to delete it properly**. DiskMap must do that work automatically.

**User:** the owner of the Mac (technical profile, developer: Docker, Python/Anaconda, Rust, Node, AI tools). Speaks Spanish; the whole interface is in **Spanish (Spain)**.

**Success:** the user opens DiskMap, sees within seconds what is taking up space, understands what each item is without googling it, and frees several GB with a few clicks without fear of breaking anything. And the app is so beautiful that it is a pleasure to open.

## 2. Goals

1. **Block map** (a "squarified" treemap) of the whole disk or of one folder, interactive:
   - When the analysis finishes, the blocks enter with a staggered animation.
   - Click on a block → animated zoom inward (the block grows to fill the map and its children appear). A navigation path (breadcrumb) at the top to go back; also back via gesture/key.
   - Color by **content type** (video, images, apps, code/projects, caches, AI models, containers/VMs, documents, system, other), with a legend.
   - On hover: name, size, % of the parent, last-used date and a **plain-language explanation** of what it is.
   - Must stay smooth with thousands of blocks.
2. **Sections** (sidebar, in the style of cleanup apps like CleanMyMac/AppCleaner):
   1. **Map** — the treemap.
   2. **Cleanup** — caches, logs and leftovers detected automatically, each with an explanation, size and risk. Minimum cases (all seen in the session): Docker build cache, Homebrew, pip, uv, pnpm, npm, cargo (registry/git), conda pkgs, Hugging Face hub, Ollama models, `~/.cache/whisper`, Playwright, browser caches (Brave/Chrome/Safari), Spotify, Xcode DerivedData/simulators if present, logs, half-finished installs (e.g. `codex-runtime-install-*`).
   3. **Uninstaller** — list of apps with their **real size** (app + leftovers in `~/Library`: Application Support, Caches, Containers, Preferences, Saved Application State, HTTPStorages, Logs, LaunchAgents) and complete removal leaving no leftovers. It also detects **orphaned leftovers** of already-uninstalled apps (such as Whisky or Ollama) and broken links in `/usr/local/bin`.
   4. **Large & old** — the largest files and those that have gone months without being opened, sortable and filterable.
   5. **Duplicates** — identical files (same content) grouped, letting the user choose which one to keep.
   6. **File types** — how much each type takes up (video, photos, code, AI models…), with an animated chart and access to the files of each type.
   7. **AI Assistant** — two modes:
      - **Report**: reviews the analysis and classifies into **Safe to delete / Up to you / Don't touch**, with the reason for each item and the total recoverable space. Deletion can be done directly from the report.
      - **Chat**: free-form questions about the disk ("what is this folder?", "can I delete this?"), with the analysis as context. The chat can propose actions that the user confirms with a button.
3. **Deletion by the app itself** (user decision):
   - Files and folders → **Trash** (recoverable), never direct permanent deletion.
   - Tool caches → **their official command** when one exists (`docker builder prune -a -f`, `brew cleanup --prune=all -s`, `uv cache clean`, `pnpm store prune`, `pip cache purge`, `conda clean --all -y`, `ollama rm`…), because deleting their folders by hand can leave them inconsistent.
   - Anything that requires administrator permissions (e.g. root-owned links in `/usr/local/bin`) → system password dialog.
   - Always a **confirmation** before deleting, showing what will be deleted and how much will be freed; afterwards, an animation with the space recovered and the accumulated total freed.
4. **Explanations** for everything shown: a **local catalog** of known paths and patterns (what it is, who creates it, whether it regenerates, risk of deleting it) covers the usual cases without AI or network; the AI explains what the catalog does not know.
5. **Light and fast**: small binary, low RAM use at rest, parallel analysis using all cores, results that appear progressively while it analyzes.

## 3. Non-goals

- It is not an antivirus, nor a RAM/battery optimizer, nor a Mac "accelerator".
- It does not sync anything to the cloud and has no user accounts.
- It is not cross-platform (macOS only).
- It does not need to be distributed on the App Store (personal use; ad-hoc signing is enough).

## 4. Anti-goals (failure even if it "works")

- **Deleting something important.** Never propose as "safe" nor delete without warning:
  - The user's documents, photos, projects and personal files (always "Up to you").
  - **Docker volumes** (they contain project databases: `*_pgdata`, `*_datos_db`…) → "Don't touch" unless explicitly requested.
  - Models or data **used by another project**: before recommending deleting a shared model/cache, check references (as was done with the shared Hugging Face blobs).
  - Anything **in use**: do not clean the cache of an open app (Spotify, Brave, ChatGPT…); ask to close it first, or do it for the user if they accept. Do not touch runtimes in use (e.g. `codex-primary-runtime`).
  - Nothing under `/System`, nor SIP-protected paths; handle "Operation not permitted" errors gracefully (e.g. `~/Library/Containers` metadata).
- **Sending file contents to the internet.** Only path names, sizes, dates and types go to the AI; never the content.
- **Looking generic** or "templated": it has to look like a first-rate Apple app (ChatGPT-for-Mac level), not a developer tool.
- **Stuttering**: zoom and transitions must run at 60–120 fps (ProMotion).
- **Lying with numbers**: sizes must be real disk space (allocated blocks, without double-counting hard links or sparse files such as `Docker.raw` by their apparent size).

## 5. Constraints

- **Machine:** MacBook with Apple M4 Pro, 24 GB RAM, macOS 27.0.1, 460 GB disk.
- **Xcode is not installed**, only Command Line Tools with **Swift 6.4**. The project must build with **Swift Package Manager** and a script that packages the `.app` (Info.plist, `.icns` icon with `iconutil`, ad-hoc signing with `codesign -s -`). If at any point Xcode turns out to be indispensable, warn first.
- **Full Disk Access:** to see `~/Library/Containers`, Mail, etc., the user must grant DiskMap the "Full Disk Access" permission. The app must detect this and guide the user to grant it, and work (with a warning) without it.
- **AI via the already-installed Claude Code** (`claude`, version 2.1.x), in non-interactive mode (`claude -p` with JSON output / streaming), without asking for new API keys. Note: the `claude` on the current PATH is a cmux shim; the app must locate the real executable (usual paths, `~/.claude/local`, global npm, Homebrew) or allow choosing it in Settings. If it is not available, the non-AI sections work all the same and the assistant explains how to enable it.

## 6. Decisions made

| Decision | Who made it |
|---|---|
| Main visualization: block map (treemap) | User (chose option A over rings and bubbles: "it's clearer") |
| Very modern, animated, Apple-style interface, "as attractive as possible" | User |
| Sections in the style of cleanup/uninstall apps | User (concrete list of sections: Claude's proposal, not objected to) |
| The app deletes by itself | User |
| Deletion to the Trash + each tool's official commands | Claude |
| Native in **Swift + SwiftUI** | User, on Claude's proposal ("the best possible", reference: ChatGPT for Mac app) |
| Animations with SwiftUI spring physics instead of GSAP (same feel) | Claude, accepted by the user |
| AI with a report **and** a chat | User |
| AI through the local Claude Code, metadata only | Claude |
| Name **DiskMap** | User ("Disc Map, or something like that"); the spelling "DiskMap" is Claude's choice |
| Custom, very attractive logo | User |
| Location `~/Desktop/Herramientas/DiskMap` | User |
| Interface in Spanish | Claude (the user speaks Spanish) |

### User decisions after the review

- **Phased construction** (user):
  - **Phase 1:** Map + Cleanup + AI Assistant (report and chat), with all the visual and animation polish. Includes the scanner, the persistent index, the catalog of known paths, safe deletion, the icon and the packaging.
  - **Phase 2:** Uninstaller, Large & old, Duplicates, File types.
  - In phase 1 the phase 2 sections may appear in the sidebar as "Coming soon" or not appear (builder's decision).
- **Trash** (user): the app does **not** empty the Trash on its own; it shows "In the Trash: X GB" and an "Empty Trash" button that the user presses.

### Claude's decisions after the builder's review

- **Honest freed space:** what is sent to the Trash is shown as "In the Trash: X GB" and does **not** count as freed until it is emptied. The app offers an "Empty Trash" button (with confirmation) and then animates the freed space. If the space does not go down because of **APFS/Time Machine local snapshots**, the app detects it (`tmutil listlocalsnapshots /`) and explains it, offering to delete them. Official commands (Docker, brew…) do free space immediately.
- **Stable signing:** the packaging script creates (only once) a self-signed certificate in the user's Keychain ("DiskMap Local Signing") and always signs with it, so that the Full Disk Access permission is not lost on every build. If that fails, it falls back to ad-hoc signing and warns.
- **Analysis scope:** the entire boot volume (including `/Library`, `/Applications`, `/private/var` and the current user; other users only if permitted), plus external volumes selectable from the sidebar. Read-only system volumes are excluded, and the "purgeable" and system space that macOS reports is shown separately (`URLResourceKey.volumeAvailableCapacityForImportantUsageKey` versus total).
- **Persistence:** an index of the last analysis is saved (in `~/Library/Application Support/DiskMap`), shown instantly when the app opens while it re-analyzes in the background and updates progressively. The accumulated total freed and the cleanup history are also saved.
- **AI actions:** the chat and the report can **only** propose actions from the app's closed catalog (move a path to the Trash, run a known official command, uninstall an app with its record). Never free-form shell commands written by the AI. If the AI and the catalog disagree on the risk, **the stricter assessment wins**.

## 7. Visual direction

- Window with a translucent sidebar (system materials/vibrancy), dark and light mode, SF Pro typography, SF Symbols icons.
- Treemap with rounded-corner blocks, thin gaps, subtle per-type gradients and a glow on hover; drawn with `Canvas`/Metal for performance.
- Animations: springs (`spring`) for zoom and selection, staggered entrances, transitions with `matchedGeometryEffect` between sections, numbers that count up, a live progress bar/ring during analysis, a restrained celebration when space is freed.
- **Custom icon** in macOS style (squircle), with the treemap block motif in vivid colors and depth; generated as an `.icns` in all sizes.

## 7b. MCP server for external agents (added 2026-10-20, phase 1)

**Why:** the user and many people already work with agents (Claude Code, the Claude app, Codex, opencode and other CLIs). Instead of relying only on the internal chat, DiskMap exposes an **MCP server** so that any of those agents can query the disk and clean up what is safe. The internal chat **stays** (user decision).

**What it is:** a second executable inside the bundle, `DiskMap.app/Contents/MacOS/diskmap-mcp`, which speaks MCP over stdio (JSON-RPC 2.0). It is launched by the agent's client. It works even when the app is closed: it reads the saved index (`~/Library/Application Support/DiskMap`), the catalog, and uses the same `CleanupScanner`/`CleanupExecutor` with all their checks.

**Tools** — names in English by MCP convention, response texts in Spanish:
- `get_disk_summary`: total, free, analyzed, breakdown by type, date of the last analysis, whether Full Disk Access is on.
- `list_largest(path?, limit?)`: largest children of a folder in the index, with type, size, date and risk.
- `explain_path(path)`: what it is (catalog or dictionary of known folders), effective risk and whether it regenerates.
- `list_cleanup_items`: the Cleanup items with id, size, risk, method, blocks and "used by".
- `run_safe_cleanup(item_id)`: runs **only** items with effective risk **Safe to delete**, not blocked (open apps, "used by"), via `CleanupExecutor` (Trash or official command). Any other risk ⇒ explanatory error, nothing is executed.
- `propose_cleanup(item_id | path, reason)`: for "Up to you" items: opens DiskMap (URL `diskmap://propose?...`) with the confirmation sheet already prepared; the user decides. The agent receives "proposal sent; pending user confirmation".
- `show_in_app(path)`: opens DiskMap and zooms the map to that folder (`diskmap://show?path=`).
- `rescan`: asks DiskMap to re-analyze (`diskmap://rescan`); returns when finished or indicates that the app must be open.
- "Don't touch" never has an action tool. There is no tool that accepts arbitrary commands or paths to delete.

**Settings and visibility in the app** — in the Assistant section, **"Connect agent"** tab:
- Server status and executable path.
- Ready-to-copy instructions (copy button) for Claude Code (`claude mcp add diskmap -- <path>`), Codex (`~/.codex/config.toml`), opencode (`opencode.json`) and generic JSON configuration (`mcpServers`), plus a one-click "Add to Claude Code" if `claude` is installed.
- Switch **"Allow agents to run safe cleanups"** (on by default, user decision). If it is off, `run_safe_cleanup` replies that the user has disabled it.
- **Activity log** of the agents: each action call (who/what/how much/result) appears in the app and in the cleanup history, marked "by an agent".
- Settings shared with the server in `~/Library/Application Support/DiskMap/agents.json`.

**Added anti-goals:** the MCP never sends file contents (only metadata, like the AI); it never executes anything other than "Safe to delete" without the user's click in the app; the switch being off blocks every action.

## 8. Left to the builder

- Exact scanning algorithm (e.g. `getattrlistbulk`/`fts` in parallel) and how to count hard links and sparse files.
- Duplicates strategy (size → partial hash → full hash).
- Format of the catalog of known paths and how many initial entries (at minimum those in section 2.2 and those from the session).
- Scheme of the prompts and of the JSON the AI returns.
- Concrete icon design and exact palette, within the visual direction.
- Internal architecture and tests (with automated tests at least for scanning, size calculation, risk classification and the treemap).
