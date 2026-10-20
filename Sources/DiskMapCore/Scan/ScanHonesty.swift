import Foundation

/// Qué tan completo es el último análisis: lo dicen la tarjeta del disco, el Mapa y el MCP.
public enum ScanCompleteness: Sendable, Equatable {
    case complete
    case partial(unreadable: Int)
    case unavailable

    public static func of(_ result: ScanResult?) -> ScanCompleteness {
        guard let result else { return .unavailable }
        return result.inaccessible.isEmpty ? .complete : .partial(unreadable: result.inaccessible.count)
    }

    public var label: String {
        switch self {
        case .complete: "Análisis completo"
        case .partial(let count):
            "Análisis parcial: no se pudieron leer \(count) \(count == 1 ? "carpeta" : "carpetas")"
        case .unavailable: "Sin análisis"
        }
    }

    public var jsonName: String {
        switch self {
        case .complete: "complete"
        case .partial: "partial"
        case .unavailable: "unavailable"
        }
    }
}

/// Qué rutas tienen algo ilegible dentro (ellas mismas o algo que cuelga de ellas): su tamaño del análisis es un
/// mínimo y se muestra con «+». Ordena una vez; cada consulta es una búsqueda binaria.
public struct PartialScanIndex: Sendable {
    private let sorted: [String]

    public init(inaccessible: [String]) {
        sorted = inaccessible.map(Self.trimmed).sorted()
    }

    public var isEmpty: Bool { sorted.isEmpty }

    public func isPartial(_ path: String) -> Bool {
        guard !sorted.isEmpty else { return false }
        let path = Self.trimmed(path)
        let start = lowerBound(path)
        if start < sorted.count, sorted[start] == path { return true }
        // Lo que cuelga de `path` empieza por «path/» y es contiguo desde su primer candidato.
        let prefix = path.hasSuffix("/") ? path : path + "/"
        let inside = lowerBound(prefix)
        return inside < sorted.count && sorted[inside].hasPrefix(prefix)
    }

    /// Primer índice con `sorted[i] >= key`.
    private func lowerBound(_ key: String) -> Int {
        var low = 0, high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if sorted[mid] < key { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private static func trimmed(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
