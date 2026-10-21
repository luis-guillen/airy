import Foundation

/// Something concrete that can be cleaned: a catalog entry with its real paths and its size.
public struct CleanupItem: Sendable, Identifiable {
    /// `entry.id`, or `"\(entry.id):\(folder)"` for entries with a reference check.
    public var id: String
    public var entry: CatalogEntry
    /// Existing absolute paths (empty for cleanups without paths, like Docker).
    public var paths: [String]
    public var bytes: Int64
    public var risk: Risk
    /// Bundle IDs from `mustBeClosed` that were open at detection time.
    public var blockedByOpenApps: [String]
    /// Project files that reference this item.
    public var usedBy: [String]
    /// Starts checked (according to the classifier and the mode).
    public var preselected: Bool
    /// Matches one of the user's usage profiles: it goes first within its group.
    public var highlighted: Bool
    /// Protection that leaves it as "Do not touch", without a checkbox.
    public var protection: ProtectionMatch?
    /// Why it cannot be cleaned right now (open processes, incomplete check…), or `nil`.
    public var blockedReason: String?
    /// Lines for the UI: container names, "Kept: …", "Project untouched since …".
    public var details: [String]
    /// `{target}` values (see `CleanupMethod.targetPlaceholder`).
    public var targets: [String]
    /// Text instead of the size ("Unknown size", "Takes no disk space").
    public var sizeNote: String?
    public var lastModified: Date?
    /// Reason from a source guard (floor) or from a protection.
    public var riskReason: String?
    /// The size does not include everything (unread parts).
    public var sizeIsPartial: Bool
    /// The source's own title (see `DiscoveredTarget.label`).
    public var label: String? = nil

    public init(id: String, entry: CatalogEntry, paths: [String], bytes: Int64, risk: Risk,
                blockedByOpenApps: [String], usedBy: [String], preselected: Bool = false, highlighted: Bool = false,
                protection: ProtectionMatch? = nil, blockedReason: String? = nil, details: [String] = [],
                targets: [String] = [], sizeNote: String? = nil, lastModified: Date? = nil,
                riskReason: String? = nil, sizeIsPartial: Bool = false) {
        self.id = id; self.entry = entry; self.paths = paths; self.bytes = bytes
        self.risk = risk; self.blockedByOpenApps = blockedByOpenApps; self.usedBy = usedBy
        self.preselected = preselected; self.highlighted = highlighted
        self.protection = protection; self.blockedReason = blockedReason
        self.details = details; self.targets = targets; self.sizeNote = sizeNote
        self.lastModified = lastModified; self.riskReason = riskReason; self.sizeIsPartial = sizeIsPartial
    }

    /// Title for the UI and the history (includes the folder for per-folder items).
    public var title: String {
        if let label, !label.isEmpty { return label }
        guard let colon = id.firstIndex(of: ":"), id[..<colon] == entry.id else { return entry.title }
        return "\(entry.title): \(id[id.index(after: colon)...])"
    }
}

/// Detects which catalog entries exist on this Mac and how much they take up. It never runs cleanups:
/// only `resolve` and the size probes (`sizeProbe`).
public struct CleanupScanner: Sendable {
    public static let referenceTimeout: TimeInterval = 10

    private let catalog: Catalog
    private let runner: any CommandRunning
    private let probes: any SystemProbing
    private let references: ReferenceChecker
    private let home: String
    private let classifier: RiskClassifier
    private let processListing: any ProcessListing
    private let referenceTimeout: TimeInterval
    private let measureBudget: Duration
    /// Disk scope of the detection (`AIRY_SCAN_ROOTS` in DEBUG); `nil` ⇒ that of the calling task.
    private let scope: DiskScope?

    /// `classifier`: `nil` ⇒ default settings with this catalog and this home. `measureBudget`: time limit to
    /// measure each path that is not in the index.
    public init(catalog: Catalog, runner: any CommandRunning, probes: any SystemProbing,
                references: ReferenceChecker, home: String = NSHomeDirectory(), classifier: RiskClassifier? = nil,
                processListing: any ProcessListing = LibprocListing(),
                referenceTimeout: TimeInterval = CleanupScanner.referenceTimeout,
                measureBudget: Duration = TimeBudget.sizeMeasure, scope: DiskScope? = nil) {
        self.scope = scope
        self.processListing = processListing
        self.measureBudget = measureBudget
        self.referenceTimeout = referenceTimeout
        self.catalog = catalog
        self.runner = runner
        self.probes = probes
        self.references = references
        self.home = home.count > 1 && home.hasSuffix("/") ? String(home.dropLast()) : home
        self.classifier = classifier ?? RiskClassifier(catalog: catalog, settings: .defaults, home: self.home)
    }

    private struct Candidate {
        var id: String
        var entry: CatalogEntry
        var target: DiscoveredTarget
        var bytes: Int64
    }

    /// `inaccessible`: folders the scan could not read; a size taken from the index for a path with something
    /// unreadable inside is a minimum (`sizeIsPartial`).
    /// A cancelled pass returns `[]` as soon as it notices (stops reading the disk): it is never published.
    public func findItems(scan: FileNode?, inaccessible: [String] = []) async -> [CleanupItem] {
        guard let scope else { return await detect(scan: scan, inaccessible: inaccessible) }
        return await DiskScope.$current.withValue(scope) { await detect(scan: scan, inaccessible: inaccessible) }
    }

