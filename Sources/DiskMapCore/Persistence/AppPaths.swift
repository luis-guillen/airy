import Foundation

/// Airy's data folders and the legacy one (DiskMap), from which they are copied on first launch.
public struct AppPaths: Sendable, Equatable {
    public static let folderName = "Airy", legacyFolderName = "DiskMap", legacyBundleID = "local.diskmap.DiskMap"

    public let support: URL
    /// `nil` when `AIRY_SUPPORT_DIR` redirects the data (there is no legacy to migrate).
    public let legacySupport: URL?

    public init(support: URL, legacySupport: URL?) {
        self.support = support
        self.legacySupport = legacySupport
    }

    /// `AIRY_SUPPORT_DIR` is only honoured in DEBUG builds.
    public static func standard(home: String = NSHomeDirectory(),
                                environment: [String: String] = ProcessInfo.processInfo.environment) -> AppPaths {
        #if DEBUG
        if let override = environment["AIRY_SUPPORT_DIR"], !override.isEmpty {
            return AppPaths(support: URL(fileURLWithPath: override, isDirectory: true), legacySupport: nil)
        }
        #endif
        let base = URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("Library/Application Support", isDirectory: true)
        return AppPaths(support: base.appendingPathComponent(folderName, isDirectory: true),
                        legacySupport: base.appendingPathComponent(legacyFolderName, isDirectory: true))
    }

    public var settingsFile: URL { support.appendingPathComponent("settings.json") }
    public var operationsFile: URL { support.appendingPathComponent("operations.jsonl") }
    public var duplicatesFile: URL { support.appendingPathComponent("duplicates.json") }
    public var migrationMarker: URL { support.appendingPathComponent(".migrated-from-diskmap") }
}
