# Airy 3 of 5 — Aggressive cleanup and profile · Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cleanup becomes aggressive by default, with many new targets (Docker prunes, Node, Python, Xcode and other development tool caches, old projects, installers, Chromium browsers, app caches, old versions of agents, «Solo revisar» (Review only)). The three labels «Sin problema / Tú decides / No borrar» (No problem / You decide / Do not delete) appear in Cleanup and in the Map. Selection is multiple, with «Borrar todo» (Delete all) and **a single** confirmation. A «¿Cómo usas tu Mac?» (How do you use your Mac?) profile orders, highlights and preselects, and **never** lowers a risk.

**Architecture:** everything that decides lives in `DiskMapCore`, so the app and `airy-mcp` classify the same way:
- **Catalog and sources.** The catalog (JSON) gains optional fields. There is a single extension point, `CleanupTargets.source(for:)`. The scanner uses it to **discover** items and plan 1's deletion funnel uses it to **revalidate** them right before acting. No rule is duplicated.
- **Risk.** Risk still comes only from `RiskClassifier` (plan 1, extended without forking it).
- **Interface.** The app only paints `CleanupBoard` and `RiskExplanation`, which are pure logic and are tested without SwiftUI.

**Tech Stack:** Swift 6.4 (Command Line Tools only), SwiftPM, SwiftUI + AppKit, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-10-20-airy-fase-2-design.md` (§2.3, §2.4, §2.5, §2.9 «Más objetivos de limpieza» (More cleanup targets), «Decisiones de Claude tras la revisión del constructor» (Claude's decisions after the builder's review)), `docs/superpowers/specs/2026-10-20-diskmap-design.md` (§4 anti-goals). Path lists (ideas only): `docs/superpowers/research/2026-10-20-mole-inspiracion.md` §2.3–2.14, §5.3, §6. Interfaces consumed: `docs/superpowers/plans/2026-10-20-airy-1-identidad-seguridad-mcp.md` and its resolutions in `.superpowers/sdd/2026-10-20-airy-1-identidad-seguridad-mcp/progress.md` (F1–F15). Theme and animations: `docs/superpowers/plans/2026-10-20-airy-2-marca-animaciones.md` (`Theme.Airy` with `riskInk(_:)`/`riskFill(_:)`, `RiskBadge(risk:compact:reason:)` which already shows `Risk.label`, `AnyTransition.leafAway`, `CleanupFlow.gust`/`batchFreed`).

**Out of this plan:** creating animations (plan 2; here only `.leafAway` is used on the rows that leave and the `CleanupFlow.gust` gust, which plan 2 fires by itself on batches of ≥ 2); Performance (plan 4); Uninstaller, orphans and the other sections (plan 5).

## Global Constraints

- Swift 6.4, SwiftPM, Command Line Tools only; `swift build` / `swift test`; `.macOS(.v15)`; the test target keeps the `unsafeFlags` of the Swift Testing plugin.
- Views with the `@ViewState` alias (not `@State`); **never** `.fixedSize(horizontal:false,vertical:true)` on multiline `Text` in new or touched code (use `.lineLimit(nil)` and the container's width); existing patterns (`Theme`, `PrimaryButton`, `SectionHeader`, `GlassCard`) and plan 2's names (`Theme.Airy`, `RiskBadge(risk:compact:reason:)`, `.leafAway`); text in a risk color with `Theme.Airy.riskInk(_:)`.
- Interface in **Spanish (Spain)**; tool names and MCP fields in English.
- File contents are **never** sent to the AI or the MCP: only paths, sizes, dates, types, container/network names and catalog records. Reading listings (`zipinfo -1`, `git ls-files`, `PRAGMA freelist_count`) is local and does not leave Airy.
- Protected locations, never deletable: Docker volumes, iCloud, Mail, Messages, Keychains, AddressBook, Calendars, Photos, `/Applications`, `/Library`, `/usr`, `/bin`, `/sbin`, `/private`, `/opt/homebrew`, `/System`; personal folders are never green; runtimes in use are never touched.
- Every destructive action goes through `ConfirmSheet` → `AppModel` → `CleanupExecutor` (plan 1 funnel). No DEBUG shortcuts that act without confirmation: the new DEBUG steps only open sheets.
- The AI and the profile **only raise** risk. The profile reorders, highlights and preselects, and never changes `risk`.
- The MCP only executes unblocked green. Never amber or red. With the switch off, every action is blocked.
- Files → Trash (`trashItem`, only in the funnel); tool caches → their official command with an **argument array** (never a shell string, never `sh -c`). **Never** `docker volume prune` nor `--volumes` (also rejected in the funnel).
- In tests and verification, real cleanup commands are never run and the real Trash is never emptied. `FakeRunner` / `FakeProbes` / `FakeListing` and temporary folders with a dedicated `AIRY_SUPPORT_DIR` are used. Against the real system only reading and `dry_run: true` are allowed.
- DEBUG screenshots of own windows only; stop the app by killing **only its PID** (never `pkill -x`); do not touch Keychain trust.
- Mole is GPL-3.0: ideas and path lists are adapted, **never code**.
- Zero CPU at rest: disk walks are only done during a detection or right before acting, always with a time budget; respect «Reducir movimiento» (Reduce Motion).
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **Docker stops between detection and «Borrar todo»** → every Docker row ends up «bloqueada: Abre Docker Desktop para limpiar esto» (blocked: Open Docker Desktop to clean this) (not «falló» (failed)), without executing anything, and the rest of the batch goes on. Test in Task 2 (`daemonStoppedAfterDetectionBlocksAtAct`).
2. **The user edits a file in the "old" project after detection** → the `node_modules` is no longer touched on confirming. Test in Task 4 (`projectTouchedAfterDetectionIsRefused`).
3. **`node_modules` or `target` is a symbolic link (pnpm, monorepos, link to `~/Documents`)** → it is neither walked nor offered. What is behind it is never measured nor deleted. Test in Task 4 (`symlinkedArtifactIsNeitherWalkedNorOffered`).
4. **The same path fits two records** (an old `.dmg` in Downloads is an "installer" and an "old download"; a Chrome cache is also seen by the Application Support heuristic) → it appears in a single row and is not counted twice in «Borrar todo · X GB». Test in Task 1 (`samePathNeverInTwoItems`).
5. **The link of an agent's active version is missing** (`~/.local/bin/claude` broken or absent), or an old session is still running → no version is offered or deleted. Test in Task 5 (`missingActiveLinkOffersNothing`, `runningOldVersionIsRefused`).

## Rulings of this plan (the author's decisions; the controller confirms them with the user if they disagree)

- **R1 — System with administrator password (§2.9 #15).** `/Library/Logs/DiagnosticReports`, `/private/var/log`, `/Library/Caches` and «Instalar macOS *.app» (Install macOS *.app) remain as **«Solo revisar»** (amber, no button). Reason: `/Library`, `/private` and `/Applications` are hard protections in the Global Constraints, and phase 1 forbids administrator privileges. The only route would be a shell string with `osascript … with administrator privileges`, which breaks the argument-array rule. Cost: "System Data" is not recovered from Airy.
- **R2 — Old framework versions inside `/Applications/<Browser>.app`.** Same reason: they go to «Solo revisar».
- **R3 — Cautious = phase 1** holds record by record for the 26 phase 1 records, with a test that pins it. The new records use their `risk` in Cautious and `aggressiveRisk` in Aggressive. Even so, Cautious never preselects amber.
- **R4 — Old project.**
  - The project is the **outermost** folder with a marker (`package.json`, `pyproject.toml`, `requirements.txt`, `Cargo.toml` or `.git`). In a monorepo, touching any package keeps all the artifacts.
  - The signal is exactly the spec's.
  - iCloud (`isUbiquitousItem`, `~/Library/Mobile Documents`) and also `~/Library/CloudStorage` are excluded, out of caution.
  - Search roots: those that exist among `Projects, Developer, dev, Code, GitHub, Repos, src, Workspace, orca, Desktop, Documents`.
- **R5 — Preselection by profile.** With profiles chosen, a record labelled **only** with other profiles is not preselected. Records without a profile (logs, browsers) are preselected if they are green. Without profiles, the behavior is plan 1's.
- **R6 — Artifacts.** Only the five from the spec are preselected in Aggressive (`node_modules`, `.venv`, `target`, `.next`, `build`). Those of the extended catalog go in amber without preselection.
- **R7 — Buttons.** «Limpiar todo lo seguro» (Clean everything safe) becomes «Seleccionar todo lo verde» (Select everything green): it selects, it does not confirm. Every deletion comes out of «Borrar todo · X GB» with the single confirmation.
- **R8 — Docker networks.** They take up no disk: the row says «No ocupa espacio en disco» (Takes up no disk space) and lists the networks.
- **R9 — Commands with a target** (`simctl runtime delete <id>`, `sqlite3 <History.db> VACUUM;`). They use the `{target}` marker. The target is validated (UUID or path passed through `PathGate`) and the source revalidates it in the funnel.
- **R10 — «Descargas viejas» (Old downloads) (Basic use profile).** Items in `~/Downloads` of ≥ 50 MB unchanged for ≥ 180 days, one per row, in amber and without preselection.
- **R11 — AI models "unused for months".** They are not filtered, because `atime` is not reliable. Each row shows «Último cambio hace X» (Last changed X ago) and the profile highlights them.

---

## File structure

```
Sources/DiskMapCore/
  Catalog/Catalog.swift                 new CatalogEntry fields, RetentionRule, DiscoveryKind            (mod)
  Resources/catalog.json                new and extended records (Tasks 2–6)                              (mod)
  Cleanup/TreeWalk.swift                bounded walk: bytes, last change, watched names                   (new)
  Cleanup/CleanupTargets.swift          source protocol, StaticPatternSource, RetentionSource             (new)
  Cleanup/DockerSource.swift            DockerProbe, DockerState, DockerSource                            (new)
  Cleanup/SimulatorRuntimeSource.swift  simulator runtimes without devices                               (new)
  Cleanup/ProjectArtifactSource.swift   projects untouched ≥ 3 months and guards                          (new)
  Cleanup/InstallerSource.swift         installers in Downloads/Desktop/Documents                         (new)
  Cleanup/AppSupportCacheSource.swift   regenerable-cache heuristic in Application Support               (new)
  Cleanup/CleanupScanner.swift          discovers by sources; one path, one item                          (mod)
  Cleanup/CleanupExecutor.swift         revalidates by sources, {target}, Docker, CommandPolicy           (mod)
  Safety/CommandPolicy.swift            commands that are never executed (Docker volumes…)                (new)
  Safety/RiskClassifier.swift           `floor:` and preselection by profile                              (mod)
  Settings/AirySettings.swift           profilePrompted                                                   (mod)
  UIState/CleanupBoard.swift            labels, «Solo revisar», selection, confirmation sections          (mod)
  UIState/RiskExplanation.swift         the "why" of each label                                           (new)
  Scan/ScanHonesty.swift                complete/partial/unavailable and "+"                              (new)
  AI/AIContextBuilder.swift             profiles in the context                                           (mod)
  MCP/Tools/ReadTools.swift             list_cleanup_items by profile + fields; list_largest/summary "+"  (mod)
Sources/Airy/
  Cleanup/CleanupView.swift, CleanupRow.swift, ConfirmSheet.swift, CleanupFlow.swift                      (mod)
  Profile/ProfileSheet.swift            «¿Cómo usas tu Mac?»                                              (new)
  Settings/SettingsView.swift           «Cómo usas tu Mac» section (plan 1 file)                          (mod)
  Shell/RootView.swift, AppModel.swift, Map/HoverCard.swift, Map/MapView.swift                            (mod)
