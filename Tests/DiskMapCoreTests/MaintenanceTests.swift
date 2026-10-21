import Foundation
import Synchronization
import Testing
@testable import DiskMapCore

private struct QuietListing: ProcessListing {
    func processes() -> [RunningProcess]? { [] }
    func holders(ofPathsUnder paths: [String]) -> [RunningProcess]? { [] }
}

/// Command runner with per-call delays (only to measure Spotlight).
private final class DelayRunner: CommandRunning, Sendable {
    private let delays: Mutex<[Double]>
    let status: String
    init(delays: [Double], status: String = "/:\n\tIndexing enabled.") {
        self.delays = Mutex(delays); self.status = status
    }
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> CommandOutput {
        if executable.hasSuffix("mdutil") { return CommandOutput(status: 0, stdout: status, stderr: "") }
        let delay = delays.withLock { $0.isEmpty ? 0 : $0.removeFirst() }
        if delay > timeout { throw CommandError.timedOut(executable: executable, seconds: timeout) }
        try await Task.sleep(for: .milliseconds(Int(delay * 1000)))
        return CommandOutput(status: 0, stdout: "/Applications\n", stderr: "")
    }
    func resolve(_ executable: String) async -> String? { "/usr/bin/\(executable)" }
}

private func tempHome() -> String {
    let url = TestTemp.url("airy-maint")
    try! FileManager.default.createDirectory(at: url.appendingPathComponent("Library/Preferences"),
                                             withIntermediateDirectories: true)
    return url.path
}

private let defaultsPath = "/usr/bin/defaults"

private func readKey(_ args: [String]) -> String { ([defaultsPath] + args).joined(separator: " ") }

/// `defaults read` outputs: the given keys are "1"; the rest do not exist (code 1).
private func runner(ones: [[String]] = [], zeros: [[String]] = []) -> FakeRunner {
    var outputs: [String: CommandOutput] = [:]
    for args in MaintenanceScanner.defaultsChecks.values.map(\.args) {
        outputs[readKey(args)] = CommandOutput(status: 1, stdout: "", stderr: "does not exist")
    }
    for args in ones { outputs[readKey(args)] = CommandOutput(status: 0, stdout: "1\n", stderr: "") }
    for args in zeros { outputs[readKey(args)] = CommandOutput(status: 0, stdout: "0\n", stderr: "") }
    return FakeRunner(resolved: ["defaults": defaultsPath, "osascript": "/usr/bin/osascript"], outputs: outputs)
}

private func scanner(_ runner: some CommandRunning, home: String) throws -> MaintenanceScanner {
    MaintenanceScanner(catalog: try Catalog.bundled(), runner: runner, home: home, classifier: nil)
}

private func executor(_ runner: FakeRunner, home: String, log: OperationLog? = nil) throws -> CleanupExecutor {
    CleanupExecutor(
        runner: runner, probes: FakeProbes(),
        store: IndexStore(directory: URL(fileURLWithPath: tempHome())),
        catalog: try Catalog.bundled(), references: ReferenceChecker(roots: []), home: home,
        freeSpace: { 0 }, settings: { .missing }, log: log,
        processGuard: ProcessGuard(listing: QuietListing()), processListing: QuietListing())
}

private let network = ["read", "com.apple.desktopservices", "DSDontWriteNetworkStores"]
private let usb = ["read", "com.apple.desktopservices", "DSDontWriteUSBStores"]
private let appNap = ["read", "-g", "NSAppSleepDisabled"]
private let skipVerify = ["read", "com.apple.frameworks.diskimages", "skip-verify"]

