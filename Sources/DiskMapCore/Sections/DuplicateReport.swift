import Foundation

/// Last Duplicates result on disk (`AppPaths.duplicatesFile`): only paths, sizes and dates;
/// never the content fingerprints.
public enum DuplicateReport {
    public struct File: Codable, Sendable, Equatable {
        public struct Group: Codable, Sendable, Equatable {
            public let size: Int64, reclaimableBytes: Int64, keeper: String, copies: [String]
        }
        public let date: Date, complete: Bool, filesExamined: Int, groups: [Group]
    }

    /// JSON with snake_case keys, atomic write (temporary file + `rename`) and 0600 permissions.
    public static func save(_ result: DuplicateResult, to url: URL) throws {
        let file = File(date: result.date, complete: result.complete, filesExamined: result.filesExamined,
                        groups: result.groups.map {
                            File.Group(size: $0.size, reclaimableBytes: $0.wastedBytes, keeper: $0.keeper,
                                       copies: $0.copies.map(\.path))
                        })
        let data = try encoder.encode(file)
        let temporary = url.path + ".tmp"
        let fd = open(temporary, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary]) }
        var ok = fchmod(fd, 0o600) == 0
        if ok {
            ok = data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                    guard written > 0 else { return false }
                    offset += written
                }
                return true
            }
        }
        ok = ok && fsync(fd) == 0
        close(fd)
        guard ok, rename(temporary, url.path) == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
    }

    /// `nil` if it does not exist.
    public static func load(from url: URL) throws -> File? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try decoder.decode(File.self, from: Data(contentsOf: url))
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
