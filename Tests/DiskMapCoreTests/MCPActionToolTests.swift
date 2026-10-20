import Foundation
import Synchronization
import Testing
@testable import DiskMapCore

// MARK: - Dobles

/// Registra las URLs que se le piden abrir; nunca abre nada.
private final class RecordingOpener: URLOpening, Sendable {
    private let state = Mutex<[URL]>([])
    let succeeds: Bool
    init(succeeds: Bool = true) { self.succeeds = succeeds }
    var urls: [URL] { state.withLock { $0 } }
    func open(_ url: URL) async -> Bool {
        state.withLock { $0.append(url) }
        return succeeds
    }
}

/// Sin procesos en marcha ni ficheros abiertos.
private struct QuietListing: ProcessListing {
    func processes() -> [RunningProcess]? { [] }
    func holders(ofPathsUnder paths: [String]) -> [RunningProcess]? { [] }
}

// MARK: - Fixture

private struct ActionFixture {
    let home: String
    let env: AiryEnvironment
    let runner: FakeRunner
    let opener: RecordingOpener

    var context: MCPCallContext { MCPCallContext(environment: env, client: "test-client") }

    func call(_ tool: any MCPTool, _ arguments: [String: JSONValue] = [:]) async -> MCPToolResult {
        await tool.call(arguments, context: context)
    }

    func records() -> [OperationRecord] { (try? env.log.records()) ?? [] }

    func saveSettings(_ change: (inout AirySettings) -> Void) {
        var s = AirySettings()
        change(&s)
        try! env.settings.save(s)
    }
}

private func makeFixture(
    entries: [CatalogEntry], running: Set<String> = [], opener: RecordingOpener = RecordingOpener(),
    onRun: (@Sendable (FakeRunner.Call) -> Void)? = nil
) -> ActionFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("airy-action-\(UUID().uuidString)")
    let home = root.appendingPathComponent("home", isDirectory: true).path
    try! FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    let paths = AppPaths(support: root.appendingPathComponent("support", isDirectory: true), legacySupport: nil)
    let runner = FakeRunner(resolved: ["uv": "/fake/uv", "tool2": "/fake/tool2"], onRun: onRun)
    let env = AiryEnvironment(
        home: home, paths: paths, catalog: Catalog(entries: entries), catalogError: nil,
        settings: SettingsStore(file: paths.settingsFile), index: IndexStore(directory: paths.support),
        log: OperationLog(file: paths.operationsFile), runner: runner, probes: FakeProbes(running: running),
        processGuard: ProcessGuard(listing: QuietListing()), references: ReferenceChecker(roots: []),
        urlOpener: opener, capacity: { VolumeCapacity(total: 1000, available: 500, importantAvailable: 400) })
    return ActionFixture(home: home, env: env, runner: runner, opener: opener)
}

private func trashEntry(_ id: String, risk: Risk = .safe, mustBeClosed: [String] = [],
                        preselectInAggressive: Bool = false) -> CatalogEntry {
    CatalogEntry(id: id, title: "Prueba \(id)", explanation: "", whoCreatesIt: "", regenerates: true, risk: risk,
                 kind: .caches, paths: ["~/Library/Caches/\(id)"], cleanup: .trash, mustBeClosed: mustBeClosed,
                 preselectInAggressive: preselectInAggressive)
}

