import AppKit
import SwiftUI
import Observation
import DiskMapCore

/// Coordina todo lo que borra algo desde la interfaz: la hoja de confirmación, la ejecución en
/// tanda, la celebración, "Vaciar Papelera" (también desde la barra lateral), el aviso de
/// instantáneas de Time Machine y "Cerrar <App>". Vive en `RootView` y se comparte por entorno.
@MainActor @Observable
final class CleanupFlow {
    struct ConfirmRequest: Identifiable {
        enum Kind {
            case items([CleanupItem])
            /// Tamaño leído al pedirla, solo para la hoja; al confirmar se vuelve a leer.
            /// `nil` = la Papelera no se puede leer (se vaciará con Finder, en todos los discos).
            case emptyTrash(Int64?)
            /// Rutas sueltas (mapa o asistente) que irán a la Papelera con `AppModel.trash(paths:title:)`.
            case trashPaths([String], title: String)
        }
        /// Primer paso opcional ("Esto depende de ti" del asistente): la confirmación real llega
        /// solo tras "Sí, quiero moverlo…".
        struct Warning {
            let title: String
            let subtitle: String
            let reason: String
            let note: String
        }

        let id = UUID()
        /// Una tanda: su vista previa y su ejecución quedan en el registro con este mismo `runID`.
        let runID = UUID()
        let kind: Kind
        var warning: Warning? = nil
        /// Agente que propuso esto y por dónde (`airy://propose`: `OperationContext.viaUnverifiedURL`, el
        /// nombre es solo lo que dice el enlace); la confirmación del usuario lo deja en el registro como
        /// `.user(…, proposedBy:, proposedVia:)`.
        var proposedBy: String? = nil
        var proposedVia: String? = nil
        /// Al confirmar (antes de ejecutar) y con el resultado de cada elemento, para quien pidió la
        /// confirmación (p. ej. la tarjeta del asistente o el aviso del mapa).
        var onConfirm: (@MainActor () -> Void)? = nil
        var onOutcome: (@MainActor (CleanupOutcome) -> Void)? = nil

        /// Lo confirma el usuario; si lo propuso un agente, queda anotado como tal.
        var context: OperationContext { .user(runID: runID, proposedBy: proposedBy, proposedVia: proposedVia) }
    }

    struct SnapshotNotice: Identifiable {
        let id = UUID()
        let emptied: Int64
        let rose: Int64
        let retained: Int64
        let snapshotCount: Int
    }

    enum Sheet: Identifiable {
        case confirm(ConfirmRequest)
        case snapshots(SnapshotNotice)

        var id: UUID {
            switch self {
            case .confirm(let request): request.id
            case .snapshots(let notice): notice.id
            }
        }
    }

    struct Celebration: Identifiable, Equatable {
        let id = UUID()
        let bytes: Int64
    }

    /// Resultado de la última tanda que la vista Limpieza muestra arriba.
    struct LastResult: Identifiable {
        let id = UUID()
        let summary: CleanupRunSummary
    }

    // MARK: Estado

    var sheet: Sheet?
    var celebration: Celebration?
    var lastResult: LastResult?
    /// Ids pendientes de la tanda en curso (en orden) y el que se está ejecutando.
    private(set) var queuedIDs: [String] = []
    private(set) var currentID: String?
    private(set) var isEmptyingTrash = false
    /// Limpiados en esta tanda: se ocultan al momento, sin esperar a la nueva detección.
    private(set) var hiddenIDs: Set<String> = []
    /// Bundle IDs que se están cerrando ("Cerrar Spotify") y avisos de apps que no quisieron cerrarse.
    private(set) var closingApps: Set<String> = []
    private(set) var appRefusals: [String: String] = [:]

