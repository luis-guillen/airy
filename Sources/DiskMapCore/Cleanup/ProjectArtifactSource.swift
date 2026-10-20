import Foundation
import Synchronization

/// Reglas de «proyectos sin tocar»: qué es un proyecto, qué cuenta como señal de uso y dónde se busca.
public enum ProjectArtifactRules {
    /// Una carpeta con alguno de estos nombres dentro es la raíz de un proyecto.
    public static let rootMarkers = ["package.json", "pyproject.toml", "requirements.txt", "Cargo.toml", ".git"]
    /// No cuentan para la señal de uso (tampoco `.git/objects`).
    public static let signalExcluded: Set<String> = ["node_modules", ".venv", "target", ".next", "build", "dist"]
    public static let staleAfter: TimeInterval = 90 * 86_400
    /// Primera línea de un `CACHEDIR.TAG` válido (https://bford.info/cachedir/).
    public static let cachedirSignature = "Signature: 8a477f597d28d172789f06886806bc55"
    public static let searchRootNames = ["Projects", "Developer", "dev", "Code", "GitHub", "Repos", "src", "Workspace",
                                         "orca", "Desktop", "Documents"]
    /// Nunca se entra en estas carpetas al buscar proyectos.
    static let walkPruned: Set<String> = [".git", "Library", ".Trash", "Applications"]

    /// `~/<nombre>` de `searchRootNames` que existen y son carpetas reales (no enlaces).
    public static func defaultSearchRoots(home: String) -> [String] {
        let base = home.count > 1 && home.hasSuffix("/") ? String(home.dropLast()) : home
        return searchRootNames.map { base + "/" + $0 }.filter(isRealDirectory)
    }

    /// Cómo se vuelve a crear una carpeta con ese nombre.
    public static func regenerationHint(for name: String) -> String {
        switch name {
        case "node_modules": return "Se rehace con npm install (o pnpm/yarn)."
        case ".venv", "venv": return "Se rehace creando el entorno de nuevo (uv sync o python -m venv)."
        case "target": return "Se rehace al compilar (cargo build, mvn package…)."
        case ".next": return "Se rehace con next build o next dev."
        case "build", "dist", ".output", "zig-out": return "Se rehace al compilar el proyecto."
        case "Pods": return "Se rehace con pod install."
        case ".gradle", ".cxx": return "Se rehace al compilar con Gradle."
        case ".dart_tool": return "Se rehace con flutter pub get."
        case ".build": return "Se rehace con swift build."
        case "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache": return "Python la vuelve a crear solo."
        case ".tox", ".nox": return "Se rehace al volver a lanzar tox o nox."
        case "DerivedData": return "Xcode la vuelve a crear al compilar."
        case "obj", "bin": return "Se rehace con dotnet build."
        case "vendor": return "Se rehace con composer install."
        case ".terragrunt-cache": return "Terragrunt la vuelve a crear al ejecutarse."
        case ".expo": return "Se rehace con npx expo start."
        default: return "La herramienta que la creó la vuelve a crear al compilar o instalar."
        }
    }

    static func isRealDirectory(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    static func isUbiquitous(_ path: String) -> Bool {
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isUbiquitousItemKey])
        return values?.isUbiquitousItem == true
    }

    static func isProjectRoot(_ path: String) -> Bool {
        rootMarkers.contains { exists(path + "/" + $0) }
    }

    /// `CACHEDIR.TAG` (fichero normal) que empieza por la firma.
    static func hasCachedirTag(_ folder: String) -> Bool {
        let tag = folder + "/CACHEDIR.TAG"
        var info = stat()
        guard lstat(tag, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              let handle = FileHandle(forReadingAtPath: tag) else { return false }
        defer { try? handle.close() }
        let signature = Data(cachedirSignature.utf8)
        return (try? handle.read(upToCount: signature.count)) == signature
    }

    /// Nombres genéricos (pueden ser código del usuario): fuera de Git nunca se marcan de entrada.
    static let genericNames: Set<String> = ["build", "dist", "target", "obj", "venv"]

    /// Marcadores del ecosistema que crea cada nombre genérico, buscados en el padre o en la raíz del proyecto.
    static let ecosystemMarkers: [String: [String]] = [
        "target": ["Cargo.toml"],
        "dist": ["package.json"], ".next": ["package.json"],
        "build": ["build.gradle", "build.gradle.kts", "package.json", "CMakeLists.txt"],
        "venv": ["pyproject.toml", "requirements.txt"], ".venv": ["pyproject.toml", "requirements.txt"],
    ]

    /// Un nombre que podría ser código solo vale con su ecosistema: `bin` con un proyecto .NET y `bin/Debug`
    /// o `bin/Release`; `vendor` con Composer y `vendor/autoload.php`; `obj` con un proyecto .NET; `target`,
    /// `dist`, `.next`, `build`, `venv` y `.venv` con su marcador en el padre o en la raíz del proyecto.
    static func qualifies(_ folder: String, name: String, project: String) -> Bool {
        let parent = (folder as NSString).deletingLastPathComponent
        let places = parent == project ? [parent] : [parent, project]
        switch name {
        case "bin":
            return hasDotNetProject(parent)
                && (isRealDirectory(folder + "/Debug") || isRealDirectory(folder + "/Release"))
        case "vendor":
            return exists(parent + "/composer.json") && exists(folder + "/autoload.php")
        case "obj":
            return places.contains(where: hasDotNetProject)
        default:
            guard let markers = ecosystemMarkers[name] else { return true }
            return places.contains { place in markers.contains { exists(place + "/" + $0) } }
        }
    }

    private static func hasDotNetProject(_ folder: String) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        return names.contains { $0.hasSuffix(".csproj") || $0.hasSuffix(".fsproj") || $0.hasSuffix(".vbproj") }
    }

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "es_ES")
        formatter.dateFormat = "dd/MM/yyyy"
        return formatter
    }()

    static func day(_ date: Date) -> String { dateFormatter.string(from: date) }
}

