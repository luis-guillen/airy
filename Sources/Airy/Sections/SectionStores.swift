import Foundation
import Observation
import DiskMapCore

/// Estado de las secciones de la fase 2. Vive en `AppModel`, así que filtros, resultados y selección
/// sobreviven a los cambios de sección. Nada se calcula aquí por su cuenta: cada vista pide `refresh`
/// al aparecer y cuando cambian sus datos (nunca mientras la sección no se ve).
@MainActor @Observable
final class SectionStores {
    let largeOld = LargeOldStore()
    let fileTypes = FileTypesStore()
    // Duplicados (Task 11): `let duplicates = DuplicatesStore()`.
    // Desinstalador (Task 12): `let uninstaller = UninstallerStore()`, en `UninstallerStore.swift`.
}

/// Ráfaga de una tanda de varias filas que se van a la vez (`GustSweep` + `.gustSway`).
struct SectionGust: Equatable {
    let id = UUID()
    let start: Date
    let order: [String]
}

// MARK: - Grandes y viejos

@MainActor @Observable
final class LargeOldStore {
    var query = LargeOldQuery()
    var files: [ActionableFile] = []
    var selection = FileSelection()
    var isLoading = false
    /// Ráfaga en curso (tras confirmar varias filas a la vez).
    var gust: SectionGust?

    @ObservationIgnored private var job: Task<[ActionableFile], Never>?
    @ObservationIgnored private var generation = 0

    /// Cancela el cálculo anterior y vuelve a buscar en el árbol ya analizado (lector cancelable del árbol).
    func refresh(model: AppModel) {
        cancel()
        generation += 1
        let current = generation
        guard let root = model.scan?.root else {
            files = []
            selection.prune(to: [])
            isLoading = false
            return
        }
        let finder = model.largeOldFinder()
        let query = query
        isLoading = true
        let job = model.treeGate.read(cancellable: true) { finder.find(in: root, query: query) }
        self.job = job
        Task { [weak self] in
            let found = await job.value
            guard let self, current == self.generation, !job.isCancelled else { return }
            self.files = found
            self.selection.prune(to: found)
            self.isLoading = false
        }
    }

    /// La sección deja de verse: nada sigue corriendo.
    func cancel() {
        job?.cancel()
        job = nil
        generation += 1
        isLoading = false
    }
}

// MARK: - Tipos de archivo

@MainActor @Observable
final class FileTypesStore {
    var breakdown: FileTypeBreakdown?
    var chosen: ContentKind?
    var files: [ActionableFile] = []
    var hiddenBytes: Int64 = 0
    var selection = FileSelection()
    var isLoading = false
    var gust: SectionGust?

    @ObservationIgnored private var job: Task<([ActionableFile], Int64), Never>?
    @ObservationIgnored private var generation = 0

    /// Totales por tipo (leídos de la raíz, sin recorrer el árbol) y, si hay un tipo elegido, su lista.
    func refresh(model: AppModel) {
        guard let root = model.scan?.root else {
            cancel()
            breakdown = nil
            files = []
            hiddenBytes = 0
            selection.prune(to: [])
            return
        }
        let next = FileTypeBreakdown(root: root)
        if next != breakdown { breakdown = next }
        if let chosen, !next.slices.contains(where: { $0.kind == chosen }) { self.chosen = nil }
        loadFiles(model: model)
    }

    func choose(_ kind: ContentKind?, model: AppModel) {
        guard kind != chosen else { return }
        chosen = kind
        selection.clear()
        files = []
        hiddenBytes = 0
        loadFiles(model: model)
    }

    func cancel() {
        job?.cancel()
        job = nil
        generation += 1
        isLoading = false
    }

    private func loadFiles(model: AppModel) {
        cancel()
        let current = generation
        guard let kind = chosen, let root = model.scan?.root else {
            files = []
            hiddenBytes = 0
            selection.prune(to: [])
            return
        }
        let classifier = model.classifier
        let catalog = model.catalog
        let gate = model.gate()
        let home = NSHomeDirectory()
        isLoading = true
        let job = model.treeGate.read(cancellable: true) { () -> ([ActionableFile], Int64) in
            let (items, hidden) = FileTypeBreakdown.items(of: kind, in: root)
            let files = items.map {
                ActionableFile.make(node: $0, classifier: classifier, catalog: catalog, gate: gate,
                                    lastOpened: nil, home: home)
            }
            return (files, hidden)
        }
        self.job = job
        Task { [weak self] in
            let (found, hidden) = await job.value
            guard let self, current == self.generation, !job.isCancelled else { return }
            self.files = found
            self.hiddenBytes = hidden
            self.selection.prune(to: found)
            self.isLoading = false
        }
    }
}
