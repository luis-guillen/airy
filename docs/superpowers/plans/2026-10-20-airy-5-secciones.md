# Airy 5 of 5 — Uninstaller, Large & old, Duplicates, File types · Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The four sidebar sections labelled «Próximamente» (Coming soon) start working: an Uninstaller with real size, complete uninstallation, orphaned leftovers and broken links; Large & old; Duplicates; and File types. All four carry the three labels, multiple selection and the wind animations, and everything they delete goes through the single funnel.

**Architecture:** All the logic lives in `DiskMapCore`, tested with temporary folders and doubles (`Apps/` for inventory, leftovers, orphans and links; `Sections/` for large & old, duplicates and types). The new destructive part, which is uninstalling and removing broken links, enters `CleanupExecutor` as methods of the same funnel. The rest reuses `trashPaths`. The app only adds views and `@Observable` stores that call `AppModel`, and the MCP gains read tools plus `propose_uninstall` through `airy://`.

**Tech Stack:** Swift 6.4 (Command Line Tools only), SwiftPM, SwiftUI + AppKit, Swift Testing, CoreServices (`MDItem`), CryptoKit (`SHA256`), `getattrlist`, `launchctl`, `pkgutil`, `osascript`.

**Spec:** `docs/superpowers/specs/2026-10-20-airy-fase-2-design.md` (§2.4 labels, §2.7 sections, §2.9 «Huérfanos y desinstalador más precisos» (More precise orphans and uninstaller), §2.8 MCP) and `docs/superpowers/specs/2026-10-20-diskmap-design.md` (§2 points 3–6, §4 anti-goals, §6 «Papelera» (Trash), «Acciones de la IA» (AI actions), §7b MCP). Path lists: `docs/superpowers/research/2026-10-20-mole-inspiracion.md` §5.1, §5.2, §2.15. Binding plan 1 interfaces: `docs/superpowers/plans/2026-10-20-airy-1-identidad-seguridad-mcp.md` and its *rulings* in `.superpowers/sdd/2026-10-20-airy-1-identidad-seguridad-mcp/progress.md`.

**Consumes, without redefining:** `PathGate`, `HardProtections`, `ProtectionMatch`, `ValidatedPath`, `PathRefusal` (plan 1, Task 4). `RiskClassifier`, `Classification` (Task 5). `ProcessGuard`, `TimeBudget` (Task 6). `OperationLog`, `OperationRecord`, `OperationActor` (Task 7; *ruling* F2: it is called `OperationActor`, not `Actor`). `OperationContext`, `CleanupPreview`, `CleanupExecutor.trashPaths(_:title:context:)`, the `beforeMove` hook (Task 8). `AppModel.classify/trash/settings` (Task 9). `AiryURLCommand`, `MapNavigation.reveal(path:)`, `AppModel.handle(url:)` (Task 10). `MCPTool`, `MCPToolRegistry`, `AiryEnvironment`, `MCPFormat`, `AgentGate` (Tasks 11–13). From plan 2 (`docs/superpowers/plans/2026-10-20-airy-2-marca-animaciones.md`) it uses the `Theme.Airy` palette and `RiskBadge(risk:compact:reason:)` with the texts «Sin problema / Tú decides / No borrar» (No problem / You decide / Do not delete). It also uses its animations: the `.leafAway` transition for each row that leaves; `GustSweep(start:)` + `.gustSway(index:start:)` for batches of several items, as in Cleanup; `WindLeaves(mode: .orbit(radius:))` around the progress; and `BreezeBackground`. All respect `airyAmbientMotion`/`airyTransientMotion` (pause and «Reducir movimiento» (Reduce Motion)).

**Out of this plan:** aggressive catalog entries and profile (plan 3); Performance, quitting apps from Performance, `get_performance`, `propose_quit_app` (plan 4). If plan 3 already created an executor with an administrator password, Task 4 reuses it instead of `PrivilegedRunning`; test names do not change. Plan 4's `ProcessTerminating` works by PID and includes force quit, so the Uninstaller uses its own `AppQuitting` (by bundle id and never forcing). `WorkspaceQuitter` may build on `LiveTerminator.requestQuit`.

## Global Constraints

- Swift 6.4, SwiftPM, Command Line Tools only (no Xcode); `swift build` / `swift test`; platform `.macOS(.v15)`; the test target keeps the `unsafeFlags` of the Swift Testing plugin from Package.swift.
- Interface in **Spanish (Spain)**; MCP tool names in English and response texts in Spanish.
- File contents are **never** sent to the AI or the MCP: only paths, sizes, dates, types and identifiers. The Duplicates fingerprints (hashes) **do not** leave the process that computes them nor are they saved to disk.
- Protected locations, never deletable: Docker volumes, iCloud, Mail, Messages, Keychains, AddressBook, Calendars, Photos, `/Applications`, `/Library`, `/usr`, `/bin`, `/sbin`, `/private`, `/opt/homebrew`, `/System`. Personal folders are never green and runtimes in use are never touched. **Single, bounded exception (Task 2):** the exact `.app` that the user uninstalls, in `/Applications` or `~/Applications`.
- Every destructive action goes through `ConfirmSheet` → `AppModel` → `CleanupExecutor`; files → Trash (`trashItem` only in `CleanupExecutor.swift`); commands with an argument array, never a shell string; nothing is executed without confirmation.
- The AI and the profile only raise risk. The MCP only executes green: in this plan **no** new tool acts, they only read or propose through `airy://`. The agents switch being off blocks `propose_uninstall`, also with `dry_run`.
- Red = no checkbox and no delete button. «Seleccionar todo» (Select all) = green + selectable amber. No step selects red or protected.
- No DEBUG shortcuts that act without confirmation. DEBUG screenshots are only of own windows. To stop the app, kill **only its own PID** (never `pkill -x`). Each manual verification uses its own `AIRY_SUPPORT_DIR`.
- In tests and verification: **a real app is never uninstalled**, real `brew`, `launchctl`, `pkgutil` or `osascript` are not run, and the real Trash is not emptied. `FakeRunner`, `FakePrivileged`, `FakeQuitter`, `FakeLookup` and temporary folders are used. The only real command allowed is `/usr/bin/find … -delete` on an own temporary folder (Task 5).
- Do not touch Keychain trust settings.
- Mole is GPL-3.0: ideas and path lists are adapted, **never code**.
- Views with `@ViewState` (not `@State`); never `.fixedSize(horizontal:false,vertical:true)` on multiline `Text`; **zero CPU at rest** (no continuous `TimelineView`; computation only on opening the section or on request); «Reducir movimiento» replaces animations with fades.
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **The app changes between opening the sheet and confirming** (it updates, moves, another app takes the path or the `.app` becomes a link) → rejection and nothing moved. Test in Task 4: `bundleReplacedAfterPlanIsRefused`.
2. **A duplicate is edited or disappears between the search and the deletion**, or the copy that is kept disappears → that copy does not go to the Trash. Test in Task 7: `verifyRejectsChangedFile`, `verifyRejectsMissingKeeper`, `verifyRefusesRemovingTheKeeper`.
3. **Spotlight off, slow `mdfind` or an unreadable apps folder** → nothing is declared an orphan. Test in Task 5: `mdfindFailureMeansInstalled`, `incompleteInventoryDecidesNothing`.
4. **The app asks to save or does not quit when uninstalling** → nothing is deleted, neither the `.app` nor its leftovers. Test in Task 4: `stillRunningBlocksAndTouchesNothing`.
5. **Odd names in `/usr/local/bin`** (spaces, `*`, `?`, `[`, quotes) or a broken link that points to something again → only that link is removed, and only if it is still broken. Test in Task 5: `deleteCommandEscapesAndOnlyTouchesBrokenSymlinks`.

---

## File structure

```
Sources/DiskMapCore/
  Apps/AppInventory.swift            installed apps, ids, helpers, last use, completeness       (new)
  Apps/HomebrewCasks.swift           app → cask token                                           (new)
  Apps/LeftoverFinder.swift          an app's leftovers (location table)                        (new)
  Apps/UninstallPlan.swift           plan with real size and default selection                  (new)
  Apps/OrphanFinder.swift            orphaned leftovers by bundle id                            (new)
  Apps/BrokenLinks.swift             broken links in /usr/local/bin                             (new)
  System/PrivilegedRunner.swift      one password, commands as arrays                           (new)
  System/AppQuitter.swift            normal quit of apps                                        (new)
  Cleanup/CleanupExecutor+Uninstall.swift  funnel: uninstall and remove links                   (new)
  Safety/HardProtections.swift       ProtectionMatch.rule, matches(...)                         (mod.)
  Safety/PathGate.swift              validate(_:waiver:), ProtectionWaiver                      (mod.)
  Sections/FileSelection.swift       ActionableFile, selection and groups by risk               (new)
  Sections/LargeOldFinder.swift      large & old                                                (new)
  Sections/DuplicateFinder.swift     size → partial hash → full hash                            (new)
  Sections/DuplicateBoard.swift      what to keep, safe selection                               (new)
  Sections/DuplicateReport.swift     duplicates.json without fingerprints (for the MCP)         (new)
  Sections/FileTypeBreakdown.swift   space per type and items of each type                      (new)
  MCP/Tools/SectionTools.swift       list_apps, explain_app, list_orphans, list_large_old,
                                     list_duplicates, propose_uninstall                         (new)
Sources/Airy/Sections/               SectionStores, FileListComponents, LargeOldView, FileTypesView,
                                     TypeDonut, DuplicatesView, UninstallerView, UninstallDetail,
                                     OrphansView                                                (new)
Tests/DiskMapCoreTests/              AppInventoryTests, UninstallGateTests, LeftoverTests,
                                     UninstallFunnelTests, OrphanTests, LargeOldTests,
                                     DuplicateTests, FileTypeTests, MCPSectionToolTests
```

