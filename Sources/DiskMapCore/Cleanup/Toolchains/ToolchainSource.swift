import Foundation
import Synchronization

/// Detección de versiones de una pasada.
struct ToolchainDetection: Sendable {
    var installs: [InstalledToolchain]
    var usage: UsageReport
    /// Fórmula → dependientes; `nil` (o ausente) = no se pudo comprobar.
    var brewDependents: [String: [String]?]
    /// `nil` = listado desconocido.
    var processes: [RunningProcess]?
    /// `false` si se agotó `TimeBudget.toolchains`.
    var complete: Bool
    /// Ruta de `brew`, si está instalado.
    var brew: String?

    static let empty = ToolchainDetection(installs: [], usage: UsageReport(projectsComplete: false),
                                          brewDependents: [:], processes: nil, complete: false, brew: nil)
}

/// Una detección por `DiscoveryContext` (mismo patrón que `ProjectWalkMemo`).
final class ToolchainMemo: Sendable {
    private let state = Mutex<ToolchainDetection?>(nil)

    func detection(compute: () async -> ToolchainDetection) async -> ToolchainDetection {
        if let done = state.withLock({ $0 }) { return done }
        let fresh = await compute()
        return state.withLock { current in
            if let current { return current }
            current = fresh
            return fresh
        }
    }
}

/// Fichas `discovery {"type":"toolchains","manager":…}`: versiones repetidas de una herramienta de desarrollo.
/// Las que se usan salen en rojo; las demás, en ámbar (nunca en verde). La misma regla en `discover` y `revalidate`.
public struct ToolchainSource: CleanupTargetSource {
    static let brewUsesArguments = ["uses", "--installed"]
    static let unusedAfter: TimeInterval = 90 * 86_400
    /// Solo pruebas: raíces para las fuentes creadas con `init()` (escáner y embudo).
    @TaskLocal static var rootsOverride: (@Sendable (String) -> ToolchainRoots)?

    private let roots: (@Sendable (String) -> ToolchainRoots)?
    private let budget: Duration
    private let brewTimeout: TimeInterval
    private let brewLimit: Int

    public init() { self.init(roots: nil) }

    init(roots: (@Sendable (String) -> ToolchainRoots)?, budget: Duration = TimeBudget.toolchains,
         brewTimeout: TimeInterval = 15, brewLimit: Int = 8) {
        self.roots = roots; self.budget = budget; self.brewTimeout = brewTimeout; self.brewLimit = brewLimit
    }

