import AppKit
import Foundation
import Observation
import DiskMapCore

/// Estado de Rendimiento. Ligereza: mide cada 1,5 s **solo** entre `start()` y `stop()` (sección a la vista,
/// ventana visible); fuera de eso no hay ningún temporizador ni tarea viva.
@MainActor @Observable
final class PerformanceSession {
    static let interval: Duration = .milliseconds(1500)

    private(set) var snapshot: PerformanceSnapshot?
    private(set) var verdict: HealthVerdict?
    private(set) var board = PerformanceBoard(snapshot: nil, policy: QuitPolicy())
    var selection: Set<String> = []
    /// Ids que no se cerraron con el cierre normal (`.didNotClose`): se pueden forzar.
    private(set) var unresponsive: Set<String> = []
    /// Ids que salen volando de la lista (se cerraron).
    private(set) var leaving: Set<String> = []
    /// Mensaje de la última acción por fila (`.blocked`/`.failed`).
    private(set) var rowMessages: [String: String] = [:]
    /// Ids que se están cerrando ahora mismo.
    private(set) var closing: Set<String> = []
    private(set) var loginItems: [BrokenLoginItem] = []
    private(set) var maintenance: [CleanupItem] = []
    private(set) var maintenanceResults: [String: String] = [:]
    private(set) var spotlight: SpotlightDiagnosis?
    private(set) var isCheckingSpotlight = false

    let monitor: PerformanceMonitor
    @ObservationIgnored weak var model: AppModel?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let runner = ProcessRunner()
    @ObservationIgnored private let probes: DiagnosisProbes
    @ObservationIgnored private var maintenanceCheckedAt: Date?

    init() {
        let catalog = try? AppCatalog.bundled()
        monitor = PerformanceMonitor(sampler: LiveSampler(runner: runner)) { raw, cpu, energy in
            AppGrouper.group(raw, cpu: cpu, energy: energy, catalog: catalog)
        }
        probes = DiagnosisProbes(runner: runner)
    }

    var isRunning: Bool { task != nil }

    /// Idempotente: una sola tarea de muestreo.
    func start() {
        guard task == nil else { return }
        Self.debugLog("start")
        let monitor = monitor
        let probes = probes
        task = Task { [weak self] in
            // M1: el historial empieza de cero en cada visita, antes de la primera muestra (sin carreras con `stop()`).
            await monitor.reset()
            while !Task.isCancelled {
                let snapshot = await monitor.refresh()
                Self.debugLog("sample")
                let verdict = await monitor.verdict(probes: probes)
                Self.debugLog("verdict")
                guard !Task.isCancelled else { break }
                self?.publish(snapshot, verdict: verdict)
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    /// Para todo: ninguna medición después.
    func stop() {
        if task != nil { Self.debugLog("stop") }
        task?.cancel()
        task = nil
        // I2: nada de una visita sirve en la siguiente (ni para la vista ni para una propuesta `airy://quit`).
        snapshot = nil
        verdict = nil
        board = PerformanceBoard(snapshot: nil, policy: QuitPolicy())
    }

    /// Solo en Debug con `AIRY_PERF_LOG=1`: traza del muestreo (para comprobar que se para).
    nonisolated static func debugLog(_ event: String) {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["AIRY_PERF_LOG"] == "1" else { return }
        FileHandle.standardError.write(Data("[perf] \(Date().timeIntervalSince1970) \(event)\n".utf8))
        #endif
    }

    private func publish(_ snapshot: PerformanceSnapshot, verdict: HealthVerdict) {
        self.snapshot = snapshot
        self.verdict = verdict
        board = PerformanceBoard(snapshot: snapshot, policy: QuitPolicy())
        let alive = Set(snapshot.groups.map(\.id))
        // Lo que ya no existe deja de estar seleccionado, en salida o sin responder.
        selection.formIntersection(alive)
        unresponsive.formIntersection(alive)
        if !leaving.isEmpty { leaving.formIntersection(alive) }
        rowMessages = rowMessages.filter { alive.contains($0.key) }
    }

    /// Para `airy://quit`: una instantánea tomada después de la petición (I2). Espera a la del muestreo de la
    /// sección; si no llega (ventana oculta, sección sin abrir), mide una vez.
    func freshSnapshot() async -> PerformanceSnapshot {
        let requested = Date()
        for _ in 0..<20 {
            if let snapshot, snapshot.date >= requested { return snapshot }
            try? await Task.sleep(for: .milliseconds(150))
        }
        if let snapshot, snapshot.date >= requested { return snapshot }
        return await monitor.snapshot(since: requested)
    }

    // MARK: Cerrar

    func markClosing(_ id: String, _ on: Bool) {
        if on { closing.insert(id); rowMessages[id] = nil } else { closing.remove(id) }
    }

    func markClosed(_ id: String) {
        selection.remove(id)
        unresponsive.remove(id)
        _ = leaving.insert(id)
    }

    func markUnresponsive(_ id: String) { unresponsive.insert(id) }

    func setMessage(_ id: String, _ message: String) { rowMessages[id] = message }

    /// Filas a la vista: sin las que ya salieron.
    var visibleRows: [PerformanceRow] { board.rows.filter { !leaving.contains($0.id) } }

    // MARK: Mantenimiento

    /// Al aparecer con la ventana visible: solo si la última comprobación tiene más de unos minutos (M9).
    func refreshMaintenanceIfStale() async {
        guard PerformanceSamplingGate.maintenanceIsStale(lastCheck: maintenanceCheckedAt, now: Date()) else { return }
        await refreshMaintenance()
    }

    /// `MaintenanceScanner` + elementos de inicio rotos (solo lecturas). Al aparecer (con caché) y tras cada acción.
    func refreshMaintenance() async {
        maintenanceCheckedAt = Date()
        let onAC = snapshot?.battery?.onACPower ?? BatteryProbe.cached()?.onACPower ?? true
        let spotlight = spotlight
        let runner = runner
        let catalog = model?.catalog
        let classifier = model?.classifier
        let (items, broken) = await Task.detached(priority: .utility) { () -> ([CleanupItem], [BrokenLoginItem]) in
            var items: [CleanupItem] = []
            if let catalog {
                items = await MaintenanceScanner(catalog: catalog, runner: runner, home: NSHomeDirectory(),
                                                 classifier: classifier)
                    .findItems(spotlight: spotlight, onACPower: onAC)
            }
            return (items, LoginItemsAudit.broken(in: LoginItemsAudit.standardDirectories()))
        }.value
        maintenance = items
        loginItems = broken
    }

    func checkSpotlight() async {
        guard !isCheckingSpotlight else { return }
        isCheckingSpotlight = true
        spotlight = await SpotlightCheck(runner: runner).run()
        isCheckingSpotlight = false
        await refreshMaintenance()
    }

    func setMaintenanceResult(_ id: String, _ outcome: CleanupOutcome) {
        switch outcome {
        case .freed: maintenanceResults[id] = "Hecho"
        case .movedToTrash: maintenanceResults[id] = "Hecho: está en la Papelera"
        case .blocked(let reason): maintenanceResults[id] = reason
        case .failed(let message): maintenanceResults[id] = message
        }
    }
}
