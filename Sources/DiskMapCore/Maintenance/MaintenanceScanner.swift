import Foundation

/// Detecta los ajustes de mantenimiento (fichas `section: maintenance`) que conviene aplicar. Solo lee:
/// `defaults read` y los `.plist` de Preferencias. Se ejecutan como cualquier `CleanupItem`, por el embudo
/// (`CleanupExecutor`), siempre en ámbar y sin marcar.
public struct MaintenanceScanner: Sendable {
    static let corruptPlistID = "maintenance-corrupt-plist"
    static let spotlightID = "maintenance-spotlight-reindex"
    static let maxPlistBytes: Int64 = 10 * 1_048_576
    static let readTimeout: TimeInterval = 5

    /// Ficha ⇒ (dominio y clave que se leen, se ofrece si el valor leído es «1»).
    static let defaultsChecks: [String: (args: [String], offerWhenOne: Bool)] = [
        "maintenance-dsstore-network": (["read", "com.apple.desktopservices", "DSDontWriteNetworkStores"], false),
        "maintenance-dsstore-usb": (["read", "com.apple.desktopservices", "DSDontWriteUSBStores"], false),
        "maintenance-legacy-appnap": (["read", "-g", "NSAppSleepDisabled"], true),
        "maintenance-legacy-skipverify": (["read", "com.apple.frameworks.diskimages", "skip-verify"], true),
        "maintenance-legacy-skipverify-locked": (["read", "com.apple.frameworks.diskimages", "skip-verify-locked"], true),
        "maintenance-legacy-skipverify-remote": (["read", "com.apple.frameworks.diskimages", "skip-verify-remote"], true),
    ]

    private let catalog: Catalog
    private let runner: any CommandRunning
    private let home: String
    private let classifier: RiskClassifier

    public init(catalog: Catalog, runner: any CommandRunning, home: String, classifier: RiskClassifier?) {
        let home = home.count > 1 && home.hasSuffix("/") ? String(home.dropLast()) : home
        self.catalog = catalog; self.runner = runner; self.home = home
        self.classifier = classifier ?? RiskClassifier(catalog: catalog, settings: .defaults, home: home)
    }

    public func findItems(spotlight: SpotlightDiagnosis?, onACPower: Bool) async -> [CleanupItem] {
        var items: [CleanupItem] = []
        let defaults = await runner.resolve("defaults")
        for entry in catalog.entries where entry.section == .maintenance {
            if let check = Self.defaultsChecks[entry.id] {
                guard let defaults, let value = await read(defaults, check.args) else { continue }
                let isOne = value == "1"
                if isOne == check.offerWhenOne { items.append(item(entry, id: entry.id, paths: [], bytes: 0)) }
            } else if entry.id == Self.corruptPlistID {
                for (path, bytes) in Self.corruptPlists(home: home) {
                    let name = (path as NSString).lastPathComponent
                    items.append(item(entry, id: "\(entry.id):\(name)", paths: [path], bytes: bytes))
                }
            } else if entry.id == Self.spotlightID {
                if case .slow = spotlight, onACPower { items.append(item(entry, id: entry.id, paths: [], bytes: 0)) }
            }
        }
        return items
    }

    /// Valor leído (sin espacios), «» si la clave no existe (código ≠ 0), `nil` si no se pudo ejecutar.
    private func read(_ executable: String, _ args: [String]) async -> String? {
        guard let output = try? await runner.run(executable, args, timeout: Self.readTimeout) else { return nil }
        guard output.status == 0 else { return "" }
        return output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func item(_ entry: CatalogEntry, id: String, paths: [String], bytes: Int64) -> CleanupItem {
        let risk = Risk.strictest(classifier.classify(entry: entry, paths: paths).risk, .yourCall)
        return CleanupItem(id: id, entry: entry, paths: paths, bytes: bytes, risk: risk,
                           blockedByOpenApps: [], usedBy: [], preselected: false)
    }

    // MARK: - Preferencias dañadas

    static func preferencesFolder(home: String) -> String { home + "/Library/Preferences" }

    /// `.plist` de `~/Library/Preferences` (sin `com.apple.`, ≤ 10 MB, fichero normal) que no se pueden leer.
    static func corruptPlists(home: String) -> [(String, Int64)] {
        let folder = preferencesFolder(home: home)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return [] }
        return names.sorted().compactMap { name in
            let path = folder + "/" + name
            guard let bytes = corruptSize(path: path, home: home) else { return nil }
            return (path, bytes)
        }
    }

    /// Tamaño si `path` es hoy un `.plist` dañado de Preferencias; `nil` si no (o si es de Apple).
    static func corruptSize(path: String, home: String) -> Int64? {
        let name = (path as NSString).lastPathComponent
        guard (path as NSString).deletingLastPathComponent == preferencesFolder(home: home),
              name.hasSuffix(".plist"), !name.lowercased().hasPrefix("com.apple.") else { return nil }
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        let size = Int64(info.st_size)
        guard size <= maxPlistBytes, let data = FileManager.default.contents(atPath: path) else { return nil }
        if (try? PropertyListSerialization.propertyList(from: data, format: nil)) != nil { return nil }
        return size
    }
}

/// Fuente de las fichas de mantenimiento en el embudo: la detección es de `MaintenanceScanner`; aquí solo se
/// vuelve a comprobar, justo antes de actuar, que una preferencia sigue dañada.
struct MaintenanceSource: CleanupTargetSource {
    func discover(_ entry: CatalogEntry, context: DiscoveryContext) async -> [DiscoveredTarget] { [] }

    func revalidate(_ entry: CatalogEntry, item: CleanupItem, context: DiscoveryContext) async -> String? {
        guard entry.id == MaintenanceScanner.corruptPlistID else { return nil }
        guard !item.paths.isEmpty else { return "No hay nada que enviar a la Papelera." }
        for path in item.paths where MaintenanceScanner.corruptSize(path: path, home: context.home) == nil {
            return "Ya no está dañado."
        }
        return nil
    }
}
