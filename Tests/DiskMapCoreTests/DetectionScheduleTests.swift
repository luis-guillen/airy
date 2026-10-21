import Foundation
import Synchronization
import Testing
@testable import DiskMapCore

// MARK: - Utilities

private let day: TimeInterval = 86_400

/// Temporary folder (real path, without the `/var` → `/private/var` link).
private func tempDir(_ label: String) -> String {
    let url = TestTemp.url("airy-\(label)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return CleanupTargets.realPath(url.path)!
}

/// Creates `relative` (a folder if it ends in `/`, otherwise a 4 KB file) under `base`.
private func make(_ base: String, _ relatives: String...) {
    for relative in relatives {
        let path = base + "/" + relative
        if relative.hasSuffix("/") {
            try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        } else {
            try! FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: path, contents: Data(repeating: 1, count: 4096))
        }
    }
}

/// Dates the whole tree `days` days in the past (inside out, without following links).
private func ageTree(_ root: String, days: Double) {
    let seconds = Date().addingTimeInterval(-days * day).timeIntervalSince1970
    let names = (try? FileManager.default.subpathsOfDirectory(atPath: root)) ?? []
    for path in names.sorted(by: { $0.count > $1.count }).map({ root + "/" + $0 }) + [root] {
        var times = [timeval(tv_sec: Int(seconds), tv_usec: 0), timeval(tv_sec: Int(seconds), tv_usec: 0)]
        _ = lutimes(path, &times)
    }
}

/// Minimal index: a root named `base` and a chain of folders down to `relative` with `size` bytes.
private func index(base: String, relative: String, size: Int64) -> FileNode {
    var node = FileNode(name: (relative as NSString).lastPathComponent, isDirectory: true, allocatedSize: size)
    for component in (relative as NSString).deletingLastPathComponent.split(separator: "/").reversed() {
        node = FileNode(name: String(component), isDirectory: true, allocatedSize: size, children: [node])
    }
    return FileNode(name: base, isDirectory: true, allocatedSize: size, children: [node])
}

/// Disk walks `body` performs (root path and kind), with the `TreeWalk` observer.
private func walks<T>(_ body: () async throws -> T) async rethrows -> (T, [(String, TreeWalk.Kind)]) {
    let seen = Mutex<[(String, TreeWalk.Kind)]>([])
    let value = try await TreeWalk.$observer.withValue({ path, kind in seen.withLock { $0.append((path, kind)) } }) {
        try await body()
    }
    return (value, seen.withLock { $0 })
}

private struct NoProcesses: ProcessListing {
    func processes() -> [RunningProcess]? { [] }
    func holders(ofPathsUnder paths: [String]) -> [RunningProcess]? { [] }
}

private func cacheEntry() -> CatalogEntry {
    CatalogEntry(id: "foo", title: "Prueba", explanation: "", whoCreatesIt: "", regenerates: true, risk: .safe,
                 kind: .caches, paths: ["~/Library/Caches/foo"], cleanup: .trash)
}

private func projectCatalog() throws -> Catalog {
    let bundled = try Catalog.bundled()
    return Catalog(entries: try ["old-project-artifacts", "old-project-build-leftovers"].map {
        try #require(bundled.entry(id: $0))
    })
}

private func scanner(_ catalog: Catalog, home: String, scope: DiskScope? = nil) -> CleanupScanner {
    var settings = AirySettings()
    settings.mode = .aggressive
    return CleanupScanner(
        catalog: catalog, runner: FakeRunner(resolved: ["git": "/usr/bin/git"]), probes: FakeProbes(),
        references: ReferenceChecker(roots: []), home: home,
        classifier: RiskClassifier(catalog: catalog, settings: settings, home: home),
        processListing: NoProcesses(), scope: scope)
}

/// Old Node project in `~/Projects/app` (without Git): package.json and src from 120 days ago.
private func staleNodeApp(_ home: String) -> String {
    let app = home + "/Projects/app"
    make(app, "package.json", "src/a.js", "node_modules/left-pad/index.js")
    ageTree(app, days: 120)
    return app
}

