import Foundation

/// Lo que una fuente necesita para descubrir o revalidar objetivos.
public struct DiscoveryContext: Sendable {
    public let catalog: Catalog
    public let home: String
    public let runner: any CommandRunning
    public let processListing: any ProcessListing
    public let now: Date
    /// Índice de la última exploración (para medir sin recorrer el disco), si lo hay.
    public let scan: FileNode?
    /// Estado de Docker de esta pasada (una sola sonda); `nil` ⇒ `DockerSource` lo pregunta.
    public let docker: DockerState?
    /// Paseo de proyectos de esta pasada, compartido por todas las fichas `projectArtifacts`.
    let projectWalk = ProjectWalkMemo()

    public init(catalog: Catalog, home: String, runner: any CommandRunning, processListing: any ProcessListing,
                now: Date, scan: FileNode?, docker: DockerState? = nil) {
        self.catalog = catalog
        self.home = home.count > 1 && home.hasSuffix("/") ? String(home.dropLast()) : home
        self.runner = runner; self.processListing = processListing; self.now = now; self.scan = scan
        self.docker = docker
    }
}

/// Un elemento propuesto por una fuente, antes de medirlo y clasificarlo.
public struct DiscoveredTarget: Sendable, Equatable {
    /// `nil` ⇒ el id es `entry.id`; si no, `"\(entry.id):\(idSuffix)"`.
    public var idSuffix: String?
    public var paths: [String]
    /// Valores de `{target}` (véase `CleanupMethod.targetPlaceholder`).
    public var targets: [String] = []
    /// `nil` ⇒ lo mide el escáner (índice o `TreeWalk` con `TimeBudget.sizeMeasure`).
    public var bytes: Int64? = nil
    public var details: [String] = []
    public var lastModified: Date? = nil
    /// Cadena a buscar en proyectos (comprobación de referencias).
    public var needle: String? = nil
    /// Guardia: solo sube el riesgo.
    public var floor: Risk? = nil
    public var floorReason: String? = nil
    public var blockedReason: String? = nil
    public var sizeNote: String? = nil
    /// `false` ⇒ nunca se marca de entrada, aunque el clasificador lo permita (solo baja la preselección).
    public var preselectable: Bool = true

    public init(idSuffix: String? = nil, paths: [String], targets: [String] = [], bytes: Int64? = nil,
                details: [String] = [], lastModified: Date? = nil, needle: String? = nil, floor: Risk? = nil,
                floorReason: String? = nil, blockedReason: String? = nil, sizeNote: String? = nil) {
        self.idSuffix = idSuffix; self.paths = paths; self.targets = targets; self.bytes = bytes
        self.details = details; self.lastModified = lastModified; self.needle = needle; self.floor = floor
        self.floorReason = floorReason; self.blockedReason = blockedReason; self.sizeNote = sizeNote
    }
}

/// Único punto de extensión de la limpieza: el escáner descubre con `discover` y el embudo vuelve a
/// comprobar con `revalidate` justo antes de actuar. La misma regla en los dos sitios.
public protocol CleanupTargetSource: Sendable {
    func discover(_ entry: CatalogEntry, context: DiscoveryContext) async -> [DiscoveredTarget]
    /// En el embudo, justo antes de actuar. `nil` = sigue valiendo tal cual; si no, motivo en español.
    func revalidate(_ entry: CatalogEntry, item: CleanupItem, context: DiscoveryContext) async -> String?
}

public enum CleanupTargets {
    /// `discovery` ⇒ su fuente; `retention` ⇒ `RetentionSource`; si no, `StaticPatternSource`.
    public static func source(for entry: CatalogEntry) -> any CleanupTargetSource {
        if entry.discovery == .docker { return DockerSource() }
        if entry.discovery == .simulatorRuntimes { return SimulatorRuntimeSource() }
        if case .projectArtifacts = entry.discovery { return ProjectArtifactSource() }
        if entry.discovery == .installers { return InstallerSource() }
        if case .toolchains = entry.discovery { return PendingDiscoverySource() }
        if entry.discovery != nil { return PendingDiscoverySource() }
        if entry.retention != nil { return RetentionSource() }
        return StaticPatternSource()
    }