    private func detect(scan: FileNode?, inaccessible: [String]) async -> [CleanupItem] {
        let partialIndex = PartialScanIndex(inaccessible: inaccessible)
        let running = probes.runningBundleIDs()
        // A single Docker probe per pass for all its entries.
        let docker = catalog.entries.contains { $0.discovery == .docker }
            ? await DockerProbe.state(runner: runner) : nil
        let context = DiscoveryContext(catalog: catalog, home: home, runner: runner,
                                       processListing: processListing, now: Date(), scan: scan, docker: docker)
        var candidates: [Candidate] = []
        // One path, one item: the first catalog entry that claims it keeps it.
        var claimed = Set<String>()
        // All informational entries share a single measuring time limit (`measureBudget`): what does not fit
        // stays as "Unknown size".
        let clock = ContinuousClock()
        var reviewDeadline: ContinuousClock.Instant?
        // Maintenance (Performance) is not cleanup: `MaintenanceScanner` detects it.
        for entry in catalog.entries where entry.section != .maintenance {
            if Task.isCancelled { return [] }
            for var target in await CleanupTargets.source(for: entry).discover(entry, context: context) {
                let original = target.paths
                if !original.isEmpty {
                    let dropped = Set(original.filter { claimed.contains(RiskPolicy.canonical($0)) })
                    if !dropped.isEmpty {
                        target.paths = original.filter { !dropped.contains($0) }
                        target.targets = target.targets.filter { !dropped.contains($0) }
                        target.bytes = nil // measured again without another item's paths
                    }
                    guard !target.paths.isEmpty else { continue }
                }
                var bytes = target.bytes
                if bytes == nil {
                    var budget = measureBudget
                    var isReview = false
                    if case .info = entry.cleanup {
                        isReview = true
                        let deadline = reviewDeadline ?? clock.now.advanced(by: measureBudget)
                        reviewDeadline = deadline
                        budget = max(.zero, clock.now.duration(to: deadline))
                    }
                    bytes = measure(target.paths, scan: scan, budget: budget)
                    if bytes == nil {
                        target.sizeNote = target.sizeNote ?? String(localized: "Unknown size", bundle: .airyCore)
                        // Without an action there is nothing to block: the entry only informs.
                        if !isReview { target.blockedReason = target.blockedReason ?? String(localized: "Could not be measured in time.", bundle: .airyCore) }
                    }
                }
                let size = bytes ?? 0
                guard size > 0 || target.sizeNote != nil || target.blockedReason != nil else { continue }
                // Only the surviving item claims its paths (not a 0-byte one that gets discarded).
                claimed.formUnion(target.paths.map(RiskPolicy.canonical))
                let id = target.idSuffix.map { "\(entry.id):\($0)" } ?? entry.id
                candidates.append(Candidate(id: id, entry: entry, target: target, bytes: size))
            }
        }

        if Task.isCancelled { return [] }
        let needles = candidates.compactMap(\.target.needle)
        let checked = needles.isEmpty
            ? (found: [String: [String]](), complete: true)
            : await self.references.referencesChecked(toAny: needles, timeout: referenceTimeout)
        let references = checked.found

        // A single process list per pass, and only if some entry needs it.
        let needsProcesses = candidates.contains { !$0.entry.processNames.isEmpty }
        let processes: [RunningProcess]?
        if needsProcesses {
            let listing = processListing
            processes = await TimeBudget.run(TimeBudget.processScan, { listing.processes() }) ?? nil
        } else {
            processes = nil
        }

        return candidates.compactMap { candidate in
            let target = candidate.target
            let usedBy = target.needle.flatMap { references[$0] } ?? []
            let verdict = classifier.classify(entry: candidate.entry, paths: target.paths, floor: target.floor)
            var risk = verdict.risk
            if !usedBy.isEmpty { risk = .doNotTouch }
            // Without the protected paths, the size is only that of the remaining ones. If none remains,
            // the item is shown in red with its original size.
            var paths = target.paths
            var targets = target.targets
            var bytes = candidate.bytes
            if !verdict.keptPaths.isEmpty, verdict.keptPaths != target.paths {
                paths = verdict.keptPaths
                targets = targets.filter { paths.contains($0) || !$0.hasPrefix("/") }
                bytes = measure(paths, scan: scan) ?? 0
                guard bytes > 0 else { return nil }
            }
            // Fail closed: a running process, an unknown list or unfinished references block.
            var blockedReason = target.blockedReason
            if blockedReason == nil {
                blockedReason = ProcessGuard.state(processNames: candidate.entry.processNames, among: processes)
                    .blockedReason
            }
            if blockedReason == nil, target.needle != nil, !checked.complete {
                blockedReason = String(localized: "Could not check in time whether a project uses it.", bundle: .airyCore)
            }
            var item = CleanupItem(
                id: candidate.id, entry: candidate.entry, paths: paths, bytes: bytes,
                risk: risk, blockedByOpenApps: candidate.entry.mustBeClosed.filter { running.contains($0) },
                usedBy: usedBy, preselected: verdict.preselected && risk != .doNotTouch && target.preselectable,
                highlighted: verdict.highlighted, protection: verdict.protection, blockedReason: blockedReason,
                details: target.details, targets: targets, sizeNote: target.sizeNote,
                lastModified: target.lastModified, riskReason: target.floorReason ?? verdict.protection?.reason,
                sizeIsPartial: Self.isPartialSize(paths, scan: scan, index: partialIndex))
            item.label = target.label
            return item
        }
    }

