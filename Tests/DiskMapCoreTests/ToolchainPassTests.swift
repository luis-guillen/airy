import Foundation
import Synchronization
import Testing
@testable import DiskMapCore

/// I3: la revalidación de versiones se hace una vez por tanda (vista previa o ejecución), no por fila.
@Suite struct ToolchainPassTests {
    private let pyenv = "/fake/bin/pyenv"

    /// pyenv con 3.9.18 (global), 3.11.4 y 3.12.1.
    private func home() -> String {
        let base = toolchainTempDir()
        let v = base + "/home/.pyenv/versions"
        tcVersion(v + "/3.9.18", usedDaysAgo: 400)
        tcVersion(v + "/3.11.4", usedDaysAgo: 200)
        tcVersion(v + "/3.12.1", usedDaysAgo: 200)
        tcWrite(base + "/home/.pyenv/version", "3.9.18\n")
        return base
    }

    private func executor(_ catalog: Catalog, base: String, runner: FakeRunner) -> CleanupExecutor {
        let load = SettingsLoad.loaded(AirySettings())
        let listing = TCListing()
        return CleanupExecutor(
            runner: runner, probes: FakeProbes(),
            store: IndexStore(directory: URL(fileURLWithPath: toolchainTempDir())), catalog: catalog,
            references: ReferenceChecker(roots: []), home: base + "/home", freeSpace: { 0 }, trashSettleDelay: .zero,
            settings: { load }, processGuard: ProcessGuard(listing: listing), processListing: listing)
    }

    /// Cuenta las detecciones completas mientras corre `body`.
    private func counting(_ base: String, _ body: () async -> Void) async -> Int {
        let count = Mutex(0)
        await ToolchainSource.$rootsOverride.withValue({ _ in tcRoots(base) }) {
            await ToolchainSource.$onDetect.withValue({ count.withLock { $0 += 1 } }) { await body() }
        }
        return count.withLock { $0 }
    }

    @Test func previewAndExecuteDetectOncePerBatch() async throws {
        let base = home()
        let catalog = try tcCatalog("toolchain-pyenv")
        let runner = FakeRunner(resolved: ["pyenv": pyenv])
        let items = await tcScan(catalog, base: base, runner: runner).filter { $0.risk == .yourCall }
        #expect(items.count == 2)
        let executor = executor(catalog, base: base, runner: runner)

        // Sin tanda: una detección por fila (lo de antes).
        let unshared = await counting(base) {
            for item in items { _ = await executor.preview(item, logged: false) }
        }
        #expect(unshared == 2)
        // Hoja de confirmación: una sola detección para todas las filas.
        let previewed = await counting(base) {
            let pass = RevalidationPass()
            for item in items {
                guard case .wouldRun = await executor.preview(item, logged: false, pass: pass) else {
                    Issue.record("\(item.id)"); return
                }
            }
        }
        #expect(previewed == 1)
        // Ejecución: su propia tanda (una detección más), nunca la de la vista previa.
        let executed = await counting(base) {
            let pass = RevalidationPass()
            for item in items { #expect(await executor.execute(item, pass: pass) == .freed(0)) }
        }
        #expect(executed == 1)
        #expect(runner.calls.map(\.arguments).sorted { $0.last! < $1.last! }
            == [["uninstall", "-f", "3.11.4"], ["uninstall", "-f", "3.12.1"]])
    }

    @Test func sharedBatchStillKeepsTheLastVersion() async throws {
        let base = toolchainTempDir()
        let v = base + "/home/.pyenv/versions"
        tcVersion(v + "/3.11.4", usedDaysAgo: 200)
        tcVersion(v + "/3.12.1", usedDaysAgo: 200)
        let catalog = try tcCatalog("toolchain-pyenv")
        // El falso `pyenv uninstall` borra la carpeta (en la carpeta temporal de la prueba).
        let runner = FakeRunner(resolved: ["pyenv": pyenv], onRun: { call in
            if let version = call.arguments.last { try? FileManager.default.removeItem(atPath: v + "/" + version) }
        })
        let items = await tcScan(catalog, base: base, runner: runner)
        #expect(items.count == 2)
        let executor = executor(catalog, base: base, runner: runner)
        var outcomes: [CleanupOutcome] = []
        _ = await counting(base) {
            let pass = RevalidationPass()
            for item in items { outcomes.append(await executor.execute(item, pass: pass)) }
        }
        #expect(outcomes.first == .freed(0))
        #expect(outcomes.last == .blocked(reason: "Ya no hay otra versión de la misma herramienta."))
        #expect(runner.calls.count == 1)
    }

