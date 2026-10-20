import Foundation
import Synchronization
import Testing
@testable import DiskMapCore

// MARK: - Dobles

/// Listado de procesos simulado; `state` se puede cambiar a mitad de prueba.
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

// MARK: - Utilidades

private func tempDir(_ label: String) -> String {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(label)-\(UUID().uuidString)")
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
    id: "uv", title: "Caché de uv", explanation: "", whoCreatesIt: "", regenerates: true, risk: .safe,
    kind: .caches, paths: ["~/.cache/uv"],
    cleanup: .command(executable: "uv", arguments: ["cache", "clean"], sizeProbe: nil))

/// Un home temporal con una caché verde de Papelera (`~/Library/Caches/prueba`) y su ficha.
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

// MARK: - Pruebas

@Suite struct FunnelTests {
    @Test func agentCannotExecuteYourCall() async throws {
        let f = Fixture()
        let amber = f.entry(risk: .yourCall)
        let amberCommand = CatalogEntry(
            id: "uv", title: "Caché de uv", explanation: "", whoCreatesIt: "", regenerates: true, risk: .yourCall,
            kind: .caches, paths: ["~/.cache/uv"],
            cleanup: .command(executable: "uv", arguments: ["cache", "clean"], sizeProbe: nil))
        let exec = CleanupExecutor(
            runner: f.runner, probes: FakeProbes(), store: f.store, catalog: Catalog(entries: [amber, amberCommand]),
            references: ReferenceChecker(roots: []), home: f.home, freeSpace: { 0 },
            log: f.log, processGuard: ProcessGuard(listing: FakeListing()))
        let outcome = await exec.execute(f.item(amber), context: .agent("test"))
        guard case .blocked(let reason) = outcome else { Issue.record("esperaba .blocked, hubo \(outcome)"); return }
        #expect(reason.contains("«Sin problema»"), "\(reason)")
        let command = await exec.execute(f.item(amberCommand, paths: []), context: .agent("test"))
        guard case .blocked = command else { Issue.record("esperaba .blocked, hubo \(command)"); return }
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
            guard case .blocked(let reason) = outcome else { Issue.record("esperaba .blocked, hubo \(outcome)"); return }
            #expect(reason.contains("desactivado"), "\(reason)")
        }
        // También la vista previa (dry_run) queda bloqueada.
        guard case .blocked = await exec.preview(f.item(green), context: .agent("test")) else {
            Issue.record("la vista previa debió bloquear"); return
        }
        #expect(exists(f.folder + "/f"))
        // El usuario sí puede (el interruptor es solo para agentes).
        guard case .wouldTrash = await exec.preview(f.item(green)) else { Issue.record("el usuario sí puede"); return }
    }

    @Test func agentBlockedWhenSettingsUnreadable() async throws {
        let f = Fixture()
        let green = f.entry()
        let exec = f.executor([green], settings: { .unreadable("roto") })
        let outcome = await exec.execute(f.item(green), context: .agent("test"))
        guard case .blocked(let reason) = outcome else { Issue.record("esperaba .blocked, hubo \(outcome)"); return }
        #expect(reason.contains("no puede leer sus ajustes"), "\(reason)")
        // Fallo cerrado también para el usuario: sin ajustes no se conoce su lista «Proteger esto».
        guard case .blocked = await exec.execute(f.item(green)) else { Issue.record("debió bloquear al usuario"); return }
        #expect(exists(f.folder + "/f"))
    }

    @Test func agentCannotTrashPathsOrEmptyTrash() async throws {
        let f = Fixture()
        let probes = FakeProbes(trash: 5_000)
        let exec = f.executor([f.entry()], probes: probes)
        guard case .blocked = await exec.trashPaths([f.folder], title: "x", context: .agent("test")) else {
            Issue.record("trashPaths de agente debió bloquear"); return
        }
        guard case .blocked = await exec.emptyTrash(context: .agent("test")) else {
            Issue.record("emptyTrash de agente debió bloquear"); return
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
                Issue.record("\(label): esperaba dos bloqueos, hubo \(preview) y \(outcome)"); continue
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
        // Entre el plan y el movimiento, la carpeta se sustituye por un enlace a ~/Documents.
        let folder = f.folder
        let toLink = f.executor([green], beforeMove: { path in
            guard path == folder else { return }
            try? FileManager.default.removeItem(atPath: folder)
            try? FileManager.default.createSymbolicLink(atPath: folder, withDestinationPath: documents)
        })
        let outcome = await toLink.execute(f.item(green))
        guard case .blocked = outcome else { Issue.record("esperaba .blocked, hubo \(outcome)"); return }
        #expect(exists(documents + "/tesis.docx"))
        #expect(exists(folder)) // el enlace sigue ahí: no se movió nada

        // Otra carpeta corriente en la misma ruta (otro inodo) también se rechaza: no es lo que se comprobó.
        try FileManager.default.removeItem(atPath: folder)
        writeFile(folder + "/f")
        let toOther = f.executor([green], beforeMove: { path in
            guard path == folder else { return }
            try? FileManager.default.removeItem(atPath: folder)
            writeFile(folder + "/otro")
        })
        let other = await toOther.execute(f.item(green))
        guard case .blocked(let reason) = other else { Issue.record("esperaba .blocked, hubo \(other)"); return }
        #expect(reason.contains("ha cambiado"), "\(reason)")
        #expect(exists(folder + "/otro"))
        #expect(try f.store.history().isEmpty)
    }

    @Test func processStartedBetweenPlanAndActRefuses() async throws {
        let f = Fixture()
        let entry = f.entry(processNames: ["herramienta"])
        let listing = FakeListing()
        let exec = f.executor([entry], listing: listing, beforeMove: { _ in listing.set(.running("herramienta")) })
        let outcome = await exec.execute(f.item(entry))
        guard case .blocked(let reason) = outcome else { Issue.record("esperaba .blocked, hubo \(outcome)"); return }
        #expect(reason.contains("herramienta"), "\(reason)")
        #expect(exists(f.folder + "/f"))
    }

    @Test func userProtectedRefusedAtExecution() async throws {
        let f = Fixture()
        let green = f.entry()
        // El elemento se detectó sin proteger; al ejecutar, los ajustes vivos ya lo protegen.
        let live = LiveSettings(settings())
        let exec = f.executor([green], settings: { live.read() })
        live.set(settings(protected: ["~/Library/Caches/prueba"]))
        let outcome = await exec.execute(f.item(green))
        guard case .blocked(let reason) = outcome else { Issue.record("esperaba .blocked, hubo \(outcome)"); return }
        #expect(reason.contains("Lo has protegido tú"), "\(reason)")
        guard case .blocked = await exec.trashPaths([f.folder + "/f"], title: "x") else {
            Issue.record("trashPaths debió bloquear lo protegido"); return
        }
        #expect(exec.wouldRefuseTrash(path: f.folder))
        #expect(exists(f.folder + "/f"))

        // Protegido entre el plan y el movimiento: también se rechaza.
        live.set(settings())
        let late = f.executor([green], settings: { live.read() }, beforeMove: { _ in
            live.set(settings(protected: ["~/Library/Caches/prueba"]))
        })
        guard case .blocked = await late.execute(f.item(green)) else { Issue.record("debió bloquear al actuar"); return }
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
            Issue.record("el primero debió ejecutarse"); return
        }
        #expect(!exists(f.folder))
        live.set(settings(agents: false))
        guard case .blocked = await exec.execute(f.item(b, paths: [second]), context: .agent("test")) else {
            Issue.record("el segundo debió bloquearse"); return
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
