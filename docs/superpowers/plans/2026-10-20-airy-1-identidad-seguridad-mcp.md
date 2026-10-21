# Airy 1 of 5 — Identity, safety and MCP · Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** DiskMap becomes Airy (complete technical identity with data migration), all deletion goes through a single funnel with Mole's protections, risk is classified in the common library with mode and profile, and an `airy-mcp` MCP server lets agents query the disk, execute only what is green and propose the rest in the app.

**Architecture:** The `DiskMapCore` library is kept (UI-free, tested with Swift Testing) and gains shared settings, protections, classifier, operations log and the whole MCP server; the `Airy` app (SwiftUI) and the `airy-mcp` executable (a thin stdio wrapper) consume the same library, so they classify, validate and execute the same way even when the app is closed. App and MCP only communicate through files in `~/Library/Application Support/Airy` and through `airy://` URLs.

**Tech Stack:** Swift 6.4 (Command Line Tools only), SwiftPM, SwiftUI + AppKit, Swift Testing, `libproc`, MCP (JSON-RPC 2.0 over stdio).

**Spec:** `docs/superpowers/specs/2026-10-20-airy-fase-2-design.md` (§2.1, §2.8, §2.9 «Seguridad del borrado» (Deletion safety) and «Control del usuario» (User control), «Decisiones de Claude tras la revisión del constructor» (Claude's decisions after the builder's review)) and `docs/superpowers/specs/2026-10-20-diskmap-design.md` (§4 anti-goals, §7b MCP). Lists: `docs/superpowers/research/2026-10-20-mole-inspiracion.md` §2.15. Inherited constraints: `.superpowers/sdd/2026-10-20-diskmap-fase-1/progress.md`.

**Out of this plan:** icon, palette and animations (plan 2); aggressive catalog entries, profile interface and texts «Sin problema / Tú decides / No borrar» (No problem / You decide / Do not delete) in the app (plan 3); `get_performance` and `propose_quit_app` (plan 4); Uninstaller and the other sections (plan 5).

## Global Constraints

- Swift 6.4, SwiftPM, Command Line Tools only (no Xcode); `swift build` / `swift test`; platform `.macOS(.v15)`; the test target keeps the `unsafeFlags` of the Swift Testing plugin from Package.swift.
- SwiftUI views with the `@ViewState` alias (not `@State`), never `.fixedSize(horizontal:false,vertical:true)` on multiline `Text`; follow the existing patterns (`Theme`, `PrimaryButton`, `SectionHeader`).
- Interface in **Spanish (Spain)**; MCP tool names in English, response texts in Spanish.
- File contents are **never** sent to the AI or the MCP: only paths, sizes, dates, types and catalog records.
- Protected locations, never deletable: Docker volumes (`~/Library/Containers/com.docker.docker`, `~/Library/Group Containers/group.com.docker`), iCloud (`~/Library/Mobile Documents`), Mail, Messages, Keychains, AddressBook, Calendars, Photos, `/Applications`, `/Library`, `/usr`, `/bin`, `/sbin`, `/private`, `/opt/homebrew`, `/System`; personal folders are never green; runtimes in use (`codex-primary-runtime`) are never touched.
- Every destructive action of the app goes through `ConfirmSheet` → `AppModel` → `CleanupExecutor`; no DEBUG shortcuts that act without confirmation.
- The MCP only executes unblocked green («Borrar sin riesgo» (Safe to delete)); never amber or red; the agents switch being off blocks every action tool (including `dry_run`); there is no tool that accepts arbitrary commands or paths to delete.
- Files → Trash (`FileManager.trashItem`); tool caches → their official command with an argument array (never a shell string).
- DEBUG screenshots only of the app's own windows; to stop the app, kill **only its own PID** (never `pkill -x`); each manual verification uses its own `AIRY_SUPPORT_DIR` (DEBUG).
- In tests and verification, real cleanup commands are never run and the real Trash is never emptied (`FakeRunner`/`FakeProbes`, temporary folders; against the real system only read tools and `dry_run: true`).
- Do not touch Keychain trust settings (no `add-trusted-cert`); the old «DiskMap Local Signing» certificate is not touched.
- Mole is GPL-3.0: ideas and path lists are adapted, **never code** (not even translated); it is credited in «Acerca de Airy» (About Airy).
- Identity: name **Airy**, bundle id `local.airy.Airy`, data `~/Library/Application Support/Airy`, signing identity «Airy Local Signing», scheme `airy://`, executable `airy-mcp` in `Airy.app/Contents/MacOS/`, MCP server registered as `airy`, installation at `/Applications/Airy.app`.
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **App and `airy-mcp` writing at the same time** (history, operations log, migration) → no record is lost or corrupted. Test in Task 2 (`concurrentMigrationsCopyOnce`) and Task 7 (`concurrentAppendsFromTwoLogsKeepAll`, `historyConcurrentAppendsFromTwoStores`).
2. **`settings.json` corrupt, half-written or from a future version** → the MCP executes nothing (fail closed), the app warns and does not overwrite it without asking. Test in Task 3 (`corruptSettingsDisallowAgents`, `futureVersionIsUnreadable`) and Task 13 (`unreadableSettingsBlocksActions`).
3. **`airy://` opened by a web page or another app with hostile parameters** (`..`, control characters, a 10,000-character reason, nonexistent id) → it is rejected or truncated and never acted on without confirmation. Test in Task 10 (`parseRejectsHostileInput`, `reasonIsSanitisedAndTruncated`).
4. **The path changes between the check and the deletion** (folder replaced by a link to `~/Documents`) → rejection and nothing moved. Test in Task 4 (`identityChangeIsDetected`) and Task 8 (`identityChangeBetweenPlanAndActRefuses`).
5. **The user turns the switch off while an agent is cleaning a batch** → what is left is blocked immediately (settings are read on every item). Test in Task 8 (`liveSettingsReadPerItem`) and Task 13 (`runAllStopsWhenToggleTurnsOffMidBatch`).

---

## File structure

```
Package.swift                          name "Airy"; products DiskMapCore, Airy, airy-mcp
Resources/Info.plist                   Airy identity + CFBundleURLTypes airy
Resources/Airy.icns, Airy-1024.png, Airy.entitlements   (renamed; same icon)
scripts/build-app.sh                   Airy.app + airy-mcp, new identity, safe installation
Sources/Airy/                          (formerly Sources/DiskMap) SwiftUI app
  AiryApp.swift                        (formerly DiskMapApp.swift) scenes, URL, Settings, About
  Settings/SettingsView.swift          Mode, Agents, Protected by you            (new)
  Assistant/AgentsView.swift           «Conectar agente» tab                       (new)
Sources/AiryMCP/main.swift             stdio server startup                        (new)
Sources/DiskMapCore/
  Persistence/AppPaths.swift           Airy and legacy DiskMap data paths          (new)
  Persistence/DataMigration.swift      DiskMap → Airy copy                         (new)
  Persistence/OperationLog.swift       JSONL log with run id and author            (new)
  Settings/AirySettings.swift          mode, profiles, agents, user list           (new)
  Settings/SettingsStore.swift         settings.json                               (new)
  Settings/ProtectList.swift           «Proteger esto»                             (new)
  Safety/HardProtections.swift         hard list (Mole §2.15 + constraints)        (new)
  Safety/PathGate.swift                path and identity validation                (new)
  Safety/ProcessGuard.swift            3-state process guard                       (new)
  Safety/TimeBudget.swift              time budgets                                (new)
  Safety/RiskClassifier.swift          single effective risk                       (new)
  Catalog/FolderExplanations.swift     moved from Sources/Airy/Map/HoverCard.swift
  Integration/AiryURL.swift            airy://propose|show|rescan                  (new)
  Integration/AgentSnippets.swift      connection texts + registration in Claude Code (new)
  MCP/JSONValue.swift, MCPServer.swift, MCPTool.swift, AiryEnvironment.swift, StdioTransport.swift
  MCP/Tools/ReadTools.swift, MCP/Tools/ActionTools.swift
Tests/DiskMapCoreTests/                IdentityTests, MigrationTests, SettingsTests, PathGateTests,
                                       ClassifierTests, ProcessGuardTests, OperationLogTests,
                                       FunnelTests, AiryURLTests, MCPServerTests, MCPReadToolTests,
                                       MCPActionToolTests, AgentSnippetsTests
```

**Ruling — SwiftPM names:** the package becomes `Airy`, the executable `Airy` (`Sources/Airy`), and the library keeps the name `DiskMapCore` (and its test target `DiskMapCoreTests`): renaming it would touch every `import` in ~70 files with no visible effect. Consequence: the resource bundle becomes `Airy_DiskMapCore.bundle`.

---

### Task 1: `fase-2` branch and DiskMap → Airy identity change

**Files:**
- Modify: `Package.swift`, `Resources/Info.plist`, `scripts/build-app.sh`, `scripts/make-icon.swift` (output name), `Sources/DiskMapCore/Catalog/Catalog.swift:171`, `Sources/DiskMapCore/AI/AIAssistant.swift` (prompts), `Sources/DiskMapCore/System/CommandRunner.swift:205` (temporary prefix)
- Rename: `Sources/DiskMap/` → `Sources/Airy/`; `DiskMapApp.swift` → `AiryApp.swift` (`struct AiryApp`); `Resources/DiskMap.icns|DiskMap-1024.png|DiskMap.entitlements` → `Airy.*`
- Modify: all visible «DiskMap» strings in `Sources/Airy/**` → «Airy»; `DISKMAP_*` variables → `AIRY_*`; `local.diskmap.layout` → `local.airy.layout`; `Notification.Name("DiskMap…")` → `"Airy…"`; test folder `DiskMapPrueba` → `AiryPrueba`
- Test: `Tests/DiskMapCoreTests/IdentityTests.swift`; adjust expectations that cite «DiskMap» in `AITests.swift`

**Interfaces:**
- Produces: `Catalog.bundleName == "Airy_DiskMapCore.bundle"`; executable `Airy`; Info.plist with `CFBundleIdentifier local.airy.Airy`, `CFBundleExecutable/Name/DisplayName/IconFile Airy`, `CFBundleShortVersionString 0.2.0`, `CFBundleVersion 2`, `NSAppleEventsUsageDescription "Airy usa Finder para vaciar la Papelera."` (Airy uses Finder to empty the Trash.), `CFBundleURLTypes = [{CFBundleURLName: local.airy.Airy, CFBundleURLSchemes: [airy]}]`.

- [ ] **Step 1: Create the branch**

Run: `git switch fase-1 && git status --short && git switch -c fase-2`
Expected: clean tree; `git branch --show-current` → `fase-2`.

- [ ] **Step 2: Write the failing tests** (`IdentityTests.swift`; they read the repository with `#filePath`)

