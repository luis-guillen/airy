# Airy — Phase 2 Design (rebranding, Performance, aggressive cleanup, MCP)

Date: 2026-10-20
Status: ready for approval
Part of: `2026-10-20-diskmap-design.md` (the phase 1 design remains in force except where this document changes it).

## 1. What it is and why

DiskMap is renamed **Airy** and stops being just a disk map: it now **takes weight off the Mac** in every sense — disk space, memory, swap, processes that heat up the machine. The brand idea is **lightness and wind**: whatever is surplus gets "carried away by the wind".

The user wants three things, in this order of importance:
1. **The MCP server** (most important): so that Claude Code, Codex, opencode and other agents can query and clean the Mac through Airy.
2. **A clear app**: one that says plainly what can be deleted and what cannot, and where what is safe can be deleted without fear; and where the state of the Mac (memory, swap, temperature) can be understood without knowing how to read Activity Monitor.
3. **Aggressive cleanup** of development caches (Docker, Node, etc.) with their prunes, with multiple selection and "delete all", and a new brand with **lots of** wind animations.

**Success:** the user opens Airy, knows at a glance whether the Mac is doing well or what is slowing it down, closes whatever is heavy, deletes several GB of development caches in one go without fear, and an agent can do the same through MCP. And the app is beautiful and feels "airy".

## 2. Goals

### 2.1 Rebranding: Airy

