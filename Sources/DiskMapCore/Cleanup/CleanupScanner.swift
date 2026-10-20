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
    /// Líneas para la interfaz: nombres de contenedores, «Se conservan: …», «Proyecto sin tocar desde …».
    public var details: [String]
    /// Valores de `{target}` (véase `CleanupMethod.targetPlaceholder`).
    public var targets: [String]
    /// Texto en lugar del tamaño («Tamaño desconocido», «No ocupa espacio en disco»).
    public var sizeNote: String?
    public var lastModified: Date?
    /// Motivo de una guardia de la fuente (floor) o de una protección.
    public var riskReason: String?
    /// El tamaño no incluye todo (partes sin leer).
    public var sizeIsPartial: Bool

    public init(id: String, entry: CatalogEntry, paths: [String], bytes: Int64, risk: Risk,
                blockedByOpenApps: [String], usedBy: [String], preselected: Bool = false, highlighted: Bool = false,
                protection: ProtectionMatch? = nil, blockedReason: String? = nil, details: [String] = [],
                targets: [String] = [], sizeNote: String? = nil, lastModified: Date? = nil,
                riskReason: String? = nil, sizeIsPartial: Bool = false) {
        self.id = id; self.entry = entry; self.paths = paths; self.bytes = bytes
        self.risk = risk; self.blockedByOpenApps = blockedByOpenApps; self.usedBy = usedBy
        self.preselected = preselected; self.highlighted = highlighted
        self.protection = protection; self.blockedReason = blockedReason
        self.details = details; self.targets = targets; self.sizeNote = sizeNote
        self.lastModified = lastModified; self.riskReason = riskReason; self.sizeIsPartial = sizeIsPartial
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

    private let catalog: Catalog
    private let runner: any CommandRunning
    private let probes: any SystemProbing
    private let references: ReferenceChecker
    private let home: String
    private let classifier: RiskClassifier
    private let processListing: any ProcessListing
    private let referenceTimeout: TimeInterval
    private let measureBudget: Duration

    /// `classifier`: `nil` ⇒ ajustes por defecto con este catálogo y este home. `measureBudget`: plazo para
    /// medir cada ruta que no está en el índice.
    public init(catalog: Catalog, runner: any CommandRunning, probes: any SystemProbing,
                references: ReferenceChecker, home: String = NSHomeDirectory(), classifier: RiskClassifier? = nil,
                processListing: any ProcessListing = LibprocListing(),
                referenceTimeout: TimeInterval = CleanupScanner.referenceTimeout,
                measureBudget: Duration = TimeBudget.sizeMeasure) {
        self.processListing = processListing
        self.measureBudget = measureBudget
        self.referenceTimeout = referenceTimeout
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
        var target: DiscoveredTarget
        var bytes: Int64
    }

    /// `inaccessible`: carpetas que el análisis no pudo leer; un tamaño tomado del índice para una ruta con algo
    /// ilegible dentro es un mínimo (`sizeIsPartial`).
    public func findItems(scan: FileNode?, inaccessible: [String] = []) async -> [CleanupItem] {
        let partialIndex = PartialScanIndex(inaccessible: inaccessible)
        let running = probes.runningBundleIDs()
        // Una sola sonda de Docker por pasada para todas sus fichas.
        let docker = catalog.entries.contains { $0.discovery == .docker }
            ? await DockerProbe.state(runner: runner) : nil
        let context = DiscoveryContext(catalog: catalog, home: home, runner: runner,
                                       processListing: processListing, now: Date(), scan: scan, docker: docker)
        var candidates: [Candidate] = []
        // Una ruta, un elemento: la primera ficha del catálogo que la reclama se la queda.
        var claimed = Set<String>()
        // Todas las fichas informativas comparten un solo plazo de medida (`measureBudget`): lo que no cabe se
        // queda en «Tamaño desconocido».
        let clock = ContinuousClock()
        var reviewDeadline: ContinuousClock.Instant?
        for entry in catalog.entries {
            for var target in await CleanupTargets.source(for: entry).discover(entry, context: context) {
                let original = target.paths
                if !original.isEmpty {
                    let dropped = Set(original.filter { claimed.contains(RiskPolicy.canonical($0)) })
                    if !dropped.isEmpty {
                        target.paths = original.filter { !dropped.contains($0) }
                        target.targets = target.targets.filter { !dropped.contains($0) }
                        target.bytes = nil // se vuelve a medir sin las rutas de otro elemento
                    }
                    guard !target.paths.isEmpty else { continue }
                }
                var bytes = target.bytes
                if bytes == nil {
                    var budget = measureBudget
                    var isReview = false
                    if case .info = entry.cleanup {
                        isReview = true
                        let deadline = reviewDeadline ?? clock.now.advanced(by: measureBudget)
                        reviewDeadline = deadline
                        budget = max(.zero, clock.now.duration(to: deadline))
                    }
                    bytes = measure(target.paths, scan: scan, budget: budget)
                    if bytes == nil {
                        target.sizeNote = target.sizeNote ?? "Tamaño desconocido"
                        // Sin acción no hay nada que bloquear: la ficha solo informa.
                        if !isReview { target.blockedReason = target.blockedReason ?? "No se pudo medir a tiempo." }
                    }
                }
                let size = bytes ?? 0
                guard size > 0 || target.sizeNote != nil || target.blockedReason != nil else { continue }
                // Solo reclama sus rutas el elemento que sobrevive (no uno de 0 bytes que se descarta).
                claimed.formUnion(target.paths.map(RiskPolicy.canonical))
                let id = target.idSuffix.map { "\(entry.id):\($0)" } ?? entry.id
                candidates.append(Candidate(id: id, entry: entry, target: target, bytes: size))
            }
        }

        let needles = candidates.compactMap(\.target.needle)
        let checked = needles.isEmpty
            ? (found: [String: [String]](), complete: true)
            : await self.references.referencesChecked(toAny: needles, timeout: referenceTimeout)
        let references = checked.found

        // Un solo listado de procesos por pasada, y solo si alguna ficha lo necesita.
        let needsProcesses = candidates.contains { !$0.entry.processNames.isEmpty }
        let processes: [RunningProcess]?
        if needsProcesses {
            let listing = processListing
            processes = await TimeBudget.run(TimeBudget.processScan, { listing.processes() }) ?? nil
        } else {
            processes = nil
        }

        return candidates.compactMap { candidate in
            let target = candidate.target
            let usedBy = target.needle.flatMap { references[$0] } ?? []
            let verdict = classifier.classify(entry: candidate.entry, paths: target.paths, floor: target.floor)
            var risk = verdict.risk
            if !usedBy.isEmpty { risk = .doNotTouch }
            // Sin las rutas protegidas, el tamaño es solo el de las que quedan. Si no queda ninguna,
            // el elemento se muestra en rojo con su tamaño original.
            var paths = target.paths
            var targets = target.targets
            var bytes = candidate.bytes
            if !verdict.keptPaths.isEmpty, verdict.keptPaths != target.paths {
                paths = verdict.keptPaths
                targets = targets.filter { paths.contains($0) || !$0.hasPrefix("/") }
                bytes = measure(paths, scan: scan) ?? 0
                guard bytes > 0 else { return nil }
            }
            // Fallar cerrado: proceso en marcha, listado desconocido o referencias sin terminar bloquean.
            var blockedReason = target.blockedReason
            if blockedReason == nil {
                blockedReason = ProcessGuard.state(processNames: candidate.entry.processNames, among: processes)
                    .blockedReason
            }
            if blockedReason == nil, target.needle != nil, !checked.complete {
                blockedReason = "No se pudo comprobar a tiempo si lo usa algún proyecto."
            }
            return CleanupItem(
                id: candidate.id, entry: candidate.entry, paths: paths, bytes: bytes,
                risk: risk, blockedByOpenApps: candidate.entry.mustBeClosed.filter { running.contains($0) },
                usedBy: usedBy, preselected: verdict.preselected && risk != .doNotTouch && target.preselectable,
                highlighted: verdict.highlighted, protection: verdict.protection, blockedReason: blockedReason,
                details: target.details, targets: targets, sizeNote: target.sizeNote,
                lastModified: target.lastModified, riskReason: target.floorReason ?? verdict.protection?.reason,
                sizeIsPartial: Self.isPartialSize(paths, scan: scan, index: partialIndex))
        }
    }

    // MARK: - Tamaños

    /// Suma del índice o, si una ruta no está en él, de `TreeWalk` con `measureBudget`. Una ruta que ya no
    /// existe cuenta 0; `nil` si alguna no se pudo medir a tiempo.
    private func measure(_ paths: [String], scan: FileNode?, budget: Duration? = nil) -> Int64? {
        let budget = budget ?? measureBudget
        var total: Int64 = 0
        for path in paths {
            if let scan, let node = Self.node(at: path, in: scan) { total += node.allocatedSize; continue }
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }
            if let summary = TreeWalk.summarize(path, budget: budget) {
                total += summary.bytes
            } else if (info.st_mode & S_IFMT) == S_IFDIR, !Self.canOpen(path) {
                // Carpeta que no se puede leer (TCC, permisos): como en la fase 1, solo su propia entrada.
                total += AllocatedSize.of(path) ?? 0
            } else {
                return nil
            }
        }
        return total
    }

    /// El tamaño sale del índice y alguna de las rutas tiene algo ilegible dentro.
    private static func isPartialSize(_ paths: [String], scan: FileNode?, index: PartialScanIndex) -> Bool {
        guard let scan, !index.isEmpty else { return false }
        return paths.contains { index.isPartial($0) && node(at: $0, in: scan) != nil }
    }

    private static func canOpen(_ path: String) -> Bool {
        guard let dir = opendir(path) else { return false }
        closedir(dir)
        return true
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