@Suite struct MaintenanceTests {
    @Test func maintenanceEntriesAreAmberAndNeverPreselected() throws {
        let catalog = try Catalog.bundled()
        let maintenance = catalog.entries.filter { $0.section == .maintenance }
        #expect(maintenance.count == 8)
        for entry in maintenance {
            #expect(entry.id.hasPrefix("maintenance-"))
            #expect(entry.risk == .yourCall && entry.aggressiveRisk == nil && !entry.preselectInAggressive)
            #expect(!entry.regenerates && entry.kind == .system && entry.shortReason != nil)
        }
        let spotlight = try #require(catalog.entry(id: "maintenance-spotlight-reindex"))
        #expect(spotlight.cleanup == .command(executable: "osascript", arguments: [
            "-e", "do shell script \"/usr/bin/mdutil -E /\" with administrator privileges"], sizeProbe: nil))
        #expect(catalog.entries.filter { $0.section != .maintenance }.allSatisfy { !$0.id.hasPrefix("maintenance-") })
    }

    @Test func cleanupScannerIgnoresMaintenance() async throws {
        let home = tempHome()
        FileManager.default.createFile(atPath: home + "/Library/Preferences/bad.plist", contents: Data("zz".utf8))
        let catalog = try Catalog.bundled()
        let items = await CleanupScanner(
            catalog: catalog, runner: runner(), probes: FakeProbes(), references: ReferenceChecker(roots: []),
            home: home, processListing: QuietListing()).findItems(scan: nil)
        #expect(!items.contains { $0.id.hasPrefix("maintenance-") })
    }

    @Test func catalogMatchIgnoresMaintenance() throws {
        let catalog = try Catalog.bundled()
        let match = catalog.match(path: "/Users/x/Library/Preferences/x.plist", home: "/Users/x")
        #expect(match?.id != "maintenance-corrupt-plist")
    }

    @Test func dsStoreOfferedOnlyWhenNotSet() async throws {
        let home = tempHome()
        let set = try await scanner(runner(ones: [network]), home: home).findItems(spotlight: nil, onACPower: true)
        #expect(!set.contains { $0.id == "maintenance-dsstore-network" })
        #expect(set.contains { $0.id == "maintenance-dsstore-usb" })
        let item = try #require(set.first { $0.id == "maintenance-dsstore-usb" })
        #expect(item.risk == .yourCall && !item.preselected)
    }

    @Test func legacyDefaultsOfferedOnlyWhenHarmful() async throws {
        let home = tempHome()
        let items = try await scanner(runner(ones: [appNap], zeros: [skipVerify]), home: home)
            .findItems(spotlight: nil, onACPower: true)
        let ids = Set(items.map(\.id))
        #expect(ids.contains("maintenance-legacy-appnap"))
        #expect(!ids.contains("maintenance-legacy-skipverify"))          // "0"
        #expect(!ids.contains("maintenance-legacy-skipverify-locked"))   // missing
    }

    @Test func corruptPlistDetectedButAppleAndValidSkipped() async throws {
        let home = tempHome()
        let prefs = home + "/Library/Preferences/"
        FileManager.default.createFile(atPath: prefs + "bad.plist", contents: Data("not a plist".utf8))
        FileManager.default.createFile(atPath: prefs + "com.apple.bad.plist", contents: Data("basura".utf8))
        let ok = try PropertyListSerialization.data(fromPropertyList: ["a": 1], format: .xml, options: 0)
        FileManager.default.createFile(atPath: prefs + "ok.plist", contents: ok)
        let items = try await scanner(runner(), home: home).findItems(spotlight: nil, onACPower: true)
            .filter { $0.entry.id == "maintenance-corrupt-plist" }
        #expect(items.map(\.id) == ["maintenance-corrupt-plist:bad.plist"])
        #expect(items.first?.paths == [prefs + "bad.plist"] && items.first?.risk == .yourCall)
    }

    @Test func spotlightOnlyAfterSlowDiagnosisOnAC() async throws {
        let s = try scanner(runner(), home: tempHome())
        let id = "maintenance-spotlight-reindex"
        #expect(!(await s.findItems(spotlight: nil, onACPower: true)).contains { $0.id == id })
        #expect(!(await s.findItems(spotlight: .fine(seconds: 0.2), onACPower: true)).contains { $0.id == id })
        #expect(!(await s.findItems(spotlight: .slow(seconds: 5), onACPower: false)).contains { $0.id == id })
        #expect((await s.findItems(spotlight: .slow(seconds: 5), onACPower: true)).contains { $0.id == id })
    }

    @Test func spotlightCheckTiming() async {
        // Scaled down: threshold 0.03 s (≈ 3 s), delays 0.035 and 0.04 (≈ 3.5 and 4 s).
        let slow = await SpotlightCheck(runner: DelayRunner(delays: [0.035, 0.04]), threshold: 0.03, queryTimeout: 1).run()
        guard case .slow(let seconds) = slow else { Issue.record("expected .slow: \(slow)"); return }
        #expect(seconds >= 0.04)
        let fine = await SpotlightCheck(runner: DelayRunner(delays: [0.001, 0.001]), threshold: 0.03, queryTimeout: 1).run()
        guard case .fine = fine else { Issue.record("expected .fine: \(fine)"); return }
        let timedOut = await SpotlightCheck(runner: DelayRunner(delays: [5, 5]), threshold: 0.03, queryTimeout: 0.5).run()
        #expect(timedOut == .slow(seconds: 0.5))
        let disabled = await SpotlightCheck(runner: DelayRunner(delays: [], status: "/:\n\tIndexing disabled.")).run()
        #expect(disabled == .disabled)
        #expect(SpotlightCheck.slowSeconds == 3)
    }

    @Test func scannerOnlyReads() async throws {
        let r = runner(ones: [appNap])
        _ = try await scanner(r, home: tempHome()).findItems(spotlight: .slow(seconds: 9), onACPower: true)
        #expect(!r.calls.isEmpty)
        for call in r.calls {
            #expect(call.executable == defaultsPath && call.arguments.first == "read", "\(call)")
        }
    }

    @Test func maintenanceExecutesThroughFunnel() async throws {
        let home = tempHome()
        let r = runner()
        let log = OperationLog(file: URL(fileURLWithPath: tempHome()).appendingPathComponent("ops.jsonl"))
        let exec = try executor(r, home: home, log: log)
        let items = try await scanner(r, home: home).findItems(spotlight: nil, onACPower: true)
        let dsstore = try #require(items.first { $0.id == "maintenance-dsstore-network" })
        let before = r.calls.count
        let preview = await exec.preview(dsstore, logged: false)
        #expect(r.calls.count == before)
        #expect(preview == .wouldRun(command: ["defaults", "write", "com.apple.desktopservices",
                                               "DSDontWriteNetworkStores", "-bool", "true"], bytes: 0, upperBound: false))
        let outcome = await exec.execute(dsstore)
        #expect(outcome == .freed(0))
        #expect(r.calls.last == FakeRunner.Call(
            executable: defaultsPath, arguments: ["write", "com.apple.desktopservices", "DSDontWriteNetworkStores",
                                                  "-bool", "true"],
            timeout: CleanupExecutor.defaultCommandTimeout, workingDirectory: CleanupExecutor.commandWorkingDirectory))
        #expect(try log.records().contains { $0.itemID == "maintenance-dsstore-network" && $0.action == "clean" })

        // Damaged preference: to the Trash through the funnel; if it gets fixed before confirming, it is not touched.
        let path = home + "/Library/Preferences/bad.plist"
        FileManager.default.createFile(atPath: path, contents: Data("<plist><dict><key>".utf8))
        let plist = try #require(try await scanner(r, home: home).findItems(spotlight: nil, onACPower: true)
            .first { $0.id == "maintenance-corrupt-plist:bad.plist" })
        let ok = try PropertyListSerialization.data(fromPropertyList: ["a": 1], format: .xml, options: 0)
        FileManager.default.createFile(atPath: path, contents: ok)
        #expect(await exec.execute(plist) == .blocked(reason: "It is no longer damaged."))
        #expect(FileManager.default.fileExists(atPath: path))
        FileManager.default.createFile(atPath: path, contents: Data("<plist><dict><key>".utf8))
        guard case .movedToTrash = await exec.execute(plist) else { Issue.record("it did not go to the Trash"); return }
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func agentCannotRunMaintenance() async throws {
        let home = tempHome()
        let r = runner()
        let items = try await scanner(r, home: home).findItems(spotlight: .slow(seconds: 9), onACPower: true)
        let before = r.calls.count
        let exec = try executor(r, home: home)
        for item in items {
            guard case .blocked = await exec.execute(item, context: .agent("test")) else {
                Issue.record("\(item.id) was not blocked"); continue
            }
        }
        #expect(items.contains { $0.id == "maintenance-spotlight-reindex" })
        #expect(r.calls.count == before)
    }
}
