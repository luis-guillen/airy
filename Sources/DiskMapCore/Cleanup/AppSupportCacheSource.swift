import Foundation

/// Entry with `discovery {"type":"appSupportCaches"}`: regenerable caches of apps no other entry knows.
/// It looks at the A and A/B folders of `~/Library/Application Support`; those with some `markers` folder
/// (GPUCache, DawnCache…) as a direct child offer those folders (and `alsoCleared`). One item per folder.
public struct AppSupportCacheSource: CleanupTargetSource {
    public static let markers = ["Code Cache", "GPUCache", "DawnCache", "GrShaderCache", "GraphiteDawnCache",
                                 "DawnGraphiteCache", "DawnWebGPUCache", "Crashpad"]
    public static let alsoCleared = ["Cache", "CachedData", "Crashpad/completed"]
    public static let maxChildren = 5_000
    /// Total time limit of the folder search.
    public static let searchBudget: Duration = .seconds(10)

    public init() {}

    // MARK: - Detection

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
            // If another entry claims any of them, the folder belongs to that entry.
            if targets.contains(where: { claimedByOther($0, entry: entry, context: context) }) { continue }
            // What is protected is removed without a red row; if nothing is left, there is no item.
            targets = targets.filter { protection(of: $0, context: context) == nil }
            guard !targets.isEmpty else { continue }
            let relative = String(folder.dropFirst(support.count + 1))
            result.append(DiscoveredTarget(idSuffix: relative, paths: targets))
        }
        return result
    }

    /// Real A and A/B folders (without links) of `support`, in order, until the time limit runs out.
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
        guard DiskScope.allowsWalk(folder) else { return nil }
        return try? FileManager.default.contentsOfDirectory(atPath: folder)
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

    // MARK: - Before acting

    public func revalidate(_ entry: CatalogEntry, item: CleanupItem, context: DiscoveryContext) async -> String? {
        let support = RiskPolicy.canonical(context.home + "/Library/Application Support")
        for path in item.paths {
            let name = (path as NSString).lastPathComponent
            guard Self.isRealDirectory(path) else { return String(localized: "It is no longer a cache folder: \(name).", bundle: .airyCore) }
            guard RiskPolicy.isInside(RiskPolicy.canonical(path), root: support) else {
                return String(localized: "The path is not in Application Support: \(path).", bundle: .airyCore)
            }
            // `Crashpad/completed` hangs from `Crashpad`; the rest, from the app's folder.
            let parent = (path as NSString).deletingLastPathComponent
            let isCompleted = name == "completed" && (parent as NSString).lastPathComponent == "Crashpad"
            let folder = isCompleted ? (parent as NSString).deletingLastPathComponent : parent
            let allowed = isCompleted || Self.markers.contains(name) || Self.alsoCleared.contains(name)
            guard allowed else { return String(localized: "It is not a known cache folder: \(name).", bundle: .airyCore) }
            guard let siblings = Self.children(of: folder), !Set(Self.markers).isDisjoint(with: siblings) else {
                return String(localized: "The app no longer has recognizable cache folders: \(name).", bundle: .airyCore)
            }
            if claimedByOther(path, entry: entry, context: context) {
                return String(localized: "Another catalog entry manages it now: \(name).", bundle: .airyCore)
            }
            if let match = protection(of: path, context: context) {
                return String(localized: "This folder is protected by Airy: \(match.reason)", bundle: .airyCore)
            }
        }
        return nil
    }
}
