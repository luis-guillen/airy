import Foundation
import Synchronization

public enum ContentKind: String, Codable, CaseIterable, Sendable {
    case video, images, apps, code, caches, aiModels, containers, documents, system, other

    /// Position in `allCases` (the index into `kindBytes`), without searching `allCases`.
    var index: Int {
        switch self {
        case .video: 0
        case .images: 1
        case .apps: 2
        case .code: 3
        case .caches: 4
        case .aiModels: 5
        case .containers: 6
        case .documents: 7
        case .system: 8
        case .other: 9
        }
    }

    /// `allCases.count`.
    static let count = allCases.count

    public var title: String {
        switch self {
        case .video: String(localized: "Video", bundle: .airyCore)
        case .images: String(localized: "Images", bundle: .airyCore)
        case .apps: String(localized: "Apps", bundle: .airyCore)
        case .code: String(localized: "Code and projects", bundle: .airyCore)
        case .caches: String(localized: "Caches", bundle: .airyCore)
        case .aiModels: String(localized: "AI models", bundle: .airyCore)
        case .containers: String(localized: "Containers and VMs", bundle: .airyCore)
        case .documents: String(localized: "Documents", bundle: .airyCore)
        case .system: String(localized: "System", bundle: .airyCore)
        case .other: String(localized: "Other", bundle: .airyCore)
        }
    }
}

public enum Risk: Int, Codable, Comparable, Sendable {
    case safe = 0, yourCall = 1, doNotTouch = 2

    public var title: String {
        switch self {
        case .safe: String(localized: "Safe to delete", bundle: .airyCore)
        case .yourCall: String(localized: "Up to you", bundle: .airyCore)
        case .doNotTouch: String(localized: "Do not touch", bundle: .airyCore)
        }
    }

    /// Short traffic-light label.
    public var label: String {
        switch self {
        case .safe: String(localized: "Safe to remove", bundle: .airyCore)
        case .yourCall: String(localized: "Your call", bundle: .airyCore)
        case .doNotTouch: String(localized: "Don't delete", bundle: .airyCore)
        }
    }

    public static func < (a: Risk, b: Risk) -> Bool { a.rawValue < b.rawValue }

    /// Returns the stricter of the two risks.
    public static func strictest(_ a: Risk, _ b: Risk) -> Risk { max(a, b) }
}

/// A node of the scanned file tree. It is built on a single thread and then published,
/// effectively immutable from then on, hence `@unchecked Sendable`.
public final class FileNode: @unchecked Sendable, Identifiable {
    /// Relaxed atomic: ids only need to be unique, and the scan threads create nodes at the same time.
    private static let nextID = Atomic<Int>(0)

    // Declaration order is the memory layout: the one-byte fields go right after `lastModified`'s tag byte
    // instead of each padding out to eight bytes (176 bytes per node instead of 192).
    public let id: Int
    public var name: String
    public weak var parent: FileNode?
    public var children: [FileNode]
    public var allocatedSize: Int64
    /// Bytes per kind; index = position in `ContentKind.allCases`.
    public var kindBytes: KindBytes
    public var descendantCount: Int
    /// > 0 if the node is the "Other (N items)" aggregate.
    public var aggregatedCount: Int
    public var lastModified: Date?
    public var isDirectory: Bool
    public var kind: ContentKind

    public init(
        name: String,
        isDirectory: Bool,
        allocatedSize: Int64 = 0,
        lastModified: Date? = nil,
        kind: ContentKind = .other,
        kindBytes: KindBytes = KindBytes(),
        children: [FileNode] = [],
        descendantCount: Int = 0,
        aggregatedCount: Int = 0
    ) {
        self.id = Self.nextID.wrappingAdd(1, ordering: .relaxed).newValue
        self.name = name
        self.isDirectory = isDirectory
        self.allocatedSize = allocatedSize
        self.lastModified = lastModified
        self.kind = kind
        self.kindBytes = kindBytes
        self.children = children
        self.descendantCount = descendantCount
        self.aggregatedCount = aggregatedCount
        for child in children { child.parent = self }
    }

    /// The same with the breakdown as an array (missing values are 0, extra ones are ignored).
    public convenience init(
        name: String,
        isDirectory: Bool,
        allocatedSize: Int64 = 0,
        lastModified: Date? = nil,
        kind: ContentKind = .other,
        kindBytes: [Int64]?,
        children: [FileNode] = [],
        descendantCount: Int = 0,
        aggregatedCount: Int = 0
    ) {
        self.init(name: name, isDirectory: isDirectory, allocatedSize: allocatedSize, lastModified: lastModified,
                  kind: kind, kindBytes: kindBytes.map { KindBytes($0) } ?? KindBytes(), children: children,
                  descendantCount: descendantCount, aggregatedCount: aggregatedCount)
    }

    /// Full path, walking up through `parent`; the "/" root does not double the slash.
    public var path: String {
        var parts: [String] = []
        var node: FileNode? = self
        while let current = node {
            parts.append(current.name)
            node = current.parent
        }
        var joined = parts.reversed().joined(separator: "/")
        while joined.hasPrefix("//") { joined.removeFirst() }
        return joined
    }

    /// Kind with the most bytes in `kindBytes`; without a breakdown, the node's own `kind`.
    public var dominantKind: ContentKind {
        guard let maxBytes = kindBytes.max(), maxBytes > 0,
              let index = kindBytes.firstIndex(of: maxBytes) else { return kind }
        return ContentKind.allCases[index]
    }

    /// Removes it from the tree (e.g. after moving it to the Trash) and subtracts its size, its per-kind
    /// breakdown and its descendants from every ancestor. Does nothing without a parent.
    /// Like the rest of the tree, it must only be called from the owning thread (the main one).
    public func removeFromParent() {
        guard let parent else { return }
        parent.children.removeAll { $0 === self }
        self.parent = nil
        let removedDescendants = descendantCount + 1
        var cursor: FileNode? = parent
        while let node = cursor {
            node.allocatedSize = max(node.allocatedSize - allocatedSize, 0)
            for index in node.kindBytes.indices where index < kindBytes.count {
                node.kindBytes[index] = max(node.kindBytes[index] - kindBytes[index], 0)
            }
            node.descendantCount = max(node.descendantCount - removedDescendants, 0)
            cursor = node.parent
        }
    }

    /// Replaces what was known about the node with a freshly measured size (e.g. after cleaning a
    /// cache with its official command, which leaves the folder with less inside). Since we don't know which
    /// children remain, they are removed (the next scan shows them again) and the whole size goes to the
    /// dominant kind. Fixes size, breakdown and descendants of every ancestor.
    /// Only from the thread that owns the tree (the main one, through `TreeGate.mutate`).
    public func replaceContents(measuredSize: Int64) {
        let newSize = max(measuredSize, 0)
        guard newSize != allocatedSize else { return }
        let oldKindBytes = kindBytes
        let oldSize = allocatedSize
        let oldDescendants = descendantCount
        let newKindBytes = KindBytes(dominantKind, newSize)
        for child in children { child.parent = nil }
        children = []
        descendantCount = 0
        allocatedSize = newSize
        kindBytes = newKindBytes
        var cursor = parent
        while let node = cursor {
            node.allocatedSize = max(node.allocatedSize - oldSize + newSize, 0)
            for index in node.kindBytes.indices {
                let before = index < oldKindBytes.count ? oldKindBytes[index] : 0
                node.kindBytes[index] = max(node.kindBytes[index] - before + newKindBytes[index], 0)
            }
            node.descendantCount = max(node.descendantCount - oldDescendants, 0)
            cursor = node.parent
        }
    }
}