    /// Ráfaga de una tanda de dos filas o más: cuándo empezó y el orden de ejecución (`gustSway`).
    struct Gust: Equatable {
        let id: UUID
        let start: Date
        let order: [String]
    }
    private(set) var gust: Gust?
    /// Lo que va despejando la tanda `.items` en curso (píldora «liberados»/«despejados»).
    private(set) var batchTally = BatchMotion.Tally()
    var batchFreed: Int64 { batchTally.bytes }

    var isRunning: Bool { currentID != nil || !queuedIDs.isEmpty }
    var isBusy: Bool { isRunning || isEmptyingTrash }

    private let probes = SystemProbes()

    // MARK: Peticiones (abren la confirmación)

    func requestClean(_ items: [CleanupItem], warning: ConfirmRequest.Warning? = nil, proposedBy: String? = nil,
                      proposedVia: String? = nil,
                      onConfirm: (@MainActor () -> Void)? = nil,
                      onOutcome: (@MainActor (CleanupOutcome) -> Void)? = nil) {
        guard !items.isEmpty, !isBusy else { return }
        sheet = .confirm(ConfirmRequest(kind: .items(items), warning: warning, proposedBy: proposedBy,
                                        proposedVia: proposedVia, onConfirm: onConfirm, onOutcome: onOutcome))
    }

    func requestEmptyTrash(_ model: AppModel) {
        guard !isBusy else { return }
        sheet = .confirm(ConfirmRequest(kind: .emptyTrash(model.trashBytes)))
    }

    func requestTrash(paths: [String], title: String, warning: ConfirmRequest.Warning? = nil,
                      proposedBy: String? = nil, proposedVia: String? = nil,
                      onConfirm: (@MainActor () -> Void)? = nil,
                      onOutcome: (@MainActor (CleanupOutcome) -> Void)? = nil) {
        guard !paths.isEmpty, !isBusy else { return }
        sheet = .confirm(ConfirmRequest(kind: .trashPaths(paths, title: title), warning: warning,
                                        proposedBy: proposedBy, proposedVia: proposedVia,
                                        onConfirm: onConfirm, onOutcome: onOutcome))
    }

    func cancelSheet() { sheet = nil }

    /// El usuario confirmó en la hoja. El estado "ocupado" se fija aquí mismo, antes de lanzar la
    /// tarea, para que un segundo clic no pueda arrancar otra tanda. `blocked`: ids de elementos (o
    /// rutas sueltas) que la vista previa dio por bloqueados: no se ejecutan.
    func confirm(_ request: ConfirmRequest, model: AppModel, blocked: Set<String> = []) {
        guard !isBusy else { return }
        let context = request.context
        switch request.kind {
        case .items(let all):
            let items = all.filter { !blocked.contains($0.id) }
            guard !items.isEmpty else { return }
            start(request)
            queuedIDs = items.map(\.id)
            batchTally = BatchMotion.Tally()
            startGust(order: BatchMotion.gustOrder(ids: queuedIDs))
            Task { await run(items, model: model, context: context, onOutcome: request.onOutcome) }
        case .emptyTrash:
            start(request)
            isEmptyingTrash = true
            Task { await emptyTrash(model: model, context: context) }
        case .trashPaths(let all, let title):
            let paths = all.filter { !blocked.contains($0) }
            guard !paths.isEmpty else { return }
            start(request)
            queuedIDs = [title]
            Task { await trash(paths: paths, title: title, model: model, context: context, onOutcome: request.onOutcome) }
        }
    }

    private func start(_ request: ConfirmRequest) {
        sheet = nil
        lastResult = nil
        request.onConfirm?()
    }

