# DiskMap Phase 1 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Native macOS app "DiskMap" with Map (animated treemap), Cleanup (catalog + safe deletion) and AI Assistant (report + chat via Claude Code), packaged as an `.app` with its own icon.

**Architecture:** SwiftPM package with a UI-free `DiskMapCore` library (scanner, catalog, risk classification, treemap, cleanup, AI, persistence), fully tested with Swift Testing, and a SwiftUI `DiskMap` executable that only presents and animates. Every external effect (processes, open apps, the Trash file system) goes through protocols so it can be tested with doubles.

**Tech Stack:** Swift 6.4 (Command Line Tools, no Xcode), SwiftPM, SwiftUI + AppKit, Swift Testing (`import Testing`), `Canvas` for the treemap, Claude Code CLI 2.1.x.

**Spec:** `docs/superpowers/specs/2026-10-20-diskmap-design.md`

## Global Constraints

- Interface 100 % in **Spanish (Spain)**; sizes with `ByteCountFormatter` `.file` and locale `es_ES` ("1,5 GB").
- Build only with `swift build` / `swift test`; no Xcode. `swift-tools-version: 6.4`, minimum platform `.macOS(.v15)`.
- Files and folders → **Trash** (`FileManager.trashItem`), never permanent deletion, except for the "Vaciar Papelera" (Empty Trash) button pressed by the user.
- Tool caches → **their official command**; never delete their folders by hand.
- Confirmation before any deletion, showing what and how much.
- What is sent to the Trash does **not** count as freed until it is emptied ("En la Papelera: X GB" (In the Trash: X GB)).
- Sizes = **allocated space** (`st_blocks * 512`), hard links counted once, symbolic links not followed.
- Only paths, sizes, dates, types and catalog records go to the AI; **never file contents**. Claude is invoked with `--tools ""`.
- The AI can only propose actions from the closed catalog (`trash(path)`, `runCatalogCommand(id)`); if the AI and the catalog disagree, **the stricter risk wins**.
- Never "safe": personal files (`~/Documents`, `~/Desktop`, `~/Pictures`, `~/Movies`, `~/Music`, `~/Downloads`, `~/orca`, `~/Projects`), Docker volumes (always "No tocar" (Don't touch)), runtimes in use (`codex-primary-runtime`), `/System`.
- Do not clean the cache of an open app; ask to close it.
- Animations: zoom spring `.spring(response: 0.45, dampingFraction: 0.82)`; staggered entrance 12 ms per block, 0.6 s total maximum; target 120 fps.
- Palette by type (dark/light equal in hue): video `#FF375F`, images `#FF9F0A`, apps `#BF5AF2`, code `#0A84FF`, caches `#30D158`, AI models `#64D2FF`, containers/VM `#5E5CE6`, documents `#FFD60A`, system `#8E8E93`, other `#AC8E68`.
- Phase 2 (Uninstaller, Large & old, Duplicates, File types) appears in the sidebar **disabled with the label "Próximamente" (Coming soon)** (builder decision already made here).
- Bundle ID `local.diskmap.DiskMap`; data in `~/Library/Application Support/DiskMap`.

## Review Focus

1. **Firmlinks and links:** analyzing `/` on APFS must not count `/Users` twice (also visible as `/System/Volumes/Data/Users`) nor follow looping symbolic links → total ≈ used space reported by the volume. Test in Task 2 (`skipsSymlinkLoops`, `excludesSystemVolumesPrefix`).
2. **Paths with spaces, accents and ñ** (`Application Support`, `Música`, `diseño`) in commands and in prompts → always `Process` with an argument array, never a shell string; well-escaped JSON. Test in Task 6 (`commandArgumentsAreNotShellInterpolated`) and Task 7 (`contextKeepsUnicodePaths`).
3. **Claude absent, slow or with invalid JSON** → the rest of the app works; the assistant shows a clear state and a "Reintentar" (Retry) button; maximum time 120 s. Test in Task 7 (`reportFailsGracefullyOnInvalidJSON`, `reportTimesOut`).
4. **Files that disappear or lack permission mid-analysis** → they are skipped, counted as inaccessible and the analysis finishes. Test in Task 2 (`unreadableDirectoryIsReportedNotFatal`).
5. **Folders with tens of thousands of small files** (`node_modules`, `.git`) → the map groups the tiny ones into "Otros (N elementos)" (Other (N items)) and stays smooth; the index's RAM stays bounded. Test in Task 2 (`prunesSmallChildrenIntoAggregate`) and Task 4 (`groupsTinyEntriesIntoOthers`).

---

## File structure

```
DiskMap/
  Package.swift
  Sources/DiskMapCore/
    Model/FileNode.swift            tree node + ContentKind + Risk
    Model/Formatting.swift          byte and date formatting in Spanish
    Scan/DiskScanner.swift          parallel scanner
    Scan/FileKindClassifier.swift   type by extension/path
    Catalog/Catalog.swift           catalog model and loading
    Catalog/RiskPolicy.swift        risk rules and "the strictest wins"
    Layout/Treemap.swift            squarified + "Otros" grouping
    Persistence/IndexStore.swift    last-analysis index + history
    System/CommandRunner.swift      run processes, login PATH
    System/SystemProbes.swift       open apps, Full Disk Access, snapshots, Trash
    Cleanup/CleanupScanner.swift    detects cleanup items
    Cleanup/CleanupExecutor.swift   runs cleanups
    Cleanup/ReferenceChecker.swift  "is another project using it?"
    AI/ClaudeLocator.swift
    AI/AIContextBuilder.swift
    AI/AIAssistant.swift            report + chat
  Sources/DiskMapCore/Resources/catalog.json
  Sources/DiskMap/                  SwiftUI app (Task 8–11)
  Tests/DiskMapCoreTests/...
  scripts/make-icon.swift
  scripts/build-app.sh
  Resources/Info.plist
```

---

### Task 1: Package, model and formatting

**Files:**
- Create: `Package.swift`, `Sources/DiskMapCore/Model/FileNode.swift`, `Sources/DiskMapCore/Model/Formatting.swift`, `Sources/DiskMap/DiskMapApp.swift` (empty window "DiskMap"), `Tests/DiskMapCoreTests/ModelTests.swift`

**Interfaces:**
- Produces:
  - `public enum ContentKind: String, Codable, CaseIterable, Sendable { case video, images, apps, code, caches, aiModels, containers, documents, system, other }` with `public var title: String` ("Vídeo" (Video), "Imágenes" (Images), "Apps", "Código y proyectos" (Code and projects), "Cachés" (Caches), "Modelos de IA" (AI models), "Contenedores y VM" (Containers and VMs), "Documentos" (Documents), "Sistema" (System), "Otros" (Other)).
  - `public enum Risk: Int, Codable, Comparable, Sendable { case safe = 0, yourCall = 1, doNotTouch = 2 }` with `title` ("Borrar sin riesgo" (Safe to delete), "Depende de ti" (Up to you), "No tocar") and `public static func strictest(_ a: Risk, _ b: Risk) -> Risk`.
  - `public final class FileNode: @unchecked Sendable, Identifiable` with `id: Int`, `name: String`, `weak parent`, `children: [FileNode]`, `isDirectory: Bool`, `allocatedSize: Int64`, `lastModified: Date?`, `kind: ContentKind`, `kindBytes: [Int64]` (10 positions, index = `ContentKind.allCases`), `descendantCount: Int`, `aggregatedCount: Int` (>0 if the node is the "Otros" aggregate), `var path: String` (computed by walking up through `parent`), `var dominantKind: ContentKind`.
  - `public enum Format { static func bytes(_: Int64) -> String; static func relativeDate(_: Date?) -> String }`.

- [ ] **Step 1: Create `Package.swift`** with products: library `DiskMapCore` (resource `catalog.json` with `.process`), executable `DiskMap` (depends on `DiskMapCore`), test `DiskMapCoreTests`.
- [ ] **Step 2: Failing tests** in `ModelTests.swift`:
  - `strictestPicksHigher`: `Risk.strictest(.safe, .doNotTouch) == .doNotTouch`, `Risk.strictest(.yourCall, .safe) == .yourCall`.
  - `pathJoinsParents`: root `/` → `Users` → `ana` ⇒ `path == "/Users/ana"`.
  - `dominantKindUsesKindBytes`: `kindBytes` with video 10, code 30 ⇒ `.code`.
  - `formatsSpanishBytes`: `Format.bytes(1_500_000_000) == "1,5 GB"`.
- [ ] **Step 3:** `swift test` → FAIL (undefined types).
- [ ] **Step 4:** Implement the types.
- [ ] **Step 5:** `swift test` → PASS; `swift build` → the executable compiles.
- [ ] **Step 6:** `git add -A && git commit -m "feat: package and base model"`

---

### Task 2: Parallel scanner

**Files:**
- Create: `Sources/DiskMapCore/Scan/DiskScanner.swift`, `Sources/DiskMapCore/Scan/FileKindClassifier.swift`, `Tests/DiskMapCoreTests/ScannerTests.swift`

**Interfaces:**
- Consumes: `FileNode`, `ContentKind`.
- Produces:
  - `public struct ScanOptions: Sendable { roots: [URL]; excludedPrefixes: [String] = ["/System/Volumes", "/dev", "/Volumes", "/private/var/vm", "/.Spotlight-V100", "/.fseventsd"]; pruneThreshold: Int64 = 1_048_576 }` (if a `root` is inside `/Volumes`, that prefix is not excluded for it).
  - `public struct ScanProgress: Sendable { filesScanned: Int; bytesScanned: Int64; currentPath: String }`
  - `public struct ScanResult: Sendable { root: FileNode; inaccessible: [String]; duration: TimeInterval }`
  - `public final class DiskScanner: Sendable { init(options: ScanOptions); func scan(progress: @escaping @Sendable (ScanProgress) -> Void) async throws -> ScanResult }` — cancellable with `Task.cancel()`; `progress` at most every 100 ms.
  - `public enum FileKindClassifier { static func kind(forFileNamed: String) -> ContentKind; static func kind(forDirectoryPath: String) -> ContentKind? }`

Approach: `opendir/readdir` + `lstat` (do not follow links); size `st_blocks * 512`; hard links with `st_nlink > 1` deduplicated by `(st_dev, st_ino)` in a lock-protected set; traversal with a `TaskGroup` of width `ProcessInfo.activeProcessorCount * 2`; do not cross to a `st_dev` different from the root's unless it is another root. On closing each directory: children `< pruneThreshold` are merged into an aggregate child "Otros" (`aggregatedCount = n`), preserving `kindBytes`.

Classification by extension: video (`mp4 mov mkv avi m4v webm`), images (`jpg jpeg png heic gif tiff raw cr2 psd webp`), code (`swift py js ts rs go java c cpp h json lock`), AI models (`gguf safetensors pt pth bin ckpt onnx mlmodel npz ort`), containers (`raw` inside `com.docker.docker`, `vmdk qcow2 img dmg iso`), documents (`pdf doc docx xls xlsx ppt pptx key pages numbers txt md`). By folder: `*.app` → apps, `node_modules`/`.git`/`.venv`/`target`/`.build` → code, `Caches`/`.cache`/`DerivedData` → caches, `huggingface`/`.ollama`/`whisper` → aiModels, `com.docker.docker` → containers, `/System` `/usr` `/private` `/Library` → system.

- [ ] **Step 1: Failing tests** (each creates a temporary tree with `FileManager` in `FileManager.default.temporaryDirectory`):
  - `sumsAllocatedSizes`: two 3 MB files ⇒ `root.allocatedSize` between 6 MB and 6.1 MB.
  - `countsHardLinkOnce`: 5 MB file + hard link ⇒ total < 5.1 MB.
  - `sparseFileUsesAllocatedSize`: `ftruncate` to 1 GB without writing ⇒ < 1 MB.
  - `skipsSymlinkLoops`: link `a/loop -> ..` ⇒ the scan finishes and there is no node under `loop`.
  - `excludesSystemVolumesPrefix`: `excludedPrefixes` contains the path of a subfolder ⇒ that subfolder does not appear.
  - `unreadableDirectoryIsReportedNotFatal`: subfolder with `chmod 000` ⇒ `inaccessible` contains it and the result includes its siblings.
  - `prunesSmallChildrenIntoAggregate`: 500 files of 1 KB + one of 2 MB ⇒ 2 children, one with `aggregatedCount == 500`.
  - `classifiesKinds`: `kind(forFileNamed: "peli.MOV") == .video`, `kind(forDirectoryPath: "/x/Foo.app") == .apps`, `kind(forFileNamed: "m.gguf") == .aiModels`.
- [ ] **Step 2:** `swift test --filter ScannerTests` → FAIL.
- [ ] **Step 3:** Implement `FileKindClassifier` and `DiskScanner`.
- [ ] **Step 4:** `swift test --filter ScannerTests` → PASS.
- [ ] **Step 5: Real check:** a small manual test disabled by default (`@Test(.enabled(if: ProcessInfo.processInfo.environment["DISKMAP_REAL"] != nil))`) that scans `~` and prints time and total. Run `DISKMAP_REAL=1 swift test --filter realHome -c release` → note the time (target: home folder < 60 s on the M4 Pro).
- [ ] **Step 6:** `git commit -am "feat: parallel scanner with real size"`

---

### Task 3: Catalog and risk policy

**Files:**
- Create: `Sources/DiskMapCore/Catalog/Catalog.swift`, `Sources/DiskMapCore/Catalog/RiskPolicy.swift`, `Sources/DiskMapCore/Resources/catalog.json`, `Tests/DiskMapCoreTests/CatalogTests.swift`

**Interfaces:**
- Produces:
  - `public struct CatalogEntry: Codable, Sendable, Identifiable { id: String; title: String; explanation: String; whoCreatesIt: String; regenerates: Bool; risk: Risk; kind: ContentKind; paths: [String]; cleanup: CleanupMethod; mustBeClosed: [String]; referenceCheck: String? }`
    - `paths`: patterns with `~` and `*` (e.g. `~/.cache/codex-runtimes/codex-runtime-install-*`).
    - `mustBeClosed`: bundle IDs.
    - `referenceCheck`: string to search for in projects, with `{name}` = name of the folder found.
  - `public enum CleanupMethod: Codable, Sendable { case trash; case command(executable: String, arguments: [String], sizeProbe: [String]?); case info }` (`info` = display only, no action).
  - `public struct Catalog: Sendable { entries: [CatalogEntry]; static func bundled() throws -> Catalog; func match(path: String, home: String) -> CatalogEntry?; func entry(id: String) -> CatalogEntry? }`
  - `public enum RiskPolicy { static func minimumRisk(forPath: String, home: String) -> Risk; static func effectiveRisk(path: String, home: String, catalog: Risk?, ai: Risk?) -> Risk }` — `effectiveRisk` = the strictest of the three; with neither catalog nor AI ⇒ at least `.yourCall`.

Minimum `catalog.json` entries (explanations in plain Spanish, one or two sentences):

| id | paths / command | risk | cleanup |
|---|---|---|---|
| `docker-build-cache` | `docker builder prune -a -f`; probe `docker system df --format {{json .}}` (Build Cache row, Reclaimable) | safe | command |
| `docker-volumes` | `docker system df` (Local Volumes) | doNotTouch | info |
| `docker-images` | `docker system df` (Images) | yourCall | info |
| `homebrew` | `brew cleanup --prune=all -s`; path `~/Library/Caches/Homebrew` | safe | command |
| `pip` | `pip3 cache purge`; `~/Library/Caches/pip` | safe | command |
| `uv` | `uv cache clean`; `~/.cache/uv` | safe | command |
| `pnpm` | `pnpm store prune`; `~/Library/pnpm/store` and `~/Library/Caches/pnpm` | safe | command |
| `npm` | `npm cache clean --force`; `~/.npm/_cacache` | safe | command |
| `cargo` | `~/.cargo/registry`, `~/.cargo/git` | safe | trash |
| `conda` | `conda clean --all -y` (executable `~/anaconda3/bin/conda` or `~/miniconda3/bin/conda`); `~/anaconda3/pkgs` | safe | command |
| `huggingface-model` | `~/.cache/huggingface/hub/models--*`, `datasets--*`; referenceCheck `{name}` without the `models--` prefix, with `--` → `/` | yourCall | trash |
| `ollama-models` | `~/.ollama/models` | yourCall | info (in phase 1 `ollama rm <model>` is explained) |
| `whisper-cache` | `~/.cache/whisper` | yourCall | trash |
| `playwright` | `~/Library/Caches/ms-playwright` | safe | trash |
| `brave-cache` | `~/Library/Caches/BraveSoftware`, `~/Library/Caches/com.brave.Browser`; mustBeClosed `com.brave.Browser` | safe | trash |
| `chrome-cache` | `~/Library/Caches/Google/Chrome`; mustBeClosed `com.google.Chrome` | safe | trash |
| `safari-cache` | `~/Library/Caches/com.apple.Safari`; mustBeClosed `com.apple.Safari` | safe | trash |
| `spotify-cache` | `~/Library/Caches/com.spotify.client`; mustBeClosed `com.spotify.client` | safe | trash |
| `xcode-deriveddata` | `~/Library/Developer/Xcode/DerivedData` | safe | trash |
| `xcode-simulators` | `xcrun simctl delete unavailable` | safe | command |
| `user-logs` | `~/Library/Logs/*` | safe | trash |
| `codex-stale-installs` | `~/.cache/codex-runtimes/codex-runtime-install-*` | safe | trash |
| `codex-runtime` | `~/.cache/codex-runtimes/codex-primary-runtime` | doNotTouch | info |
| `claude-vm` | `~/Library/Application Support/Claude/vm_bundles`; mustBeClosed `com.anthropic.claudefordesktop` | yourCall | trash |
| `time-machine-snapshots` | probe `tmutil listlocalsnapshots /` | yourCall | command `tmutil thinlocalsnapshots / 999999999999 4` |

- [ ] **Step 1: Failing tests:**
  - `bundledCatalogLoads`: `Catalog.bundled().entries.count >= 25`, unique ids and all explanations non-empty.
  - `matchesGlob`: `match(path: home+"/.cache/codex-runtimes/codex-runtime-install-ab12", home:)?.id == "codex-stale-installs"`.
  - `primaryRuntimeIsNotStale`: `match(path: home+"/.cache/codex-runtimes/codex-primary-runtime")?.id == "codex-runtime"`.
  - `personalFoldersNeverSafe`: `effectiveRisk(path: home+"/Documents/x", catalog: .safe, ai: .safe) == .yourCall`.
  - `aiCannotLowerRisk`: `effectiveRisk(path: home+"/.ollama/models", catalog: .yourCall, ai: .safe) == .yourCall`.
  - `systemIsDoNotTouch`: `minimumRisk(forPath: "/System/Library", home:) == .doNotTouch`.
  - `unknownDefaultsToYourCall`: `effectiveRisk(path: "/opt/x", catalog: nil, ai: nil) == .yourCall`.
- [ ] **Step 2:** `swift test --filter CatalogTests` → FAIL.
- [ ] **Step 3:** Implement and write `catalog.json` with all the entries in the table.
- [ ] **Step 4:** `swift test --filter CatalogTests` → PASS.
- [ ] **Step 5:** `git commit -am "feat: catalog of known paths and risk policy"`

---

### Task 4: Treemap

**Files:**
- Create: `Sources/DiskMapCore/Layout/Treemap.swift`, `Tests/DiskMapCoreTests/TreemapTests.swift`

**Interfaces:**
- Produces:
  - `public struct TreemapTile: Sendable, Identifiable { id: Int; rect: CGRect; node: FileNode? ; othersCount: Int }` (`node == nil` ⇒ "Otros (N elementos)" tile).
  - `public enum Treemap { static func squarify(values: [Double], in rect: CGRect) -> [CGRect]; static func tiles(for node: FileNode, in rect: CGRect, gap: CGFloat = 2, minTileArea: CGFloat = 36) -> [TreemapTile] }`
  - `tiles` sorts children by size, groups into one "Otros" tile those that would fall below `minTileArea`, applies `squarify` (Bruls et al.) and inserts `gap`.

- [ ] **Step 1: Failing tests:**
  - `areasAreProportional`: values `[6,6,4,3,2,2,1]` in 600×400 ⇒ area of each rect / total area = value / sum (tolerance 0.5 %).
  - `rectsStayInsideAndDontOverlap`: 200 random values with a fixed seed ⇒ all inside the rect and with no intersections of area > 0.01.
  - `aspectRatiosAreSquarish`: the same 7 values ⇒ worst aspect ratio < 3.
  - `groupsTinyEntriesIntoOthers`: node with 1 child of 1 GB and 5,000 children of 1 KB in 800×600 ⇒ ≤ 2 tiles and one with `othersCount == 5000`.
  - `emptyNodeGivesNoTiles`.
- [ ] **Step 2:** `swift test --filter TreemapTests` → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `swift test --filter TreemapTests` → PASS.
- [ ] **Step 5:** `git commit -am "feat: squarified treemap"`

---

### Task 5: Index persistence and history

**Files:**
- Create: `Sources/DiskMapCore/Persistence/IndexStore.swift`, `Tests/DiskMapCoreTests/IndexStoreTests.swift`

**Interfaces:**
- Consumes: `ScanResult`, `FileNode`.
- Produces:
  - `public struct CleanupRecord: Codable, Sendable { date: Date; title: String; bytes: Int64; wentToTrash: Bool }`
  - `public final class IndexStore: Sendable { init(directory: URL); func saveScan(_: ScanResult) throws; func loadScan() throws -> ScanResult?; func append(_: CleanupRecord) throws; func history() throws -> [CleanupRecord]; func totalFreed() throws -> Int64 }`
  - `totalFreed` adds up only records with `wentToTrash == false` plus the Trash emptyings (which are recorded as `wentToTrash == false`).

Format: tree flattened into parallel arrays (`parentIndex`, `name`, `size`, `kind`, `kindBytes`, `mtime`, `aggregatedCount`) with binary `PropertyListEncoder` and atomic write to `scan.plist`; history in `history.json`.

- [ ] **Step 1: Failing tests:**
  - `roundTripsTree`: 3-level tree ⇒ after saving and loading, paths, sizes and `kindBytes` are equal.
  - `missingIndexReturnsNil`.
  - `corruptIndexReturnsNilAndIsRemoved`: write garbage to `scan.plist` ⇒ `loadScan() == nil` and the file no longer exists.
  - `totalFreedIgnoresTrashPending`: records 1 GB (trash) + 2 GB (command) ⇒ `totalFreed() == 2 GB`.
- [ ] **Step 2:** FAIL → **Step 3:** implement → **Step 4:** PASS.
- [ ] **Step 5:** `git commit -am "feat: persistent index and cleanup history"`

---

### Task 6: System, detection and execution of cleanup

**Files:**
- Create: `Sources/DiskMapCore/System/CommandRunner.swift`, `Sources/DiskMapCore/System/SystemProbes.swift`, `Sources/DiskMapCore/Cleanup/CleanupScanner.swift`, `Sources/DiskMapCore/Cleanup/CleanupExecutor.swift`, `Sources/DiskMapCore/Cleanup/ReferenceChecker.swift`, `Tests/DiskMapCoreTests/CleanupTests.swift`

**Interfaces:**
- Consumes: `Catalog`, `CatalogEntry`, `CleanupMethod`, `RiskPolicy`, `IndexStore`, `FileNode`.
- Produces:
  - `public struct CommandOutput: Sendable { status: Int32; stdout: String; stderr: String }`
  - `public protocol CommandRunning: Sendable { func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> CommandOutput; func resolve(_ executable: String) async -> String? }`
  - `public struct ProcessRunner: CommandRunning`. `resolve` uses the login shell's PATH (`/bin/zsh -lc 'printf %s "$PATH"'`, cached), because GUI apps have a minimal PATH. It runs `Process` with an argument array and kills the process when `timeout` passes.
  - `public protocol SystemProbing: Sendable { func runningBundleIDs() -> Set<String>; func hasFullDiskAccess() -> Bool; func trashSize() -> Int64; func emptyTrash() throws -> Int64; func localSnapshots() async -> [String] }`
    - `hasFullDiskAccess`: tries to list `~/Library/Containers/com.apple.stocks` or `~/Library/Safari`; if it gives `EPERM`, there is no access.
    - `emptyTrash`: `removeItem` of each item in `~/.Trash`; if there is no permission, falls back to Finder AppleScript (`empty trash`).
  - `public struct CleanupItem: Sendable, Identifiable { id: String; entry: CatalogEntry; paths: [String]; bytes: Int64; risk: Risk; blockedByOpenApps: [String]; usedBy: [String] }`
  - `public struct CleanupScanner { init(catalog:, runner:, probes:, references:, home:); func findItems(scan: FileNode?) async -> [CleanupItem] }` — size from the index if the path is in it, otherwise recursive `lstat` of the path; for `command` with `sizeProbe`, its output is parsed; omits 0-byte items; if `usedBy` is not empty, the risk goes up to `.doNotTouch`.
  - `public struct ReferenceChecker: Sendable { init(roots: [String]); func references(to needle: String, timeout: TimeInterval) async -> [String] }` — searches text files < 1 MB under `~/Desktop`, `~/Documents`, `~/Projects`, `~/orca` (if they exist), excluding `node_modules .git .venv venv .build target Library`. 10 s limit; returns paths.
  - `public enum CleanupOutcome: Sendable { case freed(Int64), movedToTrash(Int64), blocked(reason: String), failed(String) }`
  - `public struct CleanupExecutor { init(runner:, probes:, store:); func execute(_ item: CleanupItem) async -> CleanupOutcome; func emptyTrash() async -> CleanupOutcome; func trashPaths(_ paths: [String], title: String) async -> CleanupOutcome }`
    - Refuses (`blocked`) if there are open apps from `mustBeClosed`, if the risk is `.doNotTouch` or if the method is `info`.
    - For `command`, measures the volume's free space before and after (`volumeAvailableCapacityForImportantUsage`) and returns `freed(difference)`.
    - Records a `CleanupRecord` for each execution.
    - Paths that require an administrator: `osascript -e 'do shell script "rm -f <path escaped with quoted form>" with administrator privileges'`, only for broken links outside `$HOME`.

- [ ] **Step 1: Failing tests**, with `FakeRunner` (records calls and returns fixed outputs) and `FakeProbes`:
  - `commandArgumentsAreNotShellInterpolated`: run `uv` with `FakeRunner` ⇒ recorded call `("/opt/homebrew/bin/uv", ["cache","clean"])`.
  - `blocksWhenAppOpen`: Spotify entry with `runningBundleIDs = ["com.spotify.client"]` ⇒ `.blocked` and the folder still exists.
  - `trashMovesNotDeletes`: temporary folder ⇒ `movedToTrash(n)` with n > 0, the original path no longer exists and there is no `freed`.
  - `doNotTouchIsNeverExecuted`: item with `.doNotTouch` ⇒ `.blocked`, zero calls to the runner.
  - `infoMethodIsNeverExecuted`.
  - `dockerProbeParsesReclaimable`: JSON output of `docker system df` with Build Cache `"Reclaimable":"29.89GB"` ⇒ `bytes ≈ 29_890_000_000`.
  - `missingToolSkipsItem`: `resolve("uv") == nil` ⇒ `uv` does not appear.
  - `referencedModelEscalatesRisk`: `ReferenceChecker` finds `mlx-community/whisper-small-mlx` in a temporary `config.toml` ⇒ the HF item has `risk == .doNotTouch` and non-empty `usedBy`.
  - `recordsHistory`: after `execute` of a command ⇒ `store.history().count == 1`.
- [ ] **Step 2:** `swift test --filter CleanupTests` → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `swift test --filter CleanupTests` → PASS.
- [ ] **Step 5:** `git commit -am "feat: safe detection and execution of cleanups"`

---

### Task 7: AI Assistant (report and chat)

**Files:**
- Create: `Sources/DiskMapCore/AI/ClaudeLocator.swift`, `Sources/DiskMapCore/AI/AIContextBuilder.swift`, `Sources/DiskMapCore/AI/AIAssistant.swift`, `Tests/DiskMapCoreTests/AITests.swift`

**Interfaces:**
- Consumes: `CommandRunning`, `FileNode`, `CleanupItem`, `Catalog`, `RiskPolicy`.
- Produces:
  - `public enum ClaudeLocator { static func candidates(home: String) -> [String]; static func locate(override: String?, runner: CommandRunning) async -> String? }`
    - Candidates in order: `override`, `~/.local/bin/claude`, `~/.claude/local/claude`, `/opt/homebrew/bin/claude`, `/usr/local/bin/claude`, `~/.npm-global/bin/claude`.
    - They are accepted if `--version` contains "Claude Code" and the file does not contain `cmux-claude-wrapper`.
  - `public enum AIContextBuilder { static func context(scan: FileNode?, items: [CleanupItem], catalog: Catalog, home: String, maxNodes: Int = 400) -> String }`
    - JSON with: disk (total/free), the `maxNodes` largest nodes down to depth 6 (path with `~`, bytes, type, last change, catalog id if it matches) and the cleanup items.
    - Metadata only.
  - `public struct AIRecommendation: Codable, Sendable, Identifiable { id: String; path: String; verdict: Risk; reason: String; bytes: Int64; action: AIAction? }`
  - `public enum AIAction: Codable, Sendable { case trash(path: String); case runCatalogCommand(id: String) }`
  - `public struct AIReport: Codable, Sendable { summary: String; recommendations: [AIRecommendation]; reclaimableBytes: Int64 }`
  - `public enum AIError: Error { case notInstalled, timedOut, invalidResponse(String), failed(String) }`
  - `public struct AIAssistant { init(claudePath:, runner:, catalog:, home:); func report(context: String) async throws -> AIReport; func chat(history: [ChatMessage], context: String) -> AsyncThrowingStream<String, Error> }`
  - `public struct ChatMessage: Codable, Sendable { role: Role; text: String }`, with `enum Role { user, assistant }`.

Invocation (exact arguments):
- Base: `-p --tools "" --strict-mcp-config --disable-slash-commands --no-session-persistence --system-prompt <prompt>`.
- Report: base + `--output-format json --json-schema <AIReport schema>`; read `structured_output` from the result JSON.
- Chat: base + `--output-format stream-json --verbose --include-partial-messages`; emit the text of the `content_block_delta`s; send the full history on each turn.
- Prompt via `stdin`. 120 s timeout.

System prompt (Spanish): it is DiskMap's assistant; it only sees metadata; classifies into `safe/yourCall/doNotTouch`; never recommends deleting personal files, Docker volumes or anything under `/System`; actions can only be `trash` of a path present in the context or `runCatalogCommand` with a catalog id; explains in plain language, as to a non-technical person.

Report post-validation, always in code:
- Recommendations whose path is not in the context are dropped.
- Actions with an id that does not exist in the catalog are dropped.
- `verdict = RiskPolicy.effectiveRisk(path:, catalog:, ai: verdict)`.
- If `verdict != .safe`, the `trash` `action` is removed. It remains available after explicit confirmation in the UI only for `.yourCall`.

- [ ] **Step 1: Failing tests** (with `FakeRunner` returning fixed JSON):
  - `locatorSkipsCmuxShim`: candidate whose content contains `cmux-claude-wrapper` ⇒ discarded.
  - `invokesWithoutTools`: the arguments of `report` contain `"--tools"` followed by `""` and `"--json-schema"`.
  - `contextHasNoFileContents`: temporary file with the text "SECRETO" (SECRET) ⇒ the context does not contain "SECRETO" and does contain its path.
  - `contextKeepsUnicodePaths`: folder `Música/diseño ñ` ⇒ appears intact in the JSON and the JSON can be parsed.
  - `contextIsBounded`: 10,000 nodes ⇒ at most 400 in the context.
  - `reportDropsUnknownPaths` and `reportDropsUnknownCatalogIds`.
  - `reportCannotLowerRisk`: the AI says `safe` for `~/Documents/a.pdf` ⇒ `yourCall` and no action.
  - `reportFailsGracefullyOnInvalidJSON`: output `"hola"` ⇒ `AIError.invalidResponse`.
  - `reportTimesOut`: the runner throws a timeout ⇒ `AIError.timedOut`.
  - `chatStreamsDeltas`: three `stream-json` lines with deltas "Ho", "la", "!" ⇒ the stream emits those three strings.
- [ ] **Step 2:** `swift test --filter AITests` → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `swift test --filter AITests` → PASS.
- [ ] **Step 5: Optional real test:** `DISKMAP_REAL=1 swift test --filter realClaudeReport` with a small context ⇒ returns a valid `AIReport`.
- [ ] **Step 6:** `git commit -am "feat: AI assistant with safe report and chat"`

---

### Task 8: App skeleton, state and design

**Files:**
- Create: `Sources/DiskMap/DiskMapApp.swift` (replaces the empty window), `Sources/DiskMap/AppModel.swift`, `Sources/DiskMap/Design/Theme.swift`, `Sources/DiskMap/Design/Components.swift`, `Sources/DiskMap/Shell/RootView.swift`, `Sources/DiskMap/Shell/Sidebar.swift`, `Sources/DiskMap/Shell/FullDiskAccessBanner.swift`, `Sources/DiskMap/Shell/ScanProgressView.swift`, `Tests/DiskMapCoreTests/AppModelTests.swift` (the navigation model lives in `DiskMapCore/UIState/MapNavigation.swift` so it can be tested)

**Interfaces:**
- Consumes: all of `DiskMapCore`.
- Produces:
  - `@MainActor @Observable final class AppModel` with:
    - `section: Section` (`.map, .cleanup, .assistant`, plus `.uninstaller, .largeOld, .duplicates, .types` disabled).
    - `scan: ScanResult?`, `progress: ScanProgress?`, `isScanning`, `cleanupItems: [CleanupItem]`, `trashBytes: Int64`, `totalFreed: Int64`, `hasFullDiskAccess: Bool`, `navigation: MapNavigation`.
    - `func startScan()`: loads the index first, then re-analyzes in the background and saves.
    - `func refreshCleanup()`, `func perform(_ item: CleanupItem) async -> CleanupOutcome`, `func emptyTrash() async`.
  - `public struct MapNavigation: Sendable { private(set) var stack: [FileNode]; var current: FileNode?; mutating func zoom(into: FileNode); mutating func zoomOut(); mutating func jump(to index: Int); var breadcrumb: [String] }`
  - `Theme`: `ContentKind` colors (values from Global Constraints), `Theme.zoomSpring`, `Theme.stagger(index:)`.
  - `Components`: `GlassCard`, `RiskBadge`, `BytesCounter` (number that counts up with `contentTransition(.numericText())`), `PrimaryButton`.

Window:
- `NavigationSplitView` with a translucent `.sidebar`, `.windowStyle(.hiddenTitleBar)`, minimum size 1100×720.
- At the bottom, the sidebar shows a disk card with:
  - Usage ring distinguishing "Tus archivos" (Your files), "Sistema y purgable" (System and purgeable) (total − free − analyzed; free according to `volumeAvailableCapacityForImportantUsageKey`) and "Libre" (Free).
  - "En la Papelera: X GB" and a "Vaciar Papelera" button.
  - "Liberado en total: X" (Total freed: X).
- Above it, a disk selector: "Macintosh HD" by default, plus the external volumes from `FileManager.mountedVolumeURLs(includingResourceValuesForKeys:options: [.skipHiddenVolumes])` that are not read-only. Choosing one launches `startScan()` with that volume as `root`; `AppModel.selectedVolume: URL`.
- Full Disk Access banner with a button that opens `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`.
- Analysis progress: animated ring + file and GB counter + current path in dimmed monospace.

- [ ] **Step 1: Failing tests** for `MapNavigation`:
  - `zoomPushesAndBreadcrumb`: zoom into `Users` and then `ana` ⇒ `breadcrumb == ["Macintosh HD","Users","ana"]`.
  - `zoomOutAtRootIsNoop`.
  - `jumpTruncatesStack`: `jump(to: 0)` ⇒ `current` is the root.
- [ ] **Step 2:** FAIL → **Step 3:** implement `MapNavigation`, `AppModel`, theme, components and window structure → **Step 4:** PASS.
- [ ] **Step 5: Verify by hand:** `swift run DiskMap`.
  - The window opens with the sidebar and the phase 2 sections greyed out with "Próximamente".
  - The analysis starts with animated progress.
  - Capture with `screencapture -l $(osascript -e 'tell app "DiskMap" to id of window 1') shot.png` or `screencapture -x`; review the image.
- [ ] **Step 6:** `git commit -am "feat: app structure, theme and state"`

---

### Task 9: Map view

**Files:**
- Create: `Sources/DiskMap/Map/MapView.swift`, `Sources/DiskMap/Map/TreemapCanvas.swift`, `Sources/DiskMap/Map/HoverCard.swift`, `Sources/DiskMap/Map/Breadcrumb.swift`, `Sources/DiskMap/Map/KindLegend.swift`

**Interfaces:**
- Consumes: `Treemap.tiles`, `MapNavigation`, `Catalog.match`, `RiskPolicy`, `Theme`, `AppModel`.

Behavior:
- **Drawing:** `TreemapCanvas` draws with `Canvas` (+ `drawingGroup()`, which uses Metal).
  - Each tile is a rounded rect (radius 8, or 4 if it measures under 60 pt), with a gradient of the type's color (lighter at the top left) and a 1 pt inner border of white at 12 %.
  - Text (name + size) only if the tile measures at least 70×36.
  - The "Otros" tile carries a grey striped pattern.
- **Entrance:** after an analysis or a zoom, each tile appears with scale 0.85→1 and opacity 0→1, delayed by `Theme.stagger(index:)`. The order of appearance goes from the center outward.
- **Zoom:**
  - On click, the clicked tile is interpolated with `Theme.zoomSpring` from its rect to the whole canvas. Meanwhile, the others fade out and scale relative to it. Then the children appear with the staggered entrance.
  - To go out: Esc, Cmd+[, two-finger swipe gesture or click on the breadcrumb. It is the inverse animation.
- **On hover:**
  - The tile lights up (brightness +8 %, shadow) and a glass `HoverCard` follows the mouse with: name, path, size, percentage of the parent, last change, type, risk badge and catalog explanation or "Pregúntale al asistente" (Ask the assistant).
  - Right click opens a menu: "Mostrar en Finder" (Show in Finder), "Explicar con IA" (Explain with AI) (opens the chat with the question) and "Mover a la Papelera…" (Move to the Trash…) (only if the risk is not `.doNotTouch`, with confirmation).
- **Legend:** `KindLegend` with chips per type showing the GB of the current node. Hovering over a chip dims the tiles of other types.
- **Performance:** the layout is computed off the main thread and cached per node and size.

- [ ] **Step 1:** Implement the views.
- [ ] **Step 2: Verify by hand** with `swift run -c release DiskMap` on the real disk:
  - Check the staggered entrance, the zoom in and out, the breadcrumb, the hover card with explanations and the legend.
  - Take screenshots and review them.
  - Check that the zoom does not stutter: Instruments is not available, so it is measured with a debug FPS counter (`TimelineView(.animation)`) activated with the environment variable `DISKMAP_FPS=1`. Target: ≥ 100 fps on the M4 Pro.
- [ ] **Step 3:** `git commit -am "feat: animated block map"`

---

### Task 10: Cleanup view

**Files:**
- Create: `Sources/DiskMap/Cleanup/CleanupView.swift`, `Sources/DiskMap/Cleanup/CleanupRow.swift`, `Sources/DiskMap/Cleanup/ConfirmSheet.swift`, `Sources/DiskMap/Cleanup/FreedCelebration.swift`

**Interfaces:**
- Consumes: `AppModel.cleanupItems`, `AppModel.perform`, `AppModel.emptyTrash`, `CleanupOutcome`, `Theme`, `Components`.

Behavior:
- **Header:** "Puedes liberar X" (You can free X) with `BytesCounter` (only adds up the `.safe` items) and a "Limpiar todo lo seguro" (Clean everything safe) button.
- **Groups:** "Borrar sin riesgo", "Depende de ti" and "No tocar", with `GlassCard` cards. Each row carries an SF Symbol icon per type, title, explanation, who creates it, whether it regenerates, size, risk badge, selection checkbox and a notice if it is blocked ("Cierra Spotify para limpiar esto" (Close Spotify to clean this), with a "Cerrar Spotify" (Close Spotify) button that uses `NSRunningApplication.terminate()`) or if a project uses it ("Lo usa: …" (Used by: …)).
- `.doNotTouch` rows have no checkbox.
- **Confirmation:** before executing, a sheet opens with the list of what will be done and the method ("A la Papelera" (To the Trash) or "Comando oficial: `docker builder prune -a -f`" (Official command: …)).
- **After executing:**
  - If space was freed: restrained celebration (a ring that fills + `BytesCounter` + soft particles for 1.2 s) and the row collapses with a spring.
  - If it went to the Trash: "En la Papelera" is updated.
- **Empty Trash:** from the sidebar card, with confirmation. If afterwards the volume's free space does not rise ≥ 80 % of what was expected and `localSnapshots()` is not empty, a notice is shown explaining Time Machine snapshots and offering the `time-machine-snapshots` entry.

- [ ] **Step 1:** Implement the views.
- [ ] **Step 2: Verify by hand:**
  - Create the fake folder `~/Library/Logs/DiskMapPrueba` (DiskMapTest) with a 50 MB file. It must appear in "Borrar sin riesgo" (`user-logs`). On cleaning it, it must go to the Trash and the counter must update.
  - Open Spotify ⇒ its row appears blocked.
  - Screenshots.
- [ ] **Step 3:** `git commit -am "feat: cleanup section with safe deletion"`

---

### Task 11: AI Assistant view

**Files:**
- Create: `Sources/DiskMap/Assistant/AssistantView.swift`, `Sources/DiskMap/Assistant/ReportView.swift`, `Sources/DiskMap/Assistant/ChatView.swift`, `Sources/DiskMap/Assistant/ClaudeMissingView.swift`

**Interfaces:**
- Consumes: `AIAssistant`, `AIContextBuilder`, `ClaudeLocator`, `AIReport`, `AIAction`, `AppModel`.

Behavior:
- **Selector:** segmented between "Informe" (Report) and "Chat".
- **Report:**
  - "Analizar con IA" (Analyze with AI) button. While it works, an animated shimmer is shown (a gradient sweeping across some skeleton cards).
  - The result appears with a staggered entrance in the three risk columns. At the top, the summary and "Recuperable: X" (Recoverable: X).
  - Each recommendation has the button for its action, which goes through the same `ConfirmSheet` and through `AppModel.perform` or `trashPaths`.
- **Chat:**
  - Messages-style bubbles. The text arrives streaming with a blinking cursor.
  - Initial suggestions as chips: "¿Qué ocupa más?" (What takes up the most?), "¿Qué puedo borrar sin riesgo?" (What can I safely delete?), "¿Qué es ~/Library/Containers?" (What is ~/Library/Containers?).
  - When the answer mentions a path from the context, it appears as a chip with a "Ver en el mapa" (View on the map) button, which switches to `.map` and zooms to that path.
- **Without Claude:** `ClaudeMissingView` explains in one sentence that Claude Code is needed and offers "Elegir ejecutable…" (Choose executable…) (with `NSOpenPanel`; saved in `UserDefaults` as `claudePath`).
- **Errors:** card with a clear message and a "Reintentar" button.

- [ ] **Step 1:** Implement the views.
- [ ] **Step 2: Verify by hand** with the real disk:
  - Generate the report. Check that nothing personal appears as "safe" and that Docker volumes come out under "No tocar".
  - Ask two questions in the chat.
  - Temporarily rename `claudePath` to a nonexistent path ⇒ `ClaudeMissingView` appears.
  - Screenshots.
- [ ] **Step 3:** `git commit -am "feat: AI assistant with report and chat"`

---

### Task 12: Icon, packaging and stable signing

**Files:**
- Create: `scripts/make-icon.swift`, `scripts/build-app.sh`, `Resources/Info.plist`

**Interfaces:**
- Consumes: the `DiskMap` executable in release mode.

Details:
- **`make-icon.swift`:** draws a 1024×1024 PNG with CoreGraphics.
  - Shape: macOS squircle (100 px margin, continuous radius ≈ 185 px).
  - Background: deep gradient `#1C1C2E`→`#0B0B12`, with a subtle specular highlight at the top.
  - Inside: a treemap of 6 rounded blocks with the colors of video, code, apps, AI models, caches and documents, with gradients and an inner shadow that gives depth.
  - It then generates with `sips` the sizes 16, 32, 64, 128, 256, 512 and 1024 (@1x/@2x) in `DiskMap.iconset` and runs `iconutil -c icns`.
- **`Info.plist`:**
  - `CFBundleIdentifier` `local.diskmap.DiskMap`, `CFBundleName` and `CFBundleDisplayName` `DiskMap`, `CFBundleIconFile` `DiskMap`.
  - `LSMinimumSystemVersion` `15.0`, `NSHighResolutionCapable` true, `LSApplicationCategoryType` `public.app-category.utilities`.
  - `NSAppleEventsUsageDescription`: "DiskMap usa Finder para vaciar la Papelera." (DiskMap uses Finder to empty the Trash.)
- **`build-app.sh`:**
  1. `swift build -c release`.
  2. Assemble `build/DiskMap.app/Contents/{MacOS,Resources}` and copy the binary, `Info.plist`, `DiskMap.icns` and SwiftPM's resource bundle (`DiskMap_DiskMapCore.bundle`).
  3. Sign. If the identity `DiskMap Local Signing` does not exist in `security find-identity -p codesigning`, it is created only once: `openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=DiskMap Local Signing" -addext "extendedKeyUsage=codeSigning" -addext "keyUsage=digitalSignature"`, export to `.p12`, `security import … -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign` and `security add-trusted-cert -r trustRoot -p codeSign` (asks for the user's password, so the user must be warned).
  4. `codesign --force --deep --options runtime -s "DiskMap Local Signing" build/DiskMap.app`. If it fails, use `codesign -s -` and show the notice "Firma ad-hoc: tendrás que volver a dar Acceso total al disco tras cada compilación" (Ad-hoc signature: you will have to grant Full Disk Access again after every build).
  5. `--install` option: copies to `/Applications/DiskMap.app` (asking for confirmation if it already exists).

- [ ] **Step 1:** Write `make-icon.swift` and run it with `swift scripts/make-icon.swift Resources/`. Open `Resources/DiskMap-1024.png` with Read and check that it looks good at 1024 and at 32 px.
- [ ] **Step 2:** Write `Info.plist` and `build-app.sh`.
- [ ] **Step 3:** `bash scripts/build-app.sh`. Expected: `build/DiskMap.app` exists, `codesign -dv build/DiskMap.app` shows `Authority=DiskMap Local Signing` and `open build/DiskMap.app` opens the app with its icon in the Dock.
- [ ] **Step 4:** Rebuild and check that the signature is still the same identity (the Full Disk Access permission is preserved).
- [ ] **Step 5:** `git add -A && git commit -m "feat: custom icon and signed packaging"`

---

### Task 13: Final verification of phase 1

- [ ] **Step 1:** `swift test` → everything green (note the number of tests).
- [ ] **Step 2:** Install with `bash scripts/build-app.sh --install` and grant DiskMap Full Disk Access.
- [ ] **Step 3:** Full disk analysis. Note:
  - Duration.
  - Idle RAM after the analysis (`ps -o rss= -p $(pgrep -x DiskMap)`). Target < 300 MB.
  - Size of the `.app`.
  - Total analyzed versus `df` of the data volume: difference < 5 %, explaining the difference (system/purgeable).
- [ ] **Step 4:** Go through the spec's anti-goals (§4) one by one in the real app and record it in `docs/superpowers/plans/2026-10-20-diskmap-fase-1-verificacion.md` with screenshots.
- [ ] **Step 5:** `git add -A && git commit -m "docs: phase 1 verification"`
