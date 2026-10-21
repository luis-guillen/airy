import Foundation
import Synchronization

public struct ScanOptions: Sendable {
    public static let defaultExcludedPrefixes = [
        "/System/Volumes", "/dev", "/Volumes", "/private/var/vm", "/.Spotlight-V100", "/.fseventsd",
    ]

    public var roots: [URL]
    /// Paths that are not walked. If a root lies inside a prefix, that prefix does not apply to it.
    public var excludedPrefixes: [String]
    /// Children smaller than this are merged into an "Other" node when each folder is closed.
    public var pruneThreshold: Int64
    /// Folders the user excluded in Settings › Scanning. Unlike `excludedPrefixes` they always apply, even to a
    /// root inside them, and they are never opened: each one shows up as an empty folder, the way an unreadable
    /// one does (only its own size), but it is not reported as unreadable. Matched case-insensitively, also
    /// through the root's real path (`/var` ⇄ `/private/var`).
    public var userExcluded: [String]

    public init(
        roots: [URL],
        excludedPrefixes: [String] = ScanOptions.defaultExcludedPrefixes,
        pruneThreshold: Int64 = 1_048_576,
        userExcluded: [String] = []
    ) {
        self.roots = roots
        self.excludedPrefixes = excludedPrefixes
        self.pruneThreshold = pruneThreshold
        self.userExcluded = userExcluded
    }
}

public struct ScanProgress: Sendable {
    public var filesScanned: Int
    public var bytesScanned: Int64
    public var currentPath: String

    public init(filesScanned: Int, bytesScanned: Int64, currentPath: String) {
        self.filesScanned = filesScanned
        self.bytesScanned = bytesScanned
        self.currentPath = currentPath
    }
}

public struct ScanResult: Sendable {
    public let root: FileNode
    public let inaccessible: [String]
    public let duration: TimeInterval
    /// When the full scan that produced the tree finished. Saving the tree again after
    /// a cleanup or the Trash does not change it. `nil`: unknown (an index from before it was saved).
    public let scannedAt: Date?

    public init(root: FileNode, inaccessible: [String], duration: TimeInterval, scannedAt: Date? = nil) {
        self.root = root
        self.inaccessible = inaccessible
        self.duration = duration
        self.scannedAt = scannedAt
    }
}

/// Parallel scanner: `opendir/readdir` + `fstatat` without following links, allocated size
/// (`st_blocks * 512`), hard links counted once and without crossing into other volumes.
///
/// The work is done by `budget.workers` dedicated threads with the budget's QoS (never the whole cooperative
/// pool): a shared stack of folders to read, and each folder is closed when its last subfolder
/// arrives. That way a scan cannot take more cores than it is given.
public final class DiskScanner: Sendable {
    public let options: ScanOptions
    public let budget: ScanBudget

    public init(options: ScanOptions, budget: ScanBudget) {
        self.options = options
        self.budget = budget
    }

    /// The budget is computed now from the Mac's state (Low Power Mode, temperature).
    public convenience init(options: ScanOptions, intensity: ScanIntensity = .normal) {
        self.init(options: options, budget: .current(intensity))
    }

