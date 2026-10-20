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

extension CleanupMethod {
    /// Argumento exacto de un comando que se sustituye por cada objetivo del elemento
    /// (`CleanupItem.targets`); el comando se ejecuta una vez por objetivo.
    public static let targetPlaceholder = "{target}"

    /// `true` si es un comando con algún argumento igual a `targetPlaceholder`.
    public var usesTargets: Bool {
        if case .command(_, let arguments, _) = self { return arguments.contains(Self.targetPlaceholder) }
        return false
    }
}

/// Conservar las versiones más nuevas de cada carpeta padre (y la activa, si la hay).
public struct RetentionRule: Codable, Sendable, Equatable {
    /// ≥ 1, por carpeta padre.
    public var keepNewest: Int
    /// Enlace (p. ej. `~/.local/bin/claude`): la versión a la que apunta se conserva siempre.
    public var activeLink: String?

    public init(keepNewest: Int, activeLink: String? = nil) {
        self.keepNewest = keepNewest; self.activeLink = activeLink
    }

    private enum CodingKeys: String, CodingKey { case keepNewest, activeLink }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keepNewest = try c.decode(Int.self, forKey: .keepNewest)
        guard keepNewest >= 1 else {
            throw DecodingError.dataCorruptedError(
                forKey: .keepNewest, in: c, debugDescription: "keepNewest debe ser al menos 1")
        }
        activeLink = try c.decodeIfPresent(String.self, forKey: .activeLink)
    }
}

/// Fuente de objetivos propia de una ficha (en vez de sus patrones). JSON `{"type": "...", ...}`.
public enum DiscoveryKind: Codable, Sendable, Equatable {
    case projectArtifacts(names: [String], cachedirTag: Bool)
    case installers
    case simulatorRuntimes
    case appSupportCaches
    case docker

    private enum CodingKeys: String, CodingKey { case type, names, cachedirTag }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "projectArtifacts":
            self = .projectArtifacts(
                names: try c.decode([String].self, forKey: .names),
                cachedirTag: try c.decodeIfPresent(Bool.self, forKey: .cachedirTag) ?? false)
        case "installers": self = .installers
        case "simulatorRuntimes": self = .simulatorRuntimes
        case "appSupportCaches": self = .appSupportCaches
        case "docker": self = .docker
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c, debugDescription: "Fuente de objetivos desconocida: \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .projectArtifacts(let names, let cachedirTag):
            try c.encode("projectArtifacts", forKey: .type)
            try c.encode(names, forKey: .names)
            try c.encode(cachedirTag, forKey: .cachedirTag)
        case .installers: try c.encode("installers", forKey: .type)
        case .simulatorRuntimes: try c.encode("simulatorRuntimes", forKey: .type)
        case .appSupportCaches: try c.encode("appSupportCaches", forKey: .type)
        case .docker: try c.encode("docker", forKey: .type)
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

/// Sección de la app a la que pertenece una ficha: Limpieza (por defecto) o Mantenimiento (Rendimiento).
public enum CatalogSection: String, Codable, Sendable { case cleanup, maintenance }

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
    /// Cadena a buscar en proyectos; `{name}` = nombre de la carpeta encontrada, transformado:
    /// se quita el prefijo `models--` / `datasets--` y `--` pasa a `/` (Hugging Face).
    /// Véase `referenceNeedle(forMatchedFolder:)`.
    public var referenceCheck: String?
    /// `true` si el comando oficial solo quita una parte (p. ej. `pnpm store prune` deja lo que usan
    /// los proyectos): la interfaz muestra "hasta X" y no lo suma como seguro en "Puedes liberar".
    public var partialCleanup: Bool
    /// Riesgo en modo Agresivo. Solo puede bajar el de `risk` si la ficha se regenera y no es «No tocar»;
    /// subirlo, siempre (véase `RiskClassifier.baseRisk(of:)`). `nil` ⇒ el de `risk`.
    public var aggressiveRisk: Risk?
    /// En modo Agresivo, se marca de entrada aunque sea «Depende de ti».
    public var preselectInAggressive: Bool
    /// Perfiles de uso para los que esta ficha se destaca (nunca cambian el riesgo).
    public var profiles: [UsageProfile]
    /// Procesos que deben estar cerrados antes de limpiar (los rellena la tarea 6).
    public var processNames: [String]
    /// Una frase: por qué es verde o rojo, o qué pierdes si es ámbar.
    public var shortReason: String?
    /// Un elemento por ruta encontrada (en vez de uno por ficha).
    public var perMatch: Bool
    /// Últimos componentes que nunca se incluyen (p. ej. `.DS_Store`).
    public var except: [String]
    /// Solo rutas sin cambios dentro desde hace al menos estos días.
    public var staleAfterDays: Int?
    /// Tamaño mínimo por elemento.
    public var minimumBytes: Int64?
    /// Conservar las versiones más nuevas (y la activa) de cada carpeta padre.
    public var retention: RetentionRule?
    /// Fuente de objetivos propia, en vez de los patrones.
    public var discovery: DiscoveryKind?
    /// Fichas informativas: qué hacer tú, en español.
    public var reviewHint: String?
    /// `.maintenance`: solo la ve `MaintenanceScanner` (Limpieza, `Catalog.match` y el MCP la ignoran).
    public var section: CatalogSection

