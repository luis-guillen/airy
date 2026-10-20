import Foundation

/// Pone al día el árbol analizado tras una acción (limpieza, Papelera) sin reanalizar todo:
/// se miden de nuevo solo las rutas tocadas (fuera del hilo principal) y luego se aplican.
public enum ScanTreeRefresh {
    public struct Measurement: Sendable, Equatable {
        public let path: String
        /// Espacio asignado medido ahora; `nil` si la ruta ya no existe.
        public let bytes: Int64?

        public init(path: String, bytes: Int64?) {
            self.path = path
            self.bytes = bytes
        }
    }

    /// Mide cada ruta con `lstat` + `AllocatedSize` (E/S de disco: fuera del hilo principal).
    public static func measure(_ paths: [String]) -> [Measurement] {
        paths.map { path in
            var info = stat()
            guard lstat(path, &info) == 0 else { return Measurement(path: path, bytes: nil) }
            return Measurement(path: path, bytes: AllocatedSize.of(path) ?? 0)
        }
    }

    /// Aplica las medidas: quita los nodos de lo que ya no existe y deja los demás con su tamaño
    /// nuevo. Devuelve `true` si cambió algo. Solo desde el hilo dueño del árbol (`TreeGate.mutate`),
    /// o sobre un árbol que aún no se ha publicado.
    @discardableResult
    public static func apply(_ measurements: [Measurement], to root: FileNode) -> Bool {
        var changed = false
        // De lo más hondo a lo más alto: una carpeta medida después de su hija la sustituye entera.
        for measurement in measurements.sorted(by: { $0.path.count > $1.path.count }) {
            guard let node = CleanupScanner.node(at: measurement.path, in: root), node !== root else { continue }
            if let bytes = measurement.bytes {
                if bytes != node.allocatedSize {
                    node.replaceContents(measuredSize: bytes)
                    changed = true
                }
            } else if node.parent != nil {
                node.removeFromParent()
                changed = true
            }
        }
        return changed
    }
}
