import Foundation
import Testing
@testable import DiskMapCore

// MARK: - Utilidades

private let git = "/usr/bin/git"
private let day: TimeInterval = 86_400

/// Carpeta personal temporal (ruta real, sin el enlace `/var` → `/private/var`).
private func tempHome() -> String {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("airy-proj-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return CleanupTargets.realPath(url.path)!
}

/// Crea `relative` (carpeta si acaba en `/`, si no un fichero de 4 KB) bajo `base`.
private func make(_ base: String, _ relatives: String...) {
    for relative in relatives {
        let path = base + "/" + relative
        if relative.hasSuffix("/") {
            try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        } else {
            try! FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: path, contents: Data(repeating: 1, count: 4096))
        }
    }
}

/// Fecha `path` (sin seguir enlaces) `days` días en el pasado.
private func age(_ path: String, days: Double) {
    let seconds = Date().addingTimeInterval(-days * day).timeIntervalSince1970
    var times = [timeval(tv_sec: Int(seconds), tv_usec: 0), timeval(tv_sec: Int(seconds), tv_usec: 0)]
    #expect(lutimes(path, &times) == 0, "\(path)")
}

/// Fecha todo el árbol (de dentro afuera, sin seguir enlaces).
private func ageTree(_ root: String, days: Double) {
    let names = (try? FileManager.default.subpathsOfDirectory(atPath: root)) ?? []
    for name in names.sorted(by: { $0.count > $1.count }) { age(root + "/" + name, days: days) }
    age(root, days: days)
}

private struct NoProcesses: ProcessListing {
    func processes() -> [RunningProcess]? { [] }
    func holders(ofPathsUnder paths: [String]) -> [RunningProcess]? { [] }
}

private func settings(_ mode: CleanupMode) -> AirySettings {
    var s = AirySettings()
    s.mode = mode
    return s
}

private func projectCatalog() throws -> Catalog {
    let bundled = try Catalog.bundled()
    return Catalog(entries: try ["old-project-artifacts", "old-project-build-leftovers"].map {
        try #require(bundled.entry(id: $0))
    })
}

private func gitRunner(_ outputs: [String: CommandOutput] = [:]) -> FakeRunner {
    FakeRunner(resolved: ["git": git], outputs: outputs)
}

private func scan(home: String, runner: FakeRunner = gitRunner(), mode: CleanupMode = .aggressive) async throws
    -> [CleanupItem] {
    let catalog = try projectCatalog()
    return await CleanupScanner(
        catalog: catalog, runner: runner, probes: FakeProbes(), references: ReferenceChecker(roots: []), home: home,
        classifier: RiskClassifier(catalog: catalog, settings: settings(mode), home: home),
        processListing: NoProcesses()
    ).findItems(scan: nil)
}

private func context(home: String, runner: FakeRunner = gitRunner()) throws -> DiscoveryContext {
    DiscoveryContext(catalog: try projectCatalog(), home: home, runner: runner, processListing: NoProcesses(),
                     now: Date(), scan: nil)
}

/// Proyecto Node viejo en `~/Projects/app`: package.json y src/a.js de hace 120 días, node_modules de hoy.
private func staleNodeApp(_ home: String) -> String {
    let app = home + "/Projects/app"
    make(app, "package.json", "src/a.js", "node_modules/left-pad/index.js")
    ageTree(app, days: 120)
    age(app + "/node_modules/left-pad/index.js", days: 0)
    age(app + "/node_modules", days: 0)
    return app
}

// MARK: - Pruebas