Tests/DiskMapCoreTests/
  CatalogSchemaTests, DockerTests, DevCatalogTests, ProjectArtifactTests, ExtraTargetsTests,
  AppCacheTests, ProfileTests, ScanHonestyTests (new); CleanupBoardTests, MCPReadToolTests,
  CatalogTests, CleanupTests, ClassifierTests (adjustments cited in each task)
```

**Catalog order:** concrete records go before broad ones (`installers`, `old-downloads`, `app-support-caches` at the end). The scanner walks the catalog in order, and a path belongs to the first record that claims it.

---

### Task 1: Catalog schema and target sources (one extension point for scanner and funnel)

**Files:**
- Modify: `Sources/DiskMapCore/Catalog/Catalog.swift`, `Sources/DiskMapCore/Cleanup/CleanupScanner.swift`, `Sources/DiskMapCore/Cleanup/CleanupExecutor.swift` ("belongs to the record's patterns" step of plan 1's private `plan`, Task 8), `Sources/DiskMapCore/Safety/RiskClassifier.swift`
- Create: `Sources/DiskMapCore/Cleanup/TreeWalk.swift`, `Sources/DiskMapCore/Cleanup/CleanupTargets.swift`
- Test: `Tests/DiskMapCoreTests/CatalogSchemaTests.swift`; adapt `ClassifierTests.bundledCatalogDecodesWithDefaults` (it no longer requires `aggressiveRisk == nil` on all of them; it keeps the round-trip of the example JSON and adds the new fields)

**Interfaces:**
- Consumes: `CatalogEntry`, `Catalog.match`, `CleanupScanner.expand` (private, reused), `RiskClassifier.classify(entry:paths:ai:)`, `ProcessListing`, `TimeBudget`, the funnel's `plan` (plan 1 Task 8).
- Produces:
```swift
// Catalog.swift — stored fields (resolution F4): decodeIfPresent with these default values,
// parameters with a default value in the public init, encoded only if they are not the default value.
public struct RetentionRule: Codable, Sendable, Equatable {
    public var keepNewest: Int          // ≥ 1, per parent folder; JSON "keepNewest"
    public var activeLink: String?      // "~/.local/bin/claude": the version it points to is always kept
}
public enum DiscoveryKind: Codable, Sendable, Equatable {   // JSON {"type": "...", ...}; unknown type ⇒ decoding error
    case projectArtifacts(names: [String], cachedirTag: Bool)   // Task 4
    case installers                                              // Task 5
    case simulatorRuntimes                                       // Task 3
    case appSupportCaches                                        // Task 6
    case docker                                                  // Task 2
}
extension CleanupMethod { public static let targetPlaceholder = "{target}" }   // one exact argument
// CatalogEntry gains:
public var shortReason: String?      // one sentence: why it is green/red or what you lose if it is amber
public var perMatch: Bool            // false; one item per path found
public var except: [String]          // []; last components that are never included
public var staleAfterDays: Int?      // only paths unchanged inside for N days
public var minimumBytes: Int64?      // per item
public var retention: RetentionRule?
public var discovery: DiscoveryKind?
public var reviewHint: String?       // .info records: what you do yourself, in Spanish
// CleanupItem gains (default values in init):
public var details: [String] = []        // container names, «Se conservan: …» (Kept: …), «Proyecto sin tocar desde …» (Project untouched since …)
public var targets: [String] = []        // values of {target}
public var sizeNote: String? = nil       // «Tamaño desconocido» (Size unknown), «No ocupa espacio en disco»
public var lastModified: Date? = nil
public var riskReason: String? = nil     // reason for a guard (floor) or a protection
public var sizeIsPartial: Bool = false   // Task 11

// TreeWalk.swift — synchronous, does not follow links (lstat), counts hard links once, checks the clock on every entry
public struct TreeSummary: Sendable, Equatable {
    public var bytes: Int64; public var latestModification: Date?; public var watched: [String]  // relative paths, max. 10
}
public enum TreeWalk {
    /// `nil` if `budget` runs out or the root cannot be read. `prune(name, relativePath)` ⇒ do not enter.
    /// A root that is a file returns its size and its mtime.
    public static func summarize(_ root: String, budget: Duration,
                                 prune: (String, String) -> Bool = { _, _ in false },
                                 watch: (String) -> Bool = { _ in false }) -> TreeSummary?
}

// CleanupTargets.swift
public struct DiscoveryContext: Sendable {
    public let catalog: Catalog, home: String, runner: any CommandRunning, processListing: any ProcessListing
    public let now: Date, scan: FileNode?          // Task 2 adds `docker: DockerState?`
}
public struct DiscoveredTarget: Sendable, Equatable {
    public var idSuffix: String?               // nil ⇒ id = entry.id; otherwise "\(entry.id):\(idSuffix)"
    public var paths: [String]
    public var targets: [String] = []
    public var bytes: Int64? = nil             // nil ⇒ the scanner measures (index or TreeWalk with TimeBudget.sizeMeasure)
    public var details: [String] = []
    public var lastModified: Date? = nil
    public var needle: String? = nil           // reference check (HF, as now)
    public var floor: Risk? = nil              // guard: only raises
    public var floorReason: String? = nil
    public var blockedReason: String? = nil
    public var sizeNote: String? = nil
}
public protocol CleanupTargetSource: Sendable {
    func discover(_ entry: CatalogEntry, context: DiscoveryContext) async -> [DiscoveredTarget]
    /// In the funnel, right before acting. `nil` = still valid as is; otherwise a reason in Spanish.
    func revalidate(_ entry: CatalogEntry, item: CleanupItem, context: DiscoveryContext) async -> String?
}
public enum CleanupTargets {
    /// discovery ⇒ its source; retention ⇒ RetentionSource; otherwise StaticPatternSource.
    public static func source(for entry: CatalogEntry) -> any CleanupTargetSource
}
public struct StaticPatternSource: CleanupTargetSource { public init() }
public struct RetentionSource: CleanupTargetSource { public init() }
// RiskClassifier: classify(entry:paths:ai:floor:) with `floor: Risk? = nil` (strictest with everything else).
// CleanupExecutor.init gains `processListing: any ProcessListing = LibprocListing()` and `now: @Sendable () -> Date = { Date() }`.
```

Source rules:
- **`StaticPatternSource.discover`** does today what `CleanupScanner.candidates(for:)` already does, with no behavior change: it expands the patterns; `.command` records need `runner.resolve`; if they have a `sizeProbe` and are not sqlite ones (Task 5), they are left out; records with `referenceCheck` give one item per folder with `needle`. In addition:
  - It removes the paths whose last component is in `except`.
  - With `perMatch`, it gives one item per path, with `idSuffix = Format.tildePath(path)`.
  - With `staleAfterDays`, it measures with `TreeWalk.summarize`. The path is kept only if `latestModification` is earlier than `now - days`. A `nil` from the walk leaves it out.
  - It applies `minimumBytes`.
  - In `.command` with `{target}`, each path found becomes a `target`.
- **`StaticPatternSource.revalidate`** according to the record's method:
  - `.trash`: each `item.paths` must be in the live expansion (after applying `except`). With `staleAfterDays`, it must still be old (if not, «Lo has usado hace poco.» (You have used it recently.)).
  - `.command` without `{target}`: returns `nil`.
  - `.command` with `{target}`: each `target` must still be in the expansion.
- **`RetentionSource.discover`**:
  1. Expands and groups the paths by parent folder.
  2. In each group, sorts by `mtime` descending (tie: name descending).
  3. If there is an `activeLink`, resolves the link's `realpath`. The active version is the group path that contains it or equals it. If it does not resolve or falls outside the group, that group yields nothing (fail closed).
  4. The active one and the newest ones are kept until `keepNewest` is reached; the rest are the item's paths.
  5. Gives one item per record, with `details = ["Se conservan: \(names)"]`.
- **`RetentionSource.revalidate`**: recomputes the kept set. A path that is now kept, or that no longer exists, is rejected with «Ya no es una versión antigua: \(name).» (It is no longer an old version: …). With `activeLink`, it is also rejected if any process from `processListing.processes()` has an `executablePath` inside one of the item's paths («Está en uso: \(name).» (It is in use: …)), or if the listing is `nil` («No se pudo comprobar si está en uso; Airy no lo toca.» (Could not check whether it is in use; Airy does not touch it.)).
- **Scanner**:
  1. For each record, in order: `source(for:).discover`.
  2. **One path, one item**: paths whose canonical form was already claimed by an earlier item are discarded. If none is left, the candidate disappears.
  3. Size: `bytes` from the source or, if missing, index → `TreeWalk.summarize(budget: TimeBudget.sizeMeasure)`. If the walk runs out of time: `sizeNote = "Tamaño desconocido"` and `blockedReason = "No se pudo medir a tiempo."` (Could not be measured in time.).
  4. 0-byte candidates are discarded, unless they have `sizeNote` or `blockedReason`.
  5. Risk with `classify(entry:paths:floor:)`. `riskReason` = `floorReason` or the protection's reason.
  6. The rest of the pipeline (references, `ProcessGuard`, `usedBy`) does not change.
  7. `CleanupScanner.parseDockerDF/parseDockerSize` remain as public forwards (phase 1 tests).
- **Funnel**: in the private `plan`, the "belongs to the record's patterns" step becomes `CleanupTargets.source(for: live).revalidate(live, item:, context:)`, followed by `PathGate.validate` per path, as before. In `.command` with `{target}`:
  - `!item.targets.isEmpty` is required;
  - each target that starts with `/` goes through `PathGate.validate`;
  - it is executed once per target, substituting the marker;
  - the freed amounts are added up in `.freed`;
  - the first failure stops the batch and returns `.failed`;
  - `preview` returns `.wouldRun(command:)` with the first target substituted.

- [ ] **Step 1: Write the failing tests** (`CatalogSchemaTests.swift`, temporary home; `FakeRunner`/`FakeProbes` from `CleanupTests.swift`; local `FakeListing: ProcessListing`)

```swift
@Test func newFieldsRoundTripAndDefaultsAreOmitted()      // JSON with shortReason, perMatch, except, staleAfterDays, minimumBytes,
    // retention {keepNewest 2, activeLink}, discovery {"type":"projectArtifacts","names":["node_modules"],"cachedirTag":true}
    // → decodes the same; re-encode without the default fields (perMatch false does not appear); discovery {"type":"nope"} → throws
