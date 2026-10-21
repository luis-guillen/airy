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
    let duplicates = DuplicatesStore()
    /// Desinstalador, en `UninstallerStore.swift`.
    let uninstaller = UninstallerStore()
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

// MARK: - Duplicados

/// Búsqueda de Duplicados: solo con «Buscar duplicados» (nunca sola), en una tarea aparte cancelable.
/// Las huellas se quedan dentro del buscador; aquí solo hay rutas, tamaños y fechas.
@MainActor @Observable
final class DuplicatesStore {
    enum Place: Equatable { case home, folder(String) }

    var place: Place = .home { didSet { updateRoots() } }
    var search = DuplicateSearch(roots: DuplicateSearch.defaultRoots(home: NSHomeDirectory()))
    var result: DuplicateResult?
    var board = DuplicateBoard(groups: [])
    var examined = 0
    var isSearching = false
    /// Copias que ya se fueron a la Papelera: dejan de verse sin repetir la búsqueda.
    var gone: Set<String> = []

    @ObservationIgnored private var job: Task<DuplicateResult, Never>?
    @ObservationIgnored private var generation = 0

    private func updateRoots() {
        switch place {
        case .home: search.roots = DuplicateSearch.defaultRoots(home: NSHomeDirectory())
        case .folder(let path): search.roots = [path]
        }
    }

    /// Candidatos del índice (turno de lectura del árbol) y búsqueda en `Task.detached`. Al acabar, guarda
    /// el resultado (sin huellas) en `duplicates.json`.
    func start(model: AppModel) {
        guard !isSearching else { return }
        generation += 1
        let current = generation
        guard let root = model.scan?.root else { return }
        let finder = model.duplicateFinder()
        let search = search
        let gate = model.treeGate
        isSearching = true
        examined = 0
        result = nil
        gone = []
        board = DuplicateBoard(groups: [])
        let progress: @Sendable (Int) -> Void = { count in
            Task { @MainActor in if self.generation == current { self.examined = count } }
        }
        let job = Task.detached(priority: .utility) { () -> DuplicateResult in
            let candidates = await gate.read(cancellable: true) {
                DuplicateFinder.candidates(in: root, search: search)
            }.value
            guard !Task.isCancelled else {
                return DuplicateResult(groups: [], complete: false, filesExamined: 0, date: Date())
            }
            return await finder.find(search, candidates: candidates, progress: progress)
        }
        self.job = job
        Task {
            let found = await job.value
            guard current == self.generation else { return }
            self.job = nil
            self.result = found
            self.board = DuplicateBoard(groups: found.groups)
            self.examined = found.filesExamined
            self.isSearching = false
            model.saveDuplicates(found)
        }
    }

    /// Para la búsqueda: lo hallado hasta ahora se muestra como incompleto.
    func cancel() {
        job?.cancel()
    }

    /// Todas las copias salvo la conservada (nunca rojo ni protegido; lo ya movido, tampoco).
    func selectAllCopies() {
        board.selectAllCopies()
        for group in board.groups {
            for copy in group.copies where gone.contains(copy.path) && board.selected.contains(copy.path) {
                board.toggle(copy.path, in: group)
            }
        }
    }

    /// Tras la Papelera: lo que ya no está deja de verse y la selección se vacía.
    func pruneMissing() {
        for group in board.groups {
            for copy in group.copies where !FileManager.default.fileExists(atPath: copy.path) { gone.insert(copy.path) }
        }
        board.clear()
    }

    /// Copias que siguen a la vista en un grupo (con menos de dos, el grupo ya no se enseña).
    func visibleCopies(_ group: DuplicateGroup) -> [DuplicateCopy] {
        group.copies.filter { !gone.contains($0.path) }
    }
}
