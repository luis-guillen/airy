import Foundation

public struct FileTypeSlice: Sendable, Equatable, Identifiable {
    public let kind: ContentKind, bytes: Int64, fraction: Double
    public var id: ContentKind { kind }
}

/// Space per file type, read from the per-kind totals of the already saved index (it does not walk the disk).
public struct FileTypeBreakdown: Sendable, Equatable {
    public let slices: [FileTypeSlice]
    public let total: Int64

    public init(root: FileNode) {
        let pairs = zip(ContentKind.allCases, root.kindBytes).filter { $0.1 > 0 }
        let total = pairs.reduce(Int64(0)) { $0 + $1.1 }
        self.total = total
        self.slices = pairs.sorted { $0.1 > $1.1 }
            .map { FileTypeSlice(kind: $0.0, bytes: $0.1, fraction: Double($0.1) / Double(total)) }
    }

    /// Items of one kind, largest first: files with `kind == k` and `.app` bundles (without going inside) for `.apps`;
    /// never "Other" aggregates. `hiddenBytes` = bytes of the kind − sum of those listed (small or past the limit).
    public static func items(of kind: ContentKind, in root: FileNode, limit: Int = 300) -> (items: [FileNode], hiddenBytes: Int64) {
        guard limit > 0 else { return ([], max(0, root.kindBytes[kind.index])) }
        var found: [FileNode] = []
        var stack = [root]
        while let node = stack.popLast() {
            // Cancellable tree reader: if it is cancelled, it stops walking.
            if Task.isCancelled { return ([], 0) }
            if node.aggregatedCount > 0 { continue }
            // A repository (`.git`) or a build folder is never offered whole nor from the inside.
            if node.isDirectory, Self.skippedFolders.contains(node.name.lowercased()) { continue }
            if node.isDirectory {
                if (kind == .apps && node.kind == .apps && node.name.hasSuffix(".app"))
                    || Self.hasAttributedBytes(node, of: kind) {
                    found.append(node)
                } else {
                    stack.append(contentsOf: node.children)
                }
            } else if node.kind == kind {
                found.append(node)
            }
        }
        found.sort { $0.allocatedSize != $1.allocatedSize ? $0.allocatedSize > $1.allocatedSize : $0.name < $1.name }
        let shown = Array(found.prefix(max(0, limit)))
        let listed = shown.reduce(Int64(0)) { $0 + $1.kindBytes[kind.index] }
        let all = root.kindBytes[kind.index]
        return (shown, max(0, all - listed))
    }

    static let skippedFolders: Set<String> = [".git", ".build"]

    /// Folder whose kind the scanner attributed to its unrecognized bytes (Caches, bundles, system): bytes of `kind`
    /// that belong to no child. The whole folder is listed, without going inside.
    private static func hasAttributedBytes(_ node: FileNode, of kind: ContentKind) -> Bool {
        guard kind != .other, node.kind == kind else { return false }
        let inChildren = node.children.reduce(Int64(0)) { $0 + $1.kindBytes[kind.index] }
        return node.kindBytes[kind.index] > inChildren
    }
}
