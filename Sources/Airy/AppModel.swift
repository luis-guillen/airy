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
    /// Libre de verdad (`volumeAvailableCapacityKey`, lo que da `df`).
    let availableBytes: Int64
    /// Libre contando lo purgable (`volumeAvailableCapacityForImportantUsageKey`, lo que da Finder).
    let importantAvailableBytes: Int64

    var id: String { url.path }
    var symbol: String { isStartup ? "internaldrive.fill" : "externaldrive.fill" }

    static let startupFallback = Volume(url: URL(fileURLWithPath: "/"), name: "Macintosh HD",
                                        isStartup: true, totalBytes: 0, availableBytes: 0,
                                        importantAvailableBytes: 0)

    /// Lee los volúmenes montados (`skipHiddenVolumes`) y descarta los de solo lectura y los del sistema.
    static func mounted() -> [Volume] {
        let keys: [URLResourceKey] = [
            .volumeLocalizedNameKey, .volumeIsReadOnlyKey, .volumeIsRootFileSystemKey,
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
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
                availableBytes: Int64(values.volumeAvailableCapacity ?? 0),
                importantAvailableBytes: values.volumeAvailableCapacityForImportantUsage ?? 0))
        }
        if !volumes.contains(where: \.isStartup) { volumes.insert(startupFallback, at: 0) }
        return volumes.sorted { ($0.isStartup ? 0 : 1, $0.name) < ($1.isStartup ? 0 : 1, $1.name) }
    }
}

/// Aviso no bloqueante que la interfaz muestra como banner descartable.
struct Notice: Identifiable, Equatable {
    enum Kind: String { case scan, save, history, catalog, migration, url, settings, audit }
    let kind: Kind
    let message: String
    var id: String { kind.rawValue }
}

/// Orden de URL con identidad propia: dos `airy://rescan` seguidos son dos peticiones distintas.
struct PendingURLCommand: Identifiable, Equatable {
    let id = UUID()
    let command: AiryURLCommand
}

/// Estado global de la app. Todo lo pesado (análisis, lectura del índice, sondas, comandos)
/// corre fuera del hilo principal; aquí solo se publican los resultados.
@MainActor @Observable
final class AppModel {
    // MARK: Estado publicado

    var section: Section = .map
    var scan: ScanResult? {
        didSet { partialIndex = PartialScanIndex(inaccessible: scan?.inaccessible ?? []) }
    }
    /// Qué rutas del último análisis tienen algo ilegible dentro (su tamaño lleva «+»). Se ordena una vez por análisis.
    @ObservationIgnored private(set) var partialIndex = PartialScanIndex(inaccessible: [])
    /// Lo que dicen el Mapa y su pie: completo, parcial (N carpetas ilegibles) o sin análisis.
    var scanCompleteness: ScanCompleteness { .of(scan) }
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
    /// Pregunta que el mapa ("Explicar con IA") deja para el asistente; la consume `AssistantView`.
    var pendingAssistantQuestion: String?
    /// Informe, chat y Claude localizado: sobreviven a los cambios de sección.
    let assistant = AssistantSession()
    /// Orden de un enlace `airy://` pendiente de procesar: `RootView` la consume con su `CleanupFlow`.
    /// Nunca ejecuta nada: como mucho abre la hoja de confirmación.
    var pendingURLCommand: PendingURLCommand?
    /// Cualquier app o web puede abrir `airy://`: una ráfaga de enlaces se descarta.
    private var urlLimiter = URLCommandRateLimiter()
    /// Sube cada vez que el árbol mostrado cambia en sitio (p. ej. algo enviado a la Papelera).
    private(set) var treeRevision = 0

    var volumes: [Volume] = [.startupFallback]
    var selectedVolume: URL = URL(fileURLWithPath: "/") {
        didSet {
            guard oldValue != selectedVolume else { return }
            startScan(.automatic)
        }
    }

    // MARK: Dependencias

