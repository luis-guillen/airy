import Foundation
import Synchronization
import Testing
@testable import DiskMapCore

// MARK: - Doubles

/// Fake process listing; `state` can be changed halfway through a test.
private final class FakeListing: ProcessListing, Sendable {
    enum Mode: Sendable { case quiet, running(String), unknown }
    private let mode: Mutex<Mode>
    init(_ mode: Mode = .quiet) { self.mode = Mutex(mode) }
    func set(_ new: Mode) { mode.withLock { $0 = new } }

    func processes() -> [RunningProcess]? {
        switch mode.withLock({ $0 }) {
        case .quiet: []
        case .running(let name): [RunningProcess(pid: 4242, name: name, executablePath: nil)]
        case .unknown: nil
        }
    }

    func holders(ofPathsUnder paths: [String]) -> [RunningProcess]? {
        if case .unknown = mode.withLock({ $0 }) { return nil }
        return []
    }
}

private final class LiveSettings: Sendable {
    private let value: Mutex<SettingsLoad>
    private let readCount = Mutex(0)
    init(_ load: SettingsLoad) { value = Mutex(load) }
    func set(_ load: SettingsLoad) { value.withLock { $0 = load } }
    func read() -> SettingsLoad {
        readCount.withLock { $0 += 1 }
        return value.withLock { $0 }
    }
    var reads: Int { readCount.withLock { $0 } }
}

// MARK: - Utilities

