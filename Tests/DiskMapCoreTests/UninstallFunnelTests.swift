import Foundation
import Synchronization
import Testing
@testable import DiskMapCore

final class FakeQuitter: AppQuitting, Sendable {
    let running: Set<String>
    let unknown: Set<String>
    let result: QuitResult
    let onQuit: (@Sendable (String) -> Void)?
    private let state = Mutex<[String]>([])

    init(running: Set<String> = [], unknown: Set<String> = [], result: QuitResult = .quit,
         onQuit: (@Sendable (String) -> Void)? = nil) {
        self.running = running
        self.unknown = unknown
        self.result = result
        self.onQuit = onQuit
    }

    var calls: [String] { state.withLock { $0 } }

    func isRunning(bundleID: String) -> Bool? { unknown.contains(bundleID) ? nil : running.contains(bundleID) }

    func quit(bundleID: String, timeout: Duration) async -> QuitResult {
        state.withLock { $0.append(bundleID) }
        onQuit?(bundleID)
        return result
    }
}

final class FakePrivileged: PrivilegedRunning, Sendable {
    let outcome: PrivilegedOutcome
    private let state = Mutex<[[[String]]]>([])

    init(_ outcome: PrivilegedOutcome = .ok(CommandOutput(status: 0, stdout: "", stderr: ""))) {
        self.outcome = outcome
    }

    var calls: [[[String]]] { state.withLock { $0 } }

    func run(_ commands: [[String]], prompt: String) async -> PrivilegedOutcome {
        state.withLock { $0.append(commands) }
        return outcome
    }
}

private func tempDir(_ label: String) -> String {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(label)-\(UUID().uuidString)")
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

private func writeInfoPlist(_ app: String, id: String) {
    let data = try! PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id], format: .xml, options: 0)
    try! data.write(to: URL(fileURLWithPath: app + "/Contents/Info.plist"))
}

private struct UFixture {
    let tmp = tempDir("airy-uninstall")
    var apps: String { tmp + "/Applications" }
    var home: String { tmp + "/home" }
    var app: String { apps + "/Foo.app" }
    var caches: String { home + "/Library/Caches/com.example.foo" }
    var logs: String { home + "/Library/Logs/com.example.foo" }
    var agent: String { home + "/Library/LaunchAgents/com.example.foo.helper.plist" }
    let store: IndexStore
    let log: OperationLog

    init() {
        store = IndexStore(directory: URL(fileURLWithPath: tempDir("airy-uninstall-store")))
        log = OperationLog(file: URL(fileURLWithPath: tempDir("airy-uninstall-log")).appendingPathComponent("ops.jsonl"))
        mkdir(app + "/Contents/MacOS")
        writeFile(app + "/Contents/MacOS/Foo")
        writeInfoPlist(app, id: "com.example.foo")
        writeFile(caches + "/a")
        writeFile(logs + "/b")
        writeFile(agent)
        mkdir(home + "/Documents")
        writeFile(home + "/Documents/keep")
    }

    func record(cask: String? = nil) -> AppRecord {
        AppRecord(bundleID: "com.example.foo", name: "Foo", version: "1", path: app,
                  helperBundleIDs: ["com.example.foo.helper"], isSystem: false, isAppStore: false,
                  caskToken: cask, lastUsed: nil)
    }

    func leftover(_ path: String, _ kind: Leftover.Kind, risk: Risk = .safe, label: String? = nil,
                  bytes: Int64 = 5_000) -> Leftover {
        Leftover(path: path, kind: kind, bytes: bytes, risk: risk, preselected: true, matchedByName: false,
                 reason: "", launchLabel: label)
    }

    func plan(cask: String? = nil, refusal: String? = nil, extra: [Leftover] = []) -> UninstallPlan {
        UninstallPlan(app: record(cask: cask), appBytes: 5_000, leftovers: [
            leftover(caches, .caches), leftover(logs, .logs),
            leftover(agent, .launchAgent, label: "com.example.foo.helper"),
            leftover("com.example.foo.pkg", .receipt, bytes: 6_000), leftover("com.example.foo.extra", .receipt),
        ] + extra, refusal: refusal, sharedWith: nil, sizeComplete: true)
    }

    func all(_ plan: UninstallPlan) -> UninstallRequest {
        UninstallRequest(plan: plan, selected: Set(plan.leftovers.map(\.id)))
    }