    public init(
        id: String, title: String, explanation: String, whoCreatesIt: String, regenerates: Bool,
        risk: Risk, kind: ContentKind, paths: [String], cleanup: CleanupMethod,
        mustBeClosed: [String] = [], referenceCheck: String? = nil, partialCleanup: Bool = false,
        aggressiveRisk: Risk? = nil, preselectInAggressive: Bool = false, profiles: [UsageProfile] = [],
        processNames: [String] = [], shortReason: String? = nil, perMatch: Bool = false, except: [String] = [],
        staleAfterDays: Int? = nil, minimumBytes: Int64? = nil, retention: RetentionRule? = nil,
        discovery: DiscoveryKind? = nil, reviewHint: String? = nil, section: CatalogSection = .cleanup
    ) {
        self.id = id; self.title = title; self.explanation = explanation
        self.whoCreatesIt = whoCreatesIt; self.regenerates = regenerates; self.risk = risk
        self.kind = kind; self.paths = paths; self.cleanup = cleanup
        self.mustBeClosed = mustBeClosed; self.referenceCheck = referenceCheck
        self.partialCleanup = partialCleanup
        self.aggressiveRisk = aggressiveRisk; self.preselectInAggressive = preselectInAggressive
        self.profiles = profiles; self.processNames = processNames
        self.shortReason = shortReason; self.perMatch = perMatch; self.except = except
        self.staleAfterDays = staleAfterDays; self.minimumBytes = minimumBytes; self.retention = retention
        self.discovery = discovery; self.reviewHint = reviewHint; self.section = section
    }

