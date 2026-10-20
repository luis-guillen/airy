import AppKit
import Foundation
import Observation
import DiskMapCore

/// Secciones de la barra lateral. Las de la fase 2 aparecen deshabilitadas con "Próximamente".
enum Section: String, CaseIterable, Identifiable, Hashable {
    case map, cleanup, assistant
    case uninstaller, largeOld, duplicates, types

    var id: String { rawValue }

    var title: String {
        switch self {
        case .map: "Mapa"
        case .cleanup: "Limpieza"
        case .assistant: "Asistente IA"
        case .uninstaller: "Desinstalador"
        case .largeOld: "Grandes y viejos"
        case .duplicates: "Duplicados"
        case .types: "Tipos de archivo"
        }
    }

    var symbol: String {
        switch self {
        case .map: "square.grid.3x3.square"
        case .cleanup: "sparkles"
        case .assistant: "brain.head.profile"
        case .uninstaller: "xmark.app"
        case .largeOld: "calendar.badge.clock"
        case .duplicates: "doc.on.doc"
        case .types: "chart.pie"
        }
    }

    var isAvailable: Bool {
        switch self {
        case .map, .cleanup, .assistant: true
        default: false
        }
    }

    static let available: [Section] = allCases.filter(\.isAvailable)
    static let comingSoon: [Section] = allCases.filter { !$0.isAvailable }
}

/// Volumen analizable: el de arranque y los externos montados con escritura.
struct Volume: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let isStartup: Bool
    let totalBytes: Int64
    let availableBytes: Int64

    var id: String { url.path }
    var symbol: String { isStartup ? "internaldrive.fill" : "externaldrive.fill" }

    static let startupFallback = Volume(url: URL(fileURLWithPath: "/"), name: "Macintosh HD",
                                        isStartup: true, totalBytes: 0, availableBytes: 0)

    /// Lee los volúmenes montados (`skipHiddenVolumes`) y descarta los de solo lectura y los del sistema.
    static func mounted() -> [Volume] {
        let keys: [URLResourceKey] = [
            .volumeLocalizedNameKey, .volumeIsReadOnlyKey, .volumeIsRootFileSystemKey,
            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        var volumes: [Volume] = []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let isStartup = url.path == "/" || values.volumeIsRootFileSystem == true
            if !isStartup {
                if values.volumeIsReadOnly == true || url.path.hasPrefix("/System/Volumes") { continue }
            }
            volumes.append(Volume(
                url: isStartup ? URL(fileURLWithPath: "/") : url,
                name: values.volumeLocalizedName ?? (isStartup ? "Macintosh HD" : url.lastPathComponent),
                isStartup: isStartup,
                totalBytes: Int64(values.volumeTotalCapacity ?? 0),
                availableBytes: values.volumeAvailableCapacityForImportantUsage ?? 0))
        }
        if !volumes.contains(where: \.isStartup) { volumes.insert(startupFallback, at: 0) }
        return volumes.sorted { ($0.isStartup ? 0 : 1, $0.name) < ($1.isStartup ? 0 : 1, $1.name) }
    }
}

/// Aviso no bloqueante que la interfaz muestra como banner descartable.
struct Notice: Identifiable, Equatable {
    enum Kind: String { case scan, save, history, catalog }
    let kind: Kind
    let message: String
    var id: String { kind.rawValue }
}

/// Estado global de la app. Todo lo pesado (análisis, lectura del índice, sondas, comandos)
/// corre fuera del hilo principal; aquí solo se publican los resultados.
@MainActor @Observable
final class AppModel {
    // MARK: Estado publicado

    var section: Section = .map
    var scan: ScanResult?
    var progress: ScanProgress?
    var isScanning = false
    var cleanupItems: [CleanupItem] = []
    var isRefreshingCleanup = false
    /// `nil` si `~/.Trash` no se puede leer (sin Acceso total al disco): "no se sabe", no "vacía".
    var trashBytes: Int64? = 0
    var totalFreed: Int64 = 0
    /// `false` si el historial no se pudo leer: `totalFreed` es el último valor conocido.
    var totalFreedKnown = true
    var hasFullDiskAccess = true
    var navigation = MapNavigation()
    /// Fecha del análisis mostrado (la del índice guardado hasta que termina el nuevo).
    var lastScanDate: Date?
    /// Error del último análisis. Sin análisis que mostrar ocupa la pantalla; si no, va en `notices`.
    var scanError: String?
    /// Problemas que no impiden usar la app pero cambian lo que significan los números.
    var notices: [Notice] = []
    /// Pregunta que el mapa ("Explicar con IA") deja para el asistente; la consume la Tarea 11.
    var pendingAssistantQuestion: String?
    /// Sube cada vez que el árbol mostrado cambia en sitio (p. ej. algo enviado a la Papelera).
    private(set) var treeRevision = 0

