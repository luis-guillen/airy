import Foundation
import Synchronization

public struct CleanupRecord: Codable, Sendable {
    public var date: Date
    public var title: String
    public var bytes: Int64
    public var wentToTrash: Bool

    public init(date: Date, title: String, bytes: Int64, wentToTrash: Bool) {
        self.date = date
        self.title = title
        self.bytes = bytes
        self.wentToTrash = wentToTrash
    }
}

/// Persiste el último índice (`scan.plist`, plist binario, arrays paralelos) y el
/// historial de limpiezas (`history.json`). La fecha del último análisis es la fecha de
/// modificación de `scan.plist` (`lastScanDate()`).
public final class IndexStore: Sendable {
    private static let currentVersion: UInt32 = 2
    private static let noDate = -1.0e18
    private static let magic: [UInt8] = Array("DMIX".utf8)

    /// Columnas paralelas del árbol aplanado (BFS: los padres preceden a los hijos).
    struct FlatScan {
        var duration: Double = 0
        var inaccessible: [String] = []
        var parentIndex: [Int32] = []
        var name: [String] = []
        var isDirectory: [UInt8] = []
        var size: [Int64] = []
        var kind: [UInt8] = []
        /// `kindBytes` de todos los nodos concatenados (10 por nodo).
        var kindBytes: [Int64] = []
        var mtime: [Double] = []
        var descendantCount: [Int64] = []
        var aggregatedCount: [Int64] = []
    }

    private let directory: URL
    private let lock = Mutex(())

    public init(directory: URL) {
        self.directory = directory
    }

    private var scanURL: URL { directory.appendingPathComponent("scan.plist") }
    private var historyURL: URL { directory.appendingPathComponent("history.json") }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - Índice

    public func saveScan(_ result: ScanResult) throws {
        let data = Self.serialize(Self.flatten(result))
        try lock.withLock { _ in
            try ensureDirectory()
            try data.write(to: scanURL, options: .atomic)
        }
    }

    /// `nil` si no existe; si está corrupto, se borra y devuelve `nil`.
    public func loadScan() throws -> ScanResult? {
        try lock.withLock { _ in
            guard FileManager.default.fileExists(atPath: scanURL.path) else { return nil }
            let data = try Data(contentsOf: scanURL)
            guard let flat = Self.parse(data), let result = Self.rebuild(flat) else {
                try? FileManager.default.removeItem(at: scanURL)
                return nil
            }
            return result
        }
    }

    public func lastScanDate() throws -> Date? {
        try lock.withLock { _ in
            guard FileManager.default.fileExists(atPath: scanURL.path) else { return nil }
            let attributes = try FileManager.default.attributesOfItem(atPath: scanURL.path)
            return attributes[.modificationDate] as? Date
        }
    }

    // MARK: - Historial

    public func append(_ record: CleanupRecord) throws {
        try lock.withLock { _ in
            var records = try readHistory()
            records.append(record)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try ensureDirectory()
            try encoder.encode(records).write(to: historyURL, options: .atomic)
        }
    }

    public func history() throws -> [CleanupRecord] {
        try lock.withLock { _ in try readHistory() }
    }

    /// Solo lo liberado de verdad: lo enviado a la Papelera no cuenta hasta vaciarla.
    public func totalFreed() throws -> Int64 {
        try history().filter { !$0.wentToTrash }.reduce(0) { $0 + $1.bytes }
    }