    func executor(runner: FakeRunner = FakeRunner(), quitter: FakeQuitter = FakeQuitter(),
                  privileged: FakePrivileged = FakePrivileged(), protected: [String] = [],
                  beforeMove: (@Sendable (String) -> Void)? = nil) -> CleanupExecutor {
        var s = AirySettings()
        s.protectedPaths = protected
        let load = SettingsLoad.loaded(s)
        return CleanupExecutor(
            runner: runner, probes: FakeProbes(), store: store, catalog: Catalog(entries: []),
            references: ReferenceChecker(roots: []), home: home, freeSpace: { 0 }, trashSettleDelay: .zero,
            settings: { load }, log: log, processGuard: ProcessGuard(),
            protections: HardProtections(criticalRoots: [], sealedSystemLocations: [apps]),
            privileged: privileged, quitter: quitter, appRoots: [apps], beforeMove: beforeMove)
    }
}

private func isBlocked(_ outcome: CleanupOutcome) -> Bool {
    if case .blocked = outcome { return true }
    return false
}

@Suite struct UninstallFunnelTests {
    @Test func agentCannotUninstall() async {
        let f = UFixture()
        let runner = FakeRunner(), quitter = FakeQuitter(running: ["com.example.foo"]), priv = FakePrivileged()
        let report = await f.executor(runner: runner, quitter: quitter, privileged: priv)
            .uninstall(f.all(f.plan()), context: .agent("x"))
        #expect(report.outcome == .blocked(reason: CleanupExecutor.agentsCannotUninstall))
        #expect(exists(f.app) && exists(f.caches))
        #expect(runner.calls.isEmpty && quitter.calls.isEmpty && priv.calls.isEmpty)
    }

    @Test func refusedPlanDoesNothing() async {
        let f = UFixture()
        let runner = FakeRunner(), priv = FakePrivileged()
        let report = await f.executor(runner: runner, privileged: priv).uninstall(f.all(f.plan(refusal: "Es parte de macOS.")))
        #expect(report.outcome == .blocked(reason: "Es parte de macOS."))
        #expect(exists(f.app) && exists(f.caches) && runner.calls.isEmpty && priv.calls.isEmpty)
    }

    @Test func quitsBeforeTrashing() async {
        let f = UFixture()
        let quitter = FakeQuitter(running: ["com.example.foo"])
        let report = await f.executor(quitter: quitter).uninstall(f.all(f.plan()))
        guard case .movedToTrash = report.outcome else { Issue.record("\(report)"); return }
        #expect(quitter.calls == ["com.example.foo"])
        #expect(!exists(f.app) && !exists(f.caches) && !exists(f.logs))
    }