    var volumes: [Volume] = [.startupFallback]
    var selectedVolume: URL = URL(fileURLWithPath: "/") {
        didSet {
            guard oldValue != selectedVolume else { return }
            startScan()
        }
    }

    // MARK: Dependencias

    let catalog: Catalog?
    let catalogError: String?
    private let runner = ProcessRunner()
    private let probes = SystemProbes()
    private let appDirectory: URL
    /// Índice del disco de arranque e historial de limpiezas.
    private let store: IndexStore
    private var scanTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var scanGeneration = 0
    private var cleanupGeneration = 0
    private var observers: [NSObjectProtocol] = []
    /// Turno de acceso al árbol vivo: lectores en segundo plano frente a cambios (Papelera).
    let treeGate = TreeGate()
    /// Almacén del índice que se está mostrando (para volver a guardarlo tras un cambio).
    private var shownStore: IndexStore?

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        var directory = support.appendingPathComponent("DiskMap", isDirectory: true)
        #if DEBUG
        // Solo para revisar la interfaz: datos en otra carpeta (p. ej. primer arranque sin índice).
        if let override = ProcessInfo.processInfo.environment["DISKMAP_SUPPORT_DIR"] {
            directory = URL(fileURLWithPath: override, isDirectory: true)
        }
        #endif
        appDirectory = directory
        store = IndexStore(directory: appDirectory)
        do {
            catalog = try Catalog.bundled()
            catalogError = nil
        } catch {
            catalog = nil
            catalogError = "No se pudo cargar el catálogo de limpiezas (\(error)). La sección Limpieza no está disponible."
        }
        if let catalogError { notices.append(Notice(kind: .catalog, message: catalogError)) }
        observeSystem()
        refreshSystemState()
    }

    // MARK: Avisos

    func report(_ kind: Notice.Kind, _ message: String) {
        notices.removeAll { $0.kind == kind }
        notices.append(Notice(kind: kind, message: message))
    }

    func dismiss(_ kind: Notice.Kind) {
        notices.removeAll { $0.kind == kind }
        if kind == .scan { scanError = nil }
    }

    // MARK: Derivados

    var currentVolume: Volume {
        volumes.first { $0.url == selectedVolume } ?? volumes.first ?? .startupFallback
    }

    /// Bytes que ocupa lo analizado ("Tus archivos"); en el primer análisis, lo que lleva recorrido.
    var analyzedBytes: Int64 { scan?.root.allocatedSize ?? progress?.bytesScanned ?? 0 }

    /// Reparto del disco: lo analizado, el resto ocupado (sistema y purgable) y lo libre.
    var diskUsage: (userFiles: Int64, systemAndPurgeable: Int64, free: Int64, total: Int64) {
        let volume = currentVolume
        let total = max(volume.totalBytes, 0)
        let free = min(max(volume.availableBytes, 0), total)
        let used = total - free
        let user = min(analyzedBytes, used)
        return (user, max(used - user, 0), free, total)
    }

    var inaccessibleCount: Int { scan?.inaccessible.count ?? 0 }

    // MARK: Análisis

    /// Muestra al instante el índice guardado del volumen elegido, lo reanaliza en segundo
    /// plano con progreso, lo guarda y actualiza la limpieza. Cancela cualquier análisis anterior.
    func startScan() {
        scanTask?.cancel()
        scanGeneration += 1
        let generation = scanGeneration
        dismiss(.scan)
        progress = nil
        isScanning = true

        // Llega como mucho cada 100 ms desde los hilos del escáner.
        let onProgress: @Sendable (ScanProgress) -> Void = { [weak self] snapshot in
            Task { @MainActor [weak self] in
                guard let self, generation == self.scanGeneration else { return }
                self.progress = snapshot
            }
        }

        scanTask = Task { [weak self] in
            // 0. Volúmenes al día (capacidades y nombre), leídos fuera del hilo principal.
            await self?.refreshVolumes()
            guard let self, generation == self.scanGeneration else { return }
            let volume = self.currentVolume
            let store = self.store(for: volume)

            // 1. Índice guardado, leído fuera del hilo principal.
            let stored = await Task.detached(priority: .userInitiated) { () -> (ScanResult, Date?)? in
                guard let result = try? store.loadScan(), result.root.name == volume.url.path else { return nil }
                return (result, try? store.lastScanDate())
            }.value
            guard generation == self.scanGeneration else { return }
            if let (result, date) = stored {
                self.show(result, date: date, volume: volume)
                self.refreshCleanup()
            } else {
                self.scan = nil
                self.lastScanDate = nil
                self.navigation = MapNavigation(rootTitle: volume.name)
            }

            // 2. Nuevo análisis en paralelo, cancelable.
            let scanner = DiskScanner(options: ScanOptions(roots: [volume.url]))
            let job = Task.detached(priority: .userInitiated) {
                try await scanner.scan(progress: onProgress)
            }
            let result: ScanResult
            do {
                result = try await withTaskCancellationHandler {
                    try await job.value
                } onCancel: {
                    job.cancel()
                }
            } catch {
                if generation == self.scanGeneration {
                    self.isScanning = false
                    if !(error is CancellationError) {
                        let message = "No se pudo analizar «\(volume.name)»: \(error.localizedDescription)"
                        self.scanError = message
                        self.report(.scan, message)
                    }
                }
                return
            }
            guard generation == self.scanGeneration else { return }

            // 3. Publicar, guardar y refrescar la limpieza.
            self.show(result, date: Date(), volume: volume)
            self.isScanning = false
            self.progress = nil
            self.refreshSystemState()
            self.refreshCleanup()
            await self.saveIndex(result, to: store)
        }
    }

    /// Guarda el índice fuera del hilo principal. Recorre el árbol vivo, así que entra como
    /// lector de `treeGate` (no cancelable: un cambio espera a que termine de escribir).
    private func saveIndex(_ result: ScanResult, to store: IndexStore) async {
        let saveError = await treeGate.read(cancellable: false) { () -> String? in
            do { try store.saveScan(result); return nil } catch { return error.localizedDescription }
        }.value
        if let saveError {
            report(.save, "No se pudo guardar el análisis (\(saveError)). Se ve bien ahora, pero al volver a abrir DiskMap habrá que analizar de nuevo.")
        } else {
            dismiss(.save)
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanGeneration += 1
        isScanning = false
        progress = nil
    }

    /// Publica un árbol. Si es del mismo volumen que el que se ve, se conserva el nivel del mapa
    /// (tan hondo como siga existiendo) en vez de volver a la raíz.
    private func show(_ result: ScanResult, date: Date?, volume: Volume) {
        let sameRoot = navigation.root?.name == result.root.name && navigation.rootTitle == volume.name
        scan = result
        shownStore = store(for: volume)
        lastScanDate = date
        navigation = sameRoot ? navigation.restoring(in: result.root)
                              : MapNavigation(root: result.root, rootTitle: volume.name)
    }

    /// El disco de arranque usa el almacén principal; cada externo, su propia carpeta.
    private func store(for volume: Volume) -> IndexStore {
        guard !volume.isStartup else { return store }
        let safeName = volume.url.path.replacingOccurrences(of: "/", with: "_")
        return IndexStore(directory: appDirectory.appendingPathComponent("Volumes/\(safeName)", isDirectory: true))
    }

    // MARK: Limpieza

    /// Vuelve a detectar las limpiezas sobre el último análisis y actualiza Papelera y total liberado.
    func refreshCleanup() {
        cleanupTask?.cancel()
        cleanupGeneration += 1
        let generation = cleanupGeneration
        isRefreshingCleanup = true
        let root = scan?.root
        let scanner = catalog.map {
            CleanupScanner(catalog: $0, runner: runner, probes: probes, references: ReferenceChecker())
        }
        cleanupTask = Task { [weak self] in
            await self?.refreshCounters()
            // Lee el árbol vivo: lector cancelable de `treeGate` (un cambio la cancela y la espera).
            guard let gate = self?.treeGate else { return }
            let job = gate.read(cancellable: true) {
                await scanner?.findItems(scan: root) ?? []
            }
            // La tarea suelta no hereda la cancelación: se le pasa a mano.
            let items = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
            // Solo publica la última detección; las anteriores se descartan.
            guard let self, generation == self.cleanupGeneration else { return }
            self.cleanupItems = items
            self.isRefreshingCleanup = false
        }
    }

    /// Ejecuta una limpieza del catálogo (con revalidación completa) y refresca los contadores.
    /// La interfaz es la que confirma antes de llamar aquí.
    func perform(_ item: CleanupItem) async -> CleanupOutcome {
        guard let executor else { return .failed("No se pudo cargar el catálogo de limpiezas.") }
        let outcome = await executor.execute(item)
        await refreshCounters()
        await refreshVolumes()
        refreshCleanup()
        return outcome
    }

    /// Envía rutas elegidas en el mapa a la Papelera con todas las comprobaciones de
    /// `CleanupExecutor.trashPaths`, las quita del árbol mostrado y refresca como `perform`.
    /// La interfaz es la que confirma antes de llamar aquí.
    func trash(paths: [String], title: String) async -> CleanupOutcome {
        guard let executor else { return .failed("No se pudo cargar el catálogo de limpiezas.") }
        let outcome = await executor.trashPaths(paths, title: title)
        // Lo que ya no está en su sitio sale del mapa (también si se movió solo una parte).
        // Orden: (1) se buscan los nodos aquí (hilo principal, dueño del árbol); (2) `treeGate`
        // cancela la detección de limpiezas en curso y ESPERA a todos los lectores (también a
        // que termine de guardarse el índice); (3) se cambia el árbol; (4) se vuelve a guardar
        // el índice ya sin lo borrado y se detectan de nuevo las limpiezas.
        let gone = paths.compactMap { path -> FileNode? in
            var info = stat()
            return lstat(path, &info) != 0 ? node(atPath: path) : nil
        }
        if !gone.isEmpty, let scan {
            cleanupTask?.cancel()
            await treeGate.mutate { [weak self] in
                for node in gone { node.removeFromParent() }
                self?.treeRevision += 1
            }
            if let shownStore, self.scan?.root === scan.root {
                await saveIndex(scan, to: shownStore)
            }
        }
        await refreshCounters()
        await refreshVolumes()
        refreshCleanup()
        return outcome
    }

    /// Nodo del análisis mostrado para una ruta absoluta, bajando por nombre desde la raíz.
    func node(atPath path: String) -> FileNode? {
        guard let root = scan?.root else { return nil }
        let rootPath = root.path
        var rest: Substring
        if rootPath == "/" {
            rest = Substring(path)
        } else if path == rootPath || path.hasPrefix(rootPath + "/") {
            rest = path.dropFirst(rootPath.count)
        } else {
            return nil
        }
        var cursor = root
        for name in rest.split(separator: "/") {
            guard let next = cursor.children.first(where: { $0.name == name && $0.aggregatedCount == 0 }) else {
                return nil
            }
            cursor = next
        }
        return cursor === root ? nil : cursor
    }

    /// Vacía la Papelera sin preguntar: la interfaz debe confirmarlo antes.
    /// Ojo: si `~/.Trash` no se puede leer, se recurre a Finder, que vacía la Papelera de
    /// **todos** los volúmenes, no solo la del disco de arranque; la confirmación debe avisarlo.
    @discardableResult
    func emptyTrash() async -> CleanupOutcome {
        let outcome: CleanupOutcome
        if let executor {
            outcome = await executor.emptyTrash()
        } else {
            outcome = .failed("No se pudo cargar el catálogo de limpiezas.")
        }
        await refreshVolumes()
        await refreshCounters()
        refreshCleanup()
        return outcome
    }

    private var executor: CleanupExecutor? {
        catalog.map { CleanupExecutor(runner: runner, probes: probes, store: store, catalog: $0) }
    }

    /// Papelera y total liberado, leídos fuera del hilo principal.
    private func refreshCounters() async {
        let probes = probes
        let store = store
        let (trash, freed) = await Task.detached(priority: .utility) { () -> (Int64?, Result<Int64, Error>) in
            (probes.trashSizeIfReadable(), Result { try store.totalFreed() })
        }.value
        trashBytes = trash
        switch freed {
        case .success(let bytes):
            totalFreed = bytes
            totalFreedKnown = true
            dismiss(.history)
        case .failure(let error):
            // Se conserva el último valor conocido y se avisa: nunca un 0 que parezca real.
            totalFreedKnown = false
            report(.history, "No se pudo leer el historial de limpiezas (\(error.localizedDescription)). El total liberado puede no estar al día.")
        }
    }

    // MARK: Sistema

    func openFullDiskAccessSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Lee los volúmenes montados (E/S de disco) fuera del hilo principal y publica el resultado.
    /// Si el volumen elegido ya no está montado, vuelve al de arranque.
    func refreshVolumes() async {
        let mounted = await Task.detached(priority: .userInitiated) { Volume.mounted() }.value
        volumes = mounted
        if !mounted.contains(where: { $0.url == selectedVolume }) {
            selectedVolume = URL(fileURLWithPath: "/")
        }
    }

    /// Permiso de Acceso total al disco y volúmenes, ambos leídos fuera del hilo principal.
    func refreshSystemState() {
        let probes = probes
        Task { [weak self] in
            let access = await Task.detached(priority: .utility) { probes.hasFullDiskAccess() }.value
            self?.hasFullDiskAccess = access
            await self?.refreshVolumes()
        }
    }

    /// Al volver a la app se comprueba de nuevo el permiso; al montar o expulsar discos, la lista.
    private func observeSystem() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSystemState() }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    Task { await self.refreshVolumes() }
                }
            })
        }
    }
}
