import Foundation

/// Selection for the Duplicates section. Rules: the kept copy is never checked (so no group is ever
/// entirely checked) and red or protected items are never checked.
public struct DuplicateBoard: Sendable, Equatable {
    public private(set) var groups: [DuplicateGroup]
    /// `group.id` → kept path.
    public private(set) var keepers: [String: String]
    public private(set) var selected: Set<String>

    public init(groups: [DuplicateGroup]) {
        self.groups = groups
        keepers = Dictionary(groups.map { ($0.id, $0.keeper) }, uniquingKeysWith: { first, _ in first })
        selected = []
    }

    private func keeper(of group: DuplicateGroup) -> String { keepers[group.id] ?? group.keeper }

    /// Never checks what is not `canSelect` nor the kept one; never leaves the group without an unchecked copy.
    public mutating func toggle(_ path: String, in group: DuplicateGroup) {
        guard let copy = group.copies.first(where: { $0.path == path }) else { return }
        if selected.remove(path) != nil { return }
        guard copy.canSelect, path != keeper(of: group) else { return }
        let unmarked = group.copies.filter { $0.path != path && !selected.contains($0.path) }
        guard !unmarked.isEmpty else { return }
        selected.insert(path)
    }

    /// Changes the group's kept copy and unchecks it.
    public mutating func keep(_ path: String, in group: DuplicateGroup) {
        guard group.copies.contains(where: { $0.path == path }) else { return }
        keepers[group.id] = path
        selected.remove(path)
    }

    /// In each group, all except the kept one and those that are not `canSelect`.
    public mutating func selectAllCopies() {
        for group in groups {
            let keep = keeper(of: group)
            for copy in group.copies where copy.canSelect && copy.path != keep { selected.insert(copy.path) }
        }
    }

    public mutating func clear() { selected = [] }

    private func marked(in group: DuplicateGroup) -> [DuplicateCopy] {
        let keep = keeper(of: group)
        return group.copies.filter { $0.canSelect && $0.path != keep && selected.contains($0.path) }
    }

    public var reclaimableBytes: Int64 {
        groups.reduce(0) { total, group in total + marked(in: group).reduce(0) { $0 + $1.reclaimableBytes } }
    }

    /// One per group with something checked; never includes the kept one.
    public func removals() -> [DuplicateRemoval] {
        groups.compactMap { group in
            let remove = marked(in: group).map(\.path)
            guard !remove.isEmpty else { return nil }
            return DuplicateRemoval(keep: keeper(of: group), remove: remove, size: group.size,
                                    fingerprint: group.fingerprint)
        }
    }
}
