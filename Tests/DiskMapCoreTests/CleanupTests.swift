import Foundation
import Synchronization
import Testing
@testable import DiskMapCore

// MARK: - Dobles de prueba

final class FakeRunner: CommandRunning, Sendable {
    struct Call: Equatable, Sendable {
        var executable: String
        var arguments: [String]
        var timeout: TimeInterval
        var workingDirectory: String? = nil
    }

    private let state = Mutex<(calls: [Call], resolveCalls: [String])>(([], []))
    let resolved: [String: String]
    let outputs: [String: CommandOutput]
    /// Solo para pruebas: se llama tras anotar cada ejecución (p. ej. para cambiar los ajustes a mitad de tanda).
    let onRun: (@Sendable (Call) -> Void)?

    /// `outputs` se indexa por "ejecutable argumentos…" (ruta resuelta y argumentos unidos por espacios).
    init(resolved: [String: String] = [:], outputs: [String: CommandOutput] = [:],
         onRun: (@Sendable (Call) -> Void)? = nil) {
        self.resolved = resolved
        self.outputs = outputs
        self.onRun = onRun
    }

    var calls: [Call] { state.withLock { $0.calls } }
    var resolveCalls: [String] { state.withLock { $0.resolveCalls } }

    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> CommandOutput {
        let call = Call(executable: executable, arguments: arguments, timeout: timeout)
        state.withLock { $0.calls.append(call) }
        onRun?(call)
        let key = ([executable] + arguments).joined(separator: " ")
        return outputs[key] ?? CommandOutput(status: 0, stdout: "", stderr: "")
    }

    func run(_ executable: String, _ arguments: [String], stdin: String?, workingDirectory: String?,
             timeout: TimeInterval) async throws -> CommandOutput {
        guard stdin == nil else {
            throw CommandError.launchFailed(executable: executable, message: "FakeRunner no admite stdin")
        }
        let call = Call(executable: executable, arguments: arguments, timeout: timeout,
                        workingDirectory: workingDirectory)
        state.withLock { $0.calls.append(call) }
        onRun?(call)
        let key = ([executable] + arguments).joined(separator: " ")
        return outputs[key] ?? CommandOutput(status: 0, stdout: "", stderr: "")
    }

    func resolve(_ executable: String) async -> String? {
        state.withLock { $0.resolveCalls.append(executable) }
        return resolved[executable]
    }
}

final class FakeProbes: SystemProbing, Sendable {
    let running: Set<String>
    let trash: Int64
    let trashReadable: Bool
    /// `true`: la lectura al momento de las apps abiertas falla (`currentRunningBundleIDs` = `nil`).
    let currentUnknown: Bool
    private let emptied = Mutex(0)

    init(running: Set<String> = [], trash: Int64 = 0, trashReadable: Bool = true, currentUnknown: Bool = false) {
        self.running = running
        self.trash = trash
        self.trashReadable = trashReadable
        self.currentUnknown = currentUnknown
    }

    var emptyCount: Int { emptied.withLock { $0 } }

    func runningBundleIDs() -> Set<String> { running }
    func currentRunningBundleIDs() -> Set<String>? { currentUnknown ? nil : running }
    func hasFullDiskAccess() -> Bool { true }
    func trashSize() -> Int64 { trash }
    func trashSizeIfReadable() -> Int64? { trashReadable ? trash : nil }
    func emptyTrash() async throws -> Int64 {
        emptied.withLock { $0 += 1 }
        return trash
    }
    func localSnapshots() async -> [String] { [] }
}

/// Espacio libre simulado: devuelve los valores en orden (el último se repite).
final class FakeFreeSpace: Sendable {
    private let values: Mutex<[Int64]>
    init(_ values: [Int64]) { self.values = Mutex(values) }
    func next() -> Int64 {
        values.withLock { v in v.count > 1 ? v.removeFirst() : (v.first ?? 0) }
    }
}

// MARK: - Utilidades

private func makeTempDir(_ label: String = "airy-cleanup") -> String {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(label)-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.path
}

private func makeDir(_ path: String) {
    try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
}

private func writeFile(_ path: String, bytes: Int = 10_000, text: String? = nil) {
    makeDir((path as NSString).deletingLastPathComponent)
    let data = text.map { Data($0.utf8) } ?? Data(repeating: 0x41, count: bytes)
    FileManager.default.createFile(atPath: path, contents: data)
}

private func exists(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0
}

private func entry(
    _ id: String, risk: Risk = .safe, paths: [String] = [], cleanup: CleanupMethod,
    mustBeClosed: [String] = [], referenceCheck: String? = nil
) -> CatalogEntry {
    CatalogEntry(
        id: id, title: "Prueba \(id)", explanation: "", whoCreatesIt: "", regenerates: true,
        risk: risk, kind: .caches, paths: paths, cleanup: cleanup,
        mustBeClosed: mustBeClosed, referenceCheck: referenceCheck)
}

private func item(
    _ entry: CatalogEntry, paths: [String] = [], bytes: Int64 = 1_000, risk: Risk? = nil,
    usedBy: [String] = []
) -> CleanupItem {
    CleanupItem(
        id: entry.id, entry: entry, paths: paths, bytes: bytes, risk: risk ?? entry.risk,
        blockedByOpenApps: [], usedBy: usedBy)
}

private func makeStore() -> IndexStore {
    IndexStore(directory: URL(fileURLWithPath: makeTempDir("airy-cleanup-store")))
}

private let uvEntry = entry(
    "uv", paths: ["~/.cache/uv"],
    cleanup: .command(executable: "uv", arguments: ["cache", "clean"], sizeProbe: nil))

private let dockerJSON = """
{"Active":"3","Reclaimable":"1.2GB (40%)","Size":"3GB","TotalCount":"10","Type":"Images"}
{"Active":"0","Reclaimable":"0B","Size":"0B","TotalCount":"0","Type":"Containers"}
{"Active":"1","Reclaimable":"500MB (50%)","Size":"1GB","TotalCount":"2","Type":"Local Volumes"}
{"Active":"0","Reclaimable":"29.89GB","Size":"29.89GB","TotalCount":"120","Type":"Build Cache"}
"""

private let dockerEntry: CatalogEntry = {
    var e = entry(
        "docker-build-cache",
        cleanup: .command(
            executable: "docker", arguments: ["builder", "prune", "-a", "-f"],
            sizeProbe: ["system", "df", "--format", "{{json .}}"]))
    e.discovery = .docker
    return e
}()

/// Docker en marcha (`DockerProbe`): versión, `df` y listados vacíos de contenedores y redes.
private func dockerRunning(df: CommandOutput = CommandOutput(status: 0, stdout: dockerJSON, stderr: "")) -> FakeRunner {
    let d = "/usr/local/bin/docker"
    return FakeRunner(resolved: ["docker": d], outputs: [
        "\(d) version --format {{.Server.Version}}": CommandOutput(status: 0, stdout: "27.3.1\n", stderr: ""),
        "\(d) system df --format {{json .}}": df,
    ])
}

private func scanner(
    _ entries: [CatalogEntry], home: String, runner: FakeRunner = FakeRunner(),
    probes: FakeProbes = FakeProbes(), roots: [String] = []
) -> CleanupScanner {
    CleanupScanner(
        catalog: Catalog(entries: entries), runner: runner, probes: probes,
        references: ReferenceChecker(roots: roots), home: home)
}

private func executor(
    runner: FakeRunner = FakeRunner(), probes: FakeProbes = FakeProbes(), store: IndexStore,
    home: String, freeSpace: FakeFreeSpace = FakeFreeSpace([0]), entries: [CatalogEntry] = [],
    roots: [String] = []
) -> CleanupExecutor {
    // La caché de uv existe en el home de prueba: un comando solo se ejecuta si su carpeta está en el disco.
    makeDir(home + "/.cache/uv")
    return CleanupExecutor(
        runner: runner, probes: probes, store: store,
        catalog: Catalog(entries: entries + [uvEntry, dockerEntry]),
        references: ReferenceChecker(roots: roots), home: home,
        freeSpace: { freeSpace.next() }, trashSettleDelay: .zero, settings: { .missing })
}

