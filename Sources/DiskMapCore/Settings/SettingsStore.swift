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

    /// Lo que se puede rescatar de un `settings.json` ilegible (lectura tolerante, clave a clave).
    public func salvage() -> SettingsSalvage {
        guard let data = try? Data(contentsOf: file) else { return SettingsSalvage() }
        return SettingsSalvage(data: data)
    }

    /// Aparta el fichero ilegible como `settings.unreadable-<yyyyMMdd-HHmmss>.json` y escribe ajustes nuevos
    /// con lo que se pudo rescatar de él (`SettingsSalvage.settings`): la lista «Proteger esto» se conserva
    /// si se puede leer y, si no se rescata todo lo necesario, los agentes quedan apagados (falla cerrado).
    @discardableResult
    public func resetUnreadable() throws -> SettingsReset {
        let salvage = salvage()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let dir = file.deletingLastPathComponent()
        var backup: URL?
        if FileManager.default.fileExists(atPath: file.path) {
            var aside = dir.appendingPathComponent("settings.unreadable-\(stamp).json")
            var n = 2
            while FileManager.default.fileExists(atPath: aside.path) {
                aside = dir.appendingPathComponent("settings.unreadable-\(stamp)-\(n).json")
                n += 1
            }
            try FileManager.default.moveItem(at: file, to: aside)
            backup = aside
        }
        let settings = salvage.settings
        try save(settings)
        return SettingsReset(settings: settings, backup: backup, salvage: salvage)
    }
}

/// Lectura tolerante de un `settings.json` que no se puede cargar entero (corrupto o de una versión
/// más nueva): cada clave se rescata solo si tiene el tipo esperado.
public struct SettingsSalvage: Sendable, Equatable {
    public var protectedPaths: [String]?
    public var agentsEnabled: Bool?
    public var mode: CleanupMode?
    public var profiles: Set<UsageProfile>?

    public init(protectedPaths: [String]? = nil, agentsEnabled: Bool? = nil, mode: CleanupMode? = nil,
                profiles: Set<UsageProfile>? = nil) {
        self.protectedPaths = protectedPaths; self.agentsEnabled = agentsEnabled
        self.mode = mode; self.profiles = profiles
    }

    public init(data: Data) {
        self.init()
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let list = object["protectedPaths"] as? [Any], list.allSatisfy({ $0 is String }) {
            protectedPaths = list.compactMap { $0 as? String }
        }
        // `NSNumber` también acepta 0/1: solo vale un booleano JSON de verdad.
        if let value = object["agentsEnabled"] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() {
            agentsEnabled = value.boolValue
        }
        if let raw = object["mode"] as? String { mode = CleanupMode(rawValue: raw) }
        if let names = object["profiles"] as? [Any] {
            profiles = Set(names.compactMap { ($0 as? String).flatMap(UsageProfile.init(rawValue:)) })
        }
    }

    /// `true` si se recuperó la lista «Proteger esto» (aunque esté vacía).
    public var recoveredProtectedPaths: Bool { protectedPaths != nil }

    /// Ajustes nuevos: lo rescatado sobre los valores por defecto. Los agentes solo siguen activos si el
    /// fichero lo decía y además se recuperó la lista «Proteger esto»; si no, apagados.
    public var settings: AirySettings {
        var s = AirySettings.defaults
        s.protectedPaths = protectedPaths ?? []
        s.agentsEnabled = agentsEnabled == true && protectedPaths != nil
        if let mode { s.mode = mode }
        if let profiles { s.profiles = profiles }
        return s
    }
}

/// Resultado de «Restablecer ajustes».
public struct SettingsReset: Sendable, Equatable {
    public let settings: AirySettings
    /// Dónde quedó apartado el fichero ilegible (`nil` si no había fichero).
    public let backup: URL?
    public let salvage: SettingsSalvage

    /// Texto para el usuario tras restablecer: qué se conservó y qué no.
    public var message: String {
        var parts = ["Ajustes restablecidos."]
        let n = settings.protectedPaths.count
        if salvage.recoveredProtectedPaths {
            parts.append(n == 0 ? "Tu lista «Proteger esto» estaba vacía."
                         : "Se conservó tu lista «Proteger esto» (\(n) \(n == 1 ? "ruta" : "rutas")).")
        } else {
            parts.append("No se pudo recuperar tu lista «Proteger esto»: ahora está vacía. Vuelve a proteger lo que quieras en Ajustes.")
        }
        if !settings.agentsEnabled {
            parts.append("Los agentes quedan desactivados hasta que los actives en Ajustes › Agentes.")
        }
        if let backup { parts.append("El fichero anterior se guardó como \(backup.lastPathComponent).") }
        return parts.joined(separator: " ")
    }
}
