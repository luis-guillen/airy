# Mole as inspiration for Airy

Date: 2026-10-20
Source: Mole v1.59.1 (tw93/Mole, installed with Homebrew at `/opt/homebrew/Cellar/mole/1.59.1`), read-only reading of its shell scripts and README. No `mo` subcommand was run. The `status` binary (`status-go`) is compiled in Go and has no source code available: what is said about its sensors comes from `strings` on the binary (strong hints, not code read).

**License:** GPL-3.0-or-later (`LICENSE` file and Homebrew formula). The README also asks not to use the same name in forks and to mention Mole as the origin. There is a separate native app, "Mole for Mac", proprietary and paid, of which there is nothing to read. For Airy: **we adapt ideas, path lists (they are facts about macOS, not creative expression) and heuristics, but we do not copy code** (not even shell fragments translated line by line) so as not to contaminate Airy with GPL. Mole should be cited in the documentation as inspiration.

---

## 1. Mole's features and commands

| Command | What it does |
|---|---|
| `mo` | Interactive menu. |
| `mo clean` | Deep cleanup: caches, logs, temporaries, development artifacts and leftovers of already-uninstalled apps. Empties the Trash by default (direct deletion, without Finder). Options: `--dry-run`, `--whitelist`, `--debug`, `--external PATH` (cleans OS metadata from an external volume). |
| `mo uninstall [app…]` | Uninstalls apps with their leftovers. Goes to the Trash by default, `--permanent` to delete right away. `--list`, `--dry-run`. If the app is missing, it refers to `mo clean`. Integrates Homebrew Cask (`brew uninstall --cask [--zap]`). |
| `mo optimize` | Bounded maintenance (DNS, Spotlight, Finder cache, SQLite databases, etc.). Each task is skipped with a reason if it is not needed. Includes a prior **performance diagnosis** (read-only). `--whitelist` per task. |
| `mo analyze` | Terminal disk explorer (Go): overview, navigation, filter, multi-selection, Finder preview, move to the Trash. Marks "Old Downloads (90d+)". `--json` with `scan_status` per entry (`complete`/`partial`/`unavailable`) so as not to lie when the scan is partial. |
| `mo status` | Live health dashboard (Go): CPU, memory, disk, network, power, processes. Health score. `--json`, `--watch --interval 2s` (NDJSON), alerts for processes with sustained CPU, zombie diagnosis (read-only). |
| `mo purge` | Regenerable project artifacts (`node_modules`, `target`…), grouped by project, selection, permanent deletion only of what is confirmed. `--paths` configures roots, `--yes` for non-interactive use. |
| `mo installer` | Looks for installers (`.dmg .pkg .mpkg .iso .xip` and `.zip` that contain an installer) and deletes them after selection. |
| `mo history [--json]` | Log of cleanup operations (`~/Library/Logs/mole/operations.log`), with `run_id` and attribution. Disabled with `MO_NO_OPLOG=1`. |
| `mo touchid` | Configures Touch ID for `sudo`. |
| `mo completion`, `mo update`, `mo remove` | The tool's own utilities (autocompletion, update, uninstall). |
| Raycast/Alfred launchers | Scripts that open each command in the terminal. |

Design principles visible in the code, all usable by Airy:

1. **All deletion goes through a single funnel** (`safe_remove` / `safe_clean`) that validates the path, applies protections and the whitelist, and leaves a log. The cleanup functions only *propose* paths.
2. **Fail closed:** if a probe (size, process, age) runs out of time or errors, the item is kept and the reason is given.
3. **Three-state process protocol** (running / stopped / unknown): cleanup only with "stopped". If unknown, skip. Examples: the pnpm cache is not pruned if a pnpm is alive, nor DerivedData with Xcode open, nor Mail caches if Mail is running.
4. **Double check** (the list and, again, right before deleting), with file identity (inode/parent) to avoid races.
5. **"Review only" category**: large things that Mole *never* deletes by itself, it shows them with the manual command (see §2.14).
6. **Time budgets** (timeouts) on everything, so that a huge folder or a slow disk does not hang the tool.

---

## 2. Catalog of cleanup targets

Conventions: `~` = the user's folder. "Age" = minimum age. "(sudo)" = Mole asks for the administrator password. Almost everything is caches under `~/Library/Caches` and `~/Library/Application Support/<app>`, and the paths are grouped here by family. In parentheses, how Mole decides safety when it has its own rule.

### 2.1 System (requires sudo)

| Path / pattern | Criterion |
|---|---|
| `/Library/Caches/**/*.cache` | files older than 7 days |
| `/Library/Caches/**/*.log` | older than 7 days |
| `/Library/Logs/DiagnosticReports/*` | crash reports older than 7 days |
| `/private/var/log/*.log` | older than 7 days, excludes `*.gz` and `*.asl` |
| `/Library/Logs/Adobe`, `/Library/Logs/CreativeCloud`, `/Library/Logs/adobegc.log` | older than 7 days |
| `/Library/Caches/com.apple.iconservices.store` | regenerable |
| "Install macOS *.app" apps in `/Applications` | older than 14 days, not running, not the system's current version, no pending update; if the version cannot be known, it is kept |
| `/System/Library/Caches/com.apple.coresymbolicationd/data` | the only path under `/System` that its validator lets be deleted (rebuildable cache); Airy must **not** imitate it |
| Rebuildable GPU caches under `/private/var/folders/*/*/C/...` (Metal/Dawn/shader) | older than 1 day; **excludes** any folder of a security agent (see §2.16) |
| `com.apple.idleassetsd` temporaries in `/private/var/folders/*/T/` (aborted downloads `CFNetworkDownload_*.tmp`) | older than 7 days; hundreds of GB of junk have been seen here ("System Data") |
| Browser code-signing clones (`*.code_sign_clone`) | rebuildable; excludes EDR |
| Orphaned system services (LaunchDaemons/PrivilegedHelperTools whose binary no longer exists) | sudo; with a long list of known false positives (Docker, Zoom, Wireshark, Tailscale…) |
| Time Machine local snapshots | **does not delete them**: only counts (`tmutil listlocalsnapshots /`) and shows "review" |
| Failed TM backups `*.inProgress` in `/Volumes/*/Backups.backupdb` | only with TM configured, no backup running (`tmutil status`), and older than 48 h |

It does not touch `/System`, `/usr`, `/bin`, `/sbin`, `/etc`, `/var/db`, `/Library/Apple`, `/Library/Extensions`, `/Library/Keychains` nor `/private/var/db` (see the protected list in §2.15).

### 2.2 User: the essentials

| Path | Notes |
|---|---|
| `~/Library/Caches/*` (generic sweep of all children) | goes through the protection list (§2.15) and through a **live-cache guard**: rejected if there is a process of the owning app or an open SQLite handle on that cache. The Deno root is excluded. |
| `~/Library/Logs/*` | logs older than 7 days |
| `~/.Trash` | direct emptying (the user can protect it with the whitelist). If Full Disk Access is missing, it warns and skips. |
| `~/Library/Saved Application State/*` | saved states |
| `~/Library/Preferences/com.apple.recentitems.plist` | recents list |
| `~/Library/Mail Downloads`, `~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads` | Mail attachments older than 30 days and of at least 5 MB, and only if Mail is not running |
| Incomplete downloads `~/Downloads/*.download`, `*.crdownload`, `*.part` | with a "not active" guard |
| `.DS_Store` in the home (max. 500 per pass) | **protected by default** (it is in the default whitelist) |
| `~/Library/Messages/StickerCache`, `Caches/Previews/{Attachments,StickerCache}` | Messages caches |
| `~/Library/Caches/com.apple.{photoanalysisd,akd,WebKit.Networking,QuickLook.thumbnailcache,iconservices*,helpd,GeoServices,AppleMediaServices,duetexpertd,parsecd,python}`, `Quick Look/*` | user system caches |
| `~/Library/IdentityCaches/*`, `~/Library/Suggestions/*`, `AddressBook/Sources/*/Photos.cache` | identity, Siri and Contacts caches |
| Apple containers: `~/Library/Containers/com.apple.{wallpaper.agent,mediaanalysisd,AppStore,configurator.xpc.InternetService,wallpaper.extension.aerials,geod,stocks,AvatarUI.AvatarPickerMemojiPicker,AMPArtworkAgent,CoreDevice.CoreDeviceService,NeptuneOneExtension,AppleMediaServicesUI.UtilityExtension}/Data/{Library/Caches,tmp}/*` | only `Data/Library/Caches` and `Data/tmp`, never the rest of the container |
| `~/Library/Group Containers/*` caches | skips `com.apple.*`, `group.com.apple.*` and Safari extension containers |
| Apple Silicon caches: `~/Library/Caches/com.apple.rosetta.update`, `com.apple.amp.mediasevicesd` | minor |
| Clipboard/Handoff cache | rebuildable |