    /// `^[A-Za-z0-9][A-Za-z0-9._+@-]*$` y sin `..`: lo único que llega como `{target}` que no es ruta.
    static func isSafeName(_ text: String) -> Bool {
        guard let first = text.unicodeScalars.first, first.isASCII, first.properties.isAlphabetic || ("0"..."9").contains(first),
              !text.contains("..") else { return false }
        return text.unicodeScalars.allSatisfy {
            $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || "._+@-".unicodeScalars.contains($0))
        }
    }

    // MARK: - Detección

    func detection(_ context: DiscoveryContext) async -> ToolchainDetection {
        await context.toolchains.detection { await detect(context) }
    }

    private func detect(_ context: DiscoveryContext) async -> ToolchainDetection {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: budget)
        guard budget > .zero else { return .empty }
        let roots = (self.roots ?? Self.rootsOverride ?? ToolchainRoots.standard)(context.home)
        let installs = ToolchainInventory.scan(roots)
        let projects = await ProjectArtifactSource().projectList(context: context)
        let usage = await ToolchainUsage.report(installs: installs, roots: roots, projects: projects,
                                                runner: context.runner)
        let listing = context.processListing
        let processes = await TimeBudget.run(TimeBudget.processScan, { listing.processes() }) ?? nil
        var detection = ToolchainDetection(installs: installs, usage: usage, brewDependents: [:],
                                           processes: processes, complete: true, brew: nil)
        let formulas = installs.filter { $0.manager == .homebrew && Self.isDuplicate($0, in: installs) }
        if !formulas.isEmpty, let brew = await context.runner.resolve("brew") {
            detection.brew = brew
            var checked = 0
            // En secuencia (nunca en paralelo), solo las que no son ya rojas, como mucho `brewLimit`.
            for formula in formulas where Self.preBrewVerdict(formula, detection) == nil {
                guard checked < brewLimit else { break }
                guard Self.isSafeName(formula.target) else { continue }
                let left = clock.now.duration(to: deadline)
                let seconds = Double(left.components.seconds) + Double(left.components.attoseconds) / 1e18
                guard seconds > 0 else { break }
                checked += 1
                let output = try? await context.runner.run(brew, Self.brewUsesArguments + [formula.target],
                                                           timeout: min(brewTimeout, seconds))
                if let output, output.status == 0 {
                    detection.brewDependents[formula.target] = ToolchainUsage.lines(output.stdout)
                } else {
                    detection.brewDependents.updateValue(nil, forKey: formula.target)
                }
            }
        }
        detection.complete = clock.now < deadline && !Task.isCancelled
        return detection
    }

    // MARK: - Reglas

    /// Lenguaje (o herramienta, en «otras») que agrupa las instalaciones (R3).
    static func groupKey(_ install: InstalledToolchain) -> String {
        install.language == .other ? "other:\(install.plugin ?? install.name)" : install.language.rawValue
    }

    /// Hay al menos otra instalación del mismo lenguaje (los entornos de conda siempre son «extra»).
    static func isDuplicate(_ install: InstalledToolchain, in installs: [InstalledToolchain]) -> Bool {
        if install.language == .condaEnv { return true }
        let key = groupKey(install)
        return installs.filter { groupKey($0) == key }.count >= 2
    }

    enum Verdict: Equatable {
        case red(String)
        case blocked(String)
        case amber
    }

    /// Todo menos Homebrew: procesos, por defecto y pins.
    private static func preBrewVerdict(_ install: InstalledToolchain, _ d: ToolchainDetection) -> Verdict? {
        guard let processes = d.processes else { return .blocked("No se pudo comprobar si está en uso.") }
        let roots = [RiskPolicy.canonical(install.path),
                     RiskPolicy.canonical(CleanupTargets.realPath(install.path) ?? install.path)]
        for process in processes {
            guard let exe = process.executablePath else { continue }
            let canonical = RiskPolicy.canonical(exe)
            if roots.contains(where: { canonical == $0 || RiskPolicy.isInside(canonical, root: $0) }) {
                return .red("Se está usando ahora.")
            }
        }
        if let reason = d.usage.defaults[install.path] { return .red(reason) }
        if let reason = d.usage.requested[install.path] { return .red(reason) }
        return nil
    }

    static func verdict(_ install: InstalledToolchain, _ d: ToolchainDetection) -> Verdict {
        if let early = preBrewVerdict(install, d) { return early }
        if install.manager == .homebrew {
            guard let checked = d.brewDependents[install.target], let dependents = checked else {
                return .blocked("No se pudo comprobar a tiempo si Homebrew la necesita.")
            }
            if !dependents.isEmpty { return .red("Lo necesita Homebrew para: \(dependents.joined(separator: ", ")).") }
        }
        return .amber
    }

    // MARK: - CleanupTargetSource

    public func discover(_ entry: CatalogEntry, context: DiscoveryContext) async -> [DiscoveredTarget] {
        guard case .toolchains(let manager) = entry.discovery, manager != .system else { return [] }
        let d = await detection(context)
        // Plazo agotado: lo que no se evaluó del todo no se ofrece.
        guard d.complete else { return [] }
        if manager == .homebrew, d.brew == nil { return [] }
        let sizeDeadline = ContinuousClock().now.advanced(by: TimeBudget.sizeMeasure)
        var used = Set<String>()
        var result: [DiscoveredTarget] = []
        for install in d.installs where install.manager == manager && !install.informational
            && Self.isDuplicate(install, in: d.installs) {
            if install.target.hasPrefix("/") ? install.target.contains("/..") : !Self.isSafeName(install.target) {
                continue
            }
            var suffix = install.plugin.map { "\($0) \(install.version)" } ?? "\(install.language.rawValue) \(install.name)"
            if !used.insert(suffix).inserted { suffix += " (\(Format.tildePath(install.path, home: context.home)))" }
            var target = DiscoveredTarget(
                idSuffix: suffix, paths: manager == .homebrew ? [] : [install.path],
                targets: entry.cleanup.usesTargets ? [install.target] : [],
                details: details(install, d), lastModified: install.lastUsed)
            switch Self.verdict(install, d) {
            case .red(let reason):
                target.floor = .doNotTouch
                target.floorReason = reason
                target.preselectable = false
            case .blocked(let reason):
                target.blockedReason = reason
                target.preselectable = false
            case .amber:
                target.preselectable = d.usage.projectsComplete && !d.usage.noPreselect.contains(install.language)
                    && (install.lastUsed.map { $0 < context.now.addingTimeInterval(-Self.unusedAfter) } ?? false)
            }
            if manager == .homebrew {
                let left = max(.zero, ContinuousClock().now.duration(to: sizeDeadline))
                if let summary = TreeWalk.summarize(install.path, budget: left) {
                    target.bytes = summary.bytes
                } else {
                    target.bytes = 0
                    target.sizeNote = "Tamaño desconocido"
                    target.blockedReason = target.blockedReason ?? "No se pudo medir a tiempo."
                    target.preselectable = false
                }
            }
            result.append(target)
        }
        return result
    }

    private func details(_ install: InstalledToolchain, _ d: ToolchainDetection) -> [String] {
        var lines = [install.lastUsed.map { "Usada por última vez: \(ProjectArtifactRules.day($0))" } ?? "Sin fecha de uso"]
        let key = Self.groupKey(install)
        let others = d.installs.filter { Self.groupKey($0) == key && $0.path != install.path }.map(\.name)
        if !others.isEmpty { lines.append("Otras versiones: \(others.joined(separator: ", "))") }
        if install.manager == .asdf { lines.append("Luego ejecuta asdf reshim") }
        return lines
    }

    public func revalidate(_ entry: CatalogEntry, item: CleanupItem, context: DiscoveryContext) async -> String? {
        guard case .toolchains(let manager) = entry.discovery, manager != .system else {
            return "Airy no sabe comprobar «\(entry.title)» todavía; no se toca."
        }
        let gone = "Ya no es una versión instalada de «\(entry.title)»."
        let byTarget = entry.cleanup.usesTargets
        var wanted: String
        if byTarget {
            guard item.targets.count == 1, let target = item.targets.first else {
                return "«\(entry.title)» debe ser una sola versión."
            }
            if manager == .conda {
                let parent = (target as NSString).deletingLastPathComponent
                guard target.hasPrefix("/"), !target.contains("/.."), !target.hasSuffix("/") else {
                    return "Objetivo no válido para «\(entry.title)»: \(target)."
                }
                guard (parent as NSString).lastPathComponent == "envs" else { return CommandPolicy.condaBaseReason }
            } else if !Self.isSafeName(target) {
                return "Objetivo no válido para «\(entry.title)»: \(target)."
            }
            wanted = target
        } else {
            guard item.targets.isEmpty, item.paths.count == 1, let path = item.paths.first, path.hasPrefix("/") else {
                return "«\(entry.title)» debe ser una sola carpeta."
            }
            wanted = path
        }
        let d = await detection(context)
        guard d.complete else { return "No se pudo comprobar a tiempo si esta versión está en uso." }
        let match = d.installs.first { install in
            guard install.manager == manager, !install.informational else { return false }
            if byTarget {
                let paths = manager == .homebrew ? [] : [install.path]
                return install.target == wanted && item.paths.map(RiskPolicy.canonical) == paths.map(RiskPolicy.canonical)
            }
            return RiskPolicy.canonical(install.path) == RiskPolicy.canonical(wanted)
        }
        guard let install = match else { return gone }
        guard Self.isDuplicate(install, in: d.installs) else { return "Ya no hay otra versión de la misma herramienta." }
        if manager == .homebrew, d.brew == nil { return "No se encontró Homebrew en este Mac." }
        switch Self.verdict(install, d) {
        case .red(let reason), .blocked(let reason): return reason
        case .amber: break
        }
        guard d.usage.projectsComplete else {
            return "No se pudo comprobar a tiempo si algún proyecto pide esta versión."
        }
        return nil
    }
}
