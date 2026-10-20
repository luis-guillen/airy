import Foundation
import Synchronization
import Testing
@testable import DiskMapCore

/// Abre nada: solo anota las URLs (F9: propio de este archivo).
private final class QuitRecordingOpener: URLOpening, Sendable {
    private let state = Mutex<[URL]>([])
    let succeeds: Bool
    init(succeeds: Bool = true) { self.succeeds = succeeds }
    var urls: [URL] { state.withLock { $0 } }
    func open(_ url: URL) async -> Bool {
        state.withLock { $0.append(url) }
        return succeeds
    }
}

private let me = getuid()
private let mb: Int64 = 1 << 20

/// Spotify, Finder, Airy, airy-mcp suelto y dos `node` sueltos (uno grande); todo del usuario actual.
private func sampleRaw() -> RawSample {
    let spotifyApp = "/Applications/Spotify.app", finderApp = "/System/Library/CoreServices/Finder.app"
    let airyApp = "/Applications/Airy.app"
    let processes = [
        OwnProcess(pid: 1000, uid: me, name: "Spotify", executablePath: spotifyApp + "/Contents/MacOS/Spotify",
                   footprint: 400 * mb),
        OwnProcess(pid: 1001, uid: me, name: "Finder", executablePath: finderApp + "/Contents/MacOS/Finder",
                   footprint: 100 * mb),
        OwnProcess(pid: 1002, uid: me, name: "Airy", executablePath: airyApp + "/Contents/MacOS/Airy", footprint: 50 * mb),
        OwnProcess(pid: 1003, uid: me, name: "airy-mcp", executablePath: "/Users/x/bin/airy-mcp", footprint: 5 * mb),
        OwnProcess(pid: 1004, uid: me, name: "node", executablePath: "/opt/homebrew/bin/node", footprint: 30 * mb,
                   workingDirectory: "/Users/x/proyecto-secreto"),
        OwnProcess(pid: 1005, uid: me, name: "node", executablePath: "/opt/homebrew/bin/node", footprint: 300 * mb,
                   workingDirectory: "/Users/x/otro"),
    ]
    let apps = [
        RunningAppInfo(pid: 1000, bundleID: "com.spotify.client", name: "Spotify", bundlePath: spotifyApp, policy: .regular),
        RunningAppInfo(pid: 1001, bundleID: "com.apple.finder", name: "Finder", bundlePath: finderApp, policy: .regular),
        RunningAppInfo(pid: 1002, bundleID: "local.airy.Airy", name: "Airy", bundlePath: airyApp, policy: .regular),
    ]
    return RawSample(date: Date(timeIntervalSince1970: 1_000), uptimeNs: 1, memory: MemoryStats(total: 16 << 30),
                     cores: Array(repeating: CoreTicks(user: 0, system: 0, idle: 0), count: 4),
                     processes: processes, apps: apps)
}

private struct PerfFixture {
    let env: AiryEnvironment
    let opener: QuitRecordingOpener
    let sampler: FakeSampler
    var context: MCPCallContext { MCPCallContext(environment: env, client: "test-client") }
    func records() -> [OperationRecord] { (try? env.log.records()) ?? [] }
    func call(_ arguments: [String: JSONValue]) async -> MCPToolResult {
        await ProposeQuitAppTool().call(arguments, context: context)
    }
}

private func makePerfFixture(opener: QuitRecordingOpener = QuitRecordingOpener()) -> PerfFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("airy-perf-\(UUID().uuidString)")
    let home = root.appendingPathComponent("home", isDirectory: true).path
    try! FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    let paths = AppPaths(support: root.appendingPathComponent("support", isDirectory: true), legacySupport: nil)
    let sampler = FakeSampler([sampleRaw()])
    let env = AiryEnvironment(
        home: home, paths: paths, catalog: Catalog(entries: []), catalogError: nil,
        settings: SettingsStore(file: paths.settingsFile), index: IndexStore(directory: paths.support),
        log: OperationLog(file: paths.operationsFile), runner: FakeRunner(), probes: FakeProbes(),
        processGuard: ProcessGuard(), references: ReferenceChecker(roots: []), urlOpener: opener,
        capacity: { nil }, sampler: sampler, appCatalog: nil)
    return PerfFixture(env: env, opener: opener, sampler: sampler)
}