    @Test func processStartedMidBatchIsStillSeen() async throws {
        let base = home()
        let catalog = try tcCatalog("toolchain-pyenv")
        let runner = FakeRunner(resolved: ["pyenv": pyenv])
        let items = await tcScan(catalog, base: base, runner: runner).filter { $0.risk == .yourCall }
        let listing = SwitchableListing()
        let load = SettingsLoad.loaded(AirySettings())
        let executor = CleanupExecutor(
            runner: runner, probes: FakeProbes(),
            store: IndexStore(directory: URL(fileURLWithPath: toolchainTempDir())), catalog: catalog,
            references: ReferenceChecker(roots: []), home: base + "/home", freeSpace: { 0 }, trashSettleDelay: .zero,
            settings: { load }, processGuard: ProcessGuard(listing: TCListing()), processListing: listing)
        let second = try #require(items.last)
        let exe = base + "/home/.pyenv/versions/" + second.targets[0] + "/bin/python3"
        var outcomes: [CleanupOutcome] = []
        _ = await counting(base) {
            let pass = RevalidationPass()
            outcomes.append(await executor.execute(items[0], pass: pass))
            // Entre filas arranca un proceso de la segunda versión: se ve aunque la detección sea de la tanda.
            listing.set([RunningProcess(pid: 7, name: "python3", executablePath: exe)])
            outcomes.append(await executor.execute(second, pass: pass))
        }
        #expect(outcomes.first == .freed(0))
        #expect(outcomes.last == .blocked(reason: "Se está usando ahora."))
    }

    @Test func brewUsesRunsOncePerFormulaPerBatch() async throws {
        let base = toolchainTempDir()
        tcVersion(base + "/Cellar/python@3.11/3.11.6", usedDaysAgo: 200)
        tcVersion(base + "/Cellar/python@3.12/3.12.1", usedDaysAgo: 200)
        tcVersion(base + "/Cellar/python@3.13/3.13.0", usedDaysAgo: 200)
        let brew = "/fake/brew"
        let runner = FakeRunner(resolved: ["brew": brew])
        let catalog = try tcCatalog("toolchain-homebrew")
        let items = await tcScan(catalog, base: base, runner: runner)
        #expect(items.count == 3)
        let detected = runner.calls.count
        let executor = executor(catalog, base: base, runner: runner)
        let selected = Array(items.prefix(2))
        _ = await counting(base) {
            let pass = RevalidationPass()
            for item in selected + selected {
                guard case .wouldRun = await executor.preview(item, logged: false, pass: pass) else {
                    Issue.record("\(item.id)"); return
                }
            }
        }
        let uses = runner.calls.dropFirst(detected).map(\.arguments)
        #expect(uses.sorted { $0.last! < $1.last! } == selected.map { ["uses", "--installed", $0.targets[0]] }
            .sorted { $0.last! < $1.last! })
    }

    @Test func incompleteProjectSearchFailsClosedWithAReason() async throws {
        let base = home()
        let h = base + "/home"
        tcWrite(h + "/Projects/app/package.json", "{}")
        let catalog = try tcCatalog("toolchain-pyenv")
        let context = DiscoveryContext(catalog: catalog, home: h, runner: FakeRunner(resolved: ["pyenv": pyenv]),
                                       processListing: TCListing(), now: Date(), scan: nil)
        // La búsqueda de proyectos se queda sin tiempo (su propio plazo).
        let list = await ProjectArtifactSource(totalBudget: .zero).projectList(context: context)
        #expect(!list.complete)
        let source = ToolchainSource(roots: { _ in tcRoots(base) })
        let rows = await source.discover(catalog.entries[0], context: context)
        #expect(rows.count == 3)
        let amber = rows.filter { $0.floor == nil }
        #expect(amber.count == 2)
        #expect(amber.allSatisfy { $0.blockedReason == ToolchainSource.projectsIncompleteReason && !$0.preselectable })
        // La revalidación con esa misma tanda también se niega, con el motivo.
        let item = CleanupItem(id: "toolchain-pyenv:python 3.11.4", entry: catalog.entries[0], paths: [h + "/.pyenv/versions/3.11.4"], bytes: 1,
                               risk: .yourCall, blockedByOpenApps: [], usedBy: [], targets: ["3.11.4"])
        let reason = await source.revalidate(catalog.entries[0], item: item, context: context)
        #expect(reason == ToolchainSource.projectsIncompleteReason)
    }
}

final class SwitchableListing: ProcessListing, Sendable {
    private let list = Mutex<[RunningProcess]?>([])
    func set(_ processes: [RunningProcess]?) { list.withLock { $0 = processes } }
    func processes() -> [RunningProcess]? { list.withLock { $0 } }
    func holders(ofPathsUnder paths: [String]) -> [RunningProcess]? { [] }
}
