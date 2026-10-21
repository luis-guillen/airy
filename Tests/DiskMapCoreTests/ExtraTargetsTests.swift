import Foundation
import Synchronization
import Testing
@testable import DiskMapCore

// MARK: - Doubles and utilities

private final class FakeListing: ProcessListing, Sendable {
    private let list: Mutex<[RunningProcess]?>
    init(_ list: [RunningProcess]? = []) { self.list = Mutex(list) }
    func processes() -> [RunningProcess]? { list.withLock { $0 } }
    func holders(ofPathsUnder paths: [String]) -> [RunningProcess]? { [] }
}

/// Slow runner: each call takes `delay` and is recorded. Only `zipinfo` resolves.
private final class SlowRunner: CommandRunning, Sendable {
    private let count = Mutex(0)
    let delay: Duration
    init(delay: Duration) { self.delay = delay }
    var calls: Int { count.withLock { $0 } }

    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> CommandOutput {
        count.withLock { $0 += 1 }
        try? await Task.sleep(for: delay)
        return CommandOutput(status: 0, stdout: "Foo.app/\n", stderr: "")
    }

    func resolve(_ executable: String) async -> String? { executable == "zipinfo" ? "/usr/bin/zipinfo" : nil }
}

private func tempDir() -> String {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("airy-extra-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.path
}

private func makeDir(_ path: String) {
    try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
}

private func writeFile(_ path: String, bytes: Int = 10_000, daysAgo: Double = 0) {
    makeDir((path as NSString).deletingLastPathComponent)
    FileManager.default.createFile(atPath: path, contents: Data(repeating: 0x41, count: bytes))
    if daysAgo > 0 {
        try! FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-daysAgo * 86_400)], ofItemAtPath: path)
    }
}

private func setModified(_ path: String, daysAgo: Double) {
    try! FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(-daysAgo * 86_400)], ofItemAtPath: path)
}