    /// Cancellable with `Task.cancel()` (throws `CancellationError`). `progress` is called at most
    /// every 100 ms, from the scanner's threads.
    public func scan(progress: @escaping @Sendable (ScanProgress) -> Void) async throws -> ScanResult {
        let clock = ContinuousClock()
        let start = clock.now
        let shared = SharedScanState(start: start, report: progress)
        let rootPaths = Self.uniqueNormalized(options.roots.map(\.path))
        let excluded = Set(options.excludedPrefixes.map(Self.normalize))

        var nodes: [FileNode] = []
        for rootPath in rootPaths {
            let userExcluded = Self.userExcludedKeys(options.userExcluded, root: rootPath)
            // A root the user excluded (or one inside an excluded folder) is never opened.
            let rootForms = Set([rootPath, Self.realPath(rootPath) ?? rootPath].map { $0.lowercased() })
            if userExcluded.contains(where: { key in rootForms.contains { Self.path($0, isInside: key) } }) {
                nodes.append(FileNode(name: rootPath, isDirectory: true))
                continue
            }
            var info = stat()
            guard stat(rootPath, &info) == 0 else {
                shared.markInaccessible(rootPath)
                nodes.append(FileNode(name: rootPath, isDirectory: true))
                continue
            }
            guard (info.st_mode & S_IFMT) == S_IFDIR else {
                nodes.append(makeFile(name: rootPath, directory: "", info: info, shared: shared))
                continue
            }
            let context = ScanContext(
                device: info.st_dev,
                excluded: excluded.filter { !Self.path(rootPath, isInside: $0) },
                otherRoots: Set(rootPaths).subtracting([rootPath]),
                userExcluded: userExcluded,
                shared: shared
            )
            let entry = DirectoryEntry(
                path: rootPath, name: rootPath,
                ownSize: Int64(info.st_blocks) * 512, modified: Self.date(info.st_mtimespec))
            nodes.append(await scanTree(entry, context))
            try Task.checkCancellation()
        }
        try Task.checkCancellation()

        let root = nodes.count == 1 ? nodes[0] : Self.combine(nodes)
        let elapsed = clock.now - start
        let duration = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return ScanResult(root: root, inaccessible: shared.inaccessibleSorted(), duration: duration, scannedAt: Date())
    }

    // MARK: - Walk

