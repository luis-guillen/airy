import Foundation
import Synchronization

public enum ContentKind: String, Codable, CaseIterable, Sendable {
    case video, images, apps, code, caches, aiModels, containers, documents, system, other

    public var title: String {
        switch self {
        case .video: "Vídeo"
        case .images: "Imágenes"
        case .apps: "Apps"
        case .code: "Código y proyectos"
        case .caches: "Cachés"
        case .aiModels: "Modelos de IA"
        case .containers: "Contenedores y VM"
        case .documents: "Documentos"
        case .system: "Sistema"
        case .other: "Otros"
        }
    }
}

public enum Risk: Int, Codable, Comparable, Sendable {
    case safe = 0, yourCall = 1, doNotTouch = 2

    public var title: String {
        switch self {
        case .safe: "Borrar sin riesgo"
        case .yourCall: "Depende de ti"
        case .doNotTouch: "No tocar"
        }
    }

    public static func < (a: Risk, b: Risk) -> Bool { a.rawValue < b.rawValue }

    /// Devuelve el riesgo más estricto de los dos.
    public static func strictest(_ a: Risk, _ b: Risk) -> Risk { max(a, b) }
}

/// Nodo del árbol de ficheros analizado. Se construye en un solo hilo y se publica
/// después de forma inmutable en la práctica, de ahí `@unchecked Sendable`.
public final class FileNode: @unchecked Sendable, Identifiable {
    private static let nextID = Mutex(0)

    public let id: Int
    public var name: String
    public weak var parent: FileNode?
    public var children: [FileNode]
    public var isDirectory: Bool
    public var allocatedSize: Int64
    public var lastModified: Date?
    public var kind: ContentKind
    /// Bytes por tipo; índice = posición en `ContentKind.allCases`.
    public var kindBytes: [Int64]
    public var descendantCount: Int
    /// > 0 si el nodo es el agregado "Otros (N elementos)".
    public var aggregatedCount: Int

    public init(
        name: String,
        isDirectory: Bool,
        allocatedSize: Int64 = 0,
        lastModified: Date? = nil,
        kind: ContentKind = .other,
        kindBytes: [Int64]? = nil,
        children: [FileNode] = [],
        descendantCount: Int = 0,
        aggregatedCount: Int = 0
    ) {
        self.id = Self.nextID.withLock { value in
            value += 1
            return value
        }
        self.name = name
        self.isDirectory = isDirectory
        self.allocatedSize = allocatedSize
        self.lastModified = lastModified
        self.kind = kind
        self.kindBytes = kindBytes ?? Array(repeating: 0, count: ContentKind.allCases.count)
        self.children = children
        self.descendantCount = descendantCount
        self.aggregatedCount = aggregatedCount
        for child in children { child.parent = self }
    }

    /// Ruta completa subiendo por `parent`; la raíz "/" no duplica la barra.
    public var path: String {
        var parts: [String] = []
        var node: FileNode? = self
        while let current = node {
            parts.append(current.name)
            node = current.parent
        }
        var joined = parts.reversed().joined(separator: "/")
        while joined.hasPrefix("//") { joined.removeFirst() }
        return joined
    }

    /// Tipo con más bytes en `kindBytes`; si no hay desglose, el propio `kind`.
    public var dominantKind: ContentKind {
        guard let maxBytes = kindBytes.max(), maxBytes > 0,
              let index = kindBytes.firstIndex(of: maxBytes) else { return kind }
        return ContentKind.allCases[index]
    }
}
