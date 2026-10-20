import Foundation

/// Algo concreto que se puede limpiar: una entrada del catálogo con sus rutas reales y su tamaño.
public struct CleanupItem: Sendable, Identifiable {
    /// `entry.id`, o `"\(entry.id):\(carpeta)"` para entradas con comprobación de referencias.
    public var id: String
    public var entry: CatalogEntry
    /// Rutas absolutas existentes (vacío para limpiezas sin rutas, como Docker).
    public var paths: [String]
    public var bytes: Int64
    public var risk: Risk
    /// Bundle IDs de `mustBeClosed` que estaban abiertos al detectar.
    public var blockedByOpenApps: [String]
    /// Ficheros de proyectos que referencian este elemento.
    public var usedBy: [String]

    public init(id: String, entry: CatalogEntry, paths: [String], bytes: Int64, risk: Risk,
                blockedByOpenApps: [String], usedBy: [String]) {
        self.id = id; self.entry = entry; self.paths = paths; self.bytes = bytes
        self.risk = risk; self.blockedByOpenApps = blockedByOpenApps; self.usedBy = usedBy
    }

    /// Título para la interfaz y el historial (incluye la carpeta en elementos por carpeta).
    public var title: String {
        guard let colon = id.firstIndex(of: ":"), id[..<colon] == entry.id else { return entry.title }
        return "\(entry.title): \(id[id.index(after: colon)...])"
    }
}

/// Detecta qué entradas del catálogo existen en este Mac y cuánto ocupan. Nunca ejecuta limpiezas:
/// solo `resolve` y las sondas de tamaño (`sizeProbe`).
public struct CleanupScanner: Sendable {
    public static let referenceTimeout: TimeInterval = 10
    public static let probeTimeout: TimeInterval = 60

    private let catalog: Catalog
    private let runner: any CommandRunning
    private let probes: any SystemProbing
    private let references: ReferenceChecker
    private let home: String

    public init(catalog: Catalog, runner: any CommandRunning, probes: any SystemProbing,
                references: ReferenceChecker, home: String = NSHomeDirectory()) {
        self.catalog = catalog
        self.runner = runner
        self.probes = probes
        self.references = references
        self.home = home.count > 1 && home.hasSuffix("/") ? String(home.dropLast()) : home
    }

    private struct Candidate {
        var id: String
        var entry: CatalogEntry
        var paths: [String]
        var bytes: Int64
        var needle: String?
    }

    public func findItems(scan: FileNode?) async -> [CleanupItem] {
        let running = probes.runningBundleIDs()
        var found: [Candidate] = []
        for entry in catalog.entries {
            found.append(contentsOf: await candidates(for: entry, scan: scan))
        }
        let candidates = found.filter { $0.bytes > 0 }

        let needles = candidates.compactMap(\.needle)
        let references = needles.isEmpty
            ? [:] : await self.references.references(toAny: needles, timeout: Self.referenceTimeout)

        return candidates.map { candidate in
            let usedBy = candidate.needle.flatMap { references[$0] } ?? []
            var risk = candidate.paths.reduce(candidate.entry.risk) { risk, path in
                .strictest(risk, RiskPolicy.effectiveRisk(path: path, home: home, catalog: candidate.entry.risk, ai: nil))
            }
            if !usedBy.isEmpty { risk = .doNotTouch }
            return CleanupItem(
                id: candidate.id, entry: candidate.entry, paths: candidate.paths, bytes: candidate.bytes,
                risk: risk, blockedByOpenApps: candidate.entry.mustBeClosed.filter { running.contains($0) },
                usedBy: usedBy)
        }
    }

    private func candidates(for entry: CatalogEntry, scan: FileNode?) async -> [Candidate] {
        let matched = entry.paths.flatMap { Self.expand($0, home: home) }
        var unique: [String] = []
        for path in matched where !unique.contains(path) { unique.append(path) }

        if case .command(let executable, let arguments, let sizeProbe) = entry.cleanup {
            // Sin la herramienta instalada no se puede limpiar con su comando oficial.
            guard let resolved = await runner.resolve(executable) else { return [] }
            if let sizeProbe {
                guard let bytes = await probeSize(resolved, executable: executable, cleanupArguments: arguments,
                                                  probe: sizeProbe) else { return [] }
                return [Candidate(id: entry.id, entry: entry, paths: unique, bytes: bytes, needle: nil)]
            }
        }

        if entry.referenceCheck != nil {
            return unique.map { path in
                let folder = (path as NSString).lastPathComponent
                return Candidate(
                    id: "\(entry.id):\(folder)", entry: entry, paths: [path], bytes: size(of: path, scan: scan),
                    needle: entry.referenceNeedle(forMatchedFolder: folder))
            }
        }
        guard !unique.isEmpty else { return [] }
        let bytes = unique.reduce(Int64(0)) { $0 + size(of: $1, scan: scan) }
        return [Candidate(id: entry.id, entry: entry, paths: unique, bytes: bytes, needle: nil)]
    }

