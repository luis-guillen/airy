import Foundation

public struct SettingsStore: Sendable {
    public let file: URL

    public init(file: URL) { self.file = file }

    public func load() -> SettingsLoad {
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return .missing
        } catch {
            return .unreadable(String(localized: "Could not read settings.json: \(error.localizedDescription)", bundle: .airyCore))
        }
        struct Probe: Decodable { var version: Int? }
        do {
            if let v = try JSONDecoder().decode(Probe.self, from: data).version, v > AirySettings.currentVersion {
                return .unreadable(String(localized: "settings.json comes from a newer version (\(v)).", bundle: .airyCore))
            }
            return .loaded(try JSONDecoder().decode(AirySettings.self, from: data))
        } catch {
            return .unreadable(String(localized: "settings.json is not valid.", bundle: .airyCore))
        }
    }

    public func save(_ settings: AirySettings) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(settings).write(to: file, options: .atomic)
    }

    /// What can be salvaged from an unreadable `settings.json` (tolerant read, key by key).
    public func salvage() -> SettingsSalvage {
        guard let data = try? Data(contentsOf: file) else { return SettingsSalvage() }
        return SettingsSalvage(data: data)
    }

    /// Sets the unreadable file aside as `settings.unreadable-<yyyyMMdd-HHmmss>.json` and writes new settings
    /// with what could be salvaged from it (`SettingsSalvage.settings`): the "Protect this" list is kept
    /// if it can be read and, if not everything needed is salvaged, agents are turned off (fail closed).
    @discardableResult
    public func resetUnreadable() throws -> SettingsReset {
        let salvage = salvage()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let dir = file.deletingLastPathComponent()
        var backup: URL?
        if FileManager.default.fileExists(atPath: file.path) {
            var aside = dir.appendingPathComponent("settings.unreadable-\(stamp).json")
            var n = 2
            while FileManager.default.fileExists(atPath: aside.path) {
                aside = dir.appendingPathComponent("settings.unreadable-\(stamp)-\(n).json")
                n += 1
            }
            try FileManager.default.moveItem(at: file, to: aside)
            backup = aside
        }
        let settings = salvage.settings
        try save(settings)
        return SettingsReset(settings: settings, backup: backup, salvage: salvage)
    }
}

/// Tolerant read of a `settings.json` that cannot be loaded whole (corrupt or from a newer
/// version): each key is salvaged only if it has the expected type.
public struct SettingsSalvage: Sendable, Equatable {
    public var protectedPaths: [String]?
    public var agentsEnabled: Bool?
    public var mode: CleanupMode?
    public var profiles: Set<UsageProfile>?

    public init(protectedPaths: [String]? = nil, agentsEnabled: Bool? = nil, mode: CleanupMode? = nil,
                profiles: Set<UsageProfile>? = nil) {
        self.protectedPaths = protectedPaths; self.agentsEnabled = agentsEnabled
        self.mode = mode; self.profiles = profiles
    }

    public init(data: Data) {
        self.init()
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let list = object["protectedPaths"] as? [Any], list.allSatisfy({ $0 is String }) {
            protectedPaths = list.compactMap { $0 as? String }
        }
        // `NSNumber` also accepts 0/1: only a real JSON boolean counts.
        if let value = object["agentsEnabled"] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() {
            agentsEnabled = value.boolValue
        }
        if let raw = object["mode"] as? String { mode = CleanupMode(rawValue: raw) }
        if let names = object["profiles"] as? [Any] {
            profiles = Set(names.compactMap { ($0 as? String).flatMap(UsageProfile.init(rawValue:)) })
        }
    }

    /// `true` if the "Protect this" list was recovered (even if empty).
    public var recoveredProtectedPaths: Bool { protectedPaths != nil }

    /// New settings: what was salvaged on top of the defaults. Agents only stay enabled if the
    /// file said so and the "Protect this" list was also recovered; otherwise, off.
    public var settings: AirySettings {
        var s = AirySettings.defaults
        s.protectedPaths = protectedPaths ?? []
        s.agentsEnabled = agentsEnabled == true && protectedPaths != nil
        if let mode { s.mode = mode }
        if let profiles { s.profiles = profiles }
        return s
    }
}

/// Result of "Reset settings".
public struct SettingsReset: Sendable, Equatable {
    public let settings: AirySettings
    /// Where the unreadable file was set aside (`nil` if there was no file).
    public let backup: URL?
    public let salvage: SettingsSalvage

    /// Text for the user after resetting: what was kept and what was not.
    public var message: String {
        var parts = [String(localized: "Settings reset.", bundle: .airyCore)]
        let n = settings.protectedPaths.count
        if salvage.recoveredProtectedPaths {
            parts.append(n == 0 ? String(localized: "Your “Protect this” list was empty.", bundle: .airyCore)
                         : n == 1 ? String(localized: "Your “Protect this” list was kept (1 path).", bundle: .airyCore)
                         : String(localized: "Your “Protect this” list was kept (\(n) paths).", bundle: .airyCore))
        } else {
            parts.append(String(localized: "Your “Protect this” list could not be recovered: it is now empty. Protect what you want again in Settings.", bundle: .airyCore))
        }
        if !settings.agentsEnabled {
            parts.append(String(localized: "Agents stay disabled until you enable them in Settings › Agents.", bundle: .airyCore))
        }
        if let backup { parts.append(String(localized: "The previous file was saved as \(backup.lastPathComponent).", bundle: .airyCore)) }
        return parts.joined(separator: " ")
    }
}
