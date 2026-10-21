import Foundation

/// Brings the scanned tree up to date after an action (cleanup, Trash) without rescanning everything:
/// only the touched paths are measured again (off the main thread) and then applied.
public enum ScanTreeRefresh {
    public struct Measurement: Sendable, Equatable {
        public let path: String
        /// Allocated space measured now; `nil` if the path no longer exists.
        public let bytes: Int64?

        public init(path: String, bytes: Int64?) {
            self.path = path
            self.bytes = bytes
        }
    }

    /// Measures each path with `lstat` + `AllocatedSize` (disk I/O: off the main thread).
    public static func measure(_ paths: [String]) -> [Measurement] {
        paths.map { path in
            var info = stat()
            guard lstat(path, &info) == 0 else { return Measurement(path: path, bytes: nil) }
            return Measurement(path: path, bytes: AllocatedSize.of(path) ?? 0)
        }
    }

    /// Applies the measurements: removes the nodes of what no longer exists and leaves the rest with their new
    /// size. Returns `true` if anything changed. Only from the thread that owns the tree (`TreeGate.mutate`),
    /// or on a tree that has not been published yet.
    @discardableResult
    public static func apply(_ measurements: [Measurement], to root: FileNode) -> Bool {
        var changed = false
        // From deepest to highest: a folder measured after its child replaces it entirely.
        for measurement in measurements.sorted(by: { $0.path.count > $1.path.count }) {
            guard let node = CleanupScanner.node(at: measurement.path, in: root), node !== root else { continue }
            if let bytes = measurement.bytes {
                if bytes != node.allocatedSize {
                    node.replaceContents(measuredSize: bytes)
                    changed = true
                }
            } else if node.parent != nil {
                node.removeFromParent()
                changed = true
            }
        }
        return changed
    }
}