    /// Walks a root with the budget's threads and returns its closed node. Without blocking
    /// the cooperative pool: the task waits on a continuation.
    private func scanTree(_ root: DirectoryEntry, _ context: ScanContext) async -> FileNode {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<FileNode, Never>) in
                let queue = WorkQueue { continuation.resume(returning: $0) }
                queue.push([Job(entry: root, parent: nil)])
                for index in 0..<max(1, budget.workers) {
                    let thread = Thread { [self] in
                        while let job = queue.next() { process(job, context, queue) }
                    }
                    thread.name = "Airy scan \(index)"
                    thread.qualityOfService = budget.qos
                    thread.start()
                }
            }
        } onCancel: {
            context.shared.cancel()
        }
    }

    /// Reads a folder: if it has no subfolders it is closed right away; otherwise it pushes its subfolders onto the stack.
    private func process(_ job: Job, _ context: ScanContext, _ queue: WorkQueue) {
        // Cancelled: what is left is closed empty without touching the disk (the result is discarded).
        guard !context.shared.isCancelled else {
            deliver(close(job.entry, children: []), to: job.parent, queue)
            return
        }
        let (files, subdirectories) = read(job.entry, context)
        guard !subdirectories.isEmpty else {
            deliver(close(job.entry, children: files), to: job.parent, queue)
            return
        }
        let pending = PendingDirectory(entry: job.entry, children: files,
                                       remaining: subdirectories.count, parent: job.parent)
        queue.push(subdirectories.map { Job(entry: $0, parent: pending) })
    }

    /// Hands a closed node to its parent; the last child to arrive closes the parent, and so on
    /// upwards. Closing the root ends the walk.
    private func deliver(_ node: FileNode, to parent: PendingDirectory?, _ queue: WorkQueue) {
        var node = node
        var parent = parent
        while let current = parent {
            guard let children = queue.attach(node, to: current) else { return }
            node = close(current.entry, children: children)
            parent = current.parent
        }
        queue.finish(node)
    }

    private func read(_ directory: DirectoryEntry, _ context: ScanContext) -> ([FileNode], [DirectoryEntry]) {
        guard let handle = opendir(directory.path) else {
            context.shared.markInaccessible(directory.path)
            return ([], [])
        }

        var children: [FileNode] = []
        var subdirectories: [DirectoryEntry] = []
        var fileBytes: Int64 = 0
        let fd = dirfd(handle)
        while let entry = readdir(handle) {
            let found: (String, stat)? = withUnsafePointer(to: &entry.pointee.d_name) { tuple in
                tuple.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: tuple.pointee)) { cName in
                    let name = String(cString: cName)
                    guard name != ".", name != ".." else { return nil }
                    var info = stat()
                    // If it disappears between readdir and fstatat, it is skipped.
                    guard fstatat(fd, cName, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
                    return (name, info)
                }
            }
            guard let (name, info) = found else { continue }
            let childPath = directory.path == "/" ? "/" + name : directory.path + "/" + name
            if context.excluded.contains(childPath) || context.otherRoots.contains(childPath) { continue }

            if (info.st_mode & S_IFMT) == S_IFDIR {
                guard info.st_dev == context.device else { continue }
                let entry = DirectoryEntry(
                    path: childPath, name: name,
                    ownSize: Int64(info.st_blocks) * 512, modified: Self.date(info.st_mtimespec))
                // Excluded by the user: closed empty without opening it, like an unreadable folder.
                if !context.userExcluded.isEmpty, context.userExcluded.contains(childPath.lowercased()) {
                    children.append(close(entry, children: []))
                    continue
                }
                subdirectories.append(entry)
            } else {
                let file = makeFile(name: name, directory: directory.path, info: info, shared: context.shared)
                fileBytes += file.allocatedSize
                children.append(file)
            }
        }
        closedir(handle)
        context.shared.record(files: children.count, bytes: fileBytes, path: directory.path)
        return (children, subdirectories)
    }

    private func makeFile(name: String, directory: String, info: stat, shared: SharedScanState) -> FileNode {
        var size = Int64(info.st_blocks) * 512
        if info.st_nlink > 1, (info.st_mode & S_IFMT) == S_IFREG,
           !shared.claimHardLink(device: info.st_dev, inode: info.st_ino) {
            size = 0
        }
        let kind = FileKindClassifier.kind(forFileNamed: name, inDirectoryPath: directory)
        var kindBytes = Array(repeating: Int64(0), count: ContentKind.allCases.count)
        kindBytes[kind.index] = size
        return FileNode(
            name: name, isDirectory: false, allocatedSize: size,
            lastModified: Self.date(info.st_mtimespec), kind: kind, kindBytes: kindBytes)
    }

    /// Closes a folder: adds up sizes and kinds, decides its `kind` and groups the small children.
    private func close(_ directory: DirectoryEntry, children: [FileNode]) -> FileNode {
        let folderKind = FileKindClassifier.kind(forDirectoryPath: directory.path)
        var kindBytes = Array(repeating: Int64(0), count: ContentKind.allCases.count)
        kindBytes[(folderKind ?? .other).index] = directory.ownSize
        var descendants = 0
        for child in children {
            for index in kindBytes.indices { kindBytes[index] += child.kindBytes[index] }
            descendants += 1 + child.descendantCount
        }
        // What is not recognized by extension takes the folder's meaning (binaries of an .app, Caches blobs…).
        if let folderKind, folderKind != .other {
            kindBytes[folderKind.index] += kindBytes[ContentKind.other.index]
            kindBytes[ContentKind.other.index] = 0
        }

        let node = FileNode(
            name: directory.name, isDirectory: true,
            allocatedSize: kindBytes.reduce(0, +), lastModified: directory.modified,
            kindBytes: kindBytes, children: Self.pruned(children, below: options.pruneThreshold),
            descendantCount: descendants)
        node.kind = folderKind ?? node.dominantKind
        return node
    }

    private static func pruned(_ children: [FileNode], below threshold: Int64) -> [FileNode] {
        var kept: [FileNode] = []
        var small: [FileNode] = []
        for child in children {
            if child.allocatedSize < threshold { small.append(child) } else { kept.append(child) }
        }
        if small.count >= 2 {
            var kindBytes = Array(repeating: Int64(0), count: ContentKind.allCases.count)
            var hidden = 0
            for child in small {
                for index in kindBytes.indices { kindBytes[index] += child.kindBytes[index] }
                hidden += child.descendantCount
            }
            let aggregate = FileNode(
                name: "Other", isDirectory: false, allocatedSize: kindBytes.reduce(0, +),
                lastModified: small.compactMap(\.lastModified).max(),
                kindBytes: kindBytes, descendantCount: hidden, aggregatedCount: small.count)
            aggregate.kind = aggregate.dominantKind
            kept.append(aggregate)
        } else {
            kept.append(contentsOf: small)
        }
        return kept.sorted { $0.allocatedSize > $1.allocatedSize }
    }

    /// Several roots hang from an unnamed node so that each one's `path` stays absolute.
    private static func combine(_ roots: [FileNode]) -> FileNode {
        var kindBytes = Array(repeating: Int64(0), count: ContentKind.allCases.count)
        for root in roots {
            for index in kindBytes.indices { kindBytes[index] += root.kindBytes[index] }
        }
        let node = FileNode(
            name: "", isDirectory: true, allocatedSize: kindBytes.reduce(0, +), kindBytes: kindBytes,
            children: roots.sorted { $0.allocatedSize > $1.allocatedSize },
            descendantCount: roots.reduce(0) { $0 + 1 + $1.descendantCount })
        node.kind = node.dominantKind
        return node
    }

    // MARK: - Utilities

    private static func normalize(_ path: String) -> String {
        // No `standardizingPath`: it would strip `/private` and the exclusions would stop matching.
        var components: [Substring] = []
        for component in path.split(separator: "/") {
            switch component {
            case ".": continue
            case "..": _ = components.popLast()
            default: components.append(component)
            }
        }
        return "/" + components.joined(separator: "/")
    }

    /// Lowercased keys of the user's excluded folders for one root: each normalized path, its real path and,
    /// when the root reaches the disk through a link (`/var/…` ⇄ `/private/var/…`), the same folder spelled from
    /// the root, so that the per-entry check stays a set lookup. `/` and relative paths are ignored.
    static func userExcludedKeys(_ paths: [String], root: String) -> Set<String> {
        guard !paths.isEmpty else { return [] }
        let rootReal = realPath(root) ?? root
        var keys: Set<String> = []
        for raw in paths where raw.hasPrefix("/") {
            let normal = normalize(raw)
            guard normal != "/" else { continue }
            for form in Set([normal, realPath(normal) ?? normal]) where form != "/" {
                keys.insert(form.lowercased())
                if rootReal != root, path(form, isInside: rootReal), form != rootReal {
                    keys.insert((root + form.dropFirst(rootReal.count)).lowercased())
                }
            }
        }
        return keys
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func uniqueNormalized(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        return paths.map(normalize).filter { seen.insert($0).inserted }
    }

    private static func path(_ path: String, isInside prefix: String) -> Bool {
        prefix == "/" || path == prefix || path.hasPrefix(prefix + "/")
    }

    private static func date(_ time: timespec) -> Date {
        Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_nsec) / 1e9)
    }
}

