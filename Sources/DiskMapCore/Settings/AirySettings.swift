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

/// Interface language. `system` follows macOS; the others pin Airy to one language (applied on relaunch).
public enum AppLanguage: String, Codable, Sendable, CaseIterable {
    case system, en, es

    /// Language code to pin (`AiryLanguage.override`, `AppleLanguages`), or `nil` to follow macOS.
    public var code: String? { self == .system ? nil : rawValue }
}

/// How much Airy animates. `system` follows Reduce Motion; `reduced` always fades; `full` animates even with
/// Reduce Motion on. Hidden windows pause either way.
public enum MotionPreference: String, Codable, Sendable, CaseIterable {
    case system, reduced, full

    /// Whether the motion gate should treat the window as "Reduce motion".
    public func reducesMotion(systemReduceMotion: Bool) -> Bool {
        switch self {
        case .system: systemReduceMotion
        case .reduced: true
        case .full: false
        }
    }
}

/// How old the saved index must be before Airy rescans it by itself on launch.
public enum RescanAge: String, Codable, Sendable, CaseIterable {
    case oneHour = "1h", sixHours = "6h", oneDay = "24h", never

    /// `nil`: never rescanned automatically while there is a saved index.
    public var interval: TimeInterval? {
        switch self {
        case .oneHour: 3600
        case .sixHours: 6 * 3600
        case .oneDay: 24 * 3600
        case .never: nil
        }
    }
}

/// Settings shared between the app and `airy-mcp` (`settings.json`).
///
/// New keys are optional on disk: a file written before them reads with the defaults, which are what Airy did
/// before the setting existed. `version` stays 1 because older Airy builds simply ignore the extra keys.
public struct AirySettings: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public var version = 1
    public var mode: CleanupMode = .aggressive
    public var profiles: Set<UsageProfile> = []
    public var agentsEnabled = true
    /// Normalized form from `ProtectList.normalise`.
    public var protectedPaths: [String] = []
    /// Interface language (the app also writes it to its own `AppleLanguages`).
    public var language: AppLanguage = .system
    public var motion: MotionPreference = .system
    /// Rescan on launch when the saved index is older than `rescanAge`.
    public var autoRescanOnLaunch = true
    public var rescanAge: RescanAge = .sixHours
    /// Volume path to select on launch; `nil` is the startup disk.
    public var defaultVolume: String?
    /// Folders the scanner never opens (normalized by `ExcludedFolders.normalise`).
    public var excludedPaths: [String] = []
    /// AI features (Claude Code): the assistant's report and chat, "Explain with AI" and "Why is it slow?".
    public var aiEnabled = true
    public static let defaults = AirySettings()

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case version, mode, profiles, agentsEnabled, protectedPaths
        case language, motion, autoRescanOnLaunch, rescanAge, defaultVolume, excludedPaths, aiEnabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        mode = try c.decodeIfPresent(CleanupMode.self, forKey: .mode) ?? .aggressive
        let names = try c.decodeIfPresent([String].self, forKey: .profiles) ?? []
        profiles = Set(names.compactMap(UsageProfile.init(rawValue:)))
        agentsEnabled = try c.decodeIfPresent(Bool.self, forKey: .agentsEnabled) ?? true
        protectedPaths = try c.decodeIfPresent([String].self, forKey: .protectedPaths) ?? []
        // Preferences that don't decide risk: an unknown value (e.g. from a newer Airy) falls back to the default.
        language = try c.decodeIfPresent(String.self, forKey: .language).flatMap(AppLanguage.init(rawValue:)) ?? .system
        motion = try c.decodeIfPresent(String.self, forKey: .motion).flatMap(MotionPreference.init(rawValue:)) ?? .system
        autoRescanOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .autoRescanOnLaunch) ?? true
        rescanAge = try c.decodeIfPresent(String.self, forKey: .rescanAge).flatMap(RescanAge.init(rawValue:)) ?? .sixHours
        defaultVolume = try c.decodeIfPresent(String.self, forKey: .defaultVolume).flatMap { $0.isEmpty ? nil : $0 }
        excludedPaths = try c.decodeIfPresent([String].self, forKey: .excludedPaths) ?? []
        aiEnabled = try c.decodeIfPresent(Bool.self, forKey: .aiEnabled) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(mode, forKey: .mode)
        try c.encode(profiles.map(\.rawValue).sorted(), forKey: .profiles)
        try c.encode(agentsEnabled, forKey: .agentsEnabled)
        try c.encode(protectedPaths, forKey: .protectedPaths)
        try c.encode(language, forKey: .language)
        try c.encode(motion, forKey: .motion)
        try c.encode(autoRescanOnLaunch, forKey: .autoRescanOnLaunch)
        try c.encode(rescanAge, forKey: .rescanAge)
        try c.encodeIfPresent(defaultVolume, forKey: .defaultVolume)
        try c.encode(excludedPaths, forKey: .excludedPaths)
        try c.encode(aiEnabled, forKey: .aiEnabled)
    }

    /// Adds a folder to `excludedPaths`. `false` if the path is not valid or was already excluded.
    public mutating func exclude(_ path: String, home: String) -> Bool {
        guard let normal = ExcludedFolders.normalise(path, home: home),
              !excludedPaths.contains(where: { $0.caseInsensitiveCompare(normal) == .orderedSame }) else { return false }
        excludedPaths.append(normal)
        return true
    }

    public mutating func unexclude(_ path: String) {
        excludedPaths.removeAll { $0 == path }
    }

    /// "Reset all settings": everything back to its default except the "Protect this" list, which only the user
    /// empties (resetting must never quietly drop a protection).
    public func resettingPreferences() -> AirySettings {
        var fresh = AirySettings.defaults
        fresh.protectedPaths = protectedPaths
        return fresh
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

/// Folders excluded from scanning: absolute paths, `~` expanded, without `.`/`..`, repeated or trailing slashes.
public enum ExcludedFolders {
    /// `nil` for a relative path, `/`, `.`/`..` components or control characters.
    public static func normalise(_ raw: String, home: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
        else { return nil }
        let expanded: String
        if trimmed == "~" { expanded = home } else if trimmed.hasPrefix("~/") { expanded = home + trimmed.dropFirst(1) } else { expanded = trimmed }
        guard expanded.hasPrefix("/") else { return nil }
        let parts = expanded.split(separator: "/")
        guard !parts.isEmpty, !parts.contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        return "/" + parts.joined(separator: "/")
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
