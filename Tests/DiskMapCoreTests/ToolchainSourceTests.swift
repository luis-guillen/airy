import Foundation
import Synchronization
import Testing
@testable import DiskMapCore

// MARK: - Utilidades

final class TCListing: ProcessListing, Sendable {
    private let list: Mutex<[RunningProcess]?>
    init(_ list: [RunningProcess]? = []) { self.list = Mutex(list) }
    func processes() -> [RunningProcess]? { list.withLock { $0 } }
    func holders(ofPathsUnder paths: [String]) -> [RunningProcess]? { [] }
}

func tcCatalog(_ ids: String...) throws -> Catalog {
    let all = try Catalog.bundled()
    return Catalog(entries: try ids.map { try #require(all.entry(id: $0), "\($0)") })
}

/// Una versión con un fichero dentro (para que ocupe) y uso hace `days` días.
func tcVersion(_ path: String, usedDaysAgo days: Double, exe: String = "bin/python3") {
    tcWrite(path + "/" + exe, String(repeating: "x", count: 5000))
    tcSetTimes(path + "/" + exe, accessDaysAgo: days, modifiedDaysAgo: days)
    tcSetTimes((path + "/" + exe as NSString).deletingLastPathComponent, accessDaysAgo: days, modifiedDaysAgo: days)
    tcSetTimes(path, accessDaysAgo: days, modifiedDaysAgo: days)
}

func tcScan(_ catalog: Catalog, base: String, mode: CleanupMode = .aggressive, runner: FakeRunner = FakeRunner(),
            listing: TCListing = TCListing()) async -> [CleanupItem] {
    var settings = AirySettings()
    settings.mode = mode
    let home = base + "/home"
    return await ToolchainSource.$rootsOverride.withValue({ _ in tcRoots(base) }) {
        await CleanupScanner(
            catalog: catalog, runner: runner, probes: FakeProbes(), references: ReferenceChecker(roots: []),
            home: home, classifier: RiskClassifier(catalog: catalog, settings: settings, home: home),
            processListing: listing
        ).findItems(scan: nil)
    }
}

func tcExecute(_ item: CleanupItem, catalog: Catalog, base: String, runner: FakeRunner,
               context: OperationContext = .user(), beforeMove: (@Sendable (String) -> Void)? = nil) async
    -> CleanupOutcome {
    let load = SettingsLoad.loaded(AirySettings())
    let listing = TCListing()
    let executor = CleanupExecutor(
        runner: runner, probes: FakeProbes(), store: IndexStore(directory: URL(fileURLWithPath: toolchainTempDir())),
        catalog: catalog, references: ReferenceChecker(roots: []), home: base + "/home", freeSpace: { 0 },
        trashSettleDelay: .zero, settings: { load }, processGuard: ProcessGuard(listing: listing),
        processListing: listing, beforeMove: beforeMove)
    return await ToolchainSource.$rootsOverride.withValue({ _ in tcRoots(base) }) {
        await executor.execute(item, context: context)
    }
}

private let pyenvBin = "/fake/bin/pyenv"

/// pyenv con 3.9.18 (global), 3.11.4 (uso hace 200 d) y 3.12.1 (hace 10 d).
private func pyenvHome() -> String {
    let base = toolchainTempDir()
    let v = base + "/home/.pyenv/versions"
    tcVersion(v + "/3.9.18", usedDaysAgo: 400)
    tcVersion(v + "/3.11.4", usedDaysAgo: 200)
    tcVersion(v + "/3.12.1", usedDaysAgo: 10)
    tcWrite(base + "/home/.pyenv/version", "3.9.18\n")
    return base
}

@Suite struct ToolchainSourceTests {
    @Test func inUseIsRedOthersAmberNeverGreen() async throws {
        let base = pyenvHome()
        for mode in CleanupMode.allCases {
            let items = await tcScan(try tcCatalog("toolchain-pyenv"), base: base, mode: mode)
            #expect(items.map(\.id).sorted() == ["toolchain-pyenv:python 3.11.4", "toolchain-pyenv:python 3.12.1",
                                                 "toolchain-pyenv:python 3.9.18"])
            let global = try #require(items.first { $0.id.hasSuffix("3.9.18") })
            #expect(global.risk == .doNotTouch && global.riskReason == "Es la versión por defecto de pyenv.")
            #expect(items.filter { $0.id != global.id }.allSatisfy { $0.risk == .yourCall })
            #expect(!items.contains { $0.risk == .safe })
            #expect(items.allSatisfy { $0.targets == [String($0.id.split(separator: " ").last!)] })
        }
    }

    @Test func aggressivePreselectsOnlyOldUnrequested() async throws {
        let base = pyenvHome()
        let aggressive = await tcScan(try tcCatalog("toolchain-pyenv"), base: base, mode: .aggressive)
        #expect(aggressive.filter(\.preselected).map(\.id) == ["toolchain-pyenv:python 3.11.4"])
        let prudent = await tcScan(try tcCatalog("toolchain-pyenv"), base: base, mode: .prudent)
        #expect(!prudent.contains { $0.preselected })
    }

    @Test func singleInstallOffersNothing() async throws {
        let base = toolchainTempDir()
        tcVersion(base + "/home/.rbenv/versions/3.2.2", usedDaysAgo: 200, exe: "bin/ruby")
        let items = await tcScan(try tcCatalog("toolchain-rbenv", "toolchain-rvm"), base: base)
        #expect(items.isEmpty)
        // Con otra en rvm, las dos se ofrecen (se cuenta por lenguaje).
        tcVersion(base + "/home/.rvm/rubies/ruby-3.1.0", usedDaysAgo: 200, exe: "bin/ruby")
        #expect(await tcScan(try tcCatalog("toolchain-rbenv", "toolchain-rvm"), base: base).count == 2)
    }

    @Test func runningVersionIsRed() async throws {
        let base = pyenvHome()
        let exe = base + "/home/.pyenv/versions/3.11.4/bin/python3"
        let items = await tcScan(try tcCatalog("toolchain-pyenv"), base: base,
                                 listing: TCListing([RunningProcess(pid: 9, name: "python3", executablePath: exe)]))
        let running = try #require(items.first { $0.id.hasSuffix("3.11.4") })
        #expect(running.risk == .doNotTouch && running.riskReason == "Se está usando ahora." && !running.preselected)
        // Listado desconocido ⇒ bloqueado.
        let unknown = await tcScan(try tcCatalog("toolchain-pyenv"), base: base, listing: TCListing(nil))
        #expect(unknown.filter { $0.risk != .doNotTouch }.allSatisfy {
            $0.blockedReason == "No se pudo comprobar si está en uso." && !$0.preselected
        })
    }

    @Test func brewDependentsTimeoutAndVeto() async throws {
        let base = toolchainTempDir()
        tcVersion(base + "/Cellar/python@3.11/3.11.6", usedDaysAgo: 200)
        tcVersion(base + "/Cellar/python@3.12/3.12.1", usedDaysAgo: 200)
        tcVersion(base + "/Cellar/python@3.13/3.13.0", usedDaysAgo: 200)
        let brew = "/fake/brew"
        let runner = FakeRunner(resolved: ["brew": brew], outputs: [
            "\(brew) uses --installed python@3.11": CommandOutput(status: 0, stdout: "ffmpeg\n", stderr: ""),
            "\(brew) uses --installed python@3.12": CommandOutput(status: 1, stdout: "", stderr: "boom"),
        ])
        let items = await tcScan(try tcCatalog("toolchain-homebrew"), base: base, runner: runner)
        func item(_ f: String) -> CleanupItem? { items.first { $0.targets == [f] } }
        #expect(item("python@3.11")?.risk == .doNotTouch)
        #expect(item("python@3.11")?.riskReason == "Lo necesita Homebrew para: ffmpeg.")
        #expect(item("python@3.12")?.blockedReason == "No se pudo comprobar a tiempo si Homebrew la necesita.")
        #expect(item("python@3.13")?.risk == .yourCall && item("python@3.13")?.blockedReason == nil)
        #expect(items.allSatisfy { $0.paths.isEmpty && $0.bytes > 0 })
        #expect(runner.calls.allSatisfy { $0.arguments.prefix(2) == ["uses", "--installed"] && $0.timeout <= 15 })
        // Más de `brewLimit`: las que no se comprueban quedan bloqueadas.
        let limited = await ToolchainSource.$rootsOverride.withValue({ _ in tcRoots(base) }) {
            await ToolchainSource(roots: nil, brewLimit: 1).discover(
                try! tcCatalog("toolchain-homebrew").entries[0],
                context: DiscoveryContext(catalog: try! tcCatalog("toolchain-homebrew"), home: base + "/home",
                                          runner: runner, processListing: TCListing(), now: Date(), scan: nil))
        }
        #expect(limited.filter { $0.blockedReason != nil }.count == 2)
        #expect(CommandPolicy.refusal(executable: "/opt/homebrew/bin/brew",
                                      arguments: ["uninstall", "--ignore-dependencies", "x"]) != nil)
        #expect(CommandPolicy.refusal(executable: "brew", arguments: ["uninstall", "x"]) == nil)
        // Sin brew no se ofrece nada de Homebrew.
        #expect(await tcScan(try tcCatalog("toolchain-homebrew"), base: base).isEmpty)
    }

    @Test func funnelRunsOfficialCommandAsArgumentArray() async throws {
        let base = pyenvHome()
        let catalog = try tcCatalog("toolchain-pyenv")
        let runner = FakeRunner(resolved: ["pyenv": pyenvBin])
        let item = try #require(await tcScan(catalog, base: base, runner: runner).first { $0.id.hasSuffix("3.11.4") })
        let outcome = await tcExecute(item, catalog: catalog, base: base, runner: runner)
        #expect(outcome == .freed(0))
        #expect(runner.calls.map { [$0.executable] + $0.arguments } == [[pyenvBin, "uninstall", "-f", "3.11.4"]])
        #expect(runner.calls.map(\.workingDirectory) == ["/"])
    }

    @Test func condaRemovesByPathThroughPathGate() async throws {
        let base = toolchainTempDir()
        let envs = base + "/home/miniconda3/envs"
        tcVersion(envs + "/old", usedDaysAgo: 200, exe: "bin/python")
        let catalog = try tcCatalog("toolchain-conda")
        let conda = "/fake/conda"
        let runner = FakeRunner(resolved: ["conda": conda])
        let item = try #require(await tcScan(catalog, base: base, runner: runner).first)
        #expect(item.targets == [envs + "/old"] && item.risk == .yourCall)
        #expect(await tcExecute(item, catalog: catalog, base: base, runner: runner) == .freed(0))
        #expect(runner.calls.map { [$0.executable] + $0.arguments } == [[conda, "env", "remove", "-p", envs + "/old", "-y"]])

        // Cambiada por un enlace entre el plan y la ejecución: bloqueado y sin llamada.
        let swapped = FakeRunner(resolved: ["conda": conda])
        tcMakeDir(base + "/elsewhere")
        let outcome = await tcExecute(item, catalog: catalog, base: base, runner: swapped, beforeMove: { path in
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: base + "/elsewhere")
        })
        guard case .blocked = outcome else { Issue.record("\(outcome)"); return }
        #expect(swapped.calls.isEmpty)
    }

    @Test func nvmVersionGoesToTrash() async throws {
        let base = toolchainTempDir()
        let node = base + "/home/.nvm/versions/node"
        tcVersion(node + "/v18.0.0", usedDaysAgo: 200, exe: "bin/node")
        tcVersion(node + "/v20.0.0", usedDaysAgo: 200, exe: "bin/node")
        let catalog = try tcCatalog("toolchain-nvm")
        let runner = FakeRunner()
        let items = await tcScan(catalog, base: base, runner: runner)
        let item = try #require(items.first { $0.id == "toolchain-nvm:node v18.0.0" })
        #expect(item.paths == [node + "/v18.0.0"] && item.targets.isEmpty)
        let outcome = await tcExecute(item, catalog: catalog, base: base, runner: runner)
        guard case .movedToTrash = outcome else { Issue.record("\(outcome)"); return }
        #expect(!runner.calls.contains { $0.executable.contains("nvm") || $0.arguments.contains("nvm") })
        #expect(!ProjectArtifactRules.exists(node + "/v18.0.0"))
    }

    @Test func defaultChangedAfterDetectionIsRefused() async throws {
        let base = pyenvHome()
        let catalog = try tcCatalog("toolchain-pyenv")
        let runner = FakeRunner(resolved: ["pyenv": pyenvBin])
        let item = try #require(await tcScan(catalog, base: base, runner: runner).first { $0.id.hasSuffix("3.11.4") })
        tcWrite(base + "/home/.pyenv/version", "3.11.4\n")
        #expect(await tcExecute(item, catalog: catalog, base: base, runner: runner)
            == .blocked(reason: "Es la versión por defecto de pyenv."))
        // Un proyecto nuevo que la pide también la bloquea.
        tcWrite(base + "/home/.pyenv/version", "3.9.18\n")
        tcWrite(base + "/home/Projects/app/pyproject.toml", "")
        tcWrite(base + "/home/Projects/app/.python-version", "3.11\n")
        #expect(await tcExecute(item, catalog: catalog, base: base, runner: runner)
            == .blocked(reason: "La pide ~/Projects/app (.python-version)."))
        #expect(runner.calls.isEmpty)
    }

    @Test func hostileTargetsNeverRun() async throws {
        let base = pyenvHome()
        tcVersion(base + "/home/miniconda3/envs/old", usedDaysAgo: 200, exe: "bin/python")
        let catalog = try tcCatalog("toolchain-pyenv", "toolchain-conda")
        let runner = FakeRunner(resolved: ["pyenv": pyenvBin, "conda": "/fake/conda"])
        let pyenv = catalog.entries[0], conda = catalog.entries[1]
        func item(_ entry: CatalogEntry, _ target: String, paths: [String] = []) -> CleanupItem {
            CleanupItem(id: "\(entry.id):x", entry: entry, paths: paths, bytes: 1, risk: .yourCall,
                        blockedByOpenApps: [], usedBy: [], targets: [target])
        }
        let attempts = ["../x", "-rf", "3.11/../..", "base", ""].map { item(pyenv, $0) }
            + ["base", base + "/home/miniconda3", base + "/home/miniconda3/envs/../envs/old"].map { item(conda, $0) }
        for attempt in attempts {
            let outcome = await tcExecute(attempt, catalog: catalog, base: base, runner: runner)
            guard case .blocked = outcome else { Issue.record("\(attempt.targets): \(outcome)"); continue }
        }
        #expect(runner.calls.isEmpty)
        #expect(!ToolchainSource.isSafeName("-rf") && !ToolchainSource.isSafeName("a/b")
                && !ToolchainSource.isSafeName("3..1") && ToolchainSource.isSafeName("python@3.11"))
        #expect(CommandPolicy.refusal(executable: "conda", arguments: ["env", "remove", "-n", "base", "-y"]) != nil)
        #expect(CommandPolicy.refusal(executable: "conda", arguments: ["remove", "--all", "-y"]) != nil)
        #expect(CommandPolicy.refusal(executable: "conda", arguments: ["clean", "--all", "-y"]) == nil)
    }

    @Test func agentCanOnlyList() async throws {
        let base = pyenvHome()
        let catalog = try tcCatalog("toolchain-pyenv")
        let runner = FakeRunner(resolved: ["pyenv": pyenvBin])
        let items = await tcScan(catalog, base: base, runner: runner)
        let item = try #require(items.first { $0.id.hasSuffix("3.11.4") })
        #expect(item.risk == .yourCall)
        let outcome = await tcExecute(item, catalog: catalog, base: base, runner: runner, context: .agent("claude"))
        guard case .blocked = outcome else { Issue.record("\(outcome)"); return }
        #expect(runner.calls.isEmpty)
    }

    @Test func detectionBudgetExceededOffersNothing() async throws {
        let base = pyenvHome()
        let catalog = try tcCatalog("toolchain-pyenv")
        let source = ToolchainSource(roots: { _ in tcRoots(base) }, budget: .zero)
        let context = DiscoveryContext(catalog: catalog, home: base + "/home", runner: FakeRunner(),
                                       processListing: TCListing(), now: Date(), scan: nil)
        #expect(await source.discover(catalog.entries[0], context: context).isEmpty)
    }
}