// MARK: - Tests

@Suite struct DetectionScheduleTests {
    // MARK: When: the automatic detection waits for the index or the scan

    @Test func automaticDetectionWaitsForTheIndex() {
        var gate = DetectionGate()
        // On launch, before reading the index, there is nothing to reuse.
        #expect(gate.phase == .waitingForIndex)
        #expect(!gate.allowsAutomatic)
        #expect(gate.cleanupOpened(hasTree: false) == nil)
        // Recent index (no rescan): detect right away, in the background.
        #expect(gate.indexRead(hasIndex: true, plan: .skip) == .automatic)
        #expect(gate.allowsAutomatic)
        // Only once: a second notice does not launch another.
        #expect(gate.indexRead(hasIndex: true, plan: .skip) == nil)
        #expect(gate.scanFinished(.automatic) == nil)
    }

    @Test func withoutIndexDetectionWaitsForTheScan() {
        var gate = DetectionGate()
        #expect(gate.indexRead(hasIndex: false, plan: .scan(.normal)) == nil)
        #expect(gate.phase == .waitingForScan)
        #expect(!gate.allowsAutomatic)
        // Without a tree, opening Cleanup does not detect (it would measure everything on disk).
        #expect(gate.cleanupOpened(hasTree: false) == nil)
        #expect(gate.scanFinished(.automatic) == .automatic)
        #expect(gate.allowsAutomatic)
    }

    @Test func staleIndexWaitsForTheRescanUnlessTheUserOpensCleanup() {
        var gate = DetectionGate()
        // Old index: it is shown, but detecting on it would be wasted work and would compete with the scan.
        #expect(gate.indexRead(hasIndex: true, plan: .scan(.background)) == nil)
        #expect(!gate.allowsAutomatic)
        // Opening Cleanup brings it forward (the user's QoS), once per wait.
        #expect(gate.cleanupOpened(hasTree: true) == .user)
        #expect(gate.cleanupOpened(hasTree: true) == nil)
        // When the scan finishes, the automatic one on the new tree.
        #expect(gate.scanFinished(.automatic) == .automatic)
        #expect(gate.cleanupOpened(hasTree: true) == nil)
        // A new scan waits again.
        gate.scanStarted()
        #expect(!gate.allowsAutomatic)
        #expect(gate.indexRead(hasIndex: true, plan: .scan(.normal)) == nil)
        #expect(gate.cleanupOpened(hasTree: true) == .user)
    }

    /// Cleanup already open before the automatic rescan starts (old index): when it ends, the list
    /// fills itself, in the background, without pressing "Search again".
    @Test func cleanupOpenBeforeAnAutomaticRescanRefillsWhenItFinishes() {
        var gate = DetectionGate()
        #expect(gate.cleanupOpened(hasTree: false) == nil)  // onAppear before reading the index
        gate.scanStarted()
        #expect(gate.indexRead(hasIndex: true, plan: .scan(.background)) == nil)
        let trigger = gate.scanFinished(.automatic)
        #expect(trigger == .automatic)
        #expect(DetectionSchedule.budget(.automatic, lowPowerMode: false, thermalState: .nominal).qos == .background)
        // A second automatic rescan with Cleanup still open also fills it.
        gate.scanStarted()
        #expect(gate.indexRead(hasIndex: true, plan: .scan(.background)) == nil)
        #expect(gate.scanFinished(.automatic) == .automatic)
    }

    @Test func detectionAfterAUserScanKeepsTheUserQoSAndAgentsStayInBackground() {
        var user = DetectionGate()
        _ = user.indexRead(hasIndex: true, plan: .scan(.normal))
        #expect(user.scanFinished(.user) == .user)
        var agent = DetectionGate()
        _ = agent.indexRead(hasIndex: true, plan: .scan(.background))
        #expect(agent.scanFinished(.agent) == .automatic)
    }

