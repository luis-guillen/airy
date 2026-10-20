import Foundation

/// Carpetas de datos de Airy y la del legado (DiskMap), de donde se copian al primer arranque.
public struct AppPaths: Sendable, Equatable {
    public static let folderName = "Airy", legacyFolderName = "DiskMap", legacyBundleID = "local.diskmap.DiskMap"

    public let support: URL
    /// `nil` cuando `AIRY_SUPPORT_DIR` redirige los datos (no hay legado que migrar).
    public let legacySupport: URL?

    public init(support: URL, legacySupport: URL?) {
        self.support = support
        self.legacySupport = legacySupport
    }

    /// `AIRY_SUPPORT_DIR` solo se respeta en compilaciones DEBUG.
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
    public var migrationMarker: URL { support.appendingPathComponent(".migrated-from-diskmap") }
}
