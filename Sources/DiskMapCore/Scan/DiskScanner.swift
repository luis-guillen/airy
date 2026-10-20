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
///
/// El trabajo lo hacen `budget.workers` hilos propios con la QoS del presupuesto (nunca el pool
/// cooperativo entero): una pila compartida de carpetas por leer y cada carpeta se cierra cuando
/// llega su última subcarpeta. Así un análisis no puede ocupar más núcleos que los que se le dan.
public final class DiskScanner: Sendable {
    public let options: ScanOptions
    public let budget: ScanBudget

    public init(options: ScanOptions, budget: ScanBudget) {
        self.options = options
        self.budget = budget
    }

    /// El presupuesto se calcula ahora con el estado del Mac (Bajo consumo, temperatura).
    public convenience init(options: ScanOptions, intensity: ScanIntensity = .normal) {
        self.init(options: options, budget: .current(intensity))
    }

    /// Cancelable con `Task.cancel()` (lanza `CancellationError`). `progress` se llama como máximo
    /// cada 100 ms, desde los hilos del escáner.
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
        return ScanResult(root: root, inaccessible: shared.inaccessibleSorted(), duration: duration)
    }

    // MARK: - Recorrido

    /// Recorre una raíz con los hilos del presupuesto y devuelve su nodo cerrado. Sin bloquear
    /// el pool cooperativo: la tarea espera en una continuación.
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

    /// Lee una carpeta: si no tiene subcarpetas se cierra ya; si no, deja sus subcarpetas en la pila.
    private func process(_ job: Job, _ context: ScanContext, _ queue: WorkQueue) {
        // Cancelado: lo que queda se cierra vacío sin tocar el disco (el resultado se descarta).
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

    /// Entrega un nodo cerrado a su padre; el último hijo en llegar cierra al padre, y así hacia
    /// arriba. Cerrar la raíz termina el recorrido.
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

    /// Cierra una carpeta: suma tamaños y tipos, decide su `kind` y agrupa los hijos pequeños.
    private func close(_ directory: DirectoryEntry, children: [FileNode]) -> FileNode {
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
    let shared: SharedScanState
}

/// Carpeta leída que espera a sus subcarpetas. Sus campos variables solo se tocan con el
/// cerrojo de `WorkQueue` (`attach`).
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

/// Pila de carpetas por leer que comparten los hilos del escáner (LIFO: el recorrido va en
/// profundidad y las carpetas a medias no se acumulan). Todo su estado va bajo `condition`.
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

    /// Espera trabajo; `nil` cuando la raíz ya se cerró (el hilo termina).
    func next() -> Job? {
        condition.lock()
        defer { condition.unlock() }
        while jobs.isEmpty, !finished { condition.wait() }
        return jobs.popLast()
    }

    /// Añade un hijo cerrado; devuelve los hijos del padre si era el último que faltaba.
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

/// Estado mutable compartido entre hilos, protegido por `Mutex`.
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
        // El primer aviso sale enseguida; luego, como mucho cada 100 ms.
        progress = Mutex(Progress(lastReport: start - .milliseconds(100)))
        self.report = report
    }

    var isCancelled: Bool { cancelled.withLock { $0 } }

    func cancel() { cancelled.withLock { $0 = true } }

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
