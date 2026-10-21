import Foundation
import Synchronization

/// Rules for "untouched projects": what a project is, what counts as a usage signal and where to look.
public enum ProjectArtifactRules {
    /// A folder with one of these names inside is a project root.
    public static let rootMarkers = ["package.json", "pyproject.toml", "requirements.txt", "Cargo.toml", ".git"]
    /// They do not count for the usage signal (nor does `.git/objects`).
    public static let signalExcluded: Set<String> = ["node_modules", ".venv", "target", ".next", "build", "dist"]
    public static let staleAfter: TimeInterval = 90 * 86_400
    /// First line of a valid `CACHEDIR.TAG` (https://bford.info/cachedir/).
    public static let cachedirSignature = "Signature: 8a477f597d28d172789f06886806bc55"
    public static let searchRootNames = ["Projects", "Developer", "dev", "Code", "GitHub", "Repos", "src", "Workspace",
                                         "orca", "Desktop", "Documents"]
    /// These folders are never entered when looking for projects.
    static let walkPruned: Set<String> = [".git", "Library", ".Trash", "Applications"]

    /// `~/<name>` from `searchRootNames` that exist and are real folders (not links).
    public static func defaultSearchRoots(home: String) -> [String] {
        let base = home.count > 1 && home.hasSuffix("/") ? String(home.dropLast()) : home
        return searchRootNames.map { base + "/" + $0 }.filter(isRealDirectory)
    }