@Test func treeWalkStopsAtBudgetAndDoesNotFollowLinks()   // budget .zero → nil; link to a 10 MB folder counts 0 bytes, is not walked
@Test func treeWalkPrunesAndWatches()                     // prune "node_modules": its new mtime does not count; watch "-keypair.json" lists it
@Test func perMatchExceptStaleAndMinimum() async {        // ~/Downloads with a.bin (200 MB, old), b.bin (200 MB, new), c.bin (1 MB, old), .DS_Store
    #expect(items.map(\.id) == ["old:~/Downloads/a.bin"])  // staleAfterDays 180, minimumBytes 50 MB, except [".DS_Store"]
}
@Test func retentionKeepsNewestTwoPerParent() async       // iOS DeviceSupport 15,16,17 + watchOS 9,10 → paths == [iOS 15]; details "Se conservan: 17, 16"
@Test func retentionKeepsActiveLinkPlusOne() async         // versions/1.0,1.1,2.0 (2.0 newest), link → 1.0 ⇒ 1.0 and 2.0 are kept; deletes 1.1
@Test func samePathNeverInTwoItems() async                 // two records with the same pattern → the first in the catalog keeps the path; total without double counting
@Test func zeroByteItemsOnlyWithNoteOrBlock() async
@Test func funnelRevalidatesThroughTheSource() async       // retention record: after detecting, 18 is created (newest) → execute of the item with 16 → .blocked("Ya no es una versión antigua: 16.")
@Test func targetPlaceholderRunsOncePerValidatedTarget() async {
    // .command record sqlite3 ["{target}", "VACUUM;"], item.targets = [db1, db2] → runner.calls args == [[db1,"VACUUM;"],[db2,"VACUUM;"]]
    // item.targets == [] → .blocked; relative or protected target (home/Library/Keychains/x) → .blocked and runner without calls
}
@Test func classifierFloorOnlyRaises()                     // floor .doNotTouch over safe → .doNotTouch; floor .safe over yourCall → .yourCall
```

- [ ] **Step 2: Run** — `swift test --filter CatalogSchemaTests` → FAIL (nonexistent types and fields).
- [ ] **Step 3: Implement** according to Interfaces and the rules above. `TreeWalk` uses `opendir`/`lstat` (like `AllocatedSize`) and a `ContinuousClock` with a deadline; it creates no tasks.
- [ ] **Step 4: Run** — `swift test 2>&1 | tail -3` → all green. The phase 1 tests in `CleanupTests` (scanner, Docker, references) keep passing unchanged: StaticPatternSource keeps its behavior.
- [ ] **Step 5: Commit** — `feat: cleanup target sources shared by scanner and funnel` (+ Co-Authored-By).

---

### Task 2: Aggressive Docker (official prunes, stopped daemon and never volumes)

**Files:**
- Create: `Sources/DiskMapCore/Cleanup/DockerSource.swift`, `Sources/DiskMapCore/Safety/CommandPolicy.swift`
- Modify: `catalog.json` (Docker records), `CleanupScanner.swift` (a single Docker probe per pass → `DiscoveryContext.docker`; `dockerMeasure` moves to `DockerSource`), `CleanupExecutor.swift` (`CommandPolicy` before **each** cleanup `runner.run`)
- Test: `Tests/DiskMapCoreTests/DockerTests.swift`. Adapted with a reason: `CleanupTests.dockerImagesAndVolumesAppearAsInfo` (images = command and they measure `Reclaimable`), `CleanupTests.dockerOmittedWhenDaemonDown` (blocked rows now appear) and `CatalogTests.correctedCopyAndRisks` (`docker-images.regenerates == true`).

**Interfaces:**
- Consumes: `CleanupTargetSource`, `DiscoveryContext`, `DiscoveredTarget` (Task 1).
- Produces:
```swift
public struct DockerUsage: Sendable, Equatable { public var size: Int64?; public var reclaimable: Int64? }
public struct DockerSnapshot: Sendable, Equatable {
    public var usage: [String: DockerUsage]      // by "Type" of `docker system df`
    public var stoppedContainers: [String]       // names
    public var unusedNetworks: [String]          // without bridge/host/none
}
public enum DockerState: Sendable, Equatable { case notInstalled, daemonDown, running(DockerSnapshot) }
public enum DockerProbe {
    public static let timeout: TimeInterval = 20
    public static let unavailableMessage = "Abre Docker Desktop para limpiar esto"
    public static func state(runner: any CommandRunning) async -> DockerState
    /// `docker version --format {{.Server.Version}}`: status 0 **and** non-empty output.
    public static func daemonResponds(runner: any CommandRunning) async -> Bool
}
public struct DockerSource: CleanupTargetSource { public init() }   // discovery {"type":"docker"}
public enum CommandPolicy {
    /// Reason to never execute this command even if it comes from the catalog; `nil` if allowed.
    public static func refusal(executable: String, arguments: [String]) -> String?
}
// DiscoveryContext gains `docker: DockerState?` (the scanner fills it once if any record is discovery .docker).
```
Probes (exact arrays, with `docker`'s resolved path):
- `["version","--format","{{.Server.Version}}"]`;
- `["system","df","--format","{{json .}}"]`;
- `["ps","-a","--filter","status=exited","--filter","status=created","--filter","status=dead","--format","{{.Names}}"]`;
- `["network","ls","--filter","dangling=true","--format","{{.Name}}"]`.

If `resolve` returns `nil`, the state is `notInstalled`. If `version` or `df` fail, it is `daemonDown`.

| id | method (`docker …`) | measure (`df` Type / field) | risk → Aggressive | Aggressive presel. | details / note |
|---|---|---|---|---|---|
| `docker-build-cache` | `builder prune -a -f` | Build Cache / Reclaimable | safe | — | — |
| `docker-images` | `image prune -a -f` | Images / Reclaimable | yourCall → **safe**, `regenerates: true` | — | — |
| `docker-containers` (new) | `container prune -f` | Containers / Reclaimable | yourCall | **yes** | `details` = names; `shortReason` «Un contenedor parado puede guardar datos en su capa: lo pierdes.» (A stopped container may hold data in its layer: you lose it.) |
| `docker-networks` (new) | `network prune -f` | — (0 bytes) | safe | — | `sizeNote` «No ocupa espacio en disco»; `details` = names; only if there are any |
| `docker-volumes` | info | Local Volumes / Size | doNotTouch | — | `shortReason` «Guarda los datos de tus contenedores (bases de datos…): no se recuperan.» (It holds your containers' data (databases…): it cannot be recovered.) |

All carry `discovery {"type":"docker"}`, `profiles ["developer"]` and `shortReason`. `docker-build-cache`/`docker-images`: «Docker la vuelve a descargar o construir cuando la necesita.» (Docker downloads or builds it again when it needs it.).

Behavior according to the daemon's state:
- **Daemon down:** each record with a `.command` method gives a target with `bytes 0`, `sizeNote "Tamaño desconocido"` and `blockedReason = DockerProbe.unavailableMessage`. Volumes yields nothing, and Docker is never started.
- **Revalidation:** if `daemonResponds` is `false`, it is rejected with `unavailableMessage`.
- **`CommandPolicy`:** for `docker`, it rejects any argument `volume`, `volumes` or starting with `--volumes`, and the pair `system prune`, with «Airy nunca borra volúmenes de Docker.» (Airy never deletes Docker volumes.). For any executable, it rejects arguments with control scalars, with «Orden no válida.» (Invalid command.).

- [ ] **Step 1: Write the failing tests**

```swift
@Test func runningDaemonYieldsFourActionableItems() async   // fixture df + 2 stopped + 1 network → ids build-cache, images, containers, networks, volumes;
    // images.bytes == Reclaimable from the fixture; containers.details == ["db-viejo","web"]; networks.sizeNote == "No ocupa espacio en disco"