private func catalog(_ ids: String...) throws -> Catalog {
    let all = try Catalog.bundled()
    return Catalog(entries: try ids.map { try #require(all.entry(id: $0), "\($0)") })
}

private func scanner(_ catalog: Catalog, home: String, runner: FakeRunner = FakeRunner(),
                     probes: FakeProbes = FakeProbes(), measureBudget: Duration = TimeBudget.sizeMeasure)
    -> CleanupScanner {
    CleanupScanner(
        catalog: catalog, runner: runner, probes: probes, references: ReferenceChecker(roots: []), home: home,
        processListing: FakeListing(), measureBudget: measureBudget)
}

private func executor(_ catalog: Catalog, home: String, runner: FakeRunner = FakeRunner(),
                      probes: FakeProbes = FakeProbes(), listing: FakeListing = FakeListing()) -> CleanupExecutor {
    let load = SettingsLoad.loaded(AirySettings())
    return CleanupExecutor(
        runner: runner, probes: probes, store: IndexStore(directory: URL(fileURLWithPath: tempDir())),
        catalog: catalog, references: ReferenceChecker(roots: []), home: home,
        freeSpace: { 0 }, trashSettleDelay: .zero, settings: { load },
        processGuard: ProcessGuard(listing: listing), processListing: listing)
}

private let zipinfo = "/usr/bin/zipinfo"
private let sqlite3 = "/usr/bin/sqlite3"

private let reviewIDs = [
    "system-diagnostic-reports", "system-logs", "system-caches", "macos-installers", "chrome-old-frameworks",
    "brave-old-frameworks", "edge-old-frameworks", "ios-backups", "android-emulators", "agent-worktrees",
    "time-machine-in-progress", "music-sound-libraries",
]

// MARK: - Tests

@Suite struct ExtraTargetsTests {
    // MARK: Installers

    @Test func installersByExtensionAndZipListing() async throws {
        let home = tempDir()
        for name in ["a.dmg", "b.pkg", "c.zip", "d.zip", "e.txt"] { writeFile(home + "/Downloads/\(name)") }
        writeFile(home + "/Desktop/Carpeta/f.iso")
        writeFile(home + "/Desktop/Carpeta/Mas/Hondo/g.dmg") // too deep
        writeFile(home + "/Documents/H.XIP")
        let runner = FakeRunner(resolved: ["zipinfo": zipinfo], outputs: [
            "\(zipinfo) -1 \(home)/Downloads/c.zip": CommandOutput(status: 0, stdout: "Foo.app/\nFoo.app/Contents/x\n", stderr: ""),
            "\(zipinfo) -1 \(home)/Downloads/d.zip": CommandOutput(status: 0, stdout: "notes.txt\n", stderr: ""),
        ])
        let items = await scanner(try catalog("installers"), home: home, runner: runner).findItems(scan: nil)
        #expect(items.map(\.id) == [
            "installers:~/Desktop/Carpeta/f.iso", "installers:~/Documents/H.XIP", "installers:~/Downloads/a.dmg",
            "installers:~/Downloads/b.pkg", "installers:~/Downloads/c.zip",
        ])
        #expect(items.allSatisfy { $0.risk == .yourCall && !$0.preselected && $0.details.count == 1 })
        #expect(items.first?.details.first?.hasPrefix("Downloaded ") == true)
        // .zip files are read with `zipinfo -1 <path>` and a `zipListTimeout` time limit.
        #expect(runner.calls.map(\.arguments).contains(["-1", home + "/Downloads/c.zip"]))
        #expect(runner.calls.allSatisfy { $0.timeout <= InstallerSource.zipListTimeout })
    }

    @Test func zipRulesByLevel() async {
        func has(_ listing: String) async -> Bool {
            let r = FakeRunner(outputs: ["\(zipinfo) -1 z.zip": CommandOutput(status: 0, stdout: listing, stderr: "")])
            return await InstallerSource.zipHasInstaller("z.zip", zipinfo: zipinfo, runner: r, timeout: 5)
        }
        #expect(await has("Foo.app/Contents/Info.plist\n"))
        #expect(await has("Carpeta/Foo.app/\n"))
        #expect(!(await has("A/B/Foo.app/\n"))) // level 3
        #expect(await has("Instalar.PKG\n"))
        #expect(await has("Carpeta/x.dmg\n"))
        #expect(!(await has("A/B/x.pkg\n")))
        #expect(!(await has("Carpeta/x.pkg/\n"))) // a folder, not a file
        #expect(!(await has("notes.txt\nfoto.png\n")))
    }

    @Test func zipinfoFailureIsNotAnInstaller() async throws {
        let home = tempDir()
        writeFile(home + "/Downloads/c.zip")
        writeFile(home + "/Downloads/a.dmg")
        let failing = FakeRunner(resolved: ["zipinfo": zipinfo], outputs: [
            "\(zipinfo) -1 \(home)/Downloads/c.zip": CommandOutput(status: 1, stdout: "Foo.app/\n", stderr: "error"),
        ])
        let items = await scanner(try catalog("installers"), home: home, runner: failing).findItems(scan: nil)
        #expect(items.map(\.id) == ["installers:~/Downloads/a.dmg"])
        // Without `zipinfo` installed there are no .zip files either, but the .dmg files remain.
        let missing = await scanner(try catalog("installers"), home: home).findItems(scan: nil)
        #expect(missing.map(\.id) == ["installers:~/Downloads/a.dmg"])
    }

    @Test func installersSkipLinksPackagesAndHiddenFolders() async throws {
        let home = tempDir()
        writeFile(home + "/Downloads/real.dmg")
        writeFile(home + "/Downloads/.oculta/x.dmg")
        writeFile(home + "/Downloads/Algo.app/x.dmg")
        writeFile(home + "/elsewhere/y.dmg")
        try FileManager.default.createSymbolicLink(atPath: home + "/Downloads/enlace.dmg",
                                                   withDestinationPath: home + "/elsewhere/y.dmg")
        try FileManager.default.createSymbolicLink(atPath: home + "/Downloads/carpeta-enlace",
                                                   withDestinationPath: home + "/elsewhere")
        let items = await scanner(try catalog("installers"), home: home).findItems(scan: nil)
        #expect(items.map(\.id) == ["installers:~/Downloads/real.dmg"])
    }

    @Test func installersRespectZipCountAndTimeBudget() async {
        let home = tempDir()
        for i in 0..<5 { writeFile(home + "/Downloads/z\(i).zip") }
        let all = Catalog(entries: [])
        func context(_ runner: any CommandRunning) -> DiscoveryContext {
            DiscoveryContext(catalog: all, home: home, runner: runner, processListing: FakeListing(),
                             now: Date(), scan: nil)
        }
        let entry = CatalogEntry(id: "installers", title: "I", explanation: "", whoCreatesIt: "", regenerates: false,
                                 risk: .yourCall, kind: .other, paths: [], cleanup: .trash, discovery: .installers)
        // At most `maxZips` reads.
        let capped = SlowRunner(delay: .milliseconds(1))
        let few = await InstallerSource(totalBudget: .seconds(20), maxZips: 2, isUbiquitous: { _ in false })
            .discover(entry, context: context(capped))
        #expect(capped.calls == 2 && few.count == 2)
        // The total time limit cuts the series even if there is room left.
        let slow = SlowRunner(delay: .milliseconds(150))
        let started = ContinuousClock.now
        let some = await InstallerSource(totalBudget: .milliseconds(200), maxZips: 50, isUbiquitous: { _ in false })
            .discover(entry, context: context(slow))
        // 1 or 2 reads depending on how loaded the machine is (in CI, sometimes 1); never the 50.
        #expect((1...2).contains(slow.calls) && some.count == slow.calls)
        #expect(started.duration(to: .now) < .seconds(3))
        #expect(InstallerSource.zipTotalBudget == .seconds(20) && InstallerSource.maxZipListings == 50)
    }

    @Test func installerAlsoOldIsListedOnce() async throws {
        let home = tempDir()
        writeFile(home + "/Downloads/a.dmg", bytes: 60_000_000, daysAgo: 365)
        writeFile(home + "/Downloads/grande.bin", bytes: 60_000_000, daysAgo: 365)
        writeFile(home + "/Downloads/reciente.bin", bytes: 60_000_000)
        writeFile(home + "/Downloads/.DS_Store", bytes: 60_000_000, daysAgo: 365)
        let cat = try catalog("installers", "old-downloads")
        #expect(cat.entries.map(\.id) == ["installers", "old-downloads"])
        let items = await scanner(cat, home: home).findItems(scan: nil)
        #expect(items.map(\.id) == ["installers:~/Downloads/a.dmg", "old-downloads:~/Downloads/grande.bin"])
        #expect(items.allSatisfy { $0.risk == .yourCall && !$0.preselected })
    }

    @Test func installersRevalidateAtActTime() async throws {
        let home = tempDir()
        let dmg = home + "/Downloads/a.dmg"
        writeFile(dmg)
        let cat = try catalog("installers")
        let item = try #require(await scanner(cat, home: home).findItems(scan: nil).first)
        let context = DiscoveryContext(catalog: cat, home: home, runner: FakeRunner(), processListing: FakeListing(),
                                       now: Date(), scan: nil)
        let source = InstallerSource()
        let entry = try #require(cat.entries.first)
        #expect(await source.revalidate(entry, item: item, context: context) == nil)
        // It becomes a link.
        try FileManager.default.removeItem(atPath: dmg)
        try FileManager.default.createSymbolicLink(atPath: dmg, withDestinationPath: home)
        #expect(await source.revalidate(entry, item: item, context: context) == "It is no longer a regular file: a.dmg.")
        // A path outside the installer folders.
        var outside = item
        outside.paths = [home + "/otro.dmg"]
        writeFile(home + "/otro.dmg")
        #expect(await source.revalidate(entry, item: outside, context: context)?.hasPrefix("It is not in Downloads") == true)
        // A .zip that no longer has an installer.
        let zip = home + "/Downloads/c.zip"
        writeFile(zip)
        var zipItem = item
        zipItem.paths = [zip]
        let runner = FakeRunner(resolved: ["zipinfo": zipinfo], outputs: [
            "\(zipinfo) -1 \(zip)": CommandOutput(status: 0, stdout: "notes.txt\n", stderr: ""),
        ])
        let zipContext = DiscoveryContext(catalog: cat, home: home, runner: runner, processListing: FakeListing(),
                                          now: Date(), scan: nil)
        #expect(await source.revalidate(entry, item: zipItem, context: zipContext) == "It is no longer an installer: c.zip.")
    }

    // MARK: Agent versions

    private func versionsHome(link: Bool) throws -> (home: String, versions: String) {
        let home = tempDir()
        let versions = home + "/.local/share/claude/versions"
        for (i, version) in ["1", "2", "3"].enumerated() {
            writeFile(versions + "/\(version)/claude", bytes: 50_000)
            setModified(versions + "/\(version)", daysAgo: Double(30 - i * 10))
        }
        if link {
            makeDir(home + "/.local/bin")
            try FileManager.default.createSymbolicLink(
                atPath: home + "/.local/bin/claude", withDestinationPath: versions + "/3/claude")
        }
        return (home, versions)
    }

    @Test func missingActiveLinkOffersNothing() async throws {
        let (home, _) = try versionsHome(link: false)
        let cat = try catalog("claude-code-old-versions", "cursor-agent-old-versions")
        #expect(await scanner(cat, home: home).findItems(scan: nil).isEmpty)
    }

    @Test func oldAgentVersionsKeepActiveAndPrevious() async throws {
        let (home, versions) = try versionsHome(link: true)
        let items = await scanner(try catalog("claude-code-old-versions"), home: home).findItems(scan: nil)
        #expect(items.map(\.paths) == [[versions + "/1"]])
        #expect(items.first?.risk == .safe)
        #expect(items.first?.details == ["Kept: 3, 2"])
    }

    @Test func runningOldVersionIsRefused() async throws {
        let (home, versions) = try versionsHome(link: true)
        let cat = try catalog("claude-code-old-versions")
        let item = try #require(await scanner(cat, home: home).findItems(scan: nil).first)
        let listing = FakeListing([RunningProcess(pid: 9, name: "claude", executablePath: versions + "/1/claude")])
        guard case .blocked(let reason) = await executor(cat, home: home, listing: listing).execute(item) else {
            Issue.record("should have been blocked"); return
        }
        #expect(reason == "It is in use: 1.")
        #expect(FileManager.default.fileExists(atPath: versions + "/1/claude"))
    }

    @Test func listingUnknownRefusesRetentionWithLink() async throws {
        let (home, versions) = try versionsHome(link: true)
        let cat = try catalog("claude-code-old-versions")
        let item = try #require(await scanner(cat, home: home).findItems(scan: nil).first)
        guard case .blocked(let reason) = await executor(cat, home: home, listing: FakeListing(nil)).execute(item)
        else { Issue.record("should have been blocked"); return }
        #expect(reason == "Could not check whether it is in use; Airy does not touch it.")
        #expect(FileManager.default.fileExists(atPath: versions + "/1/claude"))
    }

    // MARK: Safari

    private func safariHome() -> (home: String, db: String) {
        let home = tempDir()
        let db = home + "/Library/Safari/History.db"
        writeFile(db)
        return (home, db)
    }

    private func probe(_ db: String) -> String { "\(sqlite3) -readonly \(db) PRAGMA page_size; PRAGMA freelist_count;" }

    @Test func safariCompactionSizesFromFreelistAndNeedsSafariClosed() async throws {
        let (home, db) = safariHome()
        let cat = try catalog("safari-compact")
        let runner = FakeRunner(resolved: ["sqlite3": sqlite3], outputs: [
            probe(db): CommandOutput(status: 0, stdout: "4096\n5000\n", stderr: ""),
        ])
        let open = FakeProbes(running: ["com.apple.Safari"])
        let item = try #require(await scanner(cat, home: home, runner: runner, probes: open).findItems(scan: nil).first)
        #expect(item.bytes == 20_480_000)
        #expect(item.paths == [db] && item.targets == [db])
        #expect(item.risk == .yourCall && !item.preselected)
        #expect(!item.blockedByOpenApps.isEmpty)
        #expect(item.entry.partialCleanup)
        let before = runner.calls.count
        guard case .blocked = await executor(cat, home: home, runner: runner, probes: open).execute(item) else {
            Issue.record("with Safari open it should have been blocked"); return
        }
        #expect(runner.calls.count == before) // VACUUM did not run
    }

    @Test func safariCompactionIsOmittedWhenProbeFailsOrIsSmall() async throws {
        let (home, db) = safariHome()
        let cat = try catalog("safari-compact")
        let outputs: [(CommandOutput, String)] = [
            (CommandOutput(status: 1, stdout: "4096\n5000\n", stderr: "locked"), "falla"),
            (CommandOutput(status: 0, stdout: "4096\n", stderr: ""), "a single line"),
            (CommandOutput(status: 0, stdout: "abc\ndef\n", stderr: ""), "not numbers"),
            (CommandOutput(status: 0, stdout: "4096\n2000\n", stderr: ""), "less than 10 MB"),
        ]
        for (output, label) in outputs {
            let runner = FakeRunner(resolved: ["sqlite3": sqlite3], outputs: [probe(db): output])
            #expect(await scanner(cat, home: home, runner: runner).findItems(scan: nil).isEmpty, "\(label)")
        }
        // Without sqlite3 installed, not either.
        #expect(await scanner(cat, home: home).findItems(scan: nil).isEmpty)
    }

    @Test func safariCompactionRunsVacuumWithExactArguments() async throws {
        let (home, db) = safariHome()
        let cat = try catalog("safari-compact")
        let runner = FakeRunner(resolved: ["sqlite3": sqlite3], outputs: [
            probe(db): CommandOutput(status: 0, stdout: "4096\n5000\n", stderr: ""),
        ])
        let item = try #require(await scanner(cat, home: home, runner: runner).findItems(scan: nil).first)
        _ = await executor(cat, home: home, runner: runner).execute(item)
        let last = try #require(runner.calls.last)
        #expect(last.executable == sqlite3 && last.arguments == [db, "VACUUM;"])
    }

    // MARK: Quarantine and new entries

    @Test func quarantineIsAmberNotPreselected() throws {
        let all = try Catalog.bundled()
        let entry = try #require(all.entry(id: "quarantine-history"))
        #expect(entry.risk == .yourCall && entry.aggressiveRisk == nil && !entry.preselectInAggressive)
        #expect(entry.cleanup == .trash)
        for mode in [CleanupMode.prudent, .aggressive] {
            var settings = AirySettings()
            settings.mode = mode
            let verdict = RiskClassifier(catalog: all, settings: settings, home: "/Users/ana")
                .classify(entry: entry, paths: ["/Users/ana/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2"])
            #expect(verdict.risk == .yourCall && !verdict.preselected, "\(mode)")
            #expect(verdict.keptPaths.count == 1)
        }
    }

    @Test func newTrashEntriesAreNotHardProtected() throws {
        let all = try Catalog.bundled()
        let classifier = RiskClassifier(catalog: all, settings: AirySettings(), home: "/Users/ana")
        let samples: [String: [String]] = [
            "device-firmware": ["/Users/ana/Library/iTunes/iPhone Software Updates/x.ipsw",
                                "/Users/ana/Library/Group Containers/K36BKF7T3D.group.com.apple.configurator/Library/Caches/Firmware/x.ipsw"],
            "claude-code-old-versions": ["/Users/ana/.local/share/claude/versions/1"],
            "cursor-agent-old-versions": ["/Users/ana/.local/share/cursor-agent/versions/1"],
            "lmstudio-models": ["/Users/ana/.lmstudio/models/autor/modelo", "/Users/ana/.cache/lm-studio/models/autor/modelo"],
            "installers": ["/Users/ana/Downloads/a.dmg", "/Users/ana/Desktop/a.pkg", "/Users/ana/Documents/a.zip"],
            "old-downloads": ["/Users/ana/Downloads/viejo.bin"],
        ]
        for (id, paths) in samples {
            let entry = try #require(all.entry(id: id), "\(id)")
            let verdict = classifier.classify(entry: entry, paths: paths)
            #expect(verdict.protection == nil && verdict.keptPaths == paths && verdict.risk != .doNotTouch, "\(id)")
        }
        let versions = try #require(all.entry(id: "claude-code-old-versions"))
        #expect(versions.retention == RetentionRule(keepNewest: 2, activeLink: "~/.local/bin/claude"))
        let cursor = try #require(all.entry(id: "cursor-agent-old-versions"))
        #expect(cursor.retention == RetentionRule(keepNewest: 2, activeLink: "~/.local/bin/cursor-agent"))
        let lm = try #require(all.entry(id: "lmstudio-models"))
        #expect(lm.mustBeClosed == ["ai.elementlabs.lmstudio"] && lm.perMatch && lm.risk == .yourCall)
    }

    // MARK: Review only

    @Test func reviewOnlyEntriesHaveNoActionAndAHint() throws {
        let all = try Catalog.bundled()
        for id in reviewIDs {
            let entry = try #require(all.entry(id: id), "\(id)")
            #expect(entry.cleanup == .info && entry.risk == .yourCall, "\(id)")
            #expect(entry.aggressiveRisk == nil && !entry.preselectInAggressive, "\(id)")
            #expect(!(entry.reviewHint ?? "").isEmpty, "\(id)")
            #expect(entry.shortReason != nil, "\(id)")
            let item = CleanupItem(id: id, entry: entry, paths: [], bytes: 1, risk: .yourCall,
                                   blockedByOpenApps: [], usedBy: [])
            #expect(!CleanupBoard.showsCheckbox(item), "\(id)")
        }
        #expect(all.entry(id: "music-sound-libraries")?.profiles == [.music])
        for id in ["chrome-old-frameworks", "brave-old-frameworks", "edge-old-frameworks"] {
            let entry = try #require(all.entry(id: id))
            let link = try #require(entry.retention?.activeLink)
            #expect(entry.retention?.keepNewest == 1 && link.hasSuffix("/Versions/Current"), "\(id)")
            #expect(entry.paths.allSatisfy { $0.hasPrefix("/Applications/") && $0.hasSuffix("/Versions/*") }, "\(id)")
            #expect(entry.except == ["Current"], "\(id)")
        }
        #expect(try #require(all.entry(id: "macos-installers")).paths == ["/Applications/Install macOS*.app"])
    }

    @Test func adminAndApplicationsPathsAreNeverActionable() throws {
        let sealed = ["/Library", "/private", "/Applications", "/System", "/usr", "/bin", "/sbin", "/opt"]
        for entry in try Catalog.bundled().entries {
            if case .info = entry.cleanup { continue }
            for path in entry.paths {
                #expect(!sealed.contains { path == $0 || path.hasPrefix($0 + "/") }, "\(entry.id): \(path)")
            }
        }
    }

    @Test func neverMessagesOrMailCachesNorTheActiveCodexRuntime() throws {
        let banned = ["Library/Messages", "com.apple.mail", "Mail Downloads", "Library/Mail"]
        for entry in try Catalog.bundled().entries {
            for path in entry.paths {
                #expect(!banned.contains { path.contains($0) }, "\(entry.id): \(path)")
            }
        }
        // The Codex runtime in use only appears as an informational "Do not touch", never in another entry.
        let all = try Catalog.bundled()
        let runtime = try #require(all.entry(id: "codex-runtime"))
        #expect(runtime.cleanup == .info && runtime.risk == .doNotTouch)
        for entry in all.entries where entry.id != "codex-runtime" {
            #expect(!entry.paths.contains { $0.contains("codex-primary-runtime") }, "\(entry.id)")
        }
    }

    @Test func reviewEntriesNeverOfferTheActiveCodexRuntimeOnDisk() async throws {
        let home = tempDir()
        writeFile(home + "/.cache/codex-runtimes/codex-primary-runtime/bin/codex", bytes: 40_000)
        writeFile(home + "/.codex/worktrees/a/f", bytes: 40_000)
        // Only entries with paths inside the home folder (the absolute ones would read the real disk).
        let all = try Catalog.bundled()
        let mine = Catalog(entries: all.entries.filter { $0.paths.allSatisfy { !$0.hasPrefix("/") } })
        let items = await scanner(mine, home: home).findItems(scan: nil)
        let runtimePath = home + "/.cache/codex-runtimes/codex-primary-runtime"
        for item in items where item.id != "codex-runtime" {
            #expect(!item.paths.contains { $0 == runtimePath || $0.hasPrefix(runtimePath + "/") }, "\(item.id)")
        }
        let worktrees = try #require(items.first { $0.id == "agent-worktrees" })
        #expect(worktrees.paths == [home + "/.codex/worktrees"] && worktrees.sizeNote == nil)
    }

    @Test func unknownSizeOfReviewEntriesDoesNotBlockThem() async throws {
        let home = tempDir()
        writeFile(home + "/.android/avd/a/disco", bytes: 40_000)
        writeFile(home + "/.codex/worktrees/a/f", bytes: 40_000)
        writeFile(home + "/.cache/whisper/modelo", bytes: 40_000)
        // Time limit exhausted: the two review entries come out as "Unknown size" and unblocked; the Trash one does
        // gets blocked.
        let cat = try catalog("android-emulators", "agent-worktrees", "whisper-cache")
        let items = await scanner(cat, home: home, measureBudget: .zero).findItems(scan: nil)
        let review = items.filter { $0.id != "whisper-cache" }
        #expect(review.map(\.id) == ["android-emulators", "agent-worktrees"])
        #expect(review.allSatisfy { $0.sizeNote == "Unknown size" && $0.blockedReason == nil })
        let trash = try #require(items.first { $0.id == "whisper-cache" })
        #expect(trash.blockedReason != nil)
        // With a normal time limit they are measured.
        let measured = await scanner(cat, home: home).findItems(scan: nil)
        #expect(measured.allSatisfy { $0.sizeNote == nil && $0.bytes > 0 })
    }

    @Test func catalogOrderPutsInstallersBeforeOldDownloads() throws {
        let ids = try Catalog.bundled().entries.map(\.id)
        #expect(try #require(ids.firstIndex(of: "installers")) < #require(ids.firstIndex(of: "old-downloads")))
        let old = try #require(try Catalog.bundled().entry(id: "old-downloads"))
        #expect(old.staleAfterDays == 180 && old.minimumBytes == 50_000_000 && old.perMatch)
        #expect(old.except == [".DS_Store", ".localized"] && old.paths == ["~/Downloads/*"])
        #expect(try #require(Catalog.bundled().entry(id: "installers")).discovery == .installers)
    }
}