    /// Rutas de los patrones de la ficha que existen ahora, sin repetir y sin las de `except`.
    static func livePaths(of entry: CatalogEntry, home: String) -> [String] {
        var unique: [String] = []
        for path in entry.paths.flatMap({ CleanupScanner.expand($0, home: home) })
        where !unique.contains(path) && !entry.except.contains((path as NSString).lastPathComponent) {
            unique.append(path)
        }
        return unique
    }

    static func canonicalSet(_ paths: [String]) -> Set<String> { Set(paths.map(RiskPolicy.canonical)) }

    static func realPath(_ path: String) -> String? {
        guard let real = realpath(path, nil) else { return nil }
        defer { free(real) }
        return String(cString: real)
    }

    static func expandTilde(_ pattern: String, home: String) -> String {
        if pattern == "~" { return home }
        if pattern.hasPrefix("~/") { return home + pattern.dropFirst(1) }
        return pattern
    }
}

/// Fuente de una `discovery` que esta versión aún no sabe recorrer: no ofrece nada y, si llega un
/// elemento, se rechaza (fallo cerrado).
struct PendingDiscoverySource: CleanupTargetSource {
    func discover(_ entry: CatalogEntry, context: DiscoveryContext) async -> [DiscoveredTarget] { [] }

    func revalidate(_ entry: CatalogEntry, item: CleanupItem, context: DiscoveryContext) async -> String? {
        "Airy no sabe comprobar «\(entry.title)» todavía; no se toca."
    }
}

/// Los patrones de la ficha (comportamiento de la fase 1), con `except`, `perMatch`, `staleAfterDays`,
/// `minimumBytes` y `{target}`.
public struct StaticPatternSource: CleanupTargetSource {
    public init() {}

    public func discover(_ entry: CatalogEntry, context: DiscoveryContext) async -> [DiscoveredTarget] {
        let unique = CleanupTargets.livePaths(of: entry, home: context.home)
        if case .command(let executable, _, let sizeProbe) = entry.cleanup {
            // Sin la herramienta instalada no se puede limpiar con su comando oficial.
            guard await context.runner.resolve(executable) != nil else { return [] }
            // Solo se sabe interpretar la sonda de sqlite3 (espacio libre de una base de datos). Las demás
            // (tmutil…) no se miden (Docker va por `DockerSource`).
            if let sizeProbe {
                guard executable == "sqlite3", let resolved = await context.runner.resolve(executable) else { return [] }
                return await sqliteGroups(entry, paths: unique, probe: sizeProbe, executable: resolved,
                                          runner: context.runner)
            }
        }

        var groups: [DiscoveredTarget] = []
        if entry.referenceCheck != nil {
            groups = unique.map { path in
                let folder = (path as NSString).lastPathComponent
                return DiscoveredTarget(idSuffix: folder, paths: [path],
                                        needle: entry.referenceNeedle(forMatchedFolder: folder))
            }
        } else if entry.perMatch {
            groups = unique.map { DiscoveredTarget(idSuffix: Format.tildePath($0, home: context.home), paths: [$0]) }
        } else if !unique.isEmpty {
            groups = [DiscoveredTarget(paths: unique)]
        }

        var result: [DiscoveredTarget] = []
        for var group in groups {
            if entry.staleAfterDays != nil || entry.minimumBytes != nil {
                guard measure(&group, entry: entry, now: context.now, scan: context.scan) else { continue }
            }
            if entry.cleanup.usesTargets { group.targets = group.paths }
            result.append(group)
        }
        return result
    }

    static let sqliteProbeTimeout: TimeInterval = 10

