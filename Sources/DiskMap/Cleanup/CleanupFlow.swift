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
            /// `nil` = la Papelera no se puede leer (se vaciará con Finder, en todos los discos).
            case emptyTrash(Int64?)
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

    func cancelSheet() { sheet = nil }

    /// El usuario confirmó en la hoja.
    func confirm(_ request: ConfirmRequest, model: AppModel) {
        sheet = nil
        switch request.kind {
        case .items(let items): Task { await run(items, model: model) }
        case .emptyTrash(let expected): Task { await emptyTrash(expected: expected, model: model) }
        }
    }

    /// La nueva detección ya refleja lo limpiado: nada que ocultar a mano.
    func detectionFinished() {
        guard !isRunning else { return }
        hiddenIDs = []
    }

    // MARK: Limpiar

    private func run(_ items: [CleanupItem], model: AppModel) async {
        lastResult = nil
        queuedIDs = items.map(\.id)
        let summary = await CleanupBatch.run(items, onStart: { [weak self] index in
            guard let self else { return }
            self.currentID = items[index].id
            self.queuedIDs.removeAll { $0 == items[index].id }
        }, perform: { [weak self] item in
            let outcome = await model.perform(item)
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

    // MARK: Vaciar Papelera

    private func emptyTrash(expected: Int64?, model: AppModel) async {
        isEmptyingTrash = true
        defer { isEmptyingTrash = false }
        let home = NSHomeDirectory()
        let freeBefore = await Self.freeSpace(home: home)
        let outcome = await model.emptyTrash()
        switch outcome {
        case .freed(let bytes):
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
            } else if bytes > 0 {
                celebration = Celebration(bytes: bytes)
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
    func debugApplyRun(_ items: [CleanupItem], model: AppModel) { Task { await run(items, model: model) } }
    #endif
}