// MARK: - Tests del brief

@Suite struct CleanupTests {
    @Test func commandArgumentsAreNotShellInterpolated() async throws {
        let home = makeTempDir()
        let runner = FakeRunner(resolved: ["uv": "/opt/homebrew/bin/uv"])
        let exec = executor(runner: runner, store: makeStore(), home: home)
        let outcome = await exec.execute(item(uvEntry, paths: [home + "/.cache/uv"]))
        guard case .freed = outcome else { Issue.record("esperaba .freed, hubo \(outcome)"); return }
        #expect(runner.calls.map { [$0.executable] + $0.arguments } == [["/opt/homebrew/bin/uv", "cache", "clean"]])
    }

    @Test func realProcessRunnerPassesArgumentsLiterally() async throws {
        let runner = ProcessRunner()
        let weird = "Música ñ; $(echo PWNED) `id` && rm -rf ~ 'x' \"y\""
        let output = try await runner.run("/bin/echo", [weird, "Application Support"], timeout: 10)
        #expect(output.status == 0)
        #expect(output.stdout == weird + " Application Support\n")
    }

    @Test func blocksWhenAppOpen() async throws {
        let home = makeTempDir()
        let folder = home + "/Library/Caches/com.spotify.client"
        writeFile(folder + "/data.bin")
        let spotify = entry(
            "spotify-cache", risk: .yourCall, paths: ["~/Library/Caches/com.spotify.client"],
            cleanup: .trash, mustBeClosed: ["com.spotify.client"])
        let probes = FakeProbes(running: ["com.spotify.client"])
        let items = await scanner([spotify], home: home, probes: probes).findItems(scan: nil)
        #expect(items.count == 1)
        #expect(items.first?.blockedByOpenApps == ["com.spotify.client"])

        let store = makeStore()
        let outcome = await executor(probes: probes, store: store, home: home, entries: [spotify]).execute(items[0])
        guard case .blocked = outcome else { Issue.record("esperaba .blocked, hubo \(outcome)"); return }
        #expect(exists(folder))
        #expect(try store.history().isEmpty)
    }

    @Test func trashMovesNotDeletes() async throws {
        let folder = makeTempDir("DiskMapTest")
        writeFile(folder + "/payload.bin", bytes: 50_000)
        let home = makeTempDir()
        let store = makeStore()
        let e = entry("playwright", paths: [folder], cleanup: .trash)
        let outcome = await executor(store: store, home: home, entries: [e]).execute(item(e, paths: [folder]))
        guard case .movedToTrash(let n) = outcome else {
            Issue.record("esperaba .movedToTrash, hubo \(outcome)"); return
        }
        #expect(n > 0)
        #expect(!exists(folder))
        let history = try store.history()
        #expect(history.count == 1)
        #expect(history.first?.wentToTrash == true)
        #expect(try store.totalFreed() == 0)
    }

    @Test func doNotTouchIsNeverExecuted() async throws {
        let runner = FakeRunner(resolved: ["uv": "/opt/homebrew/bin/uv"])
        let store = makeStore()
        let outcome = await executor(runner: runner, store: store, home: makeTempDir())
            .execute(item(uvEntry, risk: .doNotTouch))
        guard case .blocked = outcome else { Issue.record("esperaba .blocked, hubo \(outcome)"); return }
        #expect(runner.calls.isEmpty)
        #expect(runner.resolveCalls.isEmpty)
        #expect(try store.history().isEmpty)
    }

    @Test func infoMethodIsNeverExecuted() async throws {
        let home = makeTempDir()
        let folder = home + "/.ollama/models"
        writeFile(folder + "/blob")
        let runner = FakeRunner()
        let e = entry("ollama-models", risk: .yourCall, paths: ["~/.ollama/models"], cleanup: .info)
        let outcome = await executor(runner: runner, store: makeStore(), home: home, entries: [e])
            .execute(item(e, paths: [folder]))
        guard case .blocked = outcome else { Issue.record("esperaba .blocked, hubo \(outcome)"); return }
        #expect(runner.calls.isEmpty)
        #expect(exists(folder))
    }

    // Tarea 2 del plan 3: la sonda es de `DockerProbe` (versión primero, luego `df`) y la ficha es discovery docker.
    @Test func dockerProbeParsesReclaimable() async throws {
        let runner = dockerRunning()
        let items = await scanner([dockerEntry], home: makeTempDir(), runner: runner).findItems(scan: nil)
        #expect(items.count == 1)
        #expect(items.first?.bytes == 29_890_000_000)
        #expect(items.first?.paths == [])
        #expect(runner.calls.prefix(2).map(\.arguments)
            == [["version", "--format", "{{.Server.Version}}"], ["system", "df", "--format", "{{json .}}"]])
    }

    @Test func dockerSizeParser() {
        #expect(CleanupScanner.parseDockerSize("29.89GB (86%)") == 29_890_000_000)
        #expect(CleanupScanner.parseDockerSize("500MB") == 500_000_000)
        #expect(CleanupScanner.parseDockerSize("1.5kB") == 1_500)
        #expect(CleanupScanner.parseDockerSize("0B") == 0)
        #expect(CleanupScanner.parseDockerSize("2TB") == 2_000_000_000_000)
        #expect(CleanupScanner.parseDockerSize("basura") == nil)
    }

    @Test func missingToolSkipsItem() async throws {
        let home = makeTempDir()
        writeFile(home + "/.cache/uv/wheel.whl")
        let runner = FakeRunner(resolved: [:])
        let items = await scanner([uvEntry], home: home, runner: runner).findItems(scan: nil)
        #expect(!items.contains { $0.entry.id == "uv" })
    }

    @Test func referencedModelEscalatesRisk() async throws {
        let home = makeTempDir()
        let hub = home + "/.cache/huggingface/hub"
        writeFile(hub + "/models--mlx-community--whisper-small-mlx/blobs/weights", bytes: 20_000)
        writeFile(hub + "/models--other--unused/blobs/weights", bytes: 20_000)
        let project = home + "/Projects/app"
        writeFile(project + "/config.toml", text: "model = \"mlx-community/whisper-small-mlx\"\n")
        let hf = entry(
            "huggingface-model", risk: .yourCall,
            paths: ["~/.cache/huggingface/hub/models--*", "~/.cache/huggingface/hub/datasets--*"],
            cleanup: .trash, referenceCheck: "{name}")
        let items = await scanner([hf], home: home, roots: [home + "/Projects"]).findItems(scan: nil)
        #expect(items.count == 2)
        let used = try #require(items.first { $0.id == "huggingface-model:models--mlx-community--whisper-small-mlx" })
        #expect(used.risk == .doNotTouch)
        #expect(used.usedBy == [project + "/config.toml"])
        let unused = try #require(items.first { $0.id == "huggingface-model:models--other--unused" })
        #expect(unused.risk == .yourCall)
        #expect(unused.usedBy.isEmpty)
    }

    @Test func recordsHistory() async throws {
        let store = makeStore()
        let runner = FakeRunner(resolved: ["uv": "/opt/homebrew/bin/uv"])
        _ = await executor(runner: runner, store: store, home: makeTempDir()).execute(item(uvEntry))
        let history = try store.history()
        #expect(history.count == 1)
        #expect(history.first?.wentToTrash == false)
    }
}

// MARK: - Reglas de seguridad del ejecutor

