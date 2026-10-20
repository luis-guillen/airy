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
    }

    private let state = Mutex<(calls: [Call], resolveCalls: [String])>(([], []))
    let resolved: [String: String]
    let outputs: [String: CommandOutput]

    /// `outputs` se indexa por "ejecutable argumentos…" (ruta resuelta y argumentos unidos por espacios).
    init(resolved: [String: String] = [:], outputs: [String: CommandOutput] = [:]) {
        self.resolved = resolved
        self.outputs = outputs
    }

    var calls: [Call] { state.withLock { $0.calls } }
    var resolveCalls: [String] { state.withLock { $0.resolveCalls } }

    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> CommandOutput {
        state.withLock { $0.calls.append(Call(executable: executable, arguments: arguments, timeout: timeout)) }
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
    private let emptied = Mutex(0)

    init(running: Set<String> = [], trash: Int64 = 0) {
        self.running = running
        self.trash = trash
    }

    var emptyCount: Int { emptied.withLock { $0 } }

    func runningBundleIDs() -> Set<String> { running }
    func hasFullDiskAccess() -> Bool { true }
    func trashSize() -> Int64 { trash }
    func emptyTrash() throws -> Int64 {
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

private func makeTempDir(_ label: String = "diskmap-cleanup") -> String {
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
    IndexStore(directory: URL(fileURLWithPath: makeTempDir("diskmap-cleanup-store")))
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

private let dockerEntry = entry(
    "docker-build-cache",
    cleanup: .command(
        executable: "docker", arguments: ["builder", "prune", "-a", "-f"],
        sizeProbe: ["system", "df", "--format", "{{json .}}"]))

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
    home: String, freeSpace: FakeFreeSpace = FakeFreeSpace([0])
) -> CleanupExecutor {
    CleanupExecutor(
        runner: runner, probes: probes, store: store, home: home,
        freeSpace: { freeSpace.next() })
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
        let outcome = await executor(probes: probes, store: store, home: home).execute(items[0])
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
        let outcome = await executor(store: store, home: home).execute(item(e, paths: [folder]))
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
        let outcome = await executor(runner: runner, store: makeStore(), home: home)
            .execute(item(e, paths: [folder]))
        guard case .blocked = outcome else { Issue.record("esperaba .blocked, hubo \(outcome)"); return }
        #expect(runner.calls.isEmpty)
        #expect(exists(folder))
    }

    @Test func dockerProbeParsesReclaimable() async throws {
        let runner = FakeRunner(
            resolved: ["docker": "/usr/local/bin/docker"],
            outputs: ["/usr/local/bin/docker system df --format {{json .}}":
                CommandOutput(status: 0, stdout: dockerJSON, stderr: "")])
        let items = await scanner([dockerEntry], home: makeTempDir(), runner: runner).findItems(scan: nil)
        #expect(items.count == 1)
        #expect(items.first?.bytes == 29_890_000_000)
        #expect(items.first?.paths == [])
        #expect(runner.calls.first?.arguments == ["system", "df", "--format", "{{json .}}"])
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
        let outcome = await executor(store: makeStore(), home: makeTempDir())
            .execute(item(e, paths: ["/System/Library/Caches"], risk: .safe))
        guard case .blocked = outcome else { Issue.record("esperaba .blocked, hubo \(outcome)"); return }
        #expect(exists("/System/Library/Caches"))
    }

    @Test func recheckBlocksWhenCatalogSaysDoNotTouch() async throws {
        let home = makeTempDir()
        let folder = home + "/.cache/codex-runtimes/codex-primary-runtime"
        writeFile(folder + "/bin")
        let e = entry("codex-runtime", risk: .doNotTouch, paths: [folder], cleanup: .trash)
        // El elemento llega con un riesgo obsoleto: el ejecutor recalcula con el del catálogo.
        let outcome = await executor(store: makeStore(), home: home).execute(item(e, paths: [folder], risk: .safe))
        guard case .blocked = outcome else { Issue.record("esperaba .blocked, hubo \(outcome)"); return }
        #expect(exists(folder))
    }

    @Test func usedByBlocksEvenWithStaleRisk() async throws {
        let home = makeTempDir()
        let folder = home + "/.cache/huggingface/hub/models--a--b"
        writeFile(folder + "/w")
        let e = entry("huggingface-model", risk: .yourCall, paths: [folder], cleanup: .trash)
        let outcome = await executor(store: makeStore(), home: home)
            .execute(item(e, paths: [folder], risk: .yourCall, usedBy: ["/x/config.toml"]))
        guard case .blocked = outcome else { Issue.record("esperaba .blocked, hubo \(outcome)"); return }
        #expect(exists(folder))
    }

    @Test func commandBlockedWhenAppOpenWithoutCallingRunner() async throws {
        let runner = FakeRunner(resolved: ["uv": "/opt/homebrew/bin/uv"])
        var e = uvEntry
        e.mustBeClosed = ["com.example.app"]
        let outcome = await executor(
            runner: runner, probes: FakeProbes(running: ["com.example.app"]), store: makeStore(),
            home: makeTempDir()
        ).execute(item(e))
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
        writeFile(runtime + "/bin")
        let catalog = Catalog(entries: [
            entry("codex-runtime", risk: .doNotTouch, paths: ["~/.cache/codex-runtimes/codex-primary-runtime"], cleanup: .info),
        ])
        let exec = CleanupExecutor(
            runner: FakeRunner(), probes: FakeProbes(), store: makeStore(), home: home, catalog: catalog)
        for path in [runtime, home + "/.cache/codex-runtimes", home + "/.cache"] {
            let outcome = await exec.trashPaths([path], title: "x")
            guard case .blocked = outcome else { Issue.record("debió bloquear \(path), hubo \(outcome)"); continue }
        }
        #expect(exists(runtime))
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

    @Test func processRunnerResolvesFromSearchPath() async throws {
        let dir = makeTempDir()
        let tool = dir + "/herramienta"
        writeFile(tool, text: "#!/bin/sh\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool)
        writeFile(dir + "/noejecutable", text: "x")
        let runner = ProcessRunner(searchPath: [dir + "/vacio", dir])
        #expect(await runner.resolve("herramienta") == tool)
        #expect(await runner.resolve("noejecutable") == nil)
        #expect(await runner.resolve("inexistente-diskmap") == nil)
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
        let outcome = await executor(probes: probes, store: store, home: makeTempDir()).emptyTrash()
        guard case .freed(let bytes) = outcome else { Issue.record("esperaba .freed, hubo \(outcome)"); return }
        #expect(bytes == 4_096)
        #expect(probes.emptyCount == 1)
        let history = try store.history()
        #expect(history.count == 1)
        #expect(history.first?.wentToTrash == false)
        #expect(try store.totalFreed() == 4_096)
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

    @Test func dockerOmittedWhenDaemonDown() async throws {
        let runner = FakeRunner(
            resolved: ["docker": "/usr/local/bin/docker"],
            outputs: ["/usr/local/bin/docker system df --format {{json .}}":
                CommandOutput(status: 1, stdout: "", stderr: "Cannot connect to the Docker daemon")])
        #expect(await scanner([dockerEntry], home: makeTempDir(), runner: runner).findItems(scan: nil).isEmpty)
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

    @Test func probesTrashSizeAndEmptyUseInjectedHome() throws {
        let home = makeTempDir()
        writeFile(home + "/.Trash/viejo.bin", bytes: 30_000)
        writeFile(home + "/.Trash/carpeta/otro.bin", bytes: 30_000)
        let probes = SystemProbes(home: home, runner: FakeRunner(), allowFinderFallback: false)
        let size = probes.trashSize()
        #expect(size >= 60_000)
        let freed = try probes.emptyTrash()
        #expect(freed == size)
        #expect(try FileManager.default.contentsOfDirectory(atPath: home + "/.Trash").isEmpty)
        #expect(SystemProbes(home: makeTempDir(), runner: FakeRunner(), allowFinderFallback: false).trashSize() == 0)
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