/// Resultado del paseo de proyectos de una pasada de detección (por id de ficha). Lo comparten todas las
/// fichas `projectArtifacts` del mismo `DiscoveryContext`: un solo paseo y un solo plazo por pasada.
final class ProjectWalkMemo: Sendable {
    private let state = Mutex<[String: [DiscoveredTarget]]?>(nil)

    func targets(compute: () async -> [String: [DiscoveredTarget]]) async -> [String: [DiscoveredTarget]] {
        if let done = state.withLock({ $0 }) { return done }
        let fresh = await compute()
        return state.withLock { current in
            if let current { return current }
            current = fresh
            return fresh
        }
    }
}

/// Fichas `discovery {"type":"projectArtifacts"}`: carpetas regenerables (node_modules, target…) de proyectos
/// en los que no se ha cambiado nada en `staleAfter`. Un solo paseo secuencial por pasada (sin tareas en
/// paralelo) para todas las fichas, con plazo por proyecto y un plazo total; al agotarse el total se devuelve
/// solo lo ya revisado del todo.
public struct ProjectArtifactSource: CleanupTargetSource {
    static let gitTimeout: TimeInterval = 10

    private let searchRoots: [String]?
    private let maxDepth: Int
    private let projectBudget: Duration
    private let totalBudget: Duration
    private let isUbiquitous: @Sendable (String) -> Bool
    /// Solo para pruebas: se llama cada vez que empieza un paseo completo de las raíces.
    private let onWalk: (@Sendable () -> Void)?

    public init(searchRoots: [String]? = nil, maxDepth: Int = 6,
                projectBudget: Duration = .seconds(5), totalBudget: Duration = .seconds(30)) {
        self.init(searchRoots: searchRoots, maxDepth: maxDepth, projectBudget: projectBudget,
                  totalBudget: totalBudget, isUbiquitous: ProjectArtifactRules.isUbiquitous, onWalk: nil)
    }

    init(searchRoots: [String]? = nil, maxDepth: Int = 6, projectBudget: Duration = .seconds(5),
         totalBudget: Duration = .seconds(30), isUbiquitous: @escaping @Sendable (String) -> Bool,
         onWalk: (@Sendable () -> Void)? = nil) {
        self.searchRoots = searchRoots; self.maxDepth = maxDepth
        self.projectBudget = projectBudget; self.totalBudget = totalBudget
        self.isUbiquitous = isUbiquitous; self.onWalk = onWalk
    }

    // MARK: - Detección

    public func discover(_ entry: CatalogEntry, context: DiscoveryContext) async -> [DiscoveredTarget] {
        guard case .projectArtifacts = entry.discovery else { return [] }
        let all = await context.projectWalk.targets { await walk(context: context, including: entry) }
        return all[entry.id] ?? []
    }

