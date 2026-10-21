import Foundation
import Synchronization

/// Compact summary of a scan, kept so the next scan can say what changed: the sizes of the large nodes (folders
/// and files) down to `maxDepth` below the root, capped to `maxEntries`, plus the bytes per kind. Never contents.
public struct ScanSummary: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var path: String
        public var bytes: Int64
        /// Index of the parent entry, or -1 for the root's children.
        public var parent: Int32

        public init(path: String, bytes: Int64, parent: Int32) {
            self.path = path; self.bytes = bytes; self.parent = parent
        }
    }

    public static let maxDepth = 6
    public static let minimumBytes: Int64 = 256 * 1_000_000
    public static let maxEntries = 3_000

    /// Name of the scan root (`/`, a folder, or empty for several roots): summaries of different roots are not compared.
    public var root: String
    public var scannedAt: Date?
    public var totalBytes: Int64
    /// `ContentKind.rawValue` ⇒ bytes.
    public var kinds: [String: Int64]
    /// Parents before children.
    public var entries: [Entry]
    /// Smallest size an entry can have: anything missing from the summary was smaller.
    public var floorBytes: Int64

    public init(root: String, scannedAt: Date?, totalBytes: Int64, kinds: [String: Int64], entries: [Entry],
                floorBytes: Int64) {
        self.root = root; self.scannedAt = scannedAt; self.totalBytes = totalBytes; self.kinds = kinds
        self.entries = entries; self.floorBytes = floorBytes
    }

    private enum CodingKeys: String, CodingKey { case root, scannedAt, totalBytes, kinds, entries, floorBytes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        root = try c.decode(String.self, forKey: .root)
        scannedAt = try c.decodeIfPresent(Date.self, forKey: .scannedAt)
        totalBytes = try c.decodeIfPresent(Int64.self, forKey: .totalBytes) ?? 0
        kinds = try c.decodeIfPresent([String: Int64].self, forKey: .kinds) ?? [:]
        entries = try c.decodeIfPresent([Entry].self, forKey: .entries) ?? []
        floorBytes = try c.decodeIfPresent(Int64.self, forKey: .floorBytes) ?? Self.minimumBytes
    }

    /// Walks the tree breadth-first. It must run where the tree may be read (`TreeGate` reader, or a tree nobody
    /// else holds).
    public static func make(from result: ScanResult, maxDepth: Int = maxDepth, minimumBytes: Int64 = minimumBytes,
                            maxEntries: Int = maxEntries) -> ScanSummary {
        var kinds: [String: Int64] = [:]
        for (kind, bytes) in zip(ContentKind.allCases, result.root.kindBytes) where bytes > 0 { kinds[kind.rawValue] = bytes }
        var collected: [(node: FileNode, parent: Int, depth: Int)] = []
        var queue: [(FileNode, Int, Int)] = result.root.children.map { ($0, -1, 1) }
        var head = 0
        while head < queue.count {
            let (node, parent, depth) = queue[head]
            head += 1
            guard node.aggregatedCount == 0, node.allocatedSize >= minimumBytes else { continue }
            let index = collected.count
            collected.append((node, parent, depth))
            if depth < maxDepth { for child in node.children { queue.append((child, index, depth + 1)) } }
        }
        var floor = minimumBytes
        var keep = Array(repeating: true, count: collected.count)
        if collected.count > maxEntries {
            // An ancestor is never smaller than its descendants: the largest entries keep their parents.
            let threshold = collected.map(\.node.allocatedSize).sorted(by: >)[maxEntries - 1]
            floor = max(floor, threshold)
            var kept = 0
            for i in collected.indices {
                let parentKept = collected[i].parent < 0 || keep[collected[i].parent]
                keep[i] = parentKept && collected[i].node.allocatedSize >= threshold && kept < maxEntries
                if keep[i] { kept += 1 }
            }
        }
        var newIndex = Array(repeating: Int32(-1), count: collected.count)
        var entries: [Entry] = []
        for i in collected.indices where keep[i] {
            newIndex[i] = Int32(entries.count)
            let parent = collected[i].parent < 0 ? -1 : newIndex[collected[i].parent]
            entries.append(Entry(path: collected[i].node.path, bytes: collected[i].node.allocatedSize, parent: parent))
        }
        return ScanSummary(root: result.root.name, scannedAt: result.scannedAt, totalBytes: result.root.allocatedSize,
                           kinds: kinds, entries: entries, floorBytes: floor)
    }
}

