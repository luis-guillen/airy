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
        let id = UUID()
        let kind: Kind
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

    var isRunning: Bool { currentID != nil || !queuedIDs.isEmpty }
    var isBusy: Bool { isRunning || isEmptyingTrash }

    private let probes = SystemProbes()

    // MARK: Peticiones (abren la confirmación)

    func requestClean(_ items: [CleanupItem]) {
        guard !items.isEmpty, !isBusy else { return }
        sheet = .confirm(ConfirmRequest(kind: .items(items)))
    }

    func requestEmptyTrash(_ model: AppModel) {
        guard !isBusy else { return }
        sheet = .confirm(ConfirmRequest(kind: .emptyTrash(model.trashBytes)))
    }

    func requestTrash(paths: [String], title: String) {
        guard !paths.isEmpty, !isBusy else { return }
        sheet = .confirm(ConfirmRequest(kind: .trashPaths(paths, title: title)))
    }

    func cancelSheet() { sheet = nil }

    /// El usuario confirmó en la hoja. El estado "ocupado" se fija aquí mismo, antes de lanzar la
    /// tarea, para que un segundo clic no pueda arrancar otra tanda.
    func confirm(_ request: ConfirmRequest, model: AppModel) {
        guard !isBusy else { return }
        sheet = nil
        lastResult = nil
        switch request.kind {
        case .items(let items):
            queuedIDs = items.map(\.id)
            Task { await run(items, model: model) }
        case .emptyTrash:
            isEmptyingTrash = true
            Task { await emptyTrash(model: model) }
        case .trashPaths(let paths, let title):
            queuedIDs = [title]
            Task { await trash(paths: paths, title: title, model: model) }
        }
    }

    /// La nueva detección ya refleja lo limpiado: nada que ocultar a mano.
    func detectionFinished() {
        guard !isRunning else { return }
        hiddenIDs = []
    }

    // MARK: Limpiar

    private func run(_ items: [CleanupItem], model: AppModel) async {
        let summary = await CleanupBatch.run(items, onStart: { [weak self] index in
            guard let self else { return }
            self.currentID = items[index].id
            self.queuedIDs.removeAll { $0 == items[index].id }
        }, perform: { [weak self] item in
            // Lo que desapareció desde la detección no bloquea el resto (el ejecutor revalida lo que queda).
            guard let current = CleanupBoard.withExistingPaths(item, exists: Self.exists) else {
                withAnimation(Theme.zoomSpring) { _ = self?.hiddenIDs.insert(item.id) }
                return .blocked(reason: "Ya no existe.")
            }
            let outcome = await model.perform(current)
            switch outcome {
            case .freed, .movedToTrash:
                // La fila se colapsa con el muelle en cuanto termina (la detección llega después).
                withAnimation(Theme.zoomSpring) { _ = self?.hiddenIDs.insert(item.id) }
            case .blocked, .failed: break
            }
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

    private func trash(paths: [String], title: String, model: AppModel) async {
        currentID = title
        queuedIDs = []
        let outcome = await model.trash(paths: paths, title: title)
        currentID = nil
        var summary = CleanupRunSummary()
        summary.record(id: title, title: title, outcome: outcome)
        withAnimation(Theme.sectionSpring) { lastResult = LastResult(summary: summary) }
    }

    // MARK: Vaciar Papelera

    private func emptyTrash(model: AppModel) async {
        defer { isEmptyingTrash = false }
        let home = NSHomeDirectory()
        // Lo que hay ahora (no lo que había al abrir la hoja), leído fuera del hilo principal.
        let probes = probes
        let expected = await Task.detached(priority: .userInitiated) { probes.trashSizeIfReadable() }.value
        let freeBefore = await Self.freeSpace(home: home)
        let outcome = await model.emptyTrash()
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
                           outcome: .failed("No se encontró su ficha en el catálogo de limpiezas; DiskMap no puede reducirlas."))
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
