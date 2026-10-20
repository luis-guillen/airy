import Foundation

public struct FileTypeSlice: Sendable, Equatable, Identifiable {
    public let kind: ContentKind, bytes: Int64, fraction: Double
    public var id: ContentKind { kind }
}

/// Espacio por tipo de archivo, leído de los totales por tipo del índice ya guardado (no recorre el disco).
public struct FileTypeBreakdown: Sendable, Equatable {
    public let slices: [FileTypeSlice]
    public let total: Int64

    public init(root: FileNode) {
        let pairs = zip(ContentKind.allCases, root.kindBytes).filter { $0.1 > 0 }
        let total = pairs.reduce(Int64(0)) { $0 + $1.1 }
        self.total = total
        self.slices = pairs.sorted { $0.1 > $1.1 }
            .map { FileTypeSlice(kind: $0.0, bytes: $0.1, fraction: Double($0.1) / Double(total)) }
    }

    /// Elementos de un tipo, mayores primero: ficheros con `kind == k` y paquetes `.app` (sin bajar dentro) para `.apps`;
    /// nunca agregados «Otros». `hiddenBytes` = bytes del tipo − suma de los listados (pequeños o fuera del límite).
    public static func items(of kind: ContentKind, in root: FileNode, limit: Int = 300) -> (items: [FileNode], hiddenBytes: Int64) {
        var found: [FileNode] = []
        var stack = [root]
        while let node = stack.popLast() {
            if node.aggregatedCount > 0 { continue }
            if node.isDirectory {
                if kind == .apps, node.kind == .apps, node.name.hasSuffix(".app") {
                    found.append(node)
                } else {
                    stack.append(contentsOf: node.children)
                }
            } else if node.kind == kind {
                found.append(node)
            }
        }
        found.sort { $0.allocatedSize != $1.allocatedSize ? $0.allocatedSize > $1.allocatedSize : $0.name < $1.name }
        let shown = Array(found.prefix(max(0, limit)))
        let listed = shown.reduce(Int64(0)) { $0 + $1.kindBytes[kind.index] }
        let all = root.kindBytes[kind.index]
        return (shown, max(0, all - listed))
    }
}

private extension ContentKind {
    var index: Int { ContentKind.allCases.firstIndex(of: self)! }
}