private struct DirectoryEntry: Sendable {
    let path: String
    let name: String
    let ownSize: Int64
    let modified: Date?
}

/// Immutable configuration of one specific root.
private struct ScanContext: Sendable {
    let device: dev_t
    let excluded: Set<String>
    let otherRoots: Set<String>
    /// Lowercased paths of the folders the user excluded (`DiskScanner.userExcludedKeys`).
    let userExcluded: Set<String>
    let shared: SharedScanState
}

/// A read folder waiting for its subfolders. Its mutable fields are only touched under the
/// `WorkQueue` lock (`attach`).
private final class PendingDirectory: @unchecked Sendable {
    let entry: DirectoryEntry
    let parent: PendingDirectory?
    var children: [FileNode]
    var remaining: Int

    init(entry: DirectoryEntry, children: [FileNode], remaining: Int, parent: PendingDirectory?) {
        self.entry = entry
        self.children = children
        self.remaining = remaining
        self.parent = parent
    }
}

private struct Job: Sendable {
    let entry: DirectoryEntry
    let parent: PendingDirectory?
}

/// Stack of folders to read shared by the scanner's threads (LIFO: the walk goes depth-first
/// and half-done folders do not pile up). All its state is under `condition`.
private final class WorkQueue: @unchecked Sendable {
    private let condition = NSCondition()
    private var jobs: [Job] = []
    private var finished = false
    private let onFinish: @Sendable (FileNode) -> Void

