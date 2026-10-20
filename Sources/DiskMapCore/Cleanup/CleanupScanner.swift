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
    /// Se marca de entrada (según el clasificador y el modo).
    public var preselected: Bool
    /// Coincide con algún perfil de uso del usuario: va primero dentro de su grupo.
    public var highlighted: Bool
    /// Protección que lo deja en «No tocar», sin casilla.
    public var protection: ProtectionMatch?
    /// Por qué no se puede limpiar ahora (procesos abiertos, comprobación incompleta…), o `nil`.
    public var blockedReason: String?

    public init(id: String, entry: CatalogEntry, paths: [String], bytes: Int64, risk: Risk,
                blockedByOpenApps: [String], usedBy: [String], preselected: Bool = false, highlighted: Bool = false,
                protection: ProtectionMatch? = nil, blockedReason: String? = nil) {
        self.id = id; self.entry = entry; self.paths = paths; self.bytes = bytes
        self.risk = risk; self.blockedByOpenApps = blockedByOpenApps; self.usedBy = usedBy
        self.preselected = preselected; self.highlighted = highlighted
        self.protection = protection; self.blockedReason = blockedReason
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
    private let classifier: RiskClassifier

    /// `classifier`: `nil` ⇒ ajustes por defecto con este catálogo y este home.
    public init(catalog: Catalog, runner: any CommandRunning, probes: any SystemProbing,
                references: ReferenceChecker, home: String = NSHomeDirectory(), classifier: RiskClassifier? = nil) {
        self.catalog = catalog
        self.runner = runner
        self.probes = probes
        self.references = references
        self.home = home.count > 1 && home.hasSuffix("/") ? String(home.dropLast()) : home
        self.classifier = classifier ?? RiskClassifier(catalog: catalog, settings: .defaults, home: self.home)
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
        // Una sola llamada a `docker system df` para todas las fichas de Docker.
        let dockerOutput = catalog.entries.contains { Self.dockerMeasure[$0.id] != nil }
            ? await dockerSystemDF() : nil
        var found: [Candidate] = []
        for entry in catalog.entries {
            found.append(contentsOf: await candidates(for: entry, scan: scan, dockerOutput: dockerOutput))
        }
        let candidates = found.filter { $0.bytes > 0 }

        let needles = candidates.compactMap(\.needle)
        let references = needles.isEmpty
            ? [:] : await self.references.references(toAny: needles, timeout: Self.referenceTimeout)

        return candidates.compactMap { candidate in
            let usedBy = candidate.needle.flatMap { references[$0] } ?? []
            let verdict = classifier.classify(entry: candidate.entry, paths: candidate.paths)
            var risk = verdict.risk
            if !usedBy.isEmpty { risk = .doNotTouch }
            // Sin las rutas protegidas, el tamaño es solo el de las que quedan. Si no queda ninguna,
            // el elemento se muestra en rojo con su tamaño original.
            var paths = candidate.paths
            var bytes = candidate.bytes
            if !verdict.keptPaths.isEmpty, verdict.keptPaths != candidate.paths {
                paths = verdict.keptPaths
                bytes = paths.reduce(Int64(0)) { $0 + size(of: $1, scan: scan) }
                guard bytes > 0 else { return nil }
            }
            return CleanupItem(
                id: candidate.id, entry: candidate.entry, paths: paths, bytes: bytes,
                risk: risk, blockedByOpenApps: candidate.entry.mustBeClosed.filter { running.contains($0) },
                usedBy: usedBy, preselected: verdict.preselected && risk != .doNotTouch,
                highlighted: verdict.highlighted, protection: verdict.protection)
        }
    }

    private func candidates(for entry: CatalogEntry, scan: FileNode?, dockerOutput: String?) async -> [Candidate] {
        let matched = entry.paths.flatMap { Self.expand($0, home: home) }
        var unique: [String] = []
        for path in matched where !unique.contains(path) { unique.append(path) }

        if let measure = Self.dockerMeasure[entry.id] {
            // Sin Docker o sin demonio (`df` falla) no hay elemento.
            guard let dockerOutput,
                  let bytes = Self.parseDockerDF(dockerOutput, type: measure.type, field: measure.field)
            else { return [] }
            return [Candidate(id: entry.id, entry: entry, paths: unique, bytes: bytes, needle: nil)]
        }

        if case .command(let executable, _, let sizeProbe) = entry.cleanup {
            // Sin la herramienta instalada no se puede limpiar con su comando oficial.
            guard await runner.resolve(executable) != nil else { return [] }
            // Solo se sabe interpretar la sonda de Docker: el resto (tmutil…) no se mide.
            if sizeProbe != nil { return [] }
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

    /// Qué fila y qué campo de `docker system df` mide cada ficha de Docker.
    static let dockerMeasure: [String: (type: String, field: String)] = [
        "docker-build-cache": ("Build Cache", "Reclaimable"),
        "docker-images": ("Images", "Size"),
        "docker-volumes": ("Local Volumes", "Size"),
    ]
    static let dockerDFArguments = ["system", "df", "--format", "{{json .}}"]

    /// Salida de `docker system df`, o `nil` si Docker no está instalado o el demonio no responde.
    private func dockerSystemDF() async -> String? {
        let probe = catalog.entry(id: "docker-build-cache").flatMap { entry -> [String]? in
            if case .command(_, _, let sizeProbe) = entry.cleanup { return sizeProbe }
            return nil
        } ?? Self.dockerDFArguments
        guard let docker = await runner.resolve("docker"),
              let output = try? await runner.run(docker, probe, timeout: Self.probeTimeout),
              output.status == 0 else { return nil }
        return output.stdout
    }

    /// `docker system df --format {{json .}}`: un objeto JSON por línea con "Type", "Size" y "Reclaimable".
    static func parseDockerDF(_ output: String, type: String, field: String) -> Int64? {
        for line in output.split(whereSeparator: \.isNewline) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["Type"] as? String == type,
                  let value = object[field] as? String else { continue }
            return parseDockerSize(value)
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
