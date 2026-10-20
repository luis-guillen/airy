import Foundation

public struct AppCatalogEntry: Codable, Sendable, Equatable {
    public var id, title, explanation: String
    public var bundleIDs: [String]
    public var processNames: [String]

    public init(id: String, title: String, explanation: String, bundleIDs: [String] = [], processNames: [String] = []) {
        self.id = id; self.title = title; self.explanation = explanation
        self.bundleIDs = bundleIDs; self.processNames = processNames
    }
}

/// Explicaciones de una línea de apps y procesos conocidos (`apps.json`).
public struct AppCatalog: Sendable {
    public let entries: [AppCatalogEntry]
    private let byBundleID: [String: AppCatalogEntry]
    private let byProcessName: [String: AppCatalogEntry]

    public init(entries: [AppCatalogEntry]) {
        self.entries = entries
        var bundles: [String: AppCatalogEntry] = [:], names: [String: AppCatalogEntry] = [:]
        for e in entries {
            for b in e.bundleIDs where bundles[b] == nil { bundles[b] = e }
            for n in e.processNames where names[n.lowercased()] == nil { names[n.lowercased()] = e }
        }
        byBundleID = bundles; byProcessName = names
    }

    private struct File: Decodable { let entries: [AppCatalogEntry] }

    public static func bundled() throws -> AppCatalog {
        try bundled(executableURL: Bundle.main.executableURL)
    }

    /// Misma búsqueda de bundle que `Catalog.bundled(executableURL:)`.
    public static func bundled(executableURL: URL?, searchProcessBundles: Bool = true) throws -> AppCatalog {
        let dirs = Catalog.resourceSearchDirectories(executableURL: executableURL, searchProcessBundles: searchProcessBundles)
        var tried: [String] = []
        for dir in dirs {
            let url = dir.appendingPathComponent(Catalog.bundleName)
            if tried.contains(url.path) { continue }
            tried.append(url.path)
            if let bundle = Bundle(url: url), let json = bundle.url(forResource: "apps", withExtension: "json") {
                return AppCatalog(entries: try JSONDecoder().decode(File.self, from: Data(contentsOf: json)).entries)
            }
        }
        throw CatalogError(description: "No se encontró apps.json en \(Catalog.bundleName). Buscado en: \(tried.joined(separator: ", "))")
    }

    /// Primero por bundle id; después por nombre de proceso sin distinguir mayúsculas.
    public func entry(bundleID: String?, processName: String) -> AppCatalogEntry? {
        if let bundleID, let e = byBundleID[bundleID] { return e }
        return byProcessName[processName.lowercased()]
    }
}
