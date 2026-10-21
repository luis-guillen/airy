import Darwin
import Foundation
import Synchronization

/// Free space of the startup volume, or `nil` if it cannot be read.
public protocol FreeSpaceProbing: Sendable {
    func freeBytes() -> Int64?
}

public struct VolumeFreeSpace: FreeSpaceProbing {
    private let home: String
    public init(home: String = NSHomeDirectory()) { self.home = home }
    public func freeBytes() -> Int64? { SystemProbes.volumeCapacity(home: home)?.available }
}

/// Cumulative bytes each process has written to disk (`pid ⇒ (name, bytes)`), or `nil` if unknown.
public protocol DiskWriteSampling: Sendable {
    func bytesWritten() -> [Int32: (name: String, bytes: UInt64)]?
}

/// libproc's `ri_diskio_byteswritten` per process (processes that cannot be inspected are skipped).
public struct LibprocDiskWrites: DiskWriteSampling {
    public init() {}

    public func bytesWritten() -> [Int32: (name: String, bytes: UInt64)]? {
        let needed = proc_listallpids(nil, 0)
        guard needed > 0 else { return nil }
        var pids = [Int32](repeating: 0, count: Int(needed) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard count > 0 else { return nil }
        var result: [Int32: (name: String, bytes: UInt64)] = [:]
        for pid in pids.prefix(Int(count)) where pid > 0 {
            var info = rusage_info_v4()
            let status = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            guard status == 0 else { continue }
            var nameBuffer = [CChar](repeating: 0, count: 256)
            let length = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
            let name = length > 0 ? String(cString: nameBuffer) : "pid \(pid)"
            result[pid] = (name, info.ri_diskio_byteswritten)
        }
        return result
    }
}

/// A file that was deleted while a process still has it open: its space only comes back when the process closes it.
public struct DeletedOpenFile: Codable, Sendable, Equatable {
    public var process: String
    public var pid: Int32
    public var bytes: Int64
    public var path: String
}

/// A process that wrote a lot to disk in the moments after the drop was noticed.
public struct DiskWriter: Codable, Sendable, Equatable {
    public var process: String
    public var pid: Int32
    public var bytesWritten: Int64
}

/// What Airy saw when free space dropped fast. Read-only: it never acts on it.
public struct SpaceDropSnapshot: Codable, Sendable, Equatable {
    public var detectedAt: Date
    public var droppedBytes: Int64
    public var seconds: TimeInterval
    public var freeBefore: Int64
    public var freeAfter: Int64
    /// Largest first; empty if there were none or they could not be listed (`filesKnown`).
    public var deletedOpenFiles: [DeletedOpenFile]
    public var filesKnown: Bool
    public var topWriters: [DiskWriter]

    public var minutes: Int { max(1, Int((seconds / 60).rounded())) }

    /// "Free space dropped 18 GB in 6 min — biggest open deleted file: Docker (12 GB)".
    public var message: String {
        let dropped = Format.bytes(droppedBytes)
        let minutes = self.minutes
        if let biggest = deletedOpenFiles.first {
            return String(localized: "Free space dropped \(dropped) in \(minutes) min — biggest open deleted file: \(biggest.process) (\(Format.bytes(biggest.bytes)))", bundle: .airyCore)
        }
        if let writer = topWriters.first {
            return String(localized: "Free space dropped \(dropped) in \(minutes) min — writing the most: \(writer.process)", bundle: .airyCore)
        }
        return String(localized: "Free space dropped \(dropped) in \(minutes) min.", bundle: .airyCore)
    }
}

/// Pure detection: samples of free space within `window`; a drop larger than `threshold` from the highest sample in
/// the window fires once, then waits `cooldown` before it can fire again.
public struct SpaceDropDetector: Sendable {
    public static let threshold: Int64 = 10 * 1_000_000_000
    public static let window: TimeInterval = 600
    public static let cooldown: TimeInterval = 1_800