    /// Un paseo para todas las fichas `projectArtifacts` del catálogo (en su orden), con un solo plazo.
    private func walk(context: DiscoveryContext, including entry: CatalogEntry) async -> [String: [DiscoveredTarget]] {
        onWalk?()
        var fichas: [(id: String, names: Set<String>, cachedirTag: Bool)] = []
        for candidate in context.catalog.entries.contains(where: { $0.id == entry.id })
            ? context.catalog.entries : context.catalog.entries + [entry] {
            if case .projectArtifacts(let names, let cachedirTag) = candidate.discovery {
                fichas.append((candidate.id, Set(names), cachedirTag))
            }
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: totalBudget)
        let skipped = Self.artifactNames(in: context.catalog).union(fichas.flatMap(\.names))
        let homeReal = CleanupTargets.realPath(context.home) ?? context.home
        let cutoff = context.now.addingTimeInterval(-ProjectArtifactRules.staleAfter)
        var result: [String: [DiscoveredTarget]] = [:]
        for root in roots(home: context.home) {
            for project in projects(in: root, skipped: skipped, deadline: deadline) {
                guard clock.now < deadline, !Task.isCancelled else { return result }
                guard let signal = Self.signal(of: project, budget: budget(until: deadline)), signal < cutoff
                else { continue }
                for ficha in fichas {
                    let folders = artifacts(in: project, names: ficha.names, cachedirTag: ficha.cachedirTag,
                                            skipped: skipped, deadline: deadline)
                    for folder in folders {
                        guard clock.now < deadline, !Task.isCancelled else { return result }
                        let verdict = await inspect(folder, root: root, deadline: deadline, runner: context.runner)
                        // Sin tiempo total, lo que estaba a medias no se ofrece.
                        if case .blocked = verdict, clock.now >= deadline { return result }
                        result[ficha.id, default: []].append(
                            target(folder, verdict: verdict, signal: signal, home: homeReal))
                    }
                }
            }
        }
        return result
    }

    private func target(_ folder: String, verdict: Verdict, signal: Date, home: String) -> DiscoveredTarget {
        let name = (folder as NSString).lastPathComponent
        var target = DiscoveredTarget(
            idSuffix: Format.tildePath(folder, home: home), paths: [folder],
            details: ["Proyecto sin tocar desde \(ProjectArtifactRules.day(signal))",
                      ProjectArtifactRules.regenerationHint(for: name)],
            lastModified: signal)
        switch verdict {
        case .ok(let bytes, let inGit):
            target.bytes = bytes
            // Un nombre genérico sin Git que diga que es un resto ignorado se ofrece, pero sin marcar.
            if !inGit, ProjectArtifactRules.genericNames.contains(name) { target.preselectable = false }
        case .floor(let reason, let bytes):
            target.bytes = bytes
            target.floor = .doNotTouch
            target.floorReason = reason
        case .blocked(let reason):
            target.bytes = 0
            target.sizeNote = "Tamaño desconocido"
            target.blockedReason = reason
        }
        return target
    }

    // MARK: - Revalidación

    public func revalidate(_ entry: CatalogEntry, item: CleanupItem, context: DiscoveryContext) async -> String? {
        guard case .projectArtifacts(let names, let cachedirTag) = entry.discovery else {
            return "Airy no sabe comprobar «\(entry.title)» todavía; no se toca."
        }
        guard item.paths.count == 1, let path = item.paths.first, path.hasPrefix("/") else {
            return "«\(entry.title)» debe ser una sola carpeta."
        }
        guard ProjectArtifactRules.isRealDirectory(path) else { return "Ya no es una carpeta: \(path)." }
        let name = (path as NSString).lastPathComponent
        guard names.contains(name) || (cachedirTag && ProjectArtifactRules.hasCachedirTag(path)) else {
            return "No es una carpeta regenerable de «\(entry.title)»: \(path)."
        }
        guard let real = CleanupTargets.realPath(path), RiskPolicy.canonical(real) == RiskPolicy.canonical(path) else {
            return "La ruta pasa por un enlace: \(path)."
        }
        let roots = roots(home: context.home)
        guard let root = roots.first(where: {
            real != $0 && RiskPolicy.isInside(RiskPolicy.canonical(real), root: RiskPolicy.canonical($0))
        }) else {
            return "Ya no está en ninguna carpeta donde Airy busca proyectos."
        }
        guard let project = outermostProject(containing: real, root: root,
                                             skipped: Self.artifactNames(in: context.catalog)) else {
            return "Ya no está dentro de un proyecto."
        }
        if names.contains(name), !ProjectArtifactRules.qualifies(real, name: name, project: project) {
            return "No es una carpeta regenerable de «\(entry.title)»: \(path)."
        }
        let deadline = ContinuousClock().now.advanced(by: totalBudget)
        guard let signal = Self.signal(of: project, budget: budget(until: deadline)) else {
            return "No se pudo revisar a tiempo."
        }
        guard signal < context.now.addingTimeInterval(-ProjectArtifactRules.staleAfter) else {
            return "Has tocado el proyecto hace poco (\(ProjectArtifactRules.day(signal))): no se borra."
        }
        switch await inspect(real, root: root, deadline: deadline, runner: context.runner) {
        case .ok: return nil
        case .floor(let reason, _), .blocked(let reason): return reason
        }
    }