    /// Cadena de búsqueda para una carpeta concreta (p. ej. `models--a--b` ⇒ `a/b`).
    public func referenceNeedle(forMatchedFolder folder: String) -> String? {
        guard let referenceCheck else { return nil }
        var name = (folder as NSString).lastPathComponent
        for prefix in ["models--", "datasets--"] where name.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
            break
        }
        name = name.replacingOccurrences(of: "--", with: "/")
        return referenceCheck.replacingOccurrences(of: "{name}", with: name)
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, explanation, whoCreatesIt, regenerates, risk, kind, paths, cleanup
        case mustBeClosed, referenceCheck, partialCleanup
        case aggressiveRisk, preselectInAggressive, profiles, processNames
        case shortReason, perMatch, except, staleAfterDays, minimumBytes, retention, discovery, reviewHint
        case section
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
        partialCleanup = try c.decodeIfPresent(Bool.self, forKey: .partialCleanup) ?? false
        if let name = try c.decodeIfPresent(String.self, forKey: .aggressiveRisk) {
            guard let aggressive = Risk(jsonName: name) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .aggressiveRisk, in: c, debugDescription: "Riesgo agresivo desconocido: \(name)")
            }
            aggressiveRisk = aggressive
        } else {
            aggressiveRisk = nil
        }
        preselectInAggressive = try c.decodeIfPresent(Bool.self, forKey: .preselectInAggressive) ?? false
        // Perfiles desconocidos (de una versión futura) se ignoran: solo sirven para destacar.
        profiles = (try c.decodeIfPresent([String].self, forKey: .profiles) ?? []).compactMap(UsageProfile.init(rawValue:))
        processNames = try c.decodeIfPresent([String].self, forKey: .processNames) ?? []
        shortReason = try c.decodeIfPresent(String.self, forKey: .shortReason)
        perMatch = try c.decodeIfPresent(Bool.self, forKey: .perMatch) ?? false
        except = try c.decodeIfPresent([String].self, forKey: .except) ?? []
        staleAfterDays = try c.decodeIfPresent(Int.self, forKey: .staleAfterDays)
        minimumBytes = try c.decodeIfPresent(Int64.self, forKey: .minimumBytes)
        retention = try c.decodeIfPresent(RetentionRule.self, forKey: .retention)
        discovery = try c.decodeIfPresent(DiscoveryKind.self, forKey: .discovery)
        reviewHint = try c.decodeIfPresent(String.self, forKey: .reviewHint)
        section = try c.decodeIfPresent(CatalogSection.self, forKey: .section) ?? .cleanup
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
        if partialCleanup { try c.encode(true, forKey: .partialCleanup) }
        try c.encodeIfPresent(aggressiveRisk?.jsonName, forKey: .aggressiveRisk)
        if preselectInAggressive { try c.encode(true, forKey: .preselectInAggressive) }
        if !profiles.isEmpty { try c.encode(profiles.map(\.rawValue), forKey: .profiles) }
        if !processNames.isEmpty { try c.encode(processNames, forKey: .processNames) }
        try c.encodeIfPresent(shortReason, forKey: .shortReason)
        if perMatch { try c.encode(true, forKey: .perMatch) }
        if !except.isEmpty { try c.encode(except, forKey: .except) }
        try c.encodeIfPresent(staleAfterDays, forKey: .staleAfterDays)
        try c.encodeIfPresent(minimumBytes, forKey: .minimumBytes)
        try c.encodeIfPresent(retention, forKey: .retention)
        try c.encodeIfPresent(discovery, forKey: .discovery)
        try c.encodeIfPresent(reviewHint, forKey: .reviewHint)
        if section == .maintenance { try c.encode(section, forKey: .section) }
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

    static let bundleName = "Airy_DiskMapCore.bundle"

    private final class BundleToken {}

    /// Busca el bundle de recursos por ruta (sin `Bundle.module`, que aborta si falta):
    /// Contents/Resources del .app, raíz del bundle principal y carpeta del binario en ejecución.
    public static func bundled() throws -> Catalog {
        try bundled(executableURL: Bundle.main.executableURL)
    }

    /// Carpetas donde buscar `Airy_DiskMapCore.bundle` (compartidas con `AppCatalog`).
    static func resourceSearchDirectories(executableURL: URL?, searchProcessBundles: Bool) -> [URL] {
        var dirs: [URL] = []
        if let e = executableURL {
            let folder = e.deletingLastPathComponent()
            dirs.append(folder.deletingLastPathComponent().appendingPathComponent("Resources", isDirectory: true))
            dirs.append(folder)
        }
        if searchProcessBundles {
            if let r = Bundle.main.resourceURL { dirs.append(r) }
            dirs.append(Bundle.main.bundleURL)
            dirs.append(Bundle(for: BundleToken.self).bundleURL.deletingLastPathComponent())
            for b in Bundle.allBundles + Bundle.allFrameworks { dirs.append(b.bundleURL.deletingLastPathComponent()) }
        }
        return dirs
    }

    /// Como `bundled()`, con el ejecutable dado: busca en su carpeta y en `<ejecutable>/../../Resources`
    /// (`airy-mcp` en `Airy.app/Contents/MacOS/`). `searchProcessBundles: false` (pruebas) busca solo ahí.
    public static func bundled(executableURL: URL?, searchProcessBundles: Bool = true) throws -> Catalog {
        let dirs = resourceSearchDirectories(executableURL: executableURL, searchProcessBundles: searchProcessBundles)
        var tried: [String] = []
        for dir in dirs {
            let url = dir.appendingPathComponent(bundleName)
            if tried.contains(url.path) { continue }
            tried.append(url.path)
            if let bundle = Bundle(url: url), let json = bundle.url(forResource: "catalog", withExtension: "json") {
                return try decode(try Data(contentsOf: json))
            }
        }
        throw CatalogError(description: "No se encontró catalog.json en \(bundleName). Buscado en: \(tried.joined(separator: ", "))")
    }

    public func entry(id: String) -> CatalogEntry? { entries.first { $0.id == id } }

    /// Entrada más específica (patrón literal más largo) que contiene o iguala a `path`.
    /// Compara sin distinguir mayúsculas y tras colapsar `.`, `..` y `//`.
    public func match(path: String, home: String) -> CatalogEntry? {
        let pathParts = Self.components(RiskPolicy.canonical(path))
        var best: (entry: CatalogEntry, score: Int)?
        for entry in entries where entry.section != .maintenance {
            for pattern in entry.paths {
                let expanded = RiskPolicy.canonical(Self.expand(pattern, home: home))
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
