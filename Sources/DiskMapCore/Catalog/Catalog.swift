import Foundation

/// Cómo se limpia una entrada del catálogo.
/// `command.executable` es siempre un nombre simple (p. ej. "docker"); la app lo resuelve con el PATH.
public enum CleanupMethod: Codable, Sendable, Equatable {
    case trash
    case command(executable: String, arguments: [String], sizeProbe: [String]?)
    /// Solo se muestra; sin acción.
    case info

    private enum CodingKeys: String, CodingKey { case type, executable, arguments, sizeProbe }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "trash": self = .trash
        case "info": self = .info
        case "command":
            self = .command(
                executable: try c.decode(String.self, forKey: .executable),
                arguments: try c.decode([String].self, forKey: .arguments),
                sizeProbe: try c.decodeIfPresent([String].self, forKey: .sizeProbe))
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c, debugDescription: "Tipo de limpieza desconocido: \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .trash: try c.encode("trash", forKey: .type)
        case .info: try c.encode("info", forKey: .type)
        case .command(let executable, let arguments, let sizeProbe):
            try c.encode("command", forKey: .type)
            try c.encode(executable, forKey: .executable)
            try c.encode(arguments, forKey: .arguments)
            try c.encodeIfPresent(sizeProbe, forKey: .sizeProbe)
        }
    }
}

extension Risk {
    /// Nombres en texto usados en catalog.json y en el JSON de la IA.
    public var jsonName: String {
        switch self {
        case .safe: "safe"
        case .yourCall: "yourCall"
        case .doNotTouch: "doNotTouch"
        }
    }

    public init?(jsonName: String) {
        switch jsonName {
        case "safe": self = .safe
        case "yourCall": self = .yourCall
        case "doNotTouch": self = .doNotTouch
        default: return nil
        }
    }
}

public struct CatalogEntry: Codable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var explanation: String
    public var whoCreatesIt: String
    public var regenerates: Bool
    public var risk: Risk
    public var kind: ContentKind
    /// Patrones con `~` y `*` (el `*` no cruza límites de componente).
    public var paths: [String]
    public var cleanup: CleanupMethod
    /// Bundle IDs de apps que deben estar cerradas antes de limpiar.
    public var mustBeClosed: [String]
    /// Cadena a buscar en proyectos; `{name}` = nombre de la carpeta encontrada.
    public var referenceCheck: String?

    public init(
        id: String, title: String, explanation: String, whoCreatesIt: String, regenerates: Bool,
        risk: Risk, kind: ContentKind, paths: [String], cleanup: CleanupMethod,
        mustBeClosed: [String] = [], referenceCheck: String? = nil
    ) {
        self.id = id; self.title = title; self.explanation = explanation
        self.whoCreatesIt = whoCreatesIt; self.regenerates = regenerates; self.risk = risk
        self.kind = kind; self.paths = paths; self.cleanup = cleanup
        self.mustBeClosed = mustBeClosed; self.referenceCheck = referenceCheck
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, explanation, whoCreatesIt, regenerates, risk, kind, paths, cleanup
        case mustBeClosed, referenceCheck
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        explanation = try c.decode(String.self, forKey: .explanation)
        whoCreatesIt = try c.decode(String.self, forKey: .whoCreatesIt)
        regenerates = try c.decode(Bool.self, forKey: .regenerates)
        let riskName = try c.decode(String.self, forKey: .risk)
        guard let risk = Risk(jsonName: riskName) else {
            throw DecodingError.dataCorruptedError(
                forKey: .risk, in: c, debugDescription: "Riesgo desconocido: \(riskName)")
        }
        self.risk = risk
        let kindName = try c.decode(String.self, forKey: .kind)
        guard let kind = ContentKind(rawValue: kindName) else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c, debugDescription: "Tipo desconocido: \(kindName)")
        }
        self.kind = kind
        paths = try c.decodeIfPresent([String].self, forKey: .paths) ?? []
        cleanup = try c.decode(CleanupMethod.self, forKey: .cleanup)
        mustBeClosed = try c.decodeIfPresent([String].self, forKey: .mustBeClosed) ?? []
        referenceCheck = try c.decodeIfPresent(String.self, forKey: .referenceCheck)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(explanation, forKey: .explanation)
        try c.encode(whoCreatesIt, forKey: .whoCreatesIt)
        try c.encode(regenerates, forKey: .regenerates)
        try c.encode(risk.jsonName, forKey: .risk)
        try c.encode(kind.rawValue, forKey: .kind)
        try c.encode(paths, forKey: .paths)
        try c.encode(cleanup, forKey: .cleanup)
        try c.encode(mustBeClosed, forKey: .mustBeClosed)
        try c.encodeIfPresent(referenceCheck, forKey: .referenceCheck)
    }
}

public struct CatalogError: Error, CustomStringConvertible, Sendable {
    public let description: String
}

public struct Catalog: Sendable {
    public let entries: [CatalogEntry]

    public init(entries: [CatalogEntry]) { self.entries = entries }

    private struct File: Decodable { let entries: [CatalogEntry] }

    public static func decode(_ data: Data) throws -> Catalog {
        Catalog(entries: try JSONDecoder().decode(File.self, from: data).entries)
    }

    static let bundleName = "DiskMap_DiskMapCore.bundle"

    /// Busca primero en `Bundle.main.resourceURL` (Contents/Resources del .app) y luego en `Bundle.module`.
    public static func bundled() throws -> Catalog {
        var tried: [String] = []
        if let resources = Bundle.main.resourceURL {
            let url = resources.appendingPathComponent(bundleName)
            tried.append(url.path)
            if let bundle = Bundle(url: url), let json = bundle.url(forResource: "catalog", withExtension: "json") {
                return try decode(try Data(contentsOf: json))
            }
        }
        if let json = Bundle.module.url(forResource: "catalog", withExtension: "json") {
            return try decode(try Data(contentsOf: json))
        }
        throw CatalogError(description: "No se encontró catalog.json. Buscado en: \(tried.joined(separator: ", ")) y en Bundle.module")
    }

    public func entry(id: String) -> CatalogEntry? { entries.first { $0.id == id } }

    /// Entrada más específica (patrón literal más largo) que contiene o iguala a `path`.
    public func match(path: String, home: String) -> CatalogEntry? {
        let pathParts = Self.components(path)
        var best: (entry: CatalogEntry, score: Int)?
        for entry in entries {
            for pattern in entry.paths {
                let expanded = Self.expand(pattern, home: home)
                let patParts = Self.components(expanded)
                guard patParts.count <= pathParts.count else { continue }
                let ok = zip(patParts, pathParts).allSatisfy { Self.componentMatches($0, $1) }
                guard ok else { continue }
                let score = expanded.filter { $0 != "*" }.count
                if best == nil || score > best!.score { best = (entry, score) }
            }
        }
        return best?.entry
    }

    private static func expand(_ pattern: String, home: String) -> String {
        let base = home.hasSuffix("/") ? String(home.dropLast()) : home
        if pattern == "~" { return base }
        if pattern.hasPrefix("~/") { return base + String(pattern.dropFirst(1)) }
        return pattern
    }

    private static func components(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    private static func componentMatches(_ pattern: String, _ name: String) -> Bool {
        if !pattern.contains("*") { return pattern == name }
        return fnmatch(pattern, name, 0) == 0
    }
}
