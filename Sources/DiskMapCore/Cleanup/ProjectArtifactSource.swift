import Foundation

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

    /// `bin` solo en proyectos .NET (con `bin/Debug` o `bin/Release`); `vendor` solo con Composer.
    static func qualifies(_ folder: String, name: String) -> Bool {
        let parent = (folder as NSString).deletingLastPathComponent
        switch name {
        case "bin":
            let names = (try? FileManager.default.contentsOfDirectory(atPath: parent)) ?? []
            let dotnet = names.contains { $0.hasSuffix(".csproj") || $0.hasSuffix(".fsproj") || $0.hasSuffix(".vbproj") }
            return dotnet && (isRealDirectory(folder + "/Debug") || isRealDirectory(folder + "/Release"))
        case "vendor":
            return exists(parent + "/composer.json") && exists(folder + "/autoload.php")
        default:
            return true
        }
    }

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "es_ES")
        formatter.dateFormat = "dd/MM/yyyy"
        return formatter
    }()

    static func day(_ date: Date) -> String { dateFormatter.string(from: date) }
}

/// Fichas `discovery {"type":"projectArtifacts"}`: carpetas regenerables (node_modules, target…) de proyectos
/// en los que no se ha cambiado nada en `staleAfter`. Un paseo secuencial (sin tareas en paralelo), con plazo
/// por proyecto y plazo total; al agotarse el total se devuelve solo lo ya revisado del todo.
public struct ProjectArtifactSource: CleanupTargetSource {
    static let gitTimeout: TimeInterval = 10

    private let searchRoots: [String]?
    private let maxDepth: Int
    private let projectBudget: Duration
    private let totalBudget: Duration

    public init(searchRoots: [String]? = nil, maxDepth: Int = 6,
                projectBudget: Duration = .seconds(5), totalBudget: Duration = .seconds(30)) {
        self.searchRoots = searchRoots; self.maxDepth = maxDepth
        self.projectBudget = projectBudget; self.totalBudget = totalBudget
    }

    // MARK: - Detección

    public func discover(_ entry: CatalogEntry, context: DiscoveryContext) async -> [DiscoveredTarget] {
        guard case .projectArtifacts(let names, let cachedirTag) = entry.discovery else { return [] }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: totalBudget)
        let skipped = Self.artifactNames(in: context.catalog)
        let homeReal = CleanupTargets.realPath(context.home) ?? context.home
        var result: [DiscoveredTarget] = []
        for root in roots(home: context.home) {
            for project in projects(in: root, skipped: skipped, deadline: deadline) {
                guard clock.now < deadline, !Task.isCancelled else { return result }
                guard let signal = Self.signal(of: project, budget: budget(until: deadline)) else { continue }
                guard signal < context.now.addingTimeInterval(-ProjectArtifactRules.staleAfter) else { continue }
                let folders = Self.artifacts(in: project, names: Set(names), cachedirTag: cachedirTag,
                                             skipped: skipped, deadline: deadline)
                for folder in folders {
                    guard clock.now < deadline else { return result }
                    let verdict = await inspect(folder, root: root, deadline: deadline, runner: context.runner)
                    // Sin tiempo total, lo que estaba a medias no se ofrece.
                    if case .blocked = verdict, clock.now >= deadline { return result }
                    result.append(target(folder, verdict: verdict, signal: signal, home: homeReal))
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
        case .ok(let bytes):
            target.bytes = bytes
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
        if names.contains(name), !ProjectArtifactRules.qualifies(real, name: name) {
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

    /// Primera carpeta con marcador bajando desde `root` hasta el padre de `folder`, sin pasar por carpetas
    /// que la búsqueda poda ni pasar de `maxDepth`.
    private func outermostProject(containing folder: String, root: String, skipped: Set<String>) -> String? {
        let parent = (folder as NSString).deletingLastPathComponent
        let rest = parent == root ? [] : parent.dropFirst(root.count + 1).split(separator: "/").map(String.init)
        var current = root
        for depth in 0...rest.count {
            if depth > 0 {
                let component = rest[depth - 1]
                if ProjectArtifactRules.walkPruned.contains(component) || skipped.contains(component) { return nil }
                current += "/" + component
            }
            guard depth <= maxDepth, !ProjectArtifactRules.isUbiquitous(current) else { return nil }
            if ProjectArtifactRules.isProjectRoot(current) { return current }
        }
        return nil
    }

    // MARK: - Piezas

    enum Verdict: Equatable {
        case ok(Int64)
        case floor(String, Int64)
        case blocked(String)
    }

    /// Guardias de una carpeta candidata: repositorio anidado, claves y archivos guardados en Git.
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
        guard Self.underGit(parent, root: root) else { return .ok(summary.bytes) }
        let failure = Verdict.blocked("No se pudo comprobar con Git si guarda archivos aquí.")
        guard let git = await runner.resolve("git"),
              let output = try? await runner.run(git, ["-C", parent, "ls-files", "-z", "--",
                                                       (folder as NSString).lastPathComponent],
                                                 timeout: Self.gitTimeout),
              output.status == 0 else { return failure }
        if !output.stdout.isEmpty {
            return .floor("Git guarda archivos aquí: no es solo un resto de compilación.", summary.bytes)
        }
        return .ok(summary.bytes)
    }

    /// Alguna carpeta desde `folder` hasta `root` (incluidas) tiene `.git`.
    static func underGit(_ folder: String, root: String) -> Bool {
        var current = folder
        while true {
            if ProjectArtifactRules.exists(current + "/.git") { return true }
            if current == root || current.count <= root.count || current == "/" { return false }
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
            if ProjectArtifactRules.isUbiquitous(real) { continue }
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
                guard clock.now < deadline else { return found }
                if ProjectArtifactRules.isProjectRoot(folder) {
                    found.append(folder)
                    continue
                }
                guard depth < maxDepth else { continue }
                let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
                for name in names.sorted()
                where !ProjectArtifactRules.walkPruned.contains(name) && !skipped.contains(name) {
                    let child = folder + "/" + name
                    guard ProjectArtifactRules.isRealDirectory(child), !ProjectArtifactRules.isUbiquitous(child)
                    else { continue }
                    next.append(child)
                }
            }
            level = next
            if level.isEmpty { break }
        }
        return found
    }

    /// Carpetas reales con nombre de la ficha (o `CACHEDIR.TAG`) dentro del proyecto, sin entrar en `.git`,
    /// en lo ya encontrado ni en las carpetas de las otras fichas.
    static func artifacts(in project: String, names: Set<String>, cachedirTag: Bool, skipped: Set<String>,
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
                    if ProjectArtifactRules.qualifies(child, name: name) { found.append(child) }
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