@Suite struct CleanupSafetyTests {
    // Regla 1: revalidación justo antes de actuar.
    @Test func recheckBlocksCommandWhosePathIsSystem() async throws {
        let runner = FakeRunner(resolved: ["uv": "/opt/homebrew/bin/uv"])
        let outcome = await executor(runner: runner, store: makeStore(), home: makeTempDir())
            .execute(item(uvEntry, paths: ["/System/Library/Caches"], risk: .safe))
        guard case .blocked = outcome else { Issue.record("esperaba .blocked, hubo \(outcome)"); return }
        #expect(runner.calls.isEmpty)
    }

    @Test func recheckBlocksSystemPathEvenIfItemSaysSafe() async throws {
        let e = entry("raro", paths: ["/System/Library/Caches"], cleanup: .trash)
        let outcome = await executor(store: makeStore(), home: makeTempDir(), entries: [e])
            .execute(item(e, paths: ["/System/Library/Caches"], risk: .safe))
        guard case .blocked = outcome else { Issue.record("esperaba .blocked, hubo \(outcome)"); return }
        #expect(exists("/System/Library/Caches"))
    }

    @Test func recheckBlocksWhenCatalogSaysDoNotTouch() async throws {
        let home = makeTempDir()
        let folder = home + "/.cache/codex-runtimes/codex-primary-runtime"
        writeFile(folder + "/bin")
        let live = entry("codex-runtime", risk: .doNotTouch, paths: [folder], cleanup: .trash)
        var stale = live
        stale.risk = .safe
        // El elemento llega con una ficha y un riesgo obsoletos: manda la ficha viva del catálogo.
        let outcome = await executor(store: makeStore(), home: home, entries: [live])
            .execute(item(stale, paths: [folder], risk: .safe))
        guard case .blocked = outcome else { Issue.record("esperaba .blocked, hubo \(outcome)"); return }
        #expect(exists(folder))
    }

    @Test func usedByBlocksEvenWithStaleRisk() async throws {
        let home = makeTempDir()
        let folder = home + "/.cache/huggingface/hub/models--a--b"
        writeFile(folder + "/w")
        let e = entry("huggingface-model", risk: .yourCall, paths: [folder], cleanup: .trash)
        let outcome = await executor(store: makeStore(), home: home, entries: [e])
            .execute(item(e, paths: [folder], risk: .yourCall, usedBy: ["/x/config.toml"]))
        guard case .blocked = outcome else { Issue.record("esperaba .blocked, hubo \(outcome)"); return }
        #expect(exists(folder))
    }

    @Test func commandBlockedWhenAppOpenWithoutCallingRunner() async throws {
        let runner = FakeRunner(resolved: ["uv": "/opt/homebrew/bin/uv"])
        var live = uvEntry
        live.mustBeClosed = ["com.example.app"]
        // El elemento no lista la app; la ficha viva sí.
        let outcome = await executor(
            runner: runner, probes: FakeProbes(running: ["com.example.app"]), store: makeStore(),
            home: makeTempDir(), entries: [live]
        ).execute(item(uvEntry))
        guard case .blocked = outcome else { Issue.record("esperaba .blocked, hubo \(outcome)"); return }
        #expect(runner.calls.isEmpty)
    }

    // Regla 2: validación de rutas para la Papelera.
    @Test func trashRefusesUnsafePaths() async throws {
        let base = makeTempDir()
        let home = base + "/casa"
        makeDir(home + "/Documents")
        makeDir(home + "/Desktop")
        let inside = home + "/Library/Caches/x"
        writeFile(inside + "/f")
        let exec = executor(store: makeStore(), home: home)
        let refused = [
            "relative/path",
            "",
            "/",
            home,
            home + "/",
            home + "/Documents",
            home + "/Desktop",
            home + "/Library",
            home + "/Library/Caches/x/../../Caches",
            home + "/./Library",
            home + "/Library//Caches/x",
            home + "/no-existe",
            base, // ancestro de home
            "/System/Library/Caches",
            "/System",
            "/Users",
            "/Applications",
        ]
        for path in refused {
            let outcome = await exec.trashPaths([path], title: "x")
            guard case .blocked = outcome else { Issue.record("debió bloquear \(path), hubo \(outcome)"); continue }
        }
        #expect(exists(home + "/Documents"))
        #expect(exists(inside))
        #expect(exists(base))
    }

    @Test func trashAllowsOrdinaryFolderInsideHome() async throws {
        let home = makeTempDir()
        let target = home + "/Library/Caches/DiskMapTest-\(UUID().uuidString)"
        writeFile(target + "/f")
        let outcome = await executor(store: makeStore(), home: home).trashPaths([target], title: "x")
        guard case .movedToTrash = outcome else { Issue.record("esperaba .movedToTrash, hubo \(outcome)"); return }
        #expect(!exists(target))
    }

    @Test func trashRefusesWholeBatchIfOnePathIsUnsafe() async throws {
        let home = makeTempDir()
        let ok = home + "/Library/Caches/ok"
        writeFile(ok + "/f")
        let outcome = await executor(store: makeStore(), home: home).trashPaths([ok, "/"], title: "x")
        guard case .blocked = outcome else { Issue.record("esperaba .blocked, hubo \(outcome)"); return }
        #expect(exists(ok))
    }

    @Test func symlinkIsTrashedAsLinkNotTarget() async throws {
        let target = makeTempDir("DiskMapTest-target")
        writeFile(target + "/keep.bin")
        let dir = makeTempDir("DiskMapTest-links")
        let link = dir + "/enlace"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        let store = makeStore()
        let outcome = await executor(store: store, home: makeTempDir()).trashPaths([link], title: "Enlace")
        guard case .movedToTrash = outcome else { Issue.record("esperaba .movedToTrash, hubo \(outcome)"); return }
        #expect(!exists(link))
        #expect(exists(target + "/keep.bin"))
    }

    @Test func trashPathsRefusesCatalogDoNotTouchAndItsAncestors() async throws {
        let home = makeTempDir()
        let runtime = home + "/.cache/codex-runtimes/codex-primary-runtime"
        writeFile(runtime + "/bin/tool")
        let codex = entry("codex-runtime", risk: .doNotTouch,
                          paths: ["~/.cache/codex-runtimes/codex-primary-runtime"], cleanup: .info)
        let exec = executor(store: makeStore(), home: home, entries: [codex])
        for path in [runtime, runtime + "/bin", home + "/.cache/codex-runtimes", home + "/.cache"] {
            let outcome = await exec.trashPaths([path], title: "x")
            guard case .blocked = outcome else { Issue.record("debió bloquear \(path), hubo \(outcome)"); continue }
        }
        #expect(exists(runtime + "/bin/tool"))
    }

    @Test func trashPathsRefusesProtectedLocationsAndTheirChildren() async throws {
        let home = makeTempDir()
        let exec = executor(store: makeStore(), home: home)
        let sealed = [
            "Library/Containers/com.docker.docker", "Library/Group Containers/group.com.docker",
            "Library/Mobile Documents", "Library/Mail", "Library/Messages", "Library/Keychains",
            "Library/Application Support/AddressBook", "Library/Calendars", "Library/Photos",
        ].map { home + "/" + $0 }
        for location in sealed {
            writeFile(location + "/hijo/f")
            for path in [location, location + "/hijo", location + "/hijo/f", (location as NSString).deletingLastPathComponent] {
                let outcome = await exec.trashPaths([path], title: "x")
                guard case .blocked = outcome else { Issue.record("debió bloquear \(path), hubo \(outcome)"); continue }
            }
            #expect(exists(location + "/hijo/f"))
        }
    }

