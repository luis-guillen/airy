import Foundation
import Synchronization
import Testing
@testable import DiskMapCore

/// Fake terminator: it never touches a real process. It records every request and decides whether the "process" dies.
private final class FakeTerminator: ProcessTerminating {
    enum Call: Equatable, Sendable {
        case request(Int32, isApp: Bool)
        case force(Int32, isApp: Bool)
    }

    private let state: Mutex<(calls: [Call], alive: Bool)>
    private let diesOnRequest: Bool
    private let forceSucceeds: Bool
    private let diesOnForce: Bool

    init(diesOnRequest: Bool = true, forceSucceeds: Bool = true, diesOnForce: Bool = true) {
        self.diesOnRequest = diesOnRequest
        self.forceSucceeds = forceSucceeds
        self.diesOnForce = diesOnForce
        state = Mutex((calls: [], alive: true))
    }

    var calls: [Call] { state.withLock { $0.calls } }

    func requestQuit(pid: Int32, isApp: Bool) -> Bool {
        state.withLock { s in
            s.calls.append(.request(pid, isApp: isApp))
            if diesOnRequest { s.alive = false }
        }
        return true
    }

    func forceQuit(pid: Int32, isApp: Bool) -> Bool {
        state.withLock { s in
            s.calls.append(.force(pid, isApp: isApp))
            if forceSucceeds && diesOnForce { s.alive = false }
        }
        return forceSucceeds
    }

    func isAlive(pid: Int32, startedAt: Date) -> Bool { state.withLock { $0.alive } }
}

@Suite struct QuitExecutorTests {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let policy = QuitPolicy(currentUID: 501, ownPIDs: [4242])

    func group(id: String = "com.ejemplo.editor", name: String = "Editor", bundle: String? = "com.ejemplo.editor",
               kind: AppGroupKind = .app, pid: Int32 = 10, start: Date? = nil) -> AppGroup {
        AppGroup(id: id, name: name, bundleID: bundle,
                 bundlePath: bundle == nil ? nil : "/Applications/\(name).app", kind: kind, uid: 501,
                 leadPID: pid, leadStart: start ?? self.start, pids: [pid, pid + 1],
                 processNames: [name], memory: 123_456)
    }

    func tempLog() -> OperationLog {
        OperationLog(file: FileManager.default.temporaryDirectory
            .appendingPathComponent("airy-quit-\(UUID().uuidString)/operations.jsonl"))
    }

    fileprivate func executor(_ terminator: FakeTerminator, groups: [AppGroup], log: OperationLog? = nil) -> QuitExecutor {
        QuitExecutor(terminator: terminator, policy: policy, currentGroups: { groups }, log: log,
                     wait: .milliseconds(300), poll: .milliseconds(20))
    }

    @Test func agentContextNeverQuits() async throws {
        let fake = FakeTerminator()
        let log = tempLog()
        let g = group()
        let quitter = executor(fake, groups: [g], log: log)
        #expect(await quitter.quit(g, context: .agent("claude-code")) == .blocked("Quitting apps is always your decision, in Airy."))
        #expect(await quitter.forceQuit(g, context: .agent("claude-code")) == .blocked("Quitting apps is always your decision, in Airy."))
        #expect(fake.calls.isEmpty)
        let records = try log.records()
        #expect(records.count == 2)
        #expect(records.allSatisfy { $0.actor == .agent(client: "claude-code") && $0.outcome == "blocked" })
        #expect(records.map(\.action) == ["quit_app", "force_quit_app"])
    }

    @Test func normalQuitFirst() async {
        let fake = FakeTerminator(diesOnRequest: true)
        let g = group()
        let quitter = executor(fake, groups: [g])
        #expect(await quitter.quit(g, context: .user()) == .closed)
        #expect(fake.calls == [.request(10, isApp: true)])
        #expect(!quitter.canForceQuit(g))
    }

    @Test func unresponsiveGivesDidNotCloseThenForce() async {
        let fake = FakeTerminator(diesOnRequest: false)
        let g = group()
        let quitter = executor(fake, groups: [g])
        let began = ContinuousClock.now
        #expect(await quitter.quit(g, context: .user()) == .didNotClose)
        #expect(ContinuousClock.now - began >= .milliseconds(300))
        #expect(quitter.canForceQuit(g))
        #expect(await quitter.forceQuit(g, context: .user()) == .closed)
        #expect(fake.calls == [.request(10, isApp: true), .force(10, isApp: true)])
        #expect(!quitter.canForceQuit(g))
    }

    @Test func failedForceStaysForceable() async {
        let fake = FakeTerminator(diesOnRequest: false, forceSucceeds: false)
        let g = group()
        let quitter = executor(fake, groups: [g])
        #expect(await quitter.quit(g, context: .user()) == .didNotClose)
        #expect(await quitter.forceQuit(g, context: .user()) == .failed("Could not force it to quit."))
        #expect(quitter.canForceQuit(g))
    }