    public struct Drop: Sendable, Equatable {
        public var dropped: Int64
        public var seconds: TimeInterval
        public var freeBefore: Int64
        public var freeAfter: Int64
    }

    private var samples: [(date: Date, free: Int64)] = []
    private var lastAlert: Date?
    let threshold: Int64, window: TimeInterval, cooldown: TimeInterval

    public init(threshold: Int64 = SpaceDropDetector.threshold, window: TimeInterval = SpaceDropDetector.window,
                cooldown: TimeInterval = SpaceDropDetector.cooldown) {
        self.threshold = threshold; self.window = window; self.cooldown = cooldown
    }

    public mutating func observe(_ free: Int64, at now: Date) -> Drop? {
        let window = self.window
        samples.removeAll { now.timeIntervalSince($0.date) > window || $0.date > now }
        defer { samples.append((now, free)) }
        guard let peak = samples.max(by: { $0.free < $1.free }), peak.free - free > threshold else { return nil }
        if let lastAlert, now.timeIntervalSince(lastAlert) < cooldown { return nil }
        lastAlert = now
        let drop = Drop(dropped: peak.free - free, seconds: now.timeIntervalSince(peak.date), freeBefore: peak.free,
                        freeAfter: free)
        samples.removeAll()
        return drop
    }
}

/// Last snapshot (`space-drop.json` in Airy's data folder), shared with `airy-mcp`.
public final class SpaceDropStore: Sendable {
    public static let fileName = "space-drop.json"
    /// `get_disk_summary` only reports a drop this recent.
    public static let recentWindow: TimeInterval = 86_400

    private let url: URL
    private let lock = Mutex(())

    public init(directory: URL) { url = directory.appendingPathComponent(Self.fileName) }

    public func save(_ snapshot: SpaceDropSnapshot) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        try lock.withLock { _ in
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
    }

    public func load() -> SpaceDropSnapshot? {
        lock.withLock { _ in
            guard let data = try? Data(contentsOf: url) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(SpaceDropSnapshot.self, from: data)
        }
    }

    /// The last snapshot if it is younger than `recentWindow`.
    public func recent(now: Date = Date()) -> SpaceDropSnapshot? {
        guard let snapshot = load(), now.timeIntervalSince(snapshot.detectedAt) <= Self.recentWindow else { return nil }
        return snapshot
    }
}

/// Checks free space at most once per `interval` while the app runs (at `.background`, sleeping in between). On a
/// fast drop it takes one snapshot: deleted-but-open files (`lsof -nP +L1` through the runner, with a time limit) and,
/// if cheap, the processes writing the most over a couple of seconds. It never acts.
public final class SpaceDropMonitor: Sendable {
    public static let interval: Duration = .seconds(60)
    public static let lsofTimeout: TimeInterval = 10
    public static let maxFiles = 10
    public static let maxWriters = 5

    private let probe: any FreeSpaceProbing
    private let runner: any CommandRunning
    private let processListing: any ProcessListing
    private let writes: (any DiskWriteSampling)?
    private let writeWindow: Duration
    private let store: SpaceDropStore?
    private let detector: Mutex<SpaceDropDetector>

    public init(probe: any FreeSpaceProbing = VolumeFreeSpace(), runner: any CommandRunning,
                processListing: any ProcessListing = LibprocListing(),
                writes: (any DiskWriteSampling)? = LibprocDiskWrites(), writeWindow: Duration = .seconds(2),
                store: SpaceDropStore?, detector: SpaceDropDetector = SpaceDropDetector()) {
        self.probe = probe; self.runner = runner; self.processListing = processListing
        self.writes = writes; self.writeWindow = writeWindow; self.store = store
        self.detector = Mutex(detector)
    }