private func tempDir(_ label: String) -> String {
    let url = TestTemp.url("\(label)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.path
}

private func writeFile(_ path: String, bytes: Int = 10_000) {
    try! FileManager.default.createDirectory(
        atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: path, contents: Data(repeating: 0x41, count: bytes))
}

private func exists(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0
}

private func settings(agents: Bool = true, protected: [String] = []) -> SettingsLoad {
    var s = AirySettings()
    s.agentsEnabled = agents
    s.protectedPaths = protected
    return .loaded(s)
}

private let uvEntry = CatalogEntry(
    id: "uv", title: "uv cache", explanation: "", whoCreatesIt: "", regenerates: true, risk: .safe,
    kind: .caches, paths: ["~/.cache/uv"],
    cleanup: .command(executable: "uv", arguments: ["cache", "clean"], sizeProbe: nil))

/// A temporary home with a green Trash cache (`~/Library/Caches/prueba`) and its entry.
private struct Fixture {
    let home = tempDir("airy-funnel-home")
    let store = IndexStore(directory: URL(fileURLWithPath: tempDir("airy-funnel-store")))
    let log: OperationLog
    let runner = FakeRunner(resolved: ["uv": "/opt/homebrew/bin/uv"])
    let folder: String

    init() {
        log = OperationLog(file: URL(fileURLWithPath: tempDir("airy-funnel-log")).appendingPathComponent("ops.jsonl"))
        folder = home + "/Library/Caches/prueba"
        writeFile(folder + "/f")
    }

    func entry(_ id: String = "prueba", risk: Risk = .safe, pattern: String = "~/Library/Caches/prueba",
               cleanup: CleanupMethod = .trash, mustBeClosed: [String] = [], processNames: [String] = []) -> CatalogEntry {
        CatalogEntry(id: id, title: "Prueba \(id)", explanation: "", whoCreatesIt: "", regenerates: true, risk: risk,
                     kind: .caches, paths: [pattern], cleanup: cleanup, mustBeClosed: mustBeClosed,
                     processNames: processNames)
    }

    func item(_ entry: CatalogEntry, paths: [String]? = nil, bytes: Int64 = 10_000, usedBy: [String] = []) -> CleanupItem {
        CleanupItem(id: entry.id, entry: entry, paths: paths ?? [folder], bytes: bytes, risk: entry.risk,
                    blockedByOpenApps: [], usedBy: usedBy)
    }

    func executor(
        _ entries: [CatalogEntry], settings: @escaping @Sendable () -> SettingsLoad = { .missing },
        probes: FakeProbes = FakeProbes(), listing: FakeListing = FakeListing(),
        beforeMove: (@Sendable (String) -> Void)? = nil
    ) -> CleanupExecutor {
        CleanupExecutor(
            runner: runner, probes: probes, store: store, catalog: Catalog(entries: entries + [uvEntry]),
            references: ReferenceChecker(roots: []), home: home, freeSpace: { 0 }, trashSettleDelay: .zero,
            settings: settings, log: log, processGuard: ProcessGuard(listing: listing), protections: .standard,
            beforeMove: beforeMove)
    }
}

// MARK: - Tests

@Suite struct FunnelTests {
    @Test func agentCannotExecuteYourCall() async throws {
        let f = Fixture()
        let amber = f.entry(risk: .yourCall)
        let amberCommand = CatalogEntry(
            id: "uv", title: "uv cache", explanation: "", whoCreatesIt: "", regenerates: true, risk: .yourCall,
            kind: .caches, paths: ["~/.cache/uv"],
            cleanup: .command(executable: "uv", arguments: ["cache", "clean"], sizeProbe: nil))
        let exec = CleanupExecutor(
            runner: f.runner, probes: FakeProbes(), store: f.store, catalog: Catalog(entries: [amber, amberCommand]),
            references: ReferenceChecker(roots: []), home: f.home, freeSpace: { 0 }, settings: { .missing },
            log: f.log, processGuard: ProcessGuard(listing: FakeListing()))
        let outcome = await exec.execute(f.item(amber), context: .agent("test"))
        guard case .blocked(let reason) = outcome else { Issue.record("expected .blocked, got \(outcome)"); return }
        #expect(reason.contains("“Safe to remove”"), "\(reason)")
        let command = await exec.execute(f.item(amberCommand, paths: []), context: .agent("test"))
        guard case .blocked = command else { Issue.record("expected .blocked, got \(command)"); return }
        #expect(f.runner.calls.isEmpty)
        #expect(exists(f.folder + "/f"))
        #expect(try f.store.history().isEmpty)
        #expect(try f.log.records().map(\.outcome) == ["blocked", "blocked"])
    }

    @Test func agentBlockedWhenToggleOff() async throws {
        let f = Fixture()
        let green = f.entry()
        let exec = f.executor([green], settings: { settings(agents: false) })
        for outcome in [await exec.execute(f.item(green), context: .agent("test"))] {
            guard case .blocked(let reason) = outcome else { Issue.record("expected .blocked, got \(outcome)"); return }
            #expect(reason.contains("turned off"), "\(reason)")
        }
        // The preview (dry_run) is blocked too.
        guard case .blocked = await exec.preview(f.item(green), context: .agent("test")) else {
            Issue.record("the preview should have blocked"); return
        }
        #expect(exists(f.folder + "/f"))
        // The user can (the switch is only for agents).
        guard case .wouldTrash = await exec.preview(f.item(green)) else { Issue.record("the user can"); return }
    }

    @Test func agentBlockedWhenSettingsUnreadable() async throws {
        let f = Fixture()
        let green = f.entry()
        let exec = f.executor([green], settings: { .unreadable("roto") })
        let outcome = await exec.execute(f.item(green), context: .agent("test"))
        guard case .blocked(let reason) = outcome else { Issue.record("expected .blocked, got \(outcome)"); return }
        #expect(reason.contains("cannot read its settings"), "\(reason)")
        // Fail closed for the user too: without settings their "Protect this" list is unknown.
        guard case .blocked = await exec.execute(f.item(green)) else { Issue.record("should have blocked the user"); return }
        #expect(exists(f.folder + "/f"))
    }

    @Test func agentCannotTrashPathsOrEmptyTrash() async throws {
        let f = Fixture()
        let probes = FakeProbes(trash: 5_000)
        let exec = f.executor([f.entry()], probes: probes)
        guard case .blocked = await exec.trashPaths([f.folder], title: "x", context: .agent("test")) else {
            Issue.record("an agent's trashPaths should have blocked"); return
        }
        guard case .blocked = await exec.emptyTrash(context: .agent("test")) else {
            Issue.record("an agent's emptyTrash should have blocked"); return
        }
        #expect(probes.emptyCount == 0)
        #expect(exists(f.folder + "/f"))
        let records = try f.log.records()
        #expect(records.map(\.action) == ["trash_paths", "empty_trash"])
        #expect(records.allSatisfy { $0.actor == .agent(client: "test") && $0.outcome == "blocked" })
    }

    @Test func agentSafeItemExecutesAndIsLogged() async throws {
        let f = Fixture()
        let green = f.entry()
        let expected = try #require(AllocatedSize.of(f.folder))
        let runID = UUID()
        let outcome = await f.executor([green]).execute(f.item(green), context: .agent("test", runID: runID))
        #expect(outcome == .movedToTrash(expected))
        #expect(!exists(f.folder))
        let record = try #require(try f.log.records().last)
        #expect(record.actor == .agent(client: "test"))
        #expect(record.runID == runID)
        #expect(record.action == "clean")
        #expect(record.itemID == "prueba")
        #expect(record.outcome == "moved_to_trash")
        #expect(record.dryRun == false)
        #expect(record.bytes == expected)
        #expect(record.paths == [f.folder])
        #expect(try f.store.history().last?.byAgent == true)
    }

    @Test func userExecutionIsLoggedAsUserWithProposer() async throws {
        let f = Fixture()
        let green = f.entry()
        _ = await f.executor([green]).execute(f.item(green), context: .user(proposedBy: "claude-code"))
        let record = try #require(try f.log.records().last)
        #expect(record.actor == .user)
        #expect(record.proposedBy == "claude-code")
        #expect(try f.store.history().last?.byAgent == false)
    }

    @Test func agentIsRefusedIfTheItemStopsBeingGreenBetweenPlanAndAct() async throws {
        let f = Fixture()
        // "Your call" that Aggressive mode lowers to "Safe to remove".
        let entry = CatalogEntry(id: "prueba", title: "Prueba", explanation: "", whoCreatesIt: "", regenerates: true,
                                 risk: .yourCall, kind: .caches, paths: ["~/Library/Caches/prueba"], cleanup: .trash,
                                 aggressiveRisk: .safe)
        let item = CleanupItem(id: entry.id, entry: entry, paths: [f.folder], bytes: 10_000, risk: .safe,
                               blockedByOpenApps: [], usedBy: [])
        let aggressive = { var s = AirySettings(); s.mode = .aggressive; return s }()
        let prudent = { var s = AirySettings(); s.mode = .prudent; return s }()
        let live = LiveSettings(.loaded(aggressive))
        // The user switches to "Careful" right after the plan.
        let exec = f.executor([entry], settings: { live.read() }, beforeMove: { _ in live.set(.loaded(prudent)) })
        let outcome = await exec.execute(item, context: .agent("test"))
        guard case .blocked(let reason) = outcome else { Issue.record("expected blocked, got \(outcome)"); return }
        #expect(reason.contains("only what is marked"))
        #expect(exists(f.folder))
        // The user can (the sheet shows them the new risk and they decide).
        live.set(.loaded(aggressive))
        let user = await f.executor([entry], settings: { live.read() },
                                    beforeMove: { _ in live.set(.loaded(prudent)) }).execute(item, context: .user())
        guard case .movedToTrash = user else { Issue.record("expected moved, got \(user)"); return }
    }

    @Test func sheetPreviewIsNotLoggedButAgentDryRunIs() async throws {
        let f = Fixture()
        let green = f.entry()
        let exec = f.executor([green])
        _ = await exec.preview(f.item(green), context: .user(proposedBy: "x", proposedVia: OperationContext.viaUnverifiedURL),
                               logged: false)
        #expect(try f.log.records().isEmpty)
        _ = await exec.preview(f.item(green), context: .agent("test"))
        #expect(try f.log.records().map(\.outcome) == ["would_trash"])
    }

    @Test func urlProposalIsLoggedAsAnUnverifiedClaim() async throws {
        let f = Fixture()
        let green = f.entry()
        let context = URLProposalPolicy.context(runID: UUID(), agent: "Claude Code")
        _ = await f.executor([green]).execute(f.item(green), context: context)
        let record = try #require(try f.log.records().last)
        #expect(record.actor == .user)
        #expect(record.proposedBy == "Claude Code" && record.proposedVia == "url-unverified")
        #expect(URLProposalPolicy.activityAuthor(record) == "By link (claims to be “Claude Code”) · confirmed by you")
    }

    @Test func openAppCheckFailsClosedWhenItCannotBeRead() async throws {
        let f = Fixture()
        let safari = f.entry(mustBeClosed: ["com.apple.Safari"])
        let outcome = await f.executor([safari], probes: FakeProbes(currentUnknown: true))
            .execute(f.item(safari), context: .agent("test"))
        guard case .blocked(let reason) = outcome else { Issue.record("expected blocked, got \(outcome)"); return }
        #expect(reason.contains("Could not check whether com.apple.Safari is open"), "\(reason)")
        #expect(exists(f.folder))
    }

    @Test func historyFailureIsReportedNotSwallowed() async throws {
        let f = Fixture()
        let green = f.entry()
        // The history cannot be written: `history.json` is a folder.
        let badDir = URL(fileURLWithPath: tempDir("airy-funnel-bad"))
        let blocked = IndexStore(directory: badDir)
        try FileManager.default.createDirectory(atPath: badDir.appendingPathComponent("history.json").path,
                                                withIntermediateDirectories: true)
        let exec = CleanupExecutor(
            runner: f.runner, probes: FakeProbes(), store: blocked, catalog: Catalog(entries: [green]),
            references: ReferenceChecker(roots: []), home: f.home, freeSpace: { 0 }, trashSettleDelay: .zero,
            settings: { .missing }, log: f.log, processGuard: ProcessGuard(listing: FakeListing()))
        let outcome = await exec.execute(f.item(green), context: .user())
        guard case .movedToTrash = outcome else { Issue.record("expected moved, got \(outcome)"); return }
        let failure = try #require(f.log.takeWriteFailure())
        #expect(failure.contains("history"))
    }

    @Test func previewMovesNothingAndMatchesExecute() async throws {
        let f = Fixture()
        let green = f.entry()
        let exec = f.executor([green])
        let expected = try #require(AllocatedSize.of(f.folder))
        let preview = await exec.preview(f.item(green), context: .agent("test"))
        #expect(preview == .wouldTrash(paths: [f.folder], bytes: expected))
        #expect(exists(f.folder + "/f"))
        #expect(try f.store.history().isEmpty)
        let dry = try #require(try f.log.records().last)
        #expect(dry.dryRun && dry.outcome == "would_trash" && dry.bytes == expected)

        #expect(await exec.execute(f.item(green), context: .agent("test")) == .movedToTrash(expected))
        #expect(!exists(f.folder))
    }

    @Test func previewRunsNoCommand() async throws {
        let f = Fixture()
        try FileManager.default.createDirectory(atPath: f.home + "/.cache/uv", withIntermediateDirectories: true)
        let exec = f.executor([])
        let preview = await exec.preview(f.item(uvEntry, paths: [f.home + "/.cache/uv"], bytes: 7_000))
        #expect(preview == .wouldRun(command: ["uv", "cache", "clean"], bytes: 7_000, upperBound: false))
        #expect(f.runner.calls.isEmpty)
        let dry = try #require(try f.log.records().last)
        #expect(dry.dryRun && dry.outcome == "would_run" && dry.command == ["uv", "cache", "clean"])
    }

    @Test func previewAndExecuteBlockForTheSameReason() async throws {
        let f = Fixture()
        let cases: [(String, CatalogEntry, CleanupItem, CleanupExecutor)] = {
            let used = f.entry()
            let app = f.entry(mustBeClosed: ["com.example.app"])
            let proc = f.entry(processNames: ["herramienta"])
            let running = f.entry(processNames: ["herramienta"])
            let green = f.entry()
            return [
                ("usedBy", used, f.item(used, usedBy: ["/p/config.toml"]), f.executor([used])),
                ("app abierta", app, f.item(app), f.executor([app], probes: FakeProbes(running: ["com.example.app"]))),
                ("proceso desconocido", proc, f.item(proc), f.executor([proc], listing: FakeListing(.unknown))),
                ("proceso en marcha", running, f.item(running), f.executor([running], listing: FakeListing(.running("herramienta")))),
                ("protegido", green, f.item(green),
                 f.executor([green], settings: { settings(protected: ["~/Library/Caches/prueba"]) })),
            ]
        }()
        for (label, _, item, exec) in cases {
            let preview = await exec.preview(item)
            let outcome = await exec.execute(item)
            guard case .blocked(let a) = preview, case .blocked(let b) = outcome else {
                Issue.record("\(label): expected two blocks, got \(preview) and \(outcome)"); continue
            }
            #expect(a == b, "\(label)")
        }
        #expect(exists(f.folder + "/f"))
        #expect(try f.store.history().isEmpty)
    }

    @Test func identityChangeBetweenPlanAndActRefuses() async throws {
        let f = Fixture()
        let documents = f.home + "/Documents"
        writeFile(documents + "/tesis.docx")
        let green = f.entry()
        // Between the plan and the move, the folder is replaced by a link to ~/Documents.
        let folder = f.folder
        let toLink = f.executor([green], beforeMove: { path in
            guard path == folder else { return }
            try? FileManager.default.removeItem(atPath: folder)
            try? FileManager.default.createSymbolicLink(atPath: folder, withDestinationPath: documents)
        })
        let outcome = await toLink.execute(f.item(green))
        guard case .blocked = outcome else { Issue.record("expected .blocked, got \(outcome)"); return }
        #expect(exists(documents + "/tesis.docx"))
        #expect(exists(folder)) // the link is still there: nothing was moved

        // Another ordinary folder at the same path (another inode) is rejected too: it is not what was checked.
        try FileManager.default.removeItem(atPath: folder)
        writeFile(folder + "/f")
        let toOther = f.executor([green], beforeMove: { path in
            guard path == folder else { return }
            try? FileManager.default.removeItem(atPath: folder)
            writeFile(folder + "/otro")
        })
        let other = await toOther.execute(f.item(green))
        guard case .blocked(let reason) = other else { Issue.record("expected .blocked, got \(other)"); return }
        #expect(reason.contains("has changed"), "\(reason)")
        #expect(exists(folder + "/otro"))
        #expect(try f.store.history().isEmpty)
    }

    @Test func processStartedBetweenPlanAndActRefuses() async throws {
        let f = Fixture()
        let entry = f.entry(processNames: ["herramienta"])
        let listing = FakeListing()
        let exec = f.executor([entry], listing: listing, beforeMove: { _ in listing.set(.running("herramienta")) })
        let outcome = await exec.execute(f.item(entry))
        guard case .blocked(let reason) = outcome else { Issue.record("expected .blocked, got \(outcome)"); return }
        #expect(reason.contains("herramienta"), "\(reason)")
        #expect(exists(f.folder + "/f"))
    }

    @Test func userProtectedRefusedAtExecution() async throws {
        let f = Fixture()
        let green = f.entry()
        // The item was detected unprotected; when running, the live settings already protect it.
        let live = LiveSettings(settings())
        let exec = f.executor([green], settings: { live.read() })
        live.set(settings(protected: ["~/Library/Caches/prueba"]))
        let outcome = await exec.execute(f.item(green))
        guard case .blocked(let reason) = outcome else { Issue.record("expected .blocked, got \(outcome)"); return }
        #expect(reason.contains("You protected it"), "\(reason)")
        guard case .blocked = await exec.trashPaths([f.folder + "/f"], title: "x") else {
            Issue.record("trashPaths should have blocked what is protected"); return
        }
        #expect(exec.wouldRefuseTrash(path: f.folder))
        #expect(exists(f.folder + "/f"))

        // Protected between the plan and the move: it is rejected too.
        live.set(settings())
        let late = f.executor([green], settings: { live.read() }, beforeMove: { _ in
            live.set(settings(protected: ["~/Library/Caches/prueba"]))
        })
        guard case .blocked = await late.execute(f.item(green)) else { Issue.record("should have blocked when acting"); return }
        #expect(exists(f.folder + "/f"))
    }

    @Test func liveSettingsReadPerItem() async throws {
        let f = Fixture()
        let second = f.home + "/Library/Caches/segunda"
        writeFile(second + "/f")
        let a = f.entry("a")
        let b = f.entry("b", pattern: "~/Library/Caches/segunda")
        let live = LiveSettings(settings())
        let exec = f.executor([a, b], settings: { live.read() })

        guard case .movedToTrash = await exec.execute(f.item(a), context: .agent("test")) else {
            Issue.record("the first one should have run"); return
        }
        #expect(!exists(f.folder))
        live.set(settings(agents: false))
        guard case .blocked = await exec.execute(f.item(b, paths: [second]), context: .agent("test")) else {
            Issue.record("the second one should have been blocked"); return
        }
        #expect(exists(second + "/f"))
        #expect(live.reads >= 2)
    }

    @Test func unsafeTrashReasonIsThePathGateRule() async throws {
        let f = Fixture()
        let exec = f.executor([f.entry()])
        for path in ["relativa", "/", f.home, f.home + "/Documents", "/System", f.home + "/no-existe"] {
            let gate = PathGate(home: f.home, catalog: Catalog(entries: [f.entry(), uvEntry]),
                                userProtected: ProtectList(patterns: [], home: f.home))
            #expect(exec.unsafeTrashReason(path) == gate.validate(path).failure?.reason, "\(path)")
        }
        #expect(exec.unsafeTrashReason(f.folder) == nil)
        #expect(!exec.wouldRefuseTrash(path: f.folder))
    }

    // Review 1: commands are checked with the live entry's paths, not with the item's.
    @Test func commandProtectedIsRefusedEvenWithEmptyPaths() async throws {
        let f = Fixture()
        try FileManager.default.createDirectory(atPath: f.home + "/.cache/uv", withIntermediateDirectories: true)
        let exec = f.executor([], settings: { settings(protected: ["~/.cache/uv"]) })
        for item in [f.item(uvEntry, paths: []), f.item(uvEntry, paths: [f.home + "/.cache/uv"])] {
            guard case .blocked(let reason) = await exec.preview(item),
                  case .blocked(let same) = await exec.execute(item) else {
                Issue.record("the command on a protected folder should have been blocked"); continue
            }
            #expect(reason == same && reason.contains("You protected it"), "\(reason)")
        }
        #expect(f.runner.calls.isEmpty)
    }

    @Test func commandProtectedBetweenPlanAndActIsRefused() async throws {
        let f = Fixture()
        try FileManager.default.createDirectory(atPath: f.home + "/.cache/uv", withIntermediateDirectories: true)
        // First read (plan): unprotected; the following ones (before running): protected.
        let live = LiveSettings(settings())
        let exec = f.executor([], settings: {
            let load = live.read()
            live.set(settings(protected: ["~/.cache/uv"]))
            return load
        })
        guard case .blocked(let reason) = await exec.execute(f.item(uvEntry, paths: [])) else {
            Issue.record("should have been blocked when running"); return
        }
        #expect(reason.contains("You protected it"), "\(reason)")
        #expect(f.runner.calls.isEmpty)
    }

    @Test func commandNeedsItsLiveFolderAndOnlyItsPaths() async throws {
        let f = Fixture()
        let exec = f.executor([])
        // Without ~/.cache/uv on disk nothing runs.
        guard case .blocked = await exec.execute(f.item(uvEntry, paths: [])) else {
            Issue.record("without a folder it should have been blocked"); return
        }
        try FileManager.default.createDirectory(atPath: f.home + "/.cache/uv", withIntermediateDirectories: true)
        // A path that does not belong to the entry either.
        guard case .blocked(let reason) = await exec.execute(f.item(uvEntry, paths: [f.folder])) else {
            Issue.record("an unrelated path should have been blocked"); return
        }
        #expect(reason.contains("does not belong"), "\(reason)")
        #expect(f.runner.calls.isEmpty)
        guard case .freed = await exec.execute(f.item(uvEntry, paths: [])) else { Issue.record("should have run"); return }
        #expect(f.runner.calls.count == 1)
        #expect(try f.log.records().last?.paths == [f.home + "/.cache/uv"])
    }

    // Review 2: a batch that stops halfway is recorded with what was really moved.
    @Test func partialTrashIsLoggedWithWhatMoved() async throws {
        let f = Fixture()
        let second = f.home + "/Library/Caches/segunda"
        writeFile(second + "/f")
        let firstBytes = try #require(AllocatedSize.of(f.folder))
        let exec = f.executor([], beforeMove: { path in
            if path == second { try? FileManager.default.removeItem(atPath: second) }
        })
        let outcome = await exec.trashPaths([f.folder, second], title: "Tanda")
        guard case .blocked(let reason) = outcome else { Issue.record("expected .blocked, got \(outcome)"); return }
        #expect(!exists(f.folder))
        let record = try #require(try f.log.records().last)
        #expect(record.outcome == "partial")
        #expect(record.paths == [f.folder])
        #expect(record.bytes == firstBytes)
        #expect(record.message == reason)
        #expect(try f.store.history().last?.bytes == record.bytes)
    }

    @Test func trashItemOnlyCalledFromTheFunnel() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let allowed: [String: Set<String>] = [
            "trashItem(": ["CleanupExecutor.swift"],
            "removeItem(": ["SystemProbes.swift", "IndexStore.swift", "DataMigration.swift", "CommandRunner.swift",
                            "AIAssistant.swift"],
            "unlink(": ["SystemProbes.swift", "IndexStore.swift", "DataMigration.swift", "CommandRunner.swift",
                        "AIAssistant.swift"],
            "rmdir(": ["SystemProbes.swift", "IndexStore.swift", "DataMigration.swift", "CommandRunner.swift",
                       "AIAssistant.swift"],
        ]
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(files.count > 20)
        var trashCalls = 0
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (needle, owners) in allowed where text.contains(needle) {
                #expect(owners.contains(file.lastPathComponent), "\(needle) en \(file.lastPathComponent)")
            }
            trashCalls += text.components(separatedBy: "trashItem(").count - 1
        }
        #expect(trashCalls == 1)
    }
}