```swift
@Test func resourceBundleNameIsAirys() { #expect(Catalog.bundleName == "Airy_DiskMapCore.bundle") }
@Test func infoPlistHasAiryIdentity() throws {
    let plist = try repoPlist("Resources/Info.plist")
    #expect(plist["CFBundleIdentifier"] as? String == "local.airy.Airy")
    #expect(plist["CFBundleExecutable"] as? String == "Airy")
    let types = plist["CFBundleURLTypes"] as? [[String: Any]]
    #expect(types?.first?["CFBundleURLSchemes"] as? [String] == ["airy"])
}
/// No string literal in Sources/ contains "DiskMap" (except "DiskMapCore") nor "DISKMAP_",
/// except Persistence/AppPaths.swift and Persistence/DataMigration.swift (legacy, Task 2).
@Test func noDiskMapLeftInStringLiterals() throws {
    #expect(try stringLiteralHits(pattern: #/DiskMap(?!Core)|DISKMAP_/#, under: "Sources",
                                  allow: ["AppPaths.swift", "DataMigration.swift"]) == [])
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --filter IdentityTests`
Expected: FAIL (bundle `DiskMap_DiskMapCore.bundle`, identifier `local.diskmap.DiskMap`, dozens of literals).

- [ ] **Step 4: Rename** with `git mv` and edit according to **Files**. `Package.swift`: `name: "Airy"`, products `.library(name: "DiskMapCore", …)` and `.executable(name: "Airy", targets: ["Airy"])`, `.executableTarget(name: "Airy", dependencies: ["DiskMapCore"], path: "Sources/Airy")`. `WindowGroup("Airy")`, sidebar «Airy», banner «Airy no puede ver todo el disco» (Airy cannot see the whole disk), prompts «Eres el asistente de Airy…» (You are Airy's assistant…).

- [ ] **Step 5: `scripts/build-app.sh`**: `APP_NAME="Airy"`, `IDENTITY="Airy Local Signing"`, bundle `Airy_DiskMapCore.bundle`. Installation (`--install`), in this order:
  1. copy to `/Applications/.Airy.app.new` and `codesign --verify --deep --strict` on the copy;
  2. if `/Applications/Airy.app` exists: ask (as now); if it is open, ask and close it with `osascript -e 'tell application id "local.airy.Airy" to quit'` (wait ≤ 10 s; never `pkill`); `rm -rf` the old one and `mv` the new one;
  3. **only if all the above went well** and `/Applications/DiskMap.app` exists: if it is open, ask and close it with `tell application id "local.diskmap.DiskMap" to quit`; move it with `mv "/Applications/DiskMap.app" "$HOME/.Trash/DiskMap $(date +%Y%m%d-%H%M%S).app"`; print «✓ DiskMap.app movida a la Papelera» (DiskMap.app moved to the Trash).
  4. Final reminder: «Vuelve a dar Acceso total al disco a Airy (Ajustes del Sistema › Privacidad y seguridad).» (Grant Airy Full Disk Access again (System Settings › Privacy & Security).)

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test 2>&1 | tail -3`
Expected: PASS, 245 + 3 tests.

- [ ] **Step 7: Package without installing**

Run: `bash scripts/build-app.sh && plutil -extract CFBundleIdentifier raw build/Airy.app/Contents/Info.plist && ls build/Airy.app/Contents/Resources`
Expected: «✓ Firmada con "Airy Local Signing"» (Signed with …), `local.airy.Airy`, `Airy.icns` and `Airy_DiskMapCore.bundle`.

- [ ] **Step 8: Commit**

```bash
git add -A && git commit -m "feat: DiskMap is renamed Airy (identity, bundle id, signing, scheme)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Airy data folder and migration from DiskMap

**Files:**
- Create: `Sources/DiskMapCore/Persistence/AppPaths.swift`, `Sources/DiskMapCore/Persistence/DataMigration.swift`
- Modify: `Sources/Airy/AppModel.swift:166-176` (uses `AppPaths`, migrates before creating `IndexStore`; `Notice.Kind` gains `.migration`), `Sources/Airy/Assistant/AssistantSession.swift` (migrates `claudePath`)
- Test: `Tests/DiskMapCoreTests/MigrationTests.swift`

**Interfaces:**
- Produces:
```swift
public struct AppPaths: Sendable, Equatable {
    public static let folderName = "Airy", legacyFolderName = "DiskMap", legacyBundleID = "local.diskmap.DiskMap"
    public let support: URL
    public let legacySupport: URL?            // nil with AIRY_SUPPORT_DIR
    public init(support: URL, legacySupport: URL?)
    /// `AIRY_SUPPORT_DIR` is only honored in DEBUG builds.
    public static func standard(home: String = NSHomeDirectory(),
                                environment: [String: String] = ProcessInfo.processInfo.environment) -> AppPaths
    public var settingsFile: URL     // support/settings.json
    public var operationsFile: URL   // support/operations.jsonl
    public var migrationMarker: URL  // support/.migrated-from-diskmap
}
public enum MigrationResult: Sendable, Equatable { case notNeeded, migrated(copied: [String]), failed(String) }
public enum DataMigration {
    public static func migrateIfNeeded(_ paths: AppPaths) -> MigrationResult
    /// Copies from `legacy` to `current` the keys missing in `current`; returns the copied ones.
    public static func migrateDefaults(from legacy: UserDefaults?, to current: UserDefaults, keys: [String]) -> [String]
}
```

- [ ] **Step 1: Write the failing tests**

```swift
@Test func copiesIndexHistoryAndVolumesLeavingLegacyIntact() throws {
    // legacy: scan.plist, history.json, Volumes/_Volumes_X/scan.plist
    let r = DataMigration.migrateIfNeeded(paths)
    #expect(r == .migrated(copied: ["Volumes", "history.json", "scan.plist"]))
    #expect(try Data(contentsOf: support/"history.json") == legacyHistoryBytes)
    #expect(try snapshot(legacyDir) == legacyBefore)       // names, bytes and mtime unchanged
    #expect(FileManager.default.fileExists(atPath: paths.migrationMarker.path))
}
@Test func doesNotOverwriteExistingAiryData()      // a previous support/history.json is kept as is
@Test func secondRunIsNoOp()                       // second call → .notNeeded
@Test func noLegacyFolderWritesMarker()            // → .notNeeded and marker written
@Test func interruptedMigrationResumes()           // leftovers ".scan.plist.partial-*" are deleted; scan.plist copied
@Test func concurrentMigrationsCopyOnce() async    // two tasks at once: one .migrated and one .notNeeded; identical content
@Test func defaultsMigrationCopiesOnlyMissingKeys() // claudePath copied if missing; does not overwrite an existing one
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MigrationTests`
Expected: FAIL — `AppPaths` / `DataMigration` do not exist.

- [ ] **Step 3: Implement `migrateIfNeeded`**: create `support`; `flock(LOCK_EX)` on `support/.migration.lock`; delete leftovers `.*.partial-*`; if the marker exists → `.notNeeded`; if there is no legacy → write marker, `.notNeeded`; for each first-level child of the legacy (without `.DS_Store`) that does not exist in `support`: `copyItem` to `.<name>.partial-<uuid>` and `rename` to the final name; at the end write the marker (ISO 8601 date). Error → `.failed(message)` without marker (retried on the next launch). It never writes to the legacy.

- [ ] **Step 4: Wire the app**: `AppModel.init` uses `AppPaths.standard()` and calls `migrateIfNeeded` before creating `IndexStore`; `.failed(m)` → `.migration` notice: «No se pudieron copiar los datos de \(AppPaths.legacyFolderName) (\(m)). Siguen en su carpeta; Airy lo intentará otra vez al abrirse.» (The data of … could not be copied (…). It stays in its folder; Airy will try again when it opens.) (interpolated, so that `noDiskMapLeftInStringLiterals` stays green). `AssistantSession` calls `migrateDefaults(from: UserDefaults(suiteName: AppPaths.legacyBundleID), to: .standard, keys: ["claudePath"])` once at startup.

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter MigrationTests` → PASS (7). Run: `swift test 2>&1 | tail -3` → all green.

- [ ] **Step 6: Commit** — `feat: Airy copies DiskMap data on first launch` (+ Co-Authored-By).

---

### Task 3: Shared settings (`settings.json`) and «Proteger esto» list

**Files:**
- Create: `Sources/DiskMapCore/Settings/AirySettings.swift`, `SettingsStore.swift`, `ProtectList.swift`
- Test: `Tests/DiskMapCoreTests/SettingsTests.swift`

**Interfaces:**
- Produces:
```swift
public enum CleanupMode: String, Codable, Sendable, CaseIterable { case aggressive, prudent }   // title: "Agresivo" (Aggressive) / "Prudente" (Cautious)
public enum UsageProfile: String, Codable, Sendable, CaseIterable {
    case developer, creative, localAI, gaming, music, basic
    // title: "Programo" (I code), "Diseño, foto o vídeo" (Design, photo or video), "Uso IA en local" (I use local AI), "Juego" (I game), "Música y audio" (Music and audio), "Uso básico" (Basic use)
}
public struct AirySettings: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public var version = 1
    public var mode: CleanupMode = .aggressive
    public var profiles: Set<UsageProfile> = []
    public var agentsEnabled = true
    public var protectedPaths: [String] = []      // normalized form of ProtectList.normalise
    public static let defaults = AirySettings()
    public mutating func protect(_ path: String, home: String) -> Bool   // false if invalid or repeated
    public mutating func unprotect(_ pattern: String)
}
public enum SettingsLoad: Sendable, Equatable {
    case missing, loaded(AirySettings), unreadable(String)
    public var effective: AirySettings      // missing → defaults; unreadable → defaults with agentsEnabled = false
    public var allowsAgentActions: Bool     // missing → true; loaded → s.agentsEnabled; unreadable → false
}
public struct SettingsStore: Sendable {
    public init(file: URL)
    public func load() -> SettingsLoad
    public func save(_ settings: AirySettings) throws      // atomic, sorted keys, creates the folder
    public func resetUnreadable() throws -> AirySettings   // renames to settings.unreadable-<yyyyMMdd-HHmmss>.json and writes defaults
}
public struct ProtectList: Sendable, Equatable {
    public init(patterns: [String], home: String)
    /// Trims, expands `~`, requires absolute, rejects `..`/`.`/control characters, collapses `//`, strips the trailing `/`;
    /// returns the stored form with `~/` if it is under home.
    public static func normalise(_ raw: String, home: String) -> String?
    /// Pattern that covers `path` (equals it or contains it) or that is inside `path` (it is a parent folder);
    /// case-insensitive; `*` inside a component (fnmatch).
    public func match(_ path: String) -> String?
}
```
File: `{"version":1,"mode":"aggressive","profiles":[],"agentsEnabled":true,"protectedPaths":[]}`. Missing keys → default value; unknown profiles are ignored; unknown mode or `version > 1` → `.unreadable`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func defaultsAreAggressiveAgentsOnEmptyLists() {
    let s = AirySettings.defaults
    #expect(s.mode == .aggressive && s.agentsEnabled && s.profiles.isEmpty && s.protectedPaths.isEmpty)
}
@Test func roundTripsAndFillsMissingKeys()          // {"version":1} → defaults; save+load → equal
@Test func corruptSettingsDisallowAgents() {        // "{no json" → .unreadable; allowsAgentActions == false; effective.agentsEnabled == false
}
@Test func futureVersionIsUnreadable()              // {"version":2} → .unreadable
@Test func unknownProfileIgnoredUnknownModeUnreadable()
@Test func resetUnreadableKeepsBadFileAside()       // settings.unreadable-*.json remains with the original bytes
@Test func normaliseRules() {
    #expect(ProtectList.normalise(" ~/Library/Caches/foo/ ", home: h) == "~/Library/Caches/foo")
    #expect(ProtectList.normalise("relativa/x", home: h) == nil)
    #expect(ProtectList.normalise("/a/../b", home: h) == nil)
    #expect(ProtectList.normalise("/a\u{7}b", home: h) == nil)
}
@Test func matchInsideAncestorCaseAndWildcard() {
    let list = ProtectList(patterns: ["~/Library/Caches/Foo", "~/Models/*.gguf"], home: h)
    #expect(list.match(h + "/library/caches/foo/x") == "~/Library/Caches/Foo")
    #expect(list.match(h + "/Library/Caches") == "~/Library/Caches/Foo")   // parent folder
    #expect(list.match(h + "/Models/llama.gguf") != nil)
    #expect(list.match(h + "/Library/Caches/Bar") == nil)
}
@Test func protectDeduplicates()                    // protect twice → second false, a single entry
```

