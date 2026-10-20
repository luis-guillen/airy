import Foundation

/// Pila de zoom del mapa. `stack[0]` es la raíz analizada y `current` el nivel visible.
/// La ruta de navegación empieza por `rootTitle` (nombre del volumen, p. ej. "Macintosh HD")
/// porque `root.name` es la ruta completa analizada ("/") o "" si hay varias raíces.
public struct MapNavigation: Sendable {
    public private(set) var stack: [FileNode]
    public var rootTitle: String

    /// Sin análisis todavía: no hay nivel visible.
    public init(rootTitle: String = "Macintosh HD") {
        self.stack = []
        self.rootTitle = rootTitle
    }

    public init(root: FileNode, rootTitle: String = "Macintosh HD") {
        self.stack = [root]
        self.rootTitle = rootTitle
    }

    public var current: FileNode? { stack.last }
    public var root: FileNode? { stack.first }
    public var canZoomOut: Bool { stack.count > 1 }

    public var breadcrumb: [String] {
        [rootTitle] + stack.dropFirst().map(\.name)
    }

    /// Entra en `node` si es una carpeta descendiente del nivel actual; si está a varios
    /// niveles, apila también los intermedios para que "atrás" suba de uno en uno.
    /// Los archivos, los agregados "Otros" y los nodos ajenos se ignoran.
    public mutating func zoom(into node: FileNode) {
        guard let current, node !== current, node.isDirectory, node.aggregatedCount == 0 else { return }
        var chain: [FileNode] = []
        var cursor: FileNode? = node
        while let step = cursor, step !== current {
            chain.append(step)
            cursor = step.parent
        }
        guard cursor === current else { return }
        stack.append(contentsOf: chain.reversed())
    }

    /// La misma ruta sobre un árbol nuevo (p. ej. al terminar un reanálisis): baja por nombre desde
    /// `newRoot` hasta el nivel más hondo que siga existiendo como carpeta. Conserva `rootTitle`.
    public func restoring(in newRoot: FileNode) -> MapNavigation {
        var restored = MapNavigation(root: newRoot, rootTitle: rootTitle)
        var cursor = newRoot
        for name in stack.dropFirst().map(\.name) {
            guard let next = cursor.children.first(where: {
                $0.name == name && $0.isDirectory && $0.aggregatedCount == 0
            }) else { break }
            restored.stack.append(next)
            cursor = next
        }
        return restored
    }

    /// Sube un nivel; en la raíz no hace nada.
    public mutating func zoomOut() {
        guard stack.count > 1 else { return }
        stack.removeLast()
    }

    /// Salta al elemento `index` de la ruta de navegación (0 = raíz). Fuera de rango no hace nada.
    public mutating func jump(to index: Int) {
        guard index >= 0, index < stack.count else { return }
        stack.removeSubrange((index + 1)...)
    }
}
