import Foundation

/// Entry with `discovery {"type":"staleTemporaryFiles"}`: entries directly inside the user's temporary folder
/// (`NSTemporaryDirectory()`, the `…/T` folder in `/private/var/folders`) that nothing changed in `staleDays`,
/// grouped into a single item. Each entry must be a regular file or a real folder owned by the user, with its own
/// date and its newest descendant both older than the cutoff (bounded walk), and no process may have anything
/// open inside it. If the open files cannot be read in time, nothing is offered (fail closed).
/// `/private/tmp` is never looked at: it stays sealed by `HardProtections` (only the user's temporary folder is an
/// exception inside `/private`).
public struct TemporaryFilesSource: CleanupTargetSource {
    public static let staleDays = 3
    /// Time limit to walk every entry of a pass, and per entry.
    public static let totalBudget: Duration = .seconds(20)
    public static let entryBudget: Duration = .seconds(5)
    /// Names (or prefixes) never offered: system-managed folders and Airy's own temporary files.
    static let skippedPrefixes = ["com.apple.", "airy-"]
    static let skippedNames: Set<String> = ["TemporaryItems", "Cleanup At Startup"]

    /// Tests only: the temporary folder to look in (instead of the real one).
    @TaskLocal static var rootOverride: String?

    private let openFilesBudget: Duration

    public init() { openFilesBudget = TimeBudget.processScan }

    init(openFilesBudget: Duration) { self.openFilesBudget = openFilesBudget }

    /// The resolved temporary folder for `home`. Only the real user's home has one: with any other home (tests,
    /// previews) the source offers nothing unless `rootOverride` is set.
    static func root(home: String) -> String? {
        if let override = rootOverride { return CleanupTargets.realPath(override) ?? override }
        guard RiskPolicy.canonical(home) == RiskPolicy.canonical(NSHomeDirectory())
            || RiskPolicy.canonical(CleanupTargets.realPath(home) ?? home)
            == RiskPolicy.canonical(CleanupTargets.realPath(NSHomeDirectory()) ?? NSHomeDirectory()) else { return nil }
        guard let real = CleanupTargets.realPath(NSTemporaryDirectory()) else { return nil }
        // The same folder `HardProtections` exempts inside `/private`; never anything wider.
        guard RiskPolicy.canonical(real) == HardProtections.userTemporaryDirectory else { return nil }
        return real
    }

    static func isSkipped(_ name: String) -> Bool {
        skippedNames.contains(name) || skippedPrefixes.contains { name.hasPrefix($0) }
    }

    // MARK: - Detection

    public func discover(_ entry: CatalogEntry, context: DiscoveryContext) async -> [DiscoveredTarget] {
        guard let root = Self.root(home: context.home), DiskScope.allowsWalk(root),
              let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }
        let cutoff = context.now.addingTimeInterval(-Double(Self.staleDays) * 86_400)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.totalBudget)
        var stale: [(path: String, bytes: Int64, latest: Date?)] = []
        for name in names.sorted() where !Self.isSkipped(name) {
            if Task.isCancelled { return [] }
            let remaining = clock.now.duration(to: deadline)
            guard remaining > .zero else { break }
            let path = root + "/" + name
            guard let summary = Self.staleSummary(path, cutoff: cutoff, budget: min(remaining, Self.entryBudget))
            else { continue }
            stale.append((path, summary.bytes, summary.latestModification))
        }
        guard !stale.isEmpty else { return [] }
        // A single pass over every process's open files; unknown or too slow ⇒ nothing is offered.
        let listing = context.processListing
        guard let outcome = await TimeBudget.run(openFilesBudget, { listing.openPaths(under: [root]) }),
              let open = outcome else { return [] }
        let openCanonical = open.map(RiskPolicy.canonical)
        stale.removeAll { item in
            let canonical = RiskPolicy.canonical(item.path)
            return openCanonical.contains { RiskPolicy.isInside($0, root: canonical) }
        }
        guard !stale.isEmpty else { return [] }
        let bytes = stale.reduce(Int64(0)) { $0 + $1.bytes }
        if let minimum = entry.minimumBytes, bytes < minimum { return [] }
        let latest = stale.compactMap(\.latest).max()
        var details = [String(localized: "\(stale.count) old items in the temporary folder", bundle: .airyCore)]
        if let latest {
            details.append(String(localized: "Last change: \(Format.relativeDate(latest))", bundle: .airyCore))
        }
        return [DiscoveredTarget(paths: stale.map(\.path), bytes: bytes, details: details, lastModified: latest)]
    }

    /// The walk summary of `path` if it qualifies: a regular file or a real folder owned by the user, with its own
    /// date and its newest descendant before `cutoff`. Sockets, links and other special entries never qualify; a
    /// walk that does not finish in `budget` does not either.
    static func staleSummary(_ path: String, cutoff: Date, budget: Duration) -> TreeSummary? {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_uid == getuid() else { return nil }
        let type = info.st_mode & S_IFMT
        guard type == S_IFREG || type == S_IFDIR else { return nil }
        let own = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
        guard own < cutoff else { return nil }
        guard let summary = TreeWalk.summarize(path, budget: budget),
              let latest = summary.latestModification, latest < cutoff else { return nil }
        return summary
    }

    // MARK: - Before acting

    public func revalidate(_ entry: CatalogEntry, item: CleanupItem, context: DiscoveryContext) async -> String? {
        guard let root = Self.root(home: context.home) else {
            return String(localized: "The temporary folder is not available; Airy does not touch it.", bundle: .airyCore)
        }
        guard !item.paths.isEmpty else { return String(localized: "There is nothing to send to the Trash.", bundle: .airyCore) }
        let canonicalRoot = RiskPolicy.canonical(root)
        let cutoff = context.now.addingTimeInterval(-Double(Self.staleDays) * 86_400)
        let deadline = ContinuousClock().now.advanced(by: TimeBudget.sizeMeasure)
        for path in item.paths {
            let name = (path as NSString).lastPathComponent
            let parent = (path as NSString).deletingLastPathComponent
            // Directly inside the temporary folder, through no link.
            guard RiskPolicy.canonical(CleanupTargets.realPath(parent) ?? parent) == canonicalRoot,
                  RiskPolicy.canonical(parent) == canonicalRoot, !Self.isSkipped(name) else {
                return String(localized: "It is not in the temporary folder: \(name).", bundle: .airyCore)
            }
            let remaining = ContinuousClock().now.duration(to: deadline)
            guard Self.staleSummary(path, cutoff: cutoff, budget: max(.zero, remaining)) != nil else {
                return String(localized: "It changed recently, it is not yours or it could not be checked in time: \(name).", bundle: .airyCore)
            }
        }
        let listing = context.processListing
        guard let outcome = await TimeBudget.run(openFilesBudget, { listing.openPaths(under: [root]) }),
              let open = outcome else {
            return String(localized: "Could not check whether it is in use; Airy does not touch it.", bundle: .airyCore)
        }
        let openCanonical = open.map(RiskPolicy.canonical)
        for path in item.paths {
            let canonical = RiskPolicy.canonical(path)
            if openCanonical.contains(where: { RiskPolicy.isInside($0, root: canonical) }) {
                return String(localized: "It is in use: \((path as NSString).lastPathComponent).", bundle: .airyCore)
            }
        }
        return nil
    }
}