- [ ] **Step 2: Run test to verify it fails** — `swift test --filter SettingsTests` → FAIL (nonexistent types).
- [ ] **Step 3: Implement** according to Interfaces.
- [ ] **Step 4: Run tests to verify they pass** — `swift test --filter SettingsTests` → PASS (9).
- [ ] **Step 5: Commit** — `feat: shared Airy settings and «Proteger esto» list` (+ Co-Authored-By).

---

### Task 4: Hard protections and path validation (`PathGate`)

**Files:**
- Create: `Sources/DiskMapCore/Safety/HardProtections.swift`, `Sources/DiskMapCore/Safety/PathGate.swift`
- Modify: `Sources/DiskMapCore/Catalog/RiskPolicy.swift` (the `sealed*`/`protectedSystemRoots` lists and `trashRefusal` move to `HardProtections`; `minimumRisk`, `effectiveRisk`, `canonical`, `isInside` stay)
- Test: `Tests/DiskMapCoreTests/PathGateTests.swift`

**Interfaces:**
- Consumes: `ProtectList` (Task 3), `Catalog`.
- Produces:
```swift
public struct ProtectionMatch: Sendable, Equatable {
    public enum Source: String, Sendable { case airy, user }
    public let source: Source; public let pattern: String; public let reason: String   // reason in Spanish
}
public struct HardProtections: Sendable {
    public static let standard: HardProtections
    /// `canonicalPath` in lowercase (RiskPolicy.canonical). `nil` if not protected.
    public func match(canonicalPath: String, home: String, catalog: Catalog?) -> ProtectionMatch?
    /// Paths whose inode is never deleted (critical roots + home); `PathGate` resolves them.
    public var criticalRoots: [String] { get }
}
public struct FileIdentity: Sendable, Equatable {
    public let device: UInt64, inode: UInt64, parentDevice: UInt64, parentInode: UInt64, isSymlink: Bool
}
public struct ValidatedPath: Sendable, Equatable { public let path: String; public let forms: [String]; public let identity: FileIdentity }
public struct PathRefusal: Error, Sendable, Equatable { public let reason: String }
public struct PathGate: Sendable {
    public init(home: String, catalog: Catalog?, userProtected: ProtectList, protections: HardProtections = .standard)
    public func validate(_ path: String) -> Result<ValidatedPath, PathRefusal>
    /// Runs `lstat` on the path and its parent again right before acting; different ⇒ refusal.
    public func confirmUnchanged(_ validated: ValidatedPath) -> PathRefusal?
}
```

**Hard list** (`HardProtections.standard`, adapted from Mole §2.15 + constraints; never editable by the user and always applied on top of their settings). Paths with `~` are relative to home; comparison is case-insensitive:

