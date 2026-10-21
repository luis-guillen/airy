import Foundation
import Synchronization
import Testing
@testable import DiskMapCore

// MARK: - Doubles and utilities

/// Fake process listing (local: the one in `FunnelTests` is private).
private final class SchemaListing: ProcessListing, Sendable {
    private let list: Mutex<[RunningProcess]?>
    init(_ list: [RunningProcess]? = []) { self.list = Mutex(list) }
    func set(_ new: [RunningProcess]?) { list.withLock { $0 = new } }
    func processes() -> [RunningProcess]? { list.withLock { $0 } }
    func holders(ofPathsUnder paths: [String]) -> [RunningProcess]? { [] }
}

private func tempDir(_ label: String = "airy-schema") -> String {
    let url = TestTemp.url("\(label)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.path
}

private func makeDir(_ path: String) {
    try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
}

/// File with real (non-sparse) contents: it takes `bytes` on disk.
private func writeFile(_ path: String, bytes: Int = 10_000) {
    makeDir((path as NSString).deletingLastPathComponent)
    FileManager.default.createFile(atPath: path, contents: Data(repeating: 0x41, count: bytes))
}

private func setModified(_ path: String, daysAgo: Double) {
    try! FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(-daysAgo * 86_400)], ofItemAtPath: path)
}

private func entry(
    _ id: String, risk: Risk = .safe, paths: [String], cleanup: CleanupMethod = .trash,
    perMatch: Bool = false, except: [String] = [], staleAfterDays: Int? = nil, minimumBytes: Int64? = nil,
    retention: RetentionRule? = nil
) -> CatalogEntry {
    CatalogEntry(
        id: id, title: "Prueba \(id)", explanation: "", whoCreatesIt: "", regenerates: true, risk: risk,
        kind: .caches, paths: paths, cleanup: cleanup, perMatch: perMatch, except: except,
        staleAfterDays: staleAfterDays, minimumBytes: minimumBytes, retention: retention)
}

private func scanner(_ entries: [CatalogEntry], home: String, runner: FakeRunner = FakeRunner(),
                     measureBudget: Duration = TimeBudget.sizeMeasure) -> CleanupScanner {
    CleanupScanner(
        catalog: Catalog(entries: entries), runner: runner, probes: FakeProbes(),
        references: ReferenceChecker(roots: []), home: home, processListing: SchemaListing(),
        measureBudget: measureBudget)
}

private func executor(_ entries: [CatalogEntry], home: String, runner: FakeRunner = FakeRunner(),
                      listing: SchemaListing = SchemaListing(), freeSpace: FakeFreeSpace = FakeFreeSpace([0]),
                      protected: [String] = [], log: OperationLog? = nil,
                      beforeRun: (@Sendable (String) -> Void)? = nil) -> CleanupExecutor {
    var settings = AirySettings()
    settings.protectedPaths = protected
    let load = SettingsLoad.loaded(settings)
    return CleanupExecutor(
        runner: runner, probes: FakeProbes(), store: IndexStore(directory: URL(fileURLWithPath: tempDir("airy-schema-store"))),
        catalog: Catalog(entries: entries), references: ReferenceChecker(roots: []), home: home,
        freeSpace: { freeSpace.next() }, trashSettleDelay: .zero, settings: { load }, log: log,
        processGuard: ProcessGuard(listing: listing), processListing: listing, beforeMove: beforeRun)
}

private func makeLog() -> OperationLog {
    OperationLog(file: URL(fileURLWithPath: tempDir("airy-schema-log")).appendingPathComponent("ops.jsonl"))
}

/// Replaces `path` with a symbolic link to `destination`.
private func replaceWithLink(_ path: String, to destination: String) {
    try? FileManager.default.removeItem(atPath: path)
    try! FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: destination)
}

// MARK: - Tests