    /// How a folder with that name is recreated.
    public static func regenerationHint(for name: String) -> String {
        switch name {
        case "node_modules": return String(localized: "Rebuilt with npm install (or pnpm/yarn).", bundle: .airyCore)
        case ".venv", "venv": return String(localized: "Rebuilt by creating the environment again (uv sync or python -m venv).", bundle: .airyCore)
        case "target": return String(localized: "Rebuilt when compiling (cargo build, mvn package…).", bundle: .airyCore)
        case ".next": return String(localized: "Rebuilt with next build or next dev.", bundle: .airyCore)
        case "build", "dist", ".output", "zig-out": return String(localized: "Rebuilt when compiling the project.", bundle: .airyCore)
        case "Pods": return String(localized: "Rebuilt with pod install.", bundle: .airyCore)
        case ".gradle", ".cxx": return String(localized: "Rebuilt when compiling with Gradle.", bundle: .airyCore)
        case ".dart_tool": return String(localized: "Rebuilt with flutter pub get.", bundle: .airyCore)
        case ".build": return String(localized: "Rebuilt with swift build.", bundle: .airyCore)
        case "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache": return String(localized: "Python recreates it by itself.", bundle: .airyCore)
        case ".tox", ".nox": return String(localized: "Rebuilt when running tox or nox again.", bundle: .airyCore)
        case "DerivedData": return String(localized: "Xcode recreates it when compiling.", bundle: .airyCore)
        case "obj", "bin": return String(localized: "Rebuilt with dotnet build.", bundle: .airyCore)
        case "vendor": return String(localized: "Rebuilt with composer install.", bundle: .airyCore)
        case ".terragrunt-cache": return String(localized: "Terragrunt recreates it when it runs.", bundle: .airyCore)
        case ".expo": return String(localized: "Rebuilt with npx expo start.", bundle: .airyCore)
        default: return String(localized: "The tool that created it recreates it when compiling or installing.", bundle: .airyCore)
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

    /// `CACHEDIR.TAG` (regular file) that starts with the signature.
    static func hasCachedirTag(_ folder: String) -> Bool {
        let tag = folder + "/CACHEDIR.TAG"
        var info = stat()
        guard lstat(tag, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              let handle = FileHandle(forReadingAtPath: tag) else { return false }
        defer { try? handle.close() }
        let signature = Data(cachedirSignature.utf8)
        return (try? handle.read(upToCount: signature.count)) == signature
    }

    /// Generic names (they may be the user's code): outside Git they never start checked.
    static let genericNames: Set<String> = ["build", "dist", "target", "obj", "venv"]

    /// Ecosystem markers that each generic name creates, looked for in the parent or in the project root.
    static let ecosystemMarkers: [String: [String]] = [
        "target": ["Cargo.toml"],
        "dist": ["package.json"], ".next": ["package.json"],
        "build": ["build.gradle", "build.gradle.kts", "package.json", "CMakeLists.txt"],
        "venv": ["pyproject.toml", "requirements.txt"], ".venv": ["pyproject.toml", "requirements.txt"],
    ]

    /// A name that could be code only counts with its ecosystem: `bin` with a .NET project and `bin/Debug`
    /// or `bin/Release`; `vendor` with Composer and `vendor/autoload.php`; `obj` with a .NET project; `target`,
    /// `dist`, `.next`, `build`, `venv` and `.venv` with their marker in the parent or in the project root.
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

/// Result of the project walk of a detection pass (per entry id). Every `projectArtifacts` entry of the
/// same `DiscoveryContext` shares it: a single walk and a single time limit per pass.
final class ProjectWalkMemo: Sendable {
    private let state = Mutex<[String: [DiscoveredTarget]]?>(nil)
    private let list = Mutex<ProjectList?>(nil)

    /// List of the pass's projects (a single BFS), shared by artifacts, pins and dependencies.
    func projectList(compute: () async -> ProjectList) async -> ProjectList {
        if let done = list.withLock({ $0 }) { return done }
        let fresh = await compute()
        return list.withLock { current in
            if let current { return current }
            current = fresh
            return fresh
        }
    }

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

/// Project roots found in a pass; `complete == false` if the BFS was cut short by the time limit.
public struct ProjectList: Sendable, Equatable {
    public var projects: [String]
    public var complete: Bool

    public init(projects: [String], complete: Bool) { self.projects = projects; self.complete = complete }
}

/// Entries with `discovery {"type":"projectArtifacts"}`: regenerable folders (node_modules, target…) of projects
/// where nothing has changed in `staleAfter`. A single sequential walk per pass (without parallel
/// tasks) for every entry, with a per-project time limit and a total one; when the total runs out, only
/// what was fully reviewed is returned.
public struct ProjectArtifactSource: CleanupTargetSource {
    static let gitTimeout: TimeInterval = 10

    private let searchRoots: [String]?
    private let maxDepth: Int
    private let projectBudget: Duration
    private let totalBudget: Duration
    private let isUbiquitous: @Sendable (String) -> Bool
    /// Tests only: called every time a full walk of the roots starts.
    private let onWalk: (@Sendable () -> Void)?
    /// Tests only: called every time a project BFS starts.
    private let onListProjects: (@Sendable () -> Void)?

    public init(searchRoots: [String]? = nil, maxDepth: Int = 6,
                projectBudget: Duration = .seconds(5), totalBudget: Duration = .seconds(30)) {
        self.init(searchRoots: searchRoots, maxDepth: maxDepth, projectBudget: projectBudget,
                  totalBudget: totalBudget, isUbiquitous: ProjectArtifactRules.isUbiquitous, onWalk: nil)
    }

    init(searchRoots: [String]? = nil, maxDepth: Int = 6, projectBudget: Duration = .seconds(5),
         totalBudget: Duration = .seconds(30), isUbiquitous: @escaping @Sendable (String) -> Bool,
         onWalk: (@Sendable () -> Void)? = nil, onListProjects: (@Sendable () -> Void)? = nil) {
        self.searchRoots = searchRoots; self.maxDepth = maxDepth
        self.projectBudget = projectBudget; self.totalBudget = totalBudget
        self.isUbiquitous = isUbiquitous; self.onWalk = onWalk; self.onListProjects = onListProjects
    }

    /// Projects of the search roots (BFS with `totalBudget`), memoized in `context.projectWalk`.
    public func projectList(context: DiscoveryContext) async -> ProjectList {
        let deadline = ContinuousClock().now.advanced(by: totalBudget)
        return await context.projectWalk.projectList {
            listProjects(home: context.home, skipped: Self.artifactNames(in: context.catalog), deadline: deadline)
        }
    }

    private func listProjects(home: String, skipped: Set<String>, deadline: ContinuousClock.Instant) -> ProjectList {
        onListProjects?()
        var all: [String] = []
        for root in roots(home: home) {
            let (found, complete) = projects(in: root, skipped: skipped, deadline: deadline)
            all += found
            if !complete { return ProjectList(projects: all, complete: false) }
        }
        return ProjectList(projects: all, complete: true)
    }

    // MARK: - Detection

    public func discover(_ entry: CatalogEntry, context: DiscoveryContext) async -> [DiscoveredTarget] {
        guard case .projectArtifacts = entry.discovery else { return [] }
        let all = await context.projectWalk.targets { await walk(context: context, including: entry) }
        return all[entry.id] ?? []
    }

    /// A walk for every `projectArtifacts` entry of the catalog (in its order), with a single time limit.
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
        let list = await context.projectWalk.projectList {
            listProjects(home: context.home, skipped: skipped, deadline: deadline)
        }
        let searchRoots = roots(home: context.home)
        for project in list.projects {
            let root = searchRoots.first { project == $0 || project.hasPrefix($0 + "/") } ?? project
            guard clock.now < deadline, !Task.isCancelled else { return result }
            guard let signal = Self.signal(of: project, budget: budget(until: deadline)), signal < cutoff
            else { continue }
            for ficha in fichas {
                let folders = artifacts(in: project, names: ficha.names, cachedirTag: ficha.cachedirTag,
                                        skipped: skipped, deadline: deadline)
                for folder in folders {
                    guard clock.now < deadline, !Task.isCancelled else { return result }
                    let verdict = await inspect(folder, root: root, deadline: deadline, runner: context.runner,
                                                scan: context.scan)
                    // Without total time, what was half done is not offered.
                    if case .blocked = verdict, clock.now >= deadline { return result }
                    result[ficha.id, default: []].append(
                        target(folder, verdict: verdict, signal: signal, home: homeReal))
                }
            }
        }
        return result
    }

    private func target(_ folder: String, verdict: Verdict, signal: Date, home: String) -> DiscoveredTarget {
        let name = (folder as NSString).lastPathComponent
        var target = DiscoveredTarget(
            idSuffix: Format.tildePath(folder, home: home), paths: [folder],
            details: [String(localized: "Project untouched since \(ProjectArtifactRules.day(signal))", bundle: .airyCore),
                      ProjectArtifactRules.regenerationHint(for: name)],
            lastModified: signal)
        switch verdict {
        case .ok(let bytes, let inGit):
            target.bytes = bytes
            // A generic name without Git saying it is an ignored leftover is offered, but unchecked.
            if !inGit, ProjectArtifactRules.genericNames.contains(name) { target.preselectable = false }
        case .floor(let reason, let bytes):
            target.bytes = bytes
            target.floor = .doNotTouch
            target.floorReason = reason
        case .blocked(let reason):
            target.bytes = 0
            target.sizeNote = String(localized: "Unknown size", bundle: .airyCore)
            target.blockedReason = reason
        }
        return target
    }

    // MARK: - Revalidation

    public func revalidate(_ entry: CatalogEntry, item: CleanupItem, context: DiscoveryContext) async -> String? {
        guard case .projectArtifacts(let names, let cachedirTag) = entry.discovery else {
            return String(localized: "Airy does not know how to check “\(entry.title)” yet; it is not touched.", bundle: .airyCore)
        }
        guard item.paths.count == 1, let path = item.paths.first, path.hasPrefix("/") else {
            return String(localized: "“\(entry.title)” must be a single folder.", bundle: .airyCore)
        }
        guard ProjectArtifactRules.isRealDirectory(path) else { return String(localized: "It is no longer a folder: \(path).", bundle: .airyCore) }
        let name = (path as NSString).lastPathComponent
        guard names.contains(name) || (cachedirTag && ProjectArtifactRules.hasCachedirTag(path)) else {
            return String(localized: "It is not a regenerable folder of “\(entry.title)”: \(path).", bundle: .airyCore)
        }
        guard let real = CleanupTargets.realPath(path), RiskPolicy.canonical(real) == RiskPolicy.canonical(path) else {
            return String(localized: "The path goes through a link: \(path).", bundle: .airyCore)
        }
        let roots = roots(home: context.home)
        guard let root = roots.first(where: {
            real != $0 && RiskPolicy.isInside(RiskPolicy.canonical(real), root: RiskPolicy.canonical($0))
        }) else {
            return String(localized: "It is no longer in any folder where Airy looks for projects.", bundle: .airyCore)
        }
        guard let project = outermostProject(containing: real, root: root,
                                             skipped: Self.artifactNames(in: context.catalog)) else {
            return String(localized: "It is no longer inside a project.", bundle: .airyCore)
        }
        if names.contains(name), !ProjectArtifactRules.qualifies(real, name: name, project: project) {
            return String(localized: "It is not a regenerable folder of “\(entry.title)”: \(path).", bundle: .airyCore)
        }
        let deadline = ContinuousClock().now.advanced(by: totalBudget)
        guard let signal = Self.signal(of: project, budget: budget(until: deadline)) else {
            return String(localized: "Could not review it in time.", bundle: .airyCore)
        }
        guard signal < context.now.addingTimeInterval(-ProjectArtifactRules.staleAfter) else {
            return String(localized: "You touched the project recently (\(ProjectArtifactRules.day(signal))): it is not deleted.", bundle: .airyCore)
        }
        switch await inspect(real, root: root, deadline: deadline, runner: context.runner) {
        case .ok: return nil
        case .floor(let reason, _), .blocked(let reason): return reason
        }
    }

    /// First folder with a marker going down from `root` to `folder`'s parent, without going past `maxDepth`;
    /// no component between `root` and `folder` may be a folder the detection does not walk.
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

    // MARK: - Pieces

    enum Verdict: Equatable {
        /// `inGit`: inside a repository that says the folder is ignored and keeps no tracked files.
        case ok(Int64, inGit: Bool)
        case floor(String, Int64)
        case blocked(String)
    }

    /// Guards of a candidate folder: nested repository, keys and, inside Git, that it keeps no tracked files
    /// and is ignored. `TreeWalk.watched` has a maximum: any watched entry already raises the risk,
    /// so the order of the checks only picks the reason.
    /// `scan`: the detection's index. If it has the folder, the size comes from it and the disk is only read for
    /// the names (without `lstat`); revalidation (without an index) measures everything on disk again.
    private func inspect(_ folder: String, root: String, deadline: ContinuousClock.Instant,
                         runner: any CommandRunning, scan: FileNode? = nil) async -> Verdict {
        let isWatched: (String) -> Bool = { $0 == ".git" || $0.hasSuffix("-keypair.json") }
        let walked: (bytes: Int64, watched: [String])?
        if let scan, let node = CleanupScanner.node(at: folder, in: scan), node.allocatedSize > 0 {
            walked = TreeWalk.watchedNames(folder, budget: budget(until: deadline), watch: isWatched)
                .map { (node.allocatedSize, $0) }
        } else {
            walked = TreeWalk.summarize(folder, budget: budget(until: deadline), watch: isWatched)
                .map { ($0.bytes, $0.watched) }
        }
        guard let summary = walked else {
            return .blocked(String(localized: "Could not review it in time.", bundle: .airyCore))
        }
        let watched = summary.watched.map { ($0 as NSString).lastPathComponent }
        if watched.contains(".git") { return .floor(String(localized: "It contains another Git repository inside.", bundle: .airyCore), summary.bytes) }
        if let key = watched.first(where: { $0.hasSuffix("-keypair.json") }) {
            return .floor(String(localized: "It contains keys (\(key)): they do not regenerate.", bundle: .airyCore), summary.bytes)
        }
        let parent = (folder as NSString).deletingLastPathComponent
        guard Self.underGit(parent) else { return .ok(summary.bytes, inGit: false) }
        let failure = Verdict.blocked(String(localized: "Could not check with Git whether it keeps files here.", bundle: .airyCore))
        let name = (folder as NSString).lastPathComponent
        guard let git = await runner.resolve("git"),
              let tracked = await Self.git(git, ["ls-files", "-z", "--", name], in: parent, runner: runner,
                                           deadline: deadline),
              tracked.status == 0 else { return failure }
        if !tracked.stdout.isEmpty {
            return .floor(String(localized: "Git keeps files here: it is not just a build leftover.", bundle: .airyCore), summary.bytes)
        }
        guard let ignored = await Self.git(git, ["check-ignore", "-q", "--", name], in: parent, runner: runner,
                                           deadline: deadline) else { return failure }
        switch ignored.status {
        case 0: return .ok(summary.bytes, inGit: true)
        case 1: return .floor(String(localized: "Git does not ignore it: it may be yours, not a build leftover.", bundle: .airyCore), summary.bytes)
        default: return failure
        }
    }

    /// `git -c core.fsmonitor=false -C <folder> …` with time limit = min(10 s, what is left); `nil` without time or if
    /// it fails.
    static func git(_ git: String, _ arguments: [String], in folder: String, runner: any CommandRunning,
                    deadline: ContinuousClock.Instant) async -> CommandOutput? {
        let left = ContinuousClock().now.duration(to: deadline)
        let seconds = Double(left.components.seconds) + Double(left.components.attoseconds) / 1e18
        guard seconds > 0 else { return nil }
        return try? await runner.run(git, ["-c", "core.fsmonitor=false", "-C", folder] + arguments,
                                     timeout: min(gitTimeout, seconds))
    }

    /// Some folder from `folder` up to `/` has `.git` (also a repository above the root).
    static func underGit(_ folder: String) -> Bool {
        var current = folder
        while true {
            if ProjectArtifactRules.exists(current + "/.git") { return true }
            if current == "/" || current.isEmpty { return false }
            current = (current as NSString).deletingLastPathComponent
        }
    }

    /// Most recent date of the project without the regenerable folders nor `.git/objects`; `nil` without time.
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

    /// Folder names of every project entry (projects are not looked for inside them).
    static func artifactNames(in catalog: Catalog) -> Set<String> {
        var names = ProjectArtifactRules.signalExcluded
        for entry in catalog.entries {
            if case .projectArtifacts(let list, _) = entry.discovery { names.formUnion(list) }
        }
        return names
    }

    /// Real search roots, without those in `~/Library` (iCloud, CloudStorage…), the ubiquitous ones nor repeats.
    private func roots(home: String) -> [String] {
        let homes = Set([home, CleanupTargets.realPath(home) ?? home].map(RiskPolicy.canonical))
        var result: [String] = []
        for candidate in searchRoots ?? ProjectArtifactRules.defaultSearchRoots(home: home) {
            guard let real = CleanupTargets.realPath(candidate), ProjectArtifactRules.isRealDirectory(real),
                  DiskScope.allowsWalk(real) else {
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

    /// BFS up to `maxDepth` without following links; a project is the outermost folder with a marker.
    /// `complete == false` if the time limit ran out.
    private func projects(in root: String, skipped: Set<String>, deadline: ContinuousClock.Instant)
        -> (found: [String], complete: Bool) {
        let clock = ContinuousClock()
        var found: [String] = []
        var level = [root]
        for depth in 0...maxDepth {
            var next: [String] = []
            for folder in level {
                guard clock.now < deadline, !Task.isCancelled else { return (found, false) }
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
        return (found, true)
    }

    /// Real folders with the entry's name (and its ecosystem) or a `CACHEDIR.TAG` inside the project, without
    /// entering `.git`, what was already found nor the other entries' folders.
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
