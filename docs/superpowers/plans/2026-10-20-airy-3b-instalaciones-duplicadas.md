# Airy 3b — Duplicate Development Installs · Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cleanup detects several installed versions of the same development tool (Python, Node, Ruby, Java, Rust, Go, conda environments) and proposes removing the surplus ones. Those in use appear in red. The rest appear in amber and never in green. They are removed with the official command of their manager as an argument array, or to the Trash if the manager has no command. Informational rows are also added for duplicate Xcode, system installs and repeated `node_modules`.

**Architecture:** everything lives in `DiskMapCore`, on top of the plan 3 core (branch `fase-2-limpieza`):
- **Inventory and usage.** A read-only file-system inventory (`ToolchainInventory`) and a usage detector (`ToolchainUsage`: default version, PATH, project pins) are computed **once per detection** in a memo of `DiscoveryContext`. The memo has a time budget.
- **Target source.** `ToolchainSource` is the source of `CleanupTargets.source(for:)` for the `discovery {"type":"toolchains","manager":…}` records. There is one record per manager, because each manager has its own cleanup method. The same rule serves in `discover` and in `revalidate`.
- **Projects.** Project pins are read from the project roots of the shared walk of `ProjectArtifactSource`, which is extended to memoize the project list as well.
- **Interface.** No new view. The rows appear on the plan 3 board (`CleanupBoard`, «Solo revisar» (Review only) for `info`).