@Test func daemonDownShowsBlockedRowsAndNoVolumes() async   // `version` with status 1 → 4 rows with blockedReason == "Abre Docker Desktop para limpiar esto", canSelect false; without docker-volumes
@Test func emptyVersionOutputCountsAsDown() async           // FakeRunner returns 0 and "" by default → daemonDown
@Test func notInstalledYieldsNothing() async
@Test func daemonStoppedAfterDetectionBlocksAtAct() async    // detect with the daemon up; switch runner to `version` status 1; execute(images) → .blocked(unavailableMessage); runner without "image prune"
@Test func commandPolicyRefusesVolumes() {
    #expect(CommandPolicy.refusal(executable: "/usr/local/bin/docker", arguments: ["volume","prune","-f"]) != nil)
    #expect(CommandPolicy.refusal(executable: "docker", arguments: ["system","prune","-a","--volumes"]) != nil)
    #expect(CommandPolicy.refusal(executable: "docker", arguments: ["image","prune","-a","-f"]) == nil)
}
@Test func executorNeverRunsAVolumeCommandEvenFromCatalog() async  // test catalog with docker-builder args ["builder","prune","--volumes"] → .blocked; runner.calls empty
@Test func bundledCatalogPassesCommandPolicy() throws         // no record in the real catalog is rejected; none contains "volume"
@Test func aggressiveVsPrudentDockerRisks() throws            // aggressive: images safe, containers yourCall+preselected, volumes doNotTouch; cautious: images yourCall, no amber preselected
```

- [ ] **Step 2: Run** — `swift test --filter DockerTests` → FAIL.
- [ ] **Step 3: Implement** according to Interfaces; adapt the three phase 1 tests cited (reason in a one-line comment in each).
- [ ] **Step 4: Run** — `swift test 2>&1 | tail -3` → green.
- [ ] **Step 5: Commit** — `feat: official Docker prunes, stopped daemon blocked and veto on volumes` (+ Co-Authored-By).

---

### Task 3: Development tools and Xcode (Node, Python, long tail, DeviceSupport, runtimes) and classification table

**Files:**
- Create: `Sources/DiskMapCore/Cleanup/SimulatorRuntimeSource.swift`
- Modify: `catalog.json`
- Test: `Tests/DiskMapCoreTests/DevCatalogTests.swift`

**Interfaces:**
- Consumes: Task 1 (`RetentionRule`, `CleanupTargetSource`, `{target}`), `ProcessGuard` (plan 1, via `processNames`).
- Produces: `public struct SimulatorRuntimeSource: CleanupTargetSource { public init() }` (discovery `simulatorRuntimes`); `public enum Phase1Risks { public static let byID: [String: Risk] }` in the test target (`DevCatalogTests.swift`), with the risks of the 26 phase 1 records (those in `catalog.json` before this plan).

Existing records (risk unchanged; they gain `profiles` and `shortReason`):
- `profiles ["developer"]`: npm, pnpm, pnpm-cache, uv, pip, conda, cargo, homebrew, xcode-deriveddata, xcode-simulators, codex-stale-installs, playwright.
- `profiles ["localAI"]`: huggingface-model, ollama-models, whisper-cache, claude-vm.
- `profiles ["basic"]`: user-logs.

It is checked that the existing commands are exactly those of the spec: `npm cache clean --force`, `pnpm store prune`, `uv cache clean`, `pip3 cache purge`, `conda clean --all -y` and `brew cleanup --prune=all -s`; cargo goes with `registry` and `git` to the Trash.

New records (all `regenerates: true` unless stated; `profiles ["developer"]`):

| id | paths | method | risk → Aggressive | `processNames` / others |
|---|---|---|---|---|
| `yarn` | `~/Library/Caches/Yarn` | `yarn cache clean` | safe | `["yarn"]` |
| `yarn-berry` | `~/.yarn/berry/cache` | trash | safe | `["yarn"]` |
| `bun` | `~/.bun/install/cache` | `bun pm cache rm` | safe | `["bun"]` |
| `corepack` | `~/.cache/node/corepack` | trash | safe | `["corepack"]` |
| `go-build-cache` | `~/Library/Caches/go-build` | `go clean -cache` | safe | `["go"]` |
| `go-mod-cache` | `~/go/pkg/mod` | `go clean -modcache` | yourCall → safe | `["go"]` |
| `poetry-cache` | `~/Library/Caches/pypoetry/cache`, `~/Library/Caches/pypoetry/artifacts` | trash | safe | `["poetry"]` (`virtualenvs` stays protected) |
| `pyenv-cache` | `~/.pyenv/cache` | trash | safe | — |
| `bundler-cache` | `~/.bundle/cache` | trash | safe | `["bundle","bundler"]` |
| `composer-cache` | `~/Library/Caches/composer`, `~/.composer/cache` | `composer clear-cache` | safe | `["composer"]` |
| `gradle-caches` | `~/.gradle/caches` | trash | yourCall (without `aggressiveRisk`) | `["gradle"]`; `shortReason` «Gradle tarda en volver a bajarlo todo y lo que compilas sin conexión deja de funcionar.» (Gradle takes a long time to download everything again and what you build offline stops working.) |
| `swiftpm-cache` | `~/Library/Caches/org.swift.swiftpm` | trash | safe | `["swift-build","swift-package"]` |
| `cocoapods-cache` | `~/Library/Caches/CocoaPods` | `pod cache clean --all` | safe | `["pod"]` |
| `dart-pub-cache` | `~/.pub-cache` | `dart pub cache clean --force` | yourCall → safe | `["dart","flutter"]` |
| `electron-cache` | `~/Library/Caches/electron` | trash | safe | — |
| `node-gyp-cache` | `~/Library/Caches/node-gyp`, `~/.node-gyp` | trash | safe | — |
| `prisma-cache` | `~/.cache/prisma` | trash | safe | — |
| `terraform-plugins` | `~/.terraform.d/plugin-cache` | trash | safe | `["terraform"]` |
| `expo-cache` | `~/.expo/*` with `except ["state.json"]` | trash | safe | `["expo"]` |
| `android-build-cache` | `~/.android/build-cache`, `~/.android/cache` | trash | safe | — |
| `jetbrains-caches` | `~/Library/Caches/JetBrains/*` | trash | yourCall | `["idea","pycharm","webstorm","goland","clion","rider","phpstorm","rubymine","datagrip","studio"]` |
| `vscode-caches` | `~/Library/Application Support/Code/{Cache,CachedData,Code Cache,GPUCache,CachedExtensionVSIXs}` (5 literal patterns) | trash | safe | `mustBeClosed ["com.microsoft.VSCode"]` |
| `cursor-caches` | the same under `Application Support/Cursor` | trash | safe | `mustBeClosed ["com.todesktop.230313mzl4w4u92"]` |
| `xcode-device-support` | `~/Library/Developer/Xcode/{iOS,watchOS,tvOS,visionOS} DeviceSupport/*` | trash, `retention {keepNewest: 2}` | safe | `["Xcode","xcodebuild"]`; `shortReason` «Xcode vuelve a copiarlo al conectar el dispositivo; se conservan las 2 más recientes.» (Xcode copies it again when the device is connected; the 2 most recent are kept.) |
| `xcode-coresimulator-caches` | `~/Library/Developer/CoreSimulator/Caches` | trash | safe | `["Simulator","xcodebuild"]` |
| `xcode-test-devices` | `~/Library/Developer/XCTestDevices/*` | trash | safe | `["Xcode","xcodebuild"]` |
| `xcode-doc-cache` | `~/Library/Developer/Xcode/DocumentationCache` | trash | safe | `["Xcode"]` |
| `xcode-caches` | `~/Library/Caches/com.apple.dt.Xcode` | trash | safe | `["Xcode"]` |
| `xcode-orphan-runtimes` | — (discovery `simulatorRuntimes`) | `xcrun simctl runtime delete {target}` | yourCall, `regenerates: false` | `["Simulator","Xcode","xcodebuild"]`; `shortReason` «Tendrías que volver a descargar el runtime desde Xcode.» (You would have to download the runtime again from Xcode.) |
| `xcode-archives` | `~/Library/Developer/Xcode/Archives` | info (Solo revisar) | yourCall | `reviewHint` «Bórralos desde Xcode › Window › Organizer: ahí ves cuáles ya subiste.» (Delete them from Xcode › Window › Organizer: there you see which ones you have already uploaded.) |

The 5 paths of `vscode-caches` and `cursor-caches` are **literal** patterns: this way they meet the layer C exception of `HardProtections` ("literal pattern of a record with an action").

`SimulatorRuntimeSource`:
- Probes, with exact array: `["simctl","runtime","list","-j"]` and `["simctl","list","devices","-j"]`.
- Format of `runtime list -j`: object `{ "<UUID>": {"identifier": UUID, "runtimeIdentifier": "...", "platformIdentifier": "com.apple.platform.iphonesimulator", "version": "17.0", "sizeBytes": Int, "deletable": Bool} }`.
- Format of `list devices -j`: `{"devices": {"<runtimeIdentifier>": [...]}}`.
- **Orphan** = `deletable == true` and no devices under its `runtimeIdentifier`.
- The `target` is the `identifier` if it matches `^[0-9A-Fa-f-]{36}$` (otherwise it is discarded).
- `idSuffix` = «iOS 17.0». Platform map: iphonesimulator → iOS, watchsimulator → watchOS, appletvsimulator → tvOS, xrsimulator → visionOS.
- `bytes` = `sizeBytes`. Any probe or JSON failure gives `[]`.
- `revalidate`: probes again. Each target must still be an orphan and deletable; if not, «Ese runtime ya tiene simuladores o ya no está.» (That runtime now has simulators or no longer exists.).

- [ ] **Step 1: Write the failing tests**

```swift
@Test func phase1EntriesKeepPhase1RiskInPrudent() throws {   // R3
    let c = RiskClassifier(catalog: try .bundled(), settings: prudent, home: h)
    for (id, risk) in Phase1Risks.byID { #expect(c.baseRisk(of: try #require(catalog.entry(id: id))) == risk, "\(id)") }
}
@Test func prudentNeverPreselectsAmber() throws              // all records, classify(entry:paths:[]) in Cautious: no yourCall with preselected
@Test func aggressiveClassificationTable() throws {          // spec §2.5
    // safe: docker-build-cache, docker-images, docker-networks, npm, pnpm, yarn, bun, uv, pip, conda, cargo, homebrew,
    //       xcode-deriveddata, xcode-simulators, xcode-device-support, go-mod-cache
    // yourCall + preselected: docker-containers, old-project-artifacts (Task 4; this line is added there)
    // doNotTouch: docker-volumes, codex-runtime
}
@Test func catalogLint() throws {
    // aggressiveRisk < risk ⇒ regenerates && risk != .doNotTouch; executables without "/"; {target} at most once and only in .command;
    // retention.keepNewest ≥ 1; unique ids; every new record (not in Phase1Risks) has shortReason; .info not doNotTouch ⇒ reviewHint
}
@Test func specCommandsAreExact() throws                      // the six arrays from the spec + yarn ["cache","clean"], bun ["pm","cache","rm"], simctl delete unavailable
@Test func deviceSupportKeepsTwoNewest() async                // temporary home: iOS 15,16,17 → only 15
@Test func orphanRuntimeBecomesTargetedCommand() async {      // fixture: R1 without devices, R2 with one, R3 not deletable → one item with targets == [R1.uuid];
    // execute → runner.calls.last?.arguments == ["simctl","runtime","delete", R1.uuid]
}
@Test func runtimeWithNewDeviceIsRefusedAtAct() async         // after detecting, the devices fixture includes R1 → .blocked
@Test func malformedRuntimeIDIsDropped() async                // identifier "x; rm -rf ~" → no item
@Test func expoKeepsStateJSON() async
```

- [ ] **Step 2: Run** — `swift test --filter DevCatalogTests` → FAIL.
- [ ] **Step 3: Implement** records and source according to the tables.
- [ ] **Step 4: Run** — `swift test 2>&1 | tail -3` → green.
- [ ] **Step 5: Commit** — `feat: aggressive development catalog (Node, Python, Go, fine-grained Xcode and long tail)` (+ Co-Authored-By).

---

### Task 4: Projects untouched ≥ 3 months (regenerable artifacts with guards)

**Files:**
- Create: `Sources/DiskMapCore/Cleanup/ProjectArtifactSource.swift`
- Modify: `catalog.json` (two records)
- Test: `Tests/DiskMapCoreTests/ProjectArtifactTests.swift`; add to `DevCatalogTests.aggressiveClassificationTable` the `old-project-artifacts` line

**Interfaces:**
- Consumes: `TreeWalk` (Task 1), `CleanupTargetSource`, `CommandRunning` (for `git`).
- Produces:
```swift
public enum ProjectArtifactRules {
    public static let rootMarkers = ["package.json", "pyproject.toml", "requirements.txt", "Cargo.toml", ".git"]
    public static let signalExcluded: Set<String> = ["node_modules", ".venv", "target", ".next", "build", "dist"]  // and .git/objects
    public static let staleAfter: TimeInterval = 90 * 86_400
    public static let cachedirSignature = "Signature: 8a477f597d28d172789f06886806bc55"
    public static let searchRootNames = ["Projects", "Developer", "dev", "Code", "GitHub", "Repos", "src", "Workspace",
                                         "orca", "Desktop", "Documents"]
    public static func defaultSearchRoots(home: String) -> [String]       // those that exist, real folders
    public static func regenerationHint(for name: String) -> String       // «Se rehace con npm install (o pnpm/yarn)» (It is rebuilt with npm install (or pnpm/yarn))…
}
public struct ProjectArtifactSource: CleanupTargetSource {
    public init(searchRoots: [String]? = nil, maxDepth: Int = 6,
                projectBudget: Duration = .seconds(5), totalBudget: Duration = .seconds(30))
}
```
Records, both `trash`, `risk yourCall`, `regenerates true`, `profiles ["developer"]`:
- `old-project-artifacts`: `discovery {projectArtifacts, names [node_modules, .venv, target, .next, build], cachedirTag false}`, `preselectInAggressive true`. Title «Carpeta regenerable de un proyecto viejo» (Regenerable folder of an old project). `shortReason` «Está en un proyecto que no tocas hace más de 3 meses; se rehace con su comando.» (It is in a project you have not touched for more than 3 months; it is rebuilt with its command.)
- `old-project-build-leftovers`: `names [venv, dist, Pods, .gradle, .dart_tool, .build, .turbo, .angular, .svelte-kit, .astro, .nuxt, .output, .parcel-cache, .tox, .nox, __pycache__, .pytest_cache, .mypy_cache, .ruff_cache, .zig-cache, zig-out, .cxx, .expo, .terragrunt-cache, DerivedData, obj, bin, vendor]`, `cachedirTag true`, without preselection (R6).

`discover` algorithm (within `totalBudget`; when it runs out, what is already **complete** is returned):
1. **Search roots.** `searchRoots ?? defaultSearchRoots`, each resolved with `realpath`. Those that fall under `~/Library` (including `Mobile Documents` and `CloudStorage`) and those with `URLResourceValues.isUbiquitousItem == true` are skipped.
2. **Projects.** BFS up to `maxDepth` without following links. It prunes `.git`, `Library`, `.Trash`, `Applications`, every artifact name of either record and every name in `signalExcluded`. A folder with any `rootMarker` is a **project** (the outermost): no projects are searched inside it. Ubiquitous folders are skipped.
3. **Signal.** `TreeWalk.summarize(project, budget: projectBudget, prune: name ∈ signalExcluded || (name == "objects" && parent == ".git"))`. If it gives `nil`, the project is not offered. It is old if `latestModification < now - staleAfter`.
4. **Artifacts of an old project.** Real folders (`lstat` → `S_IFDIR`; a link is ignored) inside the project, without entering `.git` nor already-found artifacts, whose name is in `names`. With `cachedirTag`, also any folder with a `CACHEDIR.TAG` that starts with the signature.
   - `bin` is only valid if the parent has `*.csproj|*.fsproj|*.vbproj` and `bin/Debug` or `bin/Release`.
   - `vendor` is only valid if the parent has `composer.json` and `vendor/autoload.php`.
   - Otherwise they are ignored without a row.
5. **Guards per artifact.** `TreeWalk.summarize(artifact, budget: projectBudget, watch: name == ".git" || name.hasSuffix("-keypair.json"))`:
   - `nil` ⇒ `blockedReason` «No se pudo revisar a tiempo.» (Could not be reviewed in time.);
   - `.git` inside ⇒ `floor .doNotTouch`, `floorReason` «Contiene otro repositorio Git dentro.» (It contains another Git repository inside.);
   - a `*-keypair.json` ⇒ `floor .doNotTouch`, «Contiene claves (\(name)): no se regeneran.» (It contains keys (…): they are not regenerated.);
   - if the project or an ancestor up to the search root has `.git`, `git -C <artifact's parent> ls-files -z -- <name>` is executed (with `runner.resolve("git")`, 10 s deadline):
     - status 0 with output ⇒ `floor .doNotTouch`, «Git guarda archivos aquí: no es solo un resto de compilación.» (Git stores files here: it is not just a build leftover.);
     - status 0 empty ⇒ ok;
     - anything else ⇒ `blockedReason` «No se pudo comprobar con Git si guarda archivos aquí.» (Could not check with Git whether it stores files here.).
6. **Target.** `idSuffix = Format.tildePath(artifact)`, `bytes = summary.bytes`, `lastModified` = the project's signal, `details = ["Proyecto sin tocar desde \(date dd/MM/yyyy)", regenerationHint(name)]`.

`revalidate` requires exactly one path, a real folder (not a link), a name in `names` and a current search root that contains it. It then repeats steps 2–5 **only for that path**:
- outermost project going up from the parent; if there is none, «Ya no está dentro de un proyecto.» (It is no longer inside a project.);
- if it is no longer old, «Has tocado el proyecto hace poco (\(date)): no se borra.» (You touched the project recently (…): it is not deleted.);
- if any guard raises the risk or blocks, it is rejected with its reason.

- [ ] **Step 1: Write the failing tests** (temporary tree with `utimes` to date things; injected `now`; `FakeRunner` with `git` resolved)

```swift
@Test func staleProjectOffersItsNodeModulesPreselectedInAggressive() async   // app/{package.json, src/a.js (120 d ago), node_modules (today)} → 1 item yourCall preselected
@Test func signalIgnoresRegenerableFoldersAndGitObjects() async              // only recent node_modules/.git/objects → still old
@Test func recentFileAnywhereKeepsEverything() async                         // src/b.js from 10 d ago → nothing
@Test func outermostRootDecidesForMonorepo() async                           // repo/.git, repo/packages/a/node_modules; packages/b/x.ts recent → nothing
@Test func extendedNamesAreNotPreselected() async                            // __pycache__ and Pods → items of the second record, preselected false
@Test func cachedirTagIsRecognised() async
@Test func nestedRepoAndKeypairAreRed() async                                // target/deploy/x-keypair.json → doNotTouch with floorReason; vendor/.git → doNotTouch
@Test func gitTrackedBuildIsRedAndGitFailureBlocks() async                   // ls-files with output → doNotTouch; status 128 → blockedReason; unresolved git → blockedReason
@Test func binAndVendorOnlyForDotNetAndComposer() async
@Test func symlinkedArtifactIsNeitherWalkedNorOffered() async                // node_modules → link to home/Documents/large: no item; TreeWalk never enters
@Test func iCloudAndCloudStorageAreSkipped() async                           // root under home/Library/CloudStorage → nothing
@Test func budgetExceededOffersNothing() async                               // projectBudget .zero → []
@Test func projectTouchedAfterDetectionIsRefused() async                     // detect; touch src/a.js; execute → .blocked("Has tocado el proyecto hace poco…"); node_modules intact
@Test func revalidateRejectsPathOutsideAnyProject() async
```

- [ ] **Step 2: Run** — `swift test --filter ProjectArtifactTests` → FAIL.
- [ ] **Step 3: Implement** according to Interfaces.
- [ ] **Step 4: Run** — `swift test 2>&1 | tail -3` → green.
- [ ] **Step 5: Commit** — `feat: artifacts of projects untouched for 3 months, with Git and key guards` (+ Co-Authored-By).

---

### Task 5: Installers, firmware, agent versions, Safari, quarantine and «Solo revisar»

**Files:**
- Create: `Sources/DiskMapCore/Cleanup/InstallerSource.swift`
- Modify: `catalog.json`, `CleanupTargets.swift` (`StaticPatternSource`'s sqlite probe)
- Test: `Tests/DiskMapCoreTests/ExtraTargetsTests.swift`

**Interfaces:**
- Consumes: Task 1 (`RetentionSource`, `{target}`, `perMatch`, `staleAfterDays`).
- Produces: `public struct InstallerSource: CleanupTargetSource { public init(); public static let extensions: Set<String> = ["dmg","pkg","mpkg","iso","xip"]; public static let rootNames = ["Downloads","Desktop","Documents"]; public static let zipListTimeout: TimeInterval = 5 }`. In addition, the sqlite probe: in `StaticPatternSource`, a `.command` record with `executable == "sqlite3"` and `sizeProbe` runs the probe with `{target}` substituted and takes `bytes = page_size × freelist_count` (two integers, one per line). If it fails, there is no item.

`InstallerSource`:
- Searches each existing root, at depth ≤ 2, without following links and skipping ubiquitous items.
- Takes regular files with an extension in `extensions`, and `.zip` files whose `zipinfo -1 <path>` (resolved with `resolve("zipinfo")`, deadline `zipListTimeout`) has some line with a level 1–2 component ending in `.app`, or a level ≤ 2 file ending in `.pkg`, `.mpkg` or `.dmg`. A failure or an exhausted deadline ⇒ not an installer.
- One item per file: `idSuffix` = path with `~`, `details ["Descargado \(Format.relativeDate(mtime))"]` (Downloaded …).
- `revalidate`: it is still a regular file and still an installer.

New records:

| id | paths / source | method | risk (Agg.) | profiles | notes |
|---|---|---|---|---|---|
| `device-firmware` | `~/Library/iTunes/*Software Updates/*.ipsw`, `~/Library/Group Containers/K36BKF7T3D.group.com.apple.configurator/Library/Caches/Firmware/*.ipsw` | trash | safe | — | «El Mac lo vuelve a descargar si actualizas el iPhone o el iPad.» (The Mac downloads it again if you update the iPhone or the iPad.) |
| `claude-code-old-versions` | `~/.local/share/claude/versions/*`, `retention {keepNewest 2, activeLink "~/.local/bin/claude"}` | trash | safe | developer, localAI | «Se conservan la versión activa y la anterior.» (The active version and the previous one are kept.) |
| `cursor-agent-old-versions` | `~/.local/share/cursor-agent/versions/*`, `retention {2, "~/.local/bin/cursor-agent"}` | trash | safe | developer | same |
| `lmstudio-models` | `~/.lmstudio/models/*/*`, `~/.cache/lm-studio/models/*/*`, `perMatch` | trash | yourCall | localAI | `mustBeClosed ["ai.elementlabs.lmstudio"]`; «Tendrías que volver a descargar \(size).» (You would have to download … again.) (via RiskExplanation) |
| `safari-compact` | `~/Library/Safari/History.db` | `sqlite3 {target} "VACUUM;"`, `sizeProbe ["-readonly","{target}","PRAGMA page_size; PRAGMA freelist_count;"]`, `partialCleanup`, `minimumBytes 10 MB` | yourCall | basic | `mustBeClosed ["com.apple.Safari"]`, `processNames ["Safari"]`; «Compacta el historial; solo con Safari cerrado.» (Compacts the history; only with Safari closed.) |
| `quarantine-history` | `~/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2` | trash | yourCall, without preselection | — | «Borra el historial de lo que has descargado; macOS lo vuelve a crear vacío.» (Deletes the history of what you have downloaded; macOS creates it again empty.) |
| `installers` | discovery `installers` | trash | yourCall | basic | «Si lo borras, tendrás que volver a descargarlo para reinstalar.» (If you delete it, you will have to download it again to reinstall.) |
| `old-downloads` | `~/Downloads/*`, `perMatch`, `staleAfterDays 180`, `minimumBytes 50_000_000`, `except [".DS_Store",".localized"]` | trash | yourCall | basic | R10; goes **after** `installers` |

«Solo revisar» records (`.info`, `risk yourCall`, with `reviewHint`; R1 and R2):

| id | paths | `reviewHint` |
|---|---|---|
| `system-diagnostic-reports` | `/Library/Logs/DiagnosticReports` | «Necesita tu contraseña de administrador y Airy no borra fuera de tu carpeta. Puedes borrarlos tú desde Finder (⌘⇧G).» (It needs your administrator password and Airy does not delete outside your folder. You can delete them yourself from Finder (⌘⇧G).) |
| `system-logs` | `/private/var/log` | same |
| `system-caches` | `/Library/Caches` | same |
| `macos-installers` | `/Applications/Install macOS*.app` | «Arrástralo a la Papelera desde Aplicaciones si ya actualizaste.» (Drag it to the Trash from Applications if you have already updated.) |
| `chrome-old-frameworks`, `brave-old-frameworks`, `edge-old-frameworks` (3 records) | `/Applications/<App>.app/Contents/Frameworks/<App> Framework.framework/Versions/*` with `<App>` = «Google Chrome», «Brave Browser», «Microsoft Edge»; `retention {keepNewest 1, activeLink "…/Versions/Current"}` | «Se quitan al actualizar el navegador; si no, reinstálalo.» (They are removed when the browser updates; otherwise, reinstall it.) |
| `ios-backups` | `~/Library/Application Support/MobileSync/Backup` | «Gestiónalas desde Finder › tu iPhone › Gestionar copias.» (Manage them from Finder › your iPhone › Manage backups.) |
| `android-emulators` | `~/.android/avd` | «Bórralos desde Android Studio › Device Manager.» (Delete them from Android Studio › Device Manager.) |
| `agent-worktrees` | `~/.codex/worktrees`, `~/.claude/worktrees` | «Quítalos con git worktree remove desde su repositorio.» (Remove them with git worktree remove from their repository.) |
| `time-machine-in-progress` | `/Volumes/*/Backups.backupdb/*/*.inProgress` | «Es una copia de Time Machine que no terminó; revísala desde Time Machine.» (It is a Time Machine backup that did not finish; review it from Time Machine.) |
| `music-sound-libraries` (`profiles ["music"]`) | `/Library/Application Support/GarageBand`, `/Library/Application Support/Logic`, `/Library/Audio/Apple Loops` | «Gestiónalas desde Logic Pro o GarageBand › Biblioteca de sonidos: así se pueden volver a descargar.» (Manage them from Logic Pro or GarageBand › Sound Library: that way they can be downloaded again.) |

On `.info` records the scanner measures with `TreeWalk` (budget `TimeBudget.sizeMeasure`). If it runs out of time, `sizeNote = "Tamaño desconocido"`. Review records do **not** receive `blockedReason` for unknown size: they have no action.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func installersByExtensionAndZipListing() async   // Downloads/{a.dmg, b.pkg, c.zip (zipinfo lists "Foo.app/"), d.zip (lists "notes.txt"), e.txt} → a, b, c
@Test func zipinfoFailureIsNotAnInstaller() async
@Test func installerAlsoOldIsListedOnce() async         // a.dmg of 300 MB and 1 year → only "installers:…" (catalog order)
@Test func missingActiveLinkOffersNothing() async        // versions/{1,2,3} without ~/.local/bin/claude → no item
@Test func runningOldVersionIsRefused() async            // FakeListing with executablePath inside versions/1 → execute .blocked("Está en uso: 1.")
@Test func listingUnknownRefusesRetentionWithLink() async
@Test func safariCompactionSizesFromFreelistAndNeedsSafariClosed() async {
    // probe returns "4096\n5000" → bytes 20_480_000; FakeProbes with Safari open → blockedByOpenApps not empty; execute → .blocked
}
@Test func safariCompactionRunsVacuumWithExactArguments() async   // Safari closed → runner.calls.last == [sqlite3, [db, "VACUUM;"]]
@Test func quarantineIsAmberNotPreselected() throws
@Test func reviewOnlyEntriesHaveNoActionAndAHint() throws         // all in the table: .info, yourCall, non-empty reviewHint; showsCheckbox false
@Test func adminAndApplicationsPathsAreNeverActionable() throws   // no record with an action has patterns under /Library, /private, /Applications, /System
@Test func neverMessagesOrMailCaches() throws                     // no pattern contains "Library/Messages", "com.apple.mail", "Mail Downloads", "Library/Mail"
```

- [ ] **Step 2: Run** — `swift test --filter ExtraTargetsTests` → FAIL.
- [ ] **Step 3: Implement** according to the tables.
- [ ] **Step 4: Run** — `swift test 2>&1 | tail -3` → green.
- [ ] **Step 5: Commit** — `feat: installers, firmware, old agent versions, Safari and «Solo revisar»` (+ Co-Authored-By).

---

### Task 6: Chromium browsers, Application Support heuristic and app caches by profile

**Files:**
- Create: `Sources/DiskMapCore/Cleanup/AppSupportCacheSource.swift`
- Modify: `catalog.json`
- Test: `Tests/DiskMapCoreTests/AppCacheTests.swift`

**Interfaces:**
- Consumes: Task 1; `HardProtections.standard.match(canonicalPath:home:catalog:)` (plan 1).
- Produces: `public struct AppSupportCacheSource: CleanupTargetSource { public init(); public static let markers = ["Code Cache","GPUCache","DawnCache","GrShaderCache","GraphiteDawnCache","DawnGraphiteCache","DawnWebGPUCache","Crashpad"]; public static let alsoCleared = ["Cache","CachedData","Crashpad/completed"]; public static let maxChildren = 5_000 }`.

**Browsers.** Profile paths P = `Cache, Code Cache, GPUCache, DawnCache, DawnGraphiteCache, DawnWebGPUCache, Service Worker/CacheStorage, Service Worker/ScriptCache`. Browser paths B = `GrShaderCache, GraphiteDawnCache, ShaderCache, component_crx_cache, extensions_crx_cache, Crashpad/completed`. Each record includes as patterns `<base>/<p>`, `<base>/*/<p>` and `<base>/<b>`, plus its folder in `~/Library/Caches`. All are trash, safe, `profiles ["basic"]`, «Se vuelve a crear sola al navegar; cierra el navegador antes.» (It is created again by itself when browsing; close the browser first.):

| id | `<base>` (under `~/Library/Application Support/`) | `~/Library/Caches/…` | `mustBeClosed` |
|---|---|---|---|
| `chrome-cache` (extends) | `Google/Chrome` | `Google/Chrome` | `com.google.Chrome` |
| `brave-cache` (extends) | `BraveSoftware/Brave-Browser` | `BraveSoftware`, `com.brave.Browser` | `com.brave.Browser` |
| `edge-cache` | `Microsoft Edge` | `com.microsoft.edgemac` | `com.microsoft.edgemac` |
| `chromium-cache` | `Chromium` | `Chromium` | `org.chromium.Chromium` |
| `arc-cache` | `Arc/User Data` | `company.thebrowser.Browser` | `company.thebrowser.Browser` |
| `vivaldi-cache` | `Vivaldi` | `com.vivaldi.Vivaldi` | `com.vivaldi.Vivaldi` |
| `opera-cache` | `com.operasoftware.Opera` | `com.operasoftware.Opera` | `com.operasoftware.Opera` |
| `firefox-cache` | — | `Firefox` | `org.mozilla.firefox` |

**App caches.** All are trash. `mustBeClosed` = the bundle id indicated. Paths under `Application Support` of layer C apps are **literal patterns**, which is the `HardProtections` exception.

| id | paths | risk | profiles | `mustBeClosed` |
|---|---|---|---|---|
| `slack-cache` | `~/Library/Application Support/Slack/{Cache,Code Cache,GPUCache,Service Worker/CacheStorage}`, `~/Library/Caches/com.tinyspeck.slackmacgap` | safe | basic | `com.tinyspeck.slackmacgap` |
| `discord-cache` | `~/Library/Application Support/discord/{Cache,Code Cache,GPUCache}` | safe | basic | `com.hnc.Discord` |
| `zoom-cache` | `~/Library/Caches/us.zoom.xos` | safe | basic | `us.zoom.xos` |
| `teams-cache` | `~/Library/Containers/com.microsoft.teams2/Data/Library/Caches` | safe | basic | `com.microsoft.teams2` |
| `whatsapp-cache` | `~/Library/Containers/net.whatsapp.WhatsApp/Data/Library/Caches` | safe | basic | `net.whatsapp.WhatsApp` |
| `telegram-cache` | `~/Library/Containers/ru.keepcoder.Telegram/Data/Library/Caches` | safe | basic | `ru.keepcoder.Telegram` |
| `office-caches` | `~/Library/Containers/com.microsoft.{Word,Excel,Powerpoint,Outlook}/Data/Library/Caches` (4 literals) | safe | basic | the 4 bundle ids |
| `notion-cache` | `~/Library/Application Support/Notion/{Cache,Code Cache,GPUCache}` | safe | basic | `notion.id` |
| `adobe-media-cache` | `~/Library/Application Support/Adobe/Common/Media Cache Files`, `…/Adobe/Common/Media Cache`, `~/Library/Caches/Adobe` | safe | creative | — (`processNames ["Adobe Premiere Pro","After Effects","Adobe Media Encoder"]`) |
| `figma-cache` | `~/Library/Application Support/Figma/{Cache,Code Cache,GPUCache}` | safe | creative | `com.figma.Desktop` |
| `finalcut-cache` | `~/Library/Caches/com.apple.FinalCut` | safe | creative | `com.apple.FinalCut` |
| `davinci-cache` | `~/Movies/CacheClip` | safe (personal floor ⇒ amber) | creative | `com.blackmagic-design.DaVinciResolve` |
| `sketch-cache` | `~/Library/Caches/com.bohemiancoding.sketch3` | safe | creative | `com.bohemiancoding.sketch3` |
| `apple-music-cache` | `~/Library/Caches/com.apple.Music` | safe | music | `com.apple.Music` |
| `spotify-cache` (exists) | — | yourCall | music, basic | — |
| `vlc-cache` | `~/Library/Caches/org.videolan.vlc` | safe | music | `org.videolan.vlc` |
| `steam-caches` | `~/Library/Application Support/Steam/{appcache,htmlcache,depotcache,logs}`, `…/Steam/steamapps/shadercache` | safe | gaming | `com.valvesoftware.steam` |
| `steam-games` | `~/Library/Application Support/Steam/steamapps/common/*`, `perMatch`, `staleAfterDays 90` | yourCall | gaming | `com.valvesoftware.steam` |
| `epic-games` | `/Users/Shared/Epic Games/*`, `perMatch`, `staleAfterDays 90` | yourCall | gaming | `com.epicgames.EpicGamesLauncher` |
| `whisky-bottles` | `~/Library/Containers/com.isaacmarovitz.Whisky/Bottles/*`, `perMatch`, `staleAfterDays 90`, `regenerates false` | yourCall | gaming | `com.isaacmarovitz.Whisky` |
| `minecraft-logs` | `~/Library/Application Support/minecraft/logs` | safe | gaming | — |
| `app-support-caches` | discovery `appSupportCaches` (**last record of the catalog**) | yourCall → safe, `regenerates true` | — | — |

Notes on the table:
- **Catalog exception.** For `HardProtections` to accept the layer C paths, their canonical form must start with that of a literal pattern. Check that the four literal paths of Slack, Discord, Notion and Figma pass `PathGate.validate` in the test `sensitiveAppCachesPassThroughCatalogException`.
- **Messages and Mail.** They carry no record; `neverMessagesOrMailCaches` in Task 5 already checks it.

`AppSupportCacheSource`:
- Walks the real folders A and A/B under `~/Library/Application Support`, with a `TreeWalk` of a 10 s budget in total for the search.
- It keeps those that contain some `markers` folder as a direct child. Targets = existing children of `markers` (replacing `Crashpad` with `Crashpad/completed`) ∪ `alsoCleared`.
- The folder is discarded if:
  - it has more than `maxChildren` direct children;
  - any target is claimed by **another** record (`catalog.match` ≠ this one);
  - all its targets are rejected by `HardProtections.match` (rejected paths are removed without a red row).
- One item per folder: `idSuffix` = path relative to Application Support. Record title: «Cachés regenerables de una app» (Regenerable caches of an app).
- `revalidate`: each path exists, is a real folder, its name is in `markers ∪ alsoCleared`, the parent still has a marker, nobody else claims it and it is not protected. The live-cache guard (the funnel's `checkOpenFiles`) does the rest.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func chromiumProfileCachesAreFoundButNotProfileData() async   // Chrome/Default/{Code Cache, Cookies, Local Storage} → only Code Cache
@Test func heuristicFindsElectronAppAndSkipsCatalogued() async       // Application Support/FooApp/{GPUCache,Cache,Data} → item with GPUCache and Cache; Google/Chrome → none (claimed by chrome-cache)
@Test func heuristicDropsHardProtectedApps() async                   // Application Support/1Password/{GPUCache} → no item
@Test func heuristicSkipsHugeFolders() async                         // 5,001 children → no item
@Test func sensitiveAppCachesPassThroughCatalogException() throws    // PathGate.validate(.../Slack/Cache) == nil; (.../Slack/storage) != nil
@Test func staleGamesOnlyAfter90Days() async
@Test func appCachesCarryTheirProfiles() throws                      // table: each id with its profiles
```

- [ ] **Step 2: Run** — `swift test --filter AppCacheTests` → FAIL.
- [ ] **Step 3: Implement** according to the tables.
- [ ] **Step 4: Run** — `swift test 2>&1 | tail -3` → green.
- [ ] **Step 5: Commit** — `feat: Chromium browsers, regenerable-cache heuristic and app caches by profile` (+ Co-Authored-By).

---

### Task 7: Cleanup board (labels, «Solo revisar», selection and single confirmation)

**Files:**
- Modify: `Sources/DiskMapCore/UIState/CleanupBoard.swift`
- Create: `Sources/DiskMapCore/UIState/RiskExplanation.swift`
- Test: `Tests/DiskMapCoreTests/CleanupBoardTests.swift`. `groupsByRiskInFixedOrderSortedBySize` (titles «Sin problema», «Tú decides», «No borrar») and `yourCallNoteUsesProperPlural` («Tú decides») are adapted.

**Interfaces:**
- Produces:
```swift
extension CleanupBoard {
    public static func isReviewOnly(_ item: CleanupItem) -> Bool   // .info and risk != .doNotTouch
    // `groups` leaves out the review items; Group.title == risk.label
    public var reviewItems: [CleanupItem]                          // bytes desc, id
    public var displayItems: [CleanupItem]                         // groups (green, amber, red) + reviewItems
    public var greenSelection: Set<String>                         // ids of readySafeItems
    public var fullSelection: Set<String>                          // canSelect, green and amber; never red
    /// Prunes what is no longer valid and adds the preselected ones (canSelect) that were not in `seen`.
    public func nextSelection(current: Set<String>, seen: Set<String>) -> (selection: Set<String>, seen: Set<String>)
    public static func deleteAllTitle(_ items: [CleanupItem]) -> String   // "Borrar todo · 3,2 GB" / "Borrar todo · hasta 3,2 GB"
    /// `regular` = green; `review` = amber, in the order received; reds do not get here (canSelect).
    public static func confirmSections(_ items: [CleanupItem], excluding removed: Set<String>)
        -> (regular: [CleanupItem], review: [CleanupItem])
    public static let reviewBlockTitle = "Revisa: esto no se regenera solo o puede tener estado"   // Review: this does not regenerate by itself or may hold state
    public static func sizeText(_ item: CleanupItem) -> String     // sizeNote if it exists; "hasta" (up to) if partial; "+" if sizeIsPartial (Task 11)
}
public enum RiskExplanation {
    public static func why(risk: Risk, entry: CatalogEntry?, protection: ProtectionMatch?, reason: String?, bytes: Int64,
                           personal: Bool) -> String
    public static func why(_ item: CleanupItem, home: String = NSHomeDirectory()) -> String
}
// CleanupRunSummary gains `public var successes: [Success]` (Success: title, text — «Liberados 2 GB» (Freed 2 GB) / «1,2 GB a la Papelera» (1.2 GB to the Trash)),
// which `record` fills in .freed/.movedToTrash.
```
Priority of `why` (the first that applies):
- **doNotTouch:** `reason` (guard or protection) → `protection.reason` → `entry.shortReason` → «Es del sistema o guarda datos que no se recuperan.» (It belongs to the system or holds data that cannot be recovered.).
- **yourCall:**
  - `reason` → `entry.shortReason`;
  - otherwise, when `personal` (it is under a personal folder of `RiskPolicy.personalRoots`): «Está en tus carpetas personales: solo tú sabes si lo necesitas.» (It is in your personal folders: only you know whether you need it.);
  - otherwise, with `bytes > 0`: «Pierdes lo que hay dentro (\(Format.bytes(bytes))); no vuelve solo.» (You lose what is inside (…); it does not come back by itself.);
  - otherwise: «Pierdes lo que hay dentro; no vuelve solo.».
- **safe:** `entry.shortReason` → «Se vuelve a crear sola.» (It is created again by itself.).

- [ ] **Step 1: Write the failing tests**

```swift
@Test func groupsUseTheThreeLabelsGreenFirst()          // ["Sin problema","Tú decides","No borrar"]
@Test func reviewOnlyItemsLiveInTheirOwnList()          // ollama (info yourCall) → reviewItems, not in groups; docker-volumes (info red) stays in "No borrar"
@Test func selectAllNeverIncludesRedOrBlocked()         // fullSelection = selectable green+amber; red, protected and blocked out
@Test func greenSelectionIsReadySafe()
@Test func preselectionAppliesOnlyToNewItems() {        // 1st detection: preselected; the user removes one; 2nd detection with the same ids → it does not come back;
    // a new preselected one appears → it is added; one that disappears → it is pruned
}
@Test func deleteAllTitleSaysUpToWhenPartial()          // "Borrar todo · 3 GB" and "Borrar todo · hasta 3 GB"
@Test func confirmSectionsSplitAmberAndHonourRemoval()  // [green A, amber B, amber C], removed {C} → regular [A], review [B]; removed {A,B,C} → both empty
@Test func whyTextsFollowPriority()                     // guard > protection > shortReason > personal > size; green by default «Se vuelve a crear sola.»
@Test func summaryListsSuccessesAndProblems()           // .freed and .movedToTrash → successes with text; .blocked/.failed → problems
@Test func sizeNoteOverridesSize()                      // "No ocupa espacio en disco"
```

- [ ] **Step 2: Run** — `swift test --filter CleanupBoardTests` → FAIL.
- [ ] **Step 3: Implement** according to Interfaces.
- [ ] **Step 4: Run** — `swift test 2>&1 | tail -3` → green.
- [ ] **Step 5: Commit** — `feat: board with «Sin problema / Tú decides / No borrar», «Solo revisar» and selection` (+ Co-Authored-By).

---

### Task 8: Profile in the core (preselection, first time, MCP and Assistant)

**Files:**
- Modify: `Sources/DiskMapCore/Safety/RiskClassifier.swift` (R5 preselection), `Sources/DiskMapCore/Settings/AirySettings.swift`, `Sources/DiskMapCore/MCP/Tools/ReadTools.swift` (`ListCleanupItemsTool`, plan 1 Task 12), `Sources/DiskMapCore/AI/AIContextBuilder.swift`, `Sources/DiskMapCore/AI/AIAssistant.swift` (profile line in the prompt)
- Test: `Tests/DiskMapCoreTests/ProfileTests.swift`, `Tests/DiskMapCoreTests/MCPReadToolTests.swift`

**Interfaces:**
- Consumes: `CleanupBoard.displayItems` and `RiskExplanation.why(_:)` (Task 7), `AiryEnvironment.classifier()` (plan 1).
- Produces:
```swift
// AirySettings: public var profilePrompted = false   // JSON "profilePrompted", decodeIfPresent → false; always encoded
// RiskClassifier.preselected(risk:entry:) becomes:
//   let fits = settings.profiles.isEmpty || entry.profiles.isEmpty || highlighted(entry)
//   fits && (risk == .safe || (mode == .aggressive && risk == .yourCall && entry.preselectInAggressive))
// AIContextBuilder.context(…, profiles: Set<UsageProfile> = []) → payload "profiles": ["Programo", …] (titles, sorted)
// AIAssistant: if there are profiles, the prompt adds «El usuario usa su Mac para: <titles>. Prioriza lo que le sirve; nunca bajes un riesgo por eso.» (The user uses their Mac for: <titles>. Prioritize what is useful to them; never lower a risk because of it.)
// list_cleanup_items: items in the order of CleanupBoard(items:).displayItems; each item gains
//   "review_only": Bool, "details": [String], "size_note": String|null, "why": String, "profiles": [String];
//   output gains "profiles": [rawValue sorted]
```

- [ ] **Step 1: Write the failing tests**

```swift
@Test func profilesNeverChangeRiskOnBundledCatalog() throws {   // 64 combinations × all records × both modes: same risk as without a profile
}
@Test func profileHighlightsItsMinimumEntries() throws {        // spec §2.3: per profile, these ids exist and have the profile
    // developer: docker-build-cache, docker-images, docker-containers, docker-networks, npm, pnpm, yarn, bun, uv, pip, conda,
    //            cargo, xcode-deriveddata, xcode-simulators, xcode-device-support, old-project-artifacts
    // localAI: ollama-models, lmstudio-models, huggingface-model · creative: adobe-media-cache, finalcut-cache, davinci-cache
    // gaming: steam-games, epic-games, whisky-bottles · music: music-sound-libraries · basic: chrome-cache, safari-cache, user-logs, old-downloads
}
@Test func otherProfilesEntriesAreNotPreselected()              // profiles [.basic]: docker-build-cache safe, preselected false; user-logs safe, preselected true
@Test func noProfilesKeepsPlan1Preselection()                   // profiles []: same as before (plan 1's preselection() stays green)
@Test func profilePromptedRoundTrips()                          // {"version":1} → false; save/load true
@Test func aiContextCarriesProfileTitlesOnly()                  // JSON contains "Programo" (I code); no file content
@Test func listCleanupItemsFollowsProfileOrder() async {        // MCPReadToolTests: settings.json with profiles ["developer"];
    // A (safe, 5 GB, no profile), B (safe, 1 GB, developer) → order [B, A]; without profiles → [A, B]; "profiles" == ["developer"]
}
@Test func listCleanupItemsMarksReviewOnly() async              // .info yourCall record → review_only true, actionable_by_agent false, at the end
```

- [ ] **Step 2: Run** — `swift test --filter ProfileTests` and `--filter MCPReadToolTests` → FAIL.
- [ ] **Step 3: Implement** according to Interfaces.
- [ ] **Step 4: Run** — `swift test 2>&1 | tail -3` → green (including `ClassifierTests.preselection`).
- [ ] **Step 5: Commit** — `feat: the profile orders, highlights and preselects in Cleanup, MCP and Assistant` (+ Co-Authored-By).

---

### Task 9: Cleanup view, «Borrar todo» and the single confirmation

**Files:**
- Modify: `Sources/Airy/Cleanup/CleanupView.swift`, `CleanupRow.swift`, `ConfirmSheet.swift`, `CleanupFlow.swift`, `Sources/Airy/AppModel.swift` (scanner with `ProjectArtifactSource`, Docker context and `inaccessible`)

**Interfaces:**
- Consumes: Task 7 (`CleanupBoard.*`, `RiskExplanation`, `CleanupRunSummary.successes`), Task 8 (profile), plan 1 Task 9 (`AppModel.perform(_:context:)`, `preview(_:)`, per-row preview), `RiskBadge(risk:compact:reason:)`, `Theme.Airy`, `.leafAway`, `CleanupFlow.gust`/`batchFreed` (plan 2).
- Produces: `CleanupFlow.confirm(_ request:, excluding removed: Set<String>, model:)` (with `removed` empty it behaves as now and still fires plan 2's `gust` and `batchFreed` with the remaining items); `CleanupFlow.ConfirmRequest.Kind.items` stays the same.

Behavior and texts:
- **Header** (HeroCard): «Puedes liberar (hasta) X» (You can free (up to) X), as now. The button becomes «Seleccionar todo lo verde» (`greenSelection`, R7), and next to it «Seleccionar todo» (`fullSelection`) with secondary style. Both are disabled if empty or `flow.isBusy`.
- **Initial selection:** `nextSelection(current:seen:)` at the end of each detection (`@ViewState seen`).
- **Groups:** `GroupSection` uses `group.title` (label). Short texts:
  - green: «Se vuelve a crear solo: bórralo sin miedo.» (It is created again by itself: delete it without fear.)
  - amber: «Se puede borrar, pero pierdes algo: lee qué.» (It can be deleted, but you lose something: read what.)
  - red: «No se borra: Airy te dice por qué.» (It is not deleted: Airy tells you why.)
  Each group has «Seleccionar este grupo» (Select this group) (green and amber only).
- **«Solo revisar»:** final section, with the title «Solo revisar» and the text «Airy te dice qué es y cómo hacerlo tú; aquí no hay botón de borrar.» (Airy tells you what it is and how to do it yourself; there is no delete button here.). Each row shows `RiskBadge`, the size or the `sizeNote`, the `reviewHint` and a «Mostrar en Finder» (Show in Finder) button (`NSWorkspace.activateFileViewerSelecting`; it is not destructive).
- **Row:**
  - `RiskBadge(risk: item.risk, reason: RiskExplanation.why(item))` **always** (plan 2: `risk.label` text).
  - Under the title, a line with `RiskExplanation.why(item)` in `Theme.Airy.riskInk(item.risk)` for red and amber, and secondary for green.
  - Cleaned rows leave with `.transition(.leafAway)` (plan 2), which respects «Reducir movimiento».
  - Chip «Para ti» (For you) when `highlighted`.
  - `details`: the first 3, and «y N más» (and N more) if there are more.
  - `sizeText` with note.
  - Red rows have **no** checkbox nor any action button.
  - During the batch: the current row shows `ProgressView` and «Limpiando…» (Cleaning…); those in `queuedIDs`, «En cola» (Queued).
- **Selection bar:** «N seleccionados · X» (N selected · X), «Quitar selección» (Clear selection) and the main button `CleanupBoard.deleteAllTitle(selected)`, which opens `flow.requestClean(selected)`.
- **ConfirmSheet** (`.items`):
  - The title is «¿Borrar N elementos?» (Delete N items?).
  - The green list goes first and then, if there is amber, a **separate block** with background `Theme.color(for: .yourCall).opacity(0.10)`, amber border, title `CleanupBoard.reviewBlockTitle` and each row with its `why`.
  - **Every** row in the sheet has «Quitar» (Remove) (one click → `removed`); the amber block also has «Quitar todo lo ámbar» (Remove all the amber).
  - Each row states its method («Irá a la Papelera» (It will go to the Trash) / «Se ejecutará `docker container prune -f`» (`docker container prune -f` will be run), with plan 1's preview).
  - In `docker-containers` the names are listed: «Contenedores parados: a, b y c» (Stopped containers: a, b and c).
  - The total is recomputed without what was removed. If nothing is left, the button is disabled.
  - The button says «Borrar N · X» (Delete N · X). Return only confirms if everything goes to the Trash, as now.
  - On confirming: `flow.confirm(request, excluding: removed, model:)`.
- **Result** (ResultBanner): headline as now; below, «Hecho» (Done) with `successes` (title · text) and «No se pudo» (Could not) with `problems` (title: reason).
- **AppModel:** the scanner receives the live classifier (plan 1) and the analysis's `inaccessible` (Task 11). The executor receives `processListing` (Task 1).
- **DEBUG** (`AIRY_CLEANUP_SCRIPT`): new steps `selectgreen`, `selectall` and `deleteall`. `deleteall` only **opens** the sheet; there is no step that confirms.

- [ ] **Step 1: Verify build** — `swift build` → it compiles.
- [ ] **Step 2: Implement** as described (without `.fixedSize(horizontal:false,vertical:true)` in the new texts).
- [ ] **Step 3: Verify** — `swift build && swift test 2>&1 | tail -3` → green. Manual test in DEBUG, with its own support folder and test folder:
  1. `mkdir -p ~/Library/Logs/AiryPrueba && dd if=/dev/zero of=~/Library/Logs/AiryPrueba/x bs=1m count=5`.
  2. `AIRY_SUPPORT_DIR=$(mktemp -d) AIRY_CLEANUP_SCRIPT="section:cleanup@2,selectall@6,deleteall@8,cancel@14" .build/debug/Airy &`; save `$!`.
  3. Check in an own screenshot (DebugSnapshot): groups with the three labels, «Solo revisar» at the end, the «Borrar todo · …» bar and the sheet with a separate amber block.
  4. **Do not confirm anything.** Stop with `kill <PID>`.
- [ ] **Step 4: Commit** — `feat: Cleanup with multiple selection, «Borrar todo» and a single confirmation with an amber block` (+ Co-Authored-By).

---

### Task 10: «¿Cómo usas tu Mac?» at first launch and in Settings

**Files:**
- Create: `Sources/Airy/Profile/ProfileSheet.swift`
- Modify: `Sources/Airy/Shell/RootView.swift` (presentation), `Sources/Airy/Settings/SettingsView.swift` (plan 1 Task 9: new section), `Sources/Airy/AppModel.swift` (`setProfiles(_:)`)

**Interfaces:**
- Consumes: `AppModel.settings`, `updateSettings(_:)`, `settingsLoad` (plan 1 Task 9); `AirySettings.profilePrompted` (Task 8).
- Produces: `AppModel.setProfiles(_ profiles: Set<UsageProfile>)`, which saves `profiles`, sets `profilePrompted = true` and calls `refreshCleanup()`. `struct ProfilePicker: View { @Binding var selection: Set<UsageProfile> }`, shared by the sheet and Settings.

Texts and behavior:
- Sheet (≈ 560 pt wide): title «¿Cómo usas tu Mac?»; subtitle «Elige todo lo que encaje. Airy pondrá primero y marcará lo que más te sirve. Nunca cambia lo que es seguro borrar.» (Choose everything that fits. Airy will put first and mark what is most useful to you. It never changes what is safe to delete.).
- Six selectable cards with an SF symbol, title `UsageProfile.title` and a line:
  - Programo (I code) «Docker, Node, Python, Xcode y proyectos viejos» (Docker, Node, Python, Xcode and old projects);
  - Diseño, foto o vídeo (Design, photo or video) «Cachés de Adobe, Final Cut y DaVinci» (Adobe, Final Cut and DaVinci caches);
  - Uso IA en local (I use local AI) «Modelos de Ollama, LM Studio y Hugging Face» (Ollama, LM Studio and Hugging Face models);
  - Juego (I game) «Juegos y bottles sin abrir hace meses» (Games and bottles not opened for months);
  - Música y audio (Music and audio) «Librerías de sonidos de Logic y GarageBand» (Logic and GarageBand sound libraries);
  - Uso básico (Basic use) «Navegadores, registros y descargas viejas» (Browsers, logs and old downloads).
- Buttons: «Ahora no» (Not now) (`setProfiles([])`) and «Continuar» (Continue) (`setProfiles(selection)`).
- It is presented from `RootView` only once when `!model.settings.profilePrompted && !model.settingsLoad.isUnreadable`, after the migration and outside the launch animation (plan 2).
- Settings › «Cómo usas tu Mac»: the same `ProfilePicker` (saves on change). Footer: «Solo cambia el orden y lo que se marca de entrada; nunca lo que es seguro borrar.» (It only changes the order and what is checked from the start; never what is safe to delete.).
- DEBUG: `profile` step of `AIRY_CLEANUP_SCRIPT`, which opens the sheet (and `cancel` closes it).

- [ ] **Step 1: Write the failing test** — in `ProfileTests`: `promptOnlyWhenNotPromptedAndReadable()` over a pure function `ProfilePrompt.shouldShow(_ load: SettingsLoad) -> Bool` (in `DiskMapCore/Settings/AirySettings.swift`): `.missing` → true; `.loaded(prompted)` → false; `.unreadable` → false.
- [ ] **Step 2: Run** — `swift test --filter ProfileTests` → FAIL.
- [ ] **Step 3: Implement** the function, the sheet, the Settings section and `setProfiles`.
- [ ] **Step 4: Verify** — `swift test 2>&1 | tail -3` → green. Manual test: `AIRY_SUPPORT_DIR=$(mktemp -d) .build/debug/Airy &`; the sheet appears; choose «Programo» and «Continuar»; in Cleanup, the development items go first with «Para ti»; reopen with the same `AIRY_SUPPORT_DIR` ⇒ it does not appear again; Settings (⌘,) shows it checked. Stop by PID.
- [ ] **Step 5: Commit** — `feat: «¿Cómo usas tu Mac?» profile at first launch and in Settings` (+ Co-Authored-By).

---

### Task 11: Analysis honesty («+») and labels in the Map

**Files:**
- Create: `Sources/DiskMapCore/Scan/ScanHonesty.swift`
- Modify: `Sources/DiskMapCore/Model/Formatting.swift`, `Sources/DiskMapCore/Cleanup/CleanupScanner.swift` (`sizeIsPartial`), `Sources/DiskMapCore/MCP/Tools/ReadTools.swift` (`list_largest` and `get_disk_summary`), `Sources/Airy/AppModel.swift` (`partialIndex`), `Sources/Airy/Map/HoverCard.swift`, `Sources/Airy/Map/MapView.swift` (disk card / map footer)
- Test: `Tests/DiskMapCoreTests/ScanHonestyTests.swift`, `MCPReadToolTests.swift`

**Interfaces:**
- Consumes: `ScanResult.inaccessible` (already exists and is persisted in the index), `RiskExplanation` (Task 7), `AppModel.classify(path:)` (plan 1 Task 9).
- Produces:
```swift
public enum ScanCompleteness: Sendable, Equatable {
    case complete, partial(unreadable: Int), unavailable
    public static func of(_ result: ScanResult?) -> ScanCompleteness
    public var label: String   // "Análisis completo" (Complete analysis) / "Análisis parcial: no se pudieron leer N carpetas" (Partial analysis: N folders could not be read) / "Sin análisis" (No analysis)
    public var jsonName: String   // "complete" | "partial" | "unavailable"
}
public struct PartialScanIndex: Sendable {
    public init(inaccessible: [String])            // sorts once
    public func isPartial(_ path: String) -> Bool  // some unreadable path is `path` or is inside it (binary search on the prefix)
}
extension Format { public static func bytes(_ value: Int64, partial: Bool) -> String }   // "12,3 GB+"
// CleanupScanner.findItems(scan:inaccessible:) with `inaccessible: [String] = []`: a size taken from the index
// for a partial path ⇒ item.sizeIsPartial = true
// list_largest: each child gains "size_partial": Bool; get_disk_summary gains "scan_status": jsonName
```
Interface:
- **HoverCard:** the size is shown with `Format.bytes(_, partial:)` and, if partial, with the help text «Airy no pudo leer todo lo que hay dentro: puede ocupar más.» (Airy could not read everything inside: it may take up more.). The risk comes from `model.classify(path:)`: `RiskBadge(risk:reason:)` and below it the line `RiskExplanation.why(risk:entry:protection:reason:nil,bytes:personal:)`.
- **Map:** the disk card or the footer show `ScanCompleteness.label` when it is not `.complete`, and the totals carry «+».
- **Cleanup:** `CleanupBoard.sizeText` adds «+» (Task 7 already anticipates it).

- [ ] **Step 1: Write the failing tests**

```swift
@Test func completenessFromResult()                      // [] → .complete; 3 paths → .partial(3); nil → .unavailable
@Test func partialIndexMatchesSelfAndAncestorsOnly() {
    let i = PartialScanIndex(inaccessible: ["/Users/a/Library/Mail", "/Users/a/x"])
    #expect(i.isPartial("/Users/a") && i.isPartial("/Users/a/Library") && i.isPartial("/Users/a/Library/Mail"))
    #expect(!i.isPartial("/Users/a/Library/Caches") && !i.isPartial("/Users/a/xy"))
}
@Test func plusSuffix()                                  // Format.bytes(1_000_000_000, partial: true).hasSuffix("+")
@Test func cleanupItemFromPartialIndexIsMarked() async
@Test func listLargestAndSummaryReportPartial() async    // MCP: child with an unreadable path inside → size_partial true; scan_status "partial"
```

- [ ] **Step 2: Run** — `swift test --filter ScanHonestyTests` → FAIL.
- [ ] **Step 3: Implement** according to Interfaces.
- [ ] **Step 4: Verify** — `swift test 2>&1 | tail -3` → green. Manual (DEBUG, own support folder): hover over `~/Library` without Full Disk Access ⇒ size with «+» and a label with its "why". Stop by PID.
- [ ] **Step 5: Commit** — `feat: sizes with «+» if the analysis is partial and clear labels in the Map` (+ Co-Authored-By).

---

### Task 12: Final verification

**Files:** none new (only what the checks uncover).

- [ ] **Step 1: Tests** — `swift test 2>&1 | tail -3` → all green (those of plans 1–2 plus those of this plan).
- [ ] **Step 2: Rule tracing in the code:**
  - `grep -rn '"--volumes"\|volume prune' Sources` → only `CommandPolicy.swift` and its tests.
  - `grep -rn 'fixedSize(horizontal: false, vertical: true)' Sources/Airy` → no occurrences in files touched by this plan.
  - `grep -rn 'trashItem(' Sources` → only `CleanupExecutor.swift`.
- [ ] **Step 3: MCP smoke test against the real system, read-only** (resolution F11):
  1. `AIRY_SUPPORT_DIR=$(mktemp -d)`; send `initialize`, `tools/call list_cleanup_items` and `tools/call run_safe_cleanup_all {"dry_run": true}` to `.build/debug/airy-mcp`.
  2. Check that the new records present on this Mac come out, that Docker comes out blocked if the daemon is stopped, that no amber item appears in `results` and that there are only `would_*`/`blocked`.
  3. Check that nothing was moved or executed: real `runner` without cleanups (the temporary folder's log only has `dryRun: true`).
- [ ] **Step 4: App** — `bash scripts/build-app.sh` and `open build/Airy.app`. The controller decides with the user whether it is the installed one; if not, the DEBUG build is used with its own `AIRY_SUPPORT_DIR`. Review:
  - the profile sheet appears;
  - Cleanup shows the three labels, «Solo revisar», «Seleccionar todo lo verde / Seleccionar todo» and «Borrar todo · X GB»;
  - the confirmation sheet has a separate amber block and something can be removed with a click; then it is **cancelled**;
  - in the Map, the hover shows the label and its "why".

  Do not confirm any real cleanup without the user present. Stop by PID.
- [ ] **Step 5: Commit** (if there were corrections) — `fix: final review of plan 3 (aggressive cleanup and profile)` (+ Co-Authored-By).