@Suite struct ToolchainSystemInfoTests {
    @Test func xcodeAndLibraryInstallsAreInfoRows() async throws {
        let base = toolchainTempDir()
        tcWrite(base + "/Applications/Xcode.app/Contents/Developer/x", "abc")
        tcWrite(base + "/Applications/Xcode-15.4.app/Contents/x", "abc")
        try FileManager.default.createSymbolicLink(atPath: base + "/xcode_link",
                                                   withDestinationPath: base + "/Applications/Xcode.app/Contents/Developer")
        let catalog = try tcCatalog("toolchain-system-info")
        let items = await tcScan(catalog, base: base)
        #expect(items.map(\.id) == ["toolchain-system-info:Xcode"])
        let item = try #require(items.first)
        #expect(item.details.sorted() == [base + "/Applications/Xcode-15.4.app",
                                          base + "/Applications/Xcode.app (en uso)"])
        #expect(item.paths.isEmpty && item.bytes > 0 && !item.preselected)
        #expect(await tcExecute(item, catalog: catalog, base: base, runner: FakeRunner())
            == .blocked(reason: "Este elemento es solo informativo."))
    }

    @Test func libraryPythonCountsTowardDuplicates() async throws {
        let base = toolchainTempDir()
        tcWrite(base + "/Python/3.11/bin/python3", "abc")
        tcVersion(base + "/home/.pyenv/versions/3.12.1", usedDaysAgo: 200)
        let items = await tcScan(try tcCatalog("toolchain-system-info", "toolchain-pyenv"), base: base)
        #expect(items.map(\.id).sorted() == ["toolchain-pyenv:python 3.12.1", "toolchain-system-info:Python"])
        #expect(items.first { $0.id.hasSuffix("3.12.1") }?.risk == .yourCall)
    }
}