    let catalog: Catalog?
    let catalogError: String?
    let paths: AppPaths
    /// Registro de operaciones compartido con `airy-mcp`.
    let operationLog: OperationLog
    /// `settings.json`: se vuelve a leer al volver a la app y antes de cada acción destructiva.
    private var settingsSession: SettingsSession
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
    /// Almacén del índice que se está mostrando (para volver a guardarlo tras un cambio) y su clave.
    private var shownStore: IndexStore?
    private var shownStoreKey = "/"
    private let saveSequencer = SaveSequencer()
    private var lastSave: [String: Task<SaveResult, Never>] = [:]
    /// Rutas que una acción (Papelera o limpieza) quitó o cambió, con su hora. Un análisis que
    /// empezó antes pudo verlas como eran: al publicarlo se vuelven a medir solo esas.
    private var touchedPaths: [String: Date] = [:]

    init() {
        let paths = AppPaths.standard()
        self.paths = paths
        appDirectory = paths.support
        operationLog = OperationLog(file: paths.operationsFile)
        var migrationFailure: String?
        if case .failed(let reason) = DataMigration.migrateIfNeeded(paths) { migrationFailure = reason }
        store = IndexStore(directory: appDirectory)
        // Tras la migración: puede haber traído el `settings.json` del legado.
        settingsSession = SettingsSession(store: SettingsStore(file: paths.settingsFile))
        do {
            catalog = try Catalog.bundled()
            catalogError = nil
        } catch {
            catalog = nil
            catalogError = "No se pudo cargar el catálogo de limpiezas (\(error)). La sección Limpieza no está disponible."
        }
        if let catalogError { notices.append(Notice(kind: .catalog, message: catalogError)) }
        if let migrationFailure {
            notices.append(Notice(kind: .migration, message: "No se pudieron copiar los datos de \(AppPaths.legacyFolderName) (\(migrationFailure)). Siguen en su carpeta; Airy lo intentará otra vez al abrirse."))
        }
        syncSettingsNotice()
        observeSystem()
        refreshSystemState()
    }

    // MARK: Ajustes

    var settingsLoad: SettingsLoad { settingsSession.load }
    var settings: AirySettings { settingsLoad.effective }

    /// Aplica un cambio y lo guarda; si cambia el modo o la lista protegida, se vuelve a detectar.
    /// Con `settings.json` ilegible no guarda nada: antes hay que restablecerlo.
    func updateSettings(_ change: (inout AirySettings) -> Void) {
        do {
            if try settingsSession.update(change) { refreshCleanup() }
            syncSettingsNotice()
        } catch is SettingsSession.Unreadable {
            syncSettingsNotice()
        } catch {
            report(.settings, "No se pudieron guardar los ajustes (\(error.localizedDescription)).")
        }
    }

    /// «Restablecer ajustes»: vuelve a leer `settings.json`; si sigue ilegible, pide confirmación (diciendo
    /// qué se conserva y qué se pierde), lo aparta y escribe ajustes nuevos con lo rescatado. Avisa de
    /// lo que pasó (p. ej. que la lista «Proteger esto» no se pudo recuperar).
    func resetSettings() {
        guard let explanation = settingsSession.resetConfirmation() else {
            syncSettingsNotice()
            refreshCleanup()
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "¿Restablecer los ajustes de Airy?"
        alert.informativeText = explanation
        alert.addButton(withTitle: "Restablecer")
        alert.addButton(withTitle: "Cancelar")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            guard let result = try settingsSession.reset() else {
                syncSettingsNotice()
                refreshCleanup()
                return
            }
            report(.settings, result.message)
            refreshCleanup()
        } catch {
            report(.settings, "No se pudieron restablecer los ajustes (\(error.localizedDescription)).")
        }
    }

    /// «Proteger esto» (no destructivo: sin confirmación).
    func protect(path: String) { protect(paths: [path]) }

    func protect(paths: [String]) {
        let home = NSHomeDirectory()
        updateSettings { settings in for path in paths { _ = settings.protect(path, home: home) } }
    }

    func unprotect(_ pattern: String) {
        updateSettings { $0.unprotect(pattern) }
    }

