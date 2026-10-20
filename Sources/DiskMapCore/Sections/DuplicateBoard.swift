import Foundation

/// Selección de la sección Duplicados. Reglas: la copia conservada nunca está marcada (así ningún grupo
/// queda entero marcado) y lo rojo o protegido nunca se marca.
public struct DuplicateBoard: Sendable, Equatable {
    public private(set) var groups: [DuplicateGroup]
    /// `group.id` → ruta conservada.
    public private(set) var keepers: [String: String]
    public private(set) var selected: Set<String>

    public init(groups: [DuplicateGroup]) {
        self.groups = groups
        keepers = Dictionary(groups.map { ($0.id, $0.keeper) }, uniquingKeysWith: { first, _ in first })
        selected = []
    }

    private func keeper(of group: DuplicateGroup) -> String { keepers[group.id] ?? group.keeper }

    /// Nunca marca lo que no `canSelect` ni el conservado; nunca deja el grupo sin una copia sin marcar.
    public mutating func toggle(_ path: String, in group: DuplicateGroup) {
        guard let copy = group.copies.first(where: { $0.path == path }) else { return }
        if selected.remove(path) != nil { return }
        guard copy.canSelect, path != keeper(of: group) else { return }
        let unmarked = group.copies.filter { $0.path != path && !selected.contains($0.path) }
        guard !unmarked.isEmpty else { return }
        selected.insert(path)
    }

    /// Cambia el conservado del grupo y lo desmarca.
    public mutating func keep(_ path: String, in group: DuplicateGroup) {
        guard group.copies.contains(where: { $0.path == path }) else { return }
        keepers[group.id] = path
        selected.remove(path)
    }

    /// En cada grupo, todas salvo el conservado y las que no `canSelect`.
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

    /// Una por grupo con algo marcado; nunca incluye el conservado.
    public func removals() -> [DuplicateRemoval] {
        groups.compactMap { group in
            let remove = marked(in: group).map(\.path)
            guard !remove.isEmpty else { return nil }
            return DuplicateRemoval(keep: keeper(of: group), remove: remove, size: group.size,
                                    fingerprint: group.fingerprint)
        }
    }
}
