import Foundation

public enum MigrationResult: Sendable, Equatable {
    case notNeeded, migrated(copied: [String]), failed(String)
}

/// Copia (nunca mueve ni borra) los datos de DiskMap a la carpeta de Airy, una sola vez.
public enum DataMigration {
    private struct Failure: Error { let message: String }

    public static func migrateIfNeeded(_ paths: AppPaths) -> MigrationResult {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: paths.support, withIntermediateDirectories: true)
        } catch { return .failed(error.localizedDescription) }

        let lockPath = paths.support.appendingPathComponent(".migration.lock").path
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return .failed(String(cString: strerror(errno))) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { return .failed(String(cString: strerror(errno))) }
        defer { flock(fd, LOCK_UN) }

        do {
            removePartials(in: paths.support)
            if fm.fileExists(atPath: paths.migrationMarker.path) { return .notNeeded }
            guard let legacy = paths.legacySupport, fm.fileExists(atPath: legacy.path) else {
                try writeMarker(paths)
                return .notNeeded
            }
            var copied: [String] = []
            let children = try fm.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent != ".DS_Store" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for child in children {
                let name = child.lastPathComponent
                let final = paths.support.appendingPathComponent(name)
                if fm.fileExists(atPath: final.path) { continue }
                let partial = paths.support.appendingPathComponent(".\(name).partial-\(UUID().uuidString)")
                try fm.copyItem(at: child, to: partial)
                if rename(partial.path, final.path) != 0 {
                    let message = String(cString: strerror(errno))
                    try? fm.removeItem(at: partial)
                    throw Failure(message: message)
                }
                copied.append(name)
            }
            try writeMarker(paths)
            return .migrated(copied: copied)
        } catch let failure as Failure {
            return .failed(failure.message)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Copia de `legacy` a `current` las claves que falten en `current`; devuelve las copiadas.
    public static func migrateDefaults(from legacy: UserDefaults?, to current: UserDefaults, keys: [String]) -> [String] {
        guard let legacy else { return [] }
        var copied: [String] = []
        for key in keys where current.object(forKey: key) == nil {
            if let value = legacy.object(forKey: key) {
                current.set(value, forKey: key)
                copied.append(key)
            }
        }
        return copied
    }

    private static func removePartials(in directory: URL) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasPrefix(".") && name.contains(".partial-") {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    private static func writeMarker(_ paths: AppPaths) throws {
        let stamp = ISO8601DateFormatter().string(from: Date())
        try Data(stamp.utf8).write(to: paths.migrationMarker, options: .atomic)
    }
}