    /// Una sonda por base de datos: `bytes = page_size × freelist_count` (dos enteros, uno por línea). Si falla o
    /// no se entiende, esa base no se ofrece. Un solo elemento con las bases que pasan `minimumBytes`.
    private func sqliteGroups(_ entry: CatalogEntry, paths: [String], probe: [String], executable: String,
                              runner: any CommandRunning) async -> [DiscoveredTarget] {
        var kept: [String] = []
        var bytes: Int64 = 0
        for path in paths {
            let arguments = probe.map { $0 == CleanupMethod.targetPlaceholder ? path : $0 }
            guard let output = try? await runner.run(executable, arguments, timeout: Self.sqliteProbeTimeout),
                  output.status == 0 else { continue }
            let numbers = output.stdout.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard numbers.count == 2, let pageSize = Int64(numbers[0]), let freePages = Int64(numbers[1]),
                  pageSize > 0, pageSize <= 65_536, freePages >= 0 else { continue }
            kept.append(path)
            bytes += pageSize * freePages
        }
        guard !kept.isEmpty, bytes >= (entry.minimumBytes ?? 1) else { return [] }
        return [DiscoveredTarget(paths: kept, targets: kept, bytes: bytes)]
    }

    /// Aplica `staleAfterDays` (quita las rutas recientes o sin medir) y `minimumBytes`. `false` ⇒ fuera.
    /// Sin `staleAfterDays`, el tamaño del índice basta (no hace falta recorrer el disco).
    private func measure(_ group: inout DiscoveredTarget, entry: CatalogEntry, now: Date, scan: FileNode?) -> Bool {
        let cutoff = entry.staleAfterDays.map { now.addingTimeInterval(-Double($0) * 86_400) }
        var kept: [String] = []
        var bytes: Int64 = 0
        var latest: Date?
        for path in group.paths {
            if cutoff == nil, let scan, let node = CleanupScanner.node(at: path, in: scan) {
                kept.append(path)
                bytes += node.allocatedSize
                continue
            }
            guard let summary = TreeWalk.summarize(path, budget: TimeBudget.sizeMeasure) else { continue }
            if let cutoff {
                guard let modified = summary.latestModification, modified < cutoff else { continue }
            }
            kept.append(path)
            bytes += summary.bytes
            if let modified = summary.latestModification, latest.map({ modified > $0 }) ?? true { latest = modified }
        }
        guard !kept.isEmpty else { return false }
        if let minimum = entry.minimumBytes, bytes < minimum { return false }
        group.paths = kept
        group.bytes = bytes
        group.lastModified = latest
        return true
    }

    public func revalidate(_ entry: CatalogEntry, item: CleanupItem, context: DiscoveryContext) async -> String? {
        switch entry.cleanup {
        case .info:
            return nil
        case .trash:
            let live = CleanupTargets.canonicalSet(CleanupTargets.livePaths(of: entry, home: context.home))
            for path in item.paths where !live.contains(RiskPolicy.canonical(path)) {
                return "La ruta no corresponde a «\(entry.title)»: \(path)."
            }
            guard let days = entry.staleAfterDays else { return nil }
            let cutoff = context.now.addingTimeInterval(-Double(days) * 86_400)
            for path in item.paths {
                guard let summary = TreeWalk.summarize(path, budget: TimeBudget.sizeMeasure) else {
                    return "No se pudo comprobar a tiempo si lo has usado; Airy no lo toca."
                }
                guard let modified = summary.latestModification, modified < cutoff else {
                    return "Lo has usado hace poco."
                }
            }
            return nil
        case .command:
            guard entry.cleanup.usesTargets else { return nil }
            let live = CleanupTargets.canonicalSet(CleanupTargets.livePaths(of: entry, home: context.home))
            for target in item.targets where !live.contains(RiskPolicy.canonical(target)) || !target.hasPrefix("/") {
                return "El objetivo no corresponde a «\(entry.title)»: \(target)."
            }
            return nil
        }
    }
}

