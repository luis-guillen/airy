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
    private static let currentVersion = 1
    private static let noDate = -1.0e18

    private struct FlatScan: Codable {
        var version: Int
        var duration: Double
        var inaccessible: [String]
        var parentIndex: [Int]
        var name: [String]
        var isDirectory: [Bool]
        var size: [Int64]
        var kind: [UInt8]
        /// `kindBytes` de todos los nodos concatenados (10 por nodo).
        var kindBytes: [Int64]
        var mtime: [Double]
        var descendantCount: [Int]
        var aggregatedCount: [Int]
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
        let flat = Self.flatten(result)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(flat)
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
            guard let flat = try? PropertyListDecoder().decode(FlatScan.self, from: data),
                  flat.version == Self.currentVersion,
                  let result = Self.rebuild(flat) else {
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

    private static func flatten(_ result: ScanResult) -> FlatScan {
        var flat = FlatScan(
            version: currentVersion, duration: result.duration, inaccessible: result.inaccessible,
            parentIndex: [], name: [], isDirectory: [], size: [], kind: [], kindBytes: [],
            mtime: [], descendantCount: [], aggregatedCount: [])
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
            flat.parentIndex.append(parent)
            flat.name.append(node.name)
            flat.isDirectory.append(node.isDirectory)
            flat.size.append(node.allocatedSize)
            flat.kind.append(kindIndex[node.kind] ?? 0)
            var bytes = node.kindBytes
            if bytes.count != kindCount {
                bytes = Array((bytes + Array(repeating: 0, count: kindCount)).prefix(kindCount))
            }
            flat.kindBytes.append(contentsOf: bytes)
            flat.mtime.append(node.lastModified?.timeIntervalSinceReferenceDate ?? noDate)
            flat.descendantCount.append(node.descendantCount)
            flat.aggregatedCount.append(node.aggregatedCount)
            for child in node.children { queue.append((child, index)) }
        }
        return flat
    }

    private static func rebuild(_ flat: FlatScan) -> ScanResult? {
        let count = flat.name.count
        let kinds = ContentKind.allCases
        let kindCount = kinds.count
        guard count > 0,
              flat.parentIndex.count == count, flat.isDirectory.count == count,
              flat.size.count == count, flat.kind.count == count,
              flat.kindBytes.count == count * kindCount, flat.mtime.count == count,
              flat.descendantCount.count == count, flat.aggregatedCount.count == count,
              flat.parentIndex[0] == -1 else { return nil }

        var nodes: [FileNode] = []
        nodes.reserveCapacity(count)
        for i in 0..<count {
            let kindRaw = Int(flat.kind[i])
            guard kindRaw < kindCount else { return nil }
            let mtime = flat.mtime[i]
            nodes.append(FileNode(
                name: flat.name[i],
                isDirectory: flat.isDirectory[i],
                allocatedSize: flat.size[i],
                lastModified: mtime == noDate ? nil : Date(timeIntervalSinceReferenceDate: mtime),
                kind: kinds[kindRaw],
                kindBytes: Array(flat.kindBytes[(i * kindCount)..<((i + 1) * kindCount)]),
                descendantCount: flat.descendantCount[i],
                aggregatedCount: flat.aggregatedCount[i]))
        }
        // Los padres preceden a los hijos, así que el orden de los hijos se conserva.
        for i in 1..<max(count, 1) {
            let p = flat.parentIndex[i]
            guard p >= 0, p < i else { return nil }
            nodes[i].parent = nodes[p]
            nodes[p].children.append(nodes[i])
        }
        return ScanResult(root: nodes[0], inaccessible: flat.inaccessible, duration: flat.duration)
    }
}