    @Test func protectedSystemLocationsRefuseChildren() {
        let homes = ["/Users/prueba"]
        for path in ["/Applications/Safari.app", "/Library/Preferences", "/usr/local/bin", "/bin/ls", "/sbin/x",
                     "/private/etc/hosts", "/opt/homebrew/Cellar", "/Applications", "/opt",
                     "/Users/prueba/Library/Mobile Documents/x", "/Users/prueba/Library", "/Users/prueba"] {
            #expect(RiskPolicy.trashRefusal(forCanonicalPath: RiskPolicy.canonical(path), homes: homes) != nil, "\(path)")
        }
        for path in ["/Users/prueba/Library/Caches/x", "/Users/prueba/.cache/whisper", "/opt/otra/x"] {
            #expect(RiskPolicy.trashRefusal(forCanonicalPath: RiskPolicy.canonical(path), homes: homes) == nil, "\(path)")
        }
        // La carpeta temporal del usuario (dentro de /private) sí admite su contenido.
        let temp = RiskPolicy.userTemporaryDirectory
        #expect(RiskPolicy.trashRefusal(forCanonicalPath: temp + "/x", homes: homes) == nil)
        #expect(RiskPolicy.trashRefusal(forCanonicalPath: temp, homes: homes) != nil)
    }

    @Test func trashPathsRefusesFoldersOfCommandCleanups() async throws {
        let home = makeTempDir()
        writeFile(home + "/.cache/uv/wheels/f")
        let exec = executor(store: makeStore(), home: home)  // uv: solo con `uv cache clean`
        for path in [home + "/.cache/uv", home + "/.cache/uv/wheels", home + "/.cache"] {
            let outcome = await exec.trashPaths([path], title: "x")
            guard case .blocked = outcome else { Issue.record("debió bloquear \(path), hubo \(outcome)"); continue }
        }
        #expect(exists(home + "/.cache/uv/wheels/f"))
    }

    @Test func trashPathsRefusesAncestorOfDoNotTouchPatternEvenIfMissing() async throws {
        let home = makeTempDir()
        let parent = home + "/.cache/codex-runtimes"
        writeFile(parent + "/codex-runtime-install-1/f")
        let codex = entry("codex-runtime", risk: .doNotTouch,
                          paths: ["~/.cache/codex-runtimes/codex-primary-runtime"], cleanup: .info)
        let outcome = await executor(store: makeStore(), home: home, entries: [codex]).trashPaths([parent], title: "x")
        guard case .blocked = outcome else { Issue.record("esperaba .blocked, hubo \(outcome)"); return }
        #expect(exists(parent))
    }

    // C1: nunca se ejecuta algo que no sea la ficha viva del catálogo.
    @Test func unknownCatalogIdIsBlocked() async throws {
        let home = makeTempDir()
        writeFile(home + "/precioso.txt")
        let runner = FakeRunner(resolved: ["rm": "/bin/rm"])
        let forged = entry("x", cleanup: .command(executable: "rm", arguments: ["-rf", home], sizeProbe: nil))
        let outcome = await executor(runner: runner, store: makeStore(), home: home).execute(item(forged))
        guard case .blocked = outcome else { Issue.record("esperaba .blocked, hubo \(outcome)"); return }
        #expect(runner.calls.isEmpty)
        #expect(runner.resolveCalls.isEmpty)
        #expect(exists(home + "/precioso.txt"))
    }

    @Test func forgedCleanupUsesLiveCatalogCommand() async throws {
        let home = makeTempDir()
        let runner = FakeRunner(resolved: ["uv": "/opt/homebrew/bin/uv", "rm": "/bin/rm"])
        var forged = uvEntry
        forged.cleanup = .command(executable: "rm", arguments: ["-rf", home], sizeProbe: nil)
        _ = await executor(runner: runner, store: makeStore(), home: home).execute(item(forged))
        #expect(runner.calls.map { [$0.executable] + $0.arguments } == [["/opt/homebrew/bin/uv", "cache", "clean"]])
        #expect(!runner.resolveCalls.contains("rm"))
    }

    @Test func forgedTrashItemOfCommandEntryRunsOnlyTheCommand() async throws {
        let home = makeTempDir()
        writeFile(home + "/Documents/tesis.docx")
        let runner = FakeRunner(resolved: ["uv": "/opt/homebrew/bin/uv"])
        var forged = uvEntry
        forged.cleanup = .trash
        _ = await executor(runner: runner, store: makeStore(), home: home)
            .execute(item(forged, paths: [home + "/Documents/tesis.docx"]))
        #expect(exists(home + "/Documents/tesis.docx"))
    }

    @Test func trashItemPathsMustBelongToLiveEntry() async throws {
        let home = makeTempDir()
        let foreign = home + "/Library/Caches/otra-cosa"
        writeFile(foreign + "/f")
        let pw = entry("playwright", paths: ["~/Library/Caches/ms-playwright"], cleanup: .trash)
        let outcome = await executor(store: makeStore(), home: home, entries: [pw])
            .execute(item(pw, paths: [foreign]))
        guard case .blocked = outcome else { Issue.record("esperaba .blocked, hubo \(outcome)"); return }
        #expect(exists(foreign))
    }

    @Test func perFolderItemLooksUpEntryBeforeColon() async throws {
        let home = makeTempDir()
        let folder = home + "/.cache/huggingface/hub/models--a--b"
        writeFile(folder + "/w")
        let hf = entry("huggingface-model", risk: .yourCall, paths: ["~/.cache/huggingface/hub/models--*"],
                       cleanup: .trash, referenceCheck: "{name}")
        let it = CleanupItem(id: "huggingface-model:models--a--b", entry: hf, paths: [folder], bytes: 10,
                             risk: .yourCall, blockedByOpenApps: [], usedBy: [])
        let store = makeStore()
        let outcome = await executor(store: store, home: home, entries: [hf]).execute(it)
        guard case .movedToTrash = outcome else { Issue.record("esperaba .movedToTrash, hubo \(outcome)"); return }
        #expect(try store.history().first?.title == "Prueba huggingface-model: models--a--b")
    }

    // I1: las referencias se vuelven a comprobar al ejecutar.
    @Test func referencesAreRecheckedBeforeTrashing() async throws {
        let home = makeTempDir()
        let hub = home + "/.cache/huggingface/hub"
        let folder = hub + "/models--org--modelo"
        writeFile(folder + "/w")
        writeFile(home + "/Projects/app/config.toml", text: "model = \"org/modelo\"")
        let hf = entry("huggingface-model", risk: .yourCall, paths: ["~/.cache/huggingface/hub/models--*"],
                       cleanup: .trash, referenceCheck: "{name}")
        let exec = executor(store: makeStore(), home: home, entries: [hf], roots: [home + "/Projects"])
        // Desde el mapa (sin elemento), la carpeta, algo dentro y la carpeta superior.
        for path in [folder, folder + "/w", hub] {
            let outcome = await exec.trashPaths([path], title: "x")
            guard case .blocked(let reason) = outcome else { Issue.record("debió bloquear \(path), hubo \(outcome)"); continue }
            #expect(reason.contains("Lo usa"))
        }
        // Un elemento detectado antes de que existiera la referencia (usedBy vacío).
        let it = CleanupItem(id: "huggingface-model:models--org--modelo", entry: hf, paths: [folder], bytes: 10,
                             risk: .yourCall, blockedByOpenApps: [], usedBy: [])
        let outcome = await exec.execute(it)
        guard case .blocked = outcome else { Issue.record("esperaba .blocked, hubo \(outcome)"); return }
        #expect(exists(folder + "/w"))
    }

    // Defensa en profundidad: también las fichas con comando oficial y `referenceCheck` vuelven a
    // comprobar referencias al ejecutar (un `usedBy` vacío puede venir de una detección cancelada).
    @Test func referencesAreRecheckedBeforeRunningACommand() async throws {
        let home = makeTempDir()
        let folder = home + "/.cache/toolcache"
        writeFile(folder + "/w")
        writeFile(home + "/Projects/app/config.toml", text: "cache = \"toolcache\"")
        let tool = entry("toolcache", risk: .yourCall, paths: ["~/.cache/toolcache"],
                         cleanup: .command(executable: "tool", arguments: ["cache", "clean"], sizeProbe: nil),
                         referenceCheck: "{name}")
        let runner = FakeRunner(resolved: ["tool": "/opt/homebrew/bin/tool"])
        let used = executor(runner: runner, store: makeStore(), home: home, entries: [tool], roots: [home + "/Projects"])
        let outcome = await used.execute(item(tool, paths: [folder], usedBy: []))
        guard case .blocked(let reason) = outcome else { Issue.record("esperaba .blocked, hubo \(outcome)"); return }
        #expect(reason.contains("Lo usa"))
        #expect(runner.calls.isEmpty)

        // Sin referencias, el comando sí se ejecuta.
        let free = executor(runner: runner, store: makeStore(), home: home, entries: [tool], roots: [home + "/Vacío"])
        _ = await free.execute(item(tool, paths: [folder], usedBy: []))
        #expect(runner.calls.count == 1)
    }