    /// Primera carpeta con marcador bajando desde `root` hasta el padre de `folder`, sin pasar de `maxDepth`;
    /// ningún componente entre `root` y `folder` puede ser una carpeta que la detección no recorre.
    private func outermostProject(containing folder: String, root: String, skipped: Set<String>) -> String? {
        let parent = (folder as NSString).deletingLastPathComponent
        let rest = parent == root ? [] : parent.dropFirst(root.count + 1).split(separator: "/").map(String.init)
        if rest.contains(where: { $0 == ".git" || ProjectArtifactRules.walkPruned.contains($0) || skipped.contains($0) }) {
            return nil
        }
        var current = root
        for depth in 0...rest.count {
            if depth > 0 { current += "/" + rest[depth - 1] }
            guard depth <= maxDepth, !isUbiquitous(current) else { return nil }
            if ProjectArtifactRules.isProjectRoot(current) { return current }
        }
        return nil
    }

    // MARK: - Piezas

    enum Verdict: Equatable {
        /// `inGit`: dentro de un repositorio que dice que la carpeta está ignorada y sin archivos guardados.
        case ok(Int64, inGit: Bool)
        case floor(String, Int64)
        case blocked(String)
    }

    /// Guardias de una carpeta candidata: repositorio anidado, claves y, dentro de Git, que no guarde archivos
    /// y que esté ignorada. `TreeWalk.watched` tiene un máximo: cualquier entrada vigilada ya sube el riesgo,
    /// así que el orden de las comprobaciones solo elige el motivo.
    private func inspect(_ folder: String, root: String, deadline: ContinuousClock.Instant,
                         runner: any CommandRunning) async -> Verdict {
        guard let summary = TreeWalk.summarize(folder, budget: budget(until: deadline), watch: {
            $0 == ".git" || $0.hasSuffix("-keypair.json")
        }) else {
            return .blocked("No se pudo revisar a tiempo.")
        }
        let watched = summary.watched.map { ($0 as NSString).lastPathComponent }
        if watched.contains(".git") { return .floor("Contiene otro repositorio Git dentro.", summary.bytes) }
        if let key = watched.first(where: { $0.hasSuffix("-keypair.json") }) {
            return .floor("Contiene claves (\(key)): no se regeneran.", summary.bytes)
        }
        let parent = (folder as NSString).deletingLastPathComponent
        guard Self.underGit(parent) else { return .ok(summary.bytes, inGit: false) }
        let failure = Verdict.blocked("No se pudo comprobar con Git si guarda archivos aquí.")
        let name = (folder as NSString).lastPathComponent
        guard let git = await runner.resolve("git"),
              let tracked = await Self.git(git, ["ls-files", "-z", "--", name], in: parent, runner: runner,
                                           deadline: deadline),
              tracked.status == 0 else { return failure }
        if !tracked.stdout.isEmpty {
            return .floor("Git guarda archivos aquí: no es solo un resto de compilación.", summary.bytes)
        }
        guard let ignored = await Self.git(git, ["check-ignore", "-q", "--", name], in: parent, runner: runner,
                                           deadline: deadline) else { return failure }
        switch ignored.status {
        case 0: return .ok(summary.bytes, inGit: true)
        case 1: return .floor("Git no la ignora: puede ser tuya, no un resto de compilación.", summary.bytes)
        default: return failure
        }
    }

    /// `git -c core.fsmonitor=false -C <carpeta> …` con plazo = mín(10 s, lo que queda); `nil` sin tiempo o si
    /// falla.
    static func git(_ git: String, _ arguments: [String], in folder: String, runner: any CommandRunning,
                    deadline: ContinuousClock.Instant) async -> CommandOutput? {
        let left = ContinuousClock().now.duration(to: deadline)
        let seconds = Double(left.components.seconds) + Double(left.components.attoseconds) / 1e18
        guard seconds > 0 else { return nil }
        return try? await runner.run(git, ["-c", "core.fsmonitor=false", "-C", folder] + arguments,
                                     timeout: min(gitTimeout, seconds))
    }

