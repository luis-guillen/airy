import Foundation
import Observation
import DiskMapCore

/// State of the phase 2 sections. It lives in `AppModel`, so filters, results and selection
/// survive section changes. Nothing is computed here on its own: each view asks for `refresh`
/// when it appears and when its data changes (never while the section isn't visible).
@MainActor @Observable
final class SectionStores {
    let largeOld = LargeOldStore()
    let fileTypes = FileTypesStore()
    let duplicates = DuplicatesStore()
    /// Uninstaller, in `UninstallerStore.swift`.
    let uninstaller = UninstallerStore()
}

/// Gust of a batch of several rows leaving at once (`GustSweep` + `.gustSway`).
struct SectionGust: Equatable {
    let id = UUID()
    let start: Date
    let order: [String]
}

// MARK: - Large & Old

@MainActor @Observable
final class LargeOldStore {
    var query = LargeOldQuery()
    var files: [ActionableFile] = []
    var selection = FileSelection()
    var isLoading = false
    /// Gust in progress (after confirming several rows at once).
    var gust: SectionGust?

    @ObservationIgnored private var job: Task<[ActionableFile], Never>?
    @ObservationIgnored private var generation = 0

    /// Cancels the previous computation and searches again in the already scanned tree (a cancellable tree reader).
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

    /// The section is no longer visible: nothing keeps running.
    func cancel() {
        job?.cancel()
        job = nil
        generation += 1
        isLoading = false
    }
}

// MARK: - File types

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

    /// Totals per kind (read from the root, without walking the tree) and, if a kind is chosen, its list.
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

// MARK: - Duplicates

/// Duplicates search: only with "Find Duplicates" (never by itself), in a separate cancellable task.
/// The fingerprints stay inside the finder; here there are only paths, sizes and dates.
@MainActor @Observable
final class DuplicatesStore {
    enum Place: Equatable { case home, folder(String) }

    var place: Place = .home { didSet { updateRoots() } }
    var search = DuplicateSearch(roots: DuplicateSearch.defaultRoots(home: NSHomeDirectory()))
    var result: DuplicateResult?
    var board = DuplicateBoard(groups: [])
    var examined = 0
    var isSearching = false
    /// Copies already moved to the Trash: they stop showing without repeating the search.
    var gone: Set<String> = []

    @ObservationIgnored private var job: Task<DuplicateResult, Never>?
    @ObservationIgnored private var generation = 0

    private func updateRoots() {
        switch place {
        case .home: search.roots = DuplicateSearch.defaultRoots(home: NSHomeDirectory())
        case .folder(let path): search.roots = [path]
        }
    }

    /// Candidates from the index (a tree read turn) and the search in `Task.detached`. When done, it saves
    /// the result (without fingerprints) to `duplicates.json`.
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

    /// Stops the search: what was found so far is shown as incomplete.
    func cancel() {
        job?.cancel()
    }

    /// All copies except the kept one (never red or protected; nor what was already moved).
    func selectAllCopies() {
        board.selectAllCopies()
        for group in board.groups {
            for copy in group.copies where gone.contains(copy.path) && board.selected.contains(copy.path) {
                board.toggle(copy.path, in: group)
            }
        }
    }

    /// After the Trash: what is gone stops showing and the selection is cleared.
    func pruneMissing() {
        for group in board.groups {
            for copy in group.copies where !FileManager.default.fileExists(atPath: copy.path) { gone.insert(copy.path) }
        }
        board.clear()
    }

    /// Copies still visible in a group (with fewer than two, the group is no longer shown).
    func visibleCopies(_ group: DuplicateGroup) -> [DuplicateCopy] {
        group.copies.filter { !gone.contains($0.path) }
    }
}