private func commandEntry(_ id: String, executable: String, folder: String, risk: Risk = .safe) -> CatalogEntry {
    CatalogEntry(id: id, title: "Caché de \(id)", explanation: "", whoCreatesIt: "", regenerates: true, risk: risk,
                 kind: .caches, paths: ["~/\(folder)"],
                 cleanup: .command(executable: executable, arguments: ["cache", "clean"], sizeProbe: nil))
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

/// Crea `~/Library/Caches/<id>/f` y devuelve la carpeta.
@discardableResult
private func makeCache(_ f: ActionFixture, _ id: String) -> String {
    let folder = f.home + "/Library/Caches/" + id
    writeFile(folder + "/f")
    return folder
}

private let actionNames = ["run_safe_cleanup", "run_safe_cleanup_all", "propose_cleanup", "show_in_app", "rescan",
                           "propose_quit_app"]

// MARK: - Pruebas

@Suite struct MCPActionToolTests {
    @Test func runSafeCleanupExecutesGreenItem() async throws {
        let f = makeFixture(entries: [trashEntry("prueba")])
        let folder = makeCache(f, "prueba")
        let result = await f.call(RunSafeCleanupTool(), ["item_id": .string("prueba")])
        #expect(!result.isError, "\(result.text)")
        let s = try #require(result.structured)
        #expect(s["outcome"]?.stringValue == "moved_to_trash")
        #expect(s["item_id"]?.stringValue == "prueba")
        #expect(s["dry_run"]?.boolValue == false)
        #expect((s["bytes"]?.intValue ?? 0) > 0)
        #expect(UUID(uuidString: s["run_id"]?.stringValue ?? "") != nil)
        #expect(!exists(folder))
        let records = f.records()
        #expect(records.count == 1)
        #expect(records.first?.actor == .agent(client: "test-client"))
        #expect(records.first?.outcome == "moved_to_trash")
        #expect(records.first?.runID.uuidString == s["run_id"]?.stringValue)
    }

    @Test func runSafeCleanupRefusesYourCall() async throws {
        let f = makeFixture(entries: [trashEntry("ambar", risk: .yourCall)])
        let folder = makeCache(f, "ambar")
        let result = await f.call(RunSafeCleanupTool(), ["item_id": .string("ambar")])
        #expect(result.isError)
        #expect(result.text == "«Prueba ambar» es «Tú decides»: solo se ejecuta lo marcado «Sin problema». Usa propose_cleanup para que el usuario decida en Airy.")
        #expect(f.runner.calls.isEmpty)
        #expect(exists(folder + "/f"))
        #expect(f.records().map(\.outcome) == ["blocked"])
    }

    @Test func runSafeCleanupRefusesDoNotTouchAndOpenApp() async throws {
        let f = makeFixture(entries: [trashEntry("rojo", risk: .doNotTouch),
                                      trashEntry("app", mustBeClosed: ["com.example.App"])],
                            running: ["com.example.App"])
        let red = makeCache(f, "rojo"), app = makeCache(f, "app")
        let redResult = await f.call(RunSafeCleanupTool(), ["item_id": .string("rojo")])
        #expect(redResult.isError)
        #expect(redResult.text == "«Prueba rojo» es «No borrar»: Airy no lo toca.")
        let appResult = await f.call(RunSafeCleanupTool(), ["item_id": .string("app")])
        #expect(appResult.isError)
        #expect(appResult.text.contains("com.example.App"))
        #expect(exists(red + "/f") && exists(app + "/f"))
        #expect(f.runner.calls.isEmpty)
        let missing = await f.call(RunSafeCleanupTool(), ["item_id": .string("no-existe")])
        #expect(missing.isError)
    }

    @Test func runSafeCleanupDryRunMovesNothing() async throws {
        let f = makeFixture(entries: [trashEntry("prueba")])
        let folder = makeCache(f, "prueba")
        let result = await f.call(RunSafeCleanupTool(), ["item_id": .string("prueba"), "dry_run": .bool(true)])
        #expect(!result.isError, "\(result.text)")
        #expect(result.structured?["outcome"]?.stringValue == "would_trash")
        #expect(result.structured?["dry_run"]?.boolValue == true)
        #expect(exists(folder + "/f"))
        let records = f.records()
        #expect(records.count == 1)
        #expect(records.first?.dryRun == true)
        #expect(records.first?.outcome == "would_trash")
    }

    @Test func oneCallYieldsExactlyOneRecord() async throws {
        let f = makeFixture(entries: [trashEntry("prueba"), trashEntry("ambar", risk: .yourCall)])
        makeCache(f, "prueba"); makeCache(f, "ambar")
        _ = await f.call(RunSafeCleanupTool(), ["item_id": .string("prueba"), "dry_run": .bool(true)])
        #expect(f.records().count == 1)
        _ = await f.call(RunSafeCleanupTool(), ["item_id": .string("prueba")])
        #expect(f.records().count == 2)
        _ = await f.call(RunSafeCleanupTool(), ["item_id": .string("ambar")])
        #expect(f.records().count == 3)
        _ = await f.call(ProposeCleanupTool(), ["item_id": .string("ambar"), "reason": .string("ocupa mucho")])
        #expect(f.records().count == 4)
        _ = await f.call(RescanTool())
        #expect(f.records().count == 5)
    }

    @Test func agentCommandUsesExactCatalogArguments() async throws {
        let f = makeFixture(entries: [commandEntry("uv", executable: "uv", folder: ".cache/uv")])
        writeFile(f.home + "/.cache/uv/f")
        let result = await f.call(RunSafeCleanupTool(), ["item_id": .string("uv")])
        #expect(!result.isError, "\(result.text)")
        #expect(result.structured?["outcome"]?.stringValue == "freed")
        #expect(f.runner.calls.map(\.executable) == ["/fake/uv"])
        #expect(f.runner.calls.map(\.arguments) == [["cache", "clean"]])
        #expect(f.records().first?.command == ["uv", "cache", "clean"])
    }

    private func assertAllActionToolsBlocked(_ f: ActionFixture, message: String) async {
        let calls: [(any MCPTool, [String: JSONValue])] = [
            (RunSafeCleanupTool(), ["item_id": .string("prueba")]),
            (RunSafeCleanupAllTool(), [:]),
            (ProposeCleanupTool(), ["item_id": .string("prueba"), "reason": .string("motivo")]),
            (ShowInAppTool(), ["path": .string(f.home + "/Library")]),
            (RescanTool(), [:]),
        ]
        for (tool, arguments) in calls {
            for dry in [false, true] {
                var args = arguments
                args["dry_run"] = .bool(dry)
                let result = await f.call(tool, args)
                #expect(result.isError, "\(tool.name) dry_run=\(dry)")
                #expect(result.text == message, "\(tool.name): \(result.text)")
            }
        }
        #expect(f.opener.urls.isEmpty)
        #expect(f.runner.calls.isEmpty)
        #expect(exists(f.home + "/Library/Caches/prueba/f"))
        #expect(f.records().allSatisfy { $0.outcome == "blocked" && $0.actor == .agent(client: "test-client") })
    }

    @Test func toggleOffBlocksEveryActionTool() async throws {
        let f = makeFixture(entries: [trashEntry("prueba")])
        makeCache(f, "prueba")
        f.saveSettings { $0.agentsEnabled = false }
        await assertAllActionToolsBlocked(
            f, message: "Has desactivado en Airy que los agentes ejecuten acciones (Ajustes › Agentes).")
    }

    @Test func unreadableSettingsBlocksActions() async throws {
        let f = makeFixture(entries: [trashEntry("prueba")])
        makeCache(f, "prueba")
        try FileManager.default.createDirectory(at: f.env.paths.settingsFile.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("{\"agentsEnabled\": tru".utf8).write(to: f.env.paths.settingsFile)
        await assertAllActionToolsBlocked(
            f, message: "Airy no puede leer sus ajustes; no se ejecuta nada hasta que los revises en la app.")
        // Una versión futura también es ilegible.
        try Data("{\"version\": 99, \"agentsEnabled\": true}".utf8).write(to: f.env.paths.settingsFile)
        let result = await f.call(RunSafeCleanupAllTool(), ["dry_run": .bool(true)])
        #expect(result.isError)
        #expect(f.runner.calls.isEmpty)
    }

    @Test func runAllOnlyTouchesGreen() async throws {
        let f = makeFixture(entries: [
            trashEntry("a"), trashEntry("b"), trashEntry("c", risk: .yourCall, preselectInAggressive: true),
            trashEntry("d", risk: .doNotTouch),
        ])
        let folders = ["a", "b", "c", "d"].map { makeCache(f, $0) }
        f.saveSettings { $0.mode = .aggressive }
        let result = await f.call(RunSafeCleanupAllTool())
        #expect(!result.isError, "\(result.text)")
        let s = try #require(result.structured)
        guard case .array(let rows)? = s["results"] else { Issue.record("results"); return }
        #expect(Set(rows.compactMap { $0["item_id"]?.stringValue }) == ["a", "b"])
        #expect(rows.allSatisfy { $0["outcome"]?.stringValue == "moved_to_trash" })
        #expect((s["moved_to_trash_bytes"]?.intValue ?? 0) > 0)
        #expect(s["freed_bytes"]?.intValue == 0)
        #expect(!exists(folders[0]) && !exists(folders[1]))
        #expect(exists(folders[2] + "/f") && exists(folders[3] + "/f"))
        let records = f.records()
        #expect(records.count == 2)
        #expect(Set(records.map(\.runID)).count == 1)
        #expect(records.first?.runID.uuidString == s["run_id"]?.stringValue)
    }

    @Test func runAllStopsWhenToggleTurnsOffMidBatch() async throws {
        let settingsFile = Mutex<URL?>(nil)
        let f = makeFixture(entries: [
            commandEntry("uv", executable: "uv", folder: ".cache/uv"),
            commandEntry("tool2", executable: "tool2", folder: ".cache/tool2"),
        ], onRun: { _ in
            // Tras el primer comando, el usuario apaga el interruptor en la app.
            guard let file = settingsFile.withLock({ $0 }) else { return }
            var s = AirySettings()
            s.agentsEnabled = false
            try! SettingsStore(file: file).save(s)
        })
        settingsFile.withLock { $0 = f.env.paths.settingsFile }
        writeFile(f.home + "/.cache/uv/f")
        writeFile(f.home + "/.cache/tool2/f")
        let result = await f.call(RunSafeCleanupAllTool())
        let s = try #require(result.structured)
        guard case .array(let rows)? = s["results"] else { Issue.record("results"); return }
        #expect(rows.count == 2)
        #expect(rows.first?["outcome"]?.stringValue == "freed")
        #expect(rows.last?["outcome"]?.stringValue == "blocked")
        #expect(rows.last?["message"]?.stringValue
            == "Has desactivado en Airy que los agentes ejecuten acciones (Ajustes › Agentes).")
        #expect(f.runner.calls.count == 1)
        #expect(f.records().map(\.outcome) == ["freed", "blocked"])
    }

    @Test func proposeOpensURLWithoutExecuting() async throws {
        let f = makeFixture(entries: [trashEntry("ambar", risk: .yourCall)])
        let folder = makeCache(f, "ambar")
        let result = await f.call(ProposeCleanupTool(), ["item_id": .string("ambar"), "reason": .string("Ocupa 10 KB")])
        #expect(!result.isError, "\(result.text)")
        #expect(result.structured?["status"]?.stringValue == "pending_user_confirmation")
        #expect(result.structured?["message"]?.stringValue == "Propuesta enviada a Airy; pendiente de confirmación del usuario.")
        let url = try #require(f.opener.urls.first)
        #expect(f.opener.urls.count == 1)
        #expect(url.absoluteString.hasPrefix("airy://propose?item=ambar&"))
        #expect(url.absoluteString.contains("agent=test-client"))
        #expect(AiryURLCommand(url: url) == .propose(target: .item("ambar"), reason: "Ocupa 10 KB", agent: "test-client"))
        #expect(result.structured?["url"]?.stringValue == url.absoluteString)
        #expect(f.runner.calls.isEmpty)
        #expect(exists(folder + "/f"))
        #expect(f.records().map(\.outcome) == ["pending_user"])
        #expect(f.records().first?.action == "propose")

        // Por ruta, también sin ejecutar.
        let byPath = await f.call(ProposeCleanupTool(), ["path": .string("~/Library/Caches/ambar/f"),
                                                         "reason": .string("viejo")])
        #expect(!byPath.isError, "\(byPath.text)")
        #expect(AiryURLCommand(url: f.opener.urls.last!) == .propose(
            target: .path(f.home + "/Library/Caches/ambar/f"), reason: "viejo", agent: "test-client"))
        #expect(exists(folder + "/f"))

        // Sin la app: error y nada más.
        let noApp = makeFixture(entries: [trashEntry("ambar", risk: .yourCall)], opener: RecordingOpener(succeeds: false))
        makeCache(noApp, "ambar")
        let failed = await noApp.call(ProposeCleanupTool(), ["item_id": .string("ambar"), "reason": .string("x")])
        #expect(failed.isError)
        #expect(failed.text == "No se pudo abrir Airy (¿está instalada en /Applications?).")
    }

    @Test func proposeRejectsRedBothTargetsAndMissingReason() async throws {
        let f = makeFixture(entries: [trashEntry("rojo", risk: .doNotTouch), trashEntry("ambar", risk: .yourCall)])
        makeCache(f, "rojo"); makeCache(f, "ambar")
        let red = await f.call(ProposeCleanupTool(), ["item_id": .string("rojo"), "reason": .string("x")])
        #expect(red.isError)
        #expect(red.text == "«Prueba rojo» es «No borrar»: Airy no lo toca.")
        let both = await f.call(ProposeCleanupTool(), ["item_id": .string("ambar"), "path": .string(f.home + "/x"),
                                                       "reason": .string("x")])
        #expect(both.isError)
        let neither = await f.call(ProposeCleanupTool(), ["reason": .string("x")])
        #expect(neither.isError)
        let noReason = await f.call(ProposeCleanupTool(), ["item_id": .string("ambar")])
        #expect(noReason.isError)
        let blank = await f.call(ProposeCleanupTool(), ["item_id": .string("ambar"), "reason": .string("   ")])
        #expect(blank.isError)
        let long = await f.call(ProposeCleanupTool(), ["item_id": .string("ambar"),
                                                       "reason": .string(String(repeating: "a", count: 501))])
        #expect(long.isError)
        let schema = ProposeCleanupTool().inputSchema
        #expect(MCPSchemaValidator.violation(of: .object(["item_id": .string("ambar")]), against: schema) != nil)
        #expect(MCPSchemaValidator.violation(of: .object(["item_id": .string("ambar"), "reason": .string("")]),
                                             against: schema) != nil)
        let missing = await f.call(ProposeCleanupTool(), ["item_id": .string("no-existe"), "reason": .string("x")])
        #expect(missing.isError)
        #expect(f.opener.urls.isEmpty)
    }

    @Test func proposePathRefusedWhenGateRefuses() async throws {
        let f = makeFixture(entries: [])
        writeFile(f.home + "/Library/Keychains/login.keychain-db")
        let result = await f.call(ProposeCleanupTool(), ["path": .string(f.home + "/Library/Keychains"),
                                                         "reason": .string("ocupa")])
        #expect(result.isError)
        let relative = await f.call(ProposeCleanupTool(), ["path": .string("relativa"), "reason": .string("x")])
        #expect(relative.isError)
        #expect(f.opener.urls.isEmpty)
        #expect(exists(f.home + "/Library/Keychains/login.keychain-db"))
    }

    @Test func showAndRescanOpenURLsDryRunDoesNot() async throws {
        let f = makeFixture(entries: [])
        let dryShow = await f.call(ShowInAppTool(), ["path": .string("~/Downloads"), "dry_run": .bool(true)])
        #expect(!dryShow.isError)
        #expect(dryShow.structured?["url"]?.stringValue == AiryURLCommand.show(path: f.home + "/Downloads").url.absoluteString)
        let dryRescan = await f.call(RescanTool(), ["dry_run": .bool(true)])
        #expect(dryRescan.structured?["url"]?.stringValue == "airy://rescan")
        #expect(f.opener.urls.isEmpty)

        let show = await f.call(ShowInAppTool(), ["path": .string("~/Downloads")])
        #expect(!show.isError)
        let rescan = await f.call(RescanTool())
        #expect(!rescan.isError)
        #expect(rescan.structured?["status"]?.stringValue == "scan_requested")
        #expect(rescan.structured?["message"]?.stringValue
            == "Análisis pedido a Airy. Cuando termine, get_disk_summary mostrará la fecha nueva.")
        #expect(f.opener.urls.map { AiryURLCommand(url: $0) } == [.show(path: f.home + "/Downloads"), .rescan])
        #expect(f.records().map(\.action) == ["show", "rescan", "show", "rescan"])
        #expect(f.records().allSatisfy { $0.outcome == "requested" })
        #expect(f.records().map(\.dryRun) == [true, true, false, false])

        let relative = await f.call(ShowInAppTool(), ["path": .string("Downloads")])
        #expect(relative.isError)
        #expect(f.opener.urls.count == 2)
    }

    /// F11: el conjunto exacto, sin contar; cada plan añade sus nombres.
    @Test func registryHasExactToolSetAndNoArbitraryInput() {
        let tools = MCPToolRegistry.standard().tools
        #expect(tools.map(\.name).sorted() == ["explain_path", "get_disk_summary", "list_cleanup_items", "list_largest",
            "propose_cleanup", "propose_quit_app", "rescan", "run_safe_cleanup", "run_safe_cleanup_all", "show_in_app"])
        for tool in tools {
            guard case .object(let properties)? = tool.inputSchema["properties"] else {
                Issue.record("\(tool.name) sin properties"); continue
            }
            for forbidden in ["command", "args", "paths"] { #expect(properties[forbidden] == nil, "\(tool.name)") }
            if properties["path"] != nil {
                #expect(["list_largest", "explain_path", "propose_cleanup", "show_in_app"].contains(tool.name))
            }
            if properties["app"] != nil { #expect(tool.name == "propose_quit_app") }
            #expect(tool.inputSchema["additionalProperties"] == .bool(false))
            if actionNames.contains(tool.name) {
                #expect(!tool.annotations.readOnly)
                #expect(tool.annotations.destructive == tool.name.hasPrefix("run_"))
                #expect(properties["dry_run"] != nil)
            }
        }
    }
}
