import Foundation

/// The map's zoom stack. `stack[0]` is the scanned root and `current` the visible level.
/// The breadcrumb starts with `rootTitle` (the volume name, e.g. "Macintosh HD")
/// because `root.name` is the full scanned path ("/") or "" when there are several roots.
public struct MapNavigation: Sendable {
    public private(set) var stack: [FileNode]
    public var rootTitle: String

    /// No scan yet: there is no visible level.
    public init(rootTitle: String = "Macintosh HD") {
        self.stack = []
        self.rootTitle = rootTitle
    }

    public init(root: FileNode, rootTitle: String = "Macintosh HD") {
        self.stack = [root]
        self.rootTitle = rootTitle
    }

    public var current: FileNode? { stack.last }
    public var root: FileNode? { stack.first }
    public var canZoomOut: Bool { stack.count > 1 }

    public var breadcrumb: [String] {
        [rootTitle] + stack.dropFirst().map(\.name)
    }

    /// Enters `node` if it is a folder descending from the current level; if it is several
    /// levels down, it also pushes the intermediate ones so that "back" goes up one at a time.
    /// Files, "Other" aggregates and unrelated nodes are ignored.
    public mutating func zoom(into node: FileNode) {
        guard let current, node !== current, node.isDirectory, node.aggregatedCount == 0 else { return }
        var chain: [FileNode] = []
        var cursor: FileNode? = node
        while let step = cursor, step !== current {
            chain.append(step)
            cursor = step.parent
        }
        guard cursor === current else { return }
        stack.append(contentsOf: chain.reversed())
    }

    /// The same path on a new tree (e.g. when a rescan finishes): goes down by name from
    /// `newRoot` to the deepest level that still exists as a folder. Keeps `rootTitle`.
    public func restoring(in newRoot: FileNode) -> MapNavigation {
        var restored = MapNavigation(root: newRoot, rootTitle: rootTitle)
        var cursor = newRoot
        for name in stack.dropFirst().map(\.name) {
            guard let next = cursor.children.first(where: {
                $0.name == name && $0.isDirectory && $0.aggregatedCount == 0
            }) else { break }
            restored.stack.append(next)
            cursor = next
        }
        return restored
    }

    /// Shows `path` from the root: goes down by name to the deepest folder that exists in the
    /// scan (a file leaves the map on its folder). `true` only if the path is a folder and it
    /// got all the way there; without a scan or with a path outside the root nothing changes and it returns `false`.
    @discardableResult
    public mutating func reveal(path: String) -> Bool {
        guard let root else { return false }
        let rootPath = root.path
        let rest: Substring
        if rootPath == "/" {
            rest = Substring(path)
        } else if path == rootPath || path.hasPrefix(rootPath + "/") {
            rest = path.dropFirst(rootPath.count)
        } else {
            return false
        }
        var chain: [FileNode] = [root]
        var reachedEnd = true
        for name in rest.split(separator: "/") {
            guard let next = chain.last?.children.first(where: {
                $0.name == name && $0.isDirectory && $0.aggregatedCount == 0
            }) else {
                reachedEnd = false
                break
            }
            chain.append(next)
        }
        stack = chain
        return reachedEnd
    }

    /// Goes up one level; at the root it does nothing.
    public mutating func zoomOut() {
        guard stack.count > 1 else { return }
        stack.removeLast()
    }

    /// Jumps to item `index` of the breadcrumb (0 = root). Out of range it does nothing.
    public mutating func jump(to index: Int) {
        guard index >= 0, index < stack.count else { return }
        stack.removeSubrange((index + 1)...)
    }
}