/// A node that grew or shrank between two scans.
public struct PathChange: Sendable, Equatable {
    public var path: String
    public var before: Int64
    public var after: Int64
    public var delta: Int64 { after - before }
    /// Names of the children that explain most of the change (largest first).
    public var hints: [String]

    public init(path: String, before: Int64, after: Int64, hints: [String]) {
        self.path = path; self.before = before; self.after = after; self.hints = hints
    }
}

public struct KindChange: Sendable, Equatable {
    public var kind: ContentKind
    public var before: Int64
    public var after: Int64
    public var delta: Int64 { after - before }
}

/// What changed between the previous summary and the current one.
public struct ScanChanges: Sendable, Equatable {
    public static let defaultMinimumBytes: Int64 = 1_000_000_000
    public static let defaultLimit = 5
    /// Share of a node's change a single child must carry for the change to be attributed to the children.
    static let descendShare = 0.6
    /// Share of a node's change a child must carry to be named as a hint.
    static let hintShare = 0.1

    public var since: Date?
    public var scannedAt: Date?
    public var totalDelta: Int64
    public var growth: [PathChange]
    public var shrink: [PathChange]
    public var kinds: [KindChange]

    public var isEmpty: Bool { growth.isEmpty && shrink.isEmpty && kinds.isEmpty }

    /// `nil` if the roots differ. Changes under `minimumBytes` are left out; each list keeps `limit` items.
    public static func compute(previous: ScanSummary, current: ScanSummary,
                               minimumBytes: Int64 = defaultMinimumBytes, limit: Int = defaultLimit) -> ScanChanges? {
        guard previous.root == current.root else { return nil }
        let minimum = max(minimumBytes, 1)
        var before: [String: Int64] = [:], after: [String: Int64] = [:]
        var children: [String: [String]] = [:]
        var top: [String] = []
        func index(_ summary: ScanSummary, into sizes: inout [String: Int64]) {
            for entry in summary.entries {
                sizes[entry.path] = entry.bytes
                let parent = entry.parent >= 0 && Int(entry.parent) < summary.entries.count
                    ? summary.entries[Int(entry.parent)].path : nil
                if let parent {
                    if !(children[parent]?.contains(entry.path) ?? false) { children[parent, default: []].append(entry.path) }
                } else if !top.contains(entry.path) {
                    top.append(entry.path)
                }
            }
        }
        index(previous, into: &before)
        index(current, into: &after)
        func delta(_ path: String) -> Int64 { (after[path] ?? 0) - (before[path] ?? 0) }

        func collect(sign: Int64) -> [PathChange] {
            var reported: [PathChange] = []
            func visit(_ path: String) {
                let d = delta(path) * sign
                // A change in the other direction (or too small) can still hide one below it.
                guard d >= minimum else {
                    for child in children[path] ?? [] { visit(child) }
                    return
                }
                var kids: [(String, Int64)] = []
                for child in children[path] ?? [] {
                    let change: Int64 = delta(child) * sign
                    if change > 0 { kids.append((child, change)) }
                }
                kids.sort { (a: (String, Int64), b: (String, Int64)) -> Bool in a.1 != b.1 ? a.1 > b.1 : a.0 < b.0 }
                if let first = kids.first, first.1 >= minimum, Double(first.1) >= descendShare * Double(d) {
                    for kid in kids where kid.1 >= minimum { visit(kid.0) }
                    return
                }
                let hints = kids.filter { Double($0.1) >= hintShare * Double(d) }.prefix(2)
                    .map { ($0.0 as NSString).lastPathComponent }
                reported.append(PathChange(path: path, before: before[path] ?? 0, after: after[path] ?? 0,
                                           hints: Array(hints)))
            }
            for path in top { visit(path) }
            return Array(reported.sorted { abs($0.delta) != abs($1.delta) ? abs($0.delta) > abs($1.delta) : $0.path < $1.path }
                .prefix(max(limit, 0)))
        }

        var kinds: [KindChange] = []
        for kind in ContentKind.allCases {
            let change = KindChange(kind: kind, before: previous.kinds[kind.rawValue] ?? 0,
                                    after: current.kinds[kind.rawValue] ?? 0)
            if abs(change.delta) >= minimum { kinds.append(change) }
        }
        kinds.sort { abs($0.delta) != abs($1.delta) ? abs($0.delta) > abs($1.delta) : $0.kind.rawValue < $1.kind.rawValue }
        return ScanChanges(since: previous.scannedAt, scannedAt: current.scannedAt,
                           totalDelta: current.totalBytes - previous.totalBytes,
                           growth: collect(sign: 1), shrink: collect(sign: -1),
                           kinds: Array(kinds.prefix(max(limit, 0))))
    }