@Suite struct MCPPerformanceToolTests {
    @Test func proposeQuitOpensURLAndNeverQuits() async {
        let f = makePerfFixture()
        let result = await f.call(["app": .string("com.spotify.client"), "reason": .string("pesa")])
        #expect(!result.isError, "\(result.text)")
        #expect(f.opener.urls == [URL(string: "airy://quit?app=com.spotify.client&reason=pesa&agent=test-client")!])
        #expect(result.structured?["status"] == .string("pending_user_confirmation"))
        #expect(result.structured?["risk"] == .string("safe"))
        #expect(result.structured?["app"] == .string("Spotify"))
        #expect(result.structured?["message"]
                == .string("Propuesta enviada a Airy; el usuario decide si la cierra. Airy nunca cierra apps por su cuenta."))
        #expect(f.sampler.calls == 1)
        let records = f.records()
        #expect(records.count == 1)
        #expect(records.first?.action == "propose_quit" && records.first?.outcome == "pending_user")
        #expect(records.first?.actor == .agent(client: "test-client"))
        // La herramienta no tiene ningún terminador: no hay camino por el que pueda cerrar nada.
        #expect(!result.text.contains("1000") && !result.text.contains("/Applications"))
    }

    @Test func proposeQuitRefusesNeverClosableUnknownAndToggleOff() async throws {
        let f = makePerfFixture()
        for app in ["Finder", "airy-mcp", "Airy", "NoExiste"] {
            let result = await f.call(["app": .string(app)])
            #expect(result.isError, "\(app)")
        }
        #expect(await f.call(["app": .string("NoExiste")]).text == "No hay ninguna app abierta llamada «NoExiste».")
        #expect(await f.call(["app": .string("finder")]).text.hasPrefix("«Finder» no se puede cerrar desde Airy: "))

        var off = AirySettings()
        off.agentsEnabled = false
        try f.env.settings.save(off)
        let toggled = await f.call(["app": .string("Spotify")])
        #expect(toggled.isError)
        #expect(toggled.text == "Has desactivado en Airy que los agentes ejecuten acciones (Ajustes › Agentes).")

        try Data("{\"agentsEnabled\": tru".utf8).write(to: f.env.paths.settingsFile)
        let unreadable = await f.call(["app": .string("Spotify"), "dry_run": .bool(true)])
        #expect(unreadable.isError)
        #expect(unreadable.text == "Airy no puede leer sus ajustes; no se ejecuta nada hasta que los revises en la app.")

        #expect(f.opener.urls.isEmpty)
        #expect(f.records().allSatisfy { $0.action == "propose_quit" && $0.outcome == "blocked" })
    }

    @Test func proposeQuitDryRunDoesNotOpen() async {
        let f = makePerfFixture()
        let result = await f.call(["app": .string("spotify"), "dry_run": .bool(true)])
        #expect(!result.isError)
        #expect(f.opener.urls.isEmpty)
        #expect(result.structured?["url"] == .string("airy://quit?app=com.spotify.client&agent=test-client"))
        #expect(f.records().first?.dryRun == true)
    }

    @Test func proposeQuitPicksBiggestOnAmbiguousName() async {
        let f = makePerfFixture()
        let result = await f.call(["app": .string("node"), "dry_run": .bool(true)])
        #expect(!result.isError)
        #expect(result.structured?["risk"] == .string("yourCall"))
        #expect(f.records().first?.bytes == 300 * mb)
        // Ni la carpeta de trabajo ni el PID salen hacia el agente.
        #expect(!result.text.contains("otro") && !result.text.contains("proyecto-secreto") && !result.text.contains("1005"))
    }

    @Test func proposeQuitReportsWhenAiryCannotOpen() async {
        let f = makePerfFixture(opener: QuitRecordingOpener(succeeds: false))
        let result = await f.call(["app": .string("Spotify")])
        #expect(result.isError && result.text == "No se pudo abrir Airy (¿está instalada en /Applications?).")
        #expect(f.records().first?.outcome == "failed")
    }
}