    @Test func stoppedScanDetectsOnWhatIsShown() {
        var shown = DetectionGate()
        _ = shown.indexRead(hasIndex: true, plan: .scan(.background))
        #expect(shown.scanStopped(hasTree: true) == .automatic)
        #expect(shown.scanStopped(hasTree: true) == nil)
        var empty = DetectionGate()
        _ = empty.indexRead(hasIndex: false, plan: .scan(.normal))
        #expect(empty.scanStopped(hasTree: false) == nil)
        #expect(empty.allowsAutomatic)
        // Cancelling before reading the index does not leave the detection waiting forever either.
        var early = DetectionGate()
        #expect(early.scanStopped(hasTree: false) == nil)
        #expect(early.allowsAutomatic)
    }

    // MARK: How: QoS and walks at a time

    @Test func automaticDetectionRunsInBackgroundWithAtMostTwoWalkers() {
        let budget = DetectionSchedule.budget(.automatic, lowPowerMode: false, thermalState: .nominal)
        #expect(budget == ScanBudget(workers: 2, qos: .background))
        #expect(DetectionSchedule.priority(for: budget) == .background)
        // The same rule as an automatic rescan.
        let rescan = ScanBudget.resolve(.background, performanceCores: 8, lowPowerMode: false, thermalState: .nominal)
        #expect(budget == rescan)
        #expect(DetectionSchedule.budget(.automatic, lowPowerMode: false, thermalState: .fair).workers == 2)
    }

    @Test func userDetectionUsesUtility() {
        let budget = DetectionSchedule.budget(.user, lowPowerMode: false, thermalState: .nominal)
        #expect(budget == ScanBudget(workers: 2, qos: .utility))
        #expect(DetectionSchedule.priority(for: budget) == .utility)
    }

    @Test func lowPowerOrHotMacMeansOneWalker() {
        for trigger in [DetectionTrigger.automatic, .user] {
            #expect(DetectionSchedule.budget(trigger, lowPowerMode: true, thermalState: .nominal).workers == 1)
            #expect(DetectionSchedule.budget(trigger, lowPowerMode: false, thermalState: .serious).workers == 1)
            #expect(DetectionSchedule.budget(trigger, lowPowerMode: false, thermalState: .critical).workers == 1)
        }
        // The QoS does not change: only the number of walks is cut.
        #expect(DetectionSchedule.budget(.automatic, lowPowerMode: true, thermalState: .critical).qos == .background)
        #expect(DetectionSchedule.trigger(after: .user) == .user)
        #expect(DetectionSchedule.trigger(after: .automatic) == .automatic)
        #expect(DetectionSchedule.trigger(after: .agent) == .automatic)
    }

    // MARK: What it reads: the index before the disk

    @Test func indexedCatalogPathIsNotWalked() async throws {
        let home = tempDir("detect-index")
        make(home, "Library/Caches/foo/blob")
        let catalog = Catalog(entries: [cacheEntry()])
        let root = index(base: home, relative: "Library/Caches/foo", size: 777_000)
        let (items, seen) = await walks { await scanner(catalog, home: home).findItems(scan: root) }
        #expect(items.map(\.bytes) == [777_000])
        #expect(seen.isEmpty, "\(seen)")
        // Without an index, the disk: one walk.
        let (live, walked) = await walks { await scanner(catalog, home: home).findItems(scan: nil) }
        #expect(live.count == 1 && live[0].bytes > 0 && live[0].bytes != 777_000)
        #expect(walked.map(\.0) == [home + "/Library/Caches/foo"])
    }

    @Test func indexedProjectArtifactTakesItsSizeFromTheIndexAndOnlyReadsNames() async throws {
        let home = tempDir("detect-project")
        let app = staleNodeApp(home)
        let catalog = try projectCatalog()
        let root = index(base: home, relative: "Projects/app/node_modules", size: 5_000_000)
        let (items, seen) = await walks { await scanner(catalog, home: home).findItems(scan: root) }
        let item = try #require(items.first)
        #expect(items.count == 1)
        #expect(item.paths == [app + "/node_modules"])
        #expect(item.bytes == 5_000_000)
        // node_modules: names only (in case there is another Git or keys inside). No full walk of it.
        #expect(seen.contains { $0.0 == app + "/node_modules" && $0.1 == .names })
        #expect(!seen.contains { $0.0 == app + "/node_modules" && $0.1 == .full })
        // Same result (except the size) as without an index.
        let live = await scanner(catalog, home: home).findItems(scan: nil)
        #expect(live.map(\.id) == items.map(\.id))
        #expect(live.map(\.risk) == items.map(\.risk))
        #expect(live.map(\.preselected) == items.map(\.preselected))
    }