**Ruling: `/Applications` exception.** The phase 1 design asks for an Uninstaller with "complete deletion" (borrado completo) and the hard list seals `/Applications`. The rule is resolved with a **waiver** (`ProtectionWaiver`) that only the uninstall funnel builds and that lets two things through. The first is the exact `.app` being uninstalled, checking its `CFBundleIdentifier` at the moment of acting. The second is the "sensitive" data folders (Mole's layer C) **of that same app**. It never waives critical roots, home-sealed items, data fragments (`keychain`, `1password`…) nor the user's list. Whatever is outside the home (`/Library/...`, separate receipts) is shown in red and is not deleted. Cost: Airy does not clean an app's system leftovers; the user sees that stated.

**Ruling: the MCP.** It gains six tools: five read-only ones (`list_apps`, `explain_app`, `list_orphans`, `list_large_old`, `list_duplicates`) and one proposal tool, `propose_uninstall`, which opens the sheet in Airy. There is no file-types tool, because `get_disk_summary.by_kind` already provides it. To delete a large file, a duplicate or an orphan, the agent uses plan 1's `propose_cleanup(path:)`. `list_duplicates` reads the latest `duplicates.json` that the app saved: the MCP does not read content to look for duplicates.

---

### Task 1: App inventory (`AppInventory`, `HomebrewCasks`)

**Files:**
- Create: `Sources/DiskMapCore/Apps/AppInventory.swift`, `Sources/DiskMapCore/Apps/HomebrewCasks.swift`
- Test: `Tests/DiskMapCoreTests/AppInventoryTests.swift`

**Interfaces:**
- Consumes: `TimeBudget.run` (plan 1, Task 6), `CommandRunning`.
- Produces:
```swift
public struct AppRecord: Sendable, Equatable, Identifiable {
    public let bundleID: String
    public let name: String             // CFBundleDisplayName ?? CFBundleName ?? name of the .app without extension
    public let version: String?         // CFBundleShortVersionString
    public let path: String             // path of the .app
    public let helperBundleIDs: [String] // Contents/Library/LoginItems/*.app, Contents/Helpers/*.app, Contents/XPCServices/*.xpc
    public let isSystem: Bool           // under /System/Applications or id in systemCriticalBundleIDs
    public let isAppStore: Bool         // Contents/_MASReceipt/receipt exists
    public let caskToken: String?
    public let lastUsed: Date?
    public var id: String { path }
    public init(…all fields…)           // public memberwise (tests)
}
public struct AppInventorySnapshot: Sendable, Equatable {
    public let apps: [AppRecord]        // ordered by name (localizedStandardCompare)
    public let complete: Bool
    public let problems: [String]       // in Spanish; empty if complete
    public var installedIDs: Set<String> { get }   // bundleID + helperBundleIDs of all, in lowercase
}
public protocol AppUsageReading: Sendable { func lastUsed(bundlePath: String) -> Date? }
public struct SpotlightUsage: AppUsageReading { public init() }     // MDItemCreateWithURL + kMDItemLastUsedDate
public struct AppInventory: Sendable {
    public static func standardRoots(home: String) -> [String]
        // ["/Applications", "/System/Applications", home+"/Applications", "/opt/homebrew/Caskroom",
        //  "/usr/local/Caskroom", home+"/Library/Application Support/Setapp/Applications"]
    public static let systemCriticalBundleIDs: Set<String>
        // com.apple.Safari, com.apple.finder, com.apple.systempreferences, com.apple.SystemSettings (if it exists), com.apple.AppStore,
        // com.apple.ActivityMonitor, com.apple.Terminal, com.apple.mail, com.apple.MobileSMS, com.apple.Photos, com.apple.iCal,
        // com.apple.AddressBook, com.apple.keychainaccess, com.apple.backup.launcher, com.apple.DiskUtility
    public static let officialUninstallerPrefixes: [String]
        // "com.crowdstrike.", "com.sentinelone.", "com.sentinel-labs.", "com.eset.", "com.jamf.", "com.jamfsoftware.",
        // "com.paloaltonetworks.", "com.cisco.anyconnect", "com.cisco.secureclient"
    public init(roots: [String], usage: any AppUsageReading = SpotlightUsage(), casks: [String: String] = [:],
                budget: Duration = .seconds(5))
    public func snapshot() async -> AppInventorySnapshot
    /// As is, without spaces, spaces → "_", spaces → "-", and in lowercase; empty if the name has < 4 characters
    /// or is in genericNames ("notes", "mail", "music", "photos", "preview", "books", "news", "home", "files", "app", "helper").
    public static func nameVariants(_ name: String) -> [String]
}
public enum HomebrewCasks {
    /// `brew info --cask --installed --json=v2` (60 s) → [name of the .app: token]. `nil` if brew is not there or fails.
    public static func installed(runner: any CommandRunning) async -> [String: String]?
    static func parse(_ json: String) -> [String: String]   // casks[].token and casks[].artifacts[].app (strings or {"target": …})
}
```
Rules:
- It looks for `*.app` down to **depth 3** under each root and does not enter an `.app`. Exception: an iOS app whose `Contents/Info.plist` is missing and that has `Wrapper/*.app` uses that wrapper's `Info.plist`. It does not follow folder symbolic links.
- A root that does not exist (`ENOENT`) is normal. There is an **incomplete inventory** (`complete == false` and a reason in `problems`) if any of these happens: a root exists but cannot be read; an `.app` has no readable `Info.plist` or lacks `CFBundleIdentifier`; or the whole walk (inside `TimeBudget.run(budget)`) does not finish in time.
- `caskToken` comes from `casks[name of the .app]`.

- [ ] **Step 1: Write the failing tests** (fake apps in a temporary folder: `Foo.app/Contents/Info.plist` written with `PropertyListSerialization`; `FakeUsage` and `FakeRunner` from `CleanupTests.swift`)

```swift
@Test func findsAppsWithIDNameAndVersion() async      // id "com.example.foo", name "Foo", version "1.2"
@Test func vendorFolderDepthTwoFoundDepthFourNot() async
@Test func helpersAreCollected() async                // LoginItems/Helper.app id → helperBundleIDs and installedIDs (lowercase)
@Test func unreadablePlistMakesSnapshotIncomplete() async   // corrupt Info.plist → complete false, problems not empty
@Test func unreadableRootMakesSnapshotIncomplete() async    // chmod 000 on the root (and restore in defer)
@Test func missingRootIsFine() async                  // nonexistent root → complete true
@Test func budgetExhaustedIsIncomplete() async        // budget .zero → complete false
@Test func appStoreAndSystemFlags() async             // _MASReceipt/receipt → isAppStore; id com.apple.Safari → isSystem
@Test func iOSWrapperUsesInnerPlist() async
@Test func nameVariantsSkipShortAndGeneric()            // "Foo Bar" → ["Foo Bar","FooBar","Foo_Bar","Foo-Bar","foo bar"…]; "Notes", "Abc" → []
@Test func caskTokenFromBrewJSON() {
    let json = #"{"casks":[{"token":"visual-studio-code","artifacts":[{"app":["Visual Studio Code.app"]}]}]}"#
    #expect(HomebrewCasks.parse(json) == ["Visual Studio Code.app": "visual-studio-code"])
}
@Test func brewMissingGivesNil() async                // FakeRunner without "brew" resolved → nil
```

- [ ] **Step 2: Run test to verify it fails.** Run `swift test --filter AppInventoryTests`. Expected: FAIL (undefined types).
- [ ] **Step 3: Implement** according to Interfaces. `SpotlightUsage` uses `MDItemCreateWithURL` and `MDItemCopyAttribute(kMDItemLastUsedDate)`, without launching processes.
- [ ] **Step 4: Run tests.** Run `swift test --filter AppInventoryTests`. Expected: PASS (12).
- [ ] **Step 5: Commit.** Message: `feat: inventory of installed apps with helpers, last use and casks` (+ Co-Authored-By).

---

### Task 2: Bounded waiver for uninstalling (`ProtectionWaiver`)

**Files:**
- Modify: `Sources/DiskMapCore/Safety/HardProtections.swift` (each match carries its rule; `matches` returns all; internal test init with sealed locations), `Sources/DiskMapCore/Safety/PathGate.swift` (`validate(_:waiver:)`)
- Test: `Tests/DiskMapCoreTests/UninstallGateTests.swift`

**Interfaces:**
- Consumes: `AppRecord`, `AppInventory.officialUninstallerPrefixes`, `AppInventory.nameVariants` (Task 1).
- Produces:
```swift
extension ProtectionMatch {
    public enum Rule: String, Sendable { case critical, sealedSystem, sealedHome, upward, fragment, sensitiveAppData, other }
    public let rule: Rule        // new stored field; init gains `rule: Rule = .other`
}
extension HardProtections {
    /// All the matches, in the order in which `match` checks them; `match(...) == matches(...).first`.
    public func matches(canonicalPath: String, home: String, catalog: Catalog?) -> [ProtectionMatch]
    init(criticalRoots: [String], sealedSystemLocations: [String])   // tests only
}
public struct ProtectionWaiver: Sendable, Equatable {
    public let bundlePath: String      // canonical
    public let bundleID: String
    public let ownedNames: [String]    // lowercase: bundleID, helperBundleIDs, AppInventory.nameVariants(name)
    /// `nil` (no waiver) if: app.isSystem; id with a prefix of officialUninstallerPrefixes; id with prefix "local.airy.";
    /// or app.path does not hang from an element of `appRoots` at depth 1 or 2.
    public static func uninstall(_ app: AppRecord, appRoots: [String]) -> ProtectionWaiver?
    public static func productionAppRoots(home: String) -> [String]   // ["/Applications", home + "/Applications"]
}
extension PathGate {
    /// plan 1's `validate(_:)` is `validate(_:waiver: nil)`.
    public func validate(_ path: String, waiver: ProtectionWaiver?) -> Result<ValidatedPath, PathRefusal>
}
```
Waiver rules: everything else in `validate` stays the same (syntax, resolved forms, critical roots' inode, user list).
- **If the path is the exact `.app`** (`== bundlePath`), only the matches of two rules are waived: `.sealedSystem` with pattern `/Applications` and `.fragment`. In addition, the `.app` cannot be a link and its `Contents/Info.plist`, read at that moment, must give `CFBundleIdentifier == bundleID`. If not, the refusal is «Ya no es la app que elegiste.» (It is no longer the app you chose.).
- **Any other path:** only `.sensitiveAppData` matches whose last component belongs to the app are waived. That component is lowercased, `.savedState`, `.plist` and `.binarycookies` are stripped from it, and it must equal `bundleID` or be in `ownedNames`.
- Nothing inside the `.app` nor the `/Applications` folder counts as the `.app`.

- [ ] **Step 1: Write the failing tests** (`HardProtections(criticalRoots: [], sealedSystemLocations: [tmp + "/Applications"])`, fake app `tmp/Applications/Foo.app`, temporary home)

```swift
@Test func bundlePassesOnlyWithItsOwnWaiver() {
    #expect(gate.validate(foo, waiver: nil) is refusal)
    #expect(gate.validate(foo, waiver: .uninstall(fooApp, appRoots: [apps])) is success)
    #expect(gate.validate(apps + "/Other.app", waiver: fooWaiver) is refusal)
    #expect(gate.validate(apps, waiver: fooWaiver) is refusal)
    #expect(gate.validate(foo + "/Contents/MacOS/Foo", waiver: fooWaiver) is refusal)
}
@Test func waiverRefusesWhenBundleIDChanged()          // rewrites Info.plist with another id → «Ya no es la app que elegiste.»
@Test func symlinkBundleRefused()
@Test func noWaiverForSystemOfficialUninstallerOrAiry() // isSystem; "com.crowdstrike.falcon"; "local.airy.Airy"; depth 3 → nil
@Test func sensitiveDataWaivedOnlyForOwner()           // home/Library/Application Support/Slack: Slack ok, without a waiver and with Discord's → refusal
@Test func sealedHomeNeverWaived()                     // com.docker.docker waiver over home/Library/Containers/com.docker.docker → refusal
@Test func fragmentDataNeverWaived()                   // 1Password waiver over home/Library/Application Support/1Password → refusal
@Test func userProtectedNeverWaived()
@Test func matchIsFirstOfMatches()                     // for 20 paths from PathGateTests: match == matches.first, same rules
```

- [ ] **Step 2: Run test to verify it fails.** Run `swift test --filter UninstallGateTests`. Expected: FAIL.
- [ ] **Step 3: Implement** according to Interfaces. Each `return` of `match` now adds to a list with its `Rule`, and `match` returns the first one.
- [ ] **Step 4: Run tests.** Run `swift test --filter "UninstallGateTests|PathGateTests|FunnelTests"`. Expected: PASS; plan 1's tests do not change.
- [ ] **Step 5: Commit.** Message: `feat: bounded PathGate waiver to uninstall a specific app` (+ Co-Authored-By).

---

### Task 3: An app's leftovers and uninstall plan (`LeftoverFinder`, `UninstallPlan`)

**Files:**
- Create: `Sources/DiskMapCore/Apps/LeftoverFinder.swift`, `Sources/DiskMapCore/Apps/UninstallPlan.swift`
- Test: `Tests/DiskMapCoreTests/LeftoverTests.swift`

**Interfaces:**
- Consumes: `AppRecord`, `AppInventorySnapshot` (Task 1), `ProtectionWaiver`, `PathGate.validate(_:waiver:)` (Task 2), `AllocatedSize.of`, `TimeBudget`.
- Produces:
```swift
public struct Leftover: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable {
        case appSupport, caches, containers, preferences, byHost, savedState, httpStorage, logs, launchAgent, webKit,
             cookies, applicationScripts, autosave, syncedPreferences, plugin, receipt, systemLocation
    }
    public let path: String            // in .receipt: the pkg id
    public let kind: Kind
    public let bytes: Int64
    public let risk: Risk
    public let preselected: Bool
    public let matchedByName: Bool
    public let reason: String          // why this label (Spanish)
    public let launchLabel: String?    // .launchAgent only
    public var id: String { kind.rawValue + ":" + path }
    public var canSelect: Bool { risk != .doNotTouch }
}
public struct UninstallPlan: Sendable, Equatable, Identifiable {
    public let app: AppRecord
    public let appBytes: Int64
    public let leftovers: [Leftover]   // risk asc, bytes desc, path
    public let refusal: String?
    public let sharedWith: String?
    public let sizeComplete: Bool
    public var id: String { app.path }
    public var leftoverBytes: Int64 { get }          // leftovers with canSelect
    public var realBytes: Int64 { get }              // appBytes + leftoverBytes
    public var defaultSelection: Set<String> { get } // preselected && canSelect
    public func bytes(selected: Set<String>) -> Int64 // appBytes + selected
}
public struct LeftoverFinder: Sendable {
    public init(home: String, gate: PathGate, runner: any CommandRunning, appRoots: [String],
                systemLibrary: String = "/Library", budget: Duration = TimeBudget.sizeMeasure)
    public func plan(for app: AppRecord, inventory: AppInventorySnapshot) async -> UninstallPlan
}
```
Location table (under `home/Library`). "id" means `bundleID` or a `helperBundleID`; "name" means one of the `AppInventory.nameVariants`.

| Kind | Path | Matches by | Risk | Presel. | Visible reason |
|---|---|---|---|---|---|
| appSupport | `Application Support/<id\|name>` | id, name | You decide | yes | «Datos y ajustes de la app; si la reinstalas empezará de cero.» (The app's data and settings; if you reinstall it, it will start from scratch.) |
| caches | `Caches/<id\|name>` | id, name | No problem | yes | «Caché: se regenera.» (Cache: it regenerates.) |
| containers | `Containers/<id>` | id | You decide | yes | «Datos de la app (sandbox).» (App data (sandbox).) |
| preferences | `Preferences/<id>.plist` | id | You decide | yes | «Ajustes de la app.» (The app's settings.) |
| byHost | `Preferences/ByHost/<id>.*.plist` | id | You decide | yes | «Ajustes de la app en este Mac.» (The app's settings on this Mac.) |
| savedState | `Saved Application State/<id>.savedState` | id | No problem | yes | «Estado de ventanas: se regenera.» (Window state: it regenerates.) |
| httpStorage | `HTTPStorages/<id>` and `<id>.binarycookies` | id | No problem | yes | «Datos de red de la app.» (The app's network data.) |
| logs | `Logs/<id\|name>` | id, name | No problem | yes | «Registros.» (Logs.) |
| launchAgent | `LaunchAgents/*.plist` whose `Label` is an id or starts with `<id>.`, or whose `Program`/`ProgramArguments[0]` is inside `app.path` | plist | You decide | yes | «Se ejecuta al iniciar sesión; se detiene antes.» (It runs at login; it is stopped first.) |
| webKit | `WebKit/<id>`, `WebKit/com.apple.WebKit.WebContent/<id>` | id | No problem | yes | «Caché web de la app.» (The app's web cache.) |
| cookies | `Cookies/<id>.binarycookies` | id | No problem | yes | «Cookies de la app.» (The app's cookies.) |
| applicationScripts | `Application Scripts/<id>` | id | You decide | yes | «Scripts de la app.» (The app's scripts.) |
| autosave | `Autosave Information/<id>` | id | You decide | **no** | «Puede tener documentos sin guardar.» (It may have unsaved documents.) |
| syncedPreferences | `SyncedPreferences/<id>.plist` | id | You decide | yes | «Ajustes sincronizados.» (Synced settings.) |
| plugin | `Services/<name>.workflow`, `QuickLook/<name>.qlgenerator`, `Audio/Plug-Ins/{Components,VST,VST3}/<name>.*` | name | You decide | **no** | «Otras apps pueden usar este complemento.» (Other apps may use this plug-in.) |
| receipt | `pkgutil --file-info <app.path>` → lines `pkgid: X` (10 s) | — | No problem | yes | «Registro de instalación; pide contraseña de administrador.» (Installation record; asks for the administrator password.) |
| systemLocation | `<systemLibrary>/{Application Support,Caches,Logs,Preferences,LaunchAgents,LaunchDaemons,PrivilegedHelperTools}/<id\|name>*` | id, name | Do not delete | no | «Fuera de tu carpeta personal: Airy no lo borra.» (Outside your personal folder: Airy does not delete it.) |

Rules, applied in this order:
1. **Name only** (id+name row where the name fits but the id does not): You decide, not preselected, `matchedByName = true`, reason «Coincide por nombre: revisa que sea de «\(name)».» (It matches by name: check that it belongs to «…».).
2. Each path goes through `gate.validate(path, waiver: .uninstall(app, appRoots:))`. If there is a refusal: Do not delete, reason = the refusal's. If `validate(path, waiver: nil)` refuses but with the waiver it passes: You decide, **not** preselected, reason «Datos de cuenta de «\(name)»: si la reinstalas tendrás que volver a configurarla.» (Account data of «…»: if you reinstall it you will have to set it up again.).
3. Floor: `strictest(row, RiskPolicy.minimumRisk(forPath:home:))`.
4. **Another installed copy:** if the inventory has another `AppRecord` with the same `bundleID` and a different path, `sharedWith` = that path and all leftovers become Do not delete with «Otra copia instalada en \(path) los usa.» (Another copy installed at … uses them.).
5. **It cannot be uninstalled:** if `ProtectionWaiver.uninstall` gives `nil`, `refusal` is filled in:
   - system: «Es parte de macOS.» (It is part of macOS.);
   - official uninstaller prefix: «Usa el desinstalador oficial de «\(name)».» (Use the official uninstaller of «…».);
   - `local.airy.*`: «Es Airy.» (It is Airy.);
   - Setapp path: «Desinstálala desde Setapp.» (Uninstall it from Setapp.);
   - any other path: «Solo se desinstalan apps de Aplicaciones.» (Only apps from Applications are uninstalled.).
6. Sizes with `AllocatedSize.of` inside `TimeBudget.run(budget)`. If it runs out, `sizeComplete = false` and what was not measured stays at 0 bytes.

- [ ] **Step 1: Write the failing tests** (temporary home and roots, app `com.example.foo` «Foo Bar», `FakeRunner` with output `pkgid: com.example.foo.pkg` for `pkgutil`)

```swift
@Test func findsLeftoversByBundleIDInEveryHomeLocation() async   // Set(kinds) ⊇ all except receipt/systemLocation/plugin
@Test func riskTableAndPreselection() async   // caches .safe yes; appSupport .yourCall yes; autosave .yourCall no; plugin no
@Test func nameOnlyMatchIsYourCallUnselected() async               // Application Support/FooBar
@Test func shortOrGenericNamesDoNotMatch() async                   // app «Notes» and «Abc»: no leftover by name
@Test func launchAgentOwnedByLabelOrProgram() async                // Label com.example.foo.helper ✓; ProgramArguments in Foo.app ✓; other ✗
@Test func receiptsFromPkgutil() async                             // runner.calls contains ["/usr/sbin/pkgutil", ["--file-info", app.path]]
@Test func systemLibraryRowsAreRedInfo() async                     // systemLibrary = tmp/Library with Caches/com.example.foo
@Test func sensitiveDataIsAmberUnselected() async                  // Slack app: Application Support/Slack .yourCall, preselected false
@Test func protectedLeftoverIsRed() async                          // user ProtectList with Caches/com.example.foo
@Test func secondCopyMakesLeftoversInformational() async           // sharedWith != nil; all .doNotTouch; defaultSelection empty
@Test func refusalTexts() async                                    // the five exact sentences
@Test func realSizeAddsAppAndSelectableLeftovers() async           // realBytes == appBytes + sum of canSelect
```

- [ ] **Step 2: Run test to verify it fails.** Run `swift test --filter LeftoverTests`. Expected: FAIL.
- [ ] **Step 3: Implement** according to Interfaces and table. LaunchAgents' `plist` files are read with `PropertyListSerialization`; unreadable ones are skipped.
- [ ] **Step 4: Run tests.** Run `swift test --filter LeftoverTests`. Expected: PASS (12).
- [ ] **Step 5: Commit.** Message: `feat: each app's leftovers and uninstall plan with real size` (+ Co-Authored-By).

---

### Task 4: Uninstall funnel (quit, `launchctl bootout`, Homebrew or Trash, receipts)

**Files:**
- Create: `Sources/DiskMapCore/System/PrivilegedRunner.swift`, `Sources/DiskMapCore/System/AppQuitter.swift`, `Sources/DiskMapCore/Cleanup/CleanupExecutor+Uninstall.swift`
- Modify: `Sources/DiskMapCore/Cleanup/CleanupExecutor.swift`. The `init` gains three default parameters: `privileged: any PrivilegedRunning = OsascriptPrivilegedRunner()`, `quitter: any AppQuitting = WorkspaceQuitter()` and `appRoots: [String]? = nil` (`nil` ⇒ `ProtectionWaiver.productionAppRoots(home:)`). It also gains an internal method `trashValidated(_ v: ValidatedPath) throws -> Int64`, which is the only call to `trashItem`.
- Modify: `Sources/DiskMapCore/Persistence/OperationLog.swift` (`action` comment: plus `"uninstall"`, `"remove_broken_links"`).
- Test: `Tests/DiskMapCoreTests/UninstallFunnelTests.swift`

**Interfaces:**
- Consumes: `UninstallPlan`, `Leftover` (Task 3), `ProtectionWaiver` (Task 2), `OperationContext`, `OperationLog`, the `beforeMove` hook (plan 1, Task 8).
- Produces:
```swift
public enum PrivilegedOutcome: Sendable, Equatable { case ok(CommandOutput), cancelled, failed(String) }
public protocol PrivilegedRunning: Sendable {
    /// A single password request for all the commands; each one is [executable, arguments…].
    func run(_ commands: [[String]], prompt: String) async -> PrivilegedOutcome
}
public struct OsascriptPrivilegedRunner: PrivilegedRunning {
    public init(runner: any CommandRunning = ProcessRunner())
    /// Fixed AppleScript text (`on run argv`): rebuilds each command with `quoted form of` of each argument,
    /// joins them with " ; " and calls `do shell script … with administrator privileges with prompt (item 1 of argv)`.
    static let scriptLines: [String]
    /// ["-e", line…, "--", prompt, "\(n1)", exe1, args1…, "\(n2)", exe2, args2…]; n = number of elements of the command.
    static func arguments(for commands: [[String]], prompt: String) -> [String]
    // status 0 → .ok; stderr with "-128" → .cancelled; other → .failed(stderr trimmed to 300)
}
public enum QuitResult: Sendable, Equatable { case notRunning, quit, stillRunning, unknown }
public protocol AppQuitting: Sendable {
    func isRunning(bundleID: String) -> Bool?                           // nil = unknown
    func quit(bundleID: String, timeout: Duration) async -> QuitResult  // normal quit (terminate()); never forceTerminate()
}
public struct WorkspaceQuitter: AppQuitting { public init() }           // NSRunningApplication.runningApplications(withBundleIdentifier:)
public struct UninstallRequest: Sendable, Equatable, Identifiable {
    public let plan: UninstallPlan
    public let selected: Set<String>   // Leftover ids
    public var id: String { plan.id }
    public init(plan: UninstallPlan, selected: Set<String>)
}
public struct UninstallReport: Sendable, Equatable {
    public var outcome: CleanupOutcome    // .movedToTrash(trashed) if anything went to the Trash; otherwise .freed(freed); or .blocked/.failed
    public var trashedBytes: Int64, freedBytes: Int64
    public var notes: [String]            // steps that failed without stopping the rest (Spanish)
}
extension CleanupExecutor {
    public func uninstall(_ request: UninstallRequest, context: OperationContext = .user()) async -> UninstallReport
}
```
Fixed order of `uninstall` (each `blocked` leaves everything as it was):
1. If `context.actor != .user`: `.blocked("Los agentes no pueden desinstalar apps; solo proponerlo en Airy.")` (Agents cannot uninstall apps; they can only propose it in Airy.).
2. If `plan.refusal`, or if `ProtectionWaiver.uninstall(app, appRoots:)` is `nil`: `.blocked(reason)`.
3. The `.app` is validated again with `gate.validate(app.path, waiver:)`; if it fails, `.blocked(reason)`.
4. **Quit.** First `isRunning(bundleID)`: `nil` ⇒ `.blocked("No se pudo comprobar si «\(name)» está abierta; Airy no sigue.")` (Could not check whether «…» is open; Airy does not continue.). For the main id and each helper that is open, `quit(timeout: .seconds(30))` is called. With `.stillRunning` or `.unknown`: `.blocked("«\(name)» sigue abierta (quizá te pide guardar algo). Ciérrala y vuelve a intentarlo.")` («…» is still open (maybe it asks you to save something). Close it and try again.).
5. For each selected `.launchAgent`: `runner.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"], timeout: 15)`. A status other than 0 adds the note «No se pudo detener \(label): \(stderr).» (Could not stop …: ….) and continues.
6. **Homebrew** (`caskToken != nil` and `runner.resolve("brew")` is not `nil`): `["uninstall", "--cask", "--zap", token]` with 600 s. A status other than 0 gives `.failed("Homebrew no pudo desinstalarla: \(stderr trimmed to 300)")` (Homebrew could not uninstall it: …) and stops there. If at the end the `.app` is still in place, it goes to the Trash as in step 7. With `caskToken` but without `brew`, it adds the note «Homebrew no está disponible; la app va a la Papelera.» (Homebrew is not available; the app goes to the Trash.) and continues to step 7. `freedBytes` = bytes measured before of what no longer exists afterwards.
7. **Trash:** `confirmUnchanged` and then `trashValidated` of the `.app`.
8. Selected leftovers with `canSelect` (not `.receipt` nor `.systemLocation`) that still exist: for each one, `validate(_:waiver:)`, `confirmUnchanged` and `trashValidated`. If one is rejected, a note with the reason and it is skipped.
9. Selected receipts: **one** call `privileged.run(ids.map { ["/usr/sbin/pkgutil", "--forget", $0] }, prompt: "Airy necesita tu contraseña para borrar el registro de instalación de «\(name)».")` (Airy needs your password to delete the installation record of «…».). If it is `.cancelled`, note «Cancelaste la contraseña: el registro de instalación se queda.» (You cancelled the password: the installation record stays.); if it is `.failed`, a note with the reason.
10. An `OperationRecord` is added with `action "uninstall"`, `itemID` = bundleID, `title` = name, `paths` = what went to the Trash, `command` = brew's arguments if there were any, `message` = notes joined by « · ». The history is recorded as in `trashPaths` (Trash ≠ freed).

- [ ] **Step 1: Write the failing tests** (`HardProtections(criticalRoots: [], sealedSystemLocations: [apps])`, `appRoots: [apps]`; `FakeQuitter` that records calls; `FakePrivileged` that records `commands` and returns what is configured; `FakeRunner`)

```swift
@Test func agentCannotUninstall() async                // .agent("x") → .blocked; nothing moved; no calls
@Test func refusedPlanDoesNothing() async
@Test func quitsBeforeTrashing() async                 // FakeQuitter running → quit → .app in the Trash; quitter.calls == ["com.example.foo"]
@Test func stillRunningBlocksAndTouchesNothing() async // .stillRunning → .blocked; .app and leftovers remain; runner without calls
@Test func unknownRunningStateBlocks() async           // isRunning nil
@Test func bootsOutSelectedLaunchAgents() async        // ["/bin/launchctl", ["bootout", "gui/\(getuid())/com.example.foo.helper"]]
@Test func brewCaskRunsZapFirst() async                // first call: brew ["uninstall","--cask","--zap","foo"]
@Test func brewFailureStopsBeforeTrash() async         // status 1 → .failed; .app and leftovers remain
@Test func onlySelectedLeftoversAreTrashed() async
@Test func leftoverSwappedForSymlinkIsRefused() async  // beforeMove swaps Caches/com.example.foo for a link to home/Documents → note; Documents intact
@Test func bundleReplacedAfterPlanIsRefused() async    // after planning, Info.plist with another id → .blocked; nothing moved
@Test func receiptsUseOnePrivilegedCallWithArgumentArrays() async {
    #expect(privileged.calls == [[["/usr/sbin/pkgutil", "--forget", "com.example.foo.pkg"],
                                  ["/usr/sbin/pkgutil", "--forget", "com.example.foo.extra"]]])
}
@Test func cancelledPasswordKeepsRestAndNotes() async  // .cancelled → outcome .movedToTrash; notes contains «Cancelaste la contraseña…»
@Test func osascriptArgumentsNeverInterpolateIntoScript() {
    let hostile = "a'; rm -rf ~ #"
    let args = OsascriptPrivilegedRunner.arguments(for: [["/bin/echo", hostile]], prompt: "p")
    #expect(args.contains(hostile))
    #expect(!OsascriptPrivilegedRunner.scriptLines.joined().contains(hostile))
    #expect(OsascriptPrivilegedRunner.scriptLines.joined().contains("quoted form of"))
}
@Test func uninstallIsLogged() async                    // log.records().last?.action == "uninstall", actor .user
```

- [ ] **Step 2: Run test to verify it fails.** Run `swift test --filter UninstallFunnelTests`. Expected: FAIL.
- [ ] **Step 3: Implement** according to Interfaces and order. Plan 1's test `trashItemOnlyCalledFromTheFunnel` must keep passing: `CleanupExecutor+Uninstall.swift` does not call `trashItem(` directly.
- [ ] **Step 4: Run tests.** Run `swift test 2>&1 | tail -3`. Expected: all green.
- [ ] **Step 5: Commit.** Message: `feat: complete uninstall through the funnel (quit, bootout, Homebrew or Trash, receipts)` (+ Co-Authored-By).

---

### Task 5: Orphaned leftovers and broken links

**Files:**
- Create: `Sources/DiskMapCore/Apps/OrphanFinder.swift`, `Sources/DiskMapCore/Apps/BrokenLinks.swift`
- Modify: `Sources/DiskMapCore/Cleanup/CleanupExecutor+Uninstall.swift` (`removeBrokenLinks`)
- Test: `Tests/DiskMapCoreTests/OrphanTests.swift`

**Interfaces:**
- Consumes: `AppInventorySnapshot` (Task 1), `PathGate`, `PrivilegedRunning` (Task 4).
- Produces:
```swift
public struct OrphanGroup: Sendable, Equatable, Identifiable {
    public let bundleID: String
    public let paths: [String]
    public let bytes: Int64
    public let lastModified: Date
    public let risk: Risk                // .safe (protected ones do not get here)
    public var id: String { bundleID }
}
public enum OrphanScan: Sendable, Equatable { case found([OrphanGroup]), undecided(String) }
public protocol BundleIDLookup: Sendable { func isInstalled(_ bundleID: String) async -> Bool? }   // nil = unknown
public struct SpotlightLookup: BundleIDLookup {
    public init(runner: any CommandRunning, timeout: TimeInterval = 5)
    // /usr/bin/mdfind ["kMDItemCFBundleIdentifier == \"\(id)\""]: non-empty output → true; empty with status 0 → false; other → nil
}
public struct OrphanFinder: Sendable {
    public static let minimumIdle: TimeInterval = 30 * 86_400
    public static let candidateFolders = ["Library/Caches", "Library/Logs", "Library/Saved Application State"]
    public static let sensitivePatterns = ["ssh", "gpg", "gnupg", "keychain", "1password", "bitwarden", "lastpass",
                                           "keepass", "dashlane", "enpass"]
    public init(home: String, gate: PathGate, lookup: any BundleIDLookup, now: @escaping @Sendable () -> Date = Date.init)
    public func scan(inventory: AppInventorySnapshot) async -> OrphanScan
    /// Right before deleting: the same decision tree with a fresh inventory.
    public func stillOrphan(_ group: OrphanGroup, inventory: AppInventorySnapshot) async -> Bool
    /// "com.foo.bar" or "com.foo.bar.savedState" → id; only com|org|net|io, ≥ 3 components, [A-Za-z0-9._-].
    static func bundleID(fromEntryName name: String) -> String?
}
public struct BrokenLink: Sendable, Equatable, Identifiable {
    public let path: String, target: String, needsAdmin: Bool
    public var id: String { path }
}
public enum BrokenLinks {
    public static let directory = "/usr/local/bin"
    /// lstat S_IFLNK, readlink, stat == ENOENT ⇒ broken (other errors ⇒ not listed); needsAdmin = access(dir, W_OK) != 0.
    public static func find(in directory: String = BrokenLinks.directory) -> [BrokenLink]
    /// ["/usr/bin/find", dir, "-maxdepth", "1", "-type", "l", "(", "-name", n1, "-o", "-name", n2, ")",
    ///  "!", "-exec", "/bin/test", "-e", "{}", ";", "-delete"]
    static func deleteCommand(directory: String, names: [String]) -> [String]
    static func globEscaped(_ name: String) -> String          // \ * ? [ ] preceded by \
}
extension CleanupExecutor {
    /// Agents ⇒ .blocked. Calls `find` again and only acts on those that are still broken with the same target;
    /// names without "/". If any needsAdmin: privileged.run([cmd], prompt: "Airy necesita tu contraseña para quitar
    /// enlaces rotos de /usr/local/bin." (= Airy needs your password to remove broken links from /usr/local/bin.)); otherwise, runner.run(cmd). Result .freed(0); "remove_broken_links" record
    /// with message = "path → target" of each one.
    public func removeBrokenLinks(_ links: [BrokenLink], context: OperationContext = .user()) async -> CleanupOutcome
    func removeBrokenLinks(_ links: [BrokenLink], directory: String, context: OperationContext) async -> CleanupOutcome  // tests
}
```
Decision tree of `scan`. The first "no" discards the id.
1. If `inventory.complete == false`, it returns `.undecided("No se pudo leer la lista completa de apps; Airy no marca restos como huérfanos.")` (Could not read the complete list of apps; Airy does not mark leftovers as orphans.).
2. Only the direct entries of `candidateFolders` are looked at, and only those that give an id. Containers, Group Containers, LaunchAgents, LaunchDaemons, Application Scripts and Application Support are **never** looked at.
3. No if the id starts with `com.apple.` or `local.airy.`, or if it contains in lowercase an element of `sensitivePatterns`.
4. No if `gate.validate(path)` rejects it (hard and user protections).
5. No if the lowercase id is in `inventory.installedIDs`.
6. No if the most recent date among the entry's `mtime` and that of its direct children is later than `now() - minimumIdle`.
7. No if `lookup.isInstalled(id)` is `true` or `nil` (a failure counts as installed and is not stored in any cache).
8. If everything passes: orphan. It is grouped by id across the three folders and the bytes are added up with `AllocatedSize.of`.

- [ ] **Step 1: Write the failing tests** (temporary home, `utimes` for dates, `FakeLookup`, hand-built inventory)

```swift
@Test func incompleteInventoryDecidesNothing() async  // .undecided with the exact text
@Test func installedIDIsNotOrphan() async             // main id and helper id
@Test func recentFolderIsNotOrphan() async            // 29 days → no; 31 days → yes; recent child in an old folder → no
@Test func mdfindFailureMeansInstalled() async        // lookup nil → not orphan
@Test func mdfindHitMeansInstalled() async
@Test func onlyCachesLogsSavedState() async           // same old id in Containers, Group Containers, LaunchAgents, Application Support → does not appear
@Test func sensitivePatternsNeverOrphans() async      // com.foo.ssh-agent, org.gnupg.x, com.1password.x, com.foo.keychainhelper
@Test func appleAndAiryNeverOrphans() async
@Test func userProtectedNeverOrphan() async
@Test func groupsAcrossFolders() async                // Caches + Logs + .savedState of the same id → 1 group, bytes added
@Test func stillOrphanRechecks() async                // after adding the app to the inventory → false
@Test func bundleIDParsing()                          // "com.a.b" ✓, "com.a.b.savedState" → "com.a.b", "Foo", "com.a", "com.a b.c", "../x" → nil
@Test func spotlightLookupQueryAndOutcomes() async    // FakeRunner: exact arguments; "/Apps/X.app\n" → true; "" → false; status 1 → nil
@Test func brokenLinkFoundLiveLinkAndFileIgnored()    // temporary folder: broken ✓, live ✗, file ✗
@Test func deleteCommandEscapesAndOnlyTouchesBrokenSymlinks() async {
    // temporary folder with broken link "a *b?[1]", broken link "c", live link "a *b?[1]x" and file "d";
    // real ProcessRunner executes deleteCommand(dir, ["a *b?[1]"]) → only "a *b?[1]" disappears
}
@Test func agentCannotRemoveLinks() async
@Test func adminLinksUsePrivilegedRunner() async      // needsAdmin → privileged.calls == [[cmd]]; runner without calls
@Test func relinkedLinkIsNotRemoved() async           // between find and remove, the target comes to exist → not included
```

- [ ] **Step 2: Run test to verify it fails.** Run `swift test --filter OrphanTests`. Expected: FAIL.
- [ ] **Step 3: Implement** according to Interfaces and tree.
- [ ] **Step 4: Run tests.** Run `swift test --filter OrphanTests`. Expected: PASS (18).
- [ ] **Step 5: Commit.** Message: `feat: orphaned leftovers by bundle id and broken links in /usr/local/bin` (+ Co-Authored-By).

---

### Task 6: Large & old (core) and shared selection

**Files:**
- Create: `Sources/DiskMapCore/Sections/FileSelection.swift`, `Sources/DiskMapCore/Sections/LargeOldFinder.swift`
- Test: `Tests/DiskMapCoreTests/LargeOldTests.swift`

**Interfaces:**
- Consumes: `FileNode`, `RiskClassifier.classify(path:)`, `PathGate`, `Catalog.match`.
- Produces:
```swift
public struct ActionableFile: Sendable, Equatable, Identifiable {
    public let path: String, name: String, bytes: Int64, kind: ContentKind
    public let lastModified: Date?, lastOpened: Date?
    public let risk: Risk, protection: ProtectionMatch?, reasons: [String]
    public var id: String { path }
    public var canSelect: Bool { risk != .doNotTouch && protection == nil }
    public var lastActivity: Date? { get }     // the most recent of lastModified and lastOpened
    /// risk = classifier.classify(path:).risk; if the catalog record does not exist or does not `regenerates`, at least .yourCall;
    /// gate.validate fails ⇒ .doNotTouch with the refusal's protection/reasons.
    public static func make(node: FileNode, classifier: RiskClassifier, catalog: Catalog?, gate: PathGate,
                            lastOpened: Date?) -> ActionableFile
}
public struct FileSelection: Sendable, Equatable {
    public private(set) var ids: Set<String>
    public init()
    public mutating func toggle(_ file: ActionableFile)          // ignores !canSelect
    public mutating func selectAllGreen(_ files: [ActionableFile])
    public mutating func selectAll(_ files: [ActionableFile])    // green + amber with canSelect
    public mutating func clear()
    public mutating func prune(to files: [ActionableFile])       // removes ids that are no longer there or cannot be checked
    public func selected(in files: [ActionableFile]) -> [ActionableFile]   // order of `files`
    public func bytes(in files: [ActionableFile]) -> Int64
    public static func groups(_ files: [ActionableFile]) -> [(risk: Risk, files: [ActionableFile])]   // green, amber, red; without empty ones
}
public protocol FileUsageReading: Sendable { func lastOpened(path: String) -> Date? }
public struct SpotlightFileUsage: FileUsageReading { public init() }    // kMDItemLastUsedDate
public struct LargeOldQuery: Sendable, Equatable {
    public enum Sort: String, Sendable, CaseIterable { case size, oldest, name }   // «Tamaño» (Size), «Más antiguos» (Oldest), «Nombre» (Name)
    public enum Scope: String, Sendable, CaseIterable { case home, everything }    // «Tu carpeta» (Your folder), «Todo el disco» (The whole disk)
    public static let sizeSteps: [Int64] = [100_000_000, 500_000_000, 1_000_000_000, 5_000_000_000]
    public static let idleSteps: [Int?] = [nil, 3, 6, 12]     // months; «Cualquier fecha» (Any date), «3 meses» (3 months), «6 meses» (6 months), «1 año» (1 year)
    public var minBytes: Int64 = 100_000_000
    public var minMonthsIdle: Int? = nil
    public var kinds: Set<ContentKind> = []                    // empty = all
    public var scope: Scope = .home
    public var sort: Sort = .size
    public var limit = 500
    public init()
}
public struct LargeOldFinder: Sendable {
    public init(classifier: RiskClassifier, catalog: Catalog?, gate: PathGate, home: String,
                usage: any FileUsageReading = SpotlightFileUsage(), now: @escaping @Sendable () -> Date = Date.init)
    /// Files only (no folders nor «Otros» (Other) aggregates), without entering `.app`; `usage` only for those that pass the size.
    /// A month = 30 days; idle = now − lastActivity; without dates ⇒ it does not pass a months filter.
    /// Order: size = bytes desc; oldest = lastActivity asc (nil at the end); name = localizedStandardCompare; tie → path.
    public func find(in root: FileNode, query: LargeOldQuery) -> [ActionableFile]
}
```

- [ ] **Step 1: Write the failing tests** (`FileNode` tree built by hand under a temporary home; `FakeUsage` that counts calls)

```swift
@Test func findsOnlyFilesAboveMinimum()
@Test func skipsAggregatesAndAppBundles()
@Test func idleFilterUsesNewestOfOpenedAndModified()   // modified 1 year ago but opened 1 month ago → does not pass «6 meses»
@Test func sortsBySizeOldestAndName()
@Test func kindFilterAndHomeScope()
@Test func personalFilesAtLeastAmber()                 // home/Movies/x.mov and home/Library/Application Support/x.bin → .yourCall
@Test func protectedFileIsRedWithoutCheckbox()         // home/Library/Mail/x.emlx → .doNotTouch, canSelect false
@Test func usageOnlyQueriedForCandidates()             // 3 large files and 50 small ones → 3 calls
@Test func selectAllNeverSelectsRed()
@Test func selectAllGreenOnlyGreen()
@Test func toggleIgnoresRed()
@Test func pruneDropsVanished()
@Test func groupsGreenFirst()
```

- [ ] **Step 2: Run test to verify it fails.** Run `swift test --filter LargeOldTests`. Expected: FAIL.
- [ ] **Step 3: Implement** according to Interfaces.
- [ ] **Step 4: Run tests.** Run `swift test --filter LargeOldTests`. Expected: PASS (13).
- [ ] **Step 5: Commit.** Message: `feat: large & old with filters, ordering and selection by risk` (+ Co-Authored-By).

---

### Task 7: Duplicates (core)

**Files:**
- Create: `Sources/DiskMapCore/Sections/DuplicateFinder.swift`, `Sources/DiskMapCore/Sections/DuplicateBoard.swift`, `Sources/DiskMapCore/Sections/DuplicateReport.swift`
- Modify: `Sources/DiskMapCore/Persistence/AppPaths.swift` (`public var duplicatesFile: URL { support.appendingPathComponent("duplicates.json") }`)
- Test: `Tests/DiskMapCoreTests/DuplicateTests.swift`

**Interfaces:**
- Consumes: `RiskClassifier`, `PathGate`, `CryptoKit.SHA256`.
- Produces:
```swift
public struct DuplicateCopy: Sendable, Equatable, Identifiable {
    public let path: String, created: Date?, modified: Date?
    public let reclaimableBytes: Int64     // getattrlist ATTR_CMNEXT_PRIVATESIZE; if not available, st_blocks * 512
    public let risk: Risk, protection: ProtectionMatch?
    public var id: String { path }
    public var canSelect: Bool { risk != .doNotTouch && protection == nil }
}
public struct DuplicateGroup: Sendable, Equatable, Identifiable {
    public let size: Int64                 // st_size of each copy
    public let copies: [DuplicateCopy]     // ≥ 2; the suggested keeper first
    public let keeper: String
    public var id: String { keeper }
    public var wastedBytes: Int64 { get }  // reclaimableBytes of those that are not keeper
}
public struct DuplicateSearch: Sendable, Equatable {
    public var roots: [String]
    public var minBytes: Int64 = 1_000_000
    public static let sizeSteps: [Int64] = [1_000_000, 10_000_000, 100_000_000]
    public static let skippedNames: Set<String> = [".Trash", ".git", "node_modules", ".venv"]
    public static func defaultRoots(home: String) -> [String]   // children of home except "Library" and ".Trash"
    public init(roots: [String], minBytes: Int64 = 1_000_000)
}
public struct DuplicateResult: Sendable, Equatable {
    public let groups: [DuplicateGroup]    // wastedBytes desc, then keeper
    public let complete: Bool
    public let filesExamined: Int
    public let date: Date
}
public struct DuplicateRemoval: Sendable, Equatable { public let keep: String; public let remove: [String]; public let size: Int64 }
public struct DuplicateFinder: Sendable {
    public static let partialChunk = 65_536
    public init(home: String, classifier: RiskClassifier, gate: PathGate)
    /// Cancellable: with Task.cancel() it returns what was found with complete false. progress = files examined (≤ 10/s).
    public func find(_ search: DuplicateSearch, progress: @escaping @Sendable (Int) -> Void = { _ in }) async -> DuplicateResult
    /// Right before deleting: re-reads the full content of `keep` and of each `remove`. Returns path → reason for rejection
    /// (empty = all good).
    public func verify(_ removal: DuplicateRemoval) async -> [String: String]
    static func suggestedKeeper(_ copies: [DuplicateCopy], home: String) -> String
}
public struct DuplicateBoard: Sendable, Equatable {
    public init(groups: [DuplicateGroup])
    public private(set) var groups: [DuplicateGroup]
    public private(set) var keepers: [String: String]      // group.id → kept path
    public private(set) var selected: Set<String>
    public mutating func toggle(_ path: String, in group: DuplicateGroup)   // never checks !canSelect nor the keeper; never leaves the group without an unchecked copy
    public mutating func keep(_ path: String, in group: DuplicateGroup)     // changes the keeper and unchecks it
    public mutating func selectAllCopies()                 // in each group, all except the keeper and the !canSelect ones
    public mutating func clear()
    public var reclaimableBytes: Int64 { get }
    public func removals() -> [DuplicateRemoval]           // never includes the keeper
}
public enum DuplicateReport {
    public struct File: Codable, Sendable, Equatable {
        public struct Group: Codable, Sendable, Equatable {
            public let size: Int64, reclaimableBytes: Int64, keeper: String, copies: [String]
        }
        public let date: Date, complete: Bool, filesExamined: Int, groups: [Group]
    }
    public static func save(_ result: DuplicateResult, to url: URL) throws    // snake_case JSON, atomic write, 0600
    public static func load(from url: URL) throws -> File?                    // nil if it does not exist
}
```
Algorithm of `find`:
1. Walks with `opendir`/`lstat` without following links and without changing volume. Skips `skippedNames` and does not enter `*.app`. Unreadable folders are skipped and counted.
2. Keeps regular files with `st_size ≥ minBytes`. Groups by `(st_dev, st_ino)` and keeps a single path: hard links are not duplicates.
3. Groups by size (≥ 2).
4. Computes a partial SHA-256 of the first and last `partialChunk` bytes and groups again (≥ 2).
5. Computes a full SHA-256 in 1 MiB blocks, with `open(O_RDONLY | O_NOFOLLOW)`. If the file changes during the read (size or `mtime`), it is discarded. The groups of ≥ 2 remain.

There is a `TaskGroup` of width `activeProcessorCount`. Risk of each copy: `strictest(classifier.classify(path:).risk, .yourCall)`; if `gate.validate` fails, red with its protection.

`suggestedKeeper`, in order: (1) the first copy (by path) that is not `canSelect`, because what is protected is never proposed for deletion; (2) those not in `home/Downloads` nor `home/Desktop`; (3) the one created earlier; (4) the shortest path; (5) alphabetical order.

`verify` rejects, with these reasons:
- `remove` contains `keep`: «Es la copia que conservas.» (It is the copy you are keeping.);
- `keep` does not exist or its content is different: «Ya no existe la copia que conservas.» (The copy you are keeping no longer exists.) / «La copia que conservas ha cambiado.» (The copy you are keeping has changed.);
- a copy does not exist: «Ya no existe.» (It no longer exists.);
- a copy has changed in size or content: «Ha cambiado desde la búsqueda.» (It has changed since the search.).

- [ ] **Step 1: Write the failing tests** (temporary folders; 200 KiB files)

```swift
@Test func identicalFilesAreGrouped() async
@Test func sameEndsDifferentMiddleAreNotDuplicates() async   // same first and last 64 KiB, different middle
@Test func hardLinksAreNotDuplicates() async                 // link() → no group
@Test func symlinksIgnored() async
@Test func belowMinimumIgnored() async
@Test func clonedCopyReclaimsNothing() async                 // clonefile(); if it is not APFS, the test is skipped with a comment
@Test func keeperPrefersProtectedThenNotDownloadsThenOldest()
@Test func selectAllCopiesNeverSelectsKeeperOrProtected()
@Test func toggleNeverSelectsWholeGroup()                    // group of 2: checking the keeper does nothing; keep() changes and unchecks
@Test func removalsNeverIncludeKeeper()
@Test func verifyRejectsChangedFile() async
@Test func verifyRejectsMissingKeeper() async
@Test func verifyRefusesRemovingTheKeeper() async
@Test func reportHasNoHashes() throws {                      // the JSON contains no 64-character hex; exact keys
    // date, complete, files_examined, groups[].size, reclaimable_bytes, keeper, copies
}
@Test func cancellationGivesIncomplete() async
```

- [ ] **Step 2: Run test to verify it fails.** Run `swift test --filter DuplicateTests`. Expected: FAIL.
- [ ] **Step 3: Implement** according to Interfaces and algorithm.
- [ ] **Step 4: Run tests.** Run `swift test --filter DuplicateTests`. Expected: PASS (15).
- [ ] **Step 5: Commit.** Message: `feat: duplicates by size, partial and full hash, with a copy to keep` (+ Co-Authored-By).

---

### Task 8: File types (core)

**Files:**
- Create: `Sources/DiskMapCore/Sections/FileTypeBreakdown.swift`
- Test: `Tests/DiskMapCoreTests/FileTypeTests.swift`

**Interfaces:**
- Consumes: `FileNode.kindBytes`, `ContentKind`.
- Produces:
```swift
public struct FileTypeSlice: Sendable, Equatable, Identifiable {
    public let kind: ContentKind, bytes: Int64, fraction: Double
    public var id: ContentKind { kind }
}
public struct FileTypeBreakdown: Sendable, Equatable {
    public let slices: [FileTypeSlice]       // without 0 types; bytes desc; fractions add up to 1 (±1e-9)
    public let total: Int64
    public init(root: FileNode)
    /// Items of a type, largest first: files with kind == k and `.app` bundles (without descending inside) for .apps;
    /// never «Otros» (Other) aggregates. hiddenBytes = the type's bytes − sum of those listed (small ones or beyond the limit).
    public static func items(of kind: ContentKind, in root: FileNode, limit: Int = 300) -> (items: [FileNode], hiddenBytes: Int64)
}
```

- [ ] **Step 1: Write the failing tests**

```swift
@Test func slicesSortedAndSumToOne()
@Test func zeroKindsDropped()
@Test func itemsOfKindSkipAggregatesAndStopAtApps()   // .apps lists Foo.app, not its internal files
@Test func hiddenBytesAccountsForRest()               // limit 2 of 5 → hiddenBytes == sum of the remaining 3 + aggregates
```

- [ ] **Step 2: Run test to verify it fails.** Run `swift test --filter FileTypeTests`. Expected: FAIL.
- [ ] **Step 3: Implement** according to Interfaces.
- [ ] **Step 4: Run tests.** Run `swift test --filter FileTypeTests`. Expected: PASS (4).
- [ ] **Step 5: Commit.** Message: `feat: space per file type and items of each type` (+ Co-Authored-By).

---

### Task 9: The sections are activated, shared pieces and Large & old view

**Files:**
- Modify: `Sources/Airy/AppModel.swift`. `Section.isAvailable` is `true` for all and `comingSoon` disappears. `let sections = SectionStores()` and the factories `largeOldFinder()`, `gate()` and `classifier()` are added, built with the live settings.
- Modify: `Sources/Airy/Shell/Sidebar.swift` (the «Próximamente» block and `selectionDisabled` go away), `Sources/Airy/Shell/RootView.swift` (`SectionContent` drives the four sections; `SectionPlaceholder` is deleted if it is left unused).
- Create: `Sources/Airy/Sections/SectionStores.swift`, `Sources/Airy/Sections/FileListComponents.swift`, `Sources/Airy/Sections/LargeOldView.swift`

**Interfaces:**
- Consumes: `ActionableFile`, `FileSelection`, `LargeOldFinder`, `LargeOldQuery` (Task 6); `CleanupFlow.requestTrash(paths:title:)` → `AppModel.trash(paths:title:context:)` (plan 1); `TreeGate.read(cancellable:)`; `MapNavigation.reveal(path:)`; `AppModel.protect(path:)`.
- Produces:
```swift
@MainActor @Observable final class SectionStores {
    let largeOld = LargeOldStore(); let fileTypes = FileTypesStore()
    let duplicates = DuplicatesStore(); let uninstaller = UninstallerStore()
}
@MainActor @Observable final class LargeOldStore {
    var query = LargeOldQuery(); var files: [ActionableFile] = []; var selection = FileSelection(); var isLoading = false
    func refresh(model: AppModel)      // cancels the previous one; reads the tree with treeGate.read(cancellable: true)
}
struct SelectableFileRow: View        // checkbox (if canSelect), icon Theme.symbol(for: kind), name, folder, size,
                                      // date, RiskBadge(risk:), .help(reasons); menu: «Mostrar en Finder» (Show in Finder), «Ver en el mapa» (View on the map), «Proteger esto» (Protect this)
struct RiskGroupedList: View          // FileSelection.groups, header per group with RiskBadge and total; rows that leave with .leafAway;
                                      // with several at once, GustSweep + .gustSway (plan 2)
struct SelectionBar: View             // «Seleccionar todo lo verde» (Select everything green), «Seleccionar todo» (Select all), «Quitar selección» (Clear selection),
                                      // PrimaryButton «Mover a la Papelera · \(size)» (Move to the Trash · …) (disabled if empty)
```
Texts: dates with `RelativeDateTimeFormatter` (`Theme.locale`): «Abierto hace 8 meses» (Opened 8 months ago) if there is `lastOpened`; otherwise «Modificado hace 8 meses» (Modified 8 months ago). The confirmation uses `flow.requestTrash(paths:, title: n == 1 ? name : "\(n) archivos")` (n files). Empty states: without analysis, «Analiza el disco para ver los archivos grandes.» (Analyze the disk to see the large files.); without results, «Nada con estos filtros.» (Nothing with these filters.). Filters on top: size «≥ 100 MB»…; «Cualquier fecha / Sin abrir 3 meses / 6 meses / 1 año» (Any date / Not opened for 3 months / 6 months / 1 year); type menu; segmented «Tu carpeta / Todo el disco»; order menu. It is recomputed on appearing and when `query`, `model.scan` or `model.treeRevision` change; nothing runs if the section is not visible. After confirming, `selection.prune(to:)`.

- [ ] **Step 1: Verify the current state.** Run `swift build && swift test 2>&1 | tail -3`. Expected: green. This task adds no new logic to the core: its logic is already tested by Task 6.
- [ ] **Step 2: Implement** according to Interfaces.
- [ ] **Step 3: Verify.** Run `swift build && swift test 2>&1 | tail -3`. Expected: green.
- [ ] **Step 4: Manual check (DEBUG).** `D=$(mktemp -d); mkdir -p ~/AiryPrueba && mkfile 150m ~/AiryPrueba/grande.bin; AIRY_SUPPORT_DIR=$D .build/debug/Airy &` (save `$!`). Four things must be checked:
  - the four sections can be chosen and no «Próximamente» is left;
  - after the analysis, Large & old lists `grande.bin` under «Tú decides»;
  - the filters and the order change the list;
  - a file from `~/Library/Mail` (if it appears) comes out red and without a checkbox.

  Then, check **only** `grande.bin`, press «Mover a la Papelera», confirm and check that the row leaves with `.leafAway`. Screenshot of the own window with `DebugSnapshot`. Stop with `kill <PID>` and delete `~/AiryPrueba`. Do not empty the Trash.
- [ ] **Step 5: Commit.** Message: `feat: phase 2 sections active and Large & old view` (+ Co-Authored-By).

---

### Task 10: File types view with animated chart

**Files:**
- Create: `Sources/Airy/Sections/FileTypesView.swift`, `Sources/Airy/Sections/TypeDonut.swift`
- Modify: `Sources/Airy/Sections/SectionStores.swift` (`FileTypesStore`)

**Interfaces:**
- Consumes: `FileTypeBreakdown` (Task 8), `ActionableFile.make` and `FileSelection` (Task 6), `RiskGroupedList` and `SelectionBar` (Task 9).
- Produces:
```swift
@MainActor @Observable final class FileTypesStore {
    var breakdown: FileTypeBreakdown?; var chosen: ContentKind?
    var files: [ActionableFile] = []; var hiddenBytes: Int64 = 0; var selection = FileSelection()
    func refresh(model: AppModel); func choose(_ kind: ContentKind?, model: AppModel)
}
struct TypeDonut: View   // Canvas; slices with Theme.color(for: kind) (Theme.Airy cool range after plan 2)
```
Chart behavior:
- On appearing and when the data changes, each slice grows from 0 degrees with `Theme.zoomSpring`, staggered with `Theme.stagger(index:)`. With «Reducir movimiento» there is only a fade.
- On hover the slice is highlighted. In the center go the total and, with the mouse over it, the type with its size and its %.
- There is no `TimelineView` nor continuous animation.

Legend beside it: type, size and %. Clicking on a slice or on a legend row shows below the list of that type (`RiskGroupedList` + `SelectionBar`). If `hiddenBytes > 0`, the footer says «y \(size) en archivos pequeños» (and … in small files). Without analysis: «Analiza el disco para ver qué tipos ocupan más.» (Analyze the disk to see which types take up the most.).

- [ ] **Step 1: Implement** according to Interfaces.
- [ ] **Step 2: Verify.** Run `swift build && swift test 2>&1 | tail -3`. Expected: green.
- [ ] **Step 3: Manual check (DEBUG).** `AIRY_SUPPORT_DIR=$(mktemp -d) .build/debug/Airy &` (save `$!`). The chart enters animated, the mouse highlights and a click on «Vídeo» (Video) lists videos. With «Reducir movimiento» enabled in System Settings there is only a fade. `ps -o %cpu= -p <PID>` after 10 s still in the section gives ≈ 0.0. Own screenshot and `kill <PID>`.
- [ ] **Step 4: Commit.** Message: `feat: File types view with animated chart and access to the files` (+ Co-Authored-By).

---

### Task 11: Duplicates view

**Files:**
- Create: `Sources/Airy/Sections/DuplicatesView.swift`
- Modify: `Sources/Airy/Sections/SectionStores.swift` (`DuplicatesStore`)
- Modify: `Sources/Airy/Cleanup/CleanupFlow.swift` (`ConfirmRequest.Kind.duplicates([DuplicateRemoval])`, `requestRemoveDuplicates(_:)`)
- Modify: `Sources/Airy/Cleanup/ConfirmSheet.swift` (paints `.duplicates`)
- Modify: `Sources/Airy/AppModel.swift` (`trashDuplicates`, saves `duplicates.json`)

**Interfaces:**
- Consumes: `DuplicateFinder`, `DuplicateBoard`, `DuplicateRemoval`, `DuplicateReport`, `AppPaths.duplicatesFile` (Task 7).
- Produces:
```swift
@MainActor @Observable final class DuplicatesStore {
    var search: DuplicateSearch; var result: DuplicateResult?; var board = DuplicateBoard(groups: [])
    var examined = 0; var isSearching = false
    func start(model: AppModel); func cancel()
}
// AppModel:
func duplicateFinder() -> DuplicateFinder
/// For each removal: finder.verify; rejected copies are not moved and their reason comes back in `notes`; the rest,
/// trash(paths:title:context: .user()) in a single call.
func trashDuplicates(_ removals: [DuplicateRemoval]) async -> (outcome: CleanupOutcome, notes: [String])
```
The search is launched only with the «Buscar duplicados» (Search for duplicates) button (never by itself) and runs in a cancellable `Task.detached`. When it finishes, the app saves `DuplicateReport.save(result, to: paths.duplicatesFile)`; if that fails, it warns with `report(.save, …)` and continues.

Screen:
- Folder chips («Tu carpeta» (Your folder) and «Elegir carpeta…» (Choose folder…) with `NSOpenPanel`), minimum size «≥ 1 MB / 10 MB / 100 MB».
- Progress: «Comparando \(n) archivos…» (Comparing n files…) with `WindLeaves(mode: .orbit(radius:))` around the ring (like the analysis after plan 2) and «Cancelar» (Cancel).
- Groups in cards: name, «\(n) copias de \(size)» (n copies of …), «Libera \(wastedBytes)» (Frees …).
- Each copy in a row: radio «Conservar» (Keep), checkbox, path, date and `RiskBadge`. A protected copy carries a lock and its reason, without a checkbox. If `reclaimableBytes == 0`: «Copia APFS: no ocupa espacio extra» (APFS copy: it takes up no extra space).
- Buttons «Seleccionar todas las copias» (Select all copies) and `PrimaryButton` «Mover copias a la Papelera · \(board.reclaimableBytes)» (Move copies to the Trash · …).
- If `complete == false`: «Búsqueda incompleta: se canceló o no se pudo leer todo.» (Incomplete search: it was cancelled or not everything could be read.).

`.duplicates` sheet: per group, «Se conserva: \(path)» (Kept: …) with a green mark and «A la Papelera: \(paths)» (To the Trash: …). At the end, the total and the note «Antes de mover nada, Airy vuelve a comparar cada copia.» (Before moving anything, Airy compares each copy again.).

- [ ] **Step 1: Implement** according to Interfaces.
- [ ] **Step 2: Verify.** Run `swift build && swift test 2>&1 | tail -3`. Expected: green.
- [ ] **Step 3: Manual check (DEBUG).** `mkdir -p ~/AiryPrueba/a ~/AiryPrueba/b && mkfile 5m ~/AiryPrueba/a/x.bin && cp ~/AiryPrueba/a/x.bin ~/AiryPrueba/b/x.bin && ln ~/AiryPrueba/a/x.bin ~/AiryPrueba/a/enlace.bin`. Then `AIRY_SUPPORT_DIR=$(mktemp -d) .build/debug/Airy &` (save `$!`). Four things must be checked:
  - with «Elegir carpeta…» = `~/AiryPrueba`, a group of 2 copies comes out and the hard link does not count;
  - the two copies cannot be both checked;
  - with `b/x.bin` checked and `echo z >> ~/AiryPrueba/b/x.bin` before confirming, it is not moved and «Ha cambiado desde la búsqueda.» (It has changed since the search.) appears;
  - after repeating the search and confirming, the copy goes to the Trash.

  Afterwards, `cat $AIRY_SUPPORT_DIR/duplicates.json` has no fingerprints. `kill <PID>` and delete `~/AiryPrueba`.
- [ ] **Step 4: Commit.** Message: `feat: Duplicates view with a copy to keep and verification before deleting` (+ Co-Authored-By).

---

### Task 12: Uninstaller view (apps, orphaned leftovers, broken links)

**Files:**
- Create: `Sources/Airy/Sections/UninstallerView.swift`, `Sources/Airy/Sections/UninstallDetail.swift`, `Sources/Airy/Sections/OrphansView.swift`
- Modify: `Sources/Airy/Sections/SectionStores.swift` (`UninstallerStore`)
- Modify: `Sources/Airy/Cleanup/CleanupFlow.swift`. `ConfirmRequest.Kind` gains `.uninstall([UninstallRequest])`, `.orphans([OrphanGroup])` and `.brokenLinks([BrokenLink])`, with `requestUninstall(_:warning:proposedBy:)`, `requestTrashOrphans(_:)` and `requestRemoveBrokenLinks(_:)`. Uninstall batches go one by one with per-row progress and a final summary, like `CleanupBatch`.
- Modify: `Sources/Airy/Cleanup/ConfirmSheet.swift` (paints the three new kinds)
- Modify: `Sources/Airy/AppModel.swift`. `executor` receives `appRoots`. `inventorySnapshot()`, `uninstall(_:context:)`, `trashOrphans(_:)` and `removeBrokenLinks(_:)` are added. In DEBUG, `AIRY_APP_ROOTS` (paths separated by `:`) replaces the inventory roots and `appRoots`.

**Interfaces:**
- Consumes: Tasks 1–5.
- Produces:
```swift
@MainActor @Observable final class UninstallerStore {
    enum Tab: String, CaseIterable { case apps, orphans, links }   // «Apps», «Restos huérfanos» (Orphaned leftovers), «Enlaces rotos» (Broken links)
    enum Sort: String, CaseIterable { case realSize, name, lastUsed } // «Tamaño real» (Real size), «Nombre» (Name), «Último uso» (Last use)
    var tab: Tab = .apps; var sort: Sort = .realSize; var searchText = ""
    var inventory: AppInventorySnapshot?; var plans: [String: UninstallPlan] = [:]   // by app.path, filled in gradually
    var checkedApps: Set<String> = []; var leftoverSelection: [String: Set<String>] = [:]   // default plan.defaultSelection
    var orphans: OrphanScan?; var orphanSelection: Set<String> = []; var links: [BrokenLink] = []; var linkSelection: Set<String> = []
    func refresh(model: AppModel)      // on first appearing and with «Actualizar» (Refresh); never in the background
}
// AppModel:
func inventorySnapshot() async -> AppInventorySnapshot       // HomebrewCasks.installed + AppInventory(roots:casks:)
func uninstall(_ request: UninstallRequest, context: OperationContext) async -> UninstallReport
    // executor.uninstall; then updateTree(afterTouching: moved paths), refreshCounters, refreshVolumes
func trashOrphans(_ groups: [OrphanGroup]) async -> CleanupOutcome
    // fresh inventory; only the groups with stillOrphan == true; trash(paths:title: "Restos huérfanos", context: .user())
func removeBrokenLinks(_ links: [BrokenLink]) async -> CleanupOutcome
```
**Apps tab.**
- List: checkbox (only if `refusal == nil`), icon `NSWorkspace.shared.icon(forFile:)`, name and version, badges «Abierta» (Open) / «Homebrew» / «App Store», «Sin abrir desde hace \(x)» (Not opened for …) or «Sin datos de uso» (No usage data), real size («+» if `!sizeComplete`) and `RiskBadge`: You decide, or Do not delete with `refusal` as help.
- Clicking on an app opens `UninstallDetail`: leftovers grouped by risk (green, amber, red), each with checkbox, path, size and reason; at the top, «App \(size) + restos \(size)» (App … + leftovers …).
- Buttons: `PrimaryButton` «Desinstalar · \(bytes(selected:))» (Uninstall · …); and with several checked, «Desinstalar \(n) apps · \(total)» (Uninstall n apps · …).

**`.uninstall` sheet**, per app:
- «Se cerrará «\(name)» si está abierta (podrá pedirte guardar).» («…» will be quit if it is open (it may ask you to save).);
- or «Homebrew la desinstala con `brew uninstall --cask --zap \(token)`; lo que borra Homebrew no pasa por la Papelera.» (Homebrew uninstalls it with `brew …`; what Homebrew deletes does not go through the Trash.), or «La app irá a la Papelera.» (The app will go to the Trash.);
- selected leftovers: green, and the amber in a highlighted block «Revisa: esto no se regenera solo» (Review: this does not regenerate by itself);
- red under «Se quedan» (They stay);
- with receipts: «Pedirá tu contraseña de administrador.» (It will ask for your administrator password.);
- and the total.

**Orphaned leftovers tab.**
- If it is `.undecided(reason)`, the reason's text.
- Otherwise, rows with id, folders, «Sin usar desde \(date)» (Unused since …), size and green, plus `SelectionBar` with «Mover a la Papelera · \(size)».
- If there are none: «No hay restos de apps desinstaladas.» (There are no leftovers of uninstalled apps.).

**Broken links tab.**
- Rows «\(name) → \(target)» and the button «Quitar enlaces rotos» (Remove broken links).
- The sheet says «Los enlaces rotos se borran: no apuntan a nada y no van a la Papelera.» (Broken links are deleted: they point to nothing and do not go to the Trash.) and, if any `needsAdmin`, «Pedirá tu contraseña de administrador.».
- If there are none: «No hay enlaces rotos en /usr/local/bin.» (There are no broken links in /usr/local/bin.).

While measuring, rows show the `.app`'s size and then the real one. An uninstalled app leaves with `.leafAway`; «Desinstalar \(n) apps» launches `GustSweep` + `.gustSway` like «Borrar todo».

- [ ] **Step 1: Implement** according to Interfaces.
- [ ] **Step 2: Verify.** Run `swift build && swift test 2>&1 | tail -3`. Expected: green.
- [ ] **Step 3: Manual check (DEBUG; never a real app).**
  1. Create a fake app `$T/Apps/Prueba Airy.app` (`T=$(mktemp -d)`), with `Contents/Info.plist` (`CFBundleIdentifier` `com.example.airyprueba`, `CFBundleName` «Prueba Airy» (Airy Test)) and `Contents/MacOS/x`.
  2. Create its leftovers: `mkdir -p ~/Library/Caches/com.example.airyprueba && touch ~/Library/Preferences/com.example.airyprueba.plist`.
  3. Start with `AIRY_APP_ROOTS=$T/Apps AIRY_SUPPORT_DIR=$(mktemp -d) .build/debug/Airy &` (save `$!`).
  4. Check the list and the leftovers (cache in green, preferences in amber).
  5. Uninstall and confirm: the app and the two leftovers are in the Trash, and the operations log has `uninstall`.
  6. Open the «Restos huérfanos» and «Enlaces rotos» tabs (only look; do not confirm anything outside the test app).

  Own screenshot and `kill <PID>`.
- [ ] **Step 4: Commit.** Message: `feat: Uninstaller view with leftovers, orphans and broken links` (+ Co-Authored-By).

---

### Task 13: MCP: section read tools and `propose_uninstall`

**Files:**
- Create: `Sources/DiskMapCore/MCP/Tools/SectionTools.swift`
- Modify: `Sources/DiskMapCore/MCP/MCPTool.swift` (`MCPToolRegistry.standard()` adds the six), `Sources/DiskMapCore/MCP/AiryEnvironment.swift` (gains `appRoots: [String]`, `usage: any AppUsageReading`, `bundleLookup: any BundleIDLookup`, `func inventorySnapshot() async -> AppInventorySnapshot`; `live()` with the standard roots), `Sources/DiskMapCore/Integration/AiryURL.swift` (`.uninstall` case), `Sources/Airy/AppModel.swift` (`handle(url:)` for `.uninstall`)
- Test: `Tests/DiskMapCoreTests/MCPSectionToolTests.swift`, `Tests/DiskMapCoreTests/AiryURLTests.swift`, and the exact tool set test in `MCPActionToolTests.swift` (the six names are added)

**Interfaces:**
- Consumes: `MCPTool`, `MCPFormat.risk`, `AgentGate`, `OperationLog`, `AiryURLCommand` (plan 1); Tasks 1, 3, 5, 6, 7.
- Produces: `ListAppsTool`, `ExplainAppTool`, `ListOrphansTool`, `ListLargeOldTool`, `ListDuplicatesTool` (`readOnly: true, destructive: false`) and `ProposeUninstallTool` (`readOnly: false, destructive: false`). In addition:
```swift
extension AiryURLCommand {
    case uninstall(bundleID: String, reason: String, agent: String?)   // airy://uninstall?bundle=<id>&reason=<r>&agent=<a>
    // bundle: ^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$; reason/agent sanitized as in propose
}
```

| Tool | Input | Output (`structured`) |
|---|---|---|
| `list_apps` | `limit?` 1…500 (100), `sort?` `size`\|`name`\|`last_used` | `complete`, `apps: [{name, bundle_id, version, path, app_bytes, last_used, running, source: homebrew\|app_store\|other, can_uninstall, refusal}]` |
| `explain_app` | `bundle_id` required | `{…what list_apps gives, real_bytes, leftover_bytes, size_complete, shared_with, leftovers: [{kind, path, bytes, preselected, matched_by_name, reason} + MCPFormat.risk]}`; missing id → error «No hay ninguna app instalada con ese identificador.» (There is no app installed with that identifier.) |
| `list_orphans` | `{}` | `decided`, `reason` (if not), `groups: [{bundle_id, paths, bytes, last_modified, risk, risk_label}]` |
| `list_large_old` | `min_bytes?` ≥ 1 000 000 (100 000 000), `older_than_months?` 0…120, `kind?` (raw of `ContentKind`), `scope?` `home`\|`everything`, `limit?` 1…200 (50) | `files: [{path, name, bytes, kind, last_modified, last_opened} + MCPFormat.risk]` from the saved index; without an index → «Aún no hay análisis guardado. Abre Airy o usa rescan.» (There is no saved analysis yet. Open Airy or use rescan.) |
| `list_duplicates` | `limit?` 1…200 (50) | `date`, `complete`, `groups: [{size, reclaimable_bytes, keeper, copies}]` from `duplicates.json`; without a file → «Aún no hay búsqueda de duplicados. Búscalos en Airy › Duplicados.» (There is no duplicates search yet. Search for them in Airy › Duplicates.) |
| `propose_uninstall` | `bundle_id` required, `reason` required (1…500), `dry_run?` | `AgentGate`. Errors: missing id (same text as `explain_app`) and `refusal` with its text. Otherwise, opens `AiryURLCommand.uninstall(…, agent: client).url` (with `dry_run` returns the URL without opening) and responds `{status: "pending_user_confirmation", url, message: "Propuesta enviada a Airy; pendiente de confirmación del usuario."}` (Proposal sent to Airy; pending user confirmation.). `OperationRecord` `propose` / `pending_user` |

`list_apps` does not compute leftovers; `explain_app` does. In `explain_app` and `list_large_old`, `last_opened` comes from `usage`. Nothing reads file contents.

In the app, `handle(url:)` with `.uninstall`: goes to the `.uninstaller` section, waits for the inventory and looks for the id.
- If it is not there: notice «Un agente propuso desinstalar «\(id)», pero no está instalada.» (An agent proposed uninstalling «…», but it is not installed.).
- If it has `refusal`: notice «Un agente propuso desinstalar «\(name)», pero \(refusal with lowercase initial)» (An agent proposed uninstalling «…», but …).
- Otherwise, `flow.requestUninstall([UninstallRequest(plan:, selected: plan.defaultSelection)], warning: (plan 1's agent warning), proposedBy: agent)`. The user's confirmation is executed with `.user(runID:, proposedBy: agent)`.

- [ ] **Step 1: Write the failing tests** (plan 1's `makeTestEnvironment(home:)` with `appRoots` and fake apps in a temporary folder, `FakeOpener`, `FakeLookup`, `FakeQuitter`)

```swift
@Test func listAppsIsReadOnlyAndSorted() async        // sort size/name/last_used; annotations.readOnly
@Test func explainAppGivesPlanWithRisks() async       // leftovers with risk_label «Sin problema» / «Tú decides»
@Test func explainUnknownAppIsError() async
@Test func listOrphansUndecidedWhenIncomplete() async
@Test func listLargeOldFromIndex() async              // saved ScanResult; min_bytes and older_than_months filter
@Test func listDuplicatesWithoutReport() async
@Test func listDuplicatesNeverExposesHashes() async   // no 64-character hex in text or structured
@Test func proposeUninstallOpensURLOnly() async       // opener: airy://uninstall?bundle=com.example.foo&…&agent=test-client;
                                                      // the fake app remains; quitter and runner without calls; record pending_user
@Test func proposeUninstallRespectsToggle() async     // agentsEnabled false, also with dry_run → isError; opener without calls
@Test func proposeUninstallRejectsSystemApp() async   // com.apple.Safari in a fake /System/Applications → isError with «Es parte de macOS.»
@Test func sectionToolsAcceptNoArbitraryCommands()    // no schema has "command", "args", "paths"; "path" in none
@Test func uninstallURLRoundTrip()                    // AiryURLTests
@Test func uninstallURLRejectsHostileBundleID()       // "../x", "a b", "a\nb", 201 characters, no bundle → nil
```

- [ ] **Step 2: Run test to verify it fails.** Run `swift test --filter "MCPSectionToolTests|AiryURLTests"`. Expected: FAIL.
- [ ] **Step 3: Implement** according to Interfaces. The expected exact tool set is updated by adding `list_apps`, `explain_app`, `list_orphans`, `list_large_old`, `list_duplicates` and `propose_uninstall`.
- [ ] **Step 4: Run tests.** Run `swift test 2>&1 | tail -3`. Expected: all green.
- [ ] **Step 5: Commit.** Message: `feat: the MCP queries apps, orphans, large files and duplicates and proposes uninstalling` (+ Co-Authored-By).

---

### Task 14: Final verification of plan 5

**Files:** none new (only fixes that come out of the verification, each with its test).

- [ ] **Step 1: Tests.** Run `swift build && swift test 2>&1 | tail -3`. Expected: all green; no test has touched `/Applications`, `brew`, `launchctl`, `pkgutil`, `osascript` nor the real Trash.
- [ ] **Step 2: Funnel audit.** Run `grep -rn 'trashItem(' Sources | grep -v CleanupExecutor.swift; grep -rn 'forceTerminate\|"/bin/sh"\|"-c"' Sources/DiskMapCore/Apps Sources/DiskMapCore/Sections Sources/DiskMapCore/System/PrivilegedRunner.swift Sources/DiskMapCore/System/AppQuitter.swift`. Expected: no output.
- [ ] **Step 3: MCP smoke (read-only and dry_run).** First `swift build`. Then, send to `.build/debug/airy-mcp` with `AIRY_SUPPORT_DIR=$(mktemp -d)` these six lines: `initialize`; `tools/list`; `tools/call` `list_apps` `{"limit":5}`; `explain_app` with the id of a real app from the previous output; `list_orphans`; and `propose_uninstall` `{"bundle_id": <that id>, "reason":"prueba", "dry_run": true}`. Expected:
  - the six new tools in `tools/list`;
  - responses without `isError`, except one explained refusal;
  - `propose_uninstall` returns the URL **without** opening Airy;
  - no text with file contents.
- [ ] **Step 4: Packaged app.** Run `bash scripts/build-app.sh && codesign --verify --strict build/Airy.app`. Expected: no errors. It is **not** installed over `/Applications` in this verification, unless the user is present and asks for it.
- [ ] **Step 5: Final walk-through (DEBUG).** Walk through the four sections with the test data from Tasks 9, 11 and 12 and check:
  - the three labels in all four;
  - «Seleccionar todo» never checks red;
  - with «Reducir movimiento» there are only fades;
  - `ps -o %cpu= -p <PID>` ≈ 0.0 after 10 s still in each section.

  Screenshots of own windows only, `kill <PID>` and delete the test data (`~/AiryPrueba`, `~/Library/Caches/com.example.airyprueba` if it was left).
- [ ] **Step 6: Commit** (if there were fixes). Message: `fix: final verification of the phase 2 sections` (+ Co-Authored-By).
