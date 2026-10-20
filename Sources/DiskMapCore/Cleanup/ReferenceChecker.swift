import Foundation

/// Busca en los proyectos del usuario si algo (p. ej. un modelo de Hugging Face) está referenciado.
/// Solo lee ficheros regulares < 1 MB, no sigue enlaces simbólicos y respeta un tiempo máximo.
public struct ReferenceChecker: Sendable {
    public static let excludedDirectoryNames: Set<String> = [
        "node_modules", ".git", ".venv", "venv", ".build", "target", "Library",
    ]
    public static let maxFileSize: Int64 = 1_000_000

    public let roots: [String]

    public init(roots: [String]) {
        self.roots = roots
    }

    /// Las raíces por defecto que existen: `~/Desktop`, `~/Documents`, `~/Projects`, `~/orca`.
    public init(home: String = NSHomeDirectory()) {
        self.init(roots: Self.defaultRoots(home: home))
    }

    public static func defaultRoots(home: String) -> [String] {
        ["Desktop", "Documents", "Projects", "orca"]
            .map { (home as NSString).appendingPathComponent($0) }
            .filter { path in
                var info = stat()
                return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
            }
    }

    /// Rutas de ficheros que contienen `needle`. Al agotar `timeout` devuelve lo encontrado hasta entonces.
    public func references(to needle: String, timeout: TimeInterval) async -> [String] {
        await references(toAny: [needle], timeout: timeout)[needle] ?? []
    }

    /// Una sola pasada para varias cadenas. La clave es la cadena; el valor, los ficheros que la contienen.
    public func references(toAny needles: [String], timeout: TimeInterval) async -> [String: [String]] {
        await referencesChecked(toAny: needles, timeout: timeout).found
    }

    /// Como `references(toAny:)`, y `complete == false` si se agotó el tiempo o se canceló antes de recorrer todo.
    public func referencesChecked(
        toAny needles: [String], timeout: TimeInterval
    ) async -> (found: [String: [String]], complete: Bool) {
        let patterns = Array(Set(needles.filter { !$0.isEmpty }))
        guard !patterns.isEmpty else { return ([:], true) }
        let encoded = patterns.map { Data($0.utf8) }
        let deadline = Date().addingTimeInterval(timeout)
        var found: [String: [String]] = [:]
        var complete = true
        var stack = roots.reversed().map { $0 }
        while let path = stack.popLast() {
            if Date() >= deadline || Task.isCancelled { complete = false; break }
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { continue }
                for name in names.sorted().reversed() where !Self.excludedDirectoryNames.contains(name) {
                    stack.append(path + "/" + name)
                }
            case S_IFREG:
                guard Int64(info.st_size) < Self.maxFileSize,
                      let data = FileManager.default.contents(atPath: path) else { continue }
                for (index, pattern) in encoded.enumerated() where data.range(of: pattern) != nil {
                    found[patterns[index], default: []].append(path)
                }
            default:
                continue // enlaces simbólicos y especiales: nunca se siguen ni se leen
            }
        }
        return (found, complete)
    }
}
