import Foundation

/// A leftover of an app: a path in its home folder (or in `/Library`, informational only) or an install
/// receipt.
public struct Leftover: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable {
        case appSupport, caches, containers, preferences, byHost, savedState, httpStorage, logs, launchAgent, webKit,
             cookies, applicationScripts, autosave, syncedPreferences, plugin, receipt, systemLocation
    }

    /// For `.receipt`: the package identifier (`pkgid`).
    public let path: String
    public let kind: Kind
    public let bytes: Int64
    public let risk: Risk
    public let preselected: Bool
    public let matchedByName: Bool
    /// Why this label (localized).
    public let reason: String
    /// `.launchAgent` only: the plist's `Label`.
    public let launchLabel: String?
    public var id: String { kind.rawValue + ":" + path }
    public var canSelect: Bool { risk != .doNotTouch }

    public init(path: String, kind: Kind, bytes: Int64, risk: Risk, preselected: Bool, matchedByName: Bool,
                reason: String, launchLabel: String?) {
        self.path = path
        self.kind = kind
        self.bytes = bytes
        self.risk = risk
        // Red is never selected by default.
        self.preselected = preselected && risk != .doNotTouch
        self.matchedByName = matchedByName
        self.reason = reason
        self.launchLabel = launchLabel
    }
}

/// What uninstalling an app would cost: the `.app` and its leftovers, with the real size.
public struct UninstallPlan: Sendable, Equatable, Identifiable {
    public let app: AppRecord
    public let appBytes: Int64
    /// Sorted by ascending risk, descending bytes and path.
    public let leftovers: [Leftover]
    /// Why Airy does not uninstall this app, or `nil`.
    public let refusal: String?
    /// Path of another installed copy with the same identifier (its leftovers stay informational only).
    public let sharedWith: String?
    /// `false` if measuring ran out of time: what was not measured is left with 0 bytes.
    public let sizeComplete: Bool
    public var id: String { app.path }

    public init(app: AppRecord, appBytes: Int64, leftovers: [Leftover], refusal: String?, sharedWith: String?,
                sizeComplete: Bool) {
        self.app = app
        self.appBytes = appBytes
        self.leftovers = leftovers.sorted {
            if $0.risk != $1.risk { return $0.risk < $1.risk }
            if $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
            return $0.path < $1.path
        }
        self.refusal = refusal
        self.sharedWith = sharedWith
        self.sizeComplete = sizeComplete
    }

    /// Bytes of the leftovers that can be selected.
    public var leftoverBytes: Int64 {
        leftovers.filter(\.canSelect).reduce(0) { $0 + $1.bytes }
    }

    /// The `.app` plus every selectable leftover.
    public var realBytes: Int64 { appBytes + leftoverBytes }

    public var defaultSelection: Set<String> {
        Set(leftovers.filter { $0.preselected && $0.canSelect }.map(\.id))
    }

    /// The `.app` plus the selected leftovers that can be selected (red never adds up).
    public func bytes(selected: Set<String>) -> Int64 {
        appBytes + leftovers.filter { $0.canSelect && selected.contains($0.id) }.reduce(0) { $0 + $1.bytes }
    }
}
