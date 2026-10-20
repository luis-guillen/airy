import Foundation

public enum CleanupMode: String, Codable, Sendable, CaseIterable {
    case aggressive, prudent
    public var title: String { self == .aggressive ? "Agresivo" : "Prudente" }
}

public enum UsageProfile: String, Codable, Sendable, CaseIterable {
    case developer, creative, localAI, gaming, music, basic
    public var title: String {
        switch self {
        case .developer: "Programo"
        case .creative: "Diseño, foto o vídeo"
        case .localAI: "Uso IA en local"
        case .gaming: "Juego"
        case .music: "Música y audio"
        case .basic: "Uso básico"
        }
    }
}

/// Ajustes compartidos entre la app y `airy-mcp` (`settings.json`).
public struct AirySettings: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public var version = 1
    public var mode: CleanupMode = .aggressive
    public var profiles: Set<UsageProfile> = []
    public var agentsEnabled = true
    /// Forma normalizada de `ProtectList.normalise`.
    public var protectedPaths: [String] = []
    public static let defaults = AirySettings()

    public init() {}

    private enum CodingKeys: String, CodingKey { case version, mode, profiles, agentsEnabled, protectedPaths }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        mode = try c.decodeIfPresent(CleanupMode.self, forKey: .mode) ?? .aggressive
        let names = try c.decodeIfPresent([String].self, forKey: .profiles) ?? []
        profiles = Set(names.compactMap(UsageProfile.init(rawValue:)))
        agentsEnabled = try c.decodeIfPresent(Bool.self, forKey: .agentsEnabled) ?? true
        protectedPaths = try c.decodeIfPresent([String].self, forKey: .protectedPaths) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(mode, forKey: .mode)
        try c.encode(profiles.map(\.rawValue).sorted(), forKey: .profiles)
        try c.encode(agentsEnabled, forKey: .agentsEnabled)
        try c.encode(protectedPaths, forKey: .protectedPaths)
    }

    /// `false` si la ruta no es válida o ya estaba protegida.
    public mutating func protect(_ path: String, home: String) -> Bool {
        guard let normal = ProtectList.normalise(path, home: home),
              !protectedPaths.contains(where: { $0.caseInsensitiveCompare(normal) == .orderedSame }) else { return false }
        protectedPaths.append(normal)
        return true
    }

    public mutating func unprotect(_ pattern: String) {
        protectedPaths.removeAll { $0 == pattern }
    }
}

/// Resultado de leer `settings.json`. `unreadable` falla cerrado: los agentes quedan desactivados
/// y la app debe bloquear las acciones destructivas hasta que el usuario lo restablezca.
public enum SettingsLoad: Sendable, Equatable {
    case missing, loaded(AirySettings), unreadable(String)

    public var effective: AirySettings {
        switch self {
        case .missing: .defaults
        case .loaded(let s): s
        case .unreadable:
            { var s = AirySettings.defaults; s.agentsEnabled = false; return s }()
        }
    }

    public var allowsAgentActions: Bool {
        switch self {
        case .missing: true
        case .loaded(let s): s.agentsEnabled
        case .unreadable: false
        }
    }

    public var isUnreadable: Bool {
        if case .unreadable = self { return true }
        return false
    }
}