    private func readHistory() throws -> [CleanupRecord] {
        guard FileManager.default.fileExists(atPath: historyURL.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([CleanupRecord].self, from: Data(contentsOf: historyURL))
    }

    // MARK: - Aplanado iterativo

    static func flatten(_ result: ScanResult) -> FlatScan {
        var flat = FlatScan()
        flat.duration = result.duration
        flat.inaccessible = result.inaccessible
        let kinds = ContentKind.allCases
        let kindCount = kinds.count
        var kindIndex: [ContentKind: UInt8] = [:]
        for (i, k) in kinds.enumerated() { kindIndex[k] = UInt8(i) }

        // Cola BFS: el índice de un hijo siempre es mayor que el de su padre.
        var queue: [(node: FileNode, parent: Int)] = [(result.root, -1)]
        var head = 0
        while head < queue.count {
            let (node, parent) = queue[head]
            let index = head
            head += 1
            flat.parentIndex.append(Int32(parent))
            flat.name.append(node.name)
            flat.isDirectory.append(node.isDirectory ? 1 : 0)
            flat.size.append(node.allocatedSize)
            flat.kind.append(kindIndex[node.kind] ?? 0)
            var bytes = node.kindBytes
            if bytes.count != kindCount {
                bytes = Array((bytes + Array(repeating: 0, count: kindCount)).prefix(kindCount))
            }
            flat.kindBytes.append(contentsOf: bytes)
            flat.mtime.append(node.lastModified?.timeIntervalSinceReferenceDate ?? noDate)
            flat.descendantCount.append(Int64(node.descendantCount))
            flat.aggregatedCount.append(Int64(node.aggregatedCount))
            for child in node.children { queue.append((child, index)) }
        }
        return flat
    }

    // MARK: - Formato binario

    /// Cabecera: magic "DMIX", versión UInt32, nodos UInt64, duración Double, inaccesibles UInt64;
    /// luego columnas de ancho fijo, offsets de cadenas (UInt64, n+1) y blobs UTF-8.
    static func serialize(_ flat: FlatScan) -> Data {
        let count = flat.name.count
        var out = Data()
        out.reserveCapacity(count * 120)
        func put<T>(_ array: [T]) {
            array.withUnsafeBytes { out.append(contentsOf: $0) }
        }
        func putValue<T>(_ value: T) {
            withUnsafeBytes(of: value) { out.append(contentsOf: $0) }
        }
        func putStrings(_ strings: [String]) {
            var offsets: [UInt64] = [0]
            offsets.reserveCapacity(strings.count + 1)
            var blob: [UInt8] = []
            for string in strings {
                blob.append(contentsOf: string.utf8)
                offsets.append(UInt64(blob.count))
            }
            put(offsets)
            put(blob)
        }
        out.append(contentsOf: magic)
        putValue(currentVersion)
        putValue(UInt64(count))
        putValue(flat.duration)
        putValue(UInt64(flat.inaccessible.count))
        put(flat.parentIndex); put(flat.isDirectory); put(flat.kind)
        // Alinear a 8 bytes para las columnas anchas.
        while out.count % 8 != 0 { out.append(0) }
        put(flat.size); put(flat.mtime); put(flat.descendantCount)
        put(flat.aggregatedCount); put(flat.kindBytes)
        putStrings(flat.name)
        putStrings(flat.inaccessible)
        return out
    }

    static func parse(_ data: Data) -> FlatScan? {
        let kindCount = ContentKind.allCases.count
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> FlatScan? in
            var pos = 0
            func take<T>(_ type: T.Type, _ n: Int) -> [T]? where T: BitwiseCopyable {
                let bytes = n * MemoryLayout<T>.stride
                guard n >= 0, n <= raw.count, pos + bytes <= raw.count else { return nil }
                let array = [T](unsafeUninitializedCapacity: n) { buffer, initialized in
                    if bytes > 0 {
                        UnsafeMutableRawBufferPointer(buffer).copyMemory(
                            from: UnsafeRawBufferPointer(rebasing: raw[pos..<(pos + bytes)]))
                    }
                    initialized = n
                }
                pos += bytes
                return array
            }
            func strings(_ n: Int) -> [String]? {
                guard let offsets = take(UInt64.self, n + 1), offsets[0] == 0 else { return nil }
                let total = Int(truncatingIfNeeded: offsets[n])
                guard total >= 0, pos + total <= raw.count else { return nil }
                let base = pos
                var result: [String] = []
                result.reserveCapacity(n)
                var previous = 0
                for i in stride(from: 1, through: n, by: 1) {
                    let end = Int(truncatingIfNeeded: offsets[i])
                    guard end >= previous, end <= total else { return nil }
                    let slice = UnsafeRawBufferPointer(rebasing: raw[(base + previous)..<(base + end)])
                    result.append(String(decoding: slice, as: UTF8.self))
                    previous = end
                }
                pos += total
                return result
            }
            guard raw.count >= 32, Array(raw[0..<4]) == magic else { return nil }
            guard raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self) == currentVersion else { return nil }
            let countU = raw.loadUnaligned(fromByteOffset: 8, as: UInt64.self)
            let inaccU = raw.loadUnaligned(fromByteOffset: 24, as: UInt64.self)
            guard countU > 0, countU < 1 << 31, inaccU < 1 << 31 else { return nil }
            let count = Int(countU)
            let inaccessibleCount = Int(inaccU)
            var flat = FlatScan()
            flat.duration = raw.loadUnaligned(fromByteOffset: 16, as: Double.self)
            pos = 32
            guard let parents = take(Int32.self, count),
                  let dirs = take(UInt8.self, count),
                  let kinds = take(UInt8.self, count) else { return nil }
            pos = (pos + 7) & ~7
            guard let sizes = take(Int64.self, count),
                  let mtimes = take(Double.self, count),
                  let descendants = take(Int64.self, count),
                  let aggregated = take(Int64.self, count),
                  let kindBytes = take(Int64.self, count * kindCount),
                  let names = strings(count),
                  let inaccessible = strings(inaccessibleCount) else { return nil }
            flat.parentIndex = parents; flat.isDirectory = dirs; flat.kind = kinds
            flat.size = sizes; flat.mtime = mtimes; flat.descendantCount = descendants
            flat.aggregatedCount = aggregated; flat.kindBytes = kindBytes
            flat.name = names; flat.inaccessible = inaccessible
            return flat
        }
    }

    static func rebuild(_ flat: FlatScan) -> ScanResult? {
        let count = flat.name.count
        let kinds = ContentKind.allCases
        let kindCount = kinds.count
        guard count > 0, flat.parentIndex[0] == -1 else { return nil }

        var childCounts = [Int32](repeating: 0, count: count)
        for i in 1..<count {
            let p = Int(flat.parentIndex[i])
            guard p >= 0, p < i else { return nil }
            childCounts[p] += 1
        }
        var nodes: [FileNode] = []
        nodes.reserveCapacity(count)
        for i in 0..<count {
            let kindRaw = Int(flat.kind[i])
            guard kindRaw < kindCount else { return nil }
            let mtime = flat.mtime[i]
            let node = FileNode(
                name: flat.name[i],
                isDirectory: flat.isDirectory[i] != 0,
                allocatedSize: flat.size[i],
                lastModified: mtime == noDate ? nil : Date(timeIntervalSinceReferenceDate: mtime),
                kind: kinds[kindRaw],
                kindBytes: Array(flat.kindBytes[(i * kindCount)..<((i + 1) * kindCount)]),
                descendantCount: Int(flat.descendantCount[i]),
                aggregatedCount: Int(flat.aggregatedCount[i]))
            if childCounts[i] > 0 { node.children.reserveCapacity(Int(childCounts[i])) }
            nodes.append(node)
        }
        for i in 1..<count {
            let parent = nodes[Int(flat.parentIndex[i])]
            nodes[i].parent = parent
            parent.children.append(nodes[i])
        }
        return ScanResult(root: nodes[0], inaccessible: flat.inaccessible, duration: flat.duration)
    }
}
