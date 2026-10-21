import Foundation
import Synchronization

public struct CleanupRecord: Codable, Sendable {
    public var date: Date
    public var title: String
    public var bytes: Int64
    public var wentToTrash: Bool
    /// `true` if an agent (MCP) asked for the cleanup. Only encoded when `true`.
    public var byAgent: Bool

    public init(date: Date, title: String, bytes: Int64, wentToTrash: Bool, byAgent: Bool = false) {
        self.date = date
        self.title = title
        self.bytes = bytes
        self.wentToTrash = wentToTrash
        self.byAgent = byAgent
    }

    private enum CodingKeys: String, CodingKey { case date, title, bytes, wentToTrash, byAgent }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(Date.self, forKey: .date)
        title = try c.decode(String.self, forKey: .title)
        bytes = try c.decode(Int64.self, forKey: .bytes)
        wentToTrash = try c.decode(Bool.self, forKey: .wentToTrash)
        byAgent = try c.decodeIfPresent(Bool.self, forKey: .byAgent) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(date, forKey: .date)
        try c.encode(title, forKey: .title)
        try c.encode(bytes, forKey: .bytes)
        try c.encode(wentToTrash, forKey: .wentToTrash)
        if byAgent { try c.encode(true, forKey: .byAgent) }
    }
}

/// Persists the last index (`scan.plist`, a compact binary file of parallel columns) and the
/// cleanup history (`history.json`). The date of the last scan goes inside the index
/// (`ScanResult.scannedAt`, v3 header): the file's modification date is useless, because
/// every cleanup or move to the Trash saves the tree again. A v2 index is read with an unknown
/// date (`nil`). v4 (the one written) stores the per-kind breakdown sparsely and the counts and
/// offsets in 32 bits: about a third of v3's size. v2 and v3 are still read, and rewritten as v4.
public final class IndexStore: Sendable {
    private static let currentVersion: UInt32 = 4
    /// v3: the same header as v4, with every column at full width (`serializeV3`).
    static let fullWidthVersion: UInt32 = 3
    /// v2: same as v3 without `scannedAt` (32-byte header instead of 40).
    private static let legacyVersion: UInt32 = 2
    private static let noDate = -1.0e18
    private static let magic: [UInt8] = Array("DMIX".utf8)

    /// Parallel columns of the flattened tree (BFS: parents precede children).
    struct FlatScan {
        var duration: Double = 0
        var scannedAt: Date?
        var inaccessible: [String] = []
        var parentIndex: [Int32] = []
        var name: [String] = []
        var isDirectory: [UInt8] = []
        var size: [Int64] = []
        var kind: [UInt8] = []
        /// `kindBytes` of every node concatenated (10 per node).
        var kindBytes: [Int64] = []
        var mtime: [Double] = []
        var descendantCount: [Int64] = []
        var aggregatedCount: [Int64] = []
        /// Format it was read from (0 if it was not read).
        var version: UInt32 = 0
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

    // MARK: - Index

    public func saveScan(_ result: ScanResult) throws {
        let data = Self.serialize(Self.flatten(result))
        try lock.withLock { _ in
            try ensureDirectory()
            try data.write(to: scanURL, options: .atomic)
        }
    }

    /// `nil` if it does not exist; if it is corrupt, it is deleted and `nil` is returned.
    public func loadScan() throws -> ScanResult? {
        try lock.withLock { _ in
            guard FileManager.default.fileExists(atPath: scanURL.path) else { return nil }
            let data = try Data(contentsOf: scanURL)
            guard let flat = Self.parse(data), let result = Self.rebuild(flat) else {
                try? FileManager.default.removeItem(at: scanURL)
                return nil
            }
            // An older format is rewritten once in the compact one, with the same content.
            if flat.version < Self.currentVersion {
                try? Self.serialize(flat).write(to: scanURL, options: .atomic)
            }
            return result
        }
    }

