import Foundation
import Synchronization
import Testing
@testable import DiskMapCore

final class FakeLookup: BundleIDLookup, Sendable {
    let answers: [String: Bool]
    let unknown: Set<String>
    private let state = Mutex<[String]>([])

    init(_ answers: [String: Bool] = [:], unknown: Set<String> = []) {
        self.answers = answers
        self.unknown = unknown
    }

    var calls: [String] { state.withLock { $0 } }

    func isInstalled(_ bundleID: String) async -> Bool? {
        state.withLock { $0.append(bundleID) }
        return unknown.contains(bundleID) ? nil : answers[bundleID] ?? false
    }
}

private func tempDir(_ label: String) -> String {
    let url = TestTemp.url("\(label)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.path
}

private func mkdir(_ path: String) {
    try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
}

private func writeFile(_ path: String) {
    mkdir((path as NSString).deletingLastPathComponent)
    FileManager.default.createFile(atPath: path, contents: Data(repeating: 0x41, count: 5_000))
}

private func exists(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0
}

private func setAge(_ path: String, days: Double) {
    try! FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-days * 86_400)],
                                           ofItemAtPath: path)
}

private func app(_ id: String, helpers: [String] = []) -> AppRecord {
    AppRecord(bundleID: id, name: "X", version: nil, path: "/Applications/X.app", helperBundleIDs: helpers,
              isSystem: false, isAppStore: false, caskToken: nil, lastUsed: nil)
}

private struct OFixture {
    let home = tempDir("airy-orphan-home")

    /// Folder `folder/name` with a file inside, everything `days` old.
    @discardableResult
    func entry(_ folder: String, _ name: String, days: Double = 60) -> String {
        let path = home + "/Library/" + folder + "/" + name
        writeFile(path + "/f")
        setAge(path + "/f", days: days)
        setAge(path, days: days)
        return path
    }

    func finder(_ lookup: FakeLookup = FakeLookup(), protected: [String] = []) -> OrphanFinder {
        let gate = PathGate(home: home, catalog: Catalog(entries: []),
                            userProtected: ProtectList(patterns: protected, home: home),
                            protections: HardProtections(criticalRoots: []))
        return OrphanFinder(home: home, gate: gate, lookup: lookup)
    }
}

private func inventory(_ apps: [AppRecord] = [], complete: Bool = true) -> AppInventorySnapshot {
    AppInventorySnapshot(apps: apps, complete: complete, problems: [])
}

private func ids(_ scan: OrphanScan) -> [String] {
    if case .found(let groups) = scan { return groups.map(\.bundleID) }
    return ["<undecided>"]
}

private struct LinkFixture {
    let dir = tempDir("airy-links")
    let store = IndexStore(directory: URL(fileURLWithPath: tempDir("airy-links-store")))
    let log = OperationLog(file: URL(fileURLWithPath: tempDir("airy-links-log")).appendingPathComponent("ops.jsonl"))

    func link(_ name: String, to target: String) {
        try! FileManager.default.createSymbolicLink(atPath: dir + "/" + name, withDestinationPath: target)
    }

    func executor(runner: FakeRunner = FakeRunner(), privileged: FakePrivileged = FakePrivileged()) -> CleanupExecutor {
        CleanupExecutor(
            runner: runner, probes: FakeProbes(), store: store, catalog: Catalog(entries: []),
            references: ReferenceChecker(roots: []), home: dir, freeSpace: { 0 }, trashSettleDelay: .zero,
            settings: { .loaded(AirySettings()) }, log: log, processGuard: ProcessGuard(),
            protections: HardProtections(criticalRoots: []), privileged: privileged, quitter: FakeQuitter(),
            appRoots: [], beforeMove: nil)
    }
}