### 2.3 Browsers

Family Safari, Chrome, Chromium, Edge, Brave, Arc, Dia, Vivaldi, Opera, Yandex, QQ Browser, Helium, Comet, Orion (Kagi), Zen and Firefox.

- HTTP cache: `~/Library/Caches/{com.apple.Safari, Google/Chrome, Chromium, com.microsoft.edgemac, BraveSoftware/Brave-Browser, company.thebrowser.Browser (Arc), company.thebrowser.dia, com.vivaldi.Vivaldi, com.operasoftware.Opera, Yandex/YandexBrowser, net.imput.helium, Comet, com.kagi.kagimacOS, zen, Firefox}/*` and `~/.cache/puppeteer`.
- Inside `~/Library/Application Support/<Browser>/<Profile>/` and `User Data/<Profile>/`: `Cache`, `Code Cache`, `GPUCache`, `DawnCache`, `DawnGraphiteCache`, `DawnWebGPUCache`, `GrShaderCache`, `GraphiteDawnCache`, `ShaderCache`, `Application Cache`, `component_crx_cache`, `extensions_crx_cache`, `Crashpad/completed`. GoogleUpdater: `crx_cache` and `*.old`.
- Service Worker CacheStorage: its own logic to clean it with a per-domain budget.
- **Old Chrome/Edge/Brave versions inside the `.app`**: `…/Contents/Frameworks/<Framework>/Versions/*` except the one `Current` points to. Only with the browser closed and with a valid `Current` symlink.
- It **never** touches the profile: cookies, history, `Local Storage`, `IndexedDB`, extensions, passwords.
- Guard: it is only cleaned if the browser is not running (probe per family).

### 2.4 User app caches (more than 190 rules, closed list per app)

Pattern: `~/Library/Caches/<bundle id>/*`, `~/Library/Containers/<bundle>/Data/Library/Caches/*`, `~/Library/Application Support/<App>/{Cache,Code Cache,GPUCache,Dawn*,logs}` and logs.