    /// One check. Returns (and stores) a snapshot when a drop fires.
    public func check(now: Date = Date()) async -> SpaceDropSnapshot? {
        guard let free = probe.freeBytes() else { return nil }
        guard let drop = detector.withLock({ $0.observe(free, at: now) }) else { return nil }
        let start = ContinuousClock().now
        let before = writes?.bytesWritten()
        let names = await TimeBudget.run(TimeBudget.processScan, { [processListing] in processListing.processes() }) ?? nil
        var pidNames: [Int32: String] = [:]
        for process in names ?? [] { pidNames[process.pid] = process.name }
        let files = await Self.deletedOpenFiles(runner: runner, names: pidNames)
        var writers: [DiskWriter] = []
        if let before, let writes {
            let remaining = writeWindow - (ContinuousClock().now - start)
            if remaining > .zero { try? await Task.sleep(for: remaining) }
            if let after = writes.bytesWritten() { writers = Self.topWriters(before: before, after: after) }
        }
        let snapshot = SpaceDropSnapshot(
            detectedAt: now, droppedBytes: drop.dropped, seconds: drop.seconds, freeBefore: drop.freeBefore,
            freeAfter: drop.freeAfter, deletedOpenFiles: files ?? [], filesKnown: files != nil, topWriters: writers)
        try? store?.save(snapshot)
        return snapshot
    }

    /// Checks every `interval` until the task is cancelled; `onDrop` runs for each snapshot.
    public func run(interval: Duration = SpaceDropMonitor.interval,
                    onDrop: @escaping @Sendable (SpaceDropSnapshot) async -> Void) async {
        while !Task.isCancelled {
            if let snapshot = await check() { await onDrop(snapshot) }
            try? await Task.sleep(for: interval)
        }
    }

    static func topWriters(before: [Int32: (name: String, bytes: UInt64)],
                           after: [Int32: (name: String, bytes: UInt64)]) -> [DiskWriter] {
        var writers: [DiskWriter] = []
        for (pid, now) in after {
            guard let then = before[pid], now.bytes > then.bytes else { continue }
            let written = now.bytes - then.bytes
            guard written > 0, written < UInt64(Int64.max) else { continue }
            writers.append(DiskWriter(process: now.name, pid: pid, bytesWritten: Int64(written)))
        }
        return Array(writers.sorted { $0.bytesWritten != $1.bytesWritten ? $0.bytesWritten > $1.bytesWritten : $0.pid < $1.pid }
            .prefix(maxWriters))
    }

    /// `lsof -nP +L1` (files with no links left) parsed; `nil` if lsof is missing, fails or runs out of time.
    static func deletedOpenFiles(runner: any CommandRunning, names: [Int32: String]) async -> [DeletedOpenFile]? {
        let arguments = ["-nP", "+L1"]
        guard let lsof = await runner.resolve("lsof"),
              CommandPolicy.refusal(executable: lsof, arguments: arguments) == nil,
              let output = try? await runner.run(lsof, arguments, timeout: lsofTimeout) else { return nil }
        // lsof exits with 1 when it finds nothing.
        guard output.status == 0 || (output.status == 1 && output.stdout.isEmpty) else { return nil }
        return parseLsof(output.stdout, names: names)
    }

    /// Regular files with `NLINK` 0, one per (process, inode), largest first.
    static func parseLsof(_ text: String, names: [Int32: String]) -> [DeletedOpenFile] {
        var seen = Set<String>()
        var files: [DeletedOpenFile] = []
        for line in text.split(whereSeparator: \.isNewline).dropFirst() {
            let columns = line.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: true).map(String.init)
            guard columns.count == 10, columns[4] == "REG", let pid = Int32(columns[1]),
                  let bytes = Int64(columns[6]), columns[7] == "0", bytes > 0 else { continue }
            guard seen.insert("\(pid):\(columns[8])").inserted else { continue }
            let command = columns[0].replacingOccurrences(of: "\\x20", with: " ")
            files.append(DeletedOpenFile(process: names[pid] ?? command, pid: pid, bytes: bytes,
                                         path: columns[9].trimmingCharacters(in: .whitespaces)))
        }
        return Array(files.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.pid < $1.pid }.prefix(maxFiles))
    }
}
