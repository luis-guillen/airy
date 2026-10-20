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
    var trashBytes: Int64 = 0
    var totalFreed: Int64 = 0
    var hasFullDiskAccess = true
    var navigation = MapNavigation()
    /// Fecha del análisis mostrado (la del índice guardado hasta que termina el nuevo).
    var lastScanDate: Date?
    var scanError: String?

    var volumes: [Volume] = [.startupFallback]
    var selectedVolume: URL = URL(fileURLWithPath: "/") {
        didSet {
            guard oldValue != selectedVolume else { return }
            startScan()
        }
    }

    // MARK: Dependencias

    let catalog: Catalog?
    private let runner = ProcessRunner()
    private let probes = SystemProbes()
    private let appDirectory: URL
    /// Índice del disco de arranque e historial de limpiezas.
    private let store: IndexStore
    private var scanTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var scanGeneration = 0
    private var observers: [NSObjectProtocol] = []

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
        catalog = try? Catalog.bundled()
        volumes = Volume.mounted()
        hasFullDiskAccess = probes.hasFullDiskAccess()
        observeSystem()
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
        let volume = currentVolume
        let store = store(for: volume)
        scanError = nil
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
            // 1. Índice guardado, leído fuera del hilo principal.
            let stored = await Task.detached(priority: .userInitiated) { () -> (ScanResult, Date?)? in
                guard let result = try? store.loadScan(), result.root.name == volume.url.path else { return nil }
                return (result, try? store.lastScanDate())
            }.value
            guard let self, generation == self.scanGeneration else { return }
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
                        self.scanError = "No se pudo analizar «\(volume.name)»: \(error.localizedDescription)"
                    }
                }
                return
            }
            guard generation == self.scanGeneration else { return }

            // 3. Publicar, guardar y refrescar la limpieza.
            self.show(result, date: Date(), volume: volume)
            self.isScanning = false
            self.progress = nil
            self.hasFullDiskAccess = self.probes.hasFullDiskAccess()
            self.refreshCleanup()
            Task.detached(priority: .utility) { try? store.saveScan(result) }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanGeneration += 1
        isScanning = false
        progress = nil
    }

    private func show(_ result: ScanResult, date: Date?, volume: Volume) {
        scan = result
        lastScanDate = date
        navigation = MapNavigation(root: result.root, rootTitle: volume.name)
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
        isRefreshingCleanup = true
        let root = scan?.root
        let scanner = catalog.map {
            CleanupScanner(catalog: $0, runner: runner, probes: probes, references: ReferenceChecker())
        }
        cleanupTask = Task { [weak self] in
            await self?.refreshCounters()
            let items = await Task.detached(priority: .utility) {
                await scanner?.findItems(scan: root) ?? []
            }.value
            guard let self, !Task.isCancelled else { return }
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
        refreshCleanup()
        return outcome
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
        volumes = Volume.mounted()
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
        let (trash, freed) = await Task.detached(priority: .utility) {
            (probes.trashSize(), (try? store.totalFreed()) ?? 0)
        }.value
        trashBytes = trash
        totalFreed = freed
    }

    // MARK: Sistema

    func openFullDiskAccessSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Al volver a la app se comprueba de nuevo el permiso; al montar o expulsar discos, la lista.
    private func observeSystem() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hasFullDiskAccess = self.probes.hasFullDiskAccess()
                self.volumes = Volume.mounted()
            }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.volumes = Volume.mounted()
                    if !self.volumes.contains(where: { $0.url == self.selectedVolume }) {
                        self.selectedVolume = URL(fileURLWithPath: "/")
                    }
                }
            })
        }
    }
}