    // I5: revalidación de cada ruta justo antes de moverla.
    @Test func eachPathIsRevalidatedRightBeforeMoving() async throws {
        let home = makeTempDir()
        let outer = home + "/Library/Caches/DiskMapTest-\(UUID().uuidString)"
        let inner = outer + "/dentro"
        writeFile(inner + "/f")
        // Al mover `outer`, `inner` deja de existir: debe detectarse antes de intentar moverla.
        let outcome = await executor(store: makeStore(), home: home).trashPaths([outer, inner], title: "x")
        guard case .blocked(let reason) = outcome else { Issue.record("esperaba .blocked, hubo \(outcome)"); return }
        #expect(reason.contains("No existe"))
    }

    // Regla 3: comandos con array de argumentos y timeout.
    @Test func commandUsesDefaultTimeoutOf600Seconds() async throws {
        let runner = FakeRunner(resolved: ["uv": "/opt/homebrew/bin/uv"])
        _ = await executor(runner: runner, store: makeStore(), home: makeTempDir()).execute(item(uvEntry))
        #expect(runner.calls.first?.timeout == 600)
    }

    @Test func processRunnerKillsOnTimeout() async throws {
        let runner = ProcessRunner()
        let start = Date()
        await #expect(throws: CommandError.self) {
            _ = try await runner.run("/bin/sleep", ["30"], timeout: 0.5)
        }
        #expect(Date().timeIntervalSince(start) < 10)
    }

    @Test func processRunnerReturnsWhenGrandchildHoldsOutput() async throws {
        // /bin/sh como ejecutable solo en la prueba, para crear un nieto que hereda stdout.
        let start = Date()
        let output = try await ProcessRunner().run("/bin/sh", ["-c", "sleep 30 & echo hola"], timeout: 1)
        #expect(Date().timeIntervalSince(start) < 3)
        #expect(output.stdout == "hola\n")
    }

    @Test func processRunnerTimeoutKillsWholeProcessGroup() async throws {
        let pidFile = makeTempDir() + "/nieto.pid"
        let start = Date()
        await #expect(throws: CommandError.self) {
            _ = try await ProcessRunner().run("/bin/sh", ["-c", "sleep 30 & echo $! > \"$0\"; wait", pidFile],
                                              timeout: 0.5)
        }
        #expect(Date().timeIntervalSince(start) < 2.5)
        let pidText = try String(contentsOfFile: pidFile, encoding: .utf8)
        let grandchild = try #require(pid_t(pidText.trimmingCharacters(in: .whitespacesAndNewlines)))
        var alive = true
        for _ in 0..<50 where alive {
            alive = kill(grandchild, 0) == 0
            if alive { usleep(20_000) }
        }
        #expect(!alive)
    }

    @Test func processRunnerReportsExitStatusAndStderr() async throws {
        let output = try await ProcessRunner().run("/bin/sh", ["-c", "echo mal >&2; exit 3"], timeout: 5)
        #expect(output.status == 3)
        #expect(output.stderr == "mal\n")
    }

    @Test func processRunnerResolvesFromSearchPath() async throws {
        let dir = makeTempDir()
        let tool = dir + "/herramienta"
        writeFile(tool, text: "#!/bin/sh\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool)
        writeFile(dir + "/noejecutable", text: "x")
        let runner = ProcessRunner(searchPath: [dir + "/vacio", dir])
        #expect(await runner.resolve("herramienta") == tool)
        #expect(await runner.resolve("noejecutable") == nil)
        #expect(await runner.resolve("inexistente-airy") == nil)
    }

    // Sin shell de login: el PATH sale de /etc/paths, /etc/paths.d, el entorno de la app y el respaldo.
    @Test func systemSearchPathReadsEtcPathsWithoutShell() throws {
        let dir = makeTempDir()
        writeFile(dir + "/paths", text: "/usr/local/bin\n/usr/bin\n\n  /bin  \nrelativa/bin\n")
        writeFile(dir + "/paths.d/20-b", text: "/opt/b/bin\n")
        writeFile(dir + "/paths.d/10-a", text: "/opt/a/bin\n/usr/bin\n")
        writeFile(dir + "/paths.d/.oculto", text: "/opt/oculto\n")
        let dirs = ProcessRunner.systemSearchPath(
            home: "/Users/prueba", environmentPath: "/env/bin:/usr/bin:",
            etcPaths: dir + "/paths", etcPathsDirectory: dir + "/paths.d")
        #expect(Array(dirs.prefix(6)) == ["/usr/local/bin", "/usr/bin", "/bin", "/opt/a/bin", "/opt/b/bin", "/env/bin"])
        #expect(!dirs.contains("/opt/oculto"))
        #expect(!dirs.contains("relativa/bin"))
        #expect(dirs.contains("/Users/prueba/anaconda3/bin"))
        #expect(dirs.contains("/Users/prueba/Library/pnpm"))
        #expect(Set(dirs).count == dirs.count)
        // Sin ficheros ni entorno, al menos el respaldo.
        let bare = ProcessRunner.systemSearchPath(home: "/Users/prueba", environmentPath: nil,
                                                  etcPaths: dir + "/no", etcPathsDirectory: dir + "/no.d")
        #expect(bare == ProcessRunner.fallbackDirectories(home: "/Users/prueba"))
    }

    @Test func processRunnerResolvesSystemToolsByDefault() async throws {
        // /etc/paths siempre trae /bin en macOS.
        #expect(await ProcessRunner().resolve("ls") == "/bin/ls")
    }

    @Test func processRunnerFallbackDirsExpandHome() {
        let dirs = ProcessRunner.fallbackDirectories(home: "/Users/prueba")
        #expect(dirs.contains("/Users/prueba/anaconda3/bin"))
        #expect(dirs.contains("/opt/homebrew/bin"))
        #expect(dirs.contains("/Users/prueba/Library/pnpm"))
    }

    @Test func missingExecutableAtRunTimeFails() async throws {
        let runner = FakeRunner(resolved: [:])
        let store = makeStore()
        let outcome = await executor(runner: runner, store: store, home: makeTempDir()).execute(item(uvEntry))
        guard case .failed = outcome else { Issue.record("esperaba .failed, hubo \(outcome)"); return }
        #expect(runner.calls.isEmpty)
        #expect(try store.history().isEmpty)
    }

    @Test func commandFailureIsNotRecorded() async throws {
        let runner = FakeRunner(
            resolved: ["uv": "/opt/homebrew/bin/uv"],
            outputs: ["/opt/homebrew/bin/uv cache clean": CommandOutput(status: 2, stdout: "", stderr: "boom")])
        let store = makeStore()
        let outcome = await executor(runner: runner, store: store, home: makeTempDir()).execute(item(uvEntry))
        guard case .failed = outcome else { Issue.record("esperaba .failed, hubo \(outcome)"); return }
        #expect(try store.history().isEmpty)
    }

    // Regla 4: liberado = diferencia de espacio libre del volumen, con suelo 0.
    @Test func freedIsVolumeDelta() async throws {
        let runner = FakeRunner(resolved: ["uv": "/opt/homebrew/bin/uv"])
        let store = makeStore()
        let outcome = await executor(
            runner: runner, store: store, home: makeTempDir(), freeSpace: FakeFreeSpace([1_000, 1_250])
        ).execute(item(uvEntry))
        guard case .freed(let bytes) = outcome else { Issue.record("esperaba .freed, hubo \(outcome)"); return }
        #expect(bytes == 250)
        #expect(try store.history().first?.bytes == 250)
    }

    @Test func freedIsFlooredAtZero() async throws {
        let runner = FakeRunner(resolved: ["uv": "/opt/homebrew/bin/uv"])
        let outcome = await executor(
            runner: runner, store: makeStore(), home: makeTempDir(), freeSpace: FakeFreeSpace([1_000, 400])
        ).execute(item(uvEntry))
        guard case .freed(let bytes) = outcome else { Issue.record("esperaba .freed, hubo \(outcome)"); return }
        #expect(bytes == 0)
    }

    // Regla 5: historial.
    @Test func emptyTrashRecordsAsFreed() async throws {
        let store = makeStore()
        let probes = FakeProbes(trash: 4_096)
        let outcome = await executor(probes: probes, store: store, home: makeTempDir(),
                                     freeSpace: FakeFreeSpace([10_000, 14_096])).emptyTrash()
        guard case .freed(let bytes) = outcome else { Issue.record("esperaba .freed, hubo \(outcome)"); return }
        #expect(bytes == 4_096)
        #expect(probes.emptyCount == 1)
        let history = try store.history()
        #expect(history.count == 1)
        #expect(history.first?.wentToTrash == false)
        #expect(try store.totalFreed() == 4_096)
    }

    // Lo anotado al vaciar es la subida medida del espacio libre (como la celebración), no lo que
    // ocupaba la Papelera: con instantáneas locales, macOS retiene parte.
    @Test func emptyTrashRecordsMeasuredFreeSpaceRise() async throws {
        let store = makeStore()
        let probes = FakeProbes(trash: 10_000)
        // Antes 1 000; después 2 000 y, tras esperar, 3 000 (se queda ahí).
        let outcome = await executor(probes: probes, store: store, home: makeTempDir(),
                                     freeSpace: FakeFreeSpace([1_000, 2_000, 3_000])).emptyTrash()
        guard case .freed(let bytes) = outcome else { Issue.record("esperaba .freed, hubo \(outcome)"); return }
        #expect(bytes == 2_000)
        #expect(try store.totalFreed() == 2_000)
        #expect(try store.history().first?.title == "Vaciar Papelera")
    }

    @Test func wouldRefuseTrashMatchesExecutorRules() async throws {
        let home = makeTempDir()
        writeFile(home + "/.cache/uv/blob")
        writeFile(home + "/Library/Caches/otra/x")
        writeFile(home + "/Documents/informe.txt")
        let exec = executor(store: makeStore(), home: home)
        // Caché con comando oficial: solo con su comando.
        #expect(exec.wouldRefuseTrash(path: home + "/.cache/uv"))
        #expect(exec.wouldRefuseTrash(path: home + "/.cache/uv/blob"))
        // Carpetas protegidas hacia arriba y rutas que no existen.
        #expect(exec.wouldRefuseTrash(path: home + "/Library"))
        #expect(exec.wouldRefuseTrash(path: home + "/Documents"))
        #expect(exec.wouldRefuseTrash(path: home + "/no-existe"))
        #expect(exec.wouldRefuseTrash(path: "/System/Library"))
        // Lo demás sí puede ir a la Papelera (con confirmación).
        #expect(!exec.wouldRefuseTrash(path: home + "/Library/Caches/otra"))
        #expect(!exec.wouldRefuseTrash(path: home + "/Documents/informe.txt"))
    }
}