/// Versiones: por carpeta padre se conservan la activa (si hay `activeLink`) y las más nuevas hasta
/// `keepNewest`; el resto forma un solo elemento.
public struct RetentionSource: CleanupTargetSource {
    public init() {}

    public func discover(_ entry: CatalogEntry, context: DiscoveryContext) async -> [DiscoveredTarget] {
        let plan = Self.plan(entry, home: context.home)
        guard !plan.removable.isEmpty else { return [] }
        return [DiscoveredTarget(paths: plan.removable, details: plan.details)]
    }

    public func revalidate(_ entry: CatalogEntry, item: CleanupItem, context: DiscoveryContext) async -> String? {
        let removable = CleanupTargets.canonicalSet(Self.plan(entry, home: context.home).removable)
        for path in item.paths where !removable.contains(RiskPolicy.canonical(path)) {
            return "Ya no es una versión antigua: \((path as NSString).lastPathComponent)."
        }
        guard entry.retention?.activeLink != nil else { return nil }
        let listing = context.processListing
        guard let outcome = await TimeBudget.run(TimeBudget.processScan, { listing.processes() }),
              let processes = outcome else {
            return "No se pudo comprobar si está en uso; Airy no lo toca."
        }
        for path in item.paths {
            var roots = [RiskPolicy.canonical(path)]
            if let real = CleanupTargets.realPath(path) { roots.append(RiskPolicy.canonical(real)) }
            for process in processes {
                guard let executable = process.executablePath else { continue }
                let exe = RiskPolicy.canonical(executable)
                if roots.contains(where: { RiskPolicy.isInside(exe, root: $0) }) {
                    return "Está en uso: \((path as NSString).lastPathComponent)."
                }
            }
        }
        return nil
    }

    struct Plan { var removable: [String]; var details: [String] }

    /// Rutas sobrantes (en el orden de los patrones) y un «Se conservan: …» por carpeta padre.
    /// Con `activeLink`, una carpeta cuya versión activa no se encuentra no da nada (fallo cerrado).
    static func plan(_ entry: CatalogEntry, home: String) -> Plan {
        guard let rule = entry.retention else { return Plan(removable: [], details: []) }
        var parents: [String] = []
        var groups: [String: [String]] = [:]
        for path in CleanupTargets.livePaths(of: entry, home: home) {
            let parent = (path as NSString).deletingLastPathComponent
            if groups[parent] == nil { parents.append(parent) }
            groups[parent, default: []].append(path)
        }
        let active = rule.activeLink.flatMap {
            CleanupTargets.realPath(CleanupTargets.expandTilde($0, home: home)).map(RiskPolicy.canonical)
        }
        var plan = Plan(removable: [], details: [])
        for parent in parents {
            let group = groups[parent] ?? []
            let sorted = group.map { ($0, modification(of: $0)) }.sorted { a, b in
                if a.1 != b.1 { return a.1 > b.1 }
                return (a.0 as NSString).lastPathComponent > (b.0 as NSString).lastPathComponent
            }.map(\.0)
            var kept: [String] = []
            if rule.activeLink != nil {
                guard let active, let version = sorted.first(where: { path in
                    let root = RiskPolicy.canonical(CleanupTargets.realPath(path) ?? path)
                    return RiskPolicy.isInside(active, root: root)
                }) else { continue }
                kept.append(version)
            }
            for path in sorted where kept.count < rule.keepNewest && !kept.contains(path) { kept.append(path) }
            plan.removable += group.filter { !kept.contains($0) }
            let names = sorted.filter(kept.contains).map { ($0 as NSString).lastPathComponent }
            plan.details.append("Se conservan: \(names.joined(separator: ", "))")
        }
        return plan
    }

    /// `mtime` de la entrada (sin seguir enlaces); 0 si no se puede leer.
    private static func modification(of path: String) -> Double {
        var info = stat()
        guard lstat(path, &info) == 0 else { return 0 }
        return Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
    }
}
