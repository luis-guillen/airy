import Foundation

/// Ficha `discovery {"type":"dependencyDuplicates"}`: el mismo paquete de Node (nombre y versión) copiado en el
/// `node_modules` de varios proyectos. Una sola fila informativa; nunca hay acción.
public struct DependencyDuplicateSource: CleanupTargetSource {
    static let minimumProjects = 3
    static let maxPackageJSONBytes = 64 * 1024

    private let budget: Duration

    public init() { self.init(budget: .seconds(20)) }

    init(budget: Duration) { self.budget = budget }

    public func discover(_ entry: CatalogEntry, context: DiscoveryContext) async -> [DiscoveredTarget] {
        guard entry.discovery == .dependencyDuplicates else { return [] }
        let list = await ProjectArtifactSource().projectList(context: context)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: budget)
        var partial = !list.complete
        /// `name@version` → una carpeta por proyecto.
        var copies: [String: [String]] = [:]
        for project in list.projects {
            guard clock.now < deadline, !Task.isCancelled else { partial = true; break }
            var seen = Set<String>()
            for (name, path) in ToolchainInventory.realChildren(project + "/node_modules") {
                let packages = name.hasPrefix("@") ? ToolchainInventory.realChildren(path).map(\.1) : [path]
                for package in packages {
                    guard let key = Self.key(of: package), seen.insert(key).inserted else { continue }
                    copies[key, default: []].append(package)
                }
            }
        }
        let repeated = copies.filter { $0.value.count >= Self.minimumProjects }
            .sorted { ($0.value.count, $1.key) > ($1.value.count, $0.key) }
        guard !repeated.isEmpty else { return [] }
        var cut = false
        var rows: [(key: String, count: Int, size: Int64)] = []
        for (key, folders) in repeated {
            let left = max(.zero, clock.now.duration(to: deadline))
            // El índice, si tiene la carpeta; si no, el disco.
            let indexed = context.scan.flatMap { CleanupScanner.node(at: folders[0], in: $0) }?.allocatedSize
            guard let size = indexed ?? TreeWalk.summarize(folders[0], budget: left)?.bytes else { cut = true; continue }
            rows.append((key, folders.count, size))
        }
        rows.sort { Int64($0.count - 1) * $0.size > Int64($1.count - 1) * $1.size }
        let total = rows.reduce(Int64(0)) { $0 + Int64($1.count - 1) * $1.size }
        var target = DiscoveredTarget(
            paths: [], bytes: total,
            details: rows.prefix(5).map { "\($0.key) · \($0.count) proyectos · \(Format.bytes($0.size)) cada copia" },
            sizeNote: partial ? "Análisis parcial" : (cut ? "Al menos" : nil))
        target.preselectable = false
        return [target]
    }

    public func revalidate(_ entry: CatalogEntry, item: CleanupItem, context: DiscoveryContext) async -> String? {
        "Este elemento es solo informativo."
    }

    /// `name@version` del `package.json` (fichero normal de como mucho 64 KB); `nil` si no se entiende.
    static func key(of package: String) -> String? {
        let file = package + "/package.json"
        var info = stat()
        guard lstat(file, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= maxPackageJSONBytes,
              let data = FileManager.default.contents(atPath: file),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let name = json["name"] as? String, let version = json["version"] as? String,
              !name.isEmpty, !version.isEmpty else { return nil }
        return "\(name)@\(version)"
    }
}