// MARK: - Detección

@Suite struct CleanupScannerTests {
    @Test func globAggregatesMatchesIntoOneItem() async throws {
        let home = makeTempDir()
        writeFile(home + "/Library/Logs/A/a.log")
        writeFile(home + "/Library/Logs/B/b.log")
        let logs = entry("user-logs", paths: ["~/Library/Logs/*"], cleanup: .trash)
        let items = await scanner([logs], home: home).findItems(scan: nil)
        #expect(items.count == 1)
        #expect(items.first?.id == "user-logs")
        #expect(Set(items.first?.paths ?? []) == [home + "/Library/Logs/A", home + "/Library/Logs/B"])
        #expect((items.first?.bytes ?? 0) > 0)
    }

    @Test func patternWithoutMatchesContributesNothing() async throws {
        let home = makeTempDir()
        let e = entry("playwright", paths: ["~/Library/Caches/ms-playwright"], cleanup: .trash)
        #expect(await scanner([e], home: home).findItems(scan: nil).isEmpty)
    }

    @Test func sizeComesFromScanIndexWhenAvailable() async throws {
        let home = makeTempDir()
        writeFile(home + "/Library/Caches/ms-playwright/x")
        let pw = FileNode(name: "ms-playwright", isDirectory: true, allocatedSize: 123_456)
        let caches = FileNode(name: "Caches", isDirectory: true, allocatedSize: 123_456, children: [pw])
        let library = FileNode(name: "Library", isDirectory: true, allocatedSize: 123_456, children: [caches])
        let root = FileNode(name: home, isDirectory: true, allocatedSize: 123_456, children: [library])
        let multi = FileNode(name: "", isDirectory: true, children: [FileNode(name: "/otro", isDirectory: true), root])
        let e = entry("playwright", paths: ["~/Library/Caches/ms-playwright"], cleanup: .trash)
        let items = await scanner([e], home: home).findItems(scan: multi)
        #expect(items.first?.bytes == 123_456)
    }

    @Test func zeroByteItemsAreOmitted() async throws {
        let home = makeTempDir()
        writeFile(home + "/Library/Caches/ms-playwright/x")
        let pw = FileNode(name: "ms-playwright", isDirectory: true, allocatedSize: 0)
        let caches = FileNode(name: "Caches", isDirectory: true, children: [pw])
        let library = FileNode(name: "Library", isDirectory: true, children: [caches])
        let root = FileNode(name: home, isDirectory: true, children: [library])
        let e = entry("playwright", paths: ["~/Library/Caches/ms-playwright"], cleanup: .trash)
        #expect(await scanner([e], home: home).findItems(scan: root).isEmpty)
    }

    @Test func commandWithoutProbeUsesPathSize() async throws {
        let home = makeTempDir()
        writeFile(home + "/.cache/uv/wheel.whl", bytes: 40_000)
        let runner = FakeRunner(resolved: ["uv": "/opt/homebrew/bin/uv"])
        let items = await scanner([uvEntry], home: home, runner: runner).findItems(scan: nil)
        #expect(items.count == 1)
        #expect((items.first?.bytes ?? 0) >= 40_000)
        #expect(items.first?.paths == [home + "/.cache/uv"])
        #expect(runner.calls.isEmpty) // detectar nunca ejecuta la limpieza
    }

    // Tarea 2 del plan 3: las imágenes pasan a ser un comando (`image prune -a -f`) medido por `Reclaimable`;
    // los volúmenes siguen siendo solo informativos y nunca se ejecutan.
    @Test func dockerImagesAndVolumesAppearAsInfo() async throws {
        let catalog = try Catalog.bundled()
        let ids = ["docker-build-cache", "docker-images", "docker-volumes"]
        let entries = try ids.map { try #require(catalog.entry(id: $0)) }
        let runner = dockerRunning()
        let items = await scanner(entries, home: makeTempDir(), runner: runner).findItems(scan: nil)
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        #expect(byID["docker-build-cache"]?.bytes == 29_890_000_000)
        #expect(byID["docker-images"]?.bytes == 1_200_000_000)
        #expect(byID["docker-images"]?.entry.cleanup
            == .command(executable: "docker", arguments: ["image", "prune", "-a", "-f"], sizeProbe: nil))
        #expect(byID["docker-volumes"]?.bytes == 1_000_000_000)
        #expect(byID["docker-volumes"]?.risk == .doNotTouch)
        let probes = runner.calls.count

        let volumes = try #require(byID["docker-volumes"])
        let exec = CleanupExecutor(
            runner: runner, probes: FakeProbes(), store: makeStore(), catalog: catalog,
            references: ReferenceChecker(roots: []), home: makeTempDir(), settings: { .missing })
        guard case .blocked = await exec.execute(volumes) else { Issue.record("volúmenes no bloqueados"); return }
        #expect(runner.calls.count == probes)
    }