@Suite struct CatalogSchemaTests {
    @Test func newFieldsRoundTripAndDefaultsAreOmitted() throws {
        let json = """
        {"entries":[{"id":"x","title":"X","explanation":"","whoCreatesIt":"","regenerates":true,"risk":"yourCall",
        "kind":"caches","paths":["~/x/*"],"cleanup":{"type":"trash"},"shortReason":"It regenerates itself.",
        "perMatch":true,"except":[".DS_Store"],"staleAfterDays":180,"minimumBytes":52428800,
        "retention":{"keepNewest":2,"activeLink":"~/.local/bin/claude"},
        "discovery":{"type":"projectArtifacts","names":["node_modules"],"cachedirTag":true},
        "reviewHint":"Check it yourself."}]}
        """
        let decoded = try #require(try Catalog.decode(Data(json.utf8)).entries.first)
        #expect(decoded.shortReason == "It regenerates itself.")
        #expect(decoded.perMatch)
        #expect(decoded.except == [".DS_Store"])
        #expect(decoded.staleAfterDays == 180)
        #expect(decoded.minimumBytes == 52_428_800)
        #expect(decoded.retention == RetentionRule(keepNewest: 2, activeLink: "~/.local/bin/claude"))
        #expect(decoded.discovery == .projectArtifacts(names: ["node_modules"], cachedirTag: true))
        #expect(decoded.reviewHint == "Check it yourself.")

        let again = try JSONDecoder().decode(CatalogEntry.self, from: JSONEncoder().encode(decoded))
        #expect(again.shortReason == decoded.shortReason && again.perMatch && again.except == decoded.except
                && again.staleAfterDays == 180 && again.minimumBytes == decoded.minimumBytes
                && again.retention == decoded.retention && again.discovery == decoded.discovery
                && again.reviewHint == decoded.reviewHint)

        for kind in [DiscoveryKind.installers, .simulatorRuntimes, .appSupportCaches, .docker] {
            var e = decoded
            e.discovery = kind
            let back = try JSONDecoder().decode(CatalogEntry.self, from: JSONEncoder().encode(e))
            #expect(back.discovery == kind)
        }

