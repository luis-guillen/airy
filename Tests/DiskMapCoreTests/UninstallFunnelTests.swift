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

private let brewInfo = ["/opt/homebrew/bin/brew", "info", "--cask", "--json=v2", "foo"]
private let brewUninstall = ["/opt/homebrew/bin/brew", "uninstall", "--cask", "foo"]

/// Output of `brew info --cask --json=v2 foo` with these `uninstall` steps (and `zap`, which never runs).
private func caskJSON(uninstall: [String: Any], zap: [String: Any]? = nil, extra: [[String: Any]] = []) -> String {
    var artifacts: [[String: Any]] = [["uninstall": [uninstall]], ["app": ["Foo.app"]]]
    if let zap { artifacts.append(["zap": [zap]]) }
    artifacts += extra
    let root: [String: Any] = ["formulae": [], "casks": [["token": "foo", "full_token": "foo", "artifacts": artifacts]]]
    let data = try! JSONSerialization.data(withJSONObject: root)
    return String(data: data, encoding: .utf8)!
}

private func brewRunner(info: String) -> FakeRunner {
    FakeRunner(resolved: ["brew": "/opt/homebrew/bin/brew"],
               outputs: [brewInfo.joined(separator: " "): CommandOutput(status: 0, stdout: info, stderr: "")])
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
        let report = await f.executor(runner: runner, privileged: priv).uninstall(f.all(f.plan(refusal: "It is part of macOS.")))
        #expect(report.outcome == .blocked(reason: "It is part of macOS."))
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
            reason: "“Foo” is still open (maybe it is asking you to save something). Quit it and try again."))
        #expect(exists(f.app) && exists(f.caches) && exists(f.agent))
        #expect(runner.calls.isEmpty)
    }

    @Test func unknownRunningStateBlocks() async {
        let f = UFixture()
        let runner = FakeRunner()
        let quitter = FakeQuitter(unknown: ["com.example.foo.helper"])
        let report = await f.executor(runner: runner, quitter: quitter).uninstall(f.all(f.plan()))
        #expect(report.outcome == .blocked(reason: "Could not check whether “Foo” is open; Airy does not go on."))
        #expect(exists(f.app) && runner.calls.isEmpty && quitter.calls.isEmpty)
    }

    @Test func bootsOutSelectedLaunchAgents() async {
        let f = UFixture()
        let runner = FakeRunner()
        _ = await f.executor(runner: runner).uninstall(f.all(f.plan()))
        #expect(runner.calls.map { [$0.executable] + $0.arguments }
            == [["/bin/launchctl", "bootout", "gui/\(getuid())/com.example.foo.helper"]])
        // Without selecting it, it is not stopped.
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

    // MARK: Homebrew (never `--zap`; before it, the cask review)

    @Test func cleanCaskUsesBrewWithoutZapThenBootsOut() async {
        let f = UFixture()
        let runner = brewRunner(info: caskJSON(uninstall: ["quit": "com.example.foo", "delete": f.app]))
        let report = await f.executor(runner: runner).uninstall(f.all(f.plan(cask: "foo")))
        let calls = runner.calls.map { [$0.executable] + $0.arguments }
        #expect(calls.contains(brewInfo))
        #expect(calls.contains(brewUninstall))
        #expect(!calls.contains { $0.contains("--zap") })
        // Homebrew first; the login agents only after Homebrew finishes well.
        #expect(calls.firstIndex { $0.first == "/bin/launchctl" }
                == calls.firstIndex(of: brewUninstall).map { $0 + 1 })
        // Fake brew: it deletes nothing, so the `.app` goes to the Trash afterwards.
        guard case .movedToTrash = report.outcome else { Issue.record("\(report)"); return }
        #expect(!exists(f.app))
    }

    @Test func chromeLikeCaskNeverRunsBrewNorZap() async {
        let f = UFixture()
        let profile = f.home + "/Library/Application Support/Google/Chrome"
        writeFile(profile + "/Default/Bookmarks")
        let runner = brewRunner(info: caskJSON(
            uninstall: ["quit": "com.example.foo", "delete": ["~/Library/Application Support/Google/Chrome", f.app]],
            zap: ["trash": ["~/Library/Application Support/Google/Chrome", "~/Library/Google"]]))
        let report = await f.executor(runner: runner).uninstall(f.all(f.plan(cask: "foo")))
        let calls = runner.calls.map { [$0.executable] + $0.arguments }
        #expect(!calls.contains(brewUninstall))
        #expect(!calls.contains { $0.contains("--zap") })
        #expect(report.notes.contains(CaskReview.unsafeReason))
        guard case .movedToTrash = report.outcome else { Issue.record("\(report)"); return }
        // Normal path: the `.app` to the Trash, the profile intact.
        #expect(!exists(f.app) && exists(profile + "/Default/Bookmarks"))
        let last = try? f.log.records().last
        #expect(last?.command == nil)
    }

    @Test func zapOnlyListIsNeverRun() async {
        let f = UFixture()
        let profile = f.home + "/Library/Application Support/Google/Chrome"
        writeFile(profile + "/Default/Bookmarks")
        let runner = brewRunner(info: caskJSON(uninstall: ["quit": "com.example.foo"],
                                               zap: ["trash": ["~/Library/Application Support/Google/Chrome"]]))
        _ = await f.executor(runner: runner).uninstall(f.all(f.plan(cask: "foo")))
        let calls = runner.calls.map { [$0.executable] + $0.arguments }
        #expect(calls.contains(brewUninstall))
        #expect(!calls.contains { $0.contains("--zap") })
        #expect(exists(profile + "/Default/Bookmarks"))
    }

    @Test func signalScriptOrForeignIDsFallBack() async {
        let cases: [[String: Any]] = [
            ["signal": [["TERM", "com.example.foo"]]],
            ["script": ["executable": "uninstall.sh"]],
            ["early_script": "x.sh"],
            ["pkgutil": "com.other.pkg"],
            ["launchctl": ["com.example.foo.helper", "com.google.keystone.agent"]],
            ["kext": "com.other.driver"],
            ["quit": "com.other.app"],
            ["rmdir": "~/Library/Application Support"],
            ["trash": "~/Documents"],
            ["delete": "~/Library/Application Support/Goo*/Chrome"],
        ]
        for directives in cases {
            let f = UFixture()
            writeFile(f.home + "/Library/Application Support/Google/Chrome/Default/Bookmarks")
            let runner = brewRunner(info: caskJSON(uninstall: directives))
            let report = await f.executor(runner: runner).uninstall(f.all(f.plan(cask: "foo")))
            let calls = runner.calls.map { [$0.executable] + $0.arguments }
            #expect(!calls.contains(brewUninstall), "\(directives)")
            #expect(report.notes.contains(CaskReview.unsafeReason), "\(directives)")
            #expect(!exists(f.app), "\(directives)")
        }
    }

    @Test func otherArtifactsFallBack() async {
        for extra in [["suite": ["Foo Suite"]], ["app": ["Foo.app", "Other.app"]],
                      ["uninstall_postflight": NSNull()], ["artifact": [["x", ["target": "~/Library/x"]]]]] as [[String: Any]] {
            let f = UFixture()
            let runner = brewRunner(info: caskJSON(uninstall: ["quit": "com.example.foo"], extra: [extra]))
            _ = await f.executor(runner: runner).uninstall(f.all(f.plan(cask: "foo")))
            #expect(!runner.calls.map { [$0.executable] + $0.arguments }.contains(brewUninstall), "\(extra)")
        }
    }

    @Test func unreadableMetadataFallsBack() async {
        let outputs: [CommandOutput] = [
            CommandOutput(status: 1, stdout: "", stderr: "Error: Cask 'foo' is unavailable"),
            CommandOutput(status: 0, stdout: "not json", stderr: ""),
            CommandOutput(status: 0, stdout: #"{"formulae":[],"casks":[]}"#, stderr: ""),
            CommandOutput(status: 0, stdout: #"{"casks":[{"token":"bar","artifacts":[]}]}"#, stderr: ""),
            CommandOutput(status: 0, stdout: #"{"casks":[{"token":"foo","artifacts":[{"uninstall":"x"}]}]}"#, stderr: ""),
        ]
        for output in outputs {
            let f = UFixture()
            let runner = FakeRunner(resolved: ["brew": "/opt/homebrew/bin/brew"], outputs: [brewInfo.joined(separator: " "): output])
            let report = await f.executor(runner: runner).uninstall(f.all(f.plan(cask: "foo")))
            let calls = runner.calls.map { [$0.executable] + $0.arguments }
            #expect(!calls.contains(brewUninstall), "\(output)")
            #expect(report.notes.contains(CaskReview.unreadableReason), "\(output)")
            guard case .movedToTrash = report.outcome else { Issue.record("\(report)"); continue }
            #expect(!exists(f.app))
        }
        // Odd token: Homebrew is not even queried.
        let g = UFixture()
        let runner = FakeRunner(resolved: ["brew": "/opt/homebrew/bin/brew"])
        _ = await g.executor(runner: runner).uninstall(g.all(g.plan(cask: "--force")))
        #expect(!runner.calls.contains { $0.executable.hasSuffix("brew") })
    }

    @Test func brewMissingFallsBackToTrash() async {
        let f = UFixture()
        let report = await f.executor(runner: FakeRunner()).uninstall(f.all(f.plan(cask: "foo")))
        #expect(report.notes.contains(CaskReview.brewMissingReason))
        guard case .movedToTrash = report.outcome else { Issue.record("\(report)"); return }
        #expect(!exists(f.app))
    }

    /// With the standard hard list (without the test roots): system paths or other apps' data ⇒ fallback.
    @Test func standardProtectionsRejectSystemAndSharedPaths() {
        let home = NSHomeDirectory()
        let gate = PathGate(home: home, catalog: nil, userProtected: ProtectList(patterns: [], home: home))
        let app = AppRecord(bundleID: "com.example.foo", name: "Foo", version: "1", path: "/Applications/Foo.app",
                            helperBundleIDs: [], isSystem: false, isAppStore: false, caskToken: "foo", lastUsed: nil)
        func verdict(_ directives: [String: Any]) -> CaskVerdict {
            CaskReview.verdict(json: caskJSON(uninstall: directives), token: "foo", app: app, home: home,
                               refusal: { gate.refusalWithoutWaiver($0) })
        }
        #expect(verdict(["quit": "com.example.foo", "delete": "/Applications/Foo.app"]) == .useBrew)
        for path in ["/Library/PrivilegedHelperTools/com.example.foo.helper", "~/Library/Application Support/Google/Chrome",
                     "~/Library/Application Support/Firefox/Profiles", "/Applications/Other.app", "~/Library/Keychains",
                     "~/Library/Group Containers/*", "relative/path", "~/Library/../Documents"] {
            #expect(verdict(["delete": path]) == .fallback(reason: CaskReview.unsafeReason), "\(path)")
            #expect(verdict(["trash": [path]]) == .fallback(reason: CaskReview.unsafeReason), "\(path)")
        }
    }

    @Test func commandPolicyRefusesZap() {
        #expect(CommandPolicy.refusal(executable: "/opt/homebrew/bin/brew",
                                      arguments: ["uninstall", "--cask", "--zap", "foo"]) == CommandPolicy.brewZapReason)
        #expect(CommandPolicy.refusal(executable: "/opt/homebrew/bin/brew",
                                      arguments: ["uninstall", "--zap=true", "foo"]) == CommandPolicy.brewZapReason)
        #expect(CommandPolicy.refusal(executable: "/opt/homebrew/bin/brew", arguments: brewUninstall.dropFirst().map { $0 }) == nil)
    }

    @Test func brewFailureStopsBeforeTrashAndBootout() async {
        let f = UFixture()
        let runner = FakeRunner(resolved: ["brew": "/opt/homebrew/bin/brew"], outputs: [
            brewInfo.joined(separator: " "): CommandOutput(status: 0, stdout: caskJSON(uninstall: ["quit": "com.example.foo"]), stderr: ""),
            brewUninstall.joined(separator: " "): CommandOutput(status: 1, stdout: "", stderr: "boom"),
        ])
        let priv = FakePrivileged()
        let report = await f.executor(runner: runner, privileged: priv).uninstall(f.all(f.plan(cask: "foo")))
        #expect(report.outcome == .failed("Homebrew could not uninstall it: boom"))
        #expect(report.notes.contains(CleanupExecutor.brewUnfinishedNote))
        #expect(exists(f.app) && exists(f.caches) && priv.calls.isEmpty)
        #expect(!runner.calls.contains { $0.executable == "/bin/launchctl" })
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
            #expect(await priv.run(commands, prompt: "p") == .failed("Command not allowed."), "\(commands)")
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