    // MARK: - Sizes

    /// Sum from the index or, if a path is not in it, from `TreeWalk` with `measureBudget`. A path that no longer
    /// exists counts as 0; `nil` if some could not be measured in time.
    private func measure(_ paths: [String], scan: FileNode?, budget: Duration? = nil) -> Int64? {
        let budget = budget ?? measureBudget
        var total: Int64 = 0
        for path in paths {
            if let scan, let node = Self.node(at: path, in: scan) { total += node.allocatedSize; continue }
            // Outside the detection's scope (DEBUG, `AIRY_SCAN_ROOTS`) it is as if it did not exist.
            guard DiskScope.allowsWalk(path) else { continue }
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }
            if let summary = TreeWalk.summarize(path, budget: budget) {
                total += summary.bytes
            } else if (info.st_mode & S_IFMT) == S_IFDIR, !Self.canOpen(path) {
                // A folder that cannot be read (TCC, permissions): as in phase 1, only its own entry.
                total += AllocatedSize.of(path) ?? 0
            } else {
                return nil
            }
        }
        return total
    }

    /// The size comes from the index and some of the paths have something unreadable inside.
    private static func isPartialSize(_ paths: [String], scan: FileNode?, index: PartialScanIndex) -> Bool {
        guard let scan, !index.isEmpty else { return false }
        return paths.contains { index.isPartial($0) && node(at: $0, in: scan) != nil }
    }

    private static func canOpen(_ path: String) -> Bool {
        guard let dir = opendir(path) else { return false }
        closedir(dir)
        return true
    }

    /// Index node for `path`, or `nil` if it is not there (e.g. grouped into "Other").
    static func node(at path: String, in root: FileNode) -> FileNode? {
        if root.name.isEmpty {
            for child in root.children where child.aggregatedCount == 0 {
                if let found = node(at: path, in: child) { return found }
            }
            return nil
        }
        guard root.aggregatedCount == 0 else { return nil }
        if path == root.name { return root }
        let prefix = root.name == "/" ? "/" : root.name + "/"
        guard path.hasPrefix(prefix) else { return nil }
        var current = root
        for component in path.dropFirst(prefix.count).split(separator: "/") {
            guard let next = current.children.first(where: {
                $0.aggregatedCount == 0 && $0.name == component
            }) else { return nil }
            current = next
        }
        return current
    }

    /// "29.89GB (86%)" ⇒ 29,890,000,000 (decimal units; the parenthesis is ignored).
    public static func parseDockerSize(_ text: String) -> Int64? {
        let value = text.split(separator: "(").first?.trimmingCharacters(in: .whitespaces) ?? ""
        let numberPart = value.prefix { $0.isNumber || $0 == "." }
        let unit = value.dropFirst(numberPart.count).trimmingCharacters(in: .whitespaces).uppercased()
        guard !numberPart.isEmpty, let number = Double(numberPart) else { return nil }
        let multipliers: [String: Double] = [
            "B": 1, "KB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12, "PB": 1e15,
        ]
        guard let multiplier = multipliers[unit] else { return nil }
        return Int64((number * multiplier).rounded())
    }

    // MARK: - Patterns

    /// Expands `~` and `*` (within a component) against the real file system.
    /// Returns existing paths (with `lstat`; a broken link also counts), sorted.
    /// With a scope (`DiskScope.current`) it lists and returns nothing outside it.
    static func expand(_ pattern: String, home: String) -> [String] {
        var full = pattern
        if pattern == "~" { full = home } else if pattern.hasPrefix("~/") { full = home + pattern.dropFirst(1) }
        guard full.hasPrefix("/") else { return [] }
        var current = ["/"]
        for component in full.split(separator: "/").map(String.init) {
            var next: [String] = []
            for base in current {
                let prefix = base == "/" ? "/" : base + "/"
                if component.contains("*") {
                    var info = stat()
                    // Only lists inside real folders, never through links.
                    guard DiskScope.allowsList(base), lstat(base, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
                          let names = try? FileManager.default.contentsOfDirectory(atPath: base) else { continue }
                    for name in names.sorted() where fnmatch(component, name, 0) == 0 {
                        next.append(prefix + name)
                    }
                } else if component == "." || component == ".." {
                    return [] // catalog patterns are canonical
                } else {
                    next.append(prefix + component)
                }
            }
            current = next
        }
        return current.filter { path in
            guard DiskScope.allowsWalk(path) else { return false }
            var info = stat()
            return lstat(path, &info) == 0
        }
    }
}
