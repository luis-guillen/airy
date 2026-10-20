import Foundation
import Synchronization
import Testing
@testable import DiskMapCore

private struct FakeListing: ProcessListing {
    var list: [RunningProcess]?
    var held: [RunningProcess]? = []
    var delay: TimeInterval = 0
    var calls: CallCounter = CallCounter()

    func processes() -> [RunningProcess]? {
        calls.bump()
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        return list
    }

    func holders(ofPathsUnder paths: [String]) -> [RunningProcess]? { held }
}

private final class CallCounter: Sendable {
    private let value = Mutex(0)
    func bump() { value.withLock { $0 += 1 } }
    var count: Int { value.withLock { $0 } }
}

private func process(_ name: String, path: String? = nil, pid: Int32 = 100) -> RunningProcess {
    RunningProcess(pid: pid, name: name, executablePath: path)
}

private func tempDir() -> String {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("airy-guard-\(UUID().uuidString)").path
    try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}

@Suite struct ProcessGuardTests {
    @Test func stoppedWhenNoProcessMatches() async {
        let guardian = ProcessGuard(listing: FakeListing(list: [process("Safari"), process("zsh")]))
        #expect(await guardian.check(processNames: ["pnpm"], paths: [], checkOpenFiles: false) == .stopped)
    }

    @Test func runningWhenNameMatchesCaseInsensitive() async {
        let guardian = ProcessGuard(listing: FakeListing(list: [process("PNPM")]))
        #expect(await guardian.check(processNames: ["pnpm"], paths: [], checkOpenFiles: false) == .running("PNPM"))
        let byPath = ProcessGuard(listing: FakeListing(list: [process("node", path: "/usr/local/bin/Pnpm")]))
        #expect(await byPath.check(processNames: ["pnpm"], paths: [], checkOpenFiles: false) == .running("node"))
    }

    @Test func unknownWhenListingFails() async {
        let guardian = ProcessGuard(listing: FakeListing(list: nil))
        let state = await guardian.check(processNames: ["pnpm"], paths: [], checkOpenFiles: false)
        guard case .unknown = state else { Issue.record("esperaba .unknown, fue \(state)"); return }
        #expect(state.blockedReason == "No se pudo comprobar si está en uso; Airy no lo toca.")
    }

    @Test func unknownWhenListingIsTooSlow() async {
        let guardian = ProcessGuard(listing: FakeListing(list: [], delay: 5), budget: .milliseconds(200))
        let start = ContinuousClock.now
        let state = await guardian.check(processNames: ["pnpm"], paths: [], checkOpenFiles: false)
        guard case .unknown = state else { Issue.record("esperaba .unknown, fue \(state)"); return }
        #expect(ContinuousClock.now - start < .seconds(1))
    }

    @Test func runningWhenAnotherProcessHoldsAFile() async {
        let guardian = ProcessGuard(listing: FakeListing(list: [], held: [process("Brave Helper")]))
        let state = await guardian.check(processNames: [], paths: ["/x"], checkOpenFiles: true)
        #expect(state == .running("Brave Helper"))
        #expect(state.blockedReason == "Está en marcha: Brave Helper. Ciérralo antes de limpiar.")
    }

    @Test func unknownWhenHoldersUnknown() async {
        let guardian = ProcessGuard(listing: FakeListing(list: [], held: nil))
        let state = await guardian.check(processNames: [], paths: ["/x"], checkOpenFiles: true)
        guard case .unknown = state else { Issue.record("esperaba .unknown, fue \(state)"); return }
    }

    @Test func timeBudgetReturnsNilOnTimeout() async {
        let start = ContinuousClock.now
        let result = await TimeBudget.run(.milliseconds(100)) { () -> Int in
            usleep(3_000_000) // llamada bloqueante que no coopera con la cancelación
            return 1
        }
        #expect(result == nil)
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(await TimeBudget.run(.seconds(2)) { 7 } == 7)
    }

    @Test func libprocListsProcessesAndExcludesSelf() {
        let listed = LibprocListing().processes()
        #expect(listed != nil)
        #expect(listed?.isEmpty == false)
        #expect(listed?.contains { $0.pid == ProcessInfo.processInfo.processIdentifier } == false)
    }

    @Test func incompleteReferenceCheckBlocksItem() async {
        let home = tempDir()
        let root = home + "/Projects"
        try! FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: root + "/a.txt", contents: Data("org/modelo".utf8))
        let cache = home + "/.cache/hf/models--org--modelo"
        try! FileManager.default.createDirectory(atPath: cache, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: cache + "/w.bin", contents: Data(repeating: 1, count: 10_000))