    @Test func namesOnlyWalkStillFindsNestedRepositoriesAndKeys() async throws {
        let home = tempDir("detect-guards")
        let app = staleNodeApp(home)
        make(app, "node_modules/dep/.git/HEAD")
        ageTree(app, days: 120)
        let catalog = try projectCatalog()
        let root = index(base: home, relative: "Projects/app/node_modules", size: 5_000_000)
        let item = try #require(await scanner(catalog, home: home).findItems(scan: root).first)
        #expect(item.risk == .doNotTouch)
        #expect(item.riskReason == "It contains another Git repository inside.")
        #expect(TreeWalk.watchedNames(app, budget: .seconds(5), watch: { $0.hasSuffix("-keypair.json") }) == [])
        make(app, "node_modules/dep/id-keypair.json")
        #expect(TreeWalk.watchedNames(app, budget: .seconds(5), watch: { $0.hasSuffix("-keypair.json") })
            == ["node_modules/dep/id-keypair.json"])
    }

    // MARK: Where: with AIRY_SCAN_ROOTS, nothing outside the roots

    @Test func scopedDetectionNeverWalksOutsideItsRoots() async throws {
        let home = tempDir("detect-scope-home")
        _ = staleNodeApp(home)
        make(home, "Library/Caches/foo/blob")
        let roots = tempDir("detect-scope-roots")
        let bundled = try projectCatalog()
        let catalog = Catalog(entries: bundled.entries + [cacheEntry()])
        let scope = DiskScope(roots: [roots])
        let (items, seen) = await walks { await scanner(catalog, home: home, scope: scope).findItems(scan: nil) }
        #expect(items.isEmpty)
        #expect(seen.isEmpty, "\(seen)")
        // Without a scope, the same thing is found.
        #expect(await scanner(catalog, home: home).findItems(scan: nil).count == 2)
    }

    @Test func diskScopeContainsItsRootsAndReachesTheirAncestors() {
        // Path with a link (`/var` → `/private/var`): both forms are valid.
        let url = TestTemp.url("airy-roots")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let linked = url.path
        let real = CleanupTargets.realPath(linked)!
        #expect(linked != real)
        let scope = DiskScope(roots: [linked])
        #expect(scope.contains(linked))
        #expect(scope.contains(real + "/a/b"))
        #expect(!scope.contains(linked + "X"))
        #expect(!scope.contains("/Users/ana/Projects"))
        #expect(scope.reaches((real as NSString).deletingLastPathComponent))
        #expect(scope.reaches("/"))
        #expect(!scope.reaches("/Users/ana"))
        #expect(DiskScope.allowsWalk("/Users/ana"))
        DiskScope.$current.withValue(scope) {
            #expect(!DiskScope.allowsWalk("/Users/ana"))
            #expect(TreeWalk.summarize("/Users", budget: .seconds(1)) == nil)
        }
    }

    // MARK: Cancelling releases the disk

    @Test func cancelledWalkStopsAtOnce() async {
        let base = tempDir("detect-cancel")
        make(base, "a/x", "b/y")
        let task = Task { () -> (TreeSummary?, [String]?) in
            withUnsafeCurrentTask { $0?.cancel() }
            return (TreeWalk.summarize(base, budget: .seconds(5)),
                    TreeWalk.watchedNames(base, budget: .seconds(5), watch: { _ in true }))
        }
        let (summary, names) = await task.value
        #expect(summary == nil)
        #expect(names == nil)
    }
}