| Group | Rule | Values |
|---|---|---|
| Critical roots | the path **is** one of them (text or inode) | `/`, `/bin`, `/dev`, `/sbin`, `/usr`, `/System`, `/System/Volumes/Data`, `/Library`, `/Library/Apple`, `/Library/Application Support`, `/Library/Extensions`, `/Library/Keychains`, `/Applications`, `/Applications/Safari.app`, `/Volumes`, `/opt`, `/opt/homebrew`, `/Users`, `/Users/Shared`, `/Users/Guest`, `/private`, `/private/tmp`, `/etc`, `/var`, `/var/db`, `/var/audit`, `/var/root`, `/private/var`, `/private/var/tmp`, `/private/var/folders`, `/private/var/db`, `/private/var/audit`, `/private/var/root`, `/Network`, `/cores`, `/home`, `/net`, `/tmp`; also any `/Users/<name>` and the home (all its forms) |
| System sealed | neither it, nor inside, nor parents | `/System`, `/Applications`, `/Library`, `/usr`, `/bin`, `/sbin`, `/private` (already existing exception: contents of the user's temporary folder), `/opt/homebrew`, `/private/var/db/powerlog` |
| Home sealed | neither it, nor inside, nor parents | `Library/Containers/com.docker.docker`, `Library/Group Containers/group.com.docker`, `Library/Mobile Documents`, `Library/Mail`, `Library/Messages`, `Library/Keychains`, `Library/Accounts`, `Library/Contacts`, `Library/Calendars`, `Library/Application Support/AddressBook`, `Library/Photos`, `Pictures/*.photoslibrary`, `Library/Application Support/com.apple.idleassetsd`, `Library/Application Support/com.apple.wallpaper`, `Library/Preferences/com.apple.dock.plist`, `Library/Preferences/com.apple.finder.plist`, `Library/Preferences/ByHost/com.apple.bluetooth.*`, `Library/Preferences/com.apple.wifi.*`, `Library/Preferences/com.apple.networkextension*`, `Library/Caches/pypoetry/virtualenvs`, `Library/Caches/org.R-project.R/R/renv`, `.prometheus/data`, `.orbstack`, `Library/Group Containers/*dev.orbstack`, `.cache/codex-runtimes/codex-primary-runtime`, `.codex/auth.json`, `.codex/sessions`, `.codex/history.jsonl`, `.codex/config.toml`, `.claude.json`, `.claude/projects`, `.ssh`, `.gnupg`, `.gitconfig.bak*`, `.zsh_history.bak*`, `.bash_history.bak*` |
| Upward (home) | it and its parents; its contents yes | home, `Documents`, `Desktop`, `Pictures`, `Movies`, `Music`, `Downloads`, `orca`, `Projects`, `Library`, `Applications`, `.Trash`, `.cache`, `.config`, `.local`, `.local/bin`, `.local/lib`, `.local/share`, `.local/state`, `Library/Application Support`, `Library/Caches`, `Library/Containers`, `Library/Group Containers`, `Library/Preferences`, `Library/Logs`, `Library/Developer` |
| Fragments | some component contains (case-insensitive) | `systemsettings`, `systempreferences`, `controlcenter`, `com.apple.settings`, `com.apple.notes`, `finder.cache`, `dock.cache`, `coreaudio`, `com.apple.audio.`, `com.apple.fontregistry`, `spotlight`, `cloudkit`, `com.apple.containermanagerd`, `com.apple.homed`, `com.apple.ap.adprivacyd`, `familycircle`, `homekit`, `shortcutssandboxcache`, `gippseudonymousid`, `cctclearcutlogger`, `com.apple.e5rt.e5bundlecache`, `com.crowdstrike.`, `com.sentinelone.`, `com.sentinel-labs.`, `com.eset.`, `com.jamf.`, `com.jamfsoftware.`, `com.paloaltonetworks.`, `com.cisco.anyconnect`, `com.cisco.secureclient`, `1password`, `keychain`, `bitwarden`, `lastpass`, `keepass`, `dashlane`, `enpass`, `gnupg` |
| Sensitive app data (Layer C) | everything under `~/Library/{Application Support,Containers,Group Containers}/<folder>` if the normalized name (lowercase without spaces, `.`, `-`, `_`) **contains** a long fragment or its last DNS component **is** a short one; except `Caches`, `Data/Library/Caches`, `Data/tmp` subtrees, and paths that a literal pattern of the catalog (not `info`) declares **inside** that folder (e.g. `Claude/vm_bundles`) | long: `1password bitwarden lastpass dashlane keepass authy yubico jetbrains vscode sublime typora cursor claude chatgpt openai codex ollama lmstudio perplexity drawthings windsurf gemini postman insomnia charles proxyman clash surge tailscale zerotier wireguard openvpn cloudflare nordvpn expressvpn protonvpn mullvad githubdesktop gitkraken sublimemerge iterm2 kitty alacritty wezterm docker orbstack vmware parallels virtualbox vagrant alfred raycast karabiner rectangle bartender obsidian notion logseq evernote dayone goodnotes adobe figma sketch affinity pixelmator maxon autodesk nativeinstruments izotope fabfilter slack discord teams telegram whatsapp wechat dropbox onedrive googledrive backblaze teamviewer anydesk`; short (equality): `jan box paw code bear zoom warp nova fork utm tower` |

Visible reasons (examples): «Carpeta crítica del sistema.» (Critical system folder.), «Ubicación protegida por Airy: Llaveros.» (Location protected by Airy: Keychains.), «Datos de una app sensible (1Password).» (Data of a sensitive app (1Password).), «Lo has protegido tú (~/…).» (You protected it yourself (~/…).)

- [ ] **Step 1: Write the failing tests** (temporary home with the necessary structure)

```swift
@Test func rejectsRelativeDotDotAndControlChars() {
    for p in ["Library/x", "/tmp/a/../b", "/a\u{7}b", "", "/a//b"] { #expect(gate.validate(p).failure != nil) }
}
@Test func rejectsCriticalRootsCaseInsensitive()   // "/usr", "/USR", "/applications", "/System/Library"
@Test func rejectsHomeAndUsersChildren()           // home, "/Users/Shared", "/Users/" + NSUserName()
@Test func rejectsAliasOfCriticalRootByInode()     // "/System/Volumes/Data/Users" (same inode as /Users)
@Test func resolvesSymlinkedAncestor()             // tmp/link → home/Library/Mail; validate(tmp/link/x) fails
@Test func symlinkTargetIsValidated()              // link → home/Library/Keychains: fails
@Test func identityChangeIsDetected() {            // validate a folder; replace it with a link to home/Documents
    #expect(gate.confirmUnchanged(validated) != nil)
}
@Test func userProtectedAndItsAncestorsRefused()   // protected ~/Library/Caches/Foo: Foo/x and the parent ~/Library/Caches/…
@Test func hardProtectionsIgnoreUserSettings()     // empty ProtectList: home/Library/Keychains/x still fails
@Test func sensitiveAppDataRefusedCatalogExceptionAllowed() {
    #expect(gate.validate(h + "/Library/Application Support/1Password/data").failure != nil)
    #expect(gate.validate(h + "/Library/Application Support/Claude/vm_bundles").failure == nil)   // real catalog
    #expect(gate.validate(h + "/Library/Application Support/Claude/otra").failure != nil)
    #expect(gate.validate(h + "/Library/Containers/com.tinyspeck.slackmacgap/Data/Library/Caches/x").failure == nil)
}
@Test func fragmentsAnywhere()                     // ~/Library/Caches/com.apple.FontRegistry, …/com.crowdstrike.x
@Test func userTempDirContentsStillAllowed()       // phase 1 behavior
```

- [ ] **Step 2: Run test to verify it fails** — `swift test --filter PathGateTests` → FAIL.
- [ ] **Step 3: Implement `PathGate.validate`** in this order: syntax (non-empty, starts with `/`, ≤ 1024 bytes, no scalars < 0x20 nor 0x7F, no empty/`.`/`..` components) → `lstat` (must exist; identity + `lstat` of the parent) → canonical forms: literal, parent resolved with `realpath` + last component, and the link's target if it is one → for each form: critical root / `/users/<x>` / home, `HardProtections.match`, `userProtected.match`, catalog rules from `CleanupExecutor.unsafeTrashReason` (related `doNotTouch` records and caches "only with their official command", moved here) → `(st_dev, st_ino)` of the target against the set of inodes of critical roots and home (computed once with `stat`).
- [ ] **Step 4: Run tests** — `swift test --filter PathGateTests` → PASS (12); `swift test --filter CleanupTests` → the phase 1 rejection tests stay green.
- [ ] **Step 5: Commit** — `feat: extended hard protections and path validation with identity` (+ Co-Authored-By).

---

### Task 5: Single risk classifier (catalog + mode + profile + protections)

**Files:**
- Create: `Sources/DiskMapCore/Safety/RiskClassifier.swift`
- Modify: `Sources/DiskMapCore/Catalog/Catalog.swift` (new `CatalogEntry` fields), `Sources/DiskMapCore/Model/FileNode.swift` (`Risk.label`), `Sources/DiskMapCore/Cleanup/CleanupScanner.swift` (uses the classifier; `CleanupItem` gains fields), `Sources/DiskMapCore/UIState/CleanupBoard.swift` (order and `canSelect`), `Sources/DiskMapCore/AI/AIAssistant.swift:252` (verdict via classifier)
- Test: `Tests/DiskMapCoreTests/ClassifierTests.swift`

**Interfaces:**
- Consumes: `AirySettings`, `ProtectList` (Task 3), `HardProtections`, `ProtectionMatch` (Task 4).
- Produces (API that plan 3 extends with aggressive entries and profiles; **extension rule:** every new entry can only raise risk, except `aggressiveRisk`, bounded below by `regenerates` and by the floors):
```swift
extension CatalogEntry {   // optional JSON; absent ⇒ phase 1 behavior
    public var aggressiveRisk: Risk?        // "aggressiveRisk"
    public var preselectInAggressive: Bool  // "preselectInAggressive", false
    public var profiles: [UsageProfile]     // "profiles", []
    public var processNames: [String]       // "processNames", [] (Task 6)
}
extension Risk { public var label: String }   // "Sin problema" / "Tú decides" / "No borrar"
public struct Classification: Sendable, Equatable {
    public var risk: Risk
    public var preselected: Bool
    public var highlighted: Bool             // matches some profile of the user
    public var protection: ProtectionMatch?
    public var keptPaths: [String]           // paths left after removing the protected ones (.trash records)
    public var reasons: [String]
}
public struct RiskClassifier: Sendable {
    public init(catalog: Catalog, settings: AirySettings, home: String, protections: HardProtections = .standard)
    public func baseRisk(of entry: CatalogEntry) -> Risk
    public func classify(entry: CatalogEntry, paths: [String], ai: Risk? = nil) -> Classification
    public func classify(path: String, ai: Risk? = nil) -> Classification
}
// CleanupItem gains (with default values in init): preselected = false, highlighted = false,
// protection: ProtectionMatch? = nil, blockedReason: String? = nil  (Task 6 fills it)
// CleanupScanner.init gains `classifier: RiskClassifier? = nil` (nil ⇒ RiskClassifier(catalog:settings:.defaults,home:))
```
Algorithm of `classify(entry:paths:ai:)`:
1. `base = baseRisk(entry)`: in Cautious, `entry.risk`; in Aggressive, `entry.aggressiveRisk` if it is higher than `entry.risk`, or if it is lower **and** `entry.regenerates` **and** `entry.risk != .doNotTouch`; otherwise `entry.risk`.
2. Protections (hard first, then the user's) per path. `.trash` records: protected paths leave `keptPaths`; if none remains (and there were some), `risk = .doNotTouch` with `protection`. `.command`/`.info` records: any related protection (inside or parent) ⇒ `.doNotTouch`.
3. `risk = strictest(base, ai, RiskPolicy.minimumRisk(path:home:) of each kept path)`.
4. `highlighted = !Set(entry.profiles).isDisjoint(with: settings.profiles)`; the profile never touches `risk`.
5. `preselected = risk == .safe || (mode == .aggressive && risk == .yourCall && entry.preselectInAggressive)`.
`classify(path:ai:)`: record from `catalog.match` → `baseRisk`; protection (including "is a parent of something protected") ⇒ `.doNotTouch`; otherwise `RiskPolicy.effectiveRisk(path:home:catalog:ai:)`.
`CleanupBoard`: within each group, `highlighted` first, then bytes desc and id; `canSelect` also requires `protection == nil && blockedReason == nil`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func prudentUsesCatalogRisk()
@Test func aggressiveLowersOnlyRegenerableEntries() {
    let e = entry(risk: .yourCall, aggressiveRisk: .safe, regenerates: true)
    #expect(classifier(.aggressive).classify(entry: e, paths: [cache]).risk == .safe)
    #expect(classifier(.prudent).classify(entry: e, paths: [cache]).risk == .yourCall)
    #expect(classifier(.aggressive).classify(entry: e.with(regenerates: false), paths: [cache]).risk == .yourCall)
}
@Test func aggressiveNeverUnlocksDoNotTouch()
@Test func personalFolderNeverGreenEvenInAggressive()   // home/Projects/app/node_modules with aggressiveRisk .safe → .yourCall
@Test func profilesNeverChangeRisk() {                  // the 64 combinations of UsageProfile give the same risk
}
@Test func aiCanOnlyRaise()                             // ai .safe over .yourCall → .yourCall; ai .doNotTouch → .doNotTouch
@Test func userProtectedMakesItemRed()
@Test func protectedChildIsDroppedFromAggregateItem()   // user-logs with a child «…/CloudKit»: keptPaths without it, risk unchanged
@Test func hardProtectionBeatsUserSettings()            // safe record with path home/Library/Keychains → .doNotTouch
@Test func preselection()                               // Aggressive+flag preselects yourCall; Cautious never
@Test func scannerRiskEqualsClassifier() async          // CleanupScanner(classifier:) → item.risk == classify(entry:paths:).risk
@Test func bundledCatalogDecodesWithDefaults()          // aggressiveRisk nil, profiles [] in all records
@Test func highlightedItemsComeFirstWithinGroup()
```

- [ ] **Step 2: Run test to verify it fails** — `swift test --filter ClassifierTests` → FAIL.
- [ ] **Step 3: Implement** according to Interfaces; `CleanupScanner.findItems` takes risk, `paths = keptPaths`, `preselected`, `highlighted`, `protection` from the classifier (with non-empty `usedBy` ⇒ `.doNotTouch`, as now); `AIAssistant` receives `classifier: RiskClassifier?` and uses it instead of `RiskPolicy.effectiveRisk` when it exists.
- [ ] **Step 4: Run tests** — `swift test 2>&1 | tail -3` → all green (including `CleanupTests`, `CleanupBoardTests`, `AITests`).
- [ ] **Step 5: Commit** — `feat: single risk classifier with mode, profile and protections` (+ Co-Authored-By).

---

### Task 6: Three-state process guard and time budgets

**Files:**
- Create: `Sources/DiskMapCore/Safety/ProcessGuard.swift`, `Sources/DiskMapCore/Safety/TimeBudget.swift`
- Modify: `Sources/DiskMapCore/Cleanup/ReferenceChecker.swift` (result with `complete`), `Sources/DiskMapCore/Cleanup/CleanupScanner.swift` (`blockedReason` if the reference check did not finish), `Sources/DiskMapCore/Resources/catalog.json` (`processNames`)
- Test: `Tests/DiskMapCoreTests/ProcessGuardTests.swift`

**Interfaces:**
- Produces:
```swift
public enum TimeBudget {
    public static let processScan: Duration = .seconds(3)
    public static let sizeMeasure: Duration = .seconds(30)
    public static let references: TimeInterval = 10
    /// `nil` if it does not finish in time (the task is cancelled).
    public static func run<T: Sendable>(_ limit: Duration, _ operation: @escaping @Sendable () async -> T) async -> T?
}
public struct RunningProcess: Sendable, Equatable { public let pid: Int32; public let name: String; public let executablePath: String? }
public protocol ProcessListing: Sendable {
    func processes() -> [RunningProcess]?                                   // nil = could not be read
    func holders(ofPathsUnder paths: [String]) -> [RunningProcess]?         // nil = unknown
}
public struct LibprocListing: ProcessListing { public init() }   // proc_listallpids, proc_name, proc_pidpath,
    // PROC_PIDLISTFDS + PROC_PIDFDVNODEPATHINFO; excludes the own PID; non-inspectable processes (EPERM) are skipped
public enum GuardState: Sendable, Equatable { case stopped, running(String), unknown(String) }
public struct ProcessGuard: Sendable {
    public init(listing: any ProcessListing = LibprocListing(), budget: Duration = TimeBudget.processScan)
    /// Case-insensitive names against `name` and the last component of `executablePath`.
    /// `checkOpenFiles`: additionally, does any process have a file open under `paths` (live cache, SQLite)?
    public func check(processNames: [String], paths: [String], checkOpenFiles: Bool) async -> GuardState
}
extension ReferenceChecker {
    public func referencesChecked(toAny needles: [String], timeout: TimeInterval) async -> (found: [String: [String]], complete: Bool)
}
```
`processNames` in catalog.json: `pnpm`, `pnpm-cache` → `["pnpm"]`; `npm` → `["npm"]`; `uv` → `["uv"]`; `pip` → `["pip", "pip3"]`; `conda` → `["conda"]`; `cargo` → `["cargo"]`; `homebrew` → `["brew"]`; `xcode-deriveddata` → `["Xcode", "xcodebuild"]`; `xcode-simulators` → `["Simulator", "xcodebuild"]`; `ollama-models` → `["ollama"]`; `whisper-cache` → `["whisper"]`.
Texts: `running` → «Está en marcha: \(name). Ciérralo antes de limpiar.» (It is running: …. Close it before cleaning.); `unknown` → «No se pudo comprobar si está en uso; Airy no lo toca.» (Could not check whether it is in use; Airy does not touch it.); incomplete references → «No se pudo comprobar a tiempo si lo usa algún proyecto.» (Could not check in time whether any project uses it.)

- [ ] **Step 1: Write the failing tests**

```swift
@Test func stoppedWhenNoProcessMatches() async
@Test func runningWhenNameMatchesCaseInsensitive() async     // "PNPM" against ["pnpm"]
@Test func unknownWhenListingFails() async                   // processes() == nil → .unknown
@Test func unknownWhenListingIsTooSlow() async               // fake listing that takes 5 s, budget 0.2 s → .unknown
@Test func runningWhenAnotherProcessHoldsAFile() async       // holders → [Brave Helper] → .running
@Test func unknownWhenHoldersUnknown() async
@Test func timeBudgetReturnsNilOnTimeout() async
@Test func libprocListsProcessesAndExcludesSelf() {          // real: not nil, not empty, without ProcessInfo.processIdentifier
}
@Test func incompleteReferenceCheckBlocksItem() async        // timeout 0 over a tree with needle: item.blockedReason != nil; canSelect false
```

- [ ] **Step 2: Run test to verify it fails** — `swift test --filter ProcessGuardTests` → FAIL.
- [ ] **Step 3: Implement** according to Interfaces (the libproc call runs inside `TimeBudget.run`).
- [ ] **Step 4: Run tests** — `swift test --filter ProcessGuardTests` → PASS (9); `swift test 2>&1 | tail -3` → green.
- [ ] **Step 5: Commit** — `feat: three-state process guard and time budgets` (+ Co-Authored-By).

---

### Task 7: Exportable operations log and process-safe history

**Files:**
- Create: `Sources/DiskMapCore/Persistence/OperationLog.swift`
- Modify: `Sources/DiskMapCore/Persistence/IndexStore.swift` (`append` with `flock` between processes; `CleanupRecord.byAgent`)
- Test: `Tests/DiskMapCoreTests/OperationLogTests.swift`

**Interfaces:**
- Produces:
```swift
public enum Actor: Codable, Sendable, Equatable { case user; case agent(client: String) }
    // JSON: {"type":"user"} / {"type":"agent","client":"claude-code"}
public struct OperationRecord: Codable, Sendable, Equatable {
    public var runID: UUID, date: Date, actor: Actor
    public var action: String      // "clean" | "trash_paths" | "empty_trash" | "propose" | "show" | "rescan"
    public var itemID: String?, title: String
    public var paths: [String], command: [String]?
    public var dryRun: Bool
    public var outcome: String     // "freed" | "moved_to_trash" | "blocked" | "failed" | "would_trash" | "would_run" | "pending_user" | "requested"
    public var bytes: Int64, message: String?, proposedBy: String?
}
public final class OperationLog: Sendable {
    public init(file: URL)
    public func append(_ record: OperationRecord) throws   // one JSON line + "\n"; O_APPEND|O_CREAT, 0600; flock(LOCK_EX)
    public func records(limit: Int? = nil) throws -> [OperationRecord]   // most recent at the end; unreadable lines are skipped
    public func exportJSON() throws -> Data   // {"exportedAt": ISO8601, "records": [...]}, sorted keys, indented
}
// CleanupRecord gains `public var byAgent: Bool` (decodeIfPresent → false; encoded only if true).
// IndexStore.append: flock(LOCK_EX) on <directory>/history.lock around read-modify-write.
```

- [ ] **Step 1: Write the failing tests**

```swift
@Test func appendAndReadBack()
@Test func skipsCorruptLine()                          // garbage line between two valid ones → 2 records
@Test func concurrentAppendsFromTwoLogsKeepAll() async  // two OperationLog, same file, 200 each → 400
@Test func historyConcurrentAppendsFromTwoStores() async // two IndexStore, same folder, 100 each → history().count == 200
@Test func exportIsValidJSONWithRunIDsAndActors()
@Test func recordFieldsAreMetadataOnly() {             // Mirror: exactly the 14 listed fields (nobody adds "contents")
}
@Test func oldHistoryWithoutByAgentDecodes()
```

- [ ] **Step 2: Run test to verify it fails** — `swift test --filter OperationLogTests` → FAIL.
- [ ] **Step 3: Implement** according to Interfaces.
- [ ] **Step 4: Run tests** — `swift test --filter OperationLogTests` → PASS (7); `swift test --filter IndexStoreTests` → green.
- [ ] **Step 5: Commit** — `feat: exportable operations log with run id and author` (+ Co-Authored-By).

---

### Task 8: Single deletion funnel (preview, author and revalidation)

**Files:**
- Modify: `Sources/DiskMapCore/Cleanup/CleanupExecutor.swift` (internal rewrite: plan → act)
- Test: `Tests/DiskMapCoreTests/FunnelTests.swift`

**Interfaces:**
- Consumes: `SettingsLoad` (Task 3), `PathGate` (Task 4), `RiskClassifier` (Task 5), `ProcessGuard`, `TimeBudget` (Task 6), `OperationLog`, `Actor` (Task 7).
- Produces:
```swift
public struct OperationContext: Sendable, Equatable {
    public let runID: UUID, actor: Actor, proposedBy: String?
    public static func user(runID: UUID = UUID(), proposedBy: String? = nil) -> OperationContext
    public static func agent(_ client: String, runID: UUID = UUID()) -> OperationContext
}
public enum CleanupPreview: Sendable, Equatable {
    case wouldTrash(paths: [String], bytes: Int64)
    case wouldRun(command: [String], bytes: Int64, upperBound: Bool)
    case blocked(reason: String)
}
// CleanupExecutor.init gains (with default values, without breaking existing calls):
//   settings: @escaping @Sendable () -> SettingsLoad = { .missing },
//   log: OperationLog? = nil, processGuard: ProcessGuard = ProcessGuard(),
//   protections: HardProtections = .standard
public func preview(_ item: CleanupItem, context: OperationContext = .user()) async -> CleanupPreview
public func execute(_ item: CleanupItem, context: OperationContext = .user()) async -> CleanupOutcome
public func trashPaths(_ paths: [String], title: String, context: OperationContext = .user()) async -> CleanupOutcome
public func emptyTrash(context: OperationContext = .user()) async -> CleanupOutcome
public func wouldRefuseTrash(path: String) -> Bool     // = PathGate.validate fails (same rule in interface and executor)
```
A single private path `plan(item, context) async -> Result<PlannedAction, PathRefusal>`; `preview` returns it without acting and `execute` executes it. Order of the plan: `settings()` **read on every call** → live classifier (live catalog record + live settings) → agent policy (`allowsAgentActions`; `risk == .safe`; otherwise «Solo se ejecuta lo marcado «Sin problema»…» (Only what is marked «Sin problema» is executed…)) → current blocks (`usedBy`, `.doNotTouch`, `.info`, open `mustBeClosed` apps) → `ProcessGuard` (`checkOpenFiles` only on `.trash` records) → references with `referencesChecked` (`complete == false` ⇒ blocked) → per path: belongs to the record's patterns + `PathGate.validate` → sizes with `TimeBudget.sizeMeasure` (exhausted ⇒ blocked). Acting: for each path, `confirmUnchanged` and then `trashItem` (the only `trashItem` call in the code). Agents: `trashPaths` and `emptyTrash` with an agent context ⇒ `.blocked` always. Each `preview`/`execute`/`trashPaths`/`emptyTrash` adds an `OperationRecord` (`dryRun` in preview); the history marks `byAgent`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func agentCannotExecuteYourCall() async          // .blocked; runner.calls empty; file intact
@Test func agentBlockedWhenToggleOff() async           // settings .loaded(agentsEnabled: false)
@Test func agentBlockedWhenSettingsUnreadable() async
@Test func agentCannotTrashPathsOrEmptyTrash() async   // probes.emptyCount == 0
@Test func agentSafeItemExecutesAndIsLogged() async {
    #expect(outcome == .movedToTrash(10_000))
    #expect(try log.records().last?.actor == .agent(client: "test"))
    #expect(try store.history().last?.byAgent == true)
}
@Test func previewMovesNothingAndMatchesExecute() async   // preview == .wouldTrash(paths, bytes); files remain; execute moves those bytes
@Test func previewRunsNoCommand() async                   // .command record → .wouldRun(["uv","cache","clean"],…); runner.calls empty
@Test func previewAndExecuteBlockForTheSameReason() async // for usedBy, open apps, unknown process, protected
@Test func identityChangeBetweenPlanAndActRefuses() async // internal beforeMove hook replaces the folder with a link to home/Documents → .blocked; Documents intact
@Test func userProtectedRefusedAtExecution() async
@Test func liveSettingsReadPerItem() async                // settings in a Mutex: 1st agent execute ok, it is turned off, 2nd .blocked
@Test func trashItemOnlyCalledFromTheFunnel() throws {    // source: "trashItem(" only in CleanupExecutor.swift;
    // "removeItem(" / "unlink(" / "rmdir(" only in SystemProbes.swift (empty Trash), IndexStore.swift (corrupt index),
    // DataMigration.swift (.partial leftovers), CommandRunner.swift and AIAssistant.swift (their own temporaries)
}
```
(The hook is an `internal` parameter of `init`, `beforeMove: (@Sendable (String) -> Void)? = nil`, for tests only.)

- [ ] **Step 2: Run test to verify it fails** — `swift test --filter FunnelTests` → FAIL.
- [ ] **Step 3: Implement** according to Interfaces.
- [ ] **Step 4: Run tests** — `swift test 2>&1 | tail -3` → all green (the ~60 tests of `CleanupTests` must keep passing; if one changes reason, the new text must be at least as strict).
- [ ] **Step 5: Commit** — `feat: single deletion funnel with preview, author and revalidation` (+ Co-Authored-By).

---

### Task 9: The app uses settings, classifier and funnel (Settings, «Proteger esto», preview, About)

**Files:**
- Create: `Sources/Airy/Settings/SettingsView.swift`
- Modify: `Sources/Airy/AppModel.swift`, `Sources/Airy/AiryApp.swift` (`Settings` scene, «Acerca de Airy»), `Sources/Airy/Cleanup/CleanupFlow.swift` + `ConfirmSheet.swift` (per-row preview, `runID` per batch), `Sources/Airy/Cleanup/CleanupRow.swift`, `Sources/Airy/Map/MapView.swift` (context menu), `Sources/Airy/Map/HoverCard.swift` (risk via `model.classify(path:)`)
- Test: `Tests/DiskMapCoreTests/CleanupBoardTests.swift` (`protectedItemHasNoCheckbox`)

**Interfaces:**
- Consumes: Tasks 2–8.
- Produces (`AppModel`, used by Tasks 10 and 14):
```swift
let paths: AppPaths
let operationLog: OperationLog
private(set) var settingsLoad: SettingsLoad
var settings: AirySettings { settingsLoad.effective }
func updateSettings(_ change: (inout AirySettings) -> Void)   // saves; if mode or list changes → refreshCleanup()
func resetSettings()                                          // SettingsStore.resetUnreadable
func protect(path: String)                                    // updateSettings { $0.protect(path, home:) }
func classify(path: String) -> Classification
func preview(_ items: [CleanupItem]) async -> [String: CleanupPreview]
func perform(_ item: CleanupItem, context: OperationContext) async -> CleanupOutcome
func trash(paths: [String], title: String, context: OperationContext) async -> CleanupOutcome
```
Texts: Settings › «Modo de limpieza» (Cleanup mode) (segmented «Agresivo» / «Prudente»; Aggressive footer: «Borra también lo que se vuelve a descargar o reconstruir solo.» (It also deletes what is downloaded or rebuilt again by itself.); Cautious: «Solo lo más evidente, sin nada «Depende de ti» preseleccionado.» (Only the most obvious, with nothing «Depende de ti» (Up to you) preselected.)); «Agentes» (Agents) (switch «Permitir que los agentes ejecuten limpiezas seguras» (Allow agents to run safe cleanups)); «Protegido por ti» (Protected by you) (list with a remove button, «Añadir carpeta…» (Add folder…) with `NSOpenPanel`, empty: «Nada todavía. Usa «Proteger esto» en el Mapa o en Limpieza.» (Nothing yet. Use «Proteger esto» (Protect this) in the Map or in Cleanup.)). Unreadable settings: `.settings` notice «No se pudieron leer los ajustes (\(reason)). Los agentes no pueden limpiar hasta que los restablezcas.» (The settings could not be read (…). Agents cannot clean until you reset them.) with a «Restablecer ajustes» (Reset settings) button. «Proteger esto» context menu on map blocks and Cleanup rows (non-destructive: no confirmation). Protected rows: «Protegido por ti» / «Protegido por Airy: \(reason)» (Protected by Airy: …), without checkbox. Confirmation sheet: each row shows its preview («Irá a la Papelera» (It will go to the Trash) / «Se ejecutará `uv cache clean`» (`uv cache clean` will be run) / struck through with the reason if it is blocked) and what is blocked is not executed. «Acerca de Airy»: `orderFrontStandardAboutPanel` with credits «Airy adapta ideas y listas de rutas de Mole (github.com/tw93/Mole, GPL-3.0). No incluye código de Mole.» (Airy adapts ideas and path lists from Mole (github.com/tw93/Mole, GPL-3.0). It does not include Mole code.)

- [ ] **Step 1: Write the failing test** — `protectedItemHasNoCheckbox`: `CleanupBoard.canSelect(item(protection: .init(source: .user, …)))` is `false` and `readySafeItems` does not include it.
- [ ] **Step 2: Run** — `swift test --filter CleanupBoardTests` → FAIL until `canSelect` is adjusted if Task 5 did not cover it; if it already passes, continue.
- [ ] **Step 3: Implement** the wiring and the views according to Interfaces (the executor receives `settings: { store.load() }`, `log: operationLog`).
- [ ] **Step 4: Verify** — `swift build && swift test 2>&1 | tail -3` → green. Manual (DEBUG): `AIRY_SUPPORT_DIR=$(mktemp -d) .build/debug/Airy &` (save `$!`): open Settings (⌘,), switch to Cautious and back; «Proteger esto» on a folder of `~/Library/Logs/AiryPrueba` ⇒ it appears in the list and the row shows «Protegido por ti»; open a confirmation and cancel it (confirm nothing); «Acerca de Airy» shows the credit. Stop with `kill <PID>`.
- [ ] **Step 5: Commit** — `feat: the app uses shared settings, the classifier and the funnel` (+ Co-Authored-By).

---

### Task 10: `airy://` URLs and their handling in the app (propose, show, rescan)

**Files:**
- Create: `Sources/DiskMapCore/Integration/AiryURL.swift`
- Modify: `Sources/DiskMapCore/UIState/MapNavigation.swift` (`reveal(path:)`), `Sources/Airy/AiryApp.swift` (`.onOpenURL`, `.handlesExternalEvents(matching: ["*"])`), `Sources/Airy/AppModel.swift` (`handle(url:)`, `pendingURLCommand`), `Sources/Airy/Shell/RootView.swift` (consumes the command with its `CleanupFlow`), `Sources/Airy/Cleanup/CleanupFlow.swift` (`requestClean` gains `warning:` and `proposedBy:`; `requestTrash` gains `proposedBy:`)
- Test: `Tests/DiskMapCoreTests/AiryURLTests.swift`, `Tests/DiskMapCoreTests/AppModelTests.swift` (`revealZoomsToDeepestExistingFolder`)

**Interfaces:**
- Produces:
```swift
public enum AiryURLCommand: Sendable, Equatable {
    public enum ProposeTarget: Sendable, Equatable { case item(String), path(String) }
    case propose(target: ProposeTarget, reason: String, agent: String?)
    case show(path: String)
    case rescan
    public static let scheme = "airy"
    public static let maxReason = 500, maxAgent = 64, maxPath = 1024, maxItemID = 200
    public init?(url: URL)
    public var url: URL
}
extension MapNavigation { public mutating func reveal(path: String) -> Bool }   // true if it reached the end
```
Forms: `airy://propose?item=<id>&reason=<r>&agent=<a>`, `airy://propose?path=<p>&reason=<r>&agent=<a>`, `airy://show?path=<p>`, `airy://rescan` (query with `URLComponents` percent-encoding). `init?(url:)` rejects: scheme ≠ `airy`, unknown host, `item` and `path` together or neither, non-absolute path / with `..` / with control characters / > 1024, id with control or > 200. `reason` and `agent`: control → space, trimmed, truncated to 500 / 64 with «…».
App (`handle(url:)`, never executes anything by itself): `rescan` → Map section and `startScan()` if it is not already analyzing; `show` → Map section and `navigation.reveal(path:)` once there is an analysis; `propose(item)` → Cleanup section, waits for the detection, looks for the id: if missing, notice «Un agente propuso «\(id)», pero ya no aparece en Limpieza.» (An agent proposed «…», but it no longer appears in Cleanup.); if it is «No tocar», notice «Un agente propuso «\(title)», pero es «No tocar»: Airy no lo ofrece.» (An agent proposed «…», but it is «No tocar» (Don't touch): Airy does not offer it.); otherwise `flow.requestClean([item], warning:, proposedBy:)`; `propose(path)` → if `wouldRefuseTrash`, notice with the reason; otherwise `flow.requestTrash(paths: [path], title: last component, warning:, proposedBy:)`. With `flow.isBusy`: notice «Airy está limpiando; vuelve a pedirlo en un momento.» (Airy is cleaning; ask again in a moment.) Warning: title «Un agente propone limpiar esto» (An agent proposes cleaning this), subtitle «\(agent ?? "Un agente") · \(reason.isEmpty ? "sin motivo" : reason)» ("An agent" / "no reason"), reason «Nada se borra hasta que lo confirmes aquí.» (Nothing is deleted until you confirm it here.), note «Revisa qué es antes de seguir.» (Review what it is before continuing.) The user's confirmation is executed with `.user(runID:, proposedBy: agent)`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func roundTripsEveryCommand()                    // url → init → equal, incl. path "/Users/x/Música & Co/ñ#1"
@Test func parseRejectsHostileInput() {
    for s in ["airy://propose?item=a&path=/x&reason=r", "airy://propose?path=x&reason=r",
              "airy://show?path=/a/../b", "airy://show?path=/a%0Ab", "airy://delete?path=/x", "http://propose?item=a"] {
        #expect(AiryURLCommand(url: URL(string: s)!) == nil)
    }
}
@Test func reasonIsSanitisedAndTruncated() {           // 10,000 characters with "\n" → count ≤ 501, without "\n"
}
@Test func revealZoomsToDeepestExistingFolder()        // "/Users/ana/Proyectos/no-existe" → current == Proyectos; returns false
```

- [ ] **Step 2: Run test to verify it fails** — `swift test --filter AiryURLTests` → FAIL.
- [ ] **Step 3: Implement** according to Interfaces.
- [ ] **Step 4: Verify** — `swift test 2>&1 | tail -3` → green. Manual with `bash scripts/build-app.sh` and `open build/Airy.app`: `open 'airy://rescan'` twice ⇒ a single window; `open 'airy://show?path=/Users'` ⇒ zoom; `open 'airy://propose?item=user-logs&reason=prueba&agent=manual'` ⇒ the «Un agente propone…» step and **Cancel**. Stop by PID.
- [ ] **Step 5: Commit** — `feat: airy:// scheme for proposals, show and rescan` (+ Co-Authored-By).

---

### Task 11: MCP core (JSON-RPC over stdio) and `airy-mcp` executable in the package

**Files:**
- Create: `Sources/DiskMapCore/MCP/JSONValue.swift`, `MCPTool.swift`, `MCPServer.swift`, `AiryEnvironment.swift`, `StdioTransport.swift`; `Sources/AiryMCP/main.swift`
- Modify: `Package.swift` (`.executable(name: "airy-mcp", targets: ["AiryMCP"])`, `.executableTarget(name: "AiryMCP", dependencies: ["DiskMapCore"], path: "Sources/AiryMCP")`), `Sources/DiskMapCore/Catalog/Catalog.swift` (`bundled()` also looks in `<executable>/../../Resources`), `Sources/DiskMapCore/System/SystemProbes.swift` (`volumeCapacity`), `scripts/build-app.sh`
- Test: `Tests/DiskMapCoreTests/MCPServerTests.swift`

**Interfaces:**
- Produces:
```swift
public indirect enum JSONValue: Codable, Sendable, Equatable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])
    public subscript(key: String) -> JSONValue? { get }
    public var stringValue: String? { get }; public var intValue: Int? { get }; public var boolValue: Bool? { get }
}
public struct MCPToolAnnotations: Sendable, Equatable { public var readOnly: Bool, destructive: Bool, idempotent: Bool }
public struct MCPToolResult: Sendable, Equatable {
    public var text: String; public var structured: JSONValue?; public var isError: Bool
    public static func ok(_ value: JSONValue, summary: String) -> MCPToolResult   // text = summary + "\n" + indented JSON
    public static func error(_ message: String) -> MCPToolResult
}
public struct MCPCallContext: Sendable { public let environment: AiryEnvironment; public let client: String }
public protocol MCPTool: Sendable {
    var name: String { get }
    var description: String { get }          // Spanish
    var inputSchema: JSONValue { get }       // type object, additionalProperties false
    var annotations: MCPToolAnnotations { get }
    func call(_ arguments: [String: JSONValue], context: MCPCallContext) async -> MCPToolResult
}
public struct MCPToolRegistry: Sendable {
    public init(_ tools: [any MCPTool])
    public var tools: [any MCPTool] { get }
    public func adding(_ tool: any MCPTool) -> MCPToolRegistry
    /// Airy's tools. Task 12 adds the read ones, Task 13 the action ones.
    /// Plan 4 adds `GetPerformanceTool()` and `ProposeQuitAppTool()` here.
    public static func standard() -> MCPToolRegistry
}
public struct VolumeCapacity: Sendable, Equatable { public let total: Int64, available: Int64, importantAvailable: Int64 }
public protocol URLOpening: Sendable { func open(_ url: URL) async -> Bool }
public struct WorkspaceURLOpener: URLOpening { public init() }   // NSWorkspace.open; starts Airy if it is closed
public struct AiryEnvironment: Sendable {
    public let home: String, paths: AppPaths
    public let catalog: Catalog?, catalogError: String?
    public let settings: SettingsStore, index: IndexStore, log: OperationLog
    public let runner: any CommandRunning, probes: any SystemProbing, processGuard: ProcessGuard
    public let references: ReferenceChecker, urlOpener: any URLOpening
    public let capacity: @Sendable () -> VolumeCapacity?
    public init(…all fields…)                // public memberwise (tests)
    public static func live(paths: AppPaths = .standard()) -> AiryEnvironment
    public func classifier() -> RiskClassifier?     // with settings.load().effective
    public func makeScanner() -> CleanupScanner?
    public func makeExecutor() -> CleanupExecutor?  // settings: { settings.load() }, log
}
public actor MCPServer {
    public static let supportedProtocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    public init(registry: MCPToolRegistry, environment: AiryEnvironment, serverVersion: String)
    public func handle(line: String) async -> String?    // nil for notifications and responses
}
public enum StdioTransport {
    public static func run(server: MCPServer, input: FileHandle = .standardInput, output: FileHandle = .standardOutput) async
}
```
Protocol: one JSON message per line; requests are served **in order, one at a time**. `initialize` → `{protocolVersion: the requested one if supported, otherwise "2025-11-25"; capabilities: {tools: {listChanged: false}}; serverInfo: {name: "airy", title: "Airy", version}; instructions: "Airy consulta y limpia el disco de este Mac. Solo ejecuta lo marcado «Sin problema»; lo demás se propone al usuario en la app. Nunca recibes el contenido de los archivos."}` (Airy queries and cleans this Mac's disk. It only executes what is marked «Sin problema»; the rest is proposed to the user in the app. You never receive the contents of files.); it stores `clientInfo.name` (without control characters, ≤ 64; default «agente» (agent)). `ping` → `{}`. `tools/list` → `{tools: [{name, description, inputSchema, annotations: {readOnlyHint, destructiveHint, idempotentHint, openWorldHint: false}}]}`. `tools/call` → `{content: [{type: "text", text}], isError}` plus `structuredContent` if the negotiated version ≥ `2025-06-18`. JSON-RPC errors: parse −32700 (id null), invalid request or batch (array) −32600, unknown method −32601, unknown tool −32602; arguments that do not meet the schema (required, types, `additionalProperties`) → result with `isError: true`. Only JSON-RPC on stdout; diagnostics on stderr.
`main.swift`: `signal(SIGPIPE, SIG_IGN)`; `DataMigration.migrateIfNeeded(.standard())`; `MCPServer(registry: .standard(), environment: .live(), serverVersion: CFBundleShortVersionString of the .app that contains it or "0.2.0")`; `await StdioTransport.run(server:)`; exits on EOF.
`build-app.sh`: copies `$BIN_DIR/airy-mcp` to `Contents/MacOS/airy-mcp` and signs it **before** the app: `codesign --force --options runtime --timestamp=none -i local.airy.Airy.mcp -s "$IDENTITY" …/airy-mcp` (ad-hoc if there is no identity).

- [ ] **Step 1: Write the failing tests** (with `FakeTool` and temporary environment `makeTestEnvironment(home:)`)

```swift
@Test func initializeNegotiatesVersion() async     // "2025-06-18" → echo; "1999-01-01" → "2025-11-25"; serverInfo.name == "airy"
@Test func notificationsGetNoResponse() async      // notifications/initialized → nil
@Test func pingReturnsEmptyResult() async
@Test func toolsListListsRegistry() async          // FakeTool's name, schema and annotations
@Test func unknownMethodIs32601() async
@Test func parseErrorIs32700WithNullID() async
@Test func batchArrayIsRejected() async            // "[...]" → −32600
@Test func unknownToolIs32602() async
@Test func schemaViolationIsToolError() async      // missing required / wrong type / extra key → isError true; FakeTool not called
@Test func structuredContentOnlyFromJune2025() async
@Test func transportWritesOneJSONLinePerResponse() async   // Pipe: 3 lines (initialize, notification, ping) → 2 valid JSON lines
@Test func catalogFoundFromBundledHelperLayout()           // Catalog.bundled(executableURL: tmp/X.app/Contents/MacOS/airy-mcp) with the bundle in Resources
```
(`Catalog.bundled()` gains a variant `bundled(executableURL: URL?)` so the lookup can be tested.)

- [ ] **Step 2: Run test to verify it fails** — `swift test --filter MCPServerTests` → FAIL.
- [ ] **Step 3: Implement** according to Interfaces.
- [ ] **Step 4: Verify** — `swift test --filter MCPServerTests` → PASS (12). Run: `bash scripts/build-app.sh && ls build/Airy.app/Contents/MacOS && codesign --verify --strict build/Airy.app/Contents/MacOS/airy-mcp && printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"prueba","version":"1"}}}' '{"jsonrpc":"2.0","id":2,"method":"ping"}' | build/Airy.app/Contents/MacOS/airy-mcp`
Expected: `Airy  airy-mcp`; verification without errors; two JSON lines (`serverInfo.name` `airy`, `result {}`).
- [ ] **Step 5: Commit** — `feat: airy-mcp MCP server over stdio inside Airy.app` (+ Co-Authored-By).

---

### Task 12: Read-only MCP tools

**Files:**
- Create: `Sources/DiskMapCore/MCP/Tools/ReadTools.swift`, `Sources/DiskMapCore/Catalog/FolderExplanations.swift` (moved from `Sources/Airy/Map/HoverCard.swift:7-60`, now `public`)
- Modify: `MCPToolRegistry.standard()` (adds the four)
- Test: `Tests/DiskMapCoreTests/MCPReadToolTests.swift`

**Interfaces:**
- Consumes: `AiryEnvironment`, `MCPTool` (Task 11); `RiskClassifier` (Task 5); `CleanupBoard`.
- Produces: `GetDiskSummaryTool`, `ListLargestTool`, `ExplainPathTool`, `ListCleanupItemsTool` (all `readOnly: true, destructive: false`) and `public enum MCPFormat { static func risk(_ c: Classification) -> [String: JSONValue] }` → `{"risk": "safe|yourCall|doNotTouch", "risk_label": Risk.label, "protected_by": "airy"|"user"|null, "reasons": [...]}`.

| Tool | Input | Output (`structured`) |
|---|---|---|
| `get_disk_summary` | `{}` | `scan_available`, `last_scan` (ISO 8601 or null), `total_bytes`, `free_bytes`, `purgeable_bytes`, `analyzed_bytes`, `by_kind: [{kind, title, bytes}]` (from `root.kindBytes`, desc), `full_disk_access`; without an index: message «Aún no hay análisis guardado. Abre Airy o usa rescan.» (There is no saved analysis yet. Open Airy or use rescan.) |
| `list_largest` | `path?` (absolute or with `~`, default `/`), `limit?` integer 1…200, default 20 | `path`, `children: [{name, path, bytes, kind, last_modified, is_directory} + MCPFormat.risk]` desc; «Otros» aggregate as `{name:"Otros", aggregated_count, path:null}`; path outside the index → error «Esa carpeta no está en el último análisis.» (That folder is not in the last analysis.) |
| `explain_path` | `path` required | `path`, `known`, `title`, `explanation` (record or `FolderExplanations`), `who_creates_it`, `regenerates`, `size_bytes` (from the index only; otherwise null), `exists` (`lstat`) + `MCPFormat.risk(classify(path:))` |
| `list_cleanup_items` | `{}` | `mode`, `items` in the order of `CleanupBoard(items:).items`: `{id, title, bytes, size_text, upper_bound, method: trash|command|info, command: [String]?, blocked_by_open_apps, used_by, blocked_reason, preselected, highlighted, actionable_by_agent}` + `MCPFormat.risk`; `actionable_by_agent = risk == .safe && CleanupBoard.canSelect(item)` |

Nothing reads file contents (only index, `lstat`, catalog and Cleanup detection).

- [ ] **Step 1: Write the failing tests**

```swift
@Test func summaryWithoutIndex() async             // scan_available false, isError false
@Test func summaryReportsKindsAndDate() async      // ScanResult saved in a temporary IndexStore
@Test func listLargestSortsAndLimits() async       // 3 children, limit 2 → the 2 largest, desc
@Test func listLargestCapsLimitAndRejectsUnknownPath() async   // limit 500 → isError; missing path → isError
@Test func explainKnownCatalogPath() async         // home/.npm/_cacache → title of the npm record, regenerates true
@Test func explainPersonalPathIsYourCall() async   // home/Documents/x → "Tú decides"
@Test func explainProtectedPathIsRed() async       // home/Library/Keychains → "No borrar", protected_by "airy"
@Test func explainUserProtected() async            // protected_by "user"
@Test func listCleanupItemsOrderedLikeBoard() async
@Test func yourCallIsNotActionableByAgent() async
@Test func outputsNeverContainFileContents() async // file with "SECRETO-123" at a cleanup path; no text from the 4 tools contains it
```

- [ ] **Step 2: Run test to verify it fails** — `swift test --filter MCPReadToolTests` → FAIL.
- [ ] **Step 3: Implement** according to Interfaces (the app keeps using `FolderExplanations` from core).
- [ ] **Step 4: Run tests** — `swift test 2>&1 | tail -3` → green.
- [ ] **Step 5: Commit** — `feat: read-only MCP tools (summary, largest, explain, cleanups)` (+ Co-Authored-By).

---

### Task 13: Action MCP tools (green only; the rest is proposed in the app)

**Files:**
- Create: `Sources/DiskMapCore/MCP/Tools/ActionTools.swift`
- Modify: `MCPToolRegistry.standard()` (adds the five; total 9)
- Test: `Tests/DiskMapCoreTests/MCPActionToolTests.swift`

**Interfaces:**
- Consumes: `AiryEnvironment.makeScanner/makeExecutor` (Task 11), `CleanupExecutor.preview/execute` with `.agent(client, runID:)` (Task 8), `AiryURLCommand` (Task 10), `OperationLog` (Task 7).
- Produces: `RunSafeCleanupTool`, `RunSafeCleanupAllTool`, `ProposeCleanupTool`, `ShowInAppTool`, `RescanTool`; `enum AgentGate { static func refusal(_ env: AiryEnvironment) -> String? }`.

| Tool | Input | Behavior |
|---|---|---|
| `run_safe_cleanup` | `item_id` required, `dry_run?` (false) | `AgentGate`; fresh detection; nonexistent id → error; `risk != .safe` or not `canSelect` → explanatory error and nothing executed; otherwise `preview`/`execute` with agent context. Output `{run_id, item_id, title, dry_run, outcome, bytes, message}` |
| `run_safe_cleanup_all` | `dry_run?` | `AgentGate`; `CleanupBoard(items:).readySafeItems` (green only), in sequence, one `run_id`; output `{run_id, dry_run, results: [...], freed_bytes, moved_to_trash_bytes}` |
| `propose_cleanup` | exactly one of `item_id` / `path`; `reason` required (1…500); `dry_run?` | `AgentGate`; nonexistent item or «No tocar», or a path that `wouldRefuseTrash` rejects → error; opens `AiryURLCommand.propose(…, agent: client).url`; output `{status: "pending_user_confirmation", url, message}` |
| `show_in_app` | `path` required, `dry_run?` | `AgentGate`; opens `airy://show?path=` |
| `rescan` | `dry_run?` | `AgentGate`; opens `airy://rescan`; `{status: "scan_requested", message}` |

`dry_run: true` in `propose/show/rescan` returns the URL without opening it. Annotations: `run_*` `destructive: true`; the rest `destructive: false`; none `readOnly`. Every action call adds an `OperationRecord` (agent actor; `propose` → `pending_user`, `show`/`rescan` → `requested`). Fixed texts:
- off: «Has desactivado en Airy que los agentes ejecuten acciones (Asistente › Conectar agente).» (You have turned off in Airy that agents run actions (Assistant › Connect agent).)
- unreadable: «Airy no puede leer sus ajustes; no se ejecuta nada hasta que los revises en la app.» (Airy cannot read its settings; nothing is executed until you review them in the app.)
- amber: ««\(title)» es «Tú decides»: solo se ejecuta lo marcado «Sin problema». Usa propose_cleanup para que el usuario decida en Airy.» («…» is «Tú decides»: only what is marked «Sin problema» is executed. Use propose_cleanup so that the user decides in Airy.)
- red: ««\(title)» es «No borrar»: Airy no lo toca.» («…» is «No borrar»: Airy does not touch it.)
- proposal: «Propuesta enviada a Airy; pendiente de confirmación del usuario.» (Proposal sent to Airy; pending user confirmation.)
- rescan: «Análisis pedido a Airy. Cuando termine, get_disk_summary mostrará la fecha nueva.» (Analysis requested from Airy. When it finishes, get_disk_summary will show the new date.)
- no app: «No se pudo abrir Airy (¿está instalada en /Applications?).» (Airy could not be opened (is it installed in /Applications?).)

- [ ] **Step 1: Write the failing tests** (`FakeRunner`, `FakeProbes`, `FakeOpener` that records URLs, temporary home, test catalog)

```swift
@Test func runSafeCleanupExecutesGreenItem() async       // file under home/Library/Caches/prueba → Trash; log actor .agent("test-client")
@Test func runSafeCleanupRefusesYourCall() async         // isError; runner.calls empty; file intact
@Test func runSafeCleanupRefusesDoNotTouchAndOpenApp() async
@Test func runSafeCleanupDryRunMovesNothing() async      // outcome "would_trash"; file remains; log dryRun true
@Test func agentCommandUsesExactCatalogArguments() async // uv record → runner.calls == [/fake/uv ["cache","clean"]]
@Test func toggleOffBlocksEveryActionTool() async        // all 5, also with dry_run → isError; opener and runner without calls
@Test func unreadableSettingsBlocksActions() async
@Test func runAllOnlyTouchesGreen() async                // A, B green; C preselected amber (Aggressive); D red → only A and B
@Test func runAllStopsWhenToggleTurnsOffMidBatch() async // after the 1st, settings.json becomes agentsEnabled false → 2nd "blocked"
@Test func proposeOpensURLWithoutExecuting() async       // opener receives airy://propose?item=…&agent=test-client; runner and Trash unchanged
@Test func proposeRejectsRedBothTargetsAndMissingReason() async
@Test func proposePathRefusedWhenGateRefuses() async     // home/Library/Keychains
@Test func showAndRescanOpenURLsDryRunDoesNot() async
@Test func registryHasExactlyNineToolsAndNoArbitraryInput() {
    #expect(Set(MCPToolRegistry.standard().tools.map(\.name)) == ["get_disk_summary", "list_largest", "explain_path",
        "list_cleanup_items", "run_safe_cleanup", "run_safe_cleanup_all", "propose_cleanup", "show_in_app", "rescan"])
    // no schema has "command", "args" or "paths"; "path" only in list_largest, explain_path, propose_cleanup, show_in_app
}
```

- [ ] **Step 2: Run test to verify it fails** — `swift test --filter MCPActionToolTests` → FAIL.
- [ ] **Step 3: Implement** according to Interfaces.
- [ ] **Step 4: Run tests** — `swift test 2>&1 | tail -3` → green.
- [ ] **Step 5: Commit** — `feat: action MCP tools (green only, proposals via airy://)` (+ Co-Authored-By).

---

### Task 14: «Conectar agente» tab, activity log and final verification

**Files:**
- Create: `Sources/DiskMapCore/Integration/AgentSnippets.swift`, `Sources/Airy/Assistant/AgentsView.swift`
- Modify: `Sources/Airy/Assistant/AssistantSession.swift` (`Mode.agents`, title «Conectar agente»), `Sources/Airy/Assistant/AssistantView.swift` (the selector stays always active; `.agents` is shown even if Claude is missing)
- Test: `Tests/DiskMapCoreTests/AgentSnippetsTests.swift`

**Interfaces:**
- Consumes: `AppModel.settings/updateSettings/operationLog` (Task 9), `AssistantSession.claude` (located Claude path).
- Produces:
```swift
public struct AgentSnippets: Sendable, Equatable {
    public init(serverPath: String)
    public var claudeCodeArguments: [String]   // ["mcp", "add", "-s", "user", "airy", "--", serverPath]
    public var claudeCode: String              // "claude mcp add -s user airy -- " + shellQuote(serverPath)
    public var codexTOML: String
    public var opencodeJSON: String
    public var genericJSON: String
    public static func shellQuote(_ s: String) -> String   // '…' with ' → '\''
}
public enum ClaudeRegistration: Sendable, Equatable { case added, alreadyPresent, failed(String) }
public enum ClaudeMCP {
    /// `claude mcp add -s user airy -- <path>` with an argument array, 30 s deadline.
    public static func add(claude: String, snippets: AgentSnippets, runner: any CommandRunning) async -> ClaudeRegistration
}
```
Exact texts (`<path>` escaped for each format; TOML: `\` → `\\`, `"` → `\"`; JSON with `JSONSerialization`, sorted keys, indent of 2):
```toml
# ~/.codex/config.toml
[mcp_servers.airy]
command = "<path>"
args = []
```
```json
{ "$schema": "https://opencode.ai/config.json", "mcp": { "airy": { "command": ["<path>"], "enabled": true, "type": "local" } } }
```
```json
{ "mcpServers": { "airy": { "args": [], "command": "<path>" } } }
```
`ClaudeMCP.add`: status 0 → `.added`; stderr/stdout with «already exists» → `.alreadyPresent`; otherwise → `.failed(trimmed stderr)`.
«Conectar agente» view (server path = app executable's folder + `airy-mcp`):
1. Status: «Servidor MCP listo» (MCP server ready) + path in monospace with «Copiar» (Copy); if it does not exist: «No se encuentra airy-mcp junto a Airy. Vuelve a empaquetar con scripts/build-app.sh.» (airy-mcp is not found next to Airy. Repackage with scripts/build-app.sh.); outside `/Applications`: «Instala Airy en Aplicaciones para que esta ruta no cambie.» (Install Airy in Applications so that this path does not change.)
2. Switch «Permitir que los agentes ejecuten limpiezas seguras» (same setting as Settings) with footer «Solo lo marcado «Borrar sin riesgo». Lo demás siempre te lo proponen aquí.» (Only what is marked «Borrar sin riesgo». Everything else is always proposed to you here.)
3. Cards with «Copiar» (`NSPasteboard`): Claude Code (+ button «Añadir a Claude Code» (Add to Claude Code), active if Claude is located; results «Añadido a Claude Code» (Added to Claude Code), «Ya estaba añadido» (It was already added), «No se pudo añadir: …» (Could not be added: …)), Codex, opencode, «Otros agentes (mcpServers)» (Other agents (mcpServers)).
4. «Actividad de los agentes» (Agent activity): `operationLog` records with agent actor or `proposedBy`, most recent first, maximum 200 (relative date, agent, action, title, result, size); empty: «Ningún agente ha usado Airy todavía.» (No agent has used Airy yet.); buttons «Actualizar» (Refresh) and «Exportar registro…» (Export log…) (`NSSavePanel`, name `airy-registro-<yyyy-MM-dd>.json`, writes `exportJSON()`); refreshed on appearing and when the app returns to the foreground.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func claudeCodeQuotesAwkwardPath() {
    let s = AgentSnippets(serverPath: "/Applications/Mi Airy's.app/Contents/MacOS/airy-mcp")
    #expect(s.claudeCode == "claude mcp add -s user airy -- '/Applications/Mi Airy'\\''s.app/Contents/MacOS/airy-mcp'")
    #expect(s.claudeCodeArguments.last == "/Applications/Mi Airy's.app/Contents/MacOS/airy-mcp")
}
@Test func codexEscapesBackslashAndQuote()
@Test func jsonSnippetsParseAndPointToServer()       // opencode: mcp.airy.command == [path]; generic: mcpServers.airy.command == path
@Test func claudeAddUsesArgumentArray() async        // FakeRunner: one call with ["mcp","add","-s","user","airy","--",path]
@Test func claudeAddDetectsAlreadyPresentAndFailure() async
```

- [ ] **Step 2: Run test to verify it fails** — `swift test --filter AgentSnippetsTests` → FAIL.
- [ ] **Step 3: Implement** `AgentSnippets`, `ClaudeMCP` and the view according to Interfaces.
- [ ] **Step 4: Final verification**
  - `swift test 2>&1 | tail -3` → all green (245 from phase 1 + the new ones).
  - `bash scripts/build-app.sh` → «✓ Firmada con "Airy Local Signing"» (Signed with …); `codesign --verify --deep --strict build/Airy.app` with no output.
  - MCP smoke test against the real system (read-only and `dry_run`): send over stdin `initialize`, `notifications/initialized`, `tools/list`, `tools/call get_disk_summary`, `tools/call list_cleanup_items`, `tools/call run_safe_cleanup_all {"dry_run": true}` to `build/Airy.app/Contents/MacOS/airy-mcp` ⇒ 9 tools, a coherent summary, `would_*`/`blocked` results and nothing moved or executed.
  - App (`open build/Airy.app`): Assistant › «Conectar agente» shows status, switch, 4 cards and the smoke test's activity; «Exportar registro…» to a temporary folder produces valid JSON. **Do not** press «Añadir a Claude Code» without the user's permission. Stop by PID.
  - Installation (`bash scripts/build-app.sh --install`) **only with the user present**: the controller asks; after installing, the user grants Full Disk Access again.
- [ ] **Step 5: Commit** — `feat: «Conectar agente» tab with instructions, registration in Claude Code and activity` (+ Co-Authored-By).
