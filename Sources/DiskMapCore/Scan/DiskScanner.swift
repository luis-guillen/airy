import Foundation
import Synchronization

public struct ScanOptions: Sendable {
    public static let defaultExcludedPrefixes = [
        "/System/Volumes", "/dev", "/Volumes", "/private/var/vm", "/.Spotlight-V100", "/.fseventsd",
    ]

    public var roots: [URL]
    /// Rutas que no se recorren. Si una raíz está dentro de un prefijo, ese prefijo no se aplica a ella.
    public var excludedPrefixes: [String]
    /// Hijos más pequeños que esto se funden en un nodo "Otros" al cerrar cada carpeta.
    public var pruneThreshold: Int64

    public init(
        roots: [URL],
        excludedPrefixes: [String] = ScanOptions.defaultExcludedPrefixes,
        pruneThreshold: Int64 = 1_048_576
    ) {
        self.roots = roots
        self.excludedPrefixes = excludedPrefixes
        self.pruneThreshold = pruneThreshold
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

    public init(root: FileNode, inaccessible: [String], duration: TimeInterval) {
        self.root = root
        self.inaccessible = inaccessible
        self.duration = duration
    }
}

/// Escáner paralelo: `opendir/readdir` + `fstatat` sin seguir enlaces, tamaño asignado
/// (`st_blocks * 512`), hard links contados una vez y sin cruzar a otros volúmenes.
public final class DiskScanner: Sendable {
    public let options: ScanOptions
    private let width = ProcessInfo.processInfo.activeProcessorCount * 2

    public init(options: ScanOptions) {
        self.options = options
    }

    /// Cancelable con `Task.cancel()` (lanza `CancellationError`). `progress` se llama como máximo cada 100 ms.
    public func scan(progress: @escaping @Sendable (ScanProgress) -> Void) async throws -> ScanResult {
        let clock = ContinuousClock()
        let start = clock.now
        let shared = SharedScanState(start: start, report: progress)
        let rootPaths = Self.uniqueNormalized(options.roots.map(\.path))
        let excluded = Set(options.excludedPrefixes.map(Self.normalize))

        var nodes: [FileNode] = []
        for rootPath in rootPaths {
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
                threshold: options.pruneThreshold,
                width: width,
                shared: shared
            )
            let entry = DirectoryEntry(
                path: rootPath, name: rootPath,
                ownSize: Int64(info.st_blocks) * 512, modified: Self.date(info.st_mtimespec))
            nodes.append(await scanDirectory(entry, context))
            try Task.checkCancellation()
        }
        try Task.checkCancellation()

        let root = nodes.count == 1 ? nodes[0] : Self.combine(nodes)
        let elapsed = clock.now - start
        let duration = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return ScanResult(root: root, inaccessible: shared.inaccessibleSorted(), duration: duration)
    }

    // MARK: - Recorrido

    private func scanDirectory(_ directory: DirectoryEntry, _ context: ScanContext) async -> FileNode {
        guard !Task.isCancelled else { return close(directory, children: [], context) }
        guard let handle = opendir(directory.path) else {
            context.shared.markInaccessible(directory.path)
            return close(directory, children: [], context)
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
                    // Si desaparece entre readdir y fstatat, se omite.
                    guard fstatat(fd, cName, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
                    return (name, info)
                }
            }
            guard let (name, info) = found else { continue }
            let childPath = directory.path == "/" ? "/" + name : directory.path + "/" + name
            if context.excluded.contains(childPath) || context.otherRoots.contains(childPath) { continue }

            if (info.st_mode & S_IFMT) == S_IFDIR {
                guard info.st_dev == context.device else { continue }
                subdirectories.append(DirectoryEntry(
                    path: childPath, name: name,
                    ownSize: Int64(info.st_blocks) * 512, modified: Self.date(info.st_mtimespec)))
            } else {
                let file = makeFile(name: name, directory: directory.path, info: info, shared: context.shared)
                fileBytes += file.allocatedSize
                children.append(file)
            }
        }
        closedir(handle)
        context.shared.record(files: children.count, bytes: fileBytes, path: directory.path)

        let width = context.width
        let scannedDirectories = await withTaskGroup(of: FileNode.self, returning: [FileNode].self) { group in
            var pending = subdirectories.makeIterator()
            for _ in 0..<width {
                guard let next = pending.next() else { break }
                group.addTask { await self.scanDirectory(next, context) }
            }
            var results: [FileNode] = []
            results.reserveCapacity(subdirectories.count)
            while let node = await group.next() {
                results.append(node)
                if let next = pending.next() {
                    group.addTask { await self.scanDirectory(next, context) }
                }
            }
            return results
        }
        children.append(contentsOf: scannedDirectories)
        return close(directory, children: children, context)
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

    /// Cierra una carpeta: suma tamaños y tipos, decide su `kind` y agrupa los hijos pequeños.
    private func close(_ directory: DirectoryEntry, children: [FileNode], _ context: ScanContext) -> FileNode {
        let folderKind = FileKindClassifier.kind(forDirectoryPath: directory.path)
        var kindBytes = Array(repeating: Int64(0), count: ContentKind.allCases.count)
        kindBytes[(folderKind ?? .other).index] = directory.ownSize
        var descendants = 0
        for child in children {
            for index in kindBytes.indices { kindBytes[index] += child.kindBytes[index] }
            descendants += 1 + child.descendantCount
        }
        // Lo que no se reconoce por extensión toma el significado de la carpeta (binarios de una .app, blobs de Caches…).
        if let folderKind, folderKind != .other {
            kindBytes[folderKind.index] += kindBytes[ContentKind.other.index]
            kindBytes[ContentKind.other.index] = 0
        }

        let node = FileNode(
            name: directory.name, isDirectory: true,
            allocatedSize: kindBytes.reduce(0, +), lastModified: directory.modified,
            kindBytes: kindBytes, children: Self.pruned(children, below: context.threshold),
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
                name: "Otros", isDirectory: false, allocatedSize: kindBytes.reduce(0, +),
                lastModified: small.compactMap(\.lastModified).max(),
                kindBytes: kindBytes, descendantCount: hidden, aggregatedCount: small.count)
            aggregate.kind = aggregate.dominantKind
            kept.append(aggregate)
        } else {
            kept.append(contentsOf: small)
        }
        return kept.sorted { $0.allocatedSize > $1.allocatedSize }
    }

    /// Varias raíces cuelgan de un nodo sin nombre para que `path` de cada una siga siendo absoluta.
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

    // MARK: - Utilidades

    private static func normalize(_ path: String) -> String {
        // Sin `standardizingPath`: quitaría `/private` y las exclusiones dejarían de coincidir.
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

/// Configuración inmutable de una raíz concreta.
private struct ScanContext: Sendable {
    let device: dev_t
    let excluded: Set<String>
    let otherRoots: Set<String>
    let threshold: Int64
    let width: Int
    let shared: SharedScanState
}

/// Estado mutable compartido entre tareas, protegido por `Mutex`.
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

    private let hardLinks = Mutex<Set<HardLinkKey>>([])
    private let inaccessible = Mutex<[String]>([])
    private let progress: Mutex<Progress>
    private let report: @Sendable (ScanProgress) -> Void

    init(start: ContinuousClock.Instant, report: @escaping @Sendable (ScanProgress) -> Void) {
        progress = Mutex(Progress(lastReport: start))
        self.report = report
    }

    /// `true` la primera vez que se ve el par (dispositivo, inodo).
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

private extension ContentKind {
    var index: Int { ContentKind.allCases.firstIndex(of: self)! }
}
