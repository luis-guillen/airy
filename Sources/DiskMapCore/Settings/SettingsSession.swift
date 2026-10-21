import Foundation

/// Settings as the app uses them: read from `settings.json`, saved when they change and,
/// if the file cannot be read, fail closed: nothing destructive until the user
/// resets it (the file is never overwritten without asking).
public struct SettingsSession: Sendable {
    /// `update` with an unreadable file: it has to be reset first.
    public struct Unreadable: Error, Sendable {}

    public let store: SettingsStore
    public private(set) var load: SettingsLoad

    public init(store: SettingsStore) {
        self.store = store
        load = store.load()
    }

    public var effective: AirySettings { load.effective }

    /// Reason to deny any destructive action right now, or `nil`.
    public var destructiveRefusal: String? {
        guard case .unreadable(let reason) = load else { return nil }
        return String(localized: "Airy cannot read its settings (\(Self.trimmed(reason))); nothing is deleted until you reset them in Settings.", bundle: .airyCore)
    }

    /// Text of the `.settings` notice while the file is unreadable.
    public var unreadableNotice: String? {
        guard case .unreadable(let reason) = load else { return nil }
        return String(localized: "The settings could not be read (\(Self.trimmed(reason))). Agents cannot clean until you reset them.", bundle: .airyCore)
    }

    /// Reads the file again. `true` if what was read changed.
    @discardableResult
    public mutating func reload() -> Bool {
        let fresh = store.load()
        defer { load = fresh }
        return fresh != load
    }

    /// Reads the latest from disk, applies `change` and saves it. Returns `true` if something that
    /// decides the risk changed (mode or protected list). With an unreadable file it throws `Unreadable`.
    @discardableResult
    public mutating func update(_ change: (inout AirySettings) -> Void) throws -> Bool {
        reload()
        guard !load.isUnreadable else { throw Unreadable() }
        let before = load.effective
        var after = before
        change(&after)
        guard after != before else { return false }
        try store.save(after)
        load = .loaded(after)
        return after.mode != before.mode || after.protectedPaths != before.protectedPaths
    }

    /// What the "Reset settings" confirmation explains (before doing it): what is kept and what is
    /// lost. `nil` if the file can already be read (there is nothing to reset).
    public mutating func resetConfirmation() -> String? {
        reload()
        guard load.isUnreadable else { return nil }
        let salvage = store.salvage()
        let s = salvage.settings
        var parts = [String(localized: "Airy will set aside the settings.json it cannot read (it keeps a copy next to it) and start with new settings.", bundle: .airyCore)]
        if salvage.recoveredProtectedPaths {
            let n = s.protectedPaths.count
            parts.append(n == 0 ? String(localized: "Your “Protect this” list is empty.", bundle: .airyCore)
                         : n == 1 ? String(localized: "Your “Protect this” list will be kept (1 path).", bundle: .airyCore)
                         : String(localized: "Your “Protect this” list will be kept (\(n) paths).", bundle: .airyCore))
        } else {
            parts.append(String(localized: "Your “Protect this” list cannot be recovered: it will be empty.", bundle: .airyCore))
        }
        parts.append(s.agentsEnabled ? String(localized: "Agents will stay enabled.", bundle: .airyCore)
                     : String(localized: "Agents will be disabled until you enable them in Settings › Agents.", bundle: .airyCore))
        return parts.joined(separator: " ")
    }

    /// Reads the file again and, only if it is still unreadable, sets it aside and writes new settings with what
    /// could be salvaged (`SettingsStore.resetUnreadable`). `nil` if it could already be read: nothing is touched.
    @discardableResult
    public mutating func reset() throws -> SettingsReset? {
        reload()
        guard load.isUnreadable else { return nil }
        let result = try store.resetUnreadable()
        load = .loaded(result.settings)
        return result
    }

    private static func trimmed(_ reason: String) -> String {
        reason.hasSuffix(".") ? String(reason.dropLast()) : reason
    }
}
