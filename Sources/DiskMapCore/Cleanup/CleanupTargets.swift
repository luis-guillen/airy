import Foundation
import Synchronization

/// What a source needs to discover or revalidate targets.
public struct DiscoveryContext: Sendable {
    public let catalog: Catalog
    public let home: String
    public let runner: any CommandRunning
    public let processListing: any ProcessListing
    public let now: Date
    /// Index of the last exploration (to measure without walking the disk), if any.
    public let scan: FileNode?
    /// Docker state for this pass (a single probe); `nil` ⇒ `DockerSource` asks for it.
    public let docker: DockerState?
    /// Project walk for this pass, shared by every `projectArtifacts` entry.
    let projectWalk = ProjectWalkMemo()
    /// Detection of tool versions for this pass, shared by every `toolchains` entry.
    let toolchains = ToolchainMemo()

    public init(catalog: Catalog, home: String, runner: any CommandRunning, processListing: any ProcessListing,
                now: Date, scan: FileNode?, docker: DockerState? = nil) {
        self.catalog = catalog
        self.home = home.count > 1 && home.hasSuffix("/") ? String(home.dropLast()) : home
        self.runner = runner; self.processListing = processListing; self.now = now; self.scan = scan
        self.docker = docker
    }
}

/// A preview batch (the confirmation sheet) or an execution batch: the sources revalidate with a single
/// `DiscoveryContext`, so the expensive work (version inventory, project list, `brew uses`) is computed once
/// for all its rows and not once per row. It only lives as long as the batch.
public final class RevalidationPass: Sendable {
    private let context = Mutex<DiscoveryContext?>(nil)

    public init() {}

    func context(_ make: () -> DiscoveryContext) -> DiscoveryContext {
        context.withLock { current in
            if let current { return current }
            let fresh = make()
            current = fresh
            return fresh
        }
    }
}

/// An item proposed by a source, before measuring and classifying it.
public struct DiscoveredTarget: Sendable, Equatable {
    /// `nil` ⇒ the id is `entry.id`; otherwise, `"\(entry.id):\(idSuffix)"`.
    public var idSuffix: String?
    public var paths: [String]
    /// `{target}` values (see `CleanupMethod.targetPlaceholder`).
    public var targets: [String] = []
    /// `nil` ⇒ the scanner measures it (index or `TreeWalk` with `TimeBudget.sizeMeasure`).
    public var bytes: Int64? = nil
    public var details: [String] = []
    public var lastModified: Date? = nil
    /// String to look for in projects (reference check).
    public var needle: String? = nil
    /// Guard: it only raises the risk.
    public var floor: Risk? = nil
    public var floorReason: String? = nil
    public var blockedReason: String? = nil
    public var sizeNote: String? = nil
    /// `false` ⇒ never starts checked, even if the classifier allows it (it only lowers the preselection).
    public var preselectable: Bool = true
    /// Own title for the UI (instead of "entry: suffix"), e.g. "Python 3.12 (Homebrew)".
    public var label: String? = nil

    public init(idSuffix: String? = nil, paths: [String], targets: [String] = [], bytes: Int64? = nil,
                details: [String] = [], lastModified: Date? = nil, needle: String? = nil, floor: Risk? = nil,
                floorReason: String? = nil, blockedReason: String? = nil, sizeNote: String? = nil) {
        self.idSuffix = idSuffix; self.paths = paths; self.targets = targets; self.bytes = bytes
        self.details = details; self.lastModified = lastModified; self.needle = needle; self.floor = floor
        self.floorReason = floorReason; self.blockedReason = blockedReason; self.sizeNote = sizeNote
    }
}

/// The single extension point of cleanup: the scanner discovers with `discover` and the funnel checks
/// again with `revalidate` right before acting. The same rule in both places.
public protocol CleanupTargetSource: Sendable {
    func discover(_ entry: CatalogEntry, context: DiscoveryContext) async -> [DiscoveredTarget]
    /// In the funnel, right before acting. `nil` = still valid as is; otherwise, a localized reason.
    func revalidate(_ entry: CatalogEntry, item: CleanupItem, context: DiscoveryContext) async -> String?
}

