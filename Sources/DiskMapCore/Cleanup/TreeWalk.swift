import Foundation

/// Summary of a bounded walk through a folder (or a file).
public struct TreeSummary: Sendable, Equatable {
    /// Allocated size (`st_blocks * 512`), hard links only once.
    public var bytes: Int64
    /// The most recent `mtime` of what was walked (the root included), or `nil` if there is none.
    public var latestModification: Date?
    /// Root-relative paths of the entries that match `watch` (max `TreeWalk.maxWatched`).
    public var watched: [String]

    public init(bytes: Int64, latestModification: Date?, watched: [String]) {
        self.bytes = bytes; self.latestModification = latestModification; self.watched = watched
    }
}

/// Synchronous disk walk with a time limit: `lstat` (never follows links), hard links counted once and the
/// clock checked at each entry. It creates no tasks. It stops (returns `nil`) if the task is cancelled, and does not leave
/// the task's scope (`DiskScope.current`).
public enum TreeWalk {
    public static let maxWatched = 10

    public enum Kind: Sendable, Equatable {
        /// `summarize`: `lstat` of each entry (size and dates).
        case full
        /// `watchedNames`: names only (`readdir`), without `lstat`.
        case names
    }

    /// Tests only: called at the start of each walk (root path and kind).
    @TaskLocal public static var observer: (@Sendable (String, Kind) -> Void)?

    /// How many entries between checks for task cancellation.
    static let cancellationStride = 128

    /// `nil` if `budget` runs out or the root cannot be read. `prune(name, relativePath)` ⇒ do not enter (neither
    /// its size nor its date is counted). A root that is a file (or link) returns its size and its `mtime`.
    public static func summarize(_ root: String, budget: Duration,
                                 prune: (String, String) -> Bool = { _, _ in false },
                                 watch: (String) -> Bool = { _ in false }) -> TreeSummary? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: budget)
        guard clock.now < deadline, !Task.isCancelled, DiskScope.allowsWalk(root) else { return nil }
        var info = stat()
        guard lstat(root, &info) == 0 else { return nil }
        observer?(root, .full)
        var walker = Walker(deadline: deadline)
        walker.visit(info)
        if (info.st_mode & S_IFMT) == S_IFDIR {
            guard walker.walk(root, relative: "", isRoot: true, prune: prune, watch: watch) else { return nil }
        }
        return TreeSummary(bytes: walker.bytes, latestModification: walker.latest.map {
            Date(timeIntervalSince1970: TimeInterval($0.tv_sec) + TimeInterval($0.tv_nsec) / 1e9)
        }, watched: walker.watched)
    }

    /// The relative paths of the entries that match `watch` (max `maxWatched`), with the same walk as
    /// `summarize` (without following links) but only with `readdir`: for when the size already comes from the index.
    /// `nil` if `budget` runs out, it is cancelled or the root cannot be read.
    public static func watchedNames(_ root: String, budget: Duration, watch: (String) -> Bool) -> [String]? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: budget)
        guard clock.now < deadline, !Task.isCancelled, DiskScope.allowsWalk(root) else { return nil }
        var info = stat()
        guard lstat(root, &info) == 0 else { return nil }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { return [] }
        observer?(root, .names)
        var watched: [String] = []
        var visited = 0
        /// `false` if the time limit ran out, it was cancelled or the root could not be opened.
        func walk(_ path: String, relative: String, isRoot: Bool) -> Bool {
            guard let dir = opendir(path) else { return !isRoot }
            defer { closedir(dir) }
            while let entry = readdir(dir) {
                guard clock.now < deadline else { return false }
                visited += 1
                if visited % cancellationStride == 0, Task.isCancelled { return false }
                let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                    String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
                }
                if name == "." || name == ".." { continue }
                let rel = relative.isEmpty ? name : relative + "/" + name
                let child = path == "/" ? "/" + name : path + "/" + name
                var type = Int32(entry.pointee.d_type)
                if type == DT_UNKNOWN {
                    var childInfo = stat()
                    guard lstat(child, &childInfo) == 0 else { continue }
                    type = (childInfo.st_mode & S_IFMT) == S_IFDIR ? DT_DIR : DT_REG
                }
                if watched.count < maxWatched, watch(name) { watched.append(rel) }
                if type == DT_DIR {
                    guard walk(child, relative: rel, isRoot: false) else { return false }
                }
            }
            return true
        }
        return walk(root, relative: "", isRoot: true) ? watched : nil
    }

    private struct HardLinkKey: Hashable { let device: dev_t; let inode: ino_t }

    private struct Walker {
        let deadline: ContinuousClock.Instant
        var bytes: Int64 = 0
        var latest: timespec?
        var watched: [String] = []
        var seen = Set<HardLinkKey>()
        var visited = 0

        init(deadline: ContinuousClock.Instant) { self.deadline = deadline }

        mutating func visit(_ info: stat) {
            let type = info.st_mode & S_IFMT
            if type == S_IFREG, info.st_nlink > 1 {
                if seen.insert(HardLinkKey(device: info.st_dev, inode: info.st_ino)).inserted {
                    bytes += Int64(info.st_blocks) * 512
                }
            } else {
                bytes += Int64(info.st_blocks) * 512
            }
            let time = info.st_mtimespec
            if let current = latest {
                if time.tv_sec > current.tv_sec || (time.tv_sec == current.tv_sec && time.tv_nsec > current.tv_nsec) {
                    latest = time
                }
            } else {
                latest = time
            }
        }

        /// `false` if the time limit ran out or the root could not be opened.
        mutating func walk(_ path: String, relative: String, isRoot: Bool,
                           prune: (String, String) -> Bool, watch: (String) -> Bool) -> Bool {
            guard let dir = opendir(path) else { return !isRoot }
            defer { closedir(dir) }
            let clock = ContinuousClock()
            while let entry = readdir(dir) {
                guard clock.now < deadline else { return false }
                visited += 1
                if visited % TreeWalk.cancellationStride == 0, Task.isCancelled { return false }
                let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                    String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
                }
                if name == "." || name == ".." { continue }
                let rel = relative.isEmpty ? name : relative + "/" + name
                if prune(name, rel) { continue }
                let child = path == "/" ? "/" + name : path + "/" + name
                var info = stat()
                guard lstat(child, &info) == 0 else { continue }
                visit(info)
                if watched.count < TreeWalk.maxWatched, watch(name) { watched.append(rel) }
                if (info.st_mode & S_IFMT) == S_IFDIR {
                    guard walk(child, relative: rel, isRoot: false, prune: prune, watch: watch) else { return false }
                }
            }
            return true
        }
    }
}
