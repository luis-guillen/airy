import Foundation
import Synchronization
import Testing
@testable import DiskMapCore

// MARK: - Utilidades

private let day: TimeInterval = 86_400

/// Carpeta temporal (ruta real, sin el enlace `/var` → `/private/var`).
private func tempDir(_ label: String) -> String {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("airy-\(label)-\(UUID().uuidString)")
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

/// Fecha todo el árbol `days` días en el pasado (de dentro afuera, sin seguir enlaces).
private func ageTree(_ root: String, days: Double) {
    let seconds = Date().addingTimeInterval(-days * day).timeIntervalSince1970
    let names = (try? FileManager.default.subpathsOfDirectory(atPath: root)) ?? []
    for path in names.sorted(by: { $0.count > $1.count }).map({ root + "/" + $0 }) + [root] {
        var times = [timeval(tv_sec: Int(seconds), tv_usec: 0), timeval(tv_sec: Int(seconds), tv_usec: 0)]
        _ = lutimes(path, &times)
    }
}

/// Índice mínimo: una raíz con nombre `base` y una cadena de carpetas hasta `relative` con `size` bytes.
private func index(base: String, relative: String, size: Int64) -> FileNode {
    var node = FileNode(name: (relative as NSString).lastPathComponent, isDirectory: true, allocatedSize: size)
    for component in (relative as NSString).deletingLastPathComponent.split(separator: "/").reversed() {
        node = FileNode(name: String(component), isDirectory: true, allocatedSize: size, children: [node])
    }
    return FileNode(name: base, isDirectory: true, allocatedSize: size, children: [node])
}

/// Paseos por disco que hace `body` (ruta raíz y tipo), con el observador de `TreeWalk`.
private func walks<T>(_ body: () async throws -> T) async rethrows -> (T, [(String, TreeWalk.Kind)]) {
    let seen = Mutex<[(String, TreeWalk.Kind)]>([])
    let value = try await TreeWalk.$observer.withValue({ path, kind in seen.withLock { $0.append((path, kind)) } }) {
        try await body()
    }
    return (value, seen.withLock { $0 })
}

private struct NoProcesses: ProcessListing {
    func processes() -> [RunningProcess]? { [] }
    func holders(ofPathsUnder paths: [String]) -> [RunningProcess]? { [] }
}

private func cacheEntry() -> CatalogEntry {
    CatalogEntry(id: "foo", title: "Prueba", explanation: "", whoCreatesIt: "", regenerates: true, risk: .safe,
                 kind: .caches, paths: ["~/Library/Caches/foo"], cleanup: .trash)
}

private func projectCatalog() throws -> Catalog {
    let bundled = try Catalog.bundled()
    return Catalog(entries: try ["old-project-artifacts", "old-project-build-leftovers"].map {
        try #require(bundled.entry(id: $0))
    })
}

private func scanner(_ catalog: Catalog, home: String, scope: DiskScope? = nil) -> CleanupScanner {
    var settings = AirySettings()
    settings.mode = .aggressive
    return CleanupScanner(
        catalog: catalog, runner: FakeRunner(resolved: ["git": "/usr/bin/git"]), probes: FakeProbes(),
        references: ReferenceChecker(roots: []), home: home,
        classifier: RiskClassifier(catalog: catalog, settings: settings, home: home),
        processListing: NoProcesses(), scope: scope)
}

/// Proyecto Node viejo en `~/Projects/app` (sin Git): package.json y src de hace 120 días.
private func staleNodeApp(_ home: String) -> String {
    let app = home + "/Projects/app"
    make(app, "package.json", "src/a.js", "node_modules/left-pad/index.js")
    ageTree(app, days: 120)
    return app
}

// MARK: - Pruebas

@Suite struct DetectionScheduleTests {
    // MARK: Cuándo: la detección automática espera al índice o al análisis

    @Test func automaticDetectionWaitsForTheIndex() {
        var gate = DetectionGate()
        // Al abrir, antes de leer el índice, no hay nada que reutilizar.
        #expect(gate.phase == .waitingForIndex)
        #expect(!gate.allowsAutomatic)
        #expect(gate.cleanupOpened(hasTree: false) == nil)
        // Índice reciente (no se reanaliza): se detecta ya, en segundo plano.
        #expect(gate.indexRead(hasIndex: true, plan: .skip) == .automatic)
        #expect(gate.allowsAutomatic)
        // Una sola vez: un segundo aviso no lanza otra.
        #expect(gate.indexRead(hasIndex: true, plan: .skip) == nil)
        #expect(gate.scanFinished(.automatic) == nil)
    }

    @Test func withoutIndexDetectionWaitsForTheScan() {
        var gate = DetectionGate()
        #expect(gate.indexRead(hasIndex: false, plan: .scan(.normal)) == nil)
        #expect(gate.phase == .waitingForScan)
        #expect(!gate.allowsAutomatic)
        // Sin árbol, abrir Limpieza no detecta (lo mediría todo en disco).
        #expect(gate.cleanupOpened(hasTree: false) == nil)
        #expect(gate.scanFinished(.automatic) == .automatic)
        #expect(gate.allowsAutomatic)
    }

    @Test func staleIndexWaitsForTheRescanUnlessTheUserOpensCleanup() {
        var gate = DetectionGate()
        // Índice viejo: se enseña, pero detectar sobre él sería trabajo tirado y competiría con el análisis.
        #expect(gate.indexRead(hasIndex: true, plan: .scan(.background)) == nil)
        #expect(!gate.allowsAutomatic)
        // Abrir Limpieza la adelanta (QoS del usuario), una vez por espera.
        #expect(gate.cleanupOpened(hasTree: true) == .user)
        #expect(gate.cleanupOpened(hasTree: true) == nil)
        // Al terminar el análisis, la automática sobre el árbol nuevo.
        #expect(gate.scanFinished(.automatic) == .automatic)
        #expect(gate.cleanupOpened(hasTree: true) == nil)
        // Un análisis nuevo vuelve a esperar.
        gate.scanStarted()
        #expect(!gate.allowsAutomatic)
        #expect(gate.indexRead(hasIndex: true, plan: .scan(.normal)) == nil)
        #expect(gate.cleanupOpened(hasTree: true) == .user)
    }

    @Test func detectionAfterAUserScanKeepsTheUserQoSAndAgentsStayInBackground() {
        var user = DetectionGate()
        _ = user.indexRead(hasIndex: true, plan: .scan(.normal))
        #expect(user.scanFinished(.user) == .user)
        var agent = DetectionGate()
        _ = agent.indexRead(hasIndex: true, plan: .scan(.background))
        #expect(agent.scanFinished(.agent) == .automatic)
    }

    @Test func stoppedScanDetectsOnWhatIsShown() {
        var shown = DetectionGate()
        _ = shown.indexRead(hasIndex: true, plan: .scan(.background))
        #expect(shown.scanStopped(hasTree: true) == .automatic)
        #expect(shown.scanStopped(hasTree: true) == nil)
        var empty = DetectionGate()
        _ = empty.indexRead(hasIndex: false, plan: .scan(.normal))
        #expect(empty.scanStopped(hasTree: false) == nil)
        #expect(empty.allowsAutomatic)
        // Cancelar antes de leer el índice tampoco deja la detección esperando para siempre.
        var early = DetectionGate()
        #expect(early.scanStopped(hasTree: false) == nil)
        #expect(early.allowsAutomatic)
    }

    // MARK: Cómo: QoS y paseos a la vez

    @Test func automaticDetectionRunsInBackgroundWithAtMostTwoWalkers() {
        let budget = DetectionSchedule.budget(.automatic, lowPowerMode: false, thermalState: .nominal)
        #expect(budget == ScanBudget(workers: 2, qos: .background))
        #expect(DetectionSchedule.priority(for: budget) == .background)
        // La misma regla que un reanálisis automático.
        let rescan = ScanBudget.resolve(.background, performanceCores: 8, lowPowerMode: false, thermalState: .nominal)
        #expect(budget == rescan)
        #expect(DetectionSchedule.budget(.automatic, lowPowerMode: false, thermalState: .fair).workers == 2)
    }

    @Test func userDetectionUsesUtility() {
        let budget = DetectionSchedule.budget(.user, lowPowerMode: false, thermalState: .nominal)
        #expect(budget == ScanBudget(workers: 2, qos: .utility))
        #expect(DetectionSchedule.priority(for: budget) == .utility)
    }

    @Test func lowPowerOrHotMacMeansOneWalker() {
        for trigger in [DetectionTrigger.automatic, .user] {
            #expect(DetectionSchedule.budget(trigger, lowPowerMode: true, thermalState: .nominal).workers == 1)
            #expect(DetectionSchedule.budget(trigger, lowPowerMode: false, thermalState: .serious).workers == 1)
            #expect(DetectionSchedule.budget(trigger, lowPowerMode: false, thermalState: .critical).workers == 1)
        }
        // La QoS no cambia: solo se recorta el número de paseos.
        #expect(DetectionSchedule.budget(.automatic, lowPowerMode: true, thermalState: .critical).qos == .background)
        #expect(DetectionSchedule.trigger(after: .user) == .user)
        #expect(DetectionSchedule.trigger(after: .automatic) == .automatic)
        #expect(DetectionSchedule.trigger(after: .agent) == .automatic)
    }

    // MARK: Qué lee: el índice antes que el disco

    @Test func indexedCatalogPathIsNotWalked() async throws {
        let home = tempDir("detect-index")
        make(home, "Library/Caches/foo/blob")
        let catalog = Catalog(entries: [cacheEntry()])
        let root = index(base: home, relative: "Library/Caches/foo", size: 777_000)
        let (items, seen) = await walks { await scanner(catalog, home: home).findItems(scan: root) }
        #expect(items.map(\.bytes) == [777_000])
        #expect(seen.isEmpty, "\(seen)")
        // Sin índice, el disco: un paseo.
        let (live, walked) = await walks { await scanner(catalog, home: home).findItems(scan: nil) }
        #expect(live.count == 1 && live[0].bytes > 0 && live[0].bytes != 777_000)
        #expect(walked.map(\.0) == [home + "/Library/Caches/foo"])
    }

    @Test func indexedProjectArtifactTakesItsSizeFromTheIndexAndOnlyReadsNames() async throws {
        let home = tempDir("detect-project")
        let app = staleNodeApp(home)
        let catalog = try projectCatalog()
        let root = index(base: home, relative: "Projects/app/node_modules", size: 5_000_000)
        let (items, seen) = await walks { await scanner(catalog, home: home).findItems(scan: root) }
        let item = try #require(items.first)
        #expect(items.count == 1)
        #expect(item.paths == [app + "/node_modules"])
        #expect(item.bytes == 5_000_000)
        // node_modules: solo nombres (por si dentro hay otro Git o claves). Ningún paseo completo de ella.
        #expect(seen.contains { $0.0 == app + "/node_modules" && $0.1 == .names })
        #expect(!seen.contains { $0.0 == app + "/node_modules" && $0.1 == .full })
        // Mismo resultado (salvo el tamaño) que sin índice.
        let live = await scanner(catalog, home: home).findItems(scan: nil)
        #expect(live.map(\.id) == items.map(\.id))
        #expect(live.map(\.risk) == items.map(\.risk))
        #expect(live.map(\.preselected) == items.map(\.preselected))
    }

    @Test func namesOnlyWalkStillFindsNestedRepositoriesAndKeys() async throws {
        let home = tempDir("detect-guards")
        let app = staleNodeApp(home)
        make(app, "node_modules/dep/.git/HEAD")
        ageTree(app, days: 120)
        let catalog = try projectCatalog()
        let root = index(base: home, relative: "Projects/app/node_modules", size: 5_000_000)
        let item = try #require(await scanner(catalog, home: home).findItems(scan: root).first)
        #expect(item.risk == .doNotTouch)
        #expect(item.riskReason == "Contiene otro repositorio Git dentro.")
        #expect(TreeWalk.watchedNames(app, budget: .seconds(5), watch: { $0.hasSuffix("-keypair.json") }) == [])
        make(app, "node_modules/dep/id-keypair.json")
        #expect(TreeWalk.watchedNames(app, budget: .seconds(5), watch: { $0.hasSuffix("-keypair.json") })
            == ["node_modules/dep/id-keypair.json"])
    }

    // MARK: Dónde: con AIRY_SCAN_ROOTS, nada fuera de las raíces

    @Test func scopedDetectionNeverWalksOutsideItsRoots() async throws {
        let home = tempDir("detect-scope-home")
        _ = staleNodeApp(home)
        make(home, "Library/Caches/foo/blob")
        let roots = tempDir("detect-scope-roots")
        let bundled = try projectCatalog()
        let catalog = Catalog(entries: bundled.entries + [cacheEntry()])
        let scope = DiskScope(roots: [roots])
        let (items, seen) = await walks { await scanner(catalog, home: home, scope: scope).findItems(scan: nil) }
        #expect(items.isEmpty)
        #expect(seen.isEmpty, "\(seen)")
        // Sin ámbito, lo mismo sí se encuentra.
        #expect(await scanner(catalog, home: home).findItems(scan: nil).count == 2)
    }

    @Test func diskScopeContainsItsRootsAndReachesTheirAncestors() {
        // Ruta con enlace (`/var` → `/private/var`): valen las dos formas.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("airy-roots-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let linked = url.path
        let real = CleanupTargets.realPath(linked)!
        #expect(linked != real)
        let scope = DiskScope(roots: [linked])
        #expect(scope.contains(linked))
        #expect(scope.contains(real + "/a/b"))
        #expect(!scope.contains(linked + "X"))
        #expect(!scope.contains("/Users/ana/Projects"))
        #expect(scope.reaches((real as NSString).deletingLastPathComponent))
        #expect(scope.reaches("/"))
        #expect(!scope.reaches("/Users/ana"))
        #expect(DiskScope.allowsWalk("/Users/ana"))
        DiskScope.$current.withValue(scope) {
            #expect(!DiskScope.allowsWalk("/Users/ana"))
            #expect(TreeWalk.summarize("/Users", budget: .seconds(1)) == nil)
        }
    }

    // MARK: Cancelar suelta el disco

    @Test func cancelledWalkStopsAtOnce() async {
        let base = tempDir("detect-cancel")
        make(base, "a/x", "b/y")
        let task = Task { () -> (TreeSummary?, [String]?) in
            withUnsafeCurrentTask { $0?.cancel() }
            return (TreeWalk.summarize(base, budget: .seconds(5)),
                    TreeWalk.watchedNames(base, budget: .seconds(5), watch: { _ in true }))
        }
        let (summary, names) = await task.value
        #expect(summary == nil)
        #expect(names == nil)
    }
}