        // Default values: they are not encoded.
        let plain = entry("plain", paths: ["~/p"])
        let text = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
        for key in ["shortReason", "perMatch", "except", "staleAfterDays", "minimumBytes", "retention",
                    "discovery", "reviewHint"] {
            #expect(!text.contains("\"\(key)\""), "\(key) should not be encoded: \(text)")
        }
        let minimal = try #require(try Catalog.decode(Data("""
        {"entries":[{"id":"m","title":"M","explanation":"","whoCreatesIt":"","regenerates":true,"risk":"safe",
        "kind":"caches","paths":[],"cleanup":{"type":"info"}}]}
        """.utf8)).entries.first)
        #expect(!minimal.perMatch && minimal.except.isEmpty && minimal.retention == nil && minimal.discovery == nil
                && minimal.shortReason == nil && minimal.reviewHint == nil)

        let unknown = json.replacingOccurrences(of: "\"type\":\"projectArtifacts\"", with: "\"type\":\"nope\"")
        #expect(throws: DecodingError.self) { try Catalog.decode(Data(unknown.utf8)) }
        let zeroKeep = json.replacingOccurrences(of: "\"keepNewest\":2", with: "\"keepNewest\":0")
        #expect(throws: DecodingError.self) { try Catalog.decode(Data(zeroKeep.utf8)) }
        #expect(CleanupMethod.targetPlaceholder == "{target}")
    }

    @Test func treeWalkStopsAtBudgetAndDoesNotFollowLinks() throws {
        let root = tempDir()
        let big = tempDir("airy-schema-big")
        defer { try? FileManager.default.removeItem(atPath: big) }
        writeFile(big + "/blob", bytes: 10_000_000)
        writeFile(root + "/small", bytes: 4_096)
        try FileManager.default.createSymbolicLink(atPath: root + "/link", withDestinationPath: big)

        #expect(TreeWalk.summarize(root, budget: .zero) == nil)
        let summary = try #require(TreeWalk.summarize(root, budget: .seconds(10), watch: { $0 == "blob" }))
        #expect(summary.bytes < 1_000_000, "the link is not walked: \(summary.bytes)")
        #expect(summary.bytes >= 4_096)
        #expect(summary.watched.isEmpty, "it does not enter the link's target")
        // A link as the root: its own entry, never its target.
        let link = try #require(TreeWalk.summarize(root + "/link", budget: .seconds(10)))
        #expect(link.bytes < 1_000_000)
        // A file as the root: its size and its date.
        setModified(big + "/blob", daysAgo: 30)
        let file = try #require(TreeWalk.summarize(big + "/blob", budget: .seconds(10)))
        #expect(file.bytes >= 10_000_000)
        let age = Date().timeIntervalSince(try #require(file.latestModification))
        #expect(abs(age - 30 * 86_400) < 60)
        #expect(TreeWalk.summarize(root + "/no-existe", budget: .seconds(10)) == nil)

        // Hard links: only once.
        let hard = tempDir()
        writeFile(hard + "/a", bytes: 1_000_000)
        try FileManager.default.linkItem(atPath: hard + "/a", toPath: hard + "/b")
        let hardSummary = try #require(TreeWalk.summarize(hard, budget: .seconds(10)))
        #expect(hardSummary.bytes < 1_500_000)
    }

    @Test func treeWalkPrunesAndWatches() throws {
        let project = tempDir()
        writeFile(project + "/src/index.js", bytes: 1_000)
        writeFile(project + "/node_modules/dep/index.js", bytes: 2_000_000)
        writeFile(project + "/deploy/solana-keypair.json", bytes: 100)
        for path in [project + "/src/index.js", project + "/src", project + "/deploy/solana-keypair.json",
                     project + "/deploy", project] {
            setModified(path, daysAgo: 200)
        }
        // node_modules just touched: it counts neither in the date nor in the size.
        let summary = try #require(TreeWalk.summarize(
            project, budget: .seconds(10), prune: { name, _ in name == "node_modules" },
            watch: { $0.hasSuffix("-keypair.json") }))
        let latest = try #require(summary.latestModification)
        #expect(Date().timeIntervalSince(latest) > 190 * 86_400)
        #expect(summary.bytes < 1_000_000)
        #expect(summary.watched == ["deploy/solana-keypair.json"])
        // Without pruning, the recent change does count.
        let full = try #require(TreeWalk.summarize(project, budget: .seconds(10)))
        #expect(Date().timeIntervalSince(try #require(full.latestModification)) < 86_400)
        #expect(full.bytes > 2_000_000)
    }

    @Test func perMatchExceptStaleAndMinimum() async {
        let home = tempDir()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let downloads = home + "/Downloads"
        writeFile(downloads + "/a.bin", bytes: 20 * 1_048_576)
        writeFile(downloads + "/b.bin", bytes: 20 * 1_048_576)
        writeFile(downloads + "/c.bin", bytes: 1 * 1_048_576)
        writeFile(downloads + "/.DS_Store", bytes: 10 * 1_048_576)
        for name in ["a.bin", "c.bin", ".DS_Store"] { setModified(downloads + "/" + name, daysAgo: 400) }
        let old = entry("old", risk: .yourCall, paths: ["~/Downloads/*"], perMatch: true,
                        except: [".DS_Store"], staleAfterDays: 180, minimumBytes: 5 * 1_048_576)
        let items = await scanner([old], home: home).findItems(scan: nil)
        #expect(items.map(\.id) == ["old:~/Downloads/a.bin"])
        #expect(items.first?.paths == [downloads + "/a.bin"])
        #expect((items.first?.bytes ?? 0) >= 20 * 1_048_576)
        #expect(items.first?.lastModified != nil)
        #expect(items.first?.title == "Prueba old: ~/Downloads/a.bin")
    }

    @Test func retentionKeepsNewestTwoPerParent() async {
        let home = tempDir()
        let base = home + "/Library/Developer/Xcode"
        for (i, version) in ["15", "16", "17"].enumerated() {
            writeFile(base + "/iOS DeviceSupport/\(version)/symbols", bytes: 100_000)
            setModified(base + "/iOS DeviceSupport/\(version)", daysAgo: Double(30 - i * 10))
        }
        for (i, version) in ["9", "10"].enumerated() {
            writeFile(base + "/watchOS DeviceSupport/\(version)/symbols", bytes: 100_000)
            setModified(base + "/watchOS DeviceSupport/\(version)", daysAgo: Double(30 - i * 10))
        }
        let support = entry("device-support", paths: [
            "~/Library/Developer/Xcode/iOS DeviceSupport/*", "~/Library/Developer/Xcode/watchOS DeviceSupport/*",
        ], retention: RetentionRule(keepNewest: 2))
        let items = await scanner([support], home: home).findItems(scan: nil)
        #expect(items.count == 1)
        #expect(items.first?.id == "device-support")
        #expect(items.first?.paths == [base + "/iOS DeviceSupport/15"])
        #expect(items.first?.details == ["Kept: 17, 16", "Kept: 10, 9"])
    }

    @Test func retentionKeepsActiveLinkPlusOne() async throws {
        let home = tempDir()
        let versions = home + "/.local/share/claude/versions"
        for (i, version) in ["1.0", "1.1", "2.0"].enumerated() {
            writeFile(versions + "/\(version)/claude", bytes: 50_000)
            setModified(versions + "/\(version)", daysAgo: Double(30 - i * 10))
        }
        makeDir(home + "/.local/bin")
        try FileManager.default.createSymbolicLink(
            atPath: home + "/.local/bin/claude", withDestinationPath: versions + "/1.0/claude")
        let agent = entry("claude-versions", paths: ["~/.local/share/claude/versions/*"],
                          retention: RetentionRule(keepNewest: 2, activeLink: "~/.local/bin/claude"))
        let items = await scanner([agent], home: home).findItems(scan: nil)
        #expect(items.map(\.paths) == [[versions + "/1.1"]])
        #expect(items.first?.details == ["Kept: 2.0, 1.0"])

        // Broken link: fail closed, nothing is offered.
        try FileManager.default.removeItem(atPath: home + "/.local/bin/claude")
        try FileManager.default.createSymbolicLink(atPath: home + "/.local/bin/claude", withDestinationPath: home + "/nada")
        #expect(await scanner([agent], home: home).findItems(scan: nil).isEmpty)

        // In the funnel: a running version of the item, or an unreadable listing, block.
        try FileManager.default.removeItem(atPath: home + "/.local/bin/claude")
        try FileManager.default.createSymbolicLink(
            atPath: home + "/.local/bin/claude", withDestinationPath: versions + "/1.0/claude")
        let item = try #require(items.first)
        let listing = SchemaListing([RunningProcess(pid: 7, name: "claude", executablePath: versions + "/1.1/claude")])
        guard case .blocked(let reason) = await executor([agent], home: home, listing: listing).execute(item) else {
            Issue.record("should have been blocked"); return
        }
        #expect(reason == "It is in use: 1.1.")
        guard case .blocked(let unknown) = await executor([agent], home: home, listing: SchemaListing(nil)).execute(item)
        else { Issue.record("should have been blocked"); return }
        #expect(unknown == "Could not check whether it is in use; Airy does not touch it.")
        #expect(FileManager.default.fileExists(atPath: versions + "/1.1/claude"))
    }

    @Test func samePathNeverInTwoItems() async {
        let home = tempDir()
        writeFile(home + "/Library/Caches/shared/data", bytes: 300_000)
        writeFile(home + "/Library/Caches/only-second/data", bytes: 100_000)
        let first = entry("first", paths: ["~/Library/Caches/shared"])
        let second = entry("second", paths: ["~/Library/Caches/shared", "~/Library/Caches/only-second"])
        let third = entry("third", paths: ["~/Library/Caches/shared"])
        let items = await scanner([first, second, third], home: home).findItems(scan: nil)
        #expect(items.map(\.id) == ["first", "second"])
        #expect(items.first?.paths == [home + "/Library/Caches/shared"])
        #expect(items.last?.paths == [home + "/Library/Caches/only-second"])
        let total = items.reduce(Int64(0)) { $0 + $1.bytes }
        #expect(total < 600_000, "without double counting: \(total)")
        #expect(total >= 400_000)
    }

    @Test func zeroByteItemsOnlyWithNoteOrBlock() async {
        let home = tempDir()
        FileManager.default.createFile(atPath: home + "/empty", contents: Data())
        writeFile(home + "/Library/Caches/full/data", bytes: 50_000)
        let empty = entry("empty", paths: ["~/empty"])
        let full = entry("full", paths: ["~/Library/Caches/full"])
        #expect(await scanner([empty, full], home: home).findItems(scan: nil).map(\.id) == ["full"])

        // Without time to measure: it keeps a note and a block, even if it measures 0.
        let items = await scanner([full], home: home, measureBudget: .zero).findItems(scan: nil)
        #expect(items.map(\.id) == ["full"])
        #expect(items.first?.bytes == 0)
        #expect(items.first?.sizeNote == "Unknown size")
        #expect(items.first?.blockedReason == "Could not be measured in time.")
    }

    @Test func funnelRevalidatesThroughTheSource() async throws {
        let home = tempDir()
        let parent = home + "/Library/Developer/Xcode/iOS DeviceSupport"
        for (i, version) in ["15", "16", "17"].enumerated() {
            writeFile(parent + "/\(version)/symbols", bytes: 100_000)
            setModified(parent + "/\(version)", daysAgo: Double(30 - i * 10))
        }
        let support = entry("device-support", paths: ["~/Library/Developer/Xcode/iOS DeviceSupport/*"],
                            retention: RetentionRule(keepNewest: 2))
        let item = try #require(await scanner([support], home: home).findItems(scan: nil).first)
        #expect(item.paths == [parent + "/15"])
        // Now 15 is the newest: it is kept and the funnel rejects it.
        setModified(parent + "/15", daysAgo: 0)
        let outcome = await executor([support], home: home).execute(item)
        #expect(outcome == .blocked(reason: "It is no longer an old version: 15."))
        #expect(FileManager.default.fileExists(atPath: parent + "/15/symbols"))

        // Static patterns entry with `staleAfterDays`: if it was used since the detection, it is not touched.
        writeFile(home + "/Downloads/old.zip", bytes: 2 * 1_048_576)
        setModified(home + "/Downloads/old.zip", daysAgo: 400)
        let downloads = entry("old", risk: .yourCall, paths: ["~/Downloads/*"], perMatch: true, staleAfterDays: 180)
        let stale = try #require(await scanner([downloads], home: home).findItems(scan: nil).first)
        setModified(home + "/Downloads/old.zip", daysAgo: 1)
        #expect(await executor([downloads], home: home).execute(stale) == .blocked(reason: "You have used it recently."))
        #expect(FileManager.default.fileExists(atPath: home + "/Downloads/old.zip"))
    }

    @Test func targetPlaceholderRunsOncePerValidatedTarget() async throws {
        let home = tempDir()
        let db1 = home + "/Library/Safari/History.db"
        let db2 = home + "/Library/Safari/Other.db"
        writeFile(db1)
        writeFile(db2)
        // Literals: `~/Library/Safari` belongs to a sensitive app and a wildcard at its level never counts as an exception.
        let compact = entry("safari-compact", paths: ["~/Library/Safari/History.db", "~/Library/Safari/Other.db",
                                                      "~/Library/Safari/Evil.db"],
                            cleanup: .command(executable: "sqlite3", arguments: ["{target}", "VACUUM;"], sizeProbe: nil))
        let runner = FakeRunner(resolved: ["sqlite3": "/usr/bin/sqlite3"])
        let detected = try #require(await scanner([compact], home: home, runner: runner).findItems(scan: nil).first)
        #expect(detected.targets == [db1, db2].sorted())

        let exec = executor([compact], home: home, runner: runner, freeSpace: FakeFreeSpace([0, 100, 100, 250]))
        var item = detected
        item.targets = [db1, db2]
        #expect(await exec.preview(item, logged: false)
                == .wouldRun(command: ["sqlite3", db1, "VACUUM;"], bytes: item.bytes, upperBound: false))
        let outcome = await exec.execute(item)
        #expect(outcome == .freed(250))
        #expect(runner.calls.map(\.arguments) == [[db1, "VACUUM;"], [db2, "VACUUM;"]])

        // Without targets, with a relative or a protected target: blocked and without running anything.
        let quiet = FakeRunner(resolved: ["sqlite3": "/usr/bin/sqlite3"])
        let blockedExec = executor([compact], home: home, runner: quiet)
        let keychain = home + "/Library/Keychains/x"
        writeFile(keychain)
        for targets in [[], ["History.db"], [keychain], [db1, keychain]] {
            item.targets = targets
            guard case .blocked = await blockedExec.execute(item) else {
                Issue.record("should have been blocked with \(targets)"); continue
            }
        }
        // A target the user has protected: the classifier stops it (the entry's paths) before `PathGate`.
        item.targets = [db1, db2]
        let guarded = executor([compact], home: home, runner: quiet, protected: ["~/Library/Safari/Other.db"])
        guard case .blocked(let reason) = await guarded.execute(item) else {
            Issue.record("should have been blocked by the user's list"); return
        }
        #expect(reason.contains("You protected it"), "\(reason)")
        // A link of the entry that points to the Keychains: only `PathGate` (which resolves links) stops it.
        let evil = home + "/Library/Safari/Evil.db"
        try FileManager.default.createSymbolicLink(atPath: evil, withDestinationPath: keychain)
        item.targets = [db1, evil]
        guard case .blocked(let linkReason) = await blockedExec.execute(item) else {
            Issue.record("the link to the Keychains should have been blocked"); return
        }
        // Refusal from `PathGate` (resolved form: Keychains or the "keychain" component), not from the ownership check.
        #expect(linkReason.contains("“Prueba safari-compact” is not run on \(evil)"), "\(linkReason)")
        #expect(linkReason.contains("Llaveros") || linkReason.contains("keychain"), "\(linkReason)")
        try FileManager.default.removeItem(atPath: evil)
        #expect(quiet.calls.isEmpty)

        // The first failure stops the batch.
        let failing = FakeRunner(resolved: ["sqlite3": "/usr/bin/sqlite3"],
                                 outputs: ["/usr/bin/sqlite3 \(db1) VACUUM;": CommandOutput(status: 1, stdout: "", stderr: "locked")])
        item.targets = [db1, db2]
        guard case .failed = await executor([compact], home: home, runner: failing).execute(item) else {
            Issue.record("should have failed"); return
        }
        #expect(failing.calls.count == 1)
    }

    @Test func targetBatchChecksEachTargetAtActAndLogsPartial() async throws {
        let home = tempDir()
        let db1 = home + "/Library/Safari/History.db"
        let db2 = home + "/Library/Safari/Other.db"
        let keychain = home + "/Library/Keychains/login.keychain-db"
        for path in [db1, db2, keychain] { writeFile(path) }
        let compact = entry("safari-compact", paths: ["~/Library/Safari/History.db", "~/Library/Safari/Other.db"],
                            cleanup: .command(executable: "sqlite3", arguments: ["{target}", "VACUUM;"], sizeProbe: nil))
        let detected = try #require(await scanner(
            [compact], home: home, runner: FakeRunner(resolved: ["sqlite3": "/usr/bin/sqlite3"])).findItems(scan: nil).first)
        var item = detected
        item.targets = [db1, db2]

        // The first target becomes a link between the plan and its run: nothing runs.
        let first = FakeRunner(resolved: ["sqlite3": "/usr/bin/sqlite3"])
        let swapFirst = executor([compact], home: home, runner: first, beforeRun: { path in
            if path == db1 { replaceWithLink(db1, to: keychain) }
        })
        guard case .blocked(let reason) = await swapFirst.execute(item) else {
            Issue.record("should have been blocked on the first target"); return
        }
        #expect(first.calls.isEmpty, "\(reason)")
        try FileManager.default.removeItem(atPath: db1)
        writeFile(db1)

        // The second changes after running the first: it stops and the record is "partial" with what ran.
        let second = FakeRunner(resolved: ["sqlite3": "/usr/bin/sqlite3"])
        let log = makeLog()
        let swapSecond = executor([compact], home: home, runner: second, freeSpace: FakeFreeSpace([0, 40]), log: log,
                                  beforeRun: { path in if path == db2 { replaceWithLink(db2, to: keychain) } })
        guard case .blocked = await swapSecond.execute(item) else { Issue.record("should have been blocked"); return }
        #expect(second.calls.map(\.arguments) == [[db1, "VACUUM;"]])
        let blockedRecord = try #require(try log.records().last)
        #expect(blockedRecord.outcome == "partial" && blockedRecord.paths == [db1] && blockedRecord.bytes == 40)
        try FileManager.default.removeItem(atPath: db2)
        writeFile(db2)

        // The first goes well and the second fails: "partial" with the first one and its bytes.
        let failing = FakeRunner(resolved: ["sqlite3": "/usr/bin/sqlite3"],
                                 outputs: ["/usr/bin/sqlite3 \(db2) VACUUM;": CommandOutput(status: 1, stdout: "", stderr: "locked")])
        let failLog = makeLog()
        guard case .failed = await executor([compact], home: home, runner: failing, freeSpace: FakeFreeSpace([0, 70, 70]),
                                            log: failLog).execute(item) else { Issue.record("should have failed"); return }
        let failRecord = try #require(try failLog.records().last)
        #expect(failRecord.outcome == "partial" && failRecord.paths == [db1] && failRecord.bytes == 70)

        // All good: the record notes the command that really ran.
        let okLog = makeLog()
        guard case .freed = await executor([compact], home: home, runner: FakeRunner(resolved: ["sqlite3": "/usr/bin/sqlite3"]),
                                           log: okLog).execute(item) else { Issue.record("should have run"); return }
        let okRecord = try #require(try okLog.records().last)
        #expect(okRecord.command == ["sqlite3", db1, "VACUUM;"] && okRecord.paths == [db1, db2])
    }

    @Test func funnelRefusesItemsTheScanBlocked() async throws {
        let home = tempDir()
        writeFile(home + "/Library/Caches/full/data", bytes: 50_000)
        let full = entry("full", paths: ["~/Library/Caches/full"])
        let item = try #require(await scanner([full], home: home, measureBudget: .zero).findItems(scan: nil).first)
        #expect(item.blockedReason == "Could not be measured in time.")
        let runner = FakeRunner()
        let outcome = await executor([full], home: home, runner: runner).execute(item)
        #expect(outcome == .blocked(reason: "“Prueba full” cannot be cleaned right now: Could not be measured in time."))
        #expect(FileManager.default.fileExists(atPath: home + "/Library/Caches/full/data"))
    }

    @Test func classifierFloorOnlyRaises() {
        let home = tempDir()
        let classifier = RiskClassifier(catalog: Catalog(entries: []), settings: AirySettings(), home: home)
        let green = entry("g", paths: ["~/Library/Caches/g"])
        let amber = entry("a", risk: .yourCall, paths: ["~/Library/Caches/a"])
        #expect(classifier.classify(entry: green, paths: [home + "/Library/Caches/g"], floor: .doNotTouch).risk
                == .doNotTouch)
        #expect(classifier.classify(entry: amber, paths: [home + "/Library/Caches/a"], floor: .safe).risk == .yourCall)
        #expect(classifier.classify(entry: green, paths: [home + "/Library/Caches/g"]).risk == .safe)
    }
}

// MARK: - Development tool versions (plan 3b)

@Suite struct ToolchainCatalogSchemaTests {
    @Test func toolchainDiscoveryDecodesAndRoundTrips() throws {
        let json = Data(#"{"type":"toolchains","manager":"rustup"}"#.utf8)
        let kind = try JSONDecoder().decode(DiscoveryKind.self, from: json)
        #expect(kind == .toolchains(manager: .rustup))
        #expect(try JSONDecoder().decode(DiscoveryKind.self, from: try JSONEncoder().encode(kind)) == kind)
        for other in [DiscoveryKind.toolchainSystemInfo, .dependencyDuplicates] {
            #expect(try JSONDecoder().decode(DiscoveryKind.self, from: try JSONEncoder().encode(other)) == other)
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(DiscoveryKind.self, from: Data(#"{"type":"toolchains","manager":"x"}"#.utf8))
        }
    }

    private static func toolchainEntries() throws -> [(ToolchainManager, CatalogEntry)] {
        try Catalog.bundled().entries.compactMap { entry in
            if case .toolchains(let manager) = entry.discovery { return (manager, entry) }
            return nil
        }
    }

    @Test func toolchainFichasAreNeverGreen() throws {
        let entries = try Self.toolchainEntries()
        #expect(entries.count == 12)
        let catalog = try Catalog.bundled()
        for (_, entry) in entries {
            #expect(entry.risk == .yourCall && entry.aggressiveRisk == nil && entry.profiles.isEmpty, "\(entry.id)")
            for mode in CleanupMode.allCases {
                var settings = AirySettings()
                settings.mode = mode
                #expect(RiskClassifier(catalog: catalog, settings: settings, home: "/Users/ana").baseRisk(of: entry)
                    == .yourCall)
            }
        }
        for id in ["toolchain-system-info", "node-dependency-duplicates"] {
            #expect(catalog.entry(id: id)?.cleanup == .info, "\(id)")
        }
    }

    @Test func toolchainCommandsAreArgumentArraysWithTarget() throws {
        let commands: Set<ToolchainManager> = [.pyenv, .conda, .fnm, .rbenv, .rustup, .homebrew]
        for (manager, entry) in try Self.toolchainEntries() where commands.contains(manager) {
            guard case .command(let executable, let arguments, _) = entry.cleanup else {
                Issue.record("\(entry.id) without a command"); continue
            }
            #expect(entry.cleanup.usesTargets, "\(entry.id)")
            #expect(!([executable] + arguments).contains { $0.contains(" ") || $0 == "sh" }, "\(entry.id)")
            if manager == .conda { #expect(arguments.contains("-p") && !arguments.contains("-n")) }
        }
    }

    @Test func shellFunctionManagersUseTrash() throws {
        let trash: Set<ToolchainManager> = [.nvm, .volta, .asdf, .rvm, .sdkman, .goSDK]
        let entries = try Self.toolchainEntries()
        #expect(Set(entries.map(\.0)) == Set(ToolchainManager.allCases).subtracting([.system]))
        for (manager, entry) in entries where trash.contains(manager) { #expect(entry.cleanup == .trash, "\(entry.id)") }
    }
}

/// M5: the catalog exception inside a sensitive app's folder is only valid for caches. Any future
/// entry with something like `Google/Chrome/*/History` breaks this test.
@Suite struct SensitiveAppCatalogPatternTests {
    /// Names without "cache" that are also regenerable (sent crash reports, downloaded VM images).
    static let allowedLastComponents: Set<String> = ["completed", "vm_bundles"]

    /// `Cache`, `Code Cache`, `GPUCache`, `Dawn*Cache`, `CacheStorage`, `ScriptCache`, `CachedData`,
    /// `component_crx_cache`, `Media Cache Files`…; never `History`, `Cookies`, `Login Data`, `Default`.
    static func isCacheName(_ name: String) -> Bool {
        allowedLastComponents.contains(name) || name.lowercased().contains("cache")
    }

    @Test func patternsUnderSensitiveAppFoldersEndInACacheName() throws {
        let catalog = try Catalog.bundled()
        var offenders: [String] = []
        for entry in catalog.entries where entry.cleanup != .info {
            for pattern in entry.paths where pattern.hasPrefix("~/") {
                let relative = String(pattern.dropFirst(2))
                for root in HardProtections.appDataRoots where relative.hasPrefix(root + "/") {
                    let rest = relative.dropFirst(root.count + 1).split(separator: "/").map(String.init)
                    guard let folder = rest.first, rest.count > 1,
                          HardProtections.sensitiveAppName(folder) != nil else { continue }
                    let last = rest.last!
                    if !Self.isCacheName(last) { offenders.append("\(entry.id): \(pattern)") }
                }
            }
        }
        #expect(offenders.isEmpty, "\(offenders)")
    }
}