    // Tarea 2 del plan 3: con el demonio caído la ficha de comando sale bloqueada (sin tamaño), no se omite.
    @Test func dockerOmittedWhenDaemonDown() async throws {
        let runner = dockerRunning(df: CommandOutput(status: 1, stdout: "", stderr: "Cannot connect to the Docker daemon"))
        let down = await scanner([dockerEntry], home: makeTempDir(), runner: runner).findItems(scan: nil)
        #expect(down.map(\.blockedReason) == [DockerProbe.unavailableMessage])
        #expect(down.first?.bytes == 0)
        let noDocker = FakeRunner(resolved: [:])
        #expect(await scanner([dockerEntry], home: makeTempDir(), runner: noDocker).findItems(scan: nil).isEmpty)
        #expect(noDocker.calls.isEmpty)
    }

    @Test func unmeasurableEntriesAreOmitted() async throws {
        let catalog = try Catalog.bundled()
        let tm = try #require(catalog.entry(id: "time-machine-snapshots"))
        let sim = try #require(catalog.entry(id: "xcode-simulators"))
        let runner = FakeRunner(
            resolved: ["tmutil": "/usr/bin/tmutil", "xcrun": "/usr/bin/xcrun"],
            outputs: ["/usr/bin/tmutil listlocalsnapshots /":
                CommandOutput(status: 0, stdout: "Snapshots for disk /:\ncom.apple.TimeMachine.2026-10-20-101010.local\n", stderr: "")])
        let items = await scanner([tm, sim], home: makeTempDir(), runner: runner).findItems(scan: nil)
        #expect(items.isEmpty)
    }

    // Antes no tenía carpeta que medir y no aparecía nunca.
    @Test func simulatorsAppearWhenDevicesFolderExists() async throws {
        let catalog = try Catalog.bundled()
        let sim = try #require(catalog.entry(id: "xcode-simulators"))
        let home = makeTempDir()
        writeFile(home + "/Library/Developer/CoreSimulator/Devices/ABCD/data.img", bytes: 40_000)
        let runner = FakeRunner(resolved: ["xcrun": "/usr/bin/xcrun"])
        let items = await scanner([sim], home: home, runner: runner).findItems(scan: nil)
        let found = try #require(items.first)
        #expect(found.paths == [home + "/Library/Developer/CoreSimulator/Devices"])
        #expect(found.bytes >= 40_000)
        #expect(CleanupBoard.isPartial(found))
        #expect(CleanupBoard.sizeText(found).hasPrefix("hasta "))
        // Solo se mide: nunca se ejecuta el comando al detectar.
        #expect(runner.calls.isEmpty)
    }

    @Test func openAppsAreReportedAndRiskUsesPolicy() async throws {
        let home = makeTempDir()
        writeFile(home + "/Library/Caches/Google/Chrome/x", bytes: 20_000)
        let chrome = entry("chrome-cache", paths: ["~/Library/Caches/Google/Chrome"], cleanup: .trash,
                           mustBeClosed: ["com.google.Chrome"])
        let items = await scanner([chrome], home: home, probes: FakeProbes(running: ["com.google.Chrome", "x"]))
            .findItems(scan: nil)
        #expect(items.first?.blockedByOpenApps == ["com.google.Chrome"])
        #expect(items.first?.risk == .safe)
    }

    @Test func bundledCatalogOnEmptyHomeFindsNothingAndRunsNoCleanup() async throws {
        let runner = FakeRunner(resolved: [:])
        let items = await CleanupScanner(
            catalog: try Catalog.bundled(), runner: runner, probes: FakeProbes(),
            references: ReferenceChecker(roots: []), home: makeTempDir()
        ).findItems(scan: nil)
        #expect(items.isEmpty)
        #expect(runner.calls.isEmpty)
    }
}

// MARK: - Referencias y sondas

@Suite struct ReferenceAndProbeTests {
    @Test func referenceCheckerSkipsExcludedDirsSymlinksAndBigFiles() async throws {
        let root = makeTempDir()
        writeFile(root + "/a/ok.txt", text: "usa org/modelo aquí")
        writeFile(root + "/node_modules/x.txt", text: "org/modelo")
        writeFile(root + "/sub/.git/config", text: "org/modelo")
        writeFile(root + "/sub/Library/y.txt", text: "org/modelo")
        var big = String(repeating: "x", count: 1_100_000)
        big += "org/modelo"
        writeFile(root + "/big.txt", text: big)
        let outside = makeTempDir()
        writeFile(outside + "/z.txt", text: "org/modelo")
        try FileManager.default.createSymbolicLink(atPath: root + "/enlace", withDestinationPath: outside)
        try FileManager.default.createSymbolicLink(atPath: root + "/enlace.txt", withDestinationPath: outside + "/z.txt")
        let found = await ReferenceChecker(roots: [root]).references(to: "org/modelo", timeout: 10)
        #expect(found == [root + "/a/ok.txt"])
    }

    @Test func referenceCheckerDefaultRootsOnlyExisting() {
        let home = makeTempDir()
        makeDir(home + "/Projects")
        makeDir(home + "/orca")
        let roots = ReferenceChecker.defaultRoots(home: home)
        #expect(roots == [home + "/Projects", home + "/orca"])
    }

    @Test func probesTrashSizeAndEmptyUseInjectedHome() async throws {
        let home = makeTempDir()
        writeFile(home + "/.Trash/viejo.bin", bytes: 30_000)
        writeFile(home + "/.Trash/carpeta/otro.bin", bytes: 30_000)
        let probes = SystemProbes(home: home, runner: FakeRunner(), allowFinderFallback: false)
        let size = probes.trashSize()
        #expect(size >= 60_000)
        let freed = try await probes.emptyTrash()
        #expect(freed == size)
        #expect(try FileManager.default.contentsOfDirectory(atPath: home + "/.Trash").isEmpty)
        #expect(SystemProbes(home: makeTempDir(), runner: FakeRunner(), allowFinderFallback: false).trashSize() == 0)
    }