**Tech Stack:** Swift 6.4 (Command Line Tools only), SwiftPM, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-10-20-airy-fase-2-design.md` §2.5b (and §2.4 labels, §2.5 project roots, §2.9 budgets and fail-closed). Anti-goals: `docs/superpowers/specs/2026-10-20-diskmap-design.md` §4. Base code: plan 3 (`docs/superpowers/plans/2026-10-20-airy-3-limpieza-agresiva-perfil.md`, already implemented in `fase-2-limpieza`): `CleanupTargetSource`, `DiscoveryContext`, `DiscoveredTarget` (`floor`, `floorReason`, `blockedReason`, `preselectable`, `targets`), `{target}` (targets that are paths go through `PathGate` without their record and are revalidated with `confirmUnchanged` when acting), `CommandPolicy.refusal`, `CleanupExecutor.commandWorkingDirectory == "/"`, `ProjectArtifactSource`/`ProjectWalkMemo`, `RiskClassifier` with Aggressive/Cautious mode.

**User decision:** no usage profile. Preselection depends **only** on risk and mode. The new records carry `profiles: []`.

**Out of this plan:** uninstalling Xcode (Uninstaller, plan 5); simulator runtimes (already in plan 3, `SimulatorRuntimeSource`); identical copies of AI models (Duplicates, plan 5); duplicate virtualenvs (R5).

## Global Constraints

- Swift 6.4, SwiftPM, Command Line Tools only; `swift build` / `swift test`; `.macOS(.v15)`; the test target keeps the Swift Testing plugin's `unsafeFlags`.
- Interface in **Spanish (Spain)**; tool names and MCP fields in English.
- File contents are **never** sent to the AI or the MCP. Only metadata is sent (paths, sizes, dates, names and versions). Reading `.nvmrc`, `package.json` (`name`/`version`) or `settings.toml` is local and does not leave Airy.
- Protected locations, never deletable: Docker volumes, iCloud, Mail, Messages, Keychains, AddressBook, Calendars, Photos, `/Applications`, `/Library`, `/usr`, `/bin`, `/sbin`, `/private`, `/opt/homebrew`, `/System`. Personal folders are never green. **Runtimes in use are never touched.**
- Every destructive action goes through `ConfirmSheet` → `AppModel` → `CleanupExecutor` (funnel). No DEBUG shortcuts that act without confirmation.
- The AI only raises risk. No profile (user decision).
- The MCP only executes unblocked green, never amber or red. With the switch off, every action is blocked. These rows are always amber or red: the MCP **only lists them** (`list_cleanup_items`).
- Official commands **always as an argument array** (never `sh -c` nor a shell string), executed with the funnel's `workingDirectory "/"`. `nvm`, `sdk` and `rvm` are shell functions and are **never** invoked.
- Read-only probes, with a time budget and fail-closed: whatever could not be checked is not preselected; when acting, it is blocked.
- In tests and verification, real cleanup commands are never run and the real Trash is never emptied. `FakeRunner`, `FakeListing`, temporary folders and a dedicated `AIRY_SUPPORT_DIR` are used. Against the real system, read-only and `dry_run: true` only.
- Zero CPU at rest: inventory, `brew uses` and project walk only during a detection or right before acting. Nothing in the background.
- DEBUG screenshots of own windows only. Stop the app by killing only its PID (never `pkill -x`). Do not touch Keychain trust.
- Mole is GPL-3.0: ideas only, never code.
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **The user changes the default version (or creates a `.nvmrc`) between detection and «Borrar todo» (Delete all).** The version now in use is rejected when acting with the new reason and nothing is executed. Test in Task 3 (`defaultChangedAfterDetectionIsRefused`).
2. **A pin that cannot be resolved** (`lts/*`, `node`, `system`, `stable` without a toolchain on that channel) or a broken `alias default`. Nothing of that language is preselected, and if the default does not resolve, the highest version of that manager counts as the default (red). Test in Task 2 (`unresolvablePinsAreConservative`).
3. **`brew uses --installed` is slow, fails or lists dependents.** The formula appears red («Lo necesita Homebrew para: …» (Homebrew needs it for: …)) or blocked, never preselectable. Moreover, `brew uninstall` never carries `--ignore-dependencies`. Test in Task 3 (`brewDependentsTimeoutAndVeto`).
4. **A malicious or odd target** (version with `/`, `..`, starting with `-`, conda environment `base`, symbolic link in `versions/`). It is not offered, and if it reaches the funnel it is rejected before executing. Test in Task 3 (`hostileTargetsNeverRun`).
5. **Many projects or a slow disk.** The project walk is done **only once** per detection for artifacts, pins and dependencies. If the deadline runs out, nothing is preselected and when acting it is blocked («No se pudo comprobar a tiempo si algún proyecto pide esta versión» (Could not check in time whether any project asks for this version)). Test in Task 2 (`oneProjectWalkPerPassAndBudgetFailsClosed`).

## Rulings of this plan (the author's decisions)

- **R1 — Trash where there is no official per-version command.**
  - `nvm`: shell function → Trash of `~/.nvm/versions/node/<v>`.
  - `volta`: `volta uninstall` only removes packages, not runtimes → Trash of `~/.volta/tools/image/node/<v>`.
  - `asdf`: its command needs two arguments (`plugin` and `version`) and `{target}` is one → Trash of `~/.asdf/installs/<plugin>/<v>`, with the detail «Luego ejecuta asdf reshim» (Then run asdf reshim).
  - `rvm`, SDKMAN and `~/sdk/go*` → Trash.
- **R2 — conda with `-p`, not with `-n`.** The command is `conda env remove -p {target} -y`. With several bases (miniconda + anaconda) the name is ambiguous, and an absolute path goes through `PathGate` and `confirmUnchanged`. The base is never offered. Bases are only searched under `~`.
- **R3 — What "duplicate" is.**
  - Installs are counted per **language**, adding up all managers and the informational-only installs (`/Library/Frameworks/Python.framework`, `/Library/Java/JavaVirtualMachines`). Apple stubs in `/usr/bin` do not count.
  - A language with fewer than 2 installs offers nothing.
  - conda environments are extra by definition: they are always offered, except `base`.
- **R4 — Pins.**
  - They are searched at the root of each project in the shared walk and in its direct children (monorepos), no deeper.
  - Matching by numeric components after stripping `v`, `ruby-` and `python-`: `3.11` asks for `3.11.x`; `18` asks for `18.*`.
  - `environment.yml` (`name:` or `prefix:`) asks for a conda environment. `go.mod` and `pom`/`gradle` are not read.
  - When acting, the walk is repeated with its deadline. If it does not finish, it is blocked.
- **R5 — Out.** Custom roots (`PYENV_ROOT`, `NVM_DIR`, `FNM_DIR`… the app does not see the shell environment): only the default paths are looked at. Duplicate virtualenvs: there is no cheap and reliable way to compare them, and old `.venv` are already covered by plan 3.
- **R6 — Homebrew.**
  - Only formulas `python@3.N`, `node`, `node@N`, `openjdk`, `openjdk@N`, `go`, `go@1.N` from `/opt/homebrew/Cellar` and `/usr/local/Cellar`.
  - `brew uses --installed <f>` only for candidates that are not already red: at most 8 per detection, 15 s each.
  - `CommandPolicy` always vetoes `brew … --ignore-dependencies`.
  - Cellar paths are never `item.paths` (they are protected). The size goes in `bytes`.

---

## File Structure

- Create `Sources/DiskMapCore/Cleanup/Toolchains/ToolchainInventory.swift`: model, injectable roots, read-only inventory and last-use date.
- Create `Sources/DiskMapCore/Cleanup/Toolchains/ToolchainUsage.swift`: default version per manager, PATH, pins (`VersionPin`) and reading of pins in projects.
- Create `Sources/DiskMapCore/Cleanup/Toolchains/ToolchainSource.swift`: verdicts, per-detection memo, `discover` and `revalidate`.
- Create `Sources/DiskMapCore/Cleanup/Toolchains/DependencyDuplicateSource.swift`: informational row for repeated `node_modules`.
- Modify:
  - `Sources/DiskMapCore/Catalog/Catalog.swift`: `DiscoveryKind` (`.toolchains(manager:)`, `.toolchainSystemInfo`, `.dependencyDuplicates`) and `ToolchainManager`.
  - `Sources/DiskMapCore/Cleanup/CleanupTargets.swift`: `source(for:)` and the new memo in `DiscoveryContext`.
  - `Sources/DiskMapCore/Cleanup/ProjectArtifactSource.swift`: memoized and shared project list.
  - `Sources/DiskMapCore/Safety/CommandPolicy.swift`: `brew` and `conda` vetoes.
  - `Sources/DiskMapCore/Safety/TimeBudget.swift`: `toolchains`.
  - `Sources/DiskMapCore/System/CommandRunner.swift`: `fallbackPatterns`.
  - `Sources/DiskMapCore/Resources/catalog.json`: 14 new records at the end.
- Tests: `Tests/DiskMapCoreTests/ToolchainInventoryTests.swift`, `ToolchainUsageTests.swift`, `ToolchainSourceTests.swift`, `DependencyDuplicateTests.swift`, and new lines in `CatalogSchemaTests.swift`.

---

### Task 1: Schema, records and read-only inventory

**Files:**
- Modify:
  - `Sources/DiskMapCore/Catalog/Catalog.swift` (`DiscoveryKind`)
  - `Sources/DiskMapCore/Cleanup/CleanupTargets.swift` (`source(for:)`; the new cases go to `PendingDiscoverySource` until tasks 3 and 4)
  - `Sources/DiskMapCore/Resources/catalog.json`
  - `Sources/DiskMapCore/System/CommandRunner.swift` (`fallbackPatterns` += `"~/.pyenv/bin"`, `"~/.rbenv/bin"`, `"~/miniforge3/bin"`, `"~/.volta/bin"`)
- Create: `Sources/DiskMapCore/Cleanup/Toolchains/ToolchainInventory.swift`
- Test: `Tests/DiskMapCoreTests/ToolchainInventoryTests.swift`, `Tests/DiskMapCoreTests/CatalogSchemaTests.swift`

**Interfaces:**
- Consumes: `CleanupScanner.expand`, `CleanupTargets.realPath`, `ProjectArtifactRules.isRealDirectory`.
- Produces:
```swift
public enum ToolchainManager: String, Codable, Sendable, CaseIterable {
    case pyenv, conda, nvm, fnm, volta, asdf, rbenv, rvm, sdkman, rustup, goSDK, homebrew, system
}
// DiscoveryKind: case toolchains(manager: ToolchainManager)  // JSON {"type":"toolchains","manager":"pyenv"}
//                case toolchainSystemInfo                     // {"type":"toolchainSystemInfo"}
//                case dependencyDuplicates                    // {"type":"dependencyDuplicates"}
public enum ToolchainLanguage: String, Sendable { case python, node, ruby, java, rust, go, condaEnv, other }

public struct InstalledToolchain: Sendable, Equatable {
    public var manager: ToolchainManager
    public var language: ToolchainLanguage
    public var name: String          // "3.11.4", "v20.11.0", "stable-aarch64-apple-darwin", "python@3.11", "java/17.0.9-tem", environment name
    public var path: String          // installation folder (Cellar/<f> in Homebrew)
    public var target: String        // value of {target} (name or path depending on the manager; see the table)
    public var lastUsed: Date?       // max(atime of the main executable, mtime of the folder); nil if it could not be read
    public var informational: Bool   // /Library/…, /Applications/Xcode*.app
}

public struct ToolchainRoots: Sendable {
    public var home: String
    public var cellars: [String]             // ["/opt/homebrew/Cellar", "/usr/local/Cellar"]
    public var applications: String          // "/Applications"
    public var libraryJava: String           // "/Library/Java/JavaVirtualMachines"
    public var libraryPython: String         // "/Library/Frameworks/Python.framework/Versions"
    public var xcodeSelectLink: String       // "/var/db/xcode_select_link"
    public static func standard(home: String) -> ToolchainRoots
}

public enum ToolchainInventory {
    /// Only `lstat`/`readdir`/`readlink`: never launches processes. Entries that are symbolic links are not
    /// offered (pyenv-virtualenv, SDKMAN's `current`, rvm's `default`).
    public static func scan(_ roots: ToolchainRoots) -> [InstalledToolchain]
}
```

Manager table (`~` = `roots.home`). In all records, the catalog's `paths` is the pattern in the "Folder" column, or `[]` when the column says so:

| manager | Folder (pattern) | language | target | Last-use executable |
|---|---|---|---|---|
| pyenv | `~/.pyenv/versions/*` | python | name | `bin/python3` |
| conda | `~/miniconda3/envs/*`, `~/anaconda3/envs/*`, `~/miniforge3/envs/*`, `~/mambaforge/envs/*`, `~/.conda/envs/*` | condaEnv | **path** | `bin/python` |
| nvm | `~/.nvm/versions/node/*` | node | path | `bin/node` |
| fnm | `~/Library/Application Support/fnm/node-versions/*`, `~/.local/share/fnm/node-versions/*`, `~/.fnm/node-versions/*` | node | name | `installation/bin/node` |
| volta | `~/.volta/tools/image/node/*` | node | path | `bin/node` |
| asdf | `~/.asdf/installs/*/*` (plugin `nodejs`→node, `python`, `ruby`, `java`, `golang`→go, `rust`; others→other) | per plugin | path | `bin/<exe>` |
| rbenv | `~/.rbenv/versions/*` | ruby | name | `bin/ruby` |
| rvm | `~/.rvm/rubies/*` (except `default`) | ruby | path | `bin/ruby` |
| sdkman | `~/.sdkman/candidates/*/*` (except `current`; `java`→java, others→other) | per candidate | path | `bin/<candidate>` |
| rustup | `~/.rustup/toolchains/*` | rust | name | `bin/rustc` |
| goSDK | `~/sdk/go*` | go | path | `bin/go` |
| homebrew | `[]` (Cellar is protected) | per formula (R6) | formula name | `<ver>/bin/<exe>` |
| system | `[]`; `Xcode*.app` (≥ 2), `libraryJava/*.jdk`, `libraryPython/*` (without `Current`) | python/java/other | — | — |

Records in `catalog.json`, one per manager except `system`:
- ids `toolchain-<manager>` (e.g. `toolchain-pyenv`, `toolchain-go-sdk` for `goSDK`).
- Common fields: `risk "yourCall"`, `regenerates false`, no `aggressiveRisk`, `preselectInAggressive true`, `profiles []`, `kind "code"`, `discovery {"type":"toolchains","manager":…}`.
- `cleanup`:
  - pyenv: `command pyenv ["uninstall","-f","{target}"]`
  - conda: `command conda ["env","remove","-p","{target}","-y"]`
  - fnm: `command fnm ["uninstall","{target}"]`
  - rbenv: `command rbenv ["uninstall","-f","{target}"]`
  - rustup: `command rustup ["toolchain","uninstall","{target}"]`
  - homebrew: `command brew ["uninstall","{target}"]`
  - the rest: `trash`
- `shortReason`: «Otra versión de la misma herramienta; la que usas y las que piden tus proyectos no se tocan.» (Another version of the same tool; the one you use and those your projects ask for are not touched.)
- In addition:
  - `toolchain-system-info`: `cleanup info`, `discovery {"type":"toolchainSystemInfo"}`, `reviewHint` «Las versiones de /Library y las apps Xcode se quitan a mano o con el Desinstalador de Airy.» (Versions in /Library and Xcode apps are removed by hand or with Airy's Uninstaller.)
  - `node-dependency-duplicates`: `cleanup info`, `discovery {"type":"dependencyDuplicates"}`, `reviewHint` «Con pnpm cada versión de un paquete se guarda una sola vez en el disco y la comparten todos tus proyectos.» (With pnpm each version of a package is stored only once on disk and shared by all your projects.)
- `title`s:
  - «Versión de Python (pyenv)» (Python version (pyenv))
  - «Entorno de conda» (conda environment)
  - «Versión de Node (nvm)» (Node version (nvm)), «Versión de Node (fnm)», «Versión de Node (Volta)»
  - «Versión instalada con asdf» (Version installed with asdf)
  - «Versión de Ruby (rbenv)» (Ruby version (rbenv)), «Versión de Ruby (rvm)»
  - «Versión instalada con SDKMAN» (Version installed with SDKMAN)
  - «Toolchain de Rust» (Rust toolchain)
  - «Versión de Go (~/sdk)» (Go version (~/sdk))
  - «Versión de Homebrew» (Homebrew version)
  - «Versiones instaladas en el sistema» (Versions installed on the system)
  - «Paquetes de Node repetidos entre proyectos» (Node packages repeated across projects)

- [ ] **Step 1: Write the failing tests**

```swift
// CatalogSchemaTests
@Test func toolchainDiscoveryDecodesAndRoundTrips()        // {"type":"toolchains","manager":"rustup"} ↔ .toolchains(manager: .rustup); unknown manager → DecodingError
@Test func toolchainFichasAreNeverGreen()                  // every record with discovery .toolchains: risk == .yourCall, aggressiveRisk == nil, profiles.isEmpty;
                                                            // RiskClassifier(.aggressive) and (.prudent).baseRisk == .yourCall
@Test func toolchainCommandsAreArgumentArraysWithTarget()  // pyenv/conda/fnm/rbenv/rustup/homebrew: cleanup.usesTargets; no argument contains " " or "sh"; conda uses "-p" (not "-n")
@Test func shellFunctionManagersUseTrash()                 // nvm, volta, asdf, rvm, sdkman, goSDK → .trash
// ToolchainInventoryTests (temporary tree as fake home and Cellar)
@Test func inventoryFindsEachManagerLayout()                // one case per table row → exact manager, language, name, target (name or path)
@Test func symlinkEntriesAreNotInventoried()                // versions/foo → link; candidates/java/current; rubies/default → absent
@Test func homebrewOnlyVersionedLanguageFormulas()          // Cellar/{python@3.11,node@18,ffmpeg,openjdk} → python@3.11, node@18, openjdk; never ffmpeg
@Test func condaBaseIsNeverAnInstall()                      // ~/miniconda3 (base) does not appear; ~/miniconda3/envs/ml does, target == absolute path
@Test func lastUsedIsMaxOfExecutableAtimeAndFolderMtime()   // utimes: atime bin/python3 = 10 d ago, folder mtime = 200 d ago → 10 d ago; missing executable → mtime
@Test func systemInstallsAreInformational()                 // applications/{Xcode.app,Xcode-beta.app}, libraryJava/x.jdk → informational == true, manager .system
```

- [ ] **Step 2: Run** `swift test --filter "ToolchainInventoryTests|CatalogSchemaTests"`. Expected: FAIL (undefined types).
- [ ] **Step 3: Implement** according to Interfaces and the table. The date is read with `lstat` (`st_atimespec`, `st_mtimespec`). In `source(for:)`, the three new cases return `PendingDiscoverySource()` for now.
- [ ] **Step 4: Run** `swift test 2>&1 | tail -3`. Expected: all green (the existing catalog tests keep passing with the 14 new records).
- [ ] **Step 5: Commit**: `feat: inventory of installed versions of development tools` (+ Co-Authored-By).

---

### Task 2: Which version is in use (default, PATH and project pins with the shared walk)

**Files:**
- Create: `Sources/DiskMapCore/Cleanup/Toolchains/ToolchainUsage.swift`
- Modify: `Sources/DiskMapCore/Cleanup/ProjectArtifactSource.swift` (`ProjectWalkMemo` gains the project list; `walk` consumes it)
- Test: `Tests/DiskMapCoreTests/ToolchainUsageTests.swift`, `Tests/DiskMapCoreTests/ProjectArtifactTests.swift`

**Interfaces:**
- Consumes: `InstalledToolchain`, `ToolchainRoots` (Task 1); `CommandRunning.resolve`; `ProjectArtifactSource`.
- Produces:
```swift
public struct ProjectList: Sendable, Equatable { public var projects: [String]; public var complete: Bool }
// ProjectWalkMemo: func projectList(compute: () async -> ProjectList) async -> ProjectList   (second slot, same Mutex pattern)
// ProjectArtifactSource:
public func projectList(context: DiscoveryContext) async -> ProjectList   // BFS of roots(home:) with totalBudget; memoized in context.projectWalk
// `walk` uses projectList(context:) instead of walking again; `onWalk` still counts artifact walks;
// new test hook `onListProjects: (@Sendable () -> Void)?` counts the BFS runs.

public struct VersionPin: Sendable, Equatable {
    public var language: ToolchainLanguage
    public var raw: String              // verbatim, without spaces
    public var source: String           // "~/Projects/app/.nvmrc" (tildePath) or "pyenv global"
    public var resolvable: Bool         // false: "lts/*", "node", "latest", "system", "stable"/"nightly" without a toolchain on that channel
    public func matches(_ install: InstalledToolchain) -> Bool
}

public struct UsageReport: Sendable {
    public var defaults: [String: String]        // InstalledToolchain.path → reason («Es la versión por defecto de pyenv.» (It is the default version of pyenv.), «La usa el PATH (node).» (The PATH uses it (node).), «Xcode activo (xcode-select).» (Active Xcode (xcode-select).))
    public var requested: [String: String]       // path → «La pide ~/Projects/app (.nvmrc).» (~/Projects/app (.nvmrc) asks for it.)
    public var noPreselect: Set<ToolchainLanguage>  // unresolvable pin or incomplete project list
    public var projectsComplete: Bool
}

public enum ToolchainUsage {
    static let pinFiles = [".nvmrc", ".node-version", ".python-version", ".tool-versions", "rust-toolchain",
                           "rust-toolchain.toml", ".ruby-version", "environment.yml"]
    static let pathExecutables: [ToolchainLanguage: [String]] = [.python: ["python3", "python"], .node: ["node"],
        .ruby: ["ruby"], .java: ["java"], .rust: ["rustc", "cargo"], .go: ["go"]]
    public static func report(installs: [InstalledToolchain], roots: ToolchainRoots, projects: ProjectList,
                              runner: any CommandRunning) async -> UsageReport
    static func pins(inProject root: String) -> [VersionPin]     // root + direct children (R4); files > 64 KB are ignored
}
```

Default rules per manager. Only files are read; no command is executed:
- **pyenv:** `~/.pyenv/version`, all its lines. A line that names a link in `versions/` (virtualenv) marks the version owning its `realpath`.
- **nvm:** `~/.nvm/alias/default`. Aliases are followed (`~/.nvm/alias/<x>`, also `lts/<x>`) up to 3 hops.
- **fnm:** `realpath` of `<fnm>/aliases/default`.
- **volta:** `node.runtime` of `~/.volta/tools/user/platform.json` (JSON).
- **asdf:** `~/.tool-versions`.
- **rbenv:** `~/.rbenv/version`.
- **rvm:** `realpath` of `~/.rvm/rubies/default`.
- **SDKMAN:** `realpath` of `candidates/<c>/current`.
- **rustup:** `default_toolchain` and the values of `[overrides]` in `~/.rustup/settings.toml`, read line by line with `^\s*([^=]+?)\s*=\s*"(.*)"\s*$`. A TOML parser is not needed.
- **Xcode:** `readlink(xcodeSelectLink)`.
- **PATH:** for each executable in `pathExecutables`, `runner.resolve` and then `realpath`. If it falls inside `install.path`, that install is in use. Shims fall inside none and mark nothing.
- **Unresolvable default:** the highest version (numeric order by components) of that manager counts as the default, and its language goes into `noPreselect`.

Matching of `VersionPin.matches`:
- Strip the prefixes `v`, `ruby-`, `python-`, `go` and `java/` (SDKMAN).
- Compare component by component, splitting on `.`: the pin is a prefix of the installed version.
- Rust: the installed name is compared without the `-(aarch64|x86_64)-apple-darwin` suffix, and `stable`/`beta`/`nightly` match by channel.
- Conda: `name:` matches the last component of the environment path, and `prefix:` matches the path.
- Homebrew: `python@3.11` counts as version `3.11`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func defaultsFromEachManagerFile()                     // one case per manager → defaults[path] with the exact reason («Es la versión por defecto de pyenv.»…)
@Test func pathResolutionMarksInUse()                        // FakeRunner.resolved["node"] = <home>/.nvm/versions/node/v20.1.0/bin/node → «La usa el PATH (node).»; pyenv shim → nothing
@Test func projectPinsMarkRequestedVersions()                // ~/Projects/app/.nvmrc "18" → v18.17.0 and v18.20.1 requested; v20 not; ~/Projects/mono/web/.python-version "3.11" (direct child) → 3.11.4
@Test func pinMatchingIsComponentWise()                      // "3.1" does not ask for 3.11.0; "v18" asks for 18.0.0; "ruby-3.2.2" asks for 3.2.2; "1.75" asks for "1.75.0-aarch64-apple-darwin"; "stable" asks for "stable-aarch64-apple-darwin"
@Test func toolVersionsAndRustToolchainTomlAreParsed()       // "nodejs 18.17.0 20.1.0" → two pins; [toolchain] channel = "1.70.0" → rust pin
@Test func unresolvablePinsAreConservative()                 // .nvmrc "lts/*" → .node ∈ noPreselect; alias default "lts/iron" without a file → the highest nvm version in defaults
@Test func condaEnvironmentYmlRequestsEnv()                  // environment.yml "name: ml" → ~/miniconda3/envs/ml requested
@Test func oneProjectWalkPerPassAndBudgetFailsClosed() async // same DiscoveryContext: discover(old-project-artifacts) + report → onListProjects == 1;
                                                              // totalBudget .zero → complete == false and all languages in noPreselect
```

- [ ] **Step 2: Run** `swift test --filter "ToolchainUsageTests|ProjectArtifactTests"`. Expected: FAIL.
- [ ] **Step 3: Implement** according to Interfaces. `projects(in:)` reports whether it was cut short by the deadline (`complete`). The existing `ProjectArtifactTests` do not change.
- [ ] **Step 4: Run** `swift test 2>&1 | tail -3`. Expected: all green.
- [ ] **Step 5: Commit**: `feat: versions in use by default, PATH and project pins with a single walk` (+ Co-Authored-By).

---

### Task 3: `ToolchainSource` (risk, preselection, Homebrew, funnel)

**Files:**
- Create: `Sources/DiskMapCore/Cleanup/Toolchains/ToolchainSource.swift`
- Modify:
  - `Sources/DiskMapCore/Cleanup/CleanupTargets.swift` (`DiscoveryContext.toolchains = ToolchainMemo()`; `.toolchains` → `ToolchainSource()`)
  - `Sources/DiskMapCore/Safety/CommandPolicy.swift`
  - `Sources/DiskMapCore/Safety/TimeBudget.swift` (`public static let toolchains: Duration = .seconds(20)`)
- Test: `Tests/DiskMapCoreTests/ToolchainSourceTests.swift`

**Interfaces:**
- Consumes: Task 1 and Task 2; `CleanupTargetSource`; `ProcessListing`; `TimeBudget.processScan`; `TreeWalk.summarize`.
- Produces:
```swift
final class ToolchainMemo: Sendable {        // same pattern as ProjectWalkMemo: one detection per DiscoveryContext
    func detection(compute: () async -> ToolchainDetection) async -> ToolchainDetection
}
struct ToolchainDetection: Sendable {
    var installs: [InstalledToolchain]
    var usage: UsageReport
    var brewDependents: [String: [String]?]   // formula → dependents; nil = could not be checked
    var processes: [RunningProcess]?          // nil = listing unknown
    var complete: Bool                        // false if TimeBudget.toolchains ran out
}
public struct ToolchainSource: CleanupTargetSource {
    public init()
    init(roots: @escaping @Sendable (String) -> ToolchainRoots, budget: Duration = TimeBudget.toolchains,
         brewTimeout: TimeInterval = 15, brewLimit: Int = 8)          // tests
    static let brewUsesArguments = ["uses", "--installed"]           // + formula
    static let unusedAfter: TimeInterval = 90 * 86_400
    /// `^[A-Za-z0-9][A-Za-z0-9._+@-]*$` and without `..`: the only thing that arrives as a non-path {target}.
    static func isSafeName(_ text: String) -> Bool
}
// CommandPolicy.refusal: brew with "--ignore-dependencies" → «Airy nunca fuerza a Homebrew a ignorar dependencias.» (Airy never forces Homebrew to ignore dependencies.);
//                        conda with "--all" or "base" → «Airy nunca borra el entorno base de conda.» (Airy never deletes conda's base environment.)
```

`discover(entry, context)` returns only the installs of `entry.discovery.manager`, from a shared detection:
1. **Inventory and groups.** Inventory, usage report and process listing (once, `TimeBudget.processScan`). Installs are grouped by language (R3). A language with fewer than 2 offers nothing. `informational` is never offered here.
2. **Verdict per install.** The first that applies wins:
   - a process whose executable is inside `path` ⇒ `floor .doNotTouch`, «Se está usando ahora.» (It is being used right now.);
   - unknown process listing ⇒ `blockedReason` «No se pudo comprobar si está en uso.» (Could not check whether it is in use.);
   - `usage.defaults[path]` ⇒ `floor .doNotTouch` with that reason;
   - `usage.requested[path]` ⇒ `floor .doNotTouch` with that reason;
   - Homebrew: `brew uses --installed <f>` (with `runner.resolve("brew")`; if it does not resolve ⇒ not offered). With non-empty output ⇒ `floor .doNotTouch`, «Lo necesita Homebrew para: a, b.». Status ≠ 0, deadline exhausted or more than `brewLimit` ⇒ `blockedReason` «No se pudo comprobar a tiempo si Homebrew la necesita.» (Could not check in time whether Homebrew needs it.);
   - otherwise ⇒ amber.
3. **Preselection.** `preselectable` only if all of these hold: `detection.complete`, `usage.projectsComplete`, the language is not in `noPreselect`, `lastUsed` is known and `lastUsed < now − unusedAfter`. The classifier already limits amber preselection to Aggressive.
4. **Target.**
   - `idSuffix = "\(language.rawValue) \(name)"`, or `"\(plugin) \(name)"` in asdf and SDKMAN.
   - `paths = [path]`, except Homebrew (`[]`).
   - `targets = [target]` only in command records.
   - In Homebrew, `bytes` = `TreeWalk.summarize(Cellar/<f>)` with the remaining deadline; `nil` ⇒ `sizeNote` «Tamaño desconocido» (Size unknown) + `blockedReason`.
   - `lastModified = lastUsed`.
   - `details`: «Usada por última vez: dd/MM/yyyy» (Last used: dd/MM/yyyy) (or «Sin fecha de uso» (No usage date)), «Otras versiones: …» (Other versions: …) (those of the same language) and, in asdf, «Luego ejecuta asdf reshim».
5. **Deadline exhausted.** Whatever was not fully evaluated is not offered.

`revalidate(entry, item, context)` repeats the detection **without a prior memo**, because the funnel creates a new `DiscoveryContext`. It requires, in this order:
- a single `target` (or a single Trash path) that corresponds to a live install of that manager with the same `path`;
- `isSafeName(target)` if it is not a path;
- that the environment is not a conda base (the path's parent must be named `envs`);
- that the verdict is still amber. If not, it is rejected with the verdict's reason (e.g. «Es la versión por defecto de pyenv.»);
- `usage.projectsComplete`. If not, «No se pudo comprobar a tiempo si algún proyecto pide esta versión.».

- [ ] **Step 1: Write the failing tests** (temporary home with `utimes`, injected `now`, `FakeRunner`, `FakeListing`, fake `ToolchainRoots`)

```swift
@Test func inUseIsRedOthersAmberNeverGreen() async           // pyenv {3.9.18 (global), 3.11.4, 3.12.1} → 3.9.18 doNotTouch with riskReason; rest yourCall; never .safe in any mode
@Test func aggressivePreselectsOnlyOldUnrequested() async    // .aggressive: 3.11.4 (used 200 d ago) preselected; 3.12.1 (10 d ago) not; .prudent: none preselected
@Test func singleInstallOffersNothing() async                // only one Ruby version across all managers → []
@Test func runningVersionIsRed() async                       // FakeListing with exe at …/versions/3.11.4/bin/python3 → doNotTouch «Se está usando ahora.»
@Test func brewDependentsTimeoutAndVeto() async              // uses → "ffmpeg" ⇒ doNotTouch «Lo necesita Homebrew para: ffmpeg.»; status 1 ⇒ blockedReason;
                                                              // CommandPolicy.refusal("brew", ["uninstall","--ignore-dependencies","x"]) != nil
@Test func funnelRunsOfficialCommandAsArgumentArray() async  // execute(item pyenv 3.11.4) → FakeRunner.calls == [pyenv ["uninstall","-f","3.11.4"], workingDirectory "/"]
@Test func condaRemovesByPathThroughPathGate() async         // calls == [conda ["env","remove","-p","<home>/miniconda3/envs/old","-y"]]; envs/old replaced by a link after planning → .blocked, no call
@Test func nvmVersionGoesToTrash() async                     // execute → .movedToTrash; no FakeRunner.calls with "nvm"
@Test func defaultChangedAfterDetectionIsRefused() async     // detect; write ~/.pyenv/version "3.11.4"; execute → .blocked("Es la versión por defecto de pyenv."); calls empty
@Test func hostileTargetsNeverRun() async                    // targets "../x", "-rf", "3.11/../..", "base", "" → .blocked; no call
@Test func agentCanOnlyList() async                          // context .agent("claude") → .blocked (green only); list_cleanup_items includes the row with risk "yourCall"
@Test func detectionBudgetExceededOffersNothing() async      // budget .zero → []
```

- [ ] **Step 2: Run** `swift test --filter ToolchainSourceTests`. Expected: FAIL.
- [ ] **Step 3: Implement** according to Interfaces. `brew uses` is executed in sequence, never in parallel, so as not to load the CPU.
- [ ] **Step 4: Run** `swift test 2>&1 | tail -3`. Expected: all green.
- [ ] **Step 5: Commit**: `feat: duplicate development versions in amber, in-use ones in red and with their official command` (+ Co-Authored-By).

---

### Task 4: Informational rows (system, Xcode and repeated `node_modules`) and verification

**Files:**
- Create: `Sources/DiskMapCore/Cleanup/Toolchains/DependencyDuplicateSource.swift`
- Modify:
  - `Sources/DiskMapCore/Cleanup/CleanupTargets.swift` (`.toolchainSystemInfo` → `ToolchainSystemInfoSource`, in `ToolchainSource.swift`; `.dependencyDuplicates` → `DependencyDuplicateSource`)
- Test: `Tests/DiskMapCoreTests/DependencyDuplicateTests.swift`, `Tests/DiskMapCoreTests/ToolchainSourceTests.swift`

**Interfaces:**
- Consumes: `ToolchainMemo`/`ToolchainDetection` (Task 3); `ProjectArtifactSource.projectList(context:)` (Task 2).
- Produces:
```swift
struct ToolchainSystemInfoSource: CleanupTargetSource      // revalidate → «Este elemento es solo informativo.» (This item is informational only.)
public struct DependencyDuplicateSource: CleanupTargetSource {
    public init()
    init(budget: Duration)                                  // tests
    static let minimumProjects = 3
}
```

**System.**
- One row per language with `informational` installs when that language totals ≥ 2 (R3), and an «Xcode» row if there are ≥ 2 `Xcode*.app`.
- `idSuffix`: «Python», «Java» or «Xcode».
- `paths = []`.
- `bytes`: sum of `TreeWalk.summarize` with the remaining deadline; `nil` ⇒ `sizeNote` «Tamaño desconocido».
- `details`: one line per install (`tildePath`), marking «(en uso)» (in use) the one in the PATH or the one from `xcode-select`.

**Repeated dependencies.**
- For each project in `projectList`, `node_modules/<pkg>/package.json` and `node_modules/@scope/<pkg>/package.json` are read, first level only.
- From each, `name` and `version` are taken with `JSONSerialization`. Files > 64 KB are ignored.
- Package folders that are links (pnpm already deduplicates) are skipped.
- Key `name@version`. Groups present in ≥ `minimumProjects` distinct projects form **one** row:
  - `bytes` = Σ (copies − 1) × size of one copy, measured with `TreeWalk` and the deadline; if cut short, `sizeNote` «Al menos» (At least) and what was measured is summed;
  - `details` = the 5 largest: «react@18.2.0 · 7 proyectos · 4,1 MB cada copia» (react@18.2.0 · 7 projects · 4.1 MB per copy);
  - `preselectable = false`.
- Incomplete list or deadline exhausted ⇒ `sizeNote` «Análisis parcial» (Partial analysis). There is never an action: the record is `info`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func xcodeAndLibraryInstallsAreInfoRows() async        // applications/{Xcode.app,Xcode-15.4.app}, link → Xcode.app → 1 info row with «(en uso)» on Xcode.app; execute → .blocked("Este elemento es solo informativo.")
@Test func libraryPythonCountsTowardDuplicates() async       // libraryPython/3.11 + pyenv 3.12.1 → info row «Python» and 3.12.1 offered in toolchain-pyenv
@Test func repeatedPackagesAcrossThreeProjectsMakeOneRow() async  // 3 projects with react@18.2.0, 2 with lodash@4.17.21 → 1 row; details only react; bytes == 2 × size
@Test func pnpmSymlinkedPackagesAreSkipped() async           // node_modules/react → link to .pnpm/... → does not count
@Test func scopedPackagesAndBadJsonAreHandled() async        // @babel/core counts; broken or > 64 KB package.json → ignored without failing
@Test func duplicatesNeverActAndAgentOnlyLists() async       // execute (user and agent) → .blocked; never FakeRunner.calls
```

- [ ] **Step 2: Run** `swift test --filter "DependencyDuplicateTests|ToolchainSourceTests"`. Expected: FAIL.
- [ ] **Step 3: Implement** according to Interfaces.
- [ ] **Step 4: Run** `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -3`. Expected: it compiles and everything is green.
- [ ] **Step 5: Read-only verification on this Mac.** Open Airy (DEBUG) in Cleanup and launch the detection. Check in the new rows:
  - the default version of each installed manager appears in red with its reason;
  - no row appears in green;
  - in Cautious nothing is checked;
  - «Solo revisar» shows Xcode, system and repeated packages if there are any.

  Without pressing «Borrar» (Delete). With `airy-mcp`, only the following is done:
  - `list_cleanup_items`, which includes the rows with `risk` `yourCall` or `doNotTouch`;
  - `run_safe_cleanup` with `dry_run: true`, which does not include them.

  Screenshots of the app's own window only. To stop, kill only Airy's PID.
- [ ] **Step 6: Commit**: `feat: informational rows for Xcode, system and repeated Node packages` (+ Co-Authored-By).