    @Test func stillRunningBlocksAndTouchesNothing() async {
        let f = UFixture()
        let runner = FakeRunner()
        let quitter = FakeQuitter(running: ["com.example.foo"], result: .stillRunning)
        let report = await f.executor(runner: runner, quitter: quitter).uninstall(f.all(f.plan()))
        #expect(report.outcome == .blocked(
            reason: "«Foo» sigue abierta (quizá te pide guardar algo). Ciérrala y vuelve a intentarlo."))
        #expect(exists(f.app) && exists(f.caches) && exists(f.agent))
        #expect(runner.calls.isEmpty)
    }

    @Test func unknownRunningStateBlocks() async {
        let f = UFixture()
        let runner = FakeRunner()
        let quitter = FakeQuitter(unknown: ["com.example.foo.helper"])
        let report = await f.executor(runner: runner, quitter: quitter).uninstall(f.all(f.plan()))
        #expect(report.outcome == .blocked(reason: "No se pudo comprobar si «Foo» está abierta; Airy no sigue."))
        #expect(exists(f.app) && runner.calls.isEmpty && quitter.calls.isEmpty)
    }

    @Test func bootsOutSelectedLaunchAgents() async {
        let f = UFixture()
        let runner = FakeRunner()
        _ = await f.executor(runner: runner).uninstall(f.all(f.plan()))
        #expect(runner.calls.map { [$0.executable] + $0.arguments }
            == [["/bin/launchctl", "bootout", "gui/\(getuid())/com.example.foo.helper"]])
        // Sin seleccionarlo, no se detiene.
        let g = UFixture()
        let other = FakeRunner()
        let plan = g.plan()
        _ = await g.executor(runner: other).uninstall(UninstallRequest(
            plan: plan, selected: Set(plan.leftovers.filter { $0.kind != .launchAgent }.map(\.id))))
        #expect(other.calls.isEmpty)
    }

    @Test func bundleChangedAfterQuitDoesNotBootOut() async {
        let f = UFixture()
        let runner = FakeRunner()
        let app = f.app
        let quitter = FakeQuitter(running: ["com.example.foo"], onQuit: { _ in
            writeInfoPlist(app, id: "com.evil.other")
        })
        let report = await f.executor(runner: runner, quitter: quitter).uninstall(f.all(f.plan()))
        #expect(isBlocked(report.outcome))
        #expect(runner.calls.isEmpty && exists(f.app) && exists(f.caches))
    }

    @Test func brewCaskRunsZapFirst() async {
        let f = UFixture()
        let runner = FakeRunner(resolved: ["brew": "/opt/homebrew/bin/brew"])
        let report = await f.executor(runner: runner).uninstall(f.all(f.plan(cask: "foo")))
        let calls = runner.calls.map { [$0.executable] + $0.arguments }
        #expect(calls.contains(["/opt/homebrew/bin/brew", "uninstall", "--cask", "--zap", "foo"]))
        #expect(calls.firstIndex { $0.first == "/opt/homebrew/bin/brew" }
                == calls.firstIndex { $0.first == "/bin/launchctl" }.map { $0 + 1 })
        // Brew falso: no borra nada, así que el `.app` va a la Papelera después.
        guard case .movedToTrash = report.outcome else { Issue.record("\(report)"); return }
        #expect(!exists(f.app))
    }

    @Test func zapSkippedWhenAnyLeftoverIsProtected() async {
        let f = UFixture()
        let runner = FakeRunner(resolved: ["brew": "/opt/homebrew/bin/brew"])
        _ = await f.executor(runner: runner, protected: [f.logs]).uninstall(f.all(f.plan(cask: "foo")))
        let calls = runner.calls.map { [$0.executable] + $0.arguments }
        #expect(calls.contains(["/opt/homebrew/bin/brew", "uninstall", "--cask", "foo"]))
        #expect(!calls.contains { $0.contains("--zap") })
        #expect(exists(f.logs))
        // Un resto sin seleccionar también evita `--zap`.
        let g = UFixture()
        let other = FakeRunner(resolved: ["brew": "/opt/homebrew/bin/brew"])
        let plan = g.plan(cask: "foo")
        _ = await g.executor(runner: other).uninstall(UninstallRequest(
            plan: plan, selected: Set(plan.leftovers.filter { $0.path != g.logs }.map(\.id))))
        #expect(!other.calls.contains { $0.arguments.contains("--zap") })
    }

    @Test func brewFailureStopsBeforeTrash() async {
        let f = UFixture()
        let runner = FakeRunner(resolved: ["brew": "/opt/homebrew/bin/brew"], outputs: [
            "/opt/homebrew/bin/brew uninstall --cask --zap foo": CommandOutput(status: 1, stdout: "", stderr: "boom"),
        ])
        let priv = FakePrivileged()
        let report = await f.executor(runner: runner, privileged: priv).uninstall(f.all(f.plan(cask: "foo")))
        #expect(report.outcome == .failed("Homebrew no pudo desinstalarla: boom"))
        #expect(report.notes.contains(CleanupExecutor.brewUnfinishedNote))
        #expect(exists(f.app) && exists(f.caches) && priv.calls.isEmpty)
    }

    @Test func onlySelectedLeftoversAreTrashed() async {
        let f = UFixture()
        let plan = f.plan()
        let selected = Set(plan.leftovers.filter { $0.path == f.caches }.map(\.id))
        let report = await f.executor().uninstall(UninstallRequest(plan: plan, selected: selected))
        guard case .movedToTrash = report.outcome else { Issue.record("\(report)"); return }
        #expect(!exists(f.app) && !exists(f.caches))
        #expect(exists(f.logs) && exists(f.agent))
    }

    @Test func leftoverSwappedForSymlinkIsRefused() async throws {
        let f = UFixture()
        let caches = f.caches, docs = f.home + "/Documents"
        let exec = f.executor(beforeMove: { path in
            guard path == caches else { return }
            try? FileManager.default.removeItem(atPath: caches)
            try? FileManager.default.createSymbolicLink(atPath: caches, withDestinationPath: docs)
        })
        let report = await exec.uninstall(f.all(f.plan()))
        #expect(report.notes.contains { $0.contains(caches) })
        #expect(exists(docs + "/keep"))
        #expect(!exists(f.app) && !exists(f.logs))
    }

    @Test func bundleReplacedAfterPlanIsRefused() async {
        let f = UFixture()
        let plan = f.plan()
        writeInfoPlist(f.app, id: "com.example.other")
        let runner = FakeRunner()
        let report = await f.executor(runner: runner).uninstall(f.all(plan))
        #expect(report.outcome == .blocked(reason: ProtectionWaiver.bundleChanged))
        #expect(exists(f.app) && exists(f.caches) && runner.calls.isEmpty)
    }

    @Test func linkedAppNeverTrashesTarget() async throws {
        let f = UFixture()
        let real = f.tmp + "/Elsewhere/Foo.app"
        mkdir(f.tmp + "/Elsewhere")
        try FileManager.default.moveItem(atPath: f.app, toPath: real)
        try FileManager.default.createSymbolicLink(atPath: f.app, withDestinationPath: real)
        _ = await f.executor().uninstall(f.all(f.plan()))
        #expect(exists(real + "/Contents/Info.plist"))
    }

    @Test func receiptsUseOnePrivilegedCallWithArgumentArrays() async {
        let f = UFixture()
        let privileged = FakePrivileged()
        _ = await f.executor(privileged: privileged).uninstall(f.all(f.plan()))
        #expect(privileged.calls == [[["/usr/sbin/pkgutil", "--forget", "com.example.foo.pkg"],
                                      ["/usr/sbin/pkgutil", "--forget", "com.example.foo.extra"]]])
    }

    @Test func cancelledPasswordKeepsRestAndNotes() async {
        let f = UFixture()
        let report = await f.executor(privileged: FakePrivileged(.cancelled)).uninstall(f.all(f.plan()))
        guard case .movedToTrash = report.outcome else { Issue.record("\(report)"); return }
        #expect(report.notes.contains(CleanupExecutor.receiptCancelledNote))
    }

    @Test func osascriptArgumentsNeverInterpolateIntoScript() {
        let hostile = "a'; rm -rf ~ #"
        let args = OsascriptPrivilegedRunner.arguments(for: [["/bin/echo", hostile]], prompt: "p")
        #expect(args.contains(hostile))
        #expect(!OsascriptPrivilegedRunner.scriptLines.joined().contains(hostile))
        #expect(OsascriptPrivilegedRunner.scriptLines.joined().contains("quoted form of"))
        #expect(Array(args.suffix(5)) == ["--", "p", "2", "/bin/echo", hostile])
    }

    @Test func privilegedRunnerRefusesOtherCommands() async {
        let runner = FakeRunner()
        let priv = OsascriptPrivilegedRunner(runner: runner)
        for commands in [[["/bin/rm", "-rf", "/"]], [["/usr/sbin/pkgutil", "--forget", "a b"]],
                         [["/usr/sbin/pkgutil", "--forget", "-x"]], [["/usr/sbin/pkgutil", "--forget", "a", "b"]],
                         [["/usr/sbin/pkgutil", "--forget", "ok.id"], ["/bin/sh", "-c", "x"]],
                         [BrokenLinks.deleteCommand(directory: "/tmp", names: ["x"])],
                         [BrokenLinks.deleteCommand(directory: "/usr/local/bin", names: ["a/b"])],
                         [BrokenLinks.deleteCommand(directory: "/usr/local/bin", names: [])], []] {
            #expect(await priv.run(commands, prompt: "p") == .failed("Orden no permitida."), "\(commands)")
        }
        #expect(runner.calls.isEmpty)
        let ok = await priv.run([["/usr/sbin/pkgutil", "--forget", "com.example.foo.pkg"],
                                 BrokenLinks.deleteCommand(directory: "/usr/local/bin", names: ["a *b?[1]"])],
                                prompt: "p")
        guard case .ok = ok else { Issue.record("\(ok)"); return }
        #expect(runner.calls.map(\.executable) == ["/usr/bin/osascript"])
    }

    @Test func uninstallIsLogged() async throws {
        let f = UFixture()
        _ = await f.executor().uninstall(f.all(f.plan()))
        let last = try #require(try f.log.records().last)
        #expect(last.action == "uninstall" && last.actor == .user && last.itemID == "com.example.foo")
        #expect(last.paths.contains(f.app) && last.outcome == "moved_to_trash")
        #expect(try f.store.history().last?.wentToTrash == true)
    }
}
