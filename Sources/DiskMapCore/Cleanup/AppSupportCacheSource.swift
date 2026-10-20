import Foundation

/// Ficha `discovery {"type":"appSupportCaches"}`: cachés regenerables de apps que ninguna otra ficha conoce.
/// Mira las carpetas A y A/B de `~/Library/Application Support`; las que tienen como hija directa alguna carpeta
/// de `markers` (GPUCache, DawnCache…) ofrecen esas carpetas (y `alsoCleared`). Un elemento por carpeta.
public struct AppSupportCacheSource: CleanupTargetSource {
    public static let markers = ["Code Cache", "GPUCache", "DawnCache", "GrShaderCache", "GraphiteDawnCache",
                                 "DawnGraphiteCache", "DawnWebGPUCache", "Crashpad"]
    public static let alsoCleared = ["Cache", "CachedData", "Crashpad/completed"]
    public static let maxChildren = 5_000
    /// Plazo total de la búsqueda de carpetas.
    public static let searchBudget: Duration = .seconds(10)

    public init() {}

    // MARK: - Detección

    public func discover(_ entry: CatalogEntry, context: DiscoveryContext) async -> [DiscoveredTarget] {
        let support = context.home + "/Library/Application Support"
        guard ProjectArtifactRules.isRealDirectory(support) else { return [] }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.searchBudget)
        var result: [DiscoveredTarget] = []
        for folder in Self.candidateFolders(in: support, deadline: deadline) {
            guard let names = Self.children(of: folder), names.count <= Self.maxChildren else { continue }
            let found = Set(names)
            guard !Set(Self.markers).isDisjoint(with: found) else { continue }
            var targets: [String] = []
            for marker in Self.markers where found.contains(marker) {
                targets.append(folder + "/" + (marker == "Crashpad" ? "Crashpad/completed" : marker))
            }
            for extra in Self.alsoCleared where !targets.contains(folder + "/" + extra) {
                targets.append(folder + "/" + extra)
            }
            targets = targets.filter(Self.isRealDirectory)
            guard !targets.isEmpty else { continue }
            // Si otra ficha reclama alguna, la carpeta es de esa ficha.
            if targets.contains(where: { claimedByOther($0, entry: entry, context: context) }) { continue }
            // Lo protegido se quita sin fila roja; si no queda nada, no hay elemento.
            targets = targets.filter { protection(of: $0, context: context) == nil }
            guard !targets.isEmpty else { continue }
            let relative = String(folder.dropFirst(support.count + 1))
            result.append(DiscoveredTarget(idSuffix: relative, paths: targets))
        }
        return result
    }

    /// Carpetas A y A/B reales (sin enlaces) de `support`, en orden, hasta agotar el plazo.
    private static func candidateFolders(in support: String, deadline: ContinuousClock.Instant) -> [String] {
        let clock = ContinuousClock()
        var folders: [String] = []
        for name in (children(of: support) ?? []).sorted() {
            guard clock.now < deadline else { break }
            let first = support + "/" + name
            guard isRealDirectory(first) else { continue }
            folders.append(first)
            for inner in (children(of: first) ?? []).sorted().prefix(maxChildren) {
                guard clock.now < deadline else { break }
                let second = first + "/" + inner
                if isRealDirectory(second) { folders.append(second) }
            }
        }
        return folders
    }

    private static func children(of folder: String) -> [String]? {
        try? FileManager.default.contentsOfDirectory(atPath: folder)
    }

    private static func isRealDirectory(_ path: String) -> Bool { ProjectArtifactRules.isRealDirectory(path) }

    private func claimedByOther(_ path: String, entry: CatalogEntry, context: DiscoveryContext) -> Bool {
        guard let owner = context.catalog.match(path: path, home: context.home) else { return false }
        return owner.id != entry.id
    }

    private func protection(of path: String, context: DiscoveryContext) -> ProtectionMatch? {
        HardProtections.standard.match(canonicalPath: RiskPolicy.canonical(path), home: context.home,
                                       catalog: context.catalog)
    }

    // MARK: - Antes de actuar

    public func revalidate(_ entry: CatalogEntry, item: CleanupItem, context: DiscoveryContext) async -> String? {
        let support = RiskPolicy.canonical(context.home + "/Library/Application Support")
        for path in item.paths {
            let name = (path as NSString).lastPathComponent
            guard Self.isRealDirectory(path) else { return "Ya no es una carpeta de caché: \(name)." }
            guard RiskPolicy.isInside(RiskPolicy.canonical(path), root: support) else {
                return "La ruta no está en Application Support: \(path)."
            }
            // `Crashpad/completed` cuelga de `Crashpad`; el resto, de la carpeta de la app.
            let parent = (path as NSString).deletingLastPathComponent
            let isCompleted = name == "completed" && (parent as NSString).lastPathComponent == "Crashpad"
            let folder = isCompleted ? (parent as NSString).deletingLastPathComponent : parent
            let allowed = isCompleted || Self.markers.contains(name) || Self.alsoCleared.contains(name)
            guard allowed else { return "No es una carpeta de caché conocida: \(name)." }
            guard let siblings = Self.children(of: folder), !Set(Self.markers).isDisjoint(with: siblings) else {
                return "La app ya no tiene carpetas de caché reconocibles: \(name)."
            }
            if claimedByOther(path, entry: entry, context: context) {
                return "Ahora la gestiona otra ficha del catálogo: \(name)."
            }
            if let match = protection(of: path, context: context) {
                return "Protegida por Airy: \(match.reason)"
            }
        }
        return nil
    }
}