@Suite struct ProjectArtifactTests {
    @Test func staleProjectOffersItsNodeModulesPreselectedInAggressive() async throws {
        let home = tempHome()
        let app = staleNodeApp(home)
        let items = try await scan(home: home)
        #expect(items.count == 1)
        let item = try #require(items.first)
        #expect(item.id == "old-project-artifacts:~/Projects/app/node_modules")
        #expect(item.paths == [app + "/node_modules"])
        #expect(item.risk == .yourCall)
        #expect(item.preselected)
        #expect(item.bytes > 0)
        #expect(item.blockedReason == nil)
        #expect(item.details.first?.hasPrefix("Proyecto sin tocar desde ") == true)
        #expect(item.details.last == ProjectArtifactRules.regenerationHint(for: "node_modules"))
        // En Prudente sigue en ámbar pero sin marcar.
        let prudent = try await scan(home: home, mode: .prudent)
        #expect(prudent.count == 1 && prudent[0].risk == .yourCall && !prudent[0].preselected)
    }

    @Test func signalIgnoresRegenerableFoldersAndGitObjects() async throws {
        let home = tempHome()
        let app = home + "/Projects/app"
        make(app, "package.json", "src/a.js", ".git/HEAD", ".git/objects/ab/cdef", "node_modules/x/i.js", "dist/o.js")
        ageTree(app, days: 120)
        for recent in [".git/objects/ab/cdef", ".git/objects/ab", ".git/objects", "node_modules/x/i.js", "dist/o.js"] {
            age(app + "/" + recent, days: 0)
        }
        let items = try await scan(home: home)
        #expect(Set(items.map(\.id)) == ["old-project-artifacts:~/Projects/app/node_modules",
                                          "old-project-build-leftovers:~/Projects/app/dist"])
    }

    @Test func recentFileAnywhereKeepsEverything() async throws {
        let home = tempHome()
        let app = staleNodeApp(home)
        make(app, "src/b.js")
        age(app + "/src/b.js", days: 10)
        age(app + "/src", days: 120)
        #expect(try await scan(home: home).isEmpty)
    }

    @Test func outermostRootDecidesForMonorepo() async throws {
        let home = tempHome()
        let repo = home + "/Projects/repo"
        make(repo, ".git/HEAD", "packages/a/package.json", "packages/a/node_modules/x/i.js", "packages/b/x.ts")
        ageTree(repo, days: 120)
        // Sin nada reciente, el monorepo es viejo y se ofrece la carpeta del paquete.
        #expect(try await scan(home: home).map(\.id) == ["old-project-artifacts:~/Projects/repo/packages/a/node_modules"])
        // Un fichero reciente en otro paquete mantiene vivo todo el repositorio.
        age(repo + "/packages/b/x.ts", days: 1)
        #expect(try await scan(home: home).isEmpty)
    }

    @Test func extendedNamesAreNotPreselected() async throws {
        let home = tempHome()
        let app = home + "/Projects/ios"
        make(app, "requirements.txt", "tool/__pycache__/m.pyc", "Pods/AFNetworking/a.m")
        ageTree(app, days: 120)
        let items = try await scan(home: home)
        #expect(Set(items.map(\.id)) == ["old-project-build-leftovers:~/Projects/ios/tool/__pycache__",
                                          "old-project-build-leftovers:~/Projects/ios/Pods"])
        for item in items {
            #expect(item.risk == .yourCall && !item.preselected, "\(item.id)")
        }
    }

    @Test func cachedirTagIsRecognised() async throws {
        let home = tempHome()
        let app = home + "/Projects/rs"
        make(app, "Cargo.toml", "rare-cache/blob", "fake-cache/blob")
        FileManager.default.createFile(
            atPath: app + "/rare-cache/CACHEDIR.TAG",
            contents: Data((ProjectArtifactRules.cachedirSignature + "\n# lo creó una herramienta\n").utf8))
        FileManager.default.createFile(atPath: app + "/fake-cache/CACHEDIR.TAG", contents: Data("Signature: otra".utf8))
        ageTree(app, days: 120)
        let items = try await scan(home: home)
        #expect(items.map(\.id) == ["old-project-build-leftovers:~/Projects/rs/rare-cache"])
    }

    @Test func nestedRepoAndKeypairAreRed() async throws {
        let home = tempHome()
        let app = home + "/Projects/sol"
        make(app, "Cargo.toml", "target/deploy/prog-keypair.json", "target/release/prog.so",
             "composer.json", "vendor/autoload.php", "vendor/acme/lib/.git/HEAD")
        ageTree(app, days: 120)
        let items = try await scan(home: home)
        let target = try #require(items.first { $0.id.hasSuffix("/target") })
        #expect(target.risk == .doNotTouch && !target.preselected)
        #expect(target.riskReason == "Contiene claves (prog-keypair.json): no se regeneran.")
        let vendor = try #require(items.first { $0.id.hasSuffix("/vendor") })
        #expect(vendor.risk == .doNotTouch && !vendor.preselected)
        #expect(vendor.riskReason == "Contiene otro repositorio Git dentro.")
    }

    @Test func gitTrackedBuildIsRedAndGitFailureBlocks() async throws {
        let home = tempHome()
        let repo = home + "/Projects/web"
        make(repo, ".git/HEAD", "package.json", "build/out.js")
        ageTree(repo, days: 120)
        let key = "\(git) -C \(repo) ls-files -z -- build"

        let tracked = try await scan(home: home, runner: gitRunner([
            key: CommandOutput(status: 0, stdout: "build/out.js\u{0}", stderr: ""),
        ]))
        #expect(tracked.count == 1)
        #expect(tracked.first?.risk == .doNotTouch)
        #expect(tracked.first?.riskReason == "Git guarda archivos aquí: no es solo un resto de compilación.")

        let clean = try await scan(home: home)
        #expect(clean.count == 1 && clean[0].risk == .yourCall && clean[0].blockedReason == nil)

        let failing = try await scan(home: home, runner: gitRunner([
            key: CommandOutput(status: 128, stdout: "", stderr: "fatal"),
        ]))
        #expect(failing.first?.blockedReason == "No se pudo comprobar con Git si guarda archivos aquí.")

        let noGit = try await scan(home: home, runner: FakeRunner())
        #expect(noGit.first?.blockedReason == "No se pudo comprobar con Git si guarda archivos aquí.")
    }

    @Test func binAndVendorOnlyForDotNetAndComposer() async throws {
        let home = tempHome()
        let node = home + "/Projects/node"
        make(node, "package.json", "bin/cli.js", "vendor/lib.js")
        let dotnet = home + "/Projects/dotnet"
        make(dotnet, ".git/HEAD", "App/App.csproj", "App/bin/Debug/App.dll", "App/obj/x.json",
             "site/composer.json", "site/vendor/autoload.php")
        ageTree(node, days: 120)
        ageTree(dotnet, days: 120)
        let items = try await scan(home: home)
        #expect(Set(items.map(\.id)) == [
            "old-project-build-leftovers:~/Projects/dotnet/App/bin",
            "old-project-build-leftovers:~/Projects/dotnet/App/obj",
            "old-project-build-leftovers:~/Projects/dotnet/site/vendor",
        ])
    }

    @Test func symlinkedArtifactIsNeitherWalkedNorOffered() async throws {
        let home = tempHome()
        let app = home + "/Projects/app"
        make(app, "package.json", "src/a.js", "build/o.js")
        make(home, "Documents/grande/reciente.bin")
        try FileManager.default.createSymbolicLink(atPath: app + "/node_modules",
                                                   withDestinationPath: home + "/Documents/grande")
        ageTree(app, days: 120)
        // Lo de detrás del enlace es de hoy: si se siguiera, el proyecto no sería viejo.
        let items = try await scan(home: home)
        #expect(items.map(\.id) == ["old-project-artifacts:~/Projects/app/build"])
        #expect(FileManager.default.fileExists(atPath: home + "/Documents/grande/reciente.bin"))
    }

    @Test func iCloudAndCloudStorageAreSkipped() async throws {
        let home = tempHome()
        for root in ["Library/CloudStorage/GoogleDrive-ana", "Library/Mobile Documents/com~apple~CloudDocs"] {
            let app = home + "/" + root + "/app"
            make(app, "package.json", "node_modules/x/i.js")
            ageTree(app, days: 120)
            let source = ProjectArtifactSource(searchRoots: [home + "/" + root, home + "/Library"])
            let entry = try #require(try projectCatalog().entry(id: "old-project-artifacts"))
            #expect(await source.discover(entry, context: try context(home: home)).isEmpty, "\(root)")
        }
        // Library nunca es raíz por defecto.
        #expect(ProjectArtifactRules.defaultSearchRoots(home: home).isEmpty)
    }

    @Test func budgetExceededOffersNothing() async throws {
        let home = tempHome()
        _ = staleNodeApp(home)
        let entry = try #require(try projectCatalog().entry(id: "old-project-artifacts"))
        let source = ProjectArtifactSource(projectBudget: .zero)
        #expect(await source.discover(entry, context: try context(home: home)).isEmpty)
        let noTime = ProjectArtifactSource(totalBudget: .zero)
        #expect(await noTime.discover(entry, context: try context(home: home)).isEmpty)
        #expect(await ProjectArtifactSource().discover(entry, context: try context(home: home)).count == 1)
    }

    @Test func projectTouchedAfterDetectionIsRefused() async throws {
        let home = tempHome()
        let app = staleNodeApp(home)
        let item = try #require(try await scan(home: home).first)
        make(app, "src/a.js")
        let catalog = try projectCatalog()
        let executor = CleanupExecutor(
            runner: gitRunner(), probes: FakeProbes(),
            store: IndexStore(directory: URL(fileURLWithPath: tempHome())), catalog: catalog,
            references: ReferenceChecker(roots: []), home: home, settings: { .missing },
            processGuard: ProcessGuard(listing: NoProcesses()), processListing: NoProcesses())
        let outcome = await executor.execute(item)
        guard case .blocked(let reason) = outcome else {
            Issue.record("esperaba un bloqueo: \(outcome)")
            return
        }
        #expect(reason.hasPrefix("Has tocado el proyecto hace poco ("), "\(reason)")
        #expect(reason.hasSuffix("): no se borra."), "\(reason)")
        #expect(FileManager.default.fileExists(atPath: app + "/node_modules/left-pad/index.js"))
    }

    @Test func revalidateRejectsPathOutsideAnyProject() async throws {
        let home = tempHome()
        let loose = home + "/Projects/suelto"
        make(loose, "node_modules/x/i.js", "notas.txt")
        ageTree(loose, days: 120)
        let entry = try #require(try projectCatalog().entry(id: "old-project-artifacts"))
        let source = ProjectArtifactSource()
        let ctx = try context(home: home)
        func item(_ paths: [String]) -> CleanupItem {
            CleanupItem(id: "old-project-artifacts:x", entry: entry, paths: paths, bytes: 4096, risk: .yourCall,
                        blockedByOpenApps: [], usedBy: [])
        }
        #expect(await source.revalidate(entry, item: item([loose + "/node_modules"]), context: ctx)
            == "Ya no está dentro de un proyecto.")
        // Fuera de toda raíz de búsqueda, con dos rutas o con un nombre que no es de la ficha: rechazado.
        let elsewhere = tempHome()
        make(elsewhere, "package.json", "node_modules/x/i.js")
        ageTree(elsewhere, days: 120)
        #expect(await source.revalidate(entry, item: item([elsewhere + "/node_modules"]), context: ctx) != nil)
        #expect(await source.revalidate(entry, item: item([loose + "/node_modules", loose + "/notas.txt"]),
                                        context: ctx) != nil)
        make(loose, "package.json", "src/")
        ageTree(loose, days: 120)
        #expect(await source.revalidate(entry, item: item([loose + "/src"]), context: ctx) != nil)
        // Ya dentro de un proyecto viejo, la misma carpeta vale.
        #expect(await source.revalidate(entry, item: item([loose + "/node_modules"]), context: ctx) == nil)
    }
}
