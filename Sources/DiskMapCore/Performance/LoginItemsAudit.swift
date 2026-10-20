import Foundation

/// Elemento de inicio (LaunchAgent) cuyo programa ya no existe. Solo se informa.
public struct BrokenLoginItem: Sendable, Equatable, Identifiable {
    public var id: String { plistPath }
    public var label: String
    public var plistPath: String
    public var missingProgram: String

    public init(label: String, plistPath: String, missingProgram: String) {
        self.label = label
        self.plistPath = plistPath
        self.missingProgram = missingProgram
    }
}

/// Auditoría de solo lectura: nunca borra, mueve ni descarga nada.
public enum LoginItemsAudit {
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!

    private static let maxPlistBytes = 1_048_576

    public static func standardDirectories(home: String = NSHomeDirectory()) -> [String] {
        [home + "/Library/LaunchAgents", "/Library/LaunchAgents"]
    }

    /// Lee cada *.plist (≤ 1 MB); programa = Program ?? ProgramArguments[0]; solo rutas absolutas;
    /// bajo /Volumes/<X> con <X> inexistente (disco desmontado) no cuenta.
    public static func broken(
        in directories: [String],
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [BrokenLoginItem] {
        let fm = FileManager.default
        var result: [BrokenLoginItem] = []
        for dir in directories {
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for name in names.sorted() where name.hasSuffix(".plist") {
                let path = (dir as NSString).appendingPathComponent(name)
                guard let data = readBoundedRegularFile(path),
                      let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                      let dict = obj as? [String: Any] else { continue }
                let program: String?
                if let p = dict["Program"] as? String, !p.isEmpty {
                    program = p
                } else if let args = dict["ProgramArguments"] as? [String], let first = args.first {
                    program = first
                } else {
                    program = nil
                }
                guard let program, program.hasPrefix("/") else { continue }
                if isOnUnmountedVolume(program, fileExists: fileExists) { continue }
                guard !fileExists(program) else { continue }
                let label = (dict["Label"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? (name as NSString).deletingPathExtension
                result.append(BrokenLoginItem(label: label, plistPath: path, missingProgram: program))
            }
        }
        return result
    }

    /// Solo ficheros regulares (se siguen enlaces simbólicos con stat, pero se rechazan FIFO y
    /// dispositivos); lectura acotada a maxPlistBytes. Nil si no es válido o supera el límite.
    private static func readBoundedRegularFile(_ path: String) -> Data? {
        var st = stat()
        guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG,
              st.st_size <= maxPlistBytes,
              let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxPlistBytes + 1),
              data.count <= maxPlistBytes else { return nil }
        return data
    }

    private static func isOnUnmountedVolume(_ program: String, fileExists: (String) -> Bool) -> Bool {
        let parts = program.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0] == "Volumes" else { return false }
        return !fileExists("/Volumes/" + parts[1])
    }
}