    /// Deletes the saved index (`scan.plist`) only; the cleanup history stays. `true` if there was one.
    @discardableResult
    public func deleteScan() throws -> Bool {
        try lock.withLock { _ in
            guard FileManager.default.fileExists(atPath: scanURL.path) else { return false }
            try FileManager.default.removeItem(at: scanURL)
            return true
        }
    }

    /// Date of the saved scan (only reads the header). `nil` if there is no index or it is unknown.
    public func lastScanDate() throws -> Date? {
        try lock.withLock { _ in
            guard let handle = FileHandle(forReadingAtPath: scanURL.path) else { return nil }
            defer { try? handle.close() }
            let header = try handle.read(upToCount: 40) ?? Data()
            return Self.scannedAt(header: header)
        }
    }

    static func scannedAt(header data: Data) -> Date? {
        data.withUnsafeBytes { raw in
            let version = raw.count >= 8 ? raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self) : 0
            guard raw.count >= 40, Array(raw[0..<4]) == magic,
                  version == currentVersion || version == fullWidthVersion else { return nil }
            let value = raw.loadUnaligned(fromByteOffset: 32, as: Double.self)
            return value == noDate ? nil : Date(timeIntervalSinceReferenceDate: value)
        }
    }

    // MARK: - History

    public func append(_ record: CleanupRecord) throws {
        try lock.withLock { _ in
            try ensureDirectory()
            // Cross-process lock (app and airy-mcp): exclusive read-modify-write.
            let fd = open(directory.appendingPathComponent("history.lock").path, O_RDWR | O_CREAT, 0o600)
            guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
            defer { close(fd) }
            guard flock(fd, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
            defer { flock(fd, LOCK_UN) }
            var records = try readHistory()
            records.append(record)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(records).write(to: historyURL, options: .atomic)
        }
    }

    public func history() throws -> [CleanupRecord] {
        try lock.withLock { _ in try readHistory() }
    }

    /// Only what was really freed: what was sent to the Trash does not count until it is emptied.
    public func totalFreed() throws -> Int64 {
        try history().filter { !$0.wentToTrash }.reduce(0) { $0 + $1.bytes }
    }

    private func readHistory() throws -> [CleanupRecord] {
        guard FileManager.default.fileExists(atPath: historyURL.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([CleanupRecord].self, from: Data(contentsOf: historyURL))
    }

    // MARK: - Iterative flattening

    static func flatten(_ result: ScanResult) -> FlatScan {
        var flat = FlatScan()
        flat.duration = result.duration
        flat.scannedAt = result.scannedAt
        flat.inaccessible = result.inaccessible
        let kinds = ContentKind.allCases
        let kindCount = kinds.count
        var kindIndex: [ContentKind: UInt8] = [:]
        for (i, k) in kinds.enumerated() { kindIndex[k] = UInt8(i) }

        // BFS queue: a child's index is always greater than its parent's.
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
            flat.kindBytes.append(contentsOf: node.kindBytes)
            flat.mtime.append(node.lastModified?.timeIntervalSinceReferenceDate ?? noDate)
            flat.descendantCount.append(Int64(node.descendantCount))
            flat.aggregatedCount.append(Int64(node.aggregatedCount))
            for child in node.children { queue.append((child, index)) }
        }
        return flat
    }

    // MARK: - Binary format

    /// The compact format (v4) or, if some value does not fit in it, the full-width one (v3).
    static func serialize(_ flat: FlatScan) -> Data {
        serializeCompact(flat) ?? serializeV3(flat)
    }

    /// Header: magic "DMIX", UInt32 version, UInt64 nodes, Double duration, UInt64 inaccessible;
    /// then fixed-width columns, string offsets (UInt64, n+1) and UTF-8 blobs.
    static func serializeV3(_ flat: FlatScan) -> Data {
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
        putValue(fullWidthVersion)
        putValue(UInt64(count))
        putValue(flat.duration)
        putValue(UInt64(flat.inaccessible.count))
        putValue(flat.scannedAt?.timeIntervalSinceReferenceDate ?? noDate)
        put(flat.parentIndex); put(flat.isDirectory); put(flat.kind)
        // Align to 8 bytes for the wide columns.
        while out.count % 8 != 0 { out.append(0) }
        put(flat.size); put(flat.mtime); put(flat.descendantCount)
        put(flat.aggregatedCount); put(flat.kindBytes)
        putStrings(flat.name)
        putStrings(flat.inaccessible)
        return out
    }


    /// Bit of `kindMask` meaning "a single kind, holding the whole `size`": no value is stored for it.
    private static let wholeSizeFlag: UInt16 = 1 << 15

    /// v4: the v3 header, then `parentIndex` (Int32), `isDirectory` and `kind` (UInt8), `kindMask` (UInt16: the
    /// kinds with bytes, plus `wholeSizeFlag`), padding to 8, `size` (Int64), `mtime` (Double), `descendantCount`
    /// and `aggregatedCount` (UInt32), padding to 8, the count of breakdown values (UInt64) and the values
    /// (Int64, in node order, one per mask bit unless `wholeSizeFlag`), then names and inaccessible paths as
    /// UInt32 offsets (n+1) and UTF-8 blobs. `nil` if a count, an offset or a breakdown does not fit.
    static func serializeCompact(_ flat: FlatScan) -> Data? {
        let count = flat.name.count
        let kindCount = ContentKind.count
        var masks: [UInt16] = []
        masks.reserveCapacity(count)
        var values: [Int64] = []
        var descendants: [UInt32] = [], aggregated: [UInt32] = []
        descendants.reserveCapacity(count)
        aggregated.reserveCapacity(count)
        for index in 0..<count {
            guard let d = UInt32(exactly: flat.descendantCount[index]),
                  let a = UInt32(exactly: flat.aggregatedCount[index]) else { return nil }
            descendants.append(d)
            aggregated.append(a)
            var mask: UInt16 = 0
            let base = index * kindCount
            for kind in 0..<kindCount where flat.kindBytes[base + kind] != 0 { mask |= 1 << kind }
            if mask.nonzeroBitCount == 1, flat.kindBytes[base + mask.trailingZeroBitCount] == flat.size[index] {
                mask |= wholeSizeFlag
            } else {
                for kind in 0..<kindCount where mask & (1 << kind) != 0 { values.append(flat.kindBytes[base + kind]) }
            }
            masks.append(mask)
        }
        func strings(_ list: [String]) -> (offsets: [UInt32], blob: [UInt8])? {
            var offsets: [UInt32] = [0]
            offsets.reserveCapacity(list.count + 1)
            var blob: [UInt8] = []
            for string in list {
                blob.append(contentsOf: string.utf8)
                guard let end = UInt32(exactly: blob.count) else { return nil }
                offsets.append(end)
            }
            return (offsets, blob)
        }
        guard let names = strings(flat.name), let inaccessible = strings(flat.inaccessible) else { return nil }

        var out = Data()
        out.reserveCapacity(count * 48 + values.count * 8 + names.blob.count)
        func put<T>(_ array: [T]) { array.withUnsafeBytes { out.append(contentsOf: $0) } }
        func putValue<T>(_ value: T) { withUnsafeBytes(of: value) { out.append(contentsOf: $0) } }
        func align() { while out.count % 8 != 0 { out.append(0) } }
        out.append(contentsOf: magic)
        putValue(currentVersion)
        putValue(UInt64(count))
        putValue(flat.duration)
        putValue(UInt64(flat.inaccessible.count))
        putValue(flat.scannedAt?.timeIntervalSinceReferenceDate ?? noDate)
        put(flat.parentIndex); put(flat.isDirectory); put(flat.kind); put(masks)
        align()
        put(flat.size); put(flat.mtime); put(descendants); put(aggregated)
        align()
        putValue(UInt64(values.count)); put(values)
        put(names.offsets); put(names.blob)
        put(inaccessible.offsets); put(inaccessible.blob)
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
            /// `n` strings: offsets (`Offset`, n+1) and their UTF-8 blob.
            func strings<Offset: FixedWidthInteger & BitwiseCopyable>(_ n: Int, _: Offset.Type = UInt64.self) -> [String]? {
                guard let offsets = take(Offset.self, n + 1), offsets[0] == 0 else { return nil }
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
            let version = raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
            guard version == currentVersion || version == fullWidthVersion || version == legacyVersion else { return nil }
            let headerSize = version == legacyVersion ? 32 : 40
            guard raw.count >= headerSize else { return nil }
            let countU = raw.loadUnaligned(fromByteOffset: 8, as: UInt64.self)
            let inaccU = raw.loadUnaligned(fromByteOffset: 24, as: UInt64.self)
            guard countU > 0, countU < 1 << 31, inaccU < 1 << 31 else { return nil }
            let count = Int(countU)
            let inaccessibleCount = Int(inaccU)
            var flat = FlatScan()
            flat.duration = raw.loadUnaligned(fromByteOffset: 16, as: Double.self)
            flat.version = version
            if version != legacyVersion {
                let value = raw.loadUnaligned(fromByteOffset: 32, as: Double.self)
                flat.scannedAt = value == noDate ? nil : Date(timeIntervalSinceReferenceDate: value)
            }
            pos = headerSize
            if version == currentVersion {
                guard let parents = take(Int32.self, count),
                      let dirs = take(UInt8.self, count),
                      let kinds = take(UInt8.self, count),
                      let masks = take(UInt16.self, count) else { return nil }
                pos = (pos + 7) & ~7
                guard let sizes = take(Int64.self, count),
                      let mtimes = take(Double.self, count),
                      let descendants = take(UInt32.self, count),
                      let aggregated = take(UInt32.self, count) else { return nil }
                pos = (pos + 7) & ~7
                guard let valueCount = take(UInt64.self, 1)?.first, valueCount <= UInt64(count * kindCount),
                      let values = take(Int64.self, Int(valueCount)) else { return nil }
                // The breakdown back at full width, value by value in node order.
                var kindBytes = [Int64](repeating: 0, count: count * kindCount)
                var next = 0
                for index in 0..<count {
                    let mask = masks[index]
                    let base = index * kindCount
                    if mask & wholeSizeFlag != 0 {
                        let kind = (mask & ~wholeSizeFlag).trailingZeroBitCount
                        guard (mask & ~wholeSizeFlag).nonzeroBitCount == 1, kind < kindCount else { return nil }
                        kindBytes[base + kind] = sizes[index]
                        continue
                    }
                    guard mask >> kindCount == 0 else { return nil }
                    var bits = mask
                    while bits != 0 {
                        guard next < values.count else { return nil }
                        kindBytes[base + bits.trailingZeroBitCount] = values[next]
                        next += 1
                        bits &= bits - 1
                    }
                }
                guard next == values.count,
                      let names = strings(count, UInt32.self),
                      let inaccessible = strings(inaccessibleCount, UInt32.self) else { return nil }
                flat.parentIndex = parents; flat.isDirectory = dirs; flat.kind = kinds
                flat.size = sizes; flat.mtime = mtimes
                flat.descendantCount = descendants.map { Int64($0) }
                flat.aggregatedCount = aggregated.map { Int64($0) }
                flat.kindBytes = kindBytes
                flat.name = names; flat.inaccessible = inaccessible
                return flat
            }
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
                kindBytes: KindBytes(flat.kindBytes[(i * kindCount)..<((i + 1) * kindCount)]),
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
        return ScanResult(root: nodes[0], inaccessible: flat.inaccessible, duration: flat.duration,
                          scannedAt: flat.scannedAt)
    }
}
