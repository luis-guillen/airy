import Foundation

/// Quién originó una operación. JSON: `{"type":"user"}` / `{"type":"agent","client":"claude-code"}`.
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
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Autor desconocido: \(other)")
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

/// Solo metadatos (rutas, tamaños, fechas, resultado): nunca contenido de archivos.
public struct OperationRecord: Codable, Sendable, Equatable {
    public var runID: UUID
    public var date: Date
    public var actor: OperationActor
    /// "clean" | "trash_paths" | "empty_trash" | "propose" | "show" | "rescan"
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
    public var proposedBy: String?

    public init(runID: UUID, date: Date, actor: OperationActor, action: String, itemID: String?,
                title: String, paths: [String], command: [String]?, dryRun: Bool, outcome: String,
                bytes: Int64, message: String?, proposedBy: String?) {
        self.runID = runID; self.date = date; self.actor = actor; self.action = action
        self.itemID = itemID; self.title = title; self.paths = paths; self.command = command
        self.dryRun = dryRun; self.outcome = outcome; self.bytes = bytes
        self.message = message; self.proposedBy = proposedBy
    }
}

/// Registro JSON Lines compartido entre la app y `airy-mcp`: cada registro se añade con una
/// única escritura `O_APPEND` bajo `flock`, de modo que dos procesos no se pisan.
public final class OperationLog: Sendable {
    private let file: URL

    public init(file: URL) {
        self.file = file
    }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    public func append(_ record: OperationRecord) throws {
        var line = try Self.encoder().encode(record)
        line.append(0x0A)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(file.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { flock(fd, LOCK_UN) }
        let ok = line.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let n = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if n < 0 { if errno == EINTR { continue }; return false }
                offset += n
            }
            return true
        }
        guard ok else { throw CocoaError(.fileWriteUnknown) }
    }

    /// Más recientes al final; las líneas ilegibles se saltan.
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