    @Test func trashSizeIfReadableDistinguishesUnreadable() throws {
        let home = makeTempDir()
        let probes = SystemProbes(home: home, runner: FakeRunner(), allowFinderFallback: false)
        // Sin ~/.Trash: se puede saber, y es 0.
        #expect(probes.trashSizeIfReadable() == 0)
        writeFile(home + "/.Trash/viejo.bin", bytes: 30_000)
        #expect((probes.trashSizeIfReadable() ?? 0) >= 30_000)
        // Sin permiso para listarla (como sin Acceso total al disco): nil, no 0.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: home + "/.Trash")
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home + "/.Trash") }
        #expect(probes.trashSizeIfReadable() == nil)
        #expect(probes.trashSize() == 0)
    }

    @Test func fakeProbesReportUnreadableTrash() {
        #expect(FakeProbes(trash: 5).trashSizeIfReadable() == 5)
        #expect(FakeProbes(trash: 5, trashReadable: false).trashSizeIfReadable() == nil)
    }

    @Test func emptyTrashRefusesSymlinkedTrash() async throws {
        let home = makeTempDir()
        let precious = makeTempDir()
        writeFile(precious + "/importante.txt")
        try FileManager.default.createSymbolicLink(atPath: home + "/.Trash", withDestinationPath: precious)
        let runner = FakeRunner()
        let probes = SystemProbes(home: home, runner: runner, allowFinderFallback: true)
        await #expect(throws: (any Error).self) { _ = try await probes.emptyTrash() }
        #expect(exists(precious + "/importante.txt"))
        #expect(runner.calls.isEmpty)
    }

    @Test func emptyTrashRemovesLinksNotTargets() async throws {
        let home = makeTempDir()
        let precious = makeTempDir()
        writeFile(precious + "/importante.txt")
        makeDir(home + "/.Trash")
        try FileManager.default.createSymbolicLink(atPath: home + "/.Trash/enlace", withDestinationPath: precious)
        _ = try await SystemProbes(home: home, runner: FakeRunner(), allowFinderFallback: false).emptyTrash()
        #expect(!exists(home + "/.Trash/enlace"))
        #expect(exists(precious + "/importante.txt"))
    }

    @Test func finderFallbackGoesThroughRunnerWithTimeout() async throws {
        let home = makeTempDir()
        writeFile(home + "/.Trash/x.bin")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: home + "/.Trash")
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home + "/.Trash") }
        let runner = FakeRunner()
        _ = try await SystemProbes(home: home, runner: runner, allowFinderFallback: true).emptyTrash()
        #expect(runner.calls == [FakeRunner.Call(
            executable: "/usr/bin/osascript", arguments: ["-e", "tell application \"Finder\" to empty trash"],
            timeout: 60)])
    }

    @Test func fullDiskAccessDetection() throws {
        let readable = makeTempDir()
        let denied = makeTempDir()
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: denied)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: denied) }
        #expect(SystemProbes.checkFullDiskAccess(candidates: [readable + "/nope", readable]) == true)
        #expect(SystemProbes.checkFullDiskAccess(candidates: [denied, readable]) == false)
    }

    @Test func localSnapshotsParsesTmutil() async {
        let runner = FakeRunner(
            resolved: ["tmutil": "/usr/bin/tmutil"],
            outputs: ["/usr/bin/tmutil listlocalsnapshots /": CommandOutput(
                status: 0,
                stdout: "Snapshots for disk /:\ncom.apple.TimeMachine.2026-10-20-101010.local\ncom.apple.TimeMachine.2026-10-20-111111.local\n",
                stderr: "")])
        let probes = SystemProbes(home: makeTempDir(), runner: runner, allowFinderFallback: false)
        #expect(await probes.localSnapshots() == [
            "com.apple.TimeMachine.2026-10-20-101010.local", "com.apple.TimeMachine.2026-10-20-111111.local",
        ])
    }

    @Test func allocatedSizeDoesNotFollowSymlinks() throws {
        let dir = makeTempDir()
        writeFile(dir + "/real.bin", bytes: 100_000)
        let other = makeTempDir()
        writeFile(other + "/huge.bin", bytes: 1_000_000)
        try FileManager.default.createSymbolicLink(atPath: dir + "/enlace", withDestinationPath: other)
        let size = try #require(AllocatedSize.of(dir))
        #expect(size >= 100_000)
        #expect(size < 1_000_000)
        #expect(AllocatedSize.of(dir + "/no-existe") == nil)
    }
}

// MARK: - Árbol al día tras una limpieza

@Suite struct ScanTreeRefreshTests {
    /// Árbol `home → .cache → uv (con dos hijos)` con tamaños de antes de limpiar.
    private func staleTree(home: String, uvBytes: Int64) -> (root: FileNode, uv: FileNode) {
        let cachesIndex = ContentKind.allCases.firstIndex(of: .caches)!
        func kb(_ bytes: Int64) -> [Int64] {
            var v = Array(repeating: Int64(0), count: ContentKind.allCases.count); v[cachesIndex] = bytes; return v
        }
        let a = FileNode(name: "a", isDirectory: false, allocatedSize: uvBytes / 2, kind: .caches, kindBytes: kb(uvBytes / 2))
        let b = FileNode(name: "b", isDirectory: false, allocatedSize: uvBytes / 2, kind: .caches, kindBytes: kb(uvBytes / 2))
        let uv = FileNode(name: "uv", isDirectory: true, allocatedSize: uvBytes, kind: .caches, kindBytes: kb(uvBytes),
                          children: [a, b], descendantCount: 2)
        let other = FileNode(name: "otro.txt", isDirectory: false, allocatedSize: 1_000, kind: .documents,
                             kindBytes: { var v = kb(0); v[ContentKind.allCases.firstIndex(of: .documents)!] = 1_000; return v }())
        let cache = FileNode(name: ".cache", isDirectory: true, allocatedSize: uvBytes, kind: .caches, kindBytes: kb(uvBytes),
                             children: [uv], descendantCount: 3)
        var rootKinds = kb(uvBytes); rootKinds[ContentKind.allCases.firstIndex(of: .documents)!] = 1_000
        let root = FileNode(name: home, isDirectory: true, allocatedSize: uvBytes + 1_000, kindBytes: rootKinds,
                            children: [cache, other], descendantCount: 5)
        return (root, uv)
    }

    // Hallazgo: tras `uv cache clean` la carpeta sigue existiendo y la detección cogía el tamaño
    // del árbol (el de antes): volvía a salir con su tamaño viejo.
    @Test func commandItemWhoseFolderStillExistsDoesNotComeBackAtOldSize() async throws {
        let home = makeTempDir()
        writeFile(home + "/.cache/uv/queda.bin", bytes: 8_192)
        let stale: Int64 = 5_000_000_000
        let (root, uv) = staleTree(home: home, uvBytes: stale)
        let runner = FakeRunner(resolved: ["uv": "/opt/homebrew/bin/uv"])
        let before = await scanner([uvEntry], home: home, runner: runner).findItems(scan: root)
        #expect(before.first?.bytes == stale)

        let measured = ScanTreeRefresh.measure([home + "/.cache/uv"])
        let now = try #require(measured.first?.bytes)
        #expect(now > 0 && now < 1_000_000)
        #expect(ScanTreeRefresh.apply(measured, to: root))

        #expect(uv.allocatedSize == now)
        #expect(uv.children.isEmpty)
        #expect(root.allocatedSize == now + 1_000)
        #expect(root.descendantCount == 3)
        #expect(root.kindBytes[ContentKind.allCases.firstIndex(of: .caches)!] == now)
        let after = await scanner([uvEntry], home: home, runner: runner).findItems(scan: root)
        #expect(after.first?.bytes == now)
    }

    @Test func goneFolderIsRemovedFromTree() async throws {
        let home = makeTempDir()
        let (root, _) = staleTree(home: home, uvBytes: 4_000)
        let measured = ScanTreeRefresh.measure([home + "/.cache/uv"])
        #expect(measured == [ScanTreeRefresh.Measurement(path: home + "/.cache/uv", bytes: nil)])
        #expect(ScanTreeRefresh.apply(measured, to: root))
        #expect(CleanupScanner.node(at: home + "/.cache/uv", in: root) == nil)
        #expect(root.allocatedSize == 1_000)
        #expect(root.descendantCount == 2)
        let items = await scanner([uvEntry], home: home, runner: FakeRunner(resolved: ["uv": "/x/uv"])).findItems(scan: root)
        #expect(items.isEmpty)
    }

    @Test func unchangedOrUnknownPathsLeaveTreeAlone() {
        let home = "/Users/nadie"
        let (root, uv) = staleTree(home: home, uvBytes: 4_000)
        #expect(!ScanTreeRefresh.apply([.init(path: home + "/.cache/uv", bytes: 4_000)], to: root))
        #expect(uv.children.count == 2)
        #expect(!ScanTreeRefresh.apply([.init(path: "/fuera/del/arbol", bytes: nil)], to: root))
        #expect(!ScanTreeRefresh.apply([.init(path: home, bytes: nil)], to: root))
        #expect(root.allocatedSize == 5_000)
    }
}
