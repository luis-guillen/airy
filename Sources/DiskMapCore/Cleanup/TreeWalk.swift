import Foundation

/// Resumen de un paseo acotado por una carpeta (o un fichero).
public struct TreeSummary: Sendable, Equatable {
    /// Tamaño asignado (`st_blocks * 512`), enlaces duros una sola vez.
    public var bytes: Int64
    /// El `mtime` más reciente de lo recorrido (la raíz incluida), o `nil` si no hay ninguno.
    public var latestModification: Date?
    /// Rutas relativas a la raíz de las entradas que cumplen `watch` (máx. `TreeWalk.maxWatched`).
    public var watched: [String]

    public init(bytes: Int64, latestModification: Date?, watched: [String]) {
        self.bytes = bytes; self.latestModification = latestModification; self.watched = watched
    }
}

/// Paseo síncrono por disco con plazo: `lstat` (nunca sigue enlaces), enlaces duros contados una vez y el
/// reloj mirado en cada entrada. No crea tareas.
public enum TreeWalk {
    public static let maxWatched = 10

    /// `nil` si se agota `budget` o la raíz no se puede leer. `prune(nombre, rutaRelativa)` ⇒ no entrar (ni
    /// se cuenta su tamaño ni su fecha). Una raíz que es fichero (o enlace) devuelve su tamaño y su `mtime`.
    public static func summarize(_ root: String, budget: Duration,
                                 prune: (String, String) -> Bool = { _, _ in false },
                                 watch: (String) -> Bool = { _ in false }) -> TreeSummary? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: budget)
        guard clock.now < deadline else { return nil }
        var info = stat()
        guard lstat(root, &info) == 0 else { return nil }
        var walker = Walker(deadline: deadline)
        walker.visit(info)
        if (info.st_mode & S_IFMT) == S_IFDIR {
            guard walker.walk(root, relative: "", isRoot: true, prune: prune, watch: watch) else { return nil }
        }
        return TreeSummary(bytes: walker.bytes, latestModification: walker.latest.map {
            Date(timeIntervalSince1970: TimeInterval($0.tv_sec) + TimeInterval($0.tv_nsec) / 1e9)
        }, watched: walker.watched)
    }

    private struct HardLinkKey: Hashable { let device: dev_t; let inode: ino_t }

    private struct Walker {
        let deadline: ContinuousClock.Instant
        var bytes: Int64 = 0
        var latest: timespec?
        var watched: [String] = []
        var seen = Set<HardLinkKey>()

        init(deadline: ContinuousClock.Instant) { self.deadline = deadline }

        mutating func visit(_ info: stat) {
            let type = info.st_mode & S_IFMT
            if type == S_IFREG, info.st_nlink > 1 {
                if seen.insert(HardLinkKey(device: info.st_dev, inode: info.st_ino)).inserted {
                    bytes += Int64(info.st_blocks) * 512
                }
            } else {
                bytes += Int64(info.st_blocks) * 512
            }
            let time = info.st_mtimespec
            if let current = latest {
                if time.tv_sec > current.tv_sec || (time.tv_sec == current.tv_sec && time.tv_nsec > current.tv_nsec) {
                    latest = time
                }
            } else {
                latest = time
            }
        }

        /// `false` si se agotó el plazo o la raíz no se pudo abrir.
        mutating func walk(_ path: String, relative: String, isRoot: Bool,
                           prune: (String, String) -> Bool, watch: (String) -> Bool) -> Bool {
            guard let dir = opendir(path) else { return !isRoot }
            defer { closedir(dir) }
            let clock = ContinuousClock()
            while let entry = readdir(dir) {
                guard clock.now < deadline else { return false }
                let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                    String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
                }
                if name == "." || name == ".." { continue }
                let rel = relative.isEmpty ? name : relative + "/" + name
                if prune(name, rel) { continue }
                let child = path == "/" ? "/" + name : path + "/" + name
                var info = stat()
                guard lstat(child, &info) == 0 else { continue }
                visit(info)
                if watched.count < TreeWalk.maxWatched, watch(name) { watched.append(rel) }
                if (info.st_mode & S_IFMT) == S_IFDIR {
                    guard walk(child, relative: rel, isRoot: false, prune: prune, watch: watch) else { return false }
                }
            }
            return true
        }
    }
}
