import AppKit
import Foundation

/// Estado del sistema que necesitan la detección y la ejecución de limpiezas (falsificable en pruebas).
public protocol SystemProbing: Sendable {
    func runningBundleIDs() -> Set<String>
    func hasFullDiskAccess() -> Bool
    func trashSize() -> Int64
    /// Borra definitivamente el contenido de `~/.Trash`. Devuelve los bytes liberados.
    /// Si no hay permiso para leerla, recurre a Finder ("empty trash"), que vacía las papeleras
    /// de **todos** los volúmenes: la interfaz debe avisarlo antes de confirmar.
    func emptyTrash() async throws -> Int64
    func localSnapshots() async -> [String]
}

/// Tamaño asignado (`st_blocks * 512`) con `lstat`, sin seguir enlaces simbólicos
/// y contando una sola vez los hard links.
public enum AllocatedSize {
    /// `nil` si la ruta no existe o no se puede leer con `lstat`.
    public static func of(_ path: String) -> Int64? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        var seen = Set<HardLinkKey>()
        return walk(path, info, &seen)
    }

    private struct HardLinkKey: Hashable { let device: dev_t; let inode: ino_t }

    private static func walk(_ path: String, _ info: stat, _ seen: inout Set<HardLinkKey>) -> Int64 {
        let type = info.st_mode & S_IFMT
        var total: Int64 = 0
        if type == S_IFREG, info.st_nlink > 1 {
            if seen.insert(HardLinkKey(device: info.st_dev, inode: info.st_ino)).inserted {
                total = Int64(info.st_blocks) * 512
            }
        } else {
            total = Int64(info.st_blocks) * 512
        }
        guard type == S_IFDIR, let dir = opendir(path) else { return total }
        defer { closedir(dir) }
        while let entry = readdir(dir) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            if name == "." || name == ".." { continue }
            let child = path == "/" ? "/" + name : path + "/" + name
            var childInfo = stat()
            guard lstat(child, &childInfo) == 0 else { continue }
            total += walk(child, childInfo, &seen)
        }
        return total
    }
}

public struct SystemProbes: SystemProbing {
    private let home: String
    private let runner: any CommandRunning
    private let allowFinderFallback: Bool

    /// `allowFinderFallback`: si no hay permiso para `~/.Trash`, vaciar con Finder (afecta a la Papelera real).
    public init(home: String = NSHomeDirectory(), runner: any CommandRunning = ProcessRunner(),
                allowFinderFallback: Bool = true) {
        self.home = home
        self.runner = runner
        self.allowFinderFallback = allowFinderFallback
    }

    private var trashPath: String { (home as NSString).appendingPathComponent(".Trash") }

    public func runningBundleIDs() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    public func hasFullDiskAccess() -> Bool {
        Self.checkFullDiskAccess(candidates: [
            (home as NSString).appendingPathComponent("Library/Containers/com.apple.stocks"),
            (home as NSString).appendingPathComponent("Library/Safari"),
        ])
    }

    /// Sin acceso si alguna carpeta protegida da `EPERM`/`EACCES` al listarla; con acceso si alguna se lee.
    /// Si ninguna existe no se puede saber y se asume que sí.
    static func checkFullDiskAccess(candidates: [String]) -> Bool {
        for path in candidates {
            if let dir = opendir(path) {
                closedir(dir)
                return true
            }
            if errno == EPERM || errno == EACCES { return false }
        }
        return true
    }

    public func trashSize() -> Int64 {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: trashPath) else { return 0 }
        return names.reduce(0) { $0 + (AllocatedSize.of(trashPath + "/" + $1) ?? 0) }
    }

    public static let finderTimeout: TimeInterval = 60

    public func emptyTrash() async throws -> Int64 {
        // Nunca a través de un enlace: `~/.Trash` debe ser una carpeta real del usuario actual.
        var info = stat()
        if lstat(trashPath, &info) != 0 {
            if errno == ENOENT { return 0 }
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: trashPath])
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else {
            throw CocoaError(.fileReadUnknown, userInfo: [
                NSFilePathErrorKey: trashPath,
                NSLocalizedDescriptionKey: "La Papelera no es una carpeta normal del usuario; no se toca.",
            ])
        }
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: trashPath)
        } catch let error as NSError where Self.isPermissionError(error) {
            return try await emptyWithFinder()
        }
        var freed: Int64 = 0
        for name in names {
            let path = trashPath + "/" + name
            let size = AllocatedSize.of(path) ?? 0
            do {
                // `removeItem` sobre la entrada: un enlace se borra como enlace, nunca su destino.
                try FileManager.default.removeItem(atPath: path)
                freed += size
            } catch let error as NSError where Self.isPermissionError(error) {
                return freed + (try await emptyWithFinder())
            }
        }
        return freed
    }

    private static func isPermissionError(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain,
           [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(error.code) { return true }
        let posix = (error.userInfo[NSUnderlyingErrorKey] as? NSError) ?? error
        return posix.domain == NSPOSIXErrorDomain && (posix.code == Int(EPERM) || posix.code == Int(EACCES))
    }

    /// Vacía con Finder (todas las papeleras de todos los volúmenes), con tiempo máximo.
    private func emptyWithFinder() async throws -> Int64 {
        guard allowFinderFallback else {
            throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: trashPath])
        }
        let before = Self.availableCapacity(home: home)
        let output = try await runner.run(
            "/usr/bin/osascript", ["-e", "tell application \"Finder\" to empty trash"],
            timeout: Self.finderTimeout)
        guard output.status == 0 else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [
                NSLocalizedDescriptionKey: "Finder no pudo vaciar la Papelera.",
            ])
        }
        return max(0, Self.availableCapacity(home: home) - before)
    }

    public func localSnapshots() async -> [String] {
        guard let output = try? await runner.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"], timeout: 30),
              output.status == 0 else { return [] }
        return Self.parseSnapshots(output.stdout)
    }

    static func parseSnapshots(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Snapshots for") }
    }

    /// Espacio disponible (`volumeAvailableCapacityForImportantUsage`) del volumen que contiene `home`.
    public static func availableCapacity(home: String) -> Int64 {
        let values = try? URL(fileURLWithPath: home)
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }
}
