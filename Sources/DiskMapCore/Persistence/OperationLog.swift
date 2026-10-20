import Foundation
import Synchronization

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
    /// Quién dijo proponerlo. Con `proposedVia` = `OperationContext.viaUnverifiedURL` es solo lo que afirmaba
    /// el enlace `airy://` (cualquier app o web puede abrir uno): no está verificado.
    public var proposedBy: String?
    /// Por dónde llegó la propuesta (`"url-unverified"`), o `nil`.
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

/// Registro JSON Lines compartido entre la app y `airy-mcp`: cada registro se añade con una
/// única escritura `O_APPEND` bajo `flock`, de modo que dos procesos no se pisan. Una línea a medias
/// (escritura cortada, proceso matado) nunca se come la siguiente: antes de escribir se mira el último
/// byte y, si no es `\n`, se cierra esa línea; una escritura que falla se deshace (`ftruncate`).
/// Cada fallo al escribir queda además pendiente en `takeWriteFailure()` para que quien llama lo diga.
public final class OperationLog: Sendable {
    typealias Writer = @Sendable (Int32, UnsafeRawPointer, Int) -> Int

    private let file: URL
    private let writer: Writer
    private let failure = Mutex<String?>(nil)

    public convenience init(file: URL) {
        self.init(file: file, writer: { fd, bytes, count in Darwin.write(fd, bytes, count) })
    }

    /// `writer`: solo para pruebas (simular escrituras cortas o fallidas).
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
            reportFailure("no se pudo anotar «\(record.title)» en el registro de operaciones (\(error.localizedDescription))")
            throw error
        }
    }

    /// Anota un fallo de auditoría (del registro o del historial) para avisar de él.
    public func reportFailure(_ message: String) {
        failure.withLock { $0 = message }
    }

    /// Último fallo de auditoría sin avisar (y lo olvida), o `nil`.
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
            // Nada a medias: se vuelve a la longitud de antes (bajo el mismo cerrojo).
            _ = ftruncate(fd, original)
            throw POSIXError(POSIXErrorCode(rawValue: failedErrno) ?? .EIO)
        }
    }

    private static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

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