    /// Solo reacciona a una tanda ya confirmada; se retira sola al acabar la ráfaga.
    private func startGust(order: [String]?) {
        guard let order else { gust = nil; return }
        let gust = Gust(id: UUID(), start: .now, order: order)
        self.gust = gust
        let lifetime = WindMotion.gustDuration(rowCount: order.count) + 0.1
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(lifetime))
            if self?.gust == gust { self?.gust = nil }
        }
    }

    /// La nueva detección ya refleja lo limpiado: nada que ocultar a mano.
    func detectionFinished() {
        guard !isRunning else { return }
        hiddenIDs = []
    }

    // MARK: Limpiar

    private func run(_ items: [CleanupItem], model: AppModel, context: OperationContext,
                     onOutcome: (@MainActor (CleanupOutcome) -> Void)?) async {
        let summary = await CleanupBatch.run(items, onStart: { [weak self] index in
            guard let self else { return }
            self.currentID = items[index].id
            self.queuedIDs.removeAll { $0 == items[index].id }
        }, perform: { [weak self] item in
            // Lo que desapareció desde la detección no bloquea el resto (el ejecutor revalida lo que queda).
            guard let current = CleanupBoard.withExistingPaths(item, exists: Self.exists) else {
                withAnimation(Theme.zoomSpring) { _ = self?.hiddenIDs.insert(item.id) }
                let gone = CleanupOutcome.blocked(reason: "Ya no existe.")
                onOutcome?(gone)
                return gone
            }
            let outcome = await model.perform(current, context: context)
            switch outcome {
            case .freed, .movedToTrash:
                self?.batchTally.add(outcome)
                // La fila se colapsa con el muelle en cuanto termina (la detección llega después).
                withAnimation(Theme.zoomSpring) { _ = self?.hiddenIDs.insert(item.id) }
            case .blocked, .failed: break
            }
            onOutcome?(outcome)
            return outcome
        })
        currentID = nil
        queuedIDs = []
        withAnimation(Theme.sectionSpring) { lastResult = LastResult(summary: summary) }
        if summary.freed > 0 { celebration = Celebration(bytes: summary.freed) }
    }

    private nonisolated static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    private func trash(paths: [String], title: String, model: AppModel, context: OperationContext,
                       onOutcome: (@MainActor (CleanupOutcome) -> Void)?) async {
        currentID = title
        queuedIDs = []
        let outcome = await model.trash(paths: paths, title: title, context: context)
        currentID = nil
        onOutcome?(outcome)
        var summary = CleanupRunSummary()
        summary.record(id: title, title: title, outcome: outcome)
        withAnimation(Theme.sectionSpring) { lastResult = LastResult(summary: summary) }
    }

    // MARK: Vaciar Papelera

    private func emptyTrash(model: AppModel, context: OperationContext) async {
        defer { isEmptyingTrash = false }
        let home = NSHomeDirectory()
        // Lo que hay ahora (no lo que había al abrir la hoja), leído fuera del hilo principal.
        let probes = probes
        let expected = await Task.detached(priority: .userInitiated) { probes.trashSizeIfReadable() }.value
        let freeBefore = await Self.freeSpace(home: home)
        let outcome = await model.emptyTrash(context: context)
        switch outcome {
        case .freed:
            var freeAfter = await Self.freeSpace(home: home)
            var snapshots: [String] = []
            if let expected, expected > 0, Double(freeAfter - freeBefore) < Double(expected) * TrashFollowUp.expectedRiseFraction {
                // APFS puede tardar un momento en devolver el espacio: se mira otra vez antes de concluir.
                for _ in 0..<3 where Double(freeAfter - freeBefore) < Double(expected) * TrashFollowUp.expectedRiseFraction {
                    try? await Task.sleep(for: .seconds(1))
                    freeAfter = await Self.freeSpace(home: home)
                }
                snapshots = await probes.localSnapshots()
            }
            if TrashFollowUp.shouldExplainSnapshots(expectedBytes: expected, freeBefore: freeBefore,
                                                    freeAfter: freeAfter, snapshotCount: snapshots.count),
               let expected {
                sheet = .snapshots(SnapshotNotice(
                    emptied: expected, rose: max(0, freeAfter - freeBefore),
                    retained: TrashFollowUp.retainedBytes(expectedBytes: expected, freeBefore: freeBefore, freeAfter: freeAfter),
                    snapshotCount: snapshots.count))
            } else {
                // Se celebra lo que de verdad subió el espacio libre, no lo que ocupaba la Papelera.
                let rose = freeAfter - freeBefore
                if rose > 0 {
                    celebration = Celebration(bytes: rose)
                } else {
                    var summary = CleanupRunSummary()
                    summary.record(id: "empty-trash", title: "Vaciar Papelera", outcome: .freed(0))
                    withAnimation(Theme.sectionSpring) { lastResult = LastResult(summary: summary) }
                }
            }
        case .movedToTrash, .blocked, .failed:
            var summary = CleanupRunSummary()
            summary.record(id: "empty-trash", title: "Vaciar Papelera", outcome: outcome)
            withAnimation(Theme.sectionSpring) { lastResult = LastResult(summary: summary) }
            model.section = .cleanup
        }
    }

    /// Desde el aviso de instantáneas: la ficha `time-machine-snapshots` del catálogo, con confirmación.
    func requestSnapshotCleanup(_ notice: SnapshotNotice, model: AppModel) {
        guard let catalog = model.catalog,
              let item = TrashFollowUp.snapshotItem(catalog: catalog, retainedBytes: notice.retained) else {
            sheet = nil
            var summary = CleanupRunSummary()
            summary.record(id: TrashFollowUp.snapshotEntryID, title: "Instantáneas de Time Machine",
                           outcome: .failed("No se encontró su ficha en el catálogo de limpiezas; Airy no puede reducirlas."))
            withAnimation(Theme.sectionSpring) { lastResult = LastResult(summary: summary) }
            model.section = .cleanup
            return
        }
        sheet = .confirm(ConfirmRequest(kind: .items([item])))
    }

    private nonisolated static func freeSpace(home: String) async -> Int64 {
        await Task.detached(priority: .userInitiated) { SystemProbes.availableCapacity(home: home) }.value
    }

    // MARK: Cerrar apps

    /// Nombre de la app abierta (el del sistema) o uno conocido por su bundle ID.
    static func appName(_ bundleID: String) -> String {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName
            ?? CleanupBoard.appName(forBundleID: bundleID)
    }

    /// "Cerrar Spotify": `terminate()` (la app puede pedir guardar), espera hasta 10 s y vuelve a detectar.
    /// Si la app no se cierra, se dice.
    func closeApp(_ bundleID: String, model: AppModel) {
        guard !closingApps.contains(bundleID) else { return }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        let name = Self.appName(bundleID)
        appRefusals[bundleID] = nil
        guard !apps.isEmpty else {
            model.refreshCleanup()
            return
        }
        closingApps.insert(bundleID)
        for app in apps { app.terminate() }
        poll(apps, bundleID: bundleID, name: name, deadline: Date().addingTimeInterval(10), model: model)
    }

    /// Comprueba cada 250 ms en la cola principal (sin el *pool* cooperativo, que va lento durante un análisis).
    private func poll(_ apps: [NSRunningApplication], bundleID: String, name: String, deadline: Date, model: AppModel) {
        let stillOpen = apps.contains { !$0.isTerminated }
        guard stillOpen, Date() < deadline else {
            closingApps.remove(bundleID)
            if stillOpen {
                appRefusals[bundleID] = "\(name) no se ha cerrado. Puede que tenga algo sin guardar: ciérrala tú y vuelve a intentarlo."
            }
            model.refreshCleanup()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            MainActor.assumeIsolated {
                self?.poll(apps, bundleID: bundleID, name: name, deadline: deadline, model: model)
            }
        }
    }

    // MARK: Depuración

    #if DEBUG
    /// Solo para capturas: sustituye bloqueos detectados (p. ej. Spotify abierta sin abrirla).
    var debugBlocked: [String: [String]] = [:]
    var debugScrollTarget: String?
    #endif
}
