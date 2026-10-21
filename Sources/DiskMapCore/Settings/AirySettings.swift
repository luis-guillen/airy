import Foundation

public enum CleanupMode: String, Codable, Sendable, CaseIterable {
    case aggressive, prudent
    public var title: String { self == .aggressive ? String(localized: "Aggressive", bundle: .airyCore) : String(localized: "Careful", bundle: .airyCore) }
}

public enum UsageProfile: String, Codable, Sendable, CaseIterable {
    case developer, creative, localAI, gaming, music, basic
    public var title: String {
        switch self {
        case .developer: String(localized: "I write code", bundle: .airyCore)
        case .creative: String(localized: "Design, photo or video", bundle: .airyCore)
        case .localAI: String(localized: "I run AI locally", bundle: .airyCore)
        case .gaming: String(localized: "Gaming", bundle: .airyCore)
        case .music: String(localized: "Music and audio", bundle: .airyCore)
        case .basic: String(localized: "Basic use", bundle: .airyCore)
        }
    }
}

/// Settings shared between the app and `airy-mcp` (`settings.json`).
public struct AirySettings: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public var version = 1
    public var mode: CleanupMode = .aggressive
    public var profiles: Set<UsageProfile> = []
    public var agentsEnabled = true
    /// Normalized form from `ProtectList.normalise`.
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

    /// `false` if the path is not valid or was already protected.
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

/// Result of reading `settings.json`. `unreadable` fails closed: agents are disabled
/// and the app must block destructive actions until the user resets it.
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
