import Foundation
import Synchronization

/// Who originated an operation. JSON: `{"type":"user"}` / `{"type":"agent","client":"claude-code"}`.
public enum OperationActor: Codable, Sendable, Equatable {
    case user
    case agent(client: String)

    private enum CodingKeys: String, CodingKey { case type, client }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "user": self = .user
        case "agent": self = .agent(client: try c.decode(String.self, forKey: .client))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown actor: \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .user:
            try c.encode("user", forKey: .type)
        case .agent(let client):
            try c.encode("agent", forKey: .type)
            try c.encode(client, forKey: .client)
        }
    }
}

/// Metadata only (paths, sizes, dates, result): never file contents.
public struct OperationRecord: Codable, Sendable, Equatable {
    public var runID: UUID
    public var date: Date
    public var actor: OperationActor
    /// "clean" | "trash_paths" | "empty_trash" | "propose" | "show" | "rescan" | "uninstall" | "remove_broken_links"
    public var action: String
    public var itemID: String?
    public var title: String
    public var paths: [String]
    public var command: [String]?
    public var dryRun: Bool
    /// "freed" | "moved_to_trash" | "partial" | "blocked" | "failed" | "would_trash" | "would_run" | "pending_user" | "requested"
    public var outcome: String
    public var bytes: Int64
    public var message: String?
    /// Who claimed to propose it. With `proposedVia` = `OperationContext.viaUnverifiedURL` it is only what the
    /// `airy://` link claimed (any app or website can open one): it is not verified.
    public var proposedBy: String?
    /// Where the proposal came from (`"url-unverified"`), or `nil`.
    public var proposedVia: String?

    public init(runID: UUID, date: Date, actor: OperationActor, action: String, itemID: String?,
                title: String, paths: [String], command: [String]?, dryRun: Bool, outcome: String,
                bytes: Int64, message: String?, proposedBy: String?, proposedVia: String? = nil) {
        self.runID = runID; self.date = date; self.actor = actor; self.action = action
        self.itemID = itemID; self.title = title; self.paths = paths; self.command = command
        self.dryRun = dryRun; self.outcome = outcome; self.bytes = bytes
        self.message = message; self.proposedBy = proposedBy; self.proposedVia = proposedVia
    }
}

/// JSON Lines log shared between the app and `airy-mcp`: each record is appended with a
/// single `O_APPEND` write under `flock`, so two processes never clobber each other. A half-written line
/// (cut-off write, killed process) never swallows the next one: before writing, the last
/// byte is checked and, if it is not `\n`, that line is closed; a failed write is undone (`ftruncate`).
/// Every write failure also stays pending in `takeWriteFailure()` so that the caller can report it.
public final class OperationLog: Sendable {
    typealias Writer = @Sendable (Int32, UnsafeRawPointer, Int) -> Int

    private let file: URL
    private let writer: Writer
    private let failure = Mutex<String?>(nil)

    public convenience init(file: URL) {
        self.init(file: file, writer: { fd, bytes, count in Darwin.write(fd, bytes, count) })
    }

    /// `writer`: tests only (to simulate short or failed writes).
    init(file: URL, writer: @escaping Writer) {
        self.file = file
        self.writer = writer
    }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    public func append(_ record: OperationRecord) throws {
        do {
            try write(record)
        } catch {
            reportFailure(String(localized: "could not record “\(record.title)” in the operation log (\(error.localizedDescription))", bundle: .airyCore))
            throw error
        }
    }

    /// Records an audit failure (from the log or the history) to warn about it.
    public func reportFailure(_ message: String) {
        failure.withLock { $0 = message }
    }

    /// Last unreported audit failure (and forgets it), or `nil`.
    public func takeWriteFailure() -> String? {
        failure.withLock { value in defer { value = nil }; return value }
    }

    private func write(_ record: OperationRecord) throws {
        let body = try Self.encoder().encode(record)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(file.path, O_RDWR | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { throw Self.posixError() }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw Self.posixError() }
        defer { flock(fd, LOCK_UN) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw Self.posixError() }
        let original = info.st_size
        var line = Data()
        if original > 0 {
            var last: UInt8 = 0
            guard pread(fd, &last, 1, original - 1) == 1 else { throw Self.posixError() }
            if last != 0x0A { line.append(0x0A) }
        }
        line.append(body)
        line.append(0x0A)
        let failedErrno: Int32? = line.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = writer(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    return errno
                }
                if n == 0 { return EIO }
                offset += n
            }
            return nil
        }
        if let failedErrno {
            // Nothing half-done: go back to the previous length (under the same lock).
            _ = ftruncate(fd, original)
            throw POSIXError(POSIXErrorCode(rawValue: failedErrno) ?? .EIO)
        }
    }

    private static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

    /// Empties the log in place (truncated under the same lock as `append`, so a concurrent write from `airy-mcp`
    /// lands whole, before or after). Only Airy's own file: nothing else is touched.
    public func clear() throws {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let fd = open(file.path, O_RDWR)
        guard fd >= 0 else { throw Self.posixError() }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw Self.posixError() }
        defer { flock(fd, LOCK_UN) }
        guard ftruncate(fd, 0) == 0 else { throw Self.posixError() }
    }

    /// Most recent at the end; unreadable lines are skipped.
    public func records(limit: Int? = nil) throws -> [OperationRecord] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let data: Data
        let fd = open(file.path, O_RDONLY)
        guard fd >= 0 else { throw CocoaError(.fileReadNoSuchFile) }
        defer { close(fd) }
        flock(fd, LOCK_SH)
        defer { flock(fd, LOCK_UN) }
        data = try FileHandle(fileDescriptor: dup(fd), closeOnDealloc: true).readToEnd() ?? Data()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var records = data.split(separator: 0x0A, omittingEmptySubsequences: true).compactMap {
            try? decoder.decode(OperationRecord.self, from: Data($0))
        }
        if let limit, limit >= 0, records.count > limit { records = Array(records.suffix(limit)) }
        return records
    }

    public func exportJSON() throws -> Data {
        struct Export: Encodable { var exportedAt: Date; var records: [OperationRecord] }
        let encoder = Self.encoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(Export(exportedAt: Date(), records: try records()))
    }
}