- **Name:** **Airy** (user's choice among Lightweight, Brisa, Airy and Lighter).
- **Logo:** **wind swirl with leaves** (user's option C over "one leaf" and "three flying leaves"). Squircle with a gradient from turquoise (`#2fd0ff`) to indigo blue (`#2a3bd9`), three concentric wind arcs in translucent white and white/light-blue leaves spinning. The circle evokes a disk and a gauge.
  - Simplified version for small sizes (≤ 64 px: menu bar, lists, Finder): a single thick arc and one leaf (at small sizes thin arcs get lost). *Claude's decision.*
  - In the app, the logo may be animated (swirl turning slowly); the `.icns` is static.
- **Palette:** user's option B, **"blue with cool accents" and strong contrast**:
  - The interface (backgrounds, sidebar, buttons, accents) is blue: night `#07112a`/`#0d2350`, blue `#2f8bff`, sky `#5ab8ff`, text `#f2f7ff`/secondary `#b9cdf0`.
  - The block map uses the **full cool range** (blues, turquoises, violets, indigo) so that each content type stands out.
  - **Strong contrast** (user request): text and indicators with at least WCAG AA contrast (4.5:1 for normal text).
  - Fixed **safety colors** even though the app is blue: green `#1fdc7a` (no problem), amber `#ffb020` (you decide), red `#ff4d5e` (do not delete). They are signals, not decoration. *Claude's decision.*
  - Light and dark mode (the palette above is the dark one; the builder derives the light one with the same contrast).
- **Technical identity change:** visible name, icon, `CFBundleName`, bundle id (`local.airy.Airy`), data folder (`~/Library/Application Support/Airy`, migrating the DiskMap one on first launch), signing identity ("Airy Local Signing"), URL scheme (`airy://`), MCP executable (`airy-mcp`) and `/Applications/Airy.app` (deleting the old `DiskMap.app` after installing). The user will have to **grant Full Disk Access again once** (macOS ties it to the identity); the app detects this and guides, as it already does.

### 2.2 Brand animations (wind)

Claude's proposal accepted by the user ("lots of animations with the brand"):
- **Launch:** leaves spinning in a swirl and forming the logo.
- **Analysis:** a breeze crossing the window; leaves orbiting the progress ring.
- **Deleting an item:** the block or row breaks apart into leaves carried off by the wind; the freed-space counter goes up.
- **"Delete all":** a big gust sweeps the list from left to right.
- **Performance:** the swirl spins faster the higher the CPU load; with the Mac hot, the blue shifts toward orange; when an app is closed, its row flies off like a leaf.
- **Always:** a very soft background breeze; buttons that sway slightly on hover.
- **Limits:** respect macOS "Reduce Motion" (replace with fades); 60–120 fps; **zero CPU at rest** (the background breeze pauses when the window is not visible or active, as the map already does).

### 2.3 User profile ("How do you use your Mac?") — WITHDRAWN

> **User decision (2026-10-20):** the profile question is removed ("it's a bit obvious"). There is no question at launch nor a profile in Settings; what is suggested and preselected depends only on risk and on the mode (Aggressive/Cautious). The text below remains for the record.


- Question at **first launch** (and editable in Settings), multiple selection: **I code**, **Design, photo or video**, **I use local AI**, **I game**, **Music and audio**, **Basic use**.
- The profile changes **what Airy suggests and in what order** (which catalog entries are shown prominently, which are preselected, explanation texts), e.g.:
  - I code → Docker caches, Node/pnpm/yarn/bun, uv/pip/conda, cargo, Xcode (DerivedData, old simulators, device files), old `node_modules`/`.venv`/`target`.
  - Local AI → Ollama, LM Studio, Hugging Face models unused for months.
  - Design/video → render caches and previews (Adobe, Final Cut, DaVinci).
  - Gaming → games and bottles (Steam, Epic, Whisky) not opened for months.
  - Music → unused Logic/GarageBand sound libraries.
  - Basic use → only the most obvious and risk-free (browsers, logs, Trash, old downloads as "you decide").
- **Inviolable rule:** the profile **never** turns anything protected into "no problem" (phase 1 anti-goals and §4). It only reorders, highlights and preselects within the catalog.

### 2.4 Clarity: what can be deleted and what cannot

User request: "make it say clearly which things can be deleted and which cannot, and if it's safe, let it be done without a problem".
- Three high-contrast labels across **the whole** app (Cleanup, Map, Uninstaller, Large & old, Duplicates, Assistant, MCP):
  - 🟢 **No problem** — can be deleted without fear; always says why ("it re-downloads itself", "Xcode rebuilds it").
  - 🟠 **You decide** — says what you lose ("you'd have to download 40 GB again").
  - 🔴 **Do not delete** — says why; **no delete button**.
- List grouped by those three labels, green on top.
- They are the same three risk levels as phase 1 ("Safe to delete / Up to you / Don't touch"), with the new visible texts. *The builder may rename the internal texts or not.*

### 2.5 Aggressive cleanup

User request: "make it aggressive, there are lots of things to delete from the Docker, Node and everything caches, and above all the prunes".
- **Default mode: Aggressive.** A "Cautious" setting is available that returns to phase 1 behavior. *Claude's decision* (the user asked for aggressive; cautious stays as a safety net).
- **New catalog actions (official commands):**
  - Docker (if the daemon is running): `docker builder prune -a -f`, `docker image prune -a -f` (all unused images, not just dangling ones), `docker container prune -f`, `docker network prune -f`. **Never** `--volumes` nor `docker volume prune`.
  - Node: `npm cache clean --force`, `pnpm store prune`, `yarn cache clean`, `bun pm cache rm`.
  - Python/others (already in phase 1, check that all are present): `uv cache clean`, `pip cache purge`, `conda clean --all -y`, `brew cleanup --prune=all -s`, cargo registry/git.
  - Xcode: `xcrun simctl delete unavailable`, DerivedData, old `~/Library/Developer/Xcode/iOS DeviceSupport`, `~/Library/Developer/CoreSimulator/Caches`.
- **Classification in aggressive mode:**
  - Green: tool caches and their build caches, unused Docker images (re-downloaded or rebuilt), unused networks, Node/Python/Rust/Homebrew caches, DerivedData, unavailable simulators.
  - Amber **preselected**: stopped Docker containers (they may hold state in their layer), `node_modules`/`.venv`/`target`/`.next`/`build` of projects untouched for ≥ 3 months (they are in personal folders; they regenerate with `npm install` etc.). *Claude's decision.*
  - Always red: Docker volumes, documents, iCloud, Mail, Messages, Keychain, Photos, Calendars, Contacts, Applications, system, runtimes in use. Same as phase 1.
- **Multiple selection:** checkboxes per row, "Select everything green", "Select all" (only green + amber; red is never selected), and a **"Delete all · X GB"** button. **A single** confirmation sheet with the full list, the total and which items go to the Trash / which are commands. It runs in sequence with per-row progress and a final summary (what worked, what failed and why).
- "Up to X GB" for commands that do not guarantee freeing everything (as in phase 1).


### 2.5b Duplicate development installs (added 2026-10-20, user request)

"Also duplicate installs of development things, dependencies and so on." Airy detects several installed versions of the same tool and proposes removing the surplus ones:
- **Languages and toolchains:** Python (pyenv, conda/miniconda/anaconda, Homebrew `python@3.x`, python.org in /Library/Frameworks — the latter informational only), conda environments, Node (nvm, fnm, volta, asdf, Homebrew `node@x`), Ruby (rbenv, rvm, asdf), Java/JDK (`/Library/Java/JavaVirtualMachines` informational only; SDKMAN, Homebrew `openjdk@x`), Rust (`rustup toolchain list`), Go (several versions in `~/sdk`, Homebrew `go@x`), Xcode (several `Xcode*.app`) and simulators.
- **Duplicate dependencies:** `node_modules` of the same package repeated across projects (information + suggest pnpm), several copies of identical AI models (already covered by Duplicates), duplicate virtualenvs.
- **Which version is in use:** the default version (current PATH, `pyenv global`, `nvm alias default`, `rustup default`, `xcode-select -p`) and any version that a project asks for (`.nvmrc`, `.node-version`, `.python-version`, `.tool-versions`, `rust-toolchain(.toml)`, `.ruby-version`, `pom/gradle` toolchains if easy) within the project roots of §2.5 is marked as **in use** (red, not offered).
- **Risk:** the other versions are **amber**; in Aggressive mode they are preselected only if they have gone ≥ 3 months unused (last-access date of the executable or its folder) and nothing asks for them; never green. Anything under `/Library`, `/Applications` or `/System` is informational only except `Xcode*.app` (which goes through the Uninstaller).
- **How it is removed:** always with the official command (`pyenv uninstall -f`, `conda env remove -n`, `nvm uninstall`, `fnm uninstall`, `volta uninstall`, `rbenv uninstall -f`, `rustup toolchain uninstall`, `brew uninstall` only if `brew uses --installed` does not need it), or to the Trash if the tool has no command. Always through the funnel and with confirmation; the MCP only lists it (never executes it, because it is amber).

### 2.6 Performance (new section)

User request: "you take all the Activity Monitor information and present it in a way the user understands; see whether the Mac is very hot and be able to close things". Optional AI.
- **Overall status** at the top, in one sentence generated by **fixed rules** (no AI): "Your Mac is doing fine", "Your Mac is tight on memory: Chrome and Docker take 60 %", "Your Mac is heating up and has slowed down", etc.
- **Memory:** used / free / file cache, **memory pressure** (green/yellow/red, like Activity Monitor) and **swap** used, with a simple explanation of what swap is and why it grows.
- **Temperature:** macOS thermal state (normal / hot / very hot / critical) and whether the system is **throttling** to cool down. No degrees in this phase: reading them requires private Apple interfaces that may break. *Claude's decision.*
- **CPU and energy:** which apps consume the most processor and energy right now.
- **"What weighs the most":** list of **apps grouped with their processes** (Chrome + its helper processes count as Chrome; stray processes such as `node` or `python` appear with their command/project if it can be determined), sorted by impact (memory, CPU), with a line saying what each one is (catalog, as on disk).
- **Quit:** a **Quit** button per row, with the usual confirmation (ConfirmSheet). First a normal quit (the app may ask to save); **"Force quit"** only if it does not respond. Multiple selection to quit several. *Claude's decision.*
  - **Never** offered for quitting: system processes or those of other users, Finder, Dock, WindowServer, loginwindow, SystemUIServer, Control Center, Airy itself nor its MCP. The user's terminal processes (`node`, `python`, local servers) are, in amber ("you may be using it").
- **No magic "free RAM" button** (Claude's stance, accepted): macOS manages memory by itself and such buttons do not really help; what relieves it is closing what consumes the most, and that is what Airy offers. This change replaces the phase 1 non-goal "it is not a RAM optimizer": it now is one, but only in an honest way.
- **Optional AI:** a "Why is it slow?" button that sends Claude only numbers and app names (never content), with the same closed invocation as the Assistant.
- **Lightness:** measurements are only taken while the section (or the MCP) requests them; refresh every 1–2 s with the section visible and nothing in the background.

### 2.7 Phase 2 sections already designed

They are built as the phase 1 design describes them (§2, points 3–6): **Uninstaller**, **Large & old**, **Duplicates**, **File types**, with the labels of §2.4, multiple selection and the animations of §2.2.

### 2.8 MCP server (most important)

Approved by the user: it is built **as §7b of the phase 1 design describes**, with these changes:
- Executable name `airy-mcp`, scheme `airy://`, settings in `~/Library/Application Support/Airy/agents.json`; MCP server registered as `airy`.
- **"Safe" respects the mode** (Aggressive/Cautious) that the user has in the app: `run_safe_cleanup` only executes what the app marks green under the current mode.
- **New tools:**
  - `run_safe_cleanup_all`: executes all unblocked green items at once (equivalent to "Delete everything green"), with the same switch.
  - `get_performance`: memory, pressure, swap, thermal state, top apps by memory/CPU (read-only).
  - `propose_quit_app(app)`: opens Airy with the quit confirmation prepared; quitting apps is **never** done by the agent without the user's click.
- The "Connect agent" tab keeps its copy instructions for Claude Code, Codex, opencode and generic JSON, the switch and the activity log.

### 2.9 What is learned from Mole (effectiveness and capability)

User request: "make it like Mole in effectiveness and capability". Full, read-only study in `docs/superpowers/research/2026-10-20-mole-inspiracion.md`. Mole is **GPL-3.0**: **ideas and path lists** are adapted, never code (not even translated line by line); it is credited as inspiration in "About". Adopted (numbers = row of the §6 table of the study):

- **Deletion safety (engineering requirements):**
  - **Single deletion funnel** with path validation: absolute, no `..` or control characters, symbolic links and ancestors resolved, critical roots compared by inode and case-insensitively, rejection of bare `~`, and file identity checked again right before deleting (#1).
  - **Three-state process guard** (running / stopped / unknown ⇒ skip) per cleanup family, and live-cache guard (owning process or open SQLite database) (#2).
  - **Hard-protection list extended** with Mole's (§2.15 of the study), always re-applied on top of any user setting (#3).
  - **Time budgets and fail-closed** on every probe; **analysis honesty** (complete / partial / unavailable, sizes with "+" if partial) (#31, #32).
- **User control:**
  - **"Protect this"**: whitelist of user paths/patterns, respected by the app and the MCP (#4).
  - **Preview** without deleting (also `dry_run: true` in the MCP action tools) and **exportable log** (JSON) with run identifier and author (user or agent) (#5).
- **More cleanup targets:**
  - Installers `.dmg/.pkg/.mpkg/.iso/.xip` and `.zip` with an installer in Downloads/Desktop/Documents → amber; Homebrew cache → green (#7).
  - Extended catalog of project artifacts (`Pods`, `.gradle`, `.dart_tool`, `.build`, `.turbo`, `.angular`, `.svelte-kit`, `.astro`, `.tox`, `__pycache__`, `CACHEDIR.TAG`…) with guards: nested repository, `*-keypair.json` keys, Git-tracked files, `bin`/`vendor` only if .NET/Composer (#8). It follows Airy's "≥ 3 months" rule, more cautious than Mole.
  - Full Chromium browsers (all derivatives, `Code Cache`, `GPUCache`, `ShaderCache`, Service Worker CacheStorage, old framework versions inside the `.app`) and a regenerable-cache heuristic in Application Support (#9).
  - Fine-grained Xcode: keep the **2** most recent DeviceSupport versions, XCTestDevices, DocumentationCache, `simctl runtime delete` of orphaned runtimes, only with Xcode and simulators stopped (#12).
  - Long tail of development caches with an official command when one exists (Go, Poetry, Ruff, mypy, Bundler, Composer, Gradle, Swift PM, Flutter, Expo, Electron, node-gyp, Prisma, Corepack, Terraform…) (#13).
  - User app caches (communication, creative, media, games, utilities, office), ordered by profile; **never** Messages or Mail caches (#14).
  - System items needing the administrator password, in amber: `/Library/Logs/DiagnosticReports`, old logs in `/private/var/log` and `/Library/Caches`, old macOS installers (#15).
  - `.ipsw` firmware → green (#33). Old versions of AI agents (Claude Code, Codex, Cursor…), keeping the active one and one previous → green (#30).
  - Safari: compact its database only with Safari closed → amber (#23). Privacy history (`QuarantineEventsV2`) → amber without preselection (#24).
  - **Review only** (no automatic delete button): Xcode Archives, iPhone backups, Android emulators, agent worktrees, failed Time Machine backups (#11, #28).
- **More precise orphans and uninstaller:** rules by bundle id (full app inventory or nothing is decided; 30 days unused; if `mdfind` fails, assume installed; only Caches/Logs/Saved State; never Containers/Group Containers/LaunchAgents; sensitive patterns `ssh/gpg/keychain/1password…` are never orphans) (#10) and an extended list of uninstaller locations, `launchctl bootout` of helpers, `brew uninstall --cask --zap` if it came from Homebrew, `pkgutil` receipts (#29).
- **More complete Performance:**
  - **Rule-based diagnosis** with real causes: `syspolicyd`/WindowServer/Spotlight/CoreSimulator ≥ 25 % sustained; swap > 50 % or free < 15 %; Docker VM > 2 GB with no containers; runaway process; mounted disk images that load `syspolicyd` (#6).
  - **Health score** as a sentence + traffic light (#20).
  - Extra metrics with stable APIs: battery (cycles, health), disk I/O, network, uptime, zombie processes, CPU per P/E cores (#18).
  - Broken **startup items** (LaunchAgents without a binary), report only with a link to System Settings (#17).
  - **Useful maintenance, amber and reversible:** do not create `.DS_Store` on network/USB, remove harmful legacy settings, repair corrupt app `.plist` files, reindex Spotlight only after diagnosing (#21).
- **Rejected:** degrees and fans (private sensors, #19), placebo optimizations —flushing DNS, restarting the network, `periodic`, Launch Services, `purge`, restarting the Dock— (#22), `VACUUM` of Mail/Messages (#23), emptying the Trash by itself (#25), deleting `.DS_Store` (#26), orphaned system services (report only, #27), caches under `/private/var/folders` (#16), Touch ID for sudo (#34).

## 3. Non-goals

- No temperature degrees nor reading of private sensors (for now).
- No "free RAM" with `purge` or similar tricks.
- No quitting system processes or those of other users.
- No App Store distribution; it remains for personal use.
- No accounts, cloud or telemetry.

## 4. Anti-goals (failure even if it "works")

All those of phase 1 remain in force. In addition:
- **Aggressive mode deleting something that does not regenerate.** Aggressive only affects things that are re-downloaded or rebuilt; personal items stay amber at minimum and protected ones red.
- **The profile or the AI lowering a risk.** They can only raise it; the profile only reorders/preselects.
- **An agent quitting apps or deleting anything amber/red** without the user's click in the app.
- **Quitting an app with unsaved work** without warning: always a normal quit first.
- **Animations making the app heavy:** an app called Airy that consumes CPU at rest is a failure.
- **Losing DiskMap data with the rename:** the index, history and total freed are migrated.
- **Looking flat, boring blue or with low contrast:** the user asked for strong contrast.

## 5. Constraints

Those of phase 1 (Swift 6.4, SwiftPM, Command Line Tools only, no Xcode, local self-signed signing, UI in Spanish (Spain), AI via local Claude Code with metadata only and the current closed invocation) and:
- The current branch `fase-1` is not yet merged into `master`; phase 2 starts from it (the builder asks before merging).
- Performance measurements with public APIs (`host_statistics64`, `sysctl` for swap/pressure, `ProcessInfo.thermalState`, `libproc`/`proc_pid_rusage`, `NSRunningApplication`).

## 6. Decisions made

| Decision | Who |
|---|---|
| Complete phase 2 + Performance + rebranding, now | User |
| MCP is the most important; approval of the §7b design | User |
| Performance: explained Activity Monitor information + quitting apps; optional AI | User |
| No "free RAM" button; closing what weighs the most is the real relief | Claude, accepted |
| Temperature without degrees (thermal state) | Claude, accepted |
| Name **Airy** | User |
| **Swirl with leaves** logo (option C, "the one that looks big") | User |
| Simplified logo version for small sizes | Claude |
| **Blue with cool accents** palette, strong contrast | User |
| Green/amber/red safety colors are kept | Claude |
| "How do you use your Mac?" profile with multiple selection, adjusts what is suggested | User (idea); list of profiles by Claude, accepted |
| The profile never lowers a risk | Claude |
| **Aggressive** cleanup with Docker/Node prunes and "Delete all" with selection | User |
| Aggressive by default, "Cautious" as an option | Claude |
| Docker volumes stay red in aggressive | Claude (consistent with phase 1) |
| Old `node_modules` and stopped containers in preselected amber | Claude |
| List of wind animations | Claude, accepted |

### Claude's decisions after the builder's review

- **Settings shared app ↔ MCP:** mode (Aggressive/Cautious), profile and agent switch live in `~/Library/Application Support/Airy/settings.json` (extending `agents.json` or replacing it). The effective risk classification (catalog + mode + profile + blocks) and the performance sampling live in the common library (`DiskMapCore`, renamable), so that the MCP classifies and measures the same as the app **even when the app is closed**.
- **MCP with the app closed:** `get_performance` measures on its own (read-only). `propose_cleanup`, `propose_quit_app`, `show_in_app` and `rescan` open Airy through `airy://…` (LaunchServices starts it if it is closed) and return "pending user confirmation" / "analysis requested".
- **"Delete all" and amber:** in the app, "Delete all" deletes **what is selected**, including preselected amber; the single confirmation sheet shows the amber in a separate, highlighted block ("Review: this does not regenerate by itself / may hold state") and removing it is one click. That confirmation counts as the user's decision. **The MCP never touches amber**: `run_safe_cleanup_all` = only unblocked green.
- **Cautious mode:** phase 1 classification and **no** amber preselection.
- **Docker:** if the daemon does not respond, the Docker actions appear blocked with "Open Docker Desktop to clean this"; Airy does not start Docker. The `docker container prune` confirmation lists the stopped containers by name.
- **"Project untouched ≥ 3 months":** root = folder with `package.json`, `pyproject.toml`/`requirements.txt`, `Cargo.toml` or `.git`; signal = most recent modification date of any file in the project **excluding** the regenerable folders (`node_modules`, `.venv`, `target`, `.next`, `build`, `dist`) and `.git/objects`. Folders synced with iCloud (already protected) are excluded.
- **DiskMap → Airy migration:** on first launch Airy **copies** the data from `Application Support/DiskMap` (index, history, total freed, settings) and leaves the old folder intact. The packaging script creates the "Airy Local Signing" identity, installs `/Applications/Airy.app` and, only if that went well, moves `DiskMap.app` to the Trash. The old DiskMap certificate is not touched.
- **Starting point:** phase 2 is built on a `fase-2` branch created from `fase-1` as it is (245 tests green, clean final review). Merging into `master` is asked of the user separately.
- **Profiles:** the examples in §2.3 are the **minimum** of catalog entries per profile. The profile affects the order, highlighting and preselection of Cleanup and the suggestions of the Assistant and the MCP (`list_cleanup_items` ordered the same way); it does **not** change the Map.

## 7. Left to the builder

- Build order (recommendation: MCP first, as it is the most important; then rebranding, aggressive Cleanup + profile, Performance, and the four sections).
- How to group processes by app (responsible app, parent chain, bundle path).
- Thresholds of the overall-status sentences and of "old project".
- Implementation of the animations (Canvas/TimelineView, leaf particles) within the limits of §2.2.
- Derived light palette and exact contrast values.
- DiskMap → Airy migration details.
- Automated tests (at least: aggressive/cautious classification, a profile that does not lower risks, never-quittable process list, MCP tools and their rejection of anything not green, data migration).