public enum CleanupTargets {
    /// `discovery` ⇒ its source; `retention` ⇒ `RetentionSource`; otherwise, `StaticPatternSource`.
    public static func source(for entry: CatalogEntry) -> any CleanupTargetSource {
        if entry.section == .maintenance { return MaintenanceSource() }
        if entry.discovery == .docker { return DockerSource() }
        if entry.discovery == .simulatorRuntimes { return SimulatorRuntimeSource() }
        if case .projectArtifacts = entry.discovery { return ProjectArtifactSource() }
        if entry.discovery == .installers { return InstallerSource() }
        if entry.discovery == .appSupportCaches { return AppSupportCacheSource() }
        if case .toolchains = entry.discovery { return ToolchainSource() }
        if entry.discovery == .toolchainSystemInfo { return ToolchainSystemInfoSource() }
        if entry.discovery == .dependencyDuplicates { return DependencyDuplicateSource() }
        if entry.discovery != nil { return PendingDiscoverySource() }
        if entry.retention != nil { return RetentionSource() }
        return StaticPatternSource()
    }

    /// Paths of the entry's patterns that exist now, without repeats and without those in `except`.
    static func livePaths(of entry: CatalogEntry, home: String) -> [String] {
        var unique: [String] = []
        for path in entry.paths.flatMap({ CleanupScanner.expand($0, home: home) })
        where !unique.contains(path) && !entry.except.contains((path as NSString).lastPathComponent) {
            unique.append(path)
        }
        return unique
    }

    static func canonicalSet(_ paths: [String]) -> Set<String> { Set(paths.map(RiskPolicy.canonical)) }

    static func realPath(_ path: String) -> String? {
        guard let real = realpath(path, nil) else { return nil }
        defer { free(real) }
        return String(cString: real)
    }

    static func expandTilde(_ pattern: String, home: String) -> String {
        if pattern == "~" { return home }
        if pattern.hasPrefix("~/") { return home + pattern.dropFirst(1) }
        return pattern
    }
}

/// Source of a `discovery` this version does not know how to walk yet: it offers nothing and, if an
/// item arrives, it is rejected (fail closed).
struct PendingDiscoverySource: CleanupTargetSource {
    func discover(_ entry: CatalogEntry, context: DiscoveryContext) async -> [DiscoveredTarget] { [] }

    func revalidate(_ entry: CatalogEntry, item: CleanupItem, context: DiscoveryContext) async -> String? {
        String(localized: "Airy does not know how to check “\(entry.title)” yet; it is not touched.", bundle: .airyCore)
    }
}

/// The entry's patterns (phase 1 behaviour), with `except`, `perMatch`, `staleAfterDays`,
/// `minimumBytes` and `{target}`.
public struct StaticPatternSource: CleanupTargetSource {
    private let measureBudget: Duration

    public init() { measureBudget = TimeBudget.sizeMeasure }

    init(measureBudget: Duration) { self.measureBudget = measureBudget }

    public func discover(_ entry: CatalogEntry, context: DiscoveryContext) async -> [DiscoveredTarget] {
        let unique = CleanupTargets.livePaths(of: entry, home: context.home)
        if case .command(let executable, _, let sizeProbe) = entry.cleanup {
            // Without the tool installed it cannot be cleaned with its official command.
            guard await context.runner.resolve(executable) != nil else { return [] }
            // Only the sqlite3 probe can be interpreted (free space of a database). The others
            // (tmutil…) are not measured (Docker goes through `DockerSource`).
            if let sizeProbe {
                guard executable == "sqlite3", let resolved = await context.runner.resolve(executable) else { return [] }
                return await sqliteGroups(entry, paths: unique, probe: sizeProbe, executable: resolved,
                                          runner: context.runner)
            }
        }

        var groups: [DiscoveredTarget] = []
        if entry.referenceCheck != nil {
            groups = unique.map { path in
                let folder = (path as NSString).lastPathComponent
                return DiscoveredTarget(idSuffix: folder, paths: [path],
                                        needle: entry.referenceNeedle(forMatchedFolder: folder))
            }
        } else if entry.perMatch {
            groups = unique.map { DiscoveredTarget(idSuffix: Format.tildePath($0, home: context.home), paths: [$0]) }
        } else if !unique.isEmpty {
            groups = [DiscoveredTarget(paths: unique)]
        }

        var result: [DiscoveredTarget] = []
        // A single time limit for every measurement of this entry (e.g. each item in Downloads).
        let deadline = ContinuousClock().now.advanced(by: measureBudget)
        for var group in groups {
            if entry.staleAfterDays != nil || entry.minimumBytes != nil {
                guard measure(&group, entry: entry, now: context.now, scan: context.scan, deadline: deadline)
                else { continue }
            }
            if entry.cleanup.usesTargets { group.targets = group.paths }
            result.append(group)
        }
        return result
    }