    /// Aviso mientras `settings.json` no se puede leer, o `nil`.
    var unreadableSettingsNotice: String? { settingsSession.unreadableNotice }

    /// Motivo para no borrar nada ahora mismo (ajustes ilegibles), o `nil`.
    var destructiveRefusal: String? { settingsSession.destructiveRefusal }

    /// Clasificador con los ajustes cargados: el mismo para Limpieza, el mapa y el asistente.
    var classifier: RiskClassifier {
        RiskClassifier(catalog: catalog ?? Catalog(entries: []), settings: settings, home: NSHomeDirectory())
    }

    func classify(path: String) -> Classification { classifier.classify(path: path) }

    /// Vuelve a leer `settings.json`; si cambió, avisa y vuelve a detectar.
    func reloadSettings() {
        guard settingsSession.reload() else { return }
        syncSettingsNotice()
        refreshCleanup()
    }

    private func syncSettingsNotice() {
        if let notice = settingsSession.unreadableNotice { report(.settings, notice) } else { dismiss(.settings) }
    }

    /// Fallo cerrado: con los ajustes ilegibles no se borra nada (ni la Papelera).
    private func settingsRefusal() -> CleanupOutcome? {
        reloadSettings()
        return settingsSession.destructiveRefusal.map { .blocked(reason: $0) }
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

    // MARK: Enlaces airy://

    /// Entrada de `.onOpenURL`: valida y deja la orden pendiente. Una URL inválida solo avisa.
    func handle(url: URL) {
        guard urlLimiter.allow() else {
            report(.url, URLProposalPolicy.rateLimited)
            return
        }
        guard let command = AiryURLCommand(url: url) else {
            report(.url, "Airy no entendió ese enlace, así que no hizo nada.")
            return
        }
        pendingURLCommand = PendingURLCommand(command: command)
    }

    /// Procesa la orden pendiente (la llama `RootView`). Nunca ejecuta una limpieza por sí misma:
    /// una propuesta solo abre la hoja de confirmación, y el usuario es quien confirma.
    func run(_ pending: PendingURLCommand, flow: CleanupFlow) async {
        defer { if pendingURLCommand?.id == pending.id { pendingURLCommand = nil } }
        switch pending.command {
        case .rescan:
            section = .map
            if !isScanning { startScan(.agent) }
        case .show(let path):
            section = .map
            guard await waitUntil({ $0.scan != nil }) else { return }
            navigation.reveal(path: path)
        case .proposeQuit:
            // Plan 4 Task 14 lo sustituye por la confirmación de cierre (ConfirmSheet → AppModel → QuitExecutor).
            report(.url, "Un agente propuso cerrar una app; esta versión de Airy aún no lo admite.")
        case .propose(let target, let reason, let agent):
            // Nunca sustituye una hoja ya abierta (el usuario confirmaría otra cosa) ni una limpieza en curso.
            if let refusal = URLProposalPolicy.refusal(sheetOpen: flow.sheet != nil, busy: flow.isBusy) {
                report(.url, refusal)
                return
            }
            // El nombre lo pone quien abre el enlace: se enseña y se anota como algo que «dice ser».
            let claimed = URLProposalPolicy.claimedAgent(agent)
            let warning = CleanupFlow.ConfirmRequest.Warning(
                title: URLProposalPolicy.warningTitle(),
                subtitle: URLProposalPolicy.warningSubtitle(agent: agent, reason: reason),
                reason: URLProposalPolicy.warningReason,
                note: URLProposalPolicy.warningNote)
            let via = OperationContext.viaUnverifiedURL
            switch target {
            case .item(let id):
                section = .cleanup
                // La detección ya terminada (o la que está en curso) decide si el id sigue existiendo.
                guard await waitUntil({ !$0.isRefreshingCleanup && ($0.scan != nil || !$0.isScanning) }) else { return }
                guard let item = cleanupItems.first(where: { $0.id == id }) else {
                    report(.url, "Llegó por enlace una propuesta de «\(URLProposalPolicy.shortPath(id))», pero ya no aparece en Limpieza.")
                    return
                }
                guard item.protection == nil else {
                    report(.url, "Llegó por enlace una propuesta de «\(item.title)», pero es «No tocar»: Airy no lo ofrece.")
                    return
                }
                // Mientras se esperaba la detección pudo abrirse otra hoja o empezar una limpieza.
                if let refusal = URLProposalPolicy.refusal(sheetOpen: flow.sheet != nil, busy: flow.isBusy) {
                    report(.url, refusal)
                    return
                }
                flow.requestClean([item], warning: warning, proposedBy: claimed, proposedVia: via)
            case .path(let path):
                if let refusal = trashRefusal(path: path) {
                    report(.url, "Llegó por enlace una propuesta de mover «\(URLProposalPolicy.shortPath(path))» a la Papelera, pero Airy no puede: \(refusal)")
                    return
                }
                let title = path.split(separator: "/").last.map(String.init) ?? path
                flow.requestTrash(paths: [path], title: title, warning: warning, proposedBy: claimed, proposedVia: via)
            }
        }
    }

    /// Espera (hasta 2 minutos, cancelable) a que se cumpla `condition` en el hilo principal.
    private func waitUntil(_ condition: (AppModel) -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(120)
        while !condition(self) {
            guard !Task.isCancelled, Date() < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return !Task.isCancelled
    }

    // MARK: Derivados

    var currentVolume: Volume {
        volumes.first { $0.url == selectedVolume } ?? volumes.first ?? .startupFallback
    }

    /// Bytes que ocupa lo analizado ("Analizado"); en el primer análisis, lo que lleva recorrido.
    var analyzedBytes: Int64 { scan?.root.allocatedSize ?? progress?.bytesScanned ?? 0 }

    /// Reparto del disco: analizado, sistema y otros, purgable y libre (véase `DiskUsageBreakdown`).
    var diskUsage: DiskUsageBreakdown {
        let volume = currentVolume
        return DiskUsageBreakdown(totalBytes: volume.totalBytes, availableBytes: volume.availableBytes,
                                  importantAvailableBytes: volume.importantAvailableBytes,
                                  analyzedBytes: analyzedBytes)
    }

    var inaccessibleCount: Int { scan?.inaccessible.count ?? 0 }

    // MARK: Análisis

    /// Muestra al instante el índice guardado del volumen elegido, lo reanaliza en segundo
    /// plano con progreso, lo guarda y actualiza la limpieza. Cancela cualquier análisis anterior.
    /// Al abrir (`.automatic`) un índice de menos de 6 h no se reanaliza; los automáticos y los
    /// de un agente van con intensidad `background` (ver `ScanSchedule` y `ScanBudget`).
    func startScan(_ trigger: ScanTrigger = .user) {
        scanTask?.cancel()
        scanGeneration += 1
        let generation = scanGeneration
        dismiss(.scan)
        progress = nil
        isScanning = true
        #if DEBUG
        if DebugSnapshot.previewsScan {
            // Solo la pantalla: nada se lee ni se analiza ni se guarda.
            scan = nil
            progress = ScanProgress(filesScanned: 184_302, bytesScanned: 61_000_000_000,
                                    currentPath: "/Users/Shared/Ejemplo/Biblioteca/Fotos")
            return
        }
        #endif

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
            let expectedRoot = Self.expectedRootName(for: volume)
            let stored = await Task.detached(priority: .userInitiated) { () -> (ScanResult, Date?)? in
                guard let result = try? store.loadScan(), result.root.name == expectedRoot else { return nil }
                // La fecha del análisis va en el índice (no la del archivo: cada limpieza lo regraba).
                return (result, result.scannedAt)
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

            // 2. ¿Hace falta? Un índice reciente se queda (el mapa dice «Último análisis: hace…»).
            let intensity: ScanIntensity
            switch ScanSchedule.plan(trigger, hasIndex: stored != nil, indexDate: stored?.1, now: Date()) {
            case .skip:
                self.isScanning = false
                return
            case .scan(let level):
                intensity = level
            }

            // 3. Nuevo análisis con hilos y QoS limitados por la intensidad, cancelable.
            let scanStarted = Date()
            let scanner = DiskScanner(options: ScanOptions(roots: Self.scanRoots(for: volume)), intensity: intensity)
            let job = Task.detached(priority: intensity == .background ? .background : .utility) {
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

            // 4. Lo que se limpió o se envió a la Papelera mientras se analizaba no vuelve a salir.
            let touched = self.touchedPaths.filter { $0.value >= scanStarted }.map(\.key)
            if !touched.isEmpty {
                let measured = await Task.detached(priority: .userInitiated) {
                    ScanTreeRefresh.measure(touched)
                }.value
                guard generation == self.scanGeneration else { return }
                // El árbol nuevo aún no se ha publicado: nadie más lo recorre.
                ScanTreeRefresh.apply(measured, to: result.root)
            }
            self.touchedPaths = self.touchedPaths.filter { $0.value >= scanStarted }

            // 5. Publicar, guardar y refrescar la limpieza.
            self.show(result, date: result.scannedAt ?? Date(), volume: volume)
            self.isScanning = false
            self.progress = nil
            self.refreshSystemState()
            self.refreshCleanup()
            await self.saveIndex(result, to: store, key: volume.url.path)
        }
    }

    /// Raíces del análisis: el volumen entero. En DEBUG, `AIRY_SCAN_ROOTS` las sustituye
    /// (comprobaciones de la app sobre una carpeta pequeña en vez del disco).
    private static func scanRoots(for volume: Volume) -> [URL] {
        #if DEBUG
        if let roots = ScanRootsOverride.roots(from: ProcessInfo.processInfo.environment) { return roots }
        #endif
        return [volume.url]
    }

    /// Nombre de la raíz de un índice válido para este volumen (con varias raíces, el nodo sin nombre).
    private static func expectedRootName(for volume: Volume) -> String {
        let roots = scanRoots(for: volume)
        return roots.count == 1 ? roots[0].path : ""
    }

    /// Guarda el índice fuera del hilo principal. Recorre el árbol vivo, así que entra como
    /// lector de `treeGate` (no cancelable: un cambio espera a que termine de escribir).
    /// Los guardados de un mismo índice van de uno en uno (cada uno espera al anterior) y, justo
    /// antes de escribir, uno que ya no es el último pedido se salta: nunca queda en disco el
    /// árbol más antiguo.
    private func saveIndex(_ result: ScanResult, to store: IndexStore, key: String) async {
        #if DEBUG
        // Con AIRY_SCAN_ROOTS y sin AIRY_SUPPORT_DIR, el árbol parcial nunca pisa el índice real.
        guard ScanRootsOverride.allowsSaving(environment: ProcessInfo.processInfo.environment) else { return }
        #endif
        let sequencer = saveSequencer
        let ticket = sequencer.begin(key)
        let previous = lastSave[key]
        let job = treeGate.read(cancellable: false) { () -> SaveResult in
            _ = await previous?.value
            guard sequencer.isLatest(ticket, for: key) else { return .skipped }
            do { try store.saveScan(result); return .saved } catch { return .failed(error.localizedDescription) }
        }
        lastSave[key] = job
        let outcome = await job.value
        if lastSave[key] == job { lastSave[key] = nil }
        switch outcome {
        case .skipped: return
        case .saved: dismiss(.save)
        case .failed(let saveError):
            report(.save, "No se pudo guardar el análisis (\(saveError)). Se ve bien ahora, pero al volver a abrir Airy habrá que analizar de nuevo.")
        }
    }

    private enum SaveResult: Sendable { case saved, skipped, failed(String) }

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
        shownStoreKey = volume.url.path
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
        let inaccessible = scan?.inaccessible ?? []
        let classifier = classifier
        let scanner = catalog.map {
            CleanupScanner(catalog: $0, runner: runner, probes: probes, references: ReferenceChecker(),
                           classifier: classifier)
        }
        // Prioridad `.utility` también para la tarea que espera: si la esperara una tarea del hilo
        // principal (`.userInitiated`), la detección (que puede medir carpetas fuera del índice)
        // subiría a esa prioridad.
        cleanupTask = Task(priority: .utility) { [weak self] in
            await self?.refreshCounters()
            // Lee el árbol vivo: lector cancelable de `treeGate` (un cambio la cancela y la espera).
            guard let gate = self?.treeGate else { return }
            let job = gate.read(cancellable: true) {
                await scanner?.findItems(scan: root, inaccessible: inaccessible) ?? []
            }
            // La tarea suelta no hereda la cancelación: se le pasa a mano.
            let items = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
            // Solo publica la última detección completa: una cancelada (resultado parcial: p. ej.
            // sin comprobar referencias) o ya sustituida no se publica nunca.
            guard let self, !Task.isCancelled, !job.isCancelled, generation == self.cleanupGeneration else { return }
            self.cleanupItems = items
            self.isRefreshingCleanup = false
        }
    }

    /// Lo que haría cada elemento ahora (mismo plan que `perform`), sin hacerlo: la hoja de confirmación
    /// lo enseña fila a fila y no ejecuta lo bloqueado.
    func preview(_ items: [CleanupItem], context: OperationContext = .user()) async -> [String: CleanupPreview] {
        guard let executor else {
            return Dictionary(items.map { ($0.id, .blocked(reason: "No se pudo cargar el catálogo de limpiezas.")) },
                              uniquingKeysWith: { a, _ in a })
        }
        var previews: [String: CleanupPreview] = [:]
        // La vista previa de la hoja no es una operación: no se anota en el registro.
        for item in items { previews[item.id] = await executor.preview(item, context: context, logged: false) }
        return previews
    }

    /// Ejecuta una limpieza del catálogo (con revalidación completa) y refresca los contadores.
    /// La interfaz es la que confirma antes de llamar aquí.
    /// `refreshesCleanup: false` para tandas: quien llama refresca la detección una sola vez al final.
    func perform(_ item: CleanupItem, context: OperationContext = .user(),
                 refreshesCleanup: Bool = true) async -> CleanupOutcome {
        if let refusal = settingsRefusal() { return refusal }
        guard let executor else { return .failed("No se pudo cargar el catálogo de limpiezas.") }
        let outcome = await executor.execute(item, context: context)
        switch outcome {
        case .freed, .movedToTrash: await updateTree(afterTouching: item.paths)
        case .blocked, .failed: break
        }
        await refreshCounters()
        await refreshVolumes()
        if refreshesCleanup { refreshCleanup() }
        reportAuditFailure()
        return outcome
    }

    /// Si no se pudo anotar algo en el registro de operaciones o en el historial, se dice (no se calla).
    private func reportAuditFailure() {
        guard let failure = operationLog.takeWriteFailure() else { return }
        report(.audit, "Airy hizo la operación, pero \(failure). El registro exportable puede estar incompleto.")
    }

    /// Envía rutas elegidas en el mapa a la Papelera con todas las comprobaciones de
    /// `CleanupExecutor.trashPaths`, las quita del árbol mostrado y refresca como `perform`.
    /// La interfaz es la que confirma antes de llamar aquí.
    func trash(paths: [String], title: String, context: OperationContext = .user()) async -> CleanupOutcome {
        if let refusal = settingsRefusal() { return refusal }
        guard let executor else { return .failed("No se pudo cargar el catálogo de limpiezas.") }
        let outcome = await executor.trashPaths(paths, title: title, context: context)
        // Lo que ya no está en su sitio sale del mapa (también si se movió solo una parte).
        // Orden: (1) se buscan los nodos aquí (hilo principal, dueño del árbol); (2) `treeGate`
        // cancela la detección de limpiezas en curso y ESPERA a todos los lectores (también a
        // que termine de guardarse el índice); (3) se cambia el árbol; (4) se vuelve a guardar
        // el índice ya sin lo borrado y se detectan de nuevo las limpiezas.
        let now = Date()
        let gone = paths.compactMap { path -> FileNode? in
            var info = stat()
            guard lstat(path, &info) != 0 else { return nil }
            touchedPaths[path] = now
            return node(atPath: path)
        }
        if !gone.isEmpty, let scan {
            // La detección en curso queda invalidada (no publicará nada) y se repite al final.
            cleanupTask?.cancel()
            cleanupGeneration += 1
            isRefreshingCleanup = true
            await treeGate.mutate { [weak self] in
                for node in gone { node.removeFromParent() }
                self?.treeRevision += 1
            }
            // El índice se vuelve a guardar sin esperar (por el turno del árbol): el resultado
            // de la Papelera vuelve enseguida aunque guardar todo el árbol tarde unos segundos.
            if let shownStore, self.scan?.root === scan.root {
                let key = shownStoreKey
                Task { [weak self] in await self?.saveIndex(scan, to: shownStore, key: key) }
            }
        }
        await refreshCounters()
        await refreshVolumes()
        refreshCleanup()
        reportAuditFailure()
        return outcome
    }

    /// Tras una limpieza, vuelve a medir sus rutas (fuera del hilo principal) y pone al día el árbol
    /// mostrado: lo que ya no existe sale; lo que sigue (p. ej. una caché limpiada con su comando,
    /// que deja la carpeta) queda con su tamaño nuevo. Así ni el mapa ni la detección de limpiezas
    /// (que prefiere el tamaño del árbol) lo enseñan con el tamaño de antes. Luego se vuelve a
    /// guardar el índice por el turno de guardado.
    private func updateTree(afterTouching paths: [String]) async {
        guard !paths.isEmpty else { return }
        let now = Date()
        for path in paths { touchedPaths[path] = now }
        guard let scan else { return }
        let measured = await Task.detached(priority: .userInitiated) { ScanTreeRefresh.measure(paths) }.value
        guard self.scan?.root === scan.root else { return }
        // La detección en curso queda invalidada (no publicará nada); `perform` la repite al final.
        cleanupTask?.cancel()
        cleanupGeneration += 1
        var changed = false
        await treeGate.mutate { [weak self] in
            guard let self, self.scan?.root === scan.root else { return }
            changed = ScanTreeRefresh.apply(measured, to: scan.root)
            if changed { self.treeRevision += 1 }
        }
        if changed, let shownStore, self.scan?.root === scan.root {
            let key = shownStoreKey
            Task { [weak self] in await self?.saveIndex(scan, to: shownStore, key: key) }
        }
    }

    /// `true` si "Mover a la Papelera…" tiene sentido para esta ruta: la misma regla que aplicará
    /// `CleanupExecutor.trashPaths` (protegidas, "No tocar", cachés con comando oficial…).
    func canOfferTrash(path: String) -> Bool {
        guard let executor else { return false }
        return !executor.wouldRefuseTrash(path: path)
    }

    /// Motivo por el que `trashPaths` rechazaría esta ruta, o `nil` si podría ofrecerse.
    func trashRefusal(path: String) -> String? {
        guard let executor else { return "el catálogo de limpiezas no está disponible." }
        return executor.unsafeTrashReason(path)
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
    func emptyTrash(context: OperationContext = .user()) async -> CleanupOutcome {
        let outcome: CleanupOutcome
        if let refusal = settingsRefusal() {
            outcome = refusal
        } else if let executor {
            outcome = await executor.emptyTrash(context: context)
        } else {
            outcome = .failed("No se pudo cargar el catálogo de limpiezas.")
        }
        await refreshVolumes()
        await refreshCounters()
        refreshCleanup()
        reportAuditFailure()
        return outcome
    }

    /// Ajustes leídos de disco en cada operación (nunca cacheados) y registro de operaciones compartido con `airy-mcp`.
    private var executor: CleanupExecutor? {
        let settings = settingsSession.store
        let log = operationLog
        return catalog.map {
            CleanupExecutor(runner: runner, probes: probes, store: store, catalog: $0,
                            settings: { settings.load() }, log: log)
        }
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
            MainActor.assumeIsolated {
                self?.reloadSettings()
                self?.refreshSystemState()
            }
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