    @Test func forceSentButStillAliveIsNotClosed() async {
        let fake = FakeTerminator(diesOnRequest: false, forceSucceeds: true, diesOnForce: false)
        let g = group()
        let quitter = executor(fake, groups: [g])
        #expect(await quitter.quit(g, context: .user()) == .didNotClose)
        #expect(await quitter.forceQuit(g, context: .user()) == .failed("Could not force it to quit."))
        #expect(quitter.canForceQuit(g))
    }

    @Test func forceWithoutPriorAttemptIsRefused() async {
        let fake = FakeTerminator()
        let g = group()
        let quitter = executor(fake, groups: [g])
        #expect(await quitter.forceQuit(g, context: .user()) == .blocked("You first have to try quitting it normally."))
        #expect(fake.calls.isEmpty)
    }

    @Test func pidReuseIsRefused() async {
        let fake = FakeTerminator()
        let g = group()
        let reused = group(start: start.addingTimeInterval(60))
        let quitter = executor(fake, groups: [reused])
        #expect(await quitter.quit(g, context: .user()) == .blocked("It is no longer open."))
        #expect(fake.calls.isEmpty)
        #expect(await executor(fake, groups: []).quit(g, context: .user()) == .blocked("It is no longer open."))
        #expect(fake.calls.isEmpty)
    }

    @Test func forceRechecksPIDToo() async {
        // An app that did not respond and then quit by itself: another process reuses its PID. Nothing is forced.
        let fake = FakeTerminator(diesOnRequest: false)
        let g = group()
        let quitter = executor(fake, groups: [g])
        #expect(await quitter.quit(g, context: .user()) == .didNotClose)
        let later = QuitExecutor(terminator: fake, policy: policy,
                                 currentGroups: { [group(start: Date(timeIntervalSince1970: 1_800_000_000))] },
                                 wait: .milliseconds(300), poll: .milliseconds(20))
        #expect(await later.forceQuit(g, context: .user()) == .blocked("It is no longer open."))
        #expect(fake.calls == [.request(10, isApp: true)])
    }

    @Test func revalidatesPolicyAtActTime() async {
        let fake = FakeTerminator()
        let g = group()
        let now = group(bundle: "com.apple.finder")
        let quitter = executor(fake, groups: [now])
        guard case .blocked = await quitter.quit(g, context: .user()) else {
            Issue.record("should have been blocked")
            return
        }
        #expect(fake.calls.isEmpty)
    }

    @Test func looseProcessUsesSignalPath() async {
        let fake = FakeTerminator()
        let g = group(id: "pid:77:1700000000", name: "node", bundle: nil, kind: .looseProcess, pid: 77)
        let quitter = executor(fake, groups: [g])
        #expect(await quitter.quit(g, context: .user()) == .closed)
        #expect(fake.calls == [.request(77, isApp: false)])
    }

    @Test func everyAttemptIsLogged() async throws {
        let log = tempLog()
        let g = group()
        _ = await executor(FakeTerminator(diesOnRequest: true), groups: [g], log: log)
            .quit(g, context: .user(proposedBy: "claude-code"))
        _ = await executor(FakeTerminator(diesOnRequest: false), groups: [g], log: log).quit(g, context: .user())
        _ = await executor(FakeTerminator(), groups: [], log: log).quit(g, context: .user())
        let records = try log.records()
        #expect(records.map(\.action) == ["quit_app", "quit_app", "quit_app"])
        #expect(records.map(\.outcome) == ["closed", "did_not_close", "blocked"])
        #expect(records.allSatisfy { $0.itemID == g.id && $0.title == "Editor" && $0.paths.isEmpty
            && $0.bytes == 123_456 && $0.actor == .user && !$0.dryRun })
        #expect(records[0].proposedBy == "claude-code")
        #expect(records[2].message == "It is no longer open.")
    }

    @Test func quitCallsOnlyInQuitExecutor() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        // Preflight F1: exact list per call.
        let allowed: [String: Set<String>] = [
            "forceTerminate(": ["QuitExecutor.swift"],
            "kill(": ["QuitExecutor.swift", "CommandRunner.swift"],
            ".terminate()": ["QuitExecutor.swift", "CleanupFlow.swift", "AppQuitter.swift"],
        ]
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(files.count > 20)
        var forceCalls = 0
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (needle, owners) in allowed where text.contains(needle) {
                #expect(owners.contains(file.lastPathComponent), "\(needle) en \(file.lastPathComponent)")
            }
            if file.lastPathComponent == "QuitExecutor.swift" {
                forceCalls += text.components(separatedBy: "forceTerminate(").count - 1
            }
            if file.lastPathComponent == "AppQuitter.swift" { #expect(!text.contains("forceTerminate")) }
        }
        #expect(forceCalls == 1)
    }
}