    /// Short name for a changed path: "Temporary files" for the user's temporary folder, else its last component.
    public static func label(for path: String) -> String {
        let canonical = RiskPolicy.canonical(CleanupTargets.realPath(path) ?? path)
        if canonical == HardProtections.userTemporaryDirectory || RiskPolicy.canonical(path) == HardProtections.userTemporaryDirectory {
            return String(localized: "Temporary files", bundle: .airyCore)
        }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }
}

/// The previous and the current scan summary (`scan-summary.json`, next to the index). Written only when a new
/// scan finishes, never when the shown tree is saved again after a cleanup.
public final class ScanChangeStore: Sendable {
    public static let fileName = "scan-summary.json"
    static let currentVersion = 1

    public struct Record: Codable, Sendable, Equatable {
        public var version: Int
        public var current: ScanSummary
        public var previous: ScanSummary?
    }

    private let directory: URL
    private let lock = Mutex(())

    public init(directory: URL) { self.directory = directory }

    private var url: URL { directory.appendingPathComponent(Self.fileName) }

    /// The stored record; `nil` if there is none, it is unreadable or it comes from a newer version.
    public func load() -> Record? {
        lock.withLock { _ in read() }
    }

    private func read() -> Record? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let record = try? decoder.decode(Record.self, from: data), record.version <= Self.currentVersion
        else { return nil }
        return record
    }

    /// Stores `summary` as the current one; the stored current becomes the previous one. Without a stored summary
    /// for this root (an index from before this file existed), `fallbackPrevious` provides it (e.g. the summary of
    /// the saved index), only if it has the same root.
    @discardableResult
    public func record(_ summary: ScanSummary, fallbackPrevious: () -> ScanSummary?) throws -> Record {
        try lock.withLock { _ in
            var previous = read()?.current
            if previous?.root != summary.root { previous = nil }
            if previous == nil, let fallback = fallbackPrevious(), fallback.root == summary.root { previous = fallback }
            let record = Record(version: Self.currentVersion, current: summary, previous: previous)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoder.encode(record).write(to: url, options: .atomic)
            return record
        }
    }

    /// What changed in the last scan; `nil` without two comparable summaries.
    public func changes(minimumBytes: Int64 = ScanChanges.defaultMinimumBytes,
                        limit: Int = ScanChanges.defaultLimit) -> ScanChanges? {
        guard let record = load(), let previous = record.previous else { return nil }
        return ScanChanges.compute(previous: previous, current: record.current, minimumBytes: minimumBytes, limit: limit)
    }
}