        let checker = ReferenceChecker(roots: [root])
        let direct = await checker.referencesChecked(toAny: ["org/modelo"], timeout: 0)
        #expect(direct.complete == false)
        let full = await checker.referencesChecked(toAny: ["org/modelo"], timeout: 10)
        #expect(full.complete && full.found["org/modelo"] == [root + "/a.txt"])

        let entry = CatalogEntry(
            id: "hf", title: "HF", explanation: "", whoCreatesIt: "", regenerates: true, risk: .safe,
            kind: .caches, paths: ["~/.cache/hf/models--*"], cleanup: .trash, referenceCheck: "{name}")
        func scan(timeout: TimeInterval) async -> CleanupItem? {
            await CleanupScanner(
                catalog: Catalog(entries: [entry]), runner: FakeRunner(), probes: FakeProbes(),
                references: checker, home: home, processListing: FakeListing(list: []),
                referenceTimeout: timeout).findItems(scan: nil).first
        }
        let incomplete = await scan(timeout: 0)
        #expect(incomplete?.blockedReason == "No se pudo comprobar a tiempo si lo usa algún proyecto.")
        #expect(incomplete.map(CleanupBoard.canSelect) == false)
    }

    @Test func scannerListsProcessesOncePerPassAndFailsClosed() async {
        let home = tempDir()
        for name in ["a", "b"] {
            try! FileManager.default.createDirectory(atPath: home + "/.cache/\(name)", withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: home + "/.cache/\(name)/f", contents: Data(repeating: 1, count: 10_000))
        }
        func entry(_ id: String, names: [String]) -> CatalogEntry {
            CatalogEntry(
                id: id, title: id, explanation: "", whoCreatesIt: "", regenerates: true, risk: .safe,
                kind: .caches, paths: ["~/.cache/\(id)"], cleanup: .trash, processNames: names)
        }
        let catalog = Catalog(entries: [entry("a", names: ["pnpm"]), entry("b", names: ["uv"])])
        func run(_ listing: FakeListing) async -> [CleanupItem] {
            await CleanupScanner(
                catalog: catalog, runner: FakeRunner(), probes: FakeProbes(),
                references: ReferenceChecker(roots: []), home: home, processListing: listing).findItems(scan: nil)
        }
        let counter = CallCounter()
        let running = await run(FakeListing(list: [process("pnpm")], calls: counter))
        #expect(counter.count == 1)
        #expect(running.first { $0.id == "a" }?.blockedReason == "Está en marcha: pnpm. Ciérralo antes de limpiar.")
        #expect(running.first { $0.id == "b" }?.blockedReason == nil)
        let unknown = await run(FakeListing(list: nil))
        #expect(unknown.allSatisfy { $0.blockedReason != nil })
    }
}

@Suite struct RunningAppsTests {
    private func fakeApp(_ name: String, id: String) throws -> String {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("airy-apps-\(UUID().uuidString)")
        let contents = root.appendingPathComponent("\(name).app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id], format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        return contents.appendingPathComponent("MacOS/\(name)").path
    }

    @Test func bundleIDsComeFromTheFreshProcessListing() throws {
        let safari = try fakeApp("Safari", id: "com.apple.Safari")
        let helper = try fakeApp("Brave Browser Helper", id: "com.brave.Browser.helper")
        let listing = FakeListing(list: [process("Safari", path: safari), process("Brave Browser Helper", path: helper),
                                         process("zsh", path: "/bin/zsh"), process("raro", path: nil)])
        #expect(RunningApps.bundleIDs(listing: listing) == ["com.apple.Safari", "com.brave.Browser.helper"])
        #expect(RunningApps.appBundle(ofExecutable: "/A/X.app/Contents/Frameworks/H.app/Contents/MacOS/H") == "/A/X.app/Contents/Frameworks/H.app")
        #expect(RunningApps.appBundle(ofExecutable: "/usr/bin/true") == nil)
    }

    @Test func probesFailClosedWhenTheListingCannotBeRead() throws {
        #expect(RunningApps.bundleIDs(listing: FakeListing(list: nil)) == nil)
        let probes = SystemProbes(home: NSHomeDirectory(), runner: FakeRunner(), allowFinderFallback: false,
                                  processListing: FakeListing(list: nil))
        #expect(probes.currentRunningBundleIDs() == nil)
        // Lo que ve el listado al momento cuenta aunque NSWorkspace aún no lo sepa.
        let safari = try fakeApp("Safari", id: "local.airy.test.safari")
        let fresh = SystemProbes(home: NSHomeDirectory(), runner: FakeRunner(), allowFinderFallback: false,
                                 processListing: FakeListing(list: [process("Safari", path: safari)]))
        #expect(fresh.currentRunningBundleIDs()?.contains("local.airy.test.safari") == true)
    }
}