    /// Alguna carpeta desde `folder` hasta `/` tiene `.git` (también un repositorio por encima de la raíz).
    static func underGit(_ folder: String) -> Bool {
        var current = folder
        while true {
            if ProjectArtifactRules.exists(current + "/.git") { return true }
            if current == "/" || current.isEmpty { return false }
            current = (current as NSString).deletingLastPathComponent
        }
    }

    /// Fecha más reciente del proyecto sin las carpetas regenerables ni `.git/objects`; `nil` sin tiempo.
    static func signal(of project: String, budget: Duration) -> Date? {
        TreeWalk.summarize(project, budget: budget, prune: { name, relative in
            ProjectArtifactRules.signalExcluded.contains(name)
                || (name == "objects" && (relative == ".git/objects" || relative.hasSuffix("/.git/objects")))
        })?.latestModification
    }

    private func budget(until deadline: ContinuousClock.Instant) -> Duration {
        let remaining = ContinuousClock().now.duration(to: deadline)
        return remaining < projectBudget ? max(remaining, .zero) : projectBudget
    }

    /// Nombres de carpeta de todas las fichas de proyectos (no se buscan proyectos dentro de ellas).
    static func artifactNames(in catalog: Catalog) -> Set<String> {
        var names = ProjectArtifactRules.signalExcluded
        for entry in catalog.entries {
            if case .projectArtifacts(let list, _) = entry.discovery { names.formUnion(list) }
        }
        return names
    }

    /// Raíces de búsqueda reales, sin las de `~/Library` (iCloud, CloudStorage…), las ubicuas ni las repetidas.
    private func roots(home: String) -> [String] {
        let homes = Set([home, CleanupTargets.realPath(home) ?? home].map(RiskPolicy.canonical))
        var result: [String] = []
        for candidate in searchRoots ?? ProjectArtifactRules.defaultSearchRoots(home: home) {
            guard let real = CleanupTargets.realPath(candidate), ProjectArtifactRules.isRealDirectory(real) else {
                continue
            }
            let canonical = RiskPolicy.canonical(real)
            if homes.contains(where: { RiskPolicy.isInside(canonical, root: $0 + "/library") }) { continue }
            if isUbiquitous(real) { continue }
            if result.contains(where: { RiskPolicy.isInside(canonical, root: RiskPolicy.canonical($0)) }) { continue }
            result.removeAll { RiskPolicy.isInside(RiskPolicy.canonical($0), root: canonical) }
            result.append(real)
        }
        return result
    }

    /// BFS hasta `maxDepth` sin seguir enlaces; un proyecto es la carpeta más externa con marcador.
    private func projects(in root: String, skipped: Set<String>, deadline: ContinuousClock.Instant) -> [String] {
        let clock = ContinuousClock()
        var found: [String] = []
        var level = [root]
        for depth in 0...maxDepth {
            var next: [String] = []
            for folder in level {
                guard clock.now < deadline, !Task.isCancelled else { return found }
                if ProjectArtifactRules.isProjectRoot(folder) {
                    found.append(folder)
                    continue
                }
                guard depth < maxDepth else { continue }
                let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
                for name in names.sorted()
                where !ProjectArtifactRules.walkPruned.contains(name) && !skipped.contains(name) {
                    let child = folder + "/" + name
                    guard ProjectArtifactRules.isRealDirectory(child), !isUbiquitous(child) else { continue }
                    next.append(child)
                }
            }
            level = next
            if level.isEmpty { break }
        }
        return found
    }

    /// Carpetas reales con nombre de la ficha (y su ecosistema) o `CACHEDIR.TAG` dentro del proyecto, sin
    /// entrar en `.git`, en lo ya encontrado ni en las carpetas de las otras fichas.
    private func artifacts(in project: String, names: Set<String>, cachedirTag: Bool, skipped: Set<String>,
                           deadline: ContinuousClock.Instant) -> [String] {
        let clock = ContinuousClock()
        var found: [String] = []
        var stack = [project]
        while let folder = stack.popLast() {
            guard clock.now < deadline else { return found }
            let children = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            for name in children.sorted().reversed() where name != ".git" {
                let child = folder + "/" + name
                guard ProjectArtifactRules.isRealDirectory(child) else { continue }
                if names.contains(name) {
                    if ProjectArtifactRules.qualifies(child, name: name, project: project) { found.append(child) }
                } else if skipped.contains(name) {
                    continue
                } else if cachedirTag, ProjectArtifactRules.hasCachedirTag(child) {
                    found.append(child)
                } else {
                    stack.append(child)
                }
            }
        }
        return found.sorted()
    }
}