    static let sqliteProbeTimeout: TimeInterval = 10

    /// One probe per database: `bytes = page_size × freelist_count` (two integers, one per line). If it fails or
    /// cannot be understood, that database is not offered. A single item with the databases that pass `minimumBytes`.
    private func sqliteGroups(_ entry: CatalogEntry, paths: [String], probe: [String], executable: String,
                              runner: any CommandRunning) async -> [DiscoveredTarget] {
        var kept: [String] = []
        var bytes: Int64 = 0
        for path in paths {
            let arguments = probe.map { $0 == CleanupMethod.targetPlaceholder ? path : $0 }
            guard let output = try? await runner.run(executable, arguments, timeout: Self.sqliteProbeTimeout),
                  output.status == 0 else { continue }
            let numbers = output.stdout.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard numbers.count == 2, let pageSize = Int64(numbers[0]), let freePages = Int64(numbers[1]),
                  pageSize > 0, pageSize <= 65_536, freePages >= 0 else { continue }
            kept.append(path)
            bytes += pageSize * freePages
        }
        guard !kept.isEmpty, bytes >= (entry.minimumBytes ?? 1) else { return [] }
        return [DiscoveredTarget(paths: kept, targets: kept, bytes: bytes)]
    }

    /// Applies `staleAfterDays` (removes recent or unmeasured paths) and `minimumBytes`. `false` ⇒ out.
    /// Without `staleAfterDays`, the index size is enough (no need to walk the disk).
    private func measure(_ group: inout DiscoveredTarget, entry: CatalogEntry, now: Date, scan: FileNode?,
                         deadline: ContinuousClock.Instant) -> Bool {
        let cutoff = entry.staleAfterDays.map { now.addingTimeInterval(-Double($0) * 86_400) }
        var kept: [String] = []
        var bytes: Int64 = 0
        var latest: Date?
        for path in group.paths {
            if cutoff == nil, let scan, let node = CleanupScanner.node(at: path, in: scan) {
                kept.append(path)
                bytes += node.allocatedSize
                continue
            }
            // Without time it cannot be known: it is not offered.
            guard let summary = TreeWalk.summarize(path, budget: max(.zero, ContinuousClock().now.duration(to: deadline)))
            else { continue }
            if let cutoff {
                guard let modified = summary.latestModification, modified < cutoff else { continue }
            }
            kept.append(path)
            bytes += summary.bytes
            if let modified = summary.latestModification, latest.map({ modified > $0 }) ?? true { latest = modified }
        }
        guard !kept.isEmpty else { return false }
        if let minimum = entry.minimumBytes, bytes < minimum { return false }
        group.paths = kept
        group.bytes = bytes
        group.lastModified = latest
        return true
    }

    public func revalidate(_ entry: CatalogEntry, item: CleanupItem, context: DiscoveryContext) async -> String? {
        switch entry.cleanup {
        case .info:
            return nil
        case .trash:
            let live = CleanupTargets.canonicalSet(CleanupTargets.livePaths(of: entry, home: context.home))
            for path in item.paths where !live.contains(RiskPolicy.canonical(path)) {
                return String(localized: "The path does not belong to “\(entry.title)”: \(path).", bundle: .airyCore)
            }
            guard let days = entry.staleAfterDays else { return nil }
            let cutoff = context.now.addingTimeInterval(-Double(days) * 86_400)
            for path in item.paths {
                guard let summary = TreeWalk.summarize(path, budget: TimeBudget.sizeMeasure) else {
                    return String(localized: "Could not check in time whether you have used it; Airy does not touch it.", bundle: .airyCore)
                }
                guard let modified = summary.latestModification, modified < cutoff else {
                    return String(localized: "You have used it recently.", bundle: .airyCore)
                }
            }
            return nil
        case .command:
            guard entry.cleanup.usesTargets else { return nil }
            let live = CleanupTargets.canonicalSet(CleanupTargets.livePaths(of: entry, home: context.home))
            for target in item.targets where !live.contains(RiskPolicy.canonical(target)) || !target.hasPrefix("/") {
                return String(localized: "The target does not belong to “\(entry.title)”: \(target).", bundle: .airyCore)
            }
            return nil
        }
    }
}