    // MARK: - Tamaños

    private func size(of path: String, scan: FileNode?) -> Int64 {
        if let scan, let node = Self.node(at: path, in: scan) { return node.allocatedSize }
        return AllocatedSize.of(path) ?? 0
    }

    /// Nodo del índice para `path`, o `nil` si no está (p. ej. agrupado en "Otros").
    static func node(at path: String, in root: FileNode) -> FileNode? {
        if root.name.isEmpty {
            for child in root.children where child.aggregatedCount == 0 {
                if let found = node(at: path, in: child) { return found }
            }
            return nil
        }
        guard root.aggregatedCount == 0 else { return nil }
        if path == root.name { return root }
        let prefix = root.name == "/" ? "/" : root.name + "/"
        guard path.hasPrefix(prefix) else { return nil }
        var current = root
        for component in path.dropFirst(prefix.count).split(separator: "/") {
            guard let next = current.children.first(where: {
                $0.aggregatedCount == 0 && $0.name == component
            }) else { return nil }
            current = next
        }
        return current
    }

    /// Ejecuta la sonda de tamaño. `nil` si falla (Docker sin demonio) o la salida no se entiende.
    private func probeSize(_ resolved: String, executable: String, cleanupArguments: [String],
                           probe: [String]) async -> Int64? {
        // Solo se sabe interpretar la salida de Docker; las demás sondas no se ejecutan.
        guard executable == "docker", let type = Self.dockerType(forCleanupArguments: cleanupArguments) else {
            return nil
        }
        guard let output = try? await runner.run(resolved, probe, timeout: Self.probeTimeout),
              output.status == 0 else { return nil }
        return Self.parseDockerReclaimable(output.stdout, type: type)
    }

    static func dockerType(forCleanupArguments arguments: [String]) -> String? {
        switch arguments.first {
        case "builder": "Build Cache"
        case "image": "Images"
        case "container": "Containers"
        case "volume": "Local Volumes"
        default: nil
        }
    }

    /// `docker system df --format {{json .}}`: un objeto JSON por línea con "Type" y "Reclaimable".
    static func parseDockerReclaimable(_ output: String, type: String) -> Int64? {
        for line in output.split(whereSeparator: \.isNewline) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["Type"] as? String == type,
                  let reclaimable = object["Reclaimable"] as? String else { continue }
            return parseDockerSize(reclaimable)
        }
        return nil
    }

    /// "29.89GB (86%)" ⇒ 29 890 000 000 (unidades decimales; se ignora el paréntesis).
    public static func parseDockerSize(_ text: String) -> Int64? {
        let value = text.split(separator: "(").first?.trimmingCharacters(in: .whitespaces) ?? ""
        let numberPart = value.prefix { $0.isNumber || $0 == "." }
        let unit = value.dropFirst(numberPart.count).trimmingCharacters(in: .whitespaces).uppercased()
        guard !numberPart.isEmpty, let number = Double(numberPart) else { return nil }
        let multipliers: [String: Double] = [
            "B": 1, "KB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12, "PB": 1e15,
        ]
        guard let multiplier = multipliers[unit] else { return nil }
        return Int64((number * multiplier).rounded())
    }

    // MARK: - Patrones

    /// Expande `~` y `*` (dentro de un componente) contra el sistema de ficheros real.
    /// Devuelve rutas existentes (con `lstat`; un enlace roto también cuenta), ordenadas.
    static func expand(_ pattern: String, home: String) -> [String] {
        var full = pattern
        if pattern == "~" { full = home } else if pattern.hasPrefix("~/") { full = home + pattern.dropFirst(1) }
        guard full.hasPrefix("/") else { return [] }
        var current = ["/"]
        for component in full.split(separator: "/").map(String.init) {
            var next: [String] = []
            for base in current {
                let prefix = base == "/" ? "/" : base + "/"
                if component.contains("*") {
                    var info = stat()
                    // Solo se lista dentro de carpetas reales, nunca a través de enlaces.
                    guard lstat(base, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
                          let names = try? FileManager.default.contentsOfDirectory(atPath: base) else { continue }
                    for name in names.sorted() where fnmatch(component, name, 0) == 0 {
                        next.append(prefix + name)
                    }
                } else if component == "." || component == ".." {
                    return [] // los patrones del catálogo son canónicos
                } else {
                    next.append(prefix + component)
                }
            }
            current = next
        }
        return current.filter { path in
            var info = stat()
            return lstat(path, &info) == 0
        }
    }
}
