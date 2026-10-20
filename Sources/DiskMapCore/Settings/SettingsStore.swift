import Foundation

public struct SettingsStore: Sendable {
    public let file: URL

    public init(file: URL) { self.file = file }

    public func load() -> SettingsLoad {
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return .missing
        } catch {
            return .unreadable("No se pudo leer settings.json: \(error.localizedDescription)")
        }
        struct Probe: Decodable { var version: Int? }
        do {
            if let v = try JSONDecoder().decode(Probe.self, from: data).version, v > AirySettings.currentVersion {
                return .unreadable("settings.json es de una versión más nueva (\(v)).")
            }
            return .loaded(try JSONDecoder().decode(AirySettings.self, from: data))
        } catch {
            return .unreadable("settings.json no es válido.")
        }
    }

    public func save(_ settings: AirySettings) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(settings).write(to: file, options: .atomic)
    }

    /// Aparta el fichero ilegible como `settings.unreadable-<yyyyMMdd-HHmmss>.json` y escribe los valores por defecto.
    @discardableResult
    public func resetUnreadable() throws -> AirySettings {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let dir = file.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: file.path) {
            var aside = dir.appendingPathComponent("settings.unreadable-\(stamp).json")
            var n = 2
            while FileManager.default.fileExists(atPath: aside.path) {
                aside = dir.appendingPathComponent("settings.unreadable-\(stamp)-\(n).json")
                n += 1
            }
            try FileManager.default.moveItem(at: file, to: aside)
        }
        try save(.defaults)
        return .defaults
    }
}