@Suite struct OrphanTests {
    @Test func incompleteInventoryDecidesNothing() async {
        let f = OFixture()
        f.entry("Caches", "com.old.app")
        #expect(await f.finder().scan(inventory: inventory(complete: false))
                == .undecided("Could not read the full list of apps; Airy does not mark leftovers as orphaned."))
    }

    @Test func installedIDIsNotOrphan() async {
        let f = OFixture()
        f.entry("Caches", "com.foo.main")
        f.entry("Caches", "com.foo.helper")
        f.entry("Caches", "com.bar.gone")
        let scan = await f.finder().scan(inventory: inventory([app("com.foo.Main", helpers: ["com.foo.helper"])]))
        #expect(ids(scan) == ["com.bar.gone"])
    }

    @Test func recentFolderIsNotOrphan() async {
        let f = OFixture()
        f.entry("Caches", "com.a.d29", days: 29)
        f.entry("Caches", "com.a.d31", days: 31)
        let old = f.entry("Caches", "com.a.child", days: 40)
        writeFile(old + "/new")
        setAge(old, days: 40)
        #expect(ids(await f.finder().scan(inventory: inventory())) == ["com.a.d31"])
    }

    @Test func mdfindFailureMeansInstalled() async {
        let f = OFixture()
        f.entry("Caches", "com.a.b")
        let lookup = FakeLookup(unknown: ["com.a.b"])
        #expect(ids(await f.finder(lookup).scan(inventory: inventory())) == [])
        #expect(lookup.calls == ["com.a.b"])
    }

    @Test func mdfindHitMeansInstalled() async {
        let f = OFixture()
        f.entry("Caches", "com.a.b")
        #expect(ids(await f.finder(FakeLookup(["com.a.b": true])).scan(inventory: inventory())) == [])
    }

    @Test func onlyCachesLogsSavedState() async throws {
        let f = OFixture()
        for folder in ["Containers", "Group Containers", "LaunchAgents", "LaunchDaemons", "Application Scripts",
                       "Application Support"] {
            f.entry(folder, "com.only.elsewhere")
            f.entry(folder, "com.both.app")
        }
        let caches = f.entry("Caches", "com.both.app")
        guard case .found(let groups) = await f.finder().scan(inventory: inventory()) else {
            Issue.record("undecided"); return
        }
        #expect(groups.map(\.bundleID) == ["com.both.app"])
        #expect(groups.first?.paths == [caches])
    }

    @Test func sensitivePatternsNeverOrphans() async {
        let f = OFixture()
        for name in ["com.foo.ssh-agent", "org.gnupg.x", "com.1password.x", "com.foo.keychainhelper",
                     "com.bitwarden.desktop", "net.foo.GPGTools"] {
            f.entry("Caches", name)
        }
        #expect(ids(await f.finder().scan(inventory: inventory())) == [])
    }

    @Test func appleAndAiryNeverOrphans() async {
        let f = OFixture()
        f.entry("Caches", "com.apple.gone")
        f.entry("Caches", "local.airy.app")
        #expect(ids(await f.finder().scan(inventory: inventory())) == [])
    }

    @Test func userProtectedNeverOrphan() async {
        let f = OFixture()
        let path = f.entry("Caches", "com.mine.keep")
        #expect(ids(await f.finder(protected: [path]).scan(inventory: inventory())) == [])
    }

    @Test func groupsAcrossFolders() async throws {
        let f = OFixture()
        let paths = [f.entry("Caches", "com.g.app"), f.entry("Logs", "com.g.app"),
                     f.entry("Saved Application State", "com.g.app.savedState")]
        guard case .found(let groups) = await f.finder().scan(inventory: inventory()) else {
            Issue.record("undecided"); return
        }
        let group = try #require(groups.first)
        #expect(groups.count == 1 && group.bundleID == "com.g.app" && group.risk == .safe)
        #expect(Set(group.paths) == Set(paths))
        #expect(group.bytes == paths.reduce(0) { $0 + (AllocatedSize.of($1) ?? 0) })
    }

    @Test func stillOrphanRechecks() async throws {
        let f = OFixture()
        f.entry("Caches", "com.g.app")
        let finder = f.finder()
        guard case .found(let groups) = await finder.scan(inventory: inventory()), let group = groups.first else {
            Issue.record("no group"); return
        }
        #expect(await finder.stillOrphan(group, inventory: inventory()))
        #expect(!(await finder.stillOrphan(group, inventory: inventory([app("com.g.app")]))))
        #expect(!(await finder.stillOrphan(group, inventory: inventory(complete: false))))
        #expect(await finder.confirmable(groups, inventory: inventory([app("com.g.app")])) == [])
        #expect(await finder.confirmable(groups, inventory: inventory()) == groups)
    }

    @Test func bundleIDParsing() {
        #expect(OrphanFinder.bundleID(fromEntryName: "com.a.b") == "com.a.b")
        #expect(OrphanFinder.bundleID(fromEntryName: "com.a.b.savedState") == "com.a.b")
        #expect(OrphanFinder.bundleID(fromEntryName: "io.x-y.z_1") == "io.x-y.z_1")
        for bad in ["Foo", "com.a", "com.a b.c", "../x", "edu.a.b", "com..b", "com.a.b/c", "com.a.ñ"] {
            #expect(OrphanFinder.bundleID(fromEntryName: bad) == nil, "\(bad)")
        }
    }

    @Test func spotlightLookupQueryAndOutcomes() async {
        let key = "/usr/bin/mdfind kMDItemCFBundleIdentifier == \"com.a.b\""
        let hit = FakeRunner(outputs: [key: CommandOutput(status: 0, stdout: "/Apps/X.app\n", stderr: "")])
        #expect(await SpotlightLookup(runner: hit).isInstalled("com.a.b") == true)
        #expect(hit.calls == [FakeRunner.Call(executable: "/usr/bin/mdfind",
                                              arguments: ["kMDItemCFBundleIdentifier == \"com.a.b\""], timeout: 5)])
        let empty = FakeRunner(outputs: [key: CommandOutput(status: 0, stdout: "", stderr: "")])
        #expect(await SpotlightLookup(runner: empty).isInstalled("com.a.b") == false)
        let failed = FakeRunner(outputs: [key: CommandOutput(status: 1, stdout: "", stderr: "x")])
        #expect(await SpotlightLookup(runner: failed).isInstalled("com.a.b") == nil)
    }

    // MARK: - Broken links

    @Test func brokenLinkFoundLiveLinkAndFileIgnored() {
        let f = LinkFixture()
        writeFile(f.dir + "/real")
        f.link("broken", to: f.dir + "/missing")
        f.link("live", to: f.dir + "/real")
        #expect(BrokenLinks.find(in: f.dir) == [BrokenLink(path: f.dir + "/broken", target: f.dir + "/missing",
                                                           needsAdmin: false)])
    }

    @Test func deleteCommandEscapesAndOnlyTouchesBrokenSymlinks() async throws {
        let f = LinkFixture()
        writeFile(f.dir + "/real")
        writeFile(f.dir + "/d")
        f.link("a *b?[1]", to: f.dir + "/missing1")
        f.link("c", to: f.dir + "/missing2")
        f.link("a *b?[1]x", to: f.dir + "/real")
        #expect(BrokenLinks.globEscaped("a *b?[1]\\") == "a \\*b\\?\\[1\\]\\\\")
        let command = BrokenLinks.deleteCommand(directory: f.dir, names: ["a *b?[1]"])
        #expect(command == ["/usr/bin/find", f.dir, "-maxdepth", "1", "-type", "l", "(", "-name", "a \\*b\\?\\[1\\]",
                            ")", "!", "-exec", "/bin/test", "-e", "{}", ";", "-delete"])
        let output = try await ProcessRunner().run(command[0], Array(command.dropFirst()), timeout: 30)
        #expect(output.status == 0)
        #expect(!exists(f.dir + "/a *b?[1]"))
        for kept in ["c", "a *b?[1]x", "d", "real"] { #expect(exists(f.dir + "/" + kept), "\(kept)") }
    }

    @Test func agentCannotRemoveLinks() async {
        let f = LinkFixture()
        f.link("broken", to: f.dir + "/missing")
        let runner = FakeRunner(), priv = FakePrivileged()
        let outcome = await f.executor(runner: runner, privileged: priv)
            .removeBrokenLinks(BrokenLinks.find(in: f.dir), directory: f.dir, context: .agent("x"))
        guard case .blocked = outcome else { Issue.record("\(outcome)"); return }
        #expect(runner.calls.isEmpty && priv.calls.isEmpty && exists(f.dir + "/broken"))
    }

    @Test func adminLinksUsePrivilegedRunner() async throws {
        let f = LinkFixture()
        f.link("broken", to: f.dir + "/missing")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: f.dir)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.dir) }
        let links = BrokenLinks.find(in: f.dir)
        #expect(links.map(\.needsAdmin) == [true])
        let runner = FakeRunner(), priv = FakePrivileged()
        let outcome = await f.executor(runner: runner, privileged: priv)
            .removeBrokenLinks(links, directory: f.dir, context: .user())
        #expect(outcome == .freed(0))
        #expect(priv.calls == [[BrokenLinks.deleteCommand(directory: f.dir, names: ["broken"])]])
        #expect(runner.calls.isEmpty)
    }

    @Test func relinkedLinkIsNotRemoved() async throws {
        let f = LinkFixture()
        f.link("relinked", to: f.dir + "/later")
        f.link("broken", to: f.dir + "/missing")
        let links = BrokenLinks.find(in: f.dir)
        #expect(links.count == 2)
        writeFile(f.dir + "/later")
        let runner = FakeRunner()
        let outcome = await f.executor(runner: runner).removeBrokenLinks(links, directory: f.dir, context: .user())
        #expect(outcome == .freed(0))
        let command = BrokenLinks.deleteCommand(directory: f.dir, names: ["broken"])
        #expect(runner.calls.map { [$0.executable] + $0.arguments } == [command])
        let record = try #require(try f.log.records().last)
        #expect(record.action == "remove_broken_links" && record.paths == [f.dir + "/broken"])
        #expect(record.message == "\(f.dir)/broken → \(f.dir)/missing")
    }
}