- **Editors/IDEs:** VS Code (`Code/{logs,Cache,CachedData,CachedExtensionVSIXs,WebStorage/*/CacheStorage}`), Cursor, Sublime, Zed (cache, node/cache, logs), CodeBuddy, obsolete editor extensions, JetBrains (logs; old Toolbox versions), Qoder, Antigravity, Filo.
- **Communication:** Slack, Discord, Legcord, Zoom, Teams (new and legacy), WhatsApp, Telegram, WeChat, QQ, Skype, DingTalk, Feishu, Tencent Meeting.
- **AI:** ChatGPT, Claude (cache, `Application Support/Claude/{Cache,Code Cache,GPUCache,Dawn*,sentry}`, logs), LM Studio (app cache, not models), Codex Desktop (exact Chromium caches; the profile and sessions are protected), Claude Code/Cursor Agent/Copilot CLI **old versions** (the active one and 1 previous are kept).
- **Creative:** Adobe (`Caches/Adobe`, `com.adobe.*`, `Media Cache Files`; the pattern `Adobe *` is protected in the path list), Figma, Sketch, Final Cut (cache; proxies only if the user checks it), DaVinci Resolve (`~/Movies/CacheClip`), Premiere, Blender, Cinema 4D, SketchUp, ScreenFlow.
- **Media:** Spotify, Apple Music/Podcasts/TV (includes Podcasts temporaries), Plex, IINA, VLC, mpv, Bilibili, iQIYI and similar, Stremio.
- **Downloads/torrents:** Transmission, qBittorrent, Aria2, Downie, Folx.
- **Games:** Steam (`htmlcache`, `appcache`, `depotcache`, `steamapps/shadercache`, logs), Epic, Battle.net, EA, GOG, Riot, Minecraft (logs, crash-reports, webcache), Lunar Client, PCSX2, RPCS3.
- **Utilities:** Notion, Obsidian, Logseq, Bear, Evernote, Alfred, The Unarchiver, TeamViewer, AnyDesk, CleanShot, Warp, Ghostty, WakaTime, mihomo-party, Todoist, Spark, Airmail.
- **Office:** Word/Excel/PowerPoint/Outlook (cache + container + logs), iWork, WPS, Thunderbird, **Apple Mail `com.apple.mail/*`** (Mole's whitelist offers it as optional).
- **Virtualization:** VMware Fusion, Parallels, VirtualBox `.cache`, UTM (app cache, sandbox cache and temporaries), Lima (downloads), Vagrant (`.vagrant.d/tmp`), Tart.
- **Generic Application Support heuristic:** an app folder is considered to have a regenerable cache if it contains `Code Cache`, `GPUCache`, `DawnCache`, `GrShaderCache`, `GraphiteDawnCache`, `DawnGraphiteCache`, `DawnWebGPUCache` or `Crashpad`; then those subfolders (and `Cache`/`CachedData`) are cleaned, except protected apps (§2.15) and except folders with too many items.
- Others: `~/.zcompdump*`, `~/.lesshst`, `~/.viminfo.tmp`, `~/.wget-hsts`, `~/.oh-my-zsh/cache`, `~/.cache/{curl,wget,pre-commit}`, curl and wget caches in `~/Library/Caches`.

### 2.5 Development tools (package and compiler caches)

With their official command when one exists (marked **cmd**):

| Tool | What it cleans |
|---|---|
| npm | `~/.npm/_cacache/*` and residuals (`_logs`, etc.) using the path from `npm config get cache`; `~/.tnpm` |
| pnpm | **cmd** `pnpm store prune` for each usable pnpm binary, with a validated store path; skips if a pnpm is running; `~/Library/pnpm/store` is only reviewed |
| yarn | `~/.yarn/cache/*`, `~/Library/Caches/Yarn/*` |
| bun | **cmd** `bun pm cache rm` and orphans in `~/.bun/install/cache` |
| Corepack | `$COREPACK_HOME/*` |
| uv | **cmd** `uv cache prune` (`uv cache dir` for the path). Note: Airy uses `uv cache clean`, which is more aggressive; Mole uses `prune` |
| pip | **cmd** `pip3 cache purge` |
| conda | **cmd** `conda clean --yes --index-cache --tarballs --logfiles` (does not touch `pkgs` in use: `~/.conda/pkgs` is only reviewed) |
| Poetry, pyenv, Jupyter, Ruff, mypy, pytest | `~/.cache/poetry`, `Library/Caches/pypoetry/{artifacts,cache}` (**`pypoetry/virtualenvs` always protected**), `~/.pyenv/cache`, `~/.jupyter/runtime`, `~/.cache/{ruff,mypy}`, `~/.pytest_cache`, PyInstaller `bincache` |
| Go | paths given by `go env GOCACHE` and `GOMODCACHE` (never wide paths such as `~` or `~/go`) |
| Rust | `$CARGO_HOME/registry/cache` (only the download cache), `~/.rustup/downloads`; it does **not** touch `registry/src`, `registry/index`, `git`, `bin` nor `toolchains` (reason: rust-analyzer and offline builds use them). Skips if cargo/rustc is running |
| Ruby | rbenv cache, `~/.gem/specs`, `~/.gem/ruby/*/cache/*.gem`, `~/.bundle/cache` |
| PHP | Composer (`~/.composer/cache`, `~/Library/Caches/composer`) |
| Other languages | Perl CPAN build, Hex (Elixir), Opam, Bazel `~/.cache/bazel`, Zig, mise, Nix, Terraform, Gradle (protected by default), Maven `~/.m2/repository` (review only), Deno (review only), NuGet (review only), CocoaPods |
| Frontend | `~/.cache/{typescript,electron,node-gyp,webpack,vite,eslint,prettier,prisma}`, `~/.node-gyp`, `~/.turbo/cache`, `~/.vite/cache`, `~/.parcel-cache`, Expo (`~/.expo/*`, except `state.json` with tokens) |
| Cloud/CI | `~/.kube/cache`, `~/.aws/cli/cache`, `~/.config/gcloud/logs`, `~/.azure/logs`, GitHub CLI (`~/.cache/gh`), `~/.cache/gitlab-runner`, `~/.circleci/cache`, `~/.sonar` |
| DB and API clients | Sequel Ace/Pro, DBeaver, Navicat, Redis Insight, Postman, Insomnia, TablePlus, Paw, Charles, Proxyman (caches only) |
| Android/Swift | `~/.android/{build-cache,cache}`, `Caches/Google/AndroidStudio*`, `~/.cache/swift-package-manager`, `Library/Caches/org.swift.swiftpm` |
| Homebrew | **cmd** `brew cleanup --prune=30` (before running, a preview with `--dry-run`); `~/Library/Caches/Homebrew/downloads/*`; does not sweep `api/` nor `bootsnap/` nor the locks directory; only every 7 days; **only shows** `brew autoremove` |
| "Orphaned" automation browsers | temporary Puppeteer/Playwright profiles older than 2 h and with no live process |
| Project caches | `__pycache__`, `.pytest_cache`, etc. inside projects with markers, with the Git index (see §5.2) |

### 2.6 Xcode and simulators

| Path / command | Criterion |
|---|---|
| `~/Library/Developer/Xcode/DerivedData/*` and `Products/*` | only with Xcode and build tooling stopped (process probe) |
| `~/Library/Caches/com.apple.dt.Xcode/*` | same |
| `~/Library/Developer/Xcode/{iOS,watchOS,tvOS} DeviceSupport/*` | **keeps the 2 most recent** by date (configurable); also cleans `*/Symbols/System/Library/Caches/*` and `*.log` |
| `~/Library/Developer/XCTestDevices/*` | each clone separately; Xcode recreates them |
| **cmd** `xcrun simctl delete unavailable` | with a `DEVELOPER_DIR` that has `simctl`; retries once because of the cold start of CoreSimulatorService |
| `~/Library/Developer/CoreSimulator/Caches/*`, `Devices/*/data/tmp/*`, `~/Library/Logs/CoreSimulator/*` | only with no booted simulators (`simctl list devices booted -j`) |
| `~/Library/Developer/CoreSimulator/Profiles/Runtimes/*/…/System/Library/Caches/*` | runtime cache |
| `/Library/Developer/CoreSimulator/Caches` (sudo), `/Library/Developer/Xcode/DocumentationCache` | system caches |
| `~/Library/Developer/Xcode/UserData/IB Support/*` | Interface Builder cache |
| Orphaned simulator runtimes (without devices) | **only reports**: `xcrun simctl runtime delete <id>` |
| `Xcode/Archives`, `CoreSimulator/Devices` | **review only** (§2.14) |

### 2.7 Docker, OrbStack and containers

**Mole does not run any `docker … prune`.** It only warns "Docker unused data · review with `docker system df`" and deletes `~/.docker/buildx/cache/*`, `~/.local/share/containers/storage/tmp/*`, `~/.vagrant.d/tmp`. It shows "review" for `~/Library/Containers/com.docker.docker/Data`, OrbStack (`~/.orbstack`, `Group Containers/*dev.orbstack/data`, `~/OrbStack`; **protected** as a path: they contain live file systems) and `~/.lima`. Airy is more aggressive and capable here (official prunes); that is an advantage of Airy, not a shortcoming.

### 2.8 Homebrew and managers

Already covered in §2.5. In addition: download leftovers in `~/Library/Caches/Homebrew`; Caskroom as part of the inventory of installed apps.

### 2.9 Leftovers of already-uninstalled apps (orphans)

See §5.1 for the logic. Folders it reviews: `~/Library/Caches`, `~/Library/Logs`, `~/Library/Saved Application State`, plus "stub" containers (only those of MacPaw/CleanMyMac) and system services (sudo).

### 2.10 Installers and firmware

- `mo installer`: `.dmg .pkg .mpkg .iso .xip` and `.zip` that look like an installer when listed with `zipinfo -1`, in `~/Downloads`, `~/Desktop`, `~/Documents`, `~/Public`, `~/Library/Downloads`, `~/Library/Caches/Homebrew`, iCloud Drive `…/com~apple~CloudDocs/Downloads`, Mail Downloads, Telegram Desktop. Verifies file identity at the moment of deleting. Discards the whole list if the scan fails or expires.
- Device firmware: `~/Library/iTunes/*Software Updates/*.ipsw`, `~/Library/Group Containers/*.group.com.apple.configurator/**/*.ipsw`.
- macOS updates: `/Library/Updates` and `/macOS Install Data` are left to Software Update; `~/Library/Updates` is only reviewed.

### 2.11 Logs

`~/Library/Logs/*` (older than 7 days; Codex's and Mole's own are protected), app logs (Claude, Zed, JetBrains, Warp, DingTalk, Steam, Minecraft…), system logs (§2.1), crash reports (`~/Library/Logs/DiagnosticReports`, Codex's `Crashpad/completed` and `pending` older than a certain age, `SentryCrash`, `KSCrash`, `Crashlytics`).

### 2.12 App state and other maintenance that deletes

`~/Library/Saved Application State/*.savedState` older than 30 days, corrupt `~/Library/Application Support/com.apple.sharedfilelist/*.sfl2|sfl3` (`plutil -lint` fails), corrupt `.plist` preferences (not `com.apple.*`).

### 2.13 Finder / Quick Look caches

`com.apple.QuickLook.thumbnailcache`, `com.apple.iconservices.store`, `com.apple.iconservices` + `qlmanage -r cache` and `qlmanage -r`.

### 2.14 Review-only items (it never deletes them by itself)

It shows them with their size and the manual command. For Airy this is the basis of its "you decide / review" category without an automatic button:

Mail (`~/Library/Mail`), macOS installers, update cache, Docker/OrbStack/Lima data, Xcode DerivedData and Archives, simulator data, iOS backups (`~/Library/Application Support/MobileSync/Backup`), LM Studio models, Hugging Face (`~/.cache/huggingface` and whatever path `HF_HOME` asks for), Maven, Ivy, NuGet, Deno, pnpm store, `~/.conda/pkgs`, Gradle, Android emulators and system-images, `mise` installs, Flutter SDK (FVM), old JetBrains data, Apple Intelligence compiled-model caches (`com.apple.e5rt.e5bundlecache`: **protected**, expensive to regenerate), agent worktrees (`~/.codex/worktrees`, `~/.claude/worktrees`), Time Machine local snapshots, broken login items/LaunchAgents, build artifacts (with the `mo purge` command).

### 2.15 Protection list (the most valuable thing to copy *as an idea*)

Mole has three independent layers. I copy the list exactly as it is defined, because it is the highest-value part for Airy's safety engine.

**Layer A: path validation before deleting (`validate_path_for_deletion`)**

- It must be absolute, without `..` as a component, without control characters.
- If the path is a symbolic link, the target is validated. If **any ancestor** is a link, the physical path is resolved and the critical and protected checks are passed again.
- Critical roots, never deletable (nor their case aliases in APFS, nor by inode): `/`, `/bin`, `/dev`, `/sbin`, `/usr`, `/System`, `/Library` (and `/Library/Apple`, `/Library/Application Support` root, `/Library/Extensions`, `/Library/Keychains`), `/Applications` (root), `/Applications/Finder.app`, `/Applications/Safari.app`, `/Volumes`, `/opt`, `/opt/homebrew` (root; the children can be), `/Users`, `/Users/Shared`, `/Users/Guest`, `/private`, `/private/tmp`, `/etc`, `/var`, `/var/db`, `/var/audit`, `/var/root`, `/private/var`, `/private/var/tmp`, `/private/var/folders` (root), `/private/var/db`, `/private/var/audit`, `/private/var/root`, `/Network`, `/cores`, `/home`, `/net`, `/tmp`. It also rejects `/Users/<name>` (the root of a home) to avoid an `rm -rf` caused by an empty variable.
- It rejects the active energy telemetry database (`powerlog`), even if it weighs tens of GB.

**Layer B: path protection (`should_protect_path`), only in cleanup mode**

- Always protected: `~/.prometheus/data`, Git configuration backups and shell history backups (`.gitconfig.bak*`, `.zsh_history.bak*`…), the shared roots `~/.cache`, `~/.config`, `~/.local` (and `~/.local/{bin,lib,share,state}`), but not their app-specific children.
- Any path with `SystemSettings`, `SystemPreferences`, `ControlCenter`, `com.apple.Settings*`, `com.apple.Notes`; system UI caches (`com.apple.systempreferences.cache`, `controlcenter.cache`, `finder.cache`, `dock.cache`: deleting them leaves blank panels); Settings and Control Center containers; `dock.plist` and `finder.plist`; Bluetooth and Wi-Fi preferences (`ByHost/com.apple.bluetooth.*`, `wifi.*`); `com.apple.networkextension*.plist` (VPN state).
- iCloud Drive: `~/Library/Mobile Documents*`.
- Personal account data: `~/Library/Accounts`, `~/Library/Keychains`, `~/Library/Mail`, `~/Library/Calendars`, `~/Library/Contacts`.
- Audio plugins and licenses: `/Library/Audio/Plug-Ins/{Components,VST,VST3}`, `iZotope`, `LaserSoft Imaging`, Native Instruments preferences, Avid Media Composer, FabFilter, PACE (iLok).
- Caches with account or license state despite the name: `ms-playwright`, Cotypist, DisplayLink, SilverFast, `Adobe *`, `com.apple.containermanagerd`, `homed`, `ap.adprivacyd`, `FamilyCircle`, `HomeKit`, Shortcuts sandbox caches (`ShortcutsSandboxCache`), `GIPPseudonymousID`, `CCTClearcutLogger` (deleting them with Gemini open causes a write loop).
- User wallpapers and screensavers: `Application Support/com.apple.idleassetsd`, `com.apple.wallpaper`.
- System audio: anything with `coreaudio`, `com.apple.audio.`, `coreaudiod` (deleting causes sound loss on Intel Macs).
- OrbStack (`~/.orbstack`, `Group Containers/*dev.orbstack`), Codex state (sessions, `auth.json`, history, indexes).
- Caches of **security agents/EDR/MDM** under `/private/var/folders`: prefixes `com.crowdstrike.`, `com.sentinelone.`, `com.sentinel-labs.`, `com.eset.`, `com.jamf.`, `com.jamfsoftware.`, `com.paloaltonetworks.`, `com.cisco.anyconnect`, `com.cisco.secureclient`. Deleting anything there triggers tamper detection (MITRE T1562.001) and looks like malware to a corporation.
- Compiled-model caches (`com.apple.e5rt.e5bundlecache`): skipped.
- App containers (`~/Library/Containers/<id>`, `Group Containers/<id>`): if the id belongs to a protected app, everything is protected except `Data/Library/Caches/*` and `Data/tmp/*`, which are considered regenerable by definition.

**Layer C: apps with sensitive data (`DATA_PROTECTED_BUNDLES` list), protected in cleanup (they can be uninstalled on request)**

Password managers (1Password, Bitwarden, LastPass, Dashlane, KeePass, Authy, Yubico), IDEs and editors (JetBrains, VS Code, Sublime, Xcode, Nova, Typora), AI tools (Cursor, Claude, ChatGPT, Codex, Ollama, LM Studio, Jan, Perplexity, DrawThings, Windsurf, Gemini), database clients, API and network tools (Postman, Insomnia, Charles, Proxyman, Paw), **VPNs and proxies** (Clash/ClashX/Verge, Surge, Tailscale, ZeroTier, WireGuard, OpenVPN, Cloudflare WARP, Nord/Express/Proton/Mullvad…), Git (GitHub Desktop, Tower, Fork, GitKraken, Sublime Merge), terminals (iTerm2, kitty, Alacritty, WezTerm, Warp), Docker and virtualization (Docker, OrbStack, UTM, VMware, Parallels, VirtualBox, Vagrant), monitoring, window managers and launchers (Alfred, Raycast, Karabiner, Rectangle, Bartender), notes (Obsidian, Notion, Bear, Logseq, Evernote, Day One, GoodNotes), design and creative (Adobe, Figma, Sketch, Affinity, Pixelmator, Cinema 4D, Autodesk, Native Instruments, iZotope, FabFilter), communication (Slack, Discord, Zoom, Teams, Telegram, WhatsApp, WeChat…), storage and backup (Dropbox, OneDrive, Google Drive, Box, Backblaze, iCloud `bird`/`CloudDocs`), remote access (TeamViewer, AnyDesk, Chrome Remote Desktop), input methods (IME).

In addition, a list of **sensitive data patterns that are never treated as orphans**: `*1password*`, `*keychain*`, `*bitwarden*`, `*lastpass*`, `*keepass*`, `*dashlane*`, `*enpass*`, `*ssh*`, `*gpg*`, `*gnupg*`, `com.apple.keychain*`.

**User whitelist (`~/.config/mole/whitelist`)**

- It is managed with `mo clean --whitelist` (a menu with the offered caches) and one path/pattern per line is saved. What the user saves *replaces* the optional defaults, but the **hard safety protections are always merged back in** (so that an old list does not lose new protections).
- Optional defaults (protected until the user unchecks them): `~/Library/Caches/ms-playwright*`, `~/.gradle/{caches,daemon}/*`, `~/.ollama/models/*`, Surge caches and data, `~/Library/Caches/org.R-project.R/R/renv/*`, `~/Library/Caches/JetBrains*`, `com.jetbrains.toolbox*`, `tealdeer/tldr-pages`, `~/Library/Application Support/JetBrains*`, `~/Library/Caches/com.apple.finder`, `~/Library/Mobile Documents*`, and the internal "Finder metadata / .DS_Store" flag.
- Hard protections that are always merged: FINDER_METADATA, `com.apple.FontRegistry*`, `com.apple.spotlight*`/`Spotlight*` (breaking them breaks search and font rendering), `CloudKit*` (breaks iCloud sync), `pypoetry/virtualenvs*` (live interpreters), `renv` (symbolic links from R projects).
- For `optimize` there is a separate whitelist (`whitelist_optimize`, by task name or path pattern).

### 2.16 Retention and thresholds (Mole constants)

Logs 7 days; crash reports 7; temporaries 7; orphans 30; orphaned "dotdir" (hint) 60; saved states 30; Mail attachments 30 days and 5 MB; GPU 1 day; safe TM backup 48 h; macOS installers 14 days; Brew every 7 days; DeviceSupport folders: keep 2; AI agent versions: keep the active one plus 1; max. 500 `.DS_Store` per pass; max. 15 parallel jobs; SQLite database over 100 MB is not compacted; notifications database is compacted if it exceeds 50 MB; `knowledgeC.db` if it exceeds 100 MB.

---

## 3. `optimize` tasks

All are "safe for automatic execution" according to Mole's catalog (there is a validation that prevents registering an unsafe task). After each one it reports one of six results: applied, unchanged, skipped, unavailable, needs attention, failed. Mole **does not use global `sudo`**: it asks for it once at the start and each task checks whether it has it; without it, it skips with a reason. It is not run as root.

Usefulness legend: **Useful** (solves a real problem or frees something measurable), **Situational** (only helps if there is a specific failure), **Placebo** (on current macOS it improves nothing measurable or is noise).

| Task | What exactly it runs | sudo | Assessment |
|---|---|---|---|
| `system_maintenance` (DNS and Spotlight) | `dscacheutil -flushcache` + `killall -HUP mDNSResponder`; queries `mdutil -s /` | yes | **Situational.** Flushing DNS only helps with resolution problems; doing it routinely is placebo. |
| `cache_refresh` (Finder) | `qlmanage -r cache`, `qlmanage -r`; deletes `com.apple.QuickLook.thumbnailcache`, `com.apple.iconservices.store`, `com.apple.iconservices` | no | **Situational.** Fixes corrupt thumbnails or icons; frees little; does not speed anything up. |
| `saved_state_cleanup` | deletes `*.savedState` older than 30 days in `~/Library/Saved Application State` | no | **Minor useful.** Some space and obsolete states; minimal risk. |
| `fix_broken_configs` | looks for corrupt `.plist` files in user preferences (not `com.apple.*`) and removes them | no | **Situational.** Solves apps that do not launch because of a damaged preference; it should be done in amber. |
| `network_optimization` | `dscacheutil -flushcache` + SIGHUP to mDNSResponder (skipped with an active VPN) | yes | **Placebo** as a routine (duplicates `system_maintenance`). |
| `sqlite_vacuum` | `VACUUM` after `PRAGMA integrity_check` on `Mail/V*/MailData/Envelope Index*`, `Messages/chat.db`, `Safari/History.db`, `Safari/TopSites.db`. Skips if Mail, Safari or Messages are running, if the database exceeds 100 MB or if the free list is small | no | **Useful with reservations.** Compacting Mail indexes can speed up search; for Airy it is **red** (Mail/Messages). Only Safari would be conceivable. |
| `prevent_network_dsstore` | `defaults write com.apple.desktopservices DSDontWriteNetworkStores -bool true` and `DSDontWriteUSBStores` | no | **Useful.** It is persistent, reversible (`defaults delete`) and avoids junk on network and USB drives. |
| `legacy_overrides_audit` | reads global `NSAppSleepDisabled` and `com.apple.frameworks.diskimages skip-verify*`; if they are set to 1 it deletes them with `defaults delete` | no | **Useful.** Removes old "tweaks" that degrade macOS (App Nap disabled, disk image verification skipped). |
| `network_stack_optimize` | `route -n flush` and `arp -a -d` (with a prior check of connectivity and of full-tunnel VPN) | yes | **Placebo / risky.** It can cut explicit VPN routes. Reject. |
| `disk_permissions_repair` | `diskutil resetUserPermissions / <uid>` (if it detects a problem) | yes | **Situational.** Only if there are permission errors in the home. |
| `spotlight_index_optimize` | measures `mdfind "kMDItemFSName == 'Applications'"` twice; if both take more than 3 s and power is connected, `mdutil -E /` (reindexes, 1-2 h of heavy use) | yes | **Situational, useful.** With search that is really broken. The prior measurement is a good idea; blind reindexing would be harmful. |
| `spotlight_orphan_rules_cleanup` | edits `EnabledPreferenceRules` in `com.apple.spotlight` removing entries of uninstalled apps | no | **Minor useful / cosmetic.** |
| `periodic_maintenance` | `sudo periodic daily weekly monthly` if stale | yes | **Placebo.** macOS does it by itself; the command disappears in macOS 26+. |
| `shared_file_list_repair` | deletes corrupt `*.sfl2/*.sfl3` (`plutil -lint`), except `ApplicationRecentDocuments` | no | **Situational.** Fixes broken Finder favorites/Recents. |
| `disk_verify` | `diskutil verifyVolume /` (disabled by default: `MOLE_ENABLE_DISK_VERIFY=1`) | no (repairing, yes) | **Useful diagnostic**, but heavy; better to read the S.M.A.R.T. status. |
| `login_items_audit` | reviews startup items without a binary (`launchctl print`, `PlistBuddy`; avoids `sfltool dumpbtm` because it raises a system notice) | no | **Useful (only reports).** |
| `quarantine_cleanup` | `sqlite3 …/com.apple.LaunchServices.QuarantineEventsV2 "DELETE FROM LSQuarantineEvent; VACUUM;"` | no | **Useful for privacy**, not for performance. Low-risk change. Amber. |
| `launch_agents_cleanup` | lists `~/Library/LaunchAgents/*.plist` whose absolute `Program` does not exist (ignores unmounted drives and names without a path) | no | **Useful (only reports).** Does not delete. |
| `notification_cleanup` | `DELETE FROM record WHERE delivered_date < now-30d; VACUUM;` on the Notification Center DB if it weighs more than 50 MB; then `killall NotificationCenter` | no | **Useful when the DB is huge.** Rare. |
| `coreduet_cleanup` | `DELETE FROM ZOBJECT WHERE ZCREATIONDATE < now-90d; VACUUM;` on `~/Library/Application Support/Knowledge/knowledgeC.db` if it exceeds 100 MB | no | **Useful with reservations.** It touches usage history (privacy). Amber. |

Tasks that Mole **withdrew** and that are worth learning from: `dock_refresh`, `memory_pressure_relief` (the `purge`), `launch_services_rebuild` (it broke running VPN extensions) and `radio_refresh` (it cut Wi-Fi/Bluetooth). This supports Airy's stance of not offering a "free RAM" button.

### 3.1 Performance diagnosis (read-only)

This is the best part of `optimize` and fits Airy's Performance section. It samples `ps -Aceo pcpu=,command=` twice, 1 s apart, and looks at these **families** with a threshold of 25 % sustained CPU in both samples:

- `syspolicyd` (Gatekeeper/code signing; if it rises, check `spctl --status` and look for mounted disk images with `hdiutil info`, offering to eject those that are not the system's);
- `WindowServer` (compositing; a symptom more than a cause);
- Spotlight (`mds`, `mdworker`, `mds_stores`, `mdbulkimport`);
- simulator disks (`diskimagesiod`, `simdiskimaged`);
- enterprise security agents (CloudShell, AliEntSafe…; **it never closes them**, it only names them).

Plus two checks outside that list:

- **Memory pressure:** `sysctl vm.swapusage` (swap used / total) and free percentage. It warns if swap exceeds **50 %** or free memory drops below **15 %**, and names the biggest consumers.
- **Idle VM holding memory:** a virtual machine (typically Docker Desktop) with more than **2 GB** and no containers running; it recommends quitting Docker Desktop.
- **Runaway process:** one that has been alive at least **12 h** and has used **≥ 25 %** sustained CPU over its whole life. It suggests `kill -TERM <pid>` but does not run it.

---

## 4. `status` metrics

`mo status` is a Go binary (`gopsutil` v4) with the help of system utilities. JSON and NDJSON output (`--watch`). The following combines what the README documents with the strings of the binary.

| Metric | What it shows | How it measures it (hint) |
|---|---|---|
| CPU | total and per-core usage, 1/5/15 min load, performance and efficiency cores (`P+E`) | `host_processor_info`/gopsutil; `hw.perflevel0.logicalcpu`, `hw.perflevel1.logicalcpu`; `vm.loadavg` |
| Memory | used, free, available, total, **pressure** | `vm_stat` (active, wired, compressed; page size from the header), `hw.memsize`, `memory_pressure`, `sysctl vm.swapusage` |
| Disk | usage, free, read/write MB/s | `statfs`/`df -k`, IOKit (`IOBlockStorageDriver`) for counters; `diskutil info` to know whether it is internal |
| Network | download/upload per interface with a chart; detects tunnels (VPN) and avoids counting the tunnel's and its carrier's traffic twice; HTTP/HTTPS/SOCKS/PAC proxy | `netstat -ib`, routing table, `scutil --proxy` |
| Power | level, state (charging/discharging), cycles, **battery health** (maximum capacity), amperage | IOKit `AppleSmartBattery` (properties such as `AppleRawMaxCapacity`, `InstantAmperage`, `CycleCount`) and `system_profiler SPPowerDataType` |
| **Temperature** | CPU and thermal state, alert "CPU temperature high" / "Overheating" | **Private IOKit HID sensors** (`IOHIDEventSystemClientCreate`, `…SetMatching`, `…CopyServices`, `IOHIDEventGetFloatValue`), i.e. a private Apple API. It also uses `powermetrics` (needs sudo) for GPU power |
| Fans | number and RPM | IOKit keys `FanCount`, `FanSpeed` |
| GPU | usage (active/idle residency) | `ioreg`/`powermetrics`; there are `nvidia-smi` paths inherited from other platforms |
| Bluetooth | devices and battery | `system_profiler SPBluetoothDataType` |
| Processes | top by CPU and memory, process alerts with CPU above the threshold during a window (`--proc-cpu-threshold`, `--proc-cpu-window`), **zombies** with the responsible parent process | `ps -Ao pid,ppid,state,pcpu,pmem,rss,comm` |
| System | model, chip, RAM, macOS version, uptime, number of processes | `kern.boottime`, `kern.osrelease`, IOPlatformUUID, `sw_vers` |
| **Health score (0-100)** | combines CPU, memory, disk capacity, S.M.A.R.T., I/O, thermals, battery and uptime, with color ranges | own calculation |

Mole's README also says that the commercial app "Mole for Mac" offers fan control on compatible Macs: it is not in the CLI and there is no code.

For Airy: it already decided **not to show degrees** because of the dependence on a private API. Mole shows it is feasible (IOHID sensors), but with the known fragility. Battery, I/O counters, network, GPU and uptime are reachable with stable interfaces and are not in the specification (see §6).

---

## 5. Logic for leftovers, uninstallation and project purging

### 5.1 Detection of orphaned leftovers (already-uninstalled apps)

1. **Inventory of installed apps** (cached 5 min): looks for `*.app` down to depth 3 in `/Applications`, `/System/Applications`, `~/Applications`, `/opt/homebrew/Caskroom`, `/usr/local/Caskroom`, `~/Library/Application Support/Setapp/Applications`, plus apps that a `.pkg` installed outside standard paths (`pkgutil --pkgs`/`--files`, `/var/db/receipts`; result cached from one hour to a week depending on the receipts fingerprint) and iOS apps on Apple Silicon (`Wrapper/*.app`). Reads `CFBundleIdentifier` with `PlistBuddy`. **If the inventory is incomplete or an Info.plist cannot be read, nothing is decided** ("an incomplete inventory cannot authorize orphans").
2. **Candidates:** only `~/Library/Caches`, `~/Library/Logs`, `~/Library/Saved Application State` with names `com.*`, `org.*`, `net.*`, `io.*` (id in reverse-DNS format).
3. **Decision tree** to consider an id an orphan:
   1. if it is in the protected data list, no;
   2. if it matches the sensitive patterns (passwords, ssh, gpg…), no;
   3. if it is in the inventory, no;
   4. if it is a system component (`loginwindow`, `dock`, `finder`, `safari`, Settings…), no;
   5. **if the folder was modified less than 30 days ago, no**;
   6. as a last resort, `mdfind "kMDItemCFBundleIdentifier == '<id>'"` (with timeout; if it fails or expires, **it is assumed installed**, and it is not stored in the result cache);
   7. if everything passes, it is an orphan.
4. It **never** considers orphans (explicit rules, "CRITICAL: NEVER"): `LaunchAgents`, `LaunchDaemons`, `Containers/`, `Application Scripts/`, `Group Containers/` (ids with a team prefix give false positives). It only handles the MacPaw/CleanMyMac container "stubs".
5. **Orphaned system services** (sudo): plists in `/Library/LaunchAgents` and `/Library/LaunchDaemons` whose binary does not exist and whose owner is not installed, with a protection list of known apps (Docker, Zoom, Wireshark ChmodBPF, Tailscale, Intego, Homebrew `homebrew.mxcl.*`…). And the equivalent `PrivilegedHelperTools`.
6. It checks the candidate's identity (inode, parent) right before deleting.

### 5.2 Uninstaller (`find_app_files`)

Locations it associates with an app, by **name** (with variants: as is, without spaces, underscore, hyphen, lowercase) and by **bundle id** (and by the ids of embedded bundles/helpers):

- User: `Application Support`, `Caches`, `Logs`, `Preferences` (`.plist` and `ByHost/<id>.*`), `Saved Application State/<id>.savedState`, `Containers/<id>`, `Group Containers` (match with team prefix), `WebKit/<id>` and `WebKit/com.apple.WebKit.WebContent/<id>`, `HTTPStorages/<id>` (+ `.binarycookies`), `Cookies/<id>.binarycookies`, `Application Scripts/<id>`, `Autosave Information/<id>`, `SyncedPreferences/<id>.plist`, `~/.config/<app>`, `~/.cache/<app>`, `~/.local/share/<app>`.
- App extensions: `Services/*.workflow`, `QuickLook/*.qlgenerator`, `Internet Plug-Ins`, `Audio/Plug-Ins/{Components,VST,VST3,Digidesign}`, `PreferencePanes`, `Input Methods`, `Screen Savers`, `Frameworks`, `Contextual Menu Items`, `Spotlight/*.mdimporter`, `ColorPickers`, `Workflows`, `Address Book Plug-Ins`, `Accessibility`, `Mail/Bundles`.
- Launchers: `~/Library/LaunchAgents/*.plist` owned by the app (by id or by a program that points inside the `.app`); they are unloaded with `launchctl bootout gui/<uid>/<id>`.
- System (sudo): `/Library/{Application Support,Caches,Logs,Preferences}` with the name or id, `/Library/LaunchAgents|LaunchDaemons/<id>.plist` (with `sudo launchctl`), `/Library/PrivilegedHelperTools`, receipts in `/private/var/db/receipts`.
- If the app is installed with Homebrew Cask, it runs `brew uninstall --cask` (or `--zap`).
- Safety: it does not touch leftovers of protected system apps (`SYSTEM_CRITICAL_BUNDLES` list: instead of `com.apple.*`, it enumerates the system components so that Xcode, Final Cut, Logic, GarageBand, iWork, etc. can be uninstalled); it **refuses** security/MDM/EDR apps that require their official uninstaller (ESET, Jamf, CrowdStrike, SentinelOne, GlobalProtect, Cisco Secure Client); it closes the app if it is open (`osascript` / `pgrep -qx`) beforehand; it shares data if another installed copy uses it ("shared app paths"); it leaves things in the Trash by default.
- Steam: separate treatment for games.

### 5.3 Project artifact purging (`mo purge`)

**What it looks for (31 names):** `node_modules`, `target`, `build`, `dist`, `venv`, `.venv`, `.pytest_cache`, `.mypy_cache`, `.tox`, `.nox`, `.ruff_cache`, `.gradle`, `.terragrunt-cache`, `__pycache__`, `.next`, `.nuxt`, `.output`, `vendor`, `bin`, `obj`, `.turbo`, `.parcel-cache`, `.dart_tool`, `.zig-cache`, `zig-out`, `.angular`, `.svelte-kit`, `.astro`, `coverage`, `DerivedData`, `Pods`, `.cxx`, `.expo`, `.build`. It also recognizes any folder marked with a `CACHEDIR.TAG` file with the standard signature (`Signature: 8a477f597d28d172789f06886806bc55`).

**Where:** default roots `~/www`, `~/dev`, `~/Projects`, `~/GitHub`, `~/Code`, `~/Workspace`, `~/Repos`, `~/Development`, `~/Library/CloudStorage`, `~/.codex/worktrees`, `~/.claude/worktrees` (or those the user configures in `~/.config/mole/purge_paths`, which *replace* the defaults). Depth: 1 to 6 levels under each root. It uses `fd` if available and `find` if not; it prunes `.git`, `Library`, `.Trash`, `Applications`. A directory is a "project" if it contains any of: `package.json`, `Cargo.toml`, `go.mod`, `pyproject.toml`, `requirements.txt`, `pom.xml`, `build.gradle`, `terragrunt.hcl`, `Gemfile`, `composer.json`, `pubspec.yaml`, `Package.swift`, `Makefile`, `build.zig`, `.git`. It recognizes monorepos (`lerna.json`, `pnpm-workspace.yaml`, `nx.json`, `rush.json`, `.git`).

**Age threshold:** `MIN_AGE_DAYS = 7`, but it is **not "untouched project"**: it is activity *inside the artifact itself*. If any file was modified in the last 7 days inside the artifact, or it cannot be checked (timeout, error), it is left **unselected by default** (state `recent`/`uncertain`); the user can check it. There is no threshold in months. Airy's criterion (entire project untouched for ≥ 3 months, excluding regenerable folders) is **more cautious and more accurate** than Mole's.

**Protections per artifact** (because the name does not prove it is regenerable):
- It is protected if it contains a nested Git repository or a `*-keypair.json` file (Anchor/Solana deployment keys in `target/deploy`).
- It is protected if it contains **files tracked by Git** (`build/` or `coverage/` with source code in the repo).
- `bin` only if the parent has `*.csproj|*.fsproj|*.vbproj` and `bin/` contains `Debug/` or `Release/`.
- `vendor` only if it is Composer's (PHP); other `vendor` folders (Go, etc.) stay protected.
- It must be physically contained (no symbolic links) inside a configured root and at depth ≥ 1 (or be the root itself if the root is a single project).
- It is revalidated right before deleting. Artifacts inside worktrees are deleted, never the worktree.
- Deletion is **permanent** (it does not go to the Trash); in non-interactive mode it requires `--yes`.
- In `mo clean`, a light version warns about artifacts with a hint ("Build artifacts · 12.3 GB · run mo purge") excluding `bin` and `vendor` for noise.

---

## 6. Gap table: what Mole covers and Airy's specification does not

Recommendation: **Adopt** (green or safe according to the catalog), **Adopt in amber** (offered, never preselected in Cautious, and with an explanation of what is lost), **Reject** (with reason). It respects Airy's rules: never Docker volumes, personal documents, iCloud, Mail, Messages, Keychains, Photos, `/System`; the AI and the profile only raise risk; everything goes through confirmation.

Sorted by expected value (the first 10 are the priorities).

| # | Gap (what Mole does) | Recommendation | Reason in one line |
|---|---|---|---|
| 1 | **Single deletion funnel with path validation** (absolute, no `..`, no control characters, symbolic links and ancestors resolved, critical roots by inode and case-insensitive, rejection of `/Users/<me>`, file identity checked again when deleting) | **Adopt** | It is the defense against the worst possible failure (deleting too much); Airy specifies it at policy level, not engine level. |
| 2 | **Three-state process guard** (running/stopped/unknown) per cleanup family, plus a live-cache guard (owning process + open SQLite handle) | **Adopt** | It avoids cleaning out from under Xcode/pnpm/browsers and corruption; "unknown" = skip. |
| 3 | **Extended protection list** (§2.15: system UI, network/VPN, caches with licenses, audio plugins, EDR, Apple Intelligence compiled models, CloudKit/Spotlight/FontRegistry, `pypoetry/virtualenvs`, `renv`, `.orbstack`, Codex) and its rule "hard protections are always merged back in" | **Adopt** | Years of real incidents condensed; Airy's catalog only enumerates what is cleaned. |
| 4 | **User whitelist** ("Protect this") by path/pattern, applied by the app and by the MCP | **Adopt** | Completely missing in Airy and gives control without asking permission for each cleanup. |
| 5 | **"Preview" mode** (`--dry-run`) and exportable **operations log** with attribution (`run_id`, app or agent) | **Adopt** | Airy has confirmation and history, but no preview for the MCP (`dry_run: true`) nor JSON export. |
| 6 | **Rule-based performance diagnosis** (families `syspolicyd`/`WindowServer`/Spotlight/CoreSimulator with ≥25 % sustained in 2 samples; swap >50 % or free <15 %; Docker VM >2 GB without containers; runaway process ≥25 % for ≥12 h; mounted disk images that load `syspolicyd`) | **Adopt** | It fits the Performance section and the "overall status" sentences; they are read-only and explain real causes. |
| 7 | **Installers** (`.dmg .pkg .mpkg .iso .xip` and `.zip` with an installer) in Downloads/Desktop/Documents/Homebrew cache/Telegram | **Adopt in amber** (green for the Homebrew cache and for clear duplicates) | It is the domestic "big winner"; the user may want to keep an installer, so amber with a list and age. |
| 8 | **Extended project artifact catalog** (+ `CACHEDIR.TAG`, `Pods`, `.gradle`, `.dart_tool`, `.build`, `.turbo`, `.angular`, `.svelte-kit`, `.astro`, `.tox`, `__pycache__`…) and **guards**: nested repository, `*-keypair.json` keys, Git-tracked files, `bin`/`vendor` only if .NET/Composer | **Adopt in amber** | Airy lists 5 folders; guards are missing that avoid deleting `build/` with code or `target/deploy` with keys. |
| 9 | **Complete cleanup of Chromium browsers** (all derivatives, `Code Cache`, `GPUCache`, `Dawn*`, `ShaderCache`, `component_crx_cache`, `Crashpad/completed`, Service Worker CacheStorage, old framework versions inside the `.app`) and a generic Application Support heuristic with regenerable-cache markers | **Adopt** | A lot of space without touching the profile; Airy mentions Brave/Chrome/Safari but not the fine list nor the old versions. |
| 10 | **Orphan rules by bundle id** (full inventory or nothing, 30 days idle, `mdfind` failing = installed, only Caches/Logs/Saved State, never Containers/Group Containers/LaunchAgents/Application Scripts, sensitive patterns `ssh/gpg/keychain/1password…`) | **Adopt** | It defines precisely when a leftover is an orphan and avoids the false positive that deletes data of a live app. |
| 11 | **"Review only" category** (Xcode Archives, iOS backups, Android emulators, LM Studio/HF models, Maven/NuGet/Gradle, old JetBrains, Docker/OrbStack, Time Machine snapshots, agent worktrees) without an automatic delete button | **Adopt** (red/amber without action, or amber with strong confirmation) | It matches Airy's three labels: they are shown, explained, the user decides. |
| 12 | **Finer Xcode**: keep the N=2 most recent DeviceSupport versions (iOS/watchOS/tvOS), XCTestDevices, DocumentationCache, Products, IB Support, `simctl runtime delete` of orphaned runtimes, only with Xcode and simulators stopped | **Adopt** | Airy says "old iOS DeviceSupport" without defining which; Mole defines the retention rule. |
| 13 | **Long catalog of development caches** (Go via `go env`, Poetry/pyenv/Ruff/mypy, Ruby/Bundler, Composer, Hex, Opam, Bazel, Terraform, kube, AWS/gcloud/Azure, Electron/node-gyp/webpack/vite/prisma, Expo, Android, Swift PM, Flutter, Corepack) with the **official cmd** if it exists | **Adopt** (green); exceptions in amber: `ms-playwright`, Gradle, JetBrains, `.ollama/models`, `renv`, tldr, `pypoetry/virtualenvs` (red) | It takes advantage of the "I code" profile; the catalog should be data (JSON/Plist), not code. |
| 14 | **User app caches** (communication, creative, media, games, utilities, office, VM) | **Adopt**, ordered by profile | Airy's profile already reorders this; the entries are needed. Only `Caches` and `Data/Library/Caches`/`Data/tmp`; **reject** Messages caches (`Messages/*Cache*`) and `com.apple.mail/*` and `Mail Downloads`. |
| 15 | **System with administrator password**: `/Library/Logs/DiagnosticReports`, old logs in `/private/var/log` and `/Library/Caches` (7 days), macOS installers ("Install macOS *.app" older than 14 days and not current), aborted `idleassetsd` temporaries (hundreds of GB in "System Data") | **Adopt in amber** (installers and `idleassetsd`); **adopt in green** the user's own crash reports `~/Library/Logs/DiagnosticReports` | It recovers the opaque "System Data"; everything requires the system password and confirmation, nothing preselected. |
| 16 | **GPU caches and signing clones under `/private/var/folders`** | **Reject** | Protected critical path, gain of MB and risk of triggering EDR detection; Mole limits it with many reservations. |
| 17 | **Startup items audit** (LaunchAgents with a nonexistent binary, broken login items) | **Adopt in amber, report only** | Useful Performance section ("slow startup"); do not delete, link to System Settings. |
| 18 | **Missing status metrics**: battery (cycles, health, amperage), disk I/O (MB/s), network per interface with tunnel detection, GPU, uptime, zombies with parent, CPU per core (P/E), proxy | **Adopt** (except GPU and private sensors) | All with stable interfaces (IOKit battery, system counters, `getifaddrs`); Airy only has memory, swap, thermal state and CPU. |
| 19 | **Temperature in degrees and fans** (private IOHID sensors, `powermetrics`) | **Reject for now** (review in a later phase as "experimental" and hidden by default) | Consistent with Airy's decision: private API that can break with every macOS; the official thermal state is enough. |
| 20 | **Global health score** (CPU, memory, disk, S.M.A.R.T., I/O, thermal, battery, uptime) | **Adopt** (as a sentence and traffic light, not just a number) | It summarizes the state at a glance and feeds the fixed-rule "overall status" that Airy already wants. |
| 21 | **Useful `optimize`**: `defaults write DSDontWriteNetworkStores/DSDontWriteUSBStores`, delete legacy tweaks (`NSAppSleepDisabled`, `skip-verify*`), Spotlight diagnosis with prior measurement before reindexing (`mdutil -E /`, 1-2 h), repair corrupt `.plist`/`.sfl*`, compact the notifications DB | **Adopt in amber** (with honest description and reversibility) | Real and reversible; Spotlight reindexing only with search measured as slow and with power connected. |
| 22 | **Placebo `optimize`**: flushing DNS, restarting the network (`route -n flush`, `arp -d`), `periodic daily weekly monthly`, "rebuilding" Launch Services, memory `purge`, restarting the Dock | **Reject** | No measurable benefit or with side effects (VPN cuts). Mole itself withdrew several. |
| 23 | **Compacting SQLite databases of Mail, Messages and Safari** (`VACUUM`) | **Reject** Mail and Messages (red in Airy); Safari **adopt in amber** only with Safari closed | Mail/Messages are a forbidden zone; the benefit is small compared with the corruption risk. |
| 24 | **Privacy history cleanup** (`QuarantineEventsV2`, `knowledgeC.db` >90 days) | **Adopt in amber** (optional, without preselection) | A privacy topic more than a space one; it deletes history, not caches. |
| 25 | **Emptying the Trash automatically** | **Reject** | Airy already decided that the user does it with a button. |
| 26 | **Deleting `.DS_Store`** | **Reject** | Mole itself leaves it protected by default; zero gain. |
| 27 | **Orphaned system services** (LaunchDaemons/helpers without a binary) and **container stubs** | **Reject deletion**, **adopt report only** | Huge list of known false positives, requires sudo and can break boots. |
| 28 | **Failed Time Machine `.inProgress` backups** (>48 h) | **Reject** (show as "review only") | Airy does not touch backups; local snapshots it does offer with `tmutil`, Mole only counts them. |
| 29 | **Uninstaller: extra locations and complete process** (WebKit, HTTPStorages, binary Cookies, Application Scripts, Autosave Information, SyncedPreferences, audio plugins/Services/Quick Look, ByHost, `pkgutil` receipts, `launchctl bootout` of helpers, `brew uninstall --cask [--zap]`, closing the open app, system leftovers with password, **refusal for security/MDM apps**) | **Adopt** (`/Library` leftovers in amber with password; audio plugins in amber) | Airy lists 8 locations; Mole shows that about 15 are missing and that there are apps that must not be uninstalled by hand. |
| 30 | **Retiring old versions of AI agents** (Claude Code, Cursor Agent, Copilot CLI, Codex runtimes; keeps the active one and 1 previous) | **Adopt** (green, non-active versions only) | Relevant to the "I code/AI" profile; clear retention rule. |
| 31 | **Scan honesty** (`scan_status`: complete/partial/unavailable; size with `+` if partial) | **Adopt** | It reinforces the anti-goal "lying with numbers". |
| 32 | **Time budgets and fail-closed** on every probe | **Adopt** (as an engineering requirement) | A large or slow disk must not hang the app nor delete with doubtful data. |
| 33 | **Device firmware** (`.ipsw` in `~/Library/iTunes/*Software Updates`, Apple Configurator) | **Adopt** (green) | Easy to recover (re-downloaded) and usually takes several GB. |
| 34 | **Touch ID for sudo** (`mo touchid`), autocompletion, self-update, Raycast/Alfred launchers | **Reject** (except `airy://` + a shortcut if wanted) | Airy uses the system password dialog; it is not a product feature. |

### The 10 biggest gaps, in one line

1. Single deletion funnel with path validation and identity check when deleting (#1).
2. Three-state process guard before cleaning each family (#2).
3. A much broader hard-protection list, always re-merged (#3).
4. User whitelist ("protect this") shared with the MCP (#4).
5. Preview and exportable operations log, also for agents (#5).
6. Rule-based performance diagnosis with real causes (#6).
7. `.dmg/.pkg/.iso/.xip/.zip` installers as an amber target (#7).
8. Extended project artifact catalog with Git, key and nested-repo guards (#8).
9. Fine cleanup of Chromium browsers and a regenerable-cache heuristic in Application Support (#9).
10. Precise orphan rules by bundle id (#10).

---

## 7. Things Airy already does better than Mole (worth keeping)

- **Docker:** official prunes of builder, images, containers and networks. Mole only warns. Keep the veto on volumes.
- **Single confirmation with a full list**, multiple selection and "Delete all": Mole mixes direct deletion and TUI selection.
- **Trash by default** for files: Mole empties the Trash and permanently purges `node_modules` and the like. Airy is recoverable.
- **"Project untouched ≥ 3 months" criterion** versus the 7 days of activity inside the artifact.
- **Usage profile** that reorders without lowering risks: Mole is the same for everyone.
- **AI models (Ollama, HF, whisper)**: Mole protects them or only reviews them; Airy treats them as part of the catalog with reference checking.
- **Time Machine local snapshots**: Mole only counts them.
- **MCP** for agents: Mole only has a CLI and `--json`.
- **No optimization placebos**: the decision not to have "free RAM" is backed by Mole's own history.