    init(onFinish: @escaping @Sendable (FileNode) -> Void) {
        self.onFinish = onFinish
    }

    func push(_ new: [Job]) {
        condition.lock()
        jobs.append(contentsOf: new)
        if new.count == 1 { condition.signal() } else { condition.broadcast() }
        condition.unlock()
    }

    /// Waits for work; `nil` once the root has been closed (the thread ends).
    func next() -> Job? {
        condition.lock()
        defer { condition.unlock() }
        while jobs.isEmpty, !finished { condition.wait() }
        // The root is only closed once everything has been handed over: with `finished` the stack is empty.
        return jobs.popLast()
    }

    /// Adds a closed child; returns the parent's children if it was the last one missing.
    func attach(_ node: FileNode, to parent: PendingDirectory) -> [FileNode]? {
        condition.lock()
        defer { condition.unlock() }
        parent.children.append(node)
        parent.remaining -= 1
        guard parent.remaining == 0 else { return nil }
        let children = parent.children
        parent.children = []
        return children
    }

    func finish(_ root: FileNode) {
        condition.lock()
        finished = true
        condition.broadcast()
        condition.unlock()
        onFinish(root)
    }
}

/// Mutable state shared between threads, protected by a `Mutex`.
private final class SharedScanState: Sendable {
    private struct HardLinkKey: Hashable {
        let device: dev_t
        let inode: ino_t
    }

    private struct Progress {
        var files = 0
        var bytes: Int64 = 0
        var lastReport: ContinuousClock.Instant
    }

    private let cancelled = Mutex(false)
    private let hardLinks = Mutex<Set<HardLinkKey>>([])
    private let inaccessible = Mutex<[String]>([])
    private let progress: Mutex<Progress>
    private let report: @Sendable (ScanProgress) -> Void

    init(start: ContinuousClock.Instant, report: @escaping @Sendable (ScanProgress) -> Void) {
        // The first update goes out right away; then, at most every 100 ms.
        progress = Mutex(Progress(lastReport: start - .milliseconds(100)))
        self.report = report
    }

    var isCancelled: Bool { cancelled.withLock { $0 } }

    func cancel() { cancelled.withLock { $0 = true } }

    /// `true` the first time the (device, inode) pair is seen.
    func claimHardLink(device: dev_t, inode: ino_t) -> Bool {
        hardLinks.withLock { $0.insert(HardLinkKey(device: device, inode: inode)).inserted }
    }

    func markInaccessible(_ path: String) {
        inaccessible.withLock { $0.append(path) }
    }

    func inaccessibleSorted() -> [String] {
        inaccessible.withLock { $0.sorted() }
    }

    func record(files: Int, bytes: Int64, path: String) {
        let snapshot: ScanProgress? = progress.withLock { state in
            state.files += files
            state.bytes += bytes
            let now = ContinuousClock.now
            guard now - state.lastReport >= .milliseconds(100) else { return nil }
            state.lastReport = now
            return ScanProgress(filesScanned: state.files, bytesScanned: state.bytes, currentPath: path)
        }
        if let snapshot { report(snapshot) }
    }
}
