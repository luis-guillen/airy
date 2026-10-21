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
    /// `false` reads every folder with `readdir` + `fstatat` (the reference the bulk reader is tested against).
    var usesBulkReader = true

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

    /// Bytes each scan thread gives `getattrlistbulk` per call (a few hundred entries).
    static let bulkBufferSize = 64 * 1024

    /// Walks a root with the budget's threads and returns its closed node. Without blocking
    /// the cooperative pool: the task waits on a continuation.
    private func scanTree(_ root: DirectoryEntry, _ context: ScanContext) async -> FileNode {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<FileNode, Never>) in
                let queue = WorkQueue { continuation.resume(returning: $0) }
                queue.push([Job(entry: root, parent: nil)])
                for index in 0..<max(1, budget.workers) {
                    let thread = Thread { [self] in
                        // One buffer per thread for the whole walk.
                        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: Self.bulkBufferSize, alignment: 16)
                        defer { buffer.deallocate() }
                        while let job = queue.next() { process(job, context, queue, buffer) }
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
    private func process(_ job: Job, _ context: ScanContext, _ queue: WorkQueue, _ buffer: UnsafeMutableRawBufferPointer) {
        // Cancelled: what is left is closed empty without touching the disk (the result is discarded).
        guard !context.shared.isCancelled else {
            deliver(close(job.entry, children: [], small: SmallFiles()), to: job.parent, queue)
            return
        }
        let listing = read(job.entry, context, buffer)
        var nodes = listing.nodes
        // Excluded by the user: closed empty without opening it, like an unreadable folder.
        for entry in listing.closedEmpty { nodes.append(close(entry, children: [], small: SmallFiles())) }
        guard !listing.subdirectories.isEmpty else {
            deliver(close(job.entry, children: nodes, small: listing.small), to: job.parent, queue)
            return
        }
        let pending = PendingDirectory(entry: job.entry, children: nodes, small: listing.small,
                                       remaining: listing.subdirectories.count, parent: job.parent)
        queue.push(listing.subdirectories.map { Job(entry: $0, parent: pending) })
    }

    /// Hands a closed node to its parent; the last child to arrive closes the parent, and so on
    /// upwards. Closing the root ends the walk.
    private func deliver(_ node: FileNode, to parent: PendingDirectory?, _ queue: WorkQueue) {
        var node = node
        var parent = parent
        while let current = parent {
            guard let children = queue.attach(node, to: current) else { return }
            node = close(current.entry, children: children, small: current.small)
            parent = current.parent
        }
        queue.finish(node)
    }

    /// Attribute bits of the bulk request.
    private enum Bulk {
        static let returned = attrgroup_t(truncatingIfNeeded: ATTR_CMN_RETURNED_ATTRS)
        static let error = attrgroup_t(truncatingIfNeeded: ATTR_CMN_ERROR)
        static let name = attrgroup_t(truncatingIfNeeded: ATTR_CMN_NAME)
        static let device = attrgroup_t(truncatingIfNeeded: ATTR_CMN_DEVID)
        static let type = attrgroup_t(truncatingIfNeeded: ATTR_CMN_OBJTYPE)
        static let modified = attrgroup_t(truncatingIfNeeded: ATTR_CMN_MODTIME)
        static let inode = attrgroup_t(truncatingIfNeeded: ATTR_CMN_FILEID)
        static let links = attrgroup_t(truncatingIfNeeded: ATTR_FILE_LINKCOUNT)
        static let allocated = attrgroup_t(truncatingIfNeeded: ATTR_FILE_ALLOCSIZE)
    }

    /// What `getattrlistbulk` is asked for each entry. Folders still go through `fstatat` (see `read`).
    private static let bulkRequest: attrlist = {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = Bulk.returned | Bulk.error | Bulk.name | Bulk.device | Bulk.type | Bulk.modified | Bulk.inode
        request.fileattr = Bulk.links | Bulk.allocated
        return request
    }()

    /// Reads a folder with `getattrlistbulk`: one call returns the name and metadata of hundreds of entries, so
    /// files no longer cost one `fstatat` each. Folders (≈ 1 in 10 entries) still use `fstatat`, because through a
    /// firmlink the bulk call describes the stub on the system volume, not the folder it leads to. Any entry
    /// the call cannot fully describe also falls back to `fstatat`; a volume without the call is read with
    /// `readdir` (`readLegacy`). Both paths produce exactly the same listing.
    private func read(_ directory: DirectoryEntry, _ context: ScanContext,
                      _ buffer: UnsafeMutableRawBufferPointer) -> Listing {
        guard options.usesBulkReader else { return readLegacy(directory, context) }
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            context.shared.markInaccessible(directory.path)
            return Listing()
        }
        var builder = ListingBuilder(directory: directory, context: context, threshold: options.pruneThreshold)
        var request = Self.bulkRequest
        var readAny = false
        let errorBit = Bulk.error, nameBit = Bulk.name, deviceBit = Bulk.device, typeBit = Bulk.type
        let timeBit = Bulk.modified, inodeBit = Bulk.inode, linksBit = Bulk.links, allocBit = Bulk.allocated
        while true {
            let count = getattrlistbulk(fd, &request, buffer.baseAddress, buffer.count, 0)
            if count < 0, !readAny {
                // This volume does not support it (or refused the first read): the old way, from scratch.
                Darwin.close(fd)
                return readLegacy(directory, context)
            }
            guard count > 0 else { break }
            readAny = true
            var entry = UnsafeRawPointer(buffer.baseAddress!)
            for _ in 0..<count {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                defer { entry += length }
                var field = entry + 4
                let returned = field.loadUnaligned(as: attribute_set_t.self)
                field += MemoryLayout<attribute_set_t>.size
                var failed = false
                if returned.commonattr & errorBit != 0 {
                    failed = field.loadUnaligned(as: UInt32.self) != 0
                    field += 4
                }
                guard returned.commonattr & nameBit != 0 else { continue }
                let reference = field.loadUnaligned(as: attrreference_t.self)
                let cName = (field + Int(reference.attr_dataoffset)).assumingMemoryBound(to: CChar.self)
                let nameLength = max(Int(reference.attr_length) - 1, 0)
                field += MemoryLayout<attrreference_t>.size
                let complete = returned.commonattr & (deviceBit | typeBit | timeBit | inodeBit) == (deviceBit | typeBit | timeBit | inodeBit)
                    && returned.fileattr & (linksBit | allocBit) == (linksBit | allocBit)
                var device: dev_t = 0, type: UInt32 = 0, modified = timespec(), inode: UInt64 = 0
                if returned.commonattr & deviceBit != 0 { device = field.loadUnaligned(as: dev_t.self); field += 4 }
                if returned.commonattr & typeBit != 0 { type = field.loadUnaligned(as: UInt32.self); field += 4 }
                if returned.commonattr & timeBit != 0 {
                    modified = field.loadUnaligned(as: timespec.self); field += MemoryLayout<timespec>.size
                }
                if returned.commonattr & inodeBit != 0 { inode = field.loadUnaligned(as: UInt64.self); field += 8 }

                // Folders, and anything not fully described: `fstatat`, exactly as before.
                guard !failed, complete, type != UInt32(VDIR.rawValue) else {
                    var info = stat()
                    // If it disappears in between, it is skipped.
                    guard fstatat(fd, cName, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
                    builder.add(name: String(cString: cName), info: info)
                    continue
                }
                let links = field.loadUnaligned(as: UInt32.self)
                field += 4
                let allocated = field.loadUnaligned(as: Int64.self)
                let name = UnsafeBufferPointer(start: UnsafeRawPointer(cName).assumingMemoryBound(to: UInt8.self),
                                               count: nameLength)
                builder.addFile(name: name, allocated: allocated, links: links,
                                isRegular: type == UInt32(VREG.rawValue), device: device, inode: inode,
                                modified: modified)
            }
        }
        Darwin.close(fd)
        return builder.finish()
    }

    /// `opendir/readdir` + `fstatat` per entry: for volumes without `getattrlistbulk`.
    private func readLegacy(_ directory: DirectoryEntry, _ context: ScanContext) -> Listing {
        guard let handle = opendir(directory.path) else {
            context.shared.markInaccessible(directory.path)
            return Listing()
        }
        var builder = ListingBuilder(directory: directory, context: context, threshold: options.pruneThreshold)
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
            builder.add(name: name, info: info)
        }
        closedir(handle)
        return builder.finish()
    }

    /// Only for a root that is a file.
    private func makeFile(name: String, directory: String, info: stat, shared: SharedScanState) -> FileNode {
        var size = Int64(info.st_blocks) * 512
        if info.st_nlink > 1, (info.st_mode & S_IFMT) == S_IFREG,
           !shared.claimHardLink(device: info.st_dev, inode: info.st_ino) {
            size = 0
        }
        let kind = FileKindClassifier.kind(forFileNamed: name, inDirectoryPath: directory)
        return Self.fileNode(name: name, size: size, modified: Self.date(info.st_mtimespec), kind: kind)
    }

    fileprivate static func fileNode(name: String, size: Int64, modified: Date, kind: ContentKind) -> FileNode {
        var kindBytes = Array(repeating: Int64(0), count: ContentKind.count)
        kindBytes[kind.index] = size
        return FileNode(name: name, isDirectory: false, allocatedSize: size, lastModified: modified,
                        kind: kind, kindBytes: kindBytes)
    }

    /// Closes a folder: adds up sizes and kinds, decides its `kind` and groups the small children.
    private func close(_ directory: DirectoryEntry, children: [FileNode], small: SmallFiles) -> FileNode {
        let folderKind = FileKindClassifier.kind(forDirectoryPath: directory.path)
        var kindBytes = Array(repeating: Int64(0), count: ContentKind.count)
        kindBytes[(folderKind ?? .other).index] = directory.ownSize
        var descendants = small.count
        if small.count > 0 {
            for index in kindBytes.indices { kindBytes[index] += small.kindBytes[index] }
        }
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
            kindBytes: kindBytes, children: Self.pruned(children, small: small, below: options.pruneThreshold),
            descendantCount: descendants)
        node.kind = folderKind ?? node.dominantKind
        return node
    }

    /// Groups the children below `threshold` into one "Other" node when there are at least two of them. The
    /// small files were already folded while reading (`small`); here they join the small closed children.
    private static func pruned(_ children: [FileNode], small files: SmallFiles, below threshold: Int64) -> [FileNode] {
        var kept: [FileNode] = []
        var small: [FileNode] = []
        for child in children {
            if child.allocatedSize < threshold { small.append(child) } else { kept.append(child) }
        }
        if small.count + files.count >= 2 {
            var kindBytes = files.count > 0 ? files.kindBytes : Array(repeating: Int64(0), count: ContentKind.count)
            var hidden = 0
            var newest = files.newest
            for child in small {
                for index in kindBytes.indices { kindBytes[index] += child.kindBytes[index] }
                hidden += child.descendantCount
                if let modified = child.lastModified { newest = max(newest ?? modified, modified) }
            }
            let aggregate = FileNode(
                name: "Other", isDirectory: false, allocatedSize: kindBytes.reduce(0, +),
                lastModified: newest,
                kindBytes: kindBytes, descendantCount: hidden, aggregatedCount: small.count + files.count)
            aggregate.kind = aggregate.dominantKind
            kept.append(aggregate)
        } else {
            kept.append(contentsOf: small)
            if let only = files.first {
                kept.append(fileNode(name: only.name, size: only.size, modified: only.modified, kind: only.kind))
            }
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

    static func date(_ time: timespec) -> Date {
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
    /// Folders that directly contain an excluded path or another root: only there does a file need its full
    /// path built to be checked against `excluded` and `otherRoots`.
    let excludedParents: Set<String>

    init(device: dev_t, excluded: Set<String>, otherRoots: Set<String>, userExcluded: Set<String>,
         shared: SharedScanState) {
        self.device = device
        self.excluded = excluded
        self.otherRoots = otherRoots
        self.userExcluded = userExcluded
        self.shared = shared
        excludedParents = Set(excluded.union(otherRoots).map { path in
            guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else { return "/" }
            return String(path[..<slash])
        })
    }

    func isExcluded(_ path: String) -> Bool { excluded.contains(path) || otherRoots.contains(path) }
}

/// Files below the prune threshold, folded while the folder is read: they would end up inside its "Other"
/// node anyway, so no `FileNode` (nor name) is made for each one. Only the first is kept whole, in case it
/// turns out to be the folder's only small child (then it is shown on its own, as before).
struct SmallFiles: Sendable {
    struct File: Sendable {
        let name: String
        let size: Int64
        let modified: Date
        let kind: ContentKind
    }

    private(set) var count = 0
    /// Per kind; empty while `count == 0`.
    private(set) var kindBytes: [Int64] = []
    private(set) var newest: Date?
    private(set) var first: File?

    /// `name` is only called for the first one.
    mutating func add(size: Int64, modified: Date, kind: ContentKind, name: () -> String) {
        if count == 0 {
            kindBytes = Array(repeating: 0, count: ContentKind.count)
            first = File(name: name(), size: size, modified: modified, kind: kind)
        }
        count += 1
        kindBytes[kind.index] += size
        newest = max(newest ?? modified, modified)
    }
}

/// What reading one folder yields: its kept children, its folded small files and the subfolders to walk.
private struct Listing {
    var nodes: [FileNode] = []
    var small = SmallFiles()
    var subdirectories: [DirectoryEntry] = []
    /// Subfolders the user excluded: closed empty without opening them.
    var closedEmpty: [DirectoryEntry] = []
}

/// Turns the entries of one folder into a `Listing`, the same way whichever call read them.
private struct ListingBuilder {
    let directory: DirectoryEntry
    let context: ScanContext
    let threshold: Int64
    /// The folder's files can only be excluded if it directly contains an excluded path.
    let checksFiles: Bool
    var listing = Listing()
    var entries = 0
    var fileBytes: Int64 = 0

    init(directory: DirectoryEntry, context: ScanContext, threshold: Int64) {
        self.directory = directory
        self.context = context
        self.threshold = threshold
        checksFiles = context.excludedParents.contains(directory.path)
    }

    private func childPath(_ name: String) -> String {
        directory.path == "/" ? "/" + name : directory.path + "/" + name
    }

    /// An entry described by `fstatat`/`lstat`.
    mutating func add(name: String, info: stat) {
        let path = childPath(name)
        if context.isExcluded(path) { return }
        if (info.st_mode & S_IFMT) == S_IFDIR {
            guard info.st_dev == context.device else { return }
            let entry = DirectoryEntry(
                path: path, name: name,
                ownSize: Int64(info.st_blocks) * 512, modified: DiskScanner.date(info.st_mtimespec))
            // Excluded by the user: closed empty without opening it, like an unreadable folder.
            if !context.userExcluded.isEmpty, context.userExcluded.contains(path.lowercased()) {
                listing.closedEmpty.append(entry)
                entries += 1
                return
            }
            listing.subdirectories.append(entry)
        } else {
            var size = Int64(info.st_blocks) * 512
            if info.st_nlink > 1, (info.st_mode & S_IFMT) == S_IFREG,
               !context.shared.claimHardLink(device: info.st_dev, inode: info.st_ino) {
                size = 0
            }
            let kind = FileKindClassifier.kind(forFileNamed: name, inDirectoryPath: directory.path)
            addFile(size: size, modified: DiskScanner.date(info.st_mtimespec), kind: kind) { name }
        }
    }

    /// A file (anything but a folder) described by `getattrlistbulk`. `allocated` is the total allocated size,
    /// which `stat` reports rounded up to 512-byte blocks.
    mutating func addFile(name: UnsafeBufferPointer<UInt8>, allocated: Int64, links: UInt32, isRegular: Bool,
                          device: dev_t, inode: UInt64, modified: timespec) {
        if checksFiles, context.isExcluded(childPath(String(decoding: name, as: UTF8.self))) { return }
        var size = (max(allocated, 0) + 511) / 512 * 512
        if links > 1, isRegular, !context.shared.claimHardLink(device: device, inode: ino_t(inode)) {
            size = 0
        }
        let kind = FileKindClassifier.kind(forFileNameBytes: name, inDirectoryPath: directory.path)
        addFile(size: size, modified: DiskScanner.date(modified), kind: kind) { String(decoding: name, as: UTF8.self) }
    }

    private mutating func addFile(size: Int64, modified: Date, kind: ContentKind, name: () -> String) {
        entries += 1
        fileBytes += size
        if size < threshold {
            listing.small.add(size: size, modified: modified, kind: kind, name: name)
        } else {
            listing.nodes.append(DiskScanner.fileNode(name: name(), size: size, modified: modified, kind: kind))
        }
    }

    func finish() -> Listing {
        context.shared.record(files: entries, bytes: fileBytes, path: directory.path)
        return listing
    }
}

/// A read folder waiting for its subfolders. Its mutable fields are only touched under the
/// `WorkQueue` lock (`attach`).
private final class PendingDirectory: @unchecked Sendable {
    let entry: DirectoryEntry
    let parent: PendingDirectory?
    let small: SmallFiles
    var children: [FileNode]
    var remaining: Int

    init(entry: DirectoryEntry, children: [FileNode], small: SmallFiles, remaining: Int, parent: PendingDirectory?) {
        self.entry = entry
        self.children = children
        self.small = small
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