/// Versions: per parent folder, the active one (if there is an `activeLink`) and the newest ones up to
/// `keepNewest` are kept; the rest forms a single item.
public struct RetentionSource: CleanupTargetSource {
    public init() {}

    public func discover(_ entry: CatalogEntry, context: DiscoveryContext) async -> [DiscoveredTarget] {
        let plan = Self.plan(entry, home: context.home)
        guard !plan.removable.isEmpty else { return [] }
        return [DiscoveredTarget(paths: plan.removable, details: plan.details)]
    }

    public func revalidate(_ entry: CatalogEntry, item: CleanupItem, context: DiscoveryContext) async -> String? {
        let removable = CleanupTargets.canonicalSet(Self.plan(entry, home: context.home).removable)
        for path in item.paths where !removable.contains(RiskPolicy.canonical(path)) {
            return String(localized: "It is no longer an old version: \((path as NSString).lastPathComponent).", bundle: .airyCore)
        }
        guard entry.retention?.activeLink != nil else { return nil }
        let listing = context.processListing
        guard let outcome = await TimeBudget.run(TimeBudget.processScan, { listing.processes() }),
              let processes = outcome else {
            return String(localized: "Could not check whether it is in use; Airy does not touch it.", bundle: .airyCore)
        }
        for path in item.paths {
            var roots = [RiskPolicy.canonical(path)]
            if let real = CleanupTargets.realPath(path) { roots.append(RiskPolicy.canonical(real)) }
            for process in processes {
                guard let executable = process.executablePath else { continue }
                let exe = RiskPolicy.canonical(executable)
                if roots.contains(where: { RiskPolicy.isInside(exe, root: $0) }) {
                    return String(localized: "It is in use: \((path as NSString).lastPathComponent).", bundle: .airyCore)
                }
            }
        }
        return nil
    }

    struct Plan { var removable: [String]; var details: [String] }

    /// Leftover paths (in pattern order) and one "Kept: …" per parent folder.
    /// With `activeLink`, a folder whose active version is not found yields nothing (fail closed).
    static func plan(_ entry: CatalogEntry, home: String) -> Plan {
        guard let rule = entry.retention else { return Plan(removable: [], details: []) }
        var parents: [String] = []
        var groups: [String: [String]] = [:]
        for path in CleanupTargets.livePaths(of: entry, home: home) {
            let parent = (path as NSString).deletingLastPathComponent
            if groups[parent] == nil { parents.append(parent) }
            groups[parent, default: []].append(path)
        }
        let active = rule.activeLink.flatMap {
            CleanupTargets.realPath(CleanupTargets.expandTilde($0, home: home)).map(RiskPolicy.canonical)
        }
        var plan = Plan(removable: [], details: [])
        for parent in parents {
            let group = groups[parent] ?? []
            let sorted = group.map { ($0, modification(of: $0)) }.sorted { a, b in
                if a.1 != b.1 { return a.1 > b.1 }
                return (a.0 as NSString).lastPathComponent > (b.0 as NSString).lastPathComponent
            }.map(\.0)
            var kept: [String] = []
            if rule.activeLink != nil {
                guard let active, let version = sorted.first(where: { path in
                    let root = RiskPolicy.canonical(CleanupTargets.realPath(path) ?? path)
                    return RiskPolicy.isInside(active, root: root)
                }) else { continue }
                kept.append(version)
            }
            for path in sorted where kept.count < rule.keepNewest && !kept.contains(path) { kept.append(path) }
            plan.removable += group.filter { !kept.contains($0) }
            let names = sorted.filter(kept.contains).map { ($0 as NSString).lastPathComponent }
            plan.details.append(String(localized: "Kept: \(names.joined(separator: ", "))", bundle: .airyCore))
        }
        return plan
    }

    /// `mtime` of the entry (without following links); 0 if it cannot be read.
    private static func modification(of path: String) -> Double {
        var info = stat()
        guard lstat(path, &info) == 0 else { return 0 }
        return Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
    }
}
