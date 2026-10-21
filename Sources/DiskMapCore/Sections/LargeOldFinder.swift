import Foundation

public protocol FileUsageReading: Sendable { func lastOpened(path: String) -> Date? }

/// Last use according to Spotlight (`kMDItemLastUsedDate`), without launching processes.
public struct SpotlightFileUsage: FileUsageReading {
    public init() {}

    public func lastOpened(path: String) -> Date? {
        guard let item = MDItemCreateWithURL(nil, URL(fileURLWithPath: path) as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }
}

public struct LargeOldQuery: Sendable, Equatable {
    public enum Sort: String, Sendable, CaseIterable { case size, oldest, name }   // "Size", "Oldest", "Name"
    public enum Scope: String, Sendable, CaseIterable { case home, everything }    // "Your folder", "Whole disk"
    public static let sizeSteps: [Int64] = [100_000_000, 500_000_000, 1_000_000_000, 5_000_000_000]
    public static let idleSteps: [Int?] = [nil, 3, 6, 12]     // months; "Any date", "3 months", "6 months", "1 year"
    public var minBytes: Int64 = 100_000_000
    public var minMonthsIdle: Int?
    public var kinds: Set<ContentKind> = []                    // empty = all
    public var scope: Scope = .home
    public var sort: Sort = .size
    public var limit = 500
    public init() {}
}

/// Finds large, unopened files in the already scanned tree (it does not walk the disk). It only asks
/// Spotlight about the candidates that pass the size, with a time limit: if it runs out, those files
/// are left with "unknown date" and never count as old.
public struct LargeOldFinder: Sendable {
    public static let usageBudget: Duration = .seconds(4)
    private static let monthSeconds: TimeInterval = 30 * 86_400

    private let classifier: RiskClassifier
    private let catalog: Catalog?
    private let gate: PathGate
    private let home: String
    private let usage: any FileUsageReading
    private let now: @Sendable () -> Date
    private let budget: Duration

    public init(classifier: RiskClassifier, catalog: Catalog?, gate: PathGate, home: String,
                usage: any FileUsageReading = SpotlightFileUsage(), now: @escaping @Sendable () -> Date = Date.init,
                budget: Duration = LargeOldFinder.usageBudget) {
        self.classifier = classifier; self.catalog = catalog; self.gate = gate; self.home = home
        self.usage = usage; self.now = now; self.budget = budget
    }

    private struct Candidate {
        let node: FileNode, path: String
        var opened: Date?, unknown = false
        var activity: Date? {
            switch (node.lastModified, opened) {
            case let (a?, b?): max(a, b)
            case let (a?, nil): a
            case let (nil, b?): b
            case (nil, nil): nil
            }
        }
    }

    /// Only files (not folders nor "Other" aggregates), without entering `.app`; `usage` only for those that pass the size.
    /// A month = 30 days; idle = now − lastActivity; no dates ⇒ it does not pass a months filter.
    public func find(in root: FileNode, query: LargeOldQuery) -> [ActionableFile] {
        let homeCanonical = RiskPolicy.canonical(home)
        var candidates: [Candidate] = []
        collect(root, path: root.path, query: query, home: homeCanonical, into: &candidates)
        // Cancellable tree reader: if it is cancelled (a tree change, another filter), it stops walking.
        if Task.isCancelled { return [] }

        let current = now()
        let cutoff = query.minMonthsIdle.map { current.addingTimeInterval(-Double($0) * Self.monthSeconds) }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: budget)
        var result: [Candidate] = []
        for var candidate in candidates {
            if Task.isCancelled { return [] }
            // A file modified after the cutoff will never be "old": no need to ask.
            if let cutoff, let modified = candidate.node.lastModified, modified > cutoff { continue }
            if clock.now < deadline {
                candidate.opened = usage.lastOpened(path: candidate.path)
            } else {
                candidate.unknown = true
            }
            if let cutoff {
                guard !candidate.unknown, let activity = candidate.activity, activity <= cutoff else { continue }
            }
            result.append(candidate)
        }

        result.sort { a, b in
            switch query.sort {
            case .size:
                if a.node.allocatedSize != b.node.allocatedSize { return a.node.allocatedSize > b.node.allocatedSize }
            case .oldest:
                switch (a.activity, b.activity) {
                case let (x?, y?) where x != y: return x < y
                case (nil, .some): return false
                case (.some, nil): return true
                default: break
                }
            case .name:
                let order = a.node.name.localizedStandardCompare(b.node.name)
                if order != .orderedSame { return order == .orderedAscending }
            }
            return a.path < b.path
        }
        return result.prefix(max(query.limit, 0)).map {
            ActionableFile.make(node: $0.node, classifier: classifier, catalog: catalog, gate: gate,
                                lastOpened: $0.opened, home: home, openDateUnknown: $0.unknown)
        }
    }

    private func collect(_ node: FileNode, path: String, query: LargeOldQuery, home: String,
                         into out: inout [Candidate]) {
        if Task.isCancelled { return }
        let canonical = RiskPolicy.canonical(path)
        if query.scope == .home {
            let inside = RiskPolicy.isInside(canonical, root: home)
            let ancestor = home.hasPrefix(canonical == "/" ? "/" : canonical + "/")
            guard inside || ancestor else { return }
        }
        if node.isDirectory {
            if node.aggregatedCount > 0 { return }
            if node.name.lowercased().hasSuffix(".app") { return }
            for child in node.children {
                collect(child, path: path == "/" ? "/" + child.name : path + "/" + child.name,
                        query: query, home: home, into: &out)
            }
            return
        }
        guard node.aggregatedCount == 0, node.allocatedSize >= query.minBytes else { return }
        if !query.kinds.isEmpty, !query.kinds.contains(node.kind) { return }
        guard query.scope == .everything || RiskPolicy.isInside(canonical, root: home) else { return }
        out.append(Candidate(node: node, path: path))
    }
}
