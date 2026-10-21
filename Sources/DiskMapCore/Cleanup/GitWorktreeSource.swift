import Foundation

/// One worktree from `git worktree list --porcelain`.
public struct GitWorktreeRecord: Sendable, Equatable {
    public var path: String
    public var head: String?
    /// Short branch name (`refs/heads/` dropped), `nil` if detached.
    public var branch: String?
    public var isBare = false
    public var isLocked = false
    public var isPrunable = false
    /// `true` for the first record: the main worktree.
    public var isMain = false
}

/// Entry with `discovery {"type":"gitWorktrees"}`: extra git worktrees of the repositories the project search found
/// (the same memoized list as the project artifacts). Read-only git with a time limit: `worktree list --porcelain`,
/// the default branch, `merge-base --is-ancestor` and `status --porcelain`. A worktree qualifies when its branch is
/// fully merged into the default branch (or git marks it prunable), it has no uncommitted or untracked changes and
/// git has not used it for a day. Never the main worktree, a bare or a locked one. One item per worktree folder,
/// always "Your call" and never checked from the start; its build folders stay with the dev-artifact sources.
public struct GitWorktreeSource: CleanupTargetSource {
    public static let gitTimeout: TimeInterval = 10
    public static let totalBudget: Duration = .seconds(30)
    /// A worktree git touched in this window may be in use (e.g. just created by an agent).
    public static let quietPeriod: TimeInterval = 86_400
    static let buildFolderNames = [".build", "DerivedData", "node_modules", "target", ".next", "build", "dist"]

    private let searchRoots: [String]?

    public init() { searchRoots = nil }

    init(searchRoots: [String]?) { self.searchRoots = searchRoots }

    // MARK: - Porcelain

    static func parse(_ porcelain: String) -> [GitWorktreeRecord] {
        var records: [GitWorktreeRecord] = []
        var current: GitWorktreeRecord?
        func flush() {
            if var record = current {
                record.isMain = records.isEmpty
                records.append(record)
            }
            current = nil
        }
        for raw in porcelain.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("worktree ") {
                flush()
                current = GitWorktreeRecord(path: String(line.dropFirst("worktree ".count)))
                continue
            }
            guard current != nil else { continue }
            if line.hasPrefix("HEAD ") { current?.head = String(line.dropFirst(5)) }
            else if line.hasPrefix("branch ") {
                var name = String(line.dropFirst("branch ".count))
                if name.hasPrefix("refs/heads/") { name = String(name.dropFirst("refs/heads/".count)) }
                current?.branch = name
            }
            else if line == "bare" { current?.isBare = true }
            else if line == "locked" || line.hasPrefix("locked ") { current?.isLocked = true }
            else if line == "prunable" || line.hasPrefix("prunable ") { current?.isPrunable = true }
        }
        flush()
        return records
    }

    // MARK: - Detection

    struct Qualified: Sendable, Equatable {
        var path: String
        var repository: String
        var branch: String?
        var defaultBranch: String
        var lastUsed: Date?
    }

    public func discover(_ entry: CatalogEntry, context: DiscoveryContext) async -> [DiscoveredTarget] {
        guard let git = await context.runner.resolve("git") else { return [] }
        let deadline = ContinuousClock().now.advanced(by: Self.totalBudget)
        let list = await ProjectArtifactSource(searchRoots: searchRoots).projectList(context: context)
        var result: [DiscoveredTarget] = []
        for project in list.projects where ProjectArtifactRules.isRealDirectory(project + "/.git") {
            if Task.isCancelled { return [] }
            guard ContinuousClock().now < deadline else { break }
            for worktree in await qualifying(in: project, git: git, runner: context.runner, now: context.now,
                                             deadline: deadline) {
                result.append(target(worktree, home: context.home))
            }
        }
        return result.sorted { ($0.paths.first ?? "") < ($1.paths.first ?? "") }
    }

    private func target(_ worktree: Qualified, home: String) -> DiscoveredTarget {
        let reason = Self.reason(worktree)
        var details = [reason]
        let builds = Self.buildFolderNames.filter { ProjectArtifactRules.isRealDirectory(worktree.path + "/" + $0) }
        if !builds.isEmpty {
            details.append(String(localized: "Includes build folders: \(builds.joined(separator: ", "))", bundle: .airyCore))
        }
        if let used = worktree.lastUsed {
            details.append(String(localized: "Git last used it \(Format.relativeDate(used))", bundle: .airyCore))
        }
        var target = DiscoveredTarget(idSuffix: Format.tildePath(worktree.path, home: home), paths: [worktree.path],
                                      details: details, lastModified: worktree.lastUsed, floor: .yourCall,
                                      floorReason: reason)
        target.preselectable = false
        target.label = String(localized: "Worktree \((worktree.path as NSString).lastPathComponent)", bundle: .airyCore)
        return target
    }

    static func reason(_ worktree: Qualified) -> String {
        if let branch = worktree.branch {
            return String(localized: "Branch \(branch) is merged into \(worktree.defaultBranch) and has no uncommitted changes", bundle: .airyCore)
        }
        return String(localized: "Git marks this worktree as prunable and it has no uncommitted changes", bundle: .airyCore)
    }

    /// The worktrees of `repository` that qualify (see the type's documentation).
    func qualifying(in repository: String, git: String, runner: any CommandRunning, now: Date,
                    deadline: ContinuousClock.Instant) async -> [Qualified] {
        guard let listing = await Self.git(git, ["worktree", "list", "--porcelain"], in: repository, runner: runner,
                                           deadline: deadline), listing.status == 0 else { return [] }
        let records = Self.parse(listing.stdout)
        guard let main = records.first, main.isMain,
              RiskPolicy.canonical(CleanupTargets.realPath(main.path) ?? main.path)
                == RiskPolicy.canonical(CleanupTargets.realPath(repository) ?? repository) else { return [] }
        let candidates = records.filter { !$0.isMain && !$0.isBare && !$0.isLocked }
        guard !candidates.isEmpty,
              let defaultBranch = await Self.defaultBranch(git: git, repository: repository, runner: runner,
                                                           deadline: deadline) else { return [] }
        let mainReal = RiskPolicy.canonical(CleanupTargets.realPath(repository) ?? repository)
        var result: [Qualified] = []
        for record in candidates {
            // Only real folders that are not the main worktree (nor one of its parents).
            guard record.path.hasPrefix("/"), ProjectArtifactRules.isRealDirectory(record.path),
                  let real = CleanupTargets.realPath(record.path),
                  RiskPolicy.canonical(real) == RiskPolicy.canonical(record.path),
                  !RiskPolicy.isInside(mainReal, root: RiskPolicy.canonical(real)) else { continue }
            if !record.isPrunable {
                guard let branch = record.branch, branch != defaultBranch,
                      let merged = await Self.git(git, ["merge-base", "--is-ancestor", "refs/heads/" + branch,
                                                        "refs/heads/" + defaultBranch], in: repository,
                                                  runner: runner, deadline: deadline),
                      merged.status == 0 else { continue }
            }
            let used = Self.lastUsed(record.path)
            if let used, now.timeIntervalSince(used) < Self.quietPeriod { continue }
            guard await Self.isClean(record.path, git: git, runner: runner, deadline: deadline) else { continue }
            result.append(Qualified(path: record.path, repository: repository,
                                    branch: record.isPrunable ? nil : record.branch,
                                    defaultBranch: defaultBranch, lastUsed: used))
        }
        return result
    }

    /// `origin/HEAD`'s branch if it exists locally, else `main` or `master`; `nil` if none.
    static func defaultBranch(git: String, repository: String, runner: any CommandRunning,
                              deadline: ContinuousClock.Instant) async -> String? {
        var candidates: [String] = []
        if let head = await Self.git(git, ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"],
                                     in: repository, runner: runner, deadline: deadline), head.status == 0 {
            let name = head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.hasPrefix("origin/") { candidates.append(String(name.dropFirst("origin/".count))) }
        }
        candidates += ["main", "master"]
        for name in candidates where !name.isEmpty {
            if let check = await Self.git(git, ["rev-parse", "--verify", "--quiet", "refs/heads/" + name],
                                          in: repository, runner: runner, deadline: deadline), check.status == 0 {
                return name
            }
        }
        return nil
    }

    /// `git status --porcelain` (untracked files included, ignored ones not) is empty.
    static func isClean(_ worktree: String, git: String, runner: any CommandRunning,
                        deadline: ContinuousClock.Instant) async -> Bool {
        guard let status = await Self.git(git, ["--no-optional-locks", "status", "--porcelain"], in: worktree,
                                          runner: runner, deadline: deadline) else { return false }
        return status.status == 0 && status.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Newest `mtime` of the worktree's admin files (`HEAD`, `index`, `logs/HEAD`) in the repository's
    /// `.git/worktrees/<name>`, read through the worktree's `.git` file; `nil` if it cannot be read.
    static func lastUsed(_ worktree: String) -> Date? {
        guard let admin = adminDirectory(of: worktree) else { return nil }
        var latest: Date?
        for name in ["HEAD", "index", "logs/HEAD"] {
            var info = stat()
            guard lstat(admin + "/" + name, &info) == 0 else { continue }
            let date = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
            if latest.map({ date > $0 }) ?? true { latest = date }
        }
        return latest
    }

    /// The `gitdir:` of a worktree's `.git` file (a regular file, never a folder or a link).
    static func adminDirectory(of worktree: String) -> String? {
        let file = worktree + "/.git"
        var info = stat()
        guard lstat(file, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size < 4096,
              let text = try? String(contentsOfFile: file, encoding: .utf8) else { return nil }
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("gitdir: ") else { return nil }
        var path = String(line.dropFirst("gitdir: ".count))
        if !path.hasPrefix("/") { path = worktree + "/" + path }
        return ProjectArtifactRules.isRealDirectory(path) ? path : nil
    }

    /// Read-only git with the shared time limit; any other command is refused by `CommandPolicy` first.
    static func git(_ git: String, _ arguments: [String], in folder: String, runner: any CommandRunning,
                    deadline: ContinuousClock.Instant) async -> CommandOutput? {
        guard CommandPolicy.refusal(executable: git, arguments: arguments) == nil else { return nil }
        let left = ContinuousClock().now.duration(to: deadline)
        let seconds = Double(left.components.seconds) + Double(left.components.attoseconds) / 1e18
        guard seconds > 0 else { return nil }
        return try? await runner.run(git, ["-c", "core.fsmonitor=false", "-C", folder] + arguments,
                                     timeout: min(gitTimeout, seconds))
    }

    // MARK: - Before acting

    public func revalidate(_ entry: CatalogEntry, item: CleanupItem, context: DiscoveryContext) async -> String? {
        guard item.paths.count == 1, let path = item.paths.first else {
            return String(localized: "“\(entry.title)” must be a single folder.", bundle: .airyCore)
        }
        let name = (path as NSString).lastPathComponent
        guard let git = await context.runner.resolve("git") else {
            return String(localized: "Could not check with Git whether it keeps changes; Airy does not touch it.", bundle: .airyCore)
        }
        guard let admin = Self.adminDirectory(of: path) else {
            return String(localized: "It is no longer a git worktree: \(name).", bundle: .airyCore)
        }
        // `<repository>/.git/worktrees/<id>` ⇒ `<repository>`.
        let repository = ((admin as NSString).deletingLastPathComponent as NSString)
            .deletingLastPathComponent.replacingOccurrences(of: "/.git", with: "", options: [.anchored, .backwards])
        let list = await ProjectArtifactSource(searchRoots: searchRoots).projectList(context: context)
        let repoCanonical = RiskPolicy.canonical(CleanupTargets.realPath(repository) ?? repository)
        guard list.projects.contains(where: { RiskPolicy.canonical(CleanupTargets.realPath($0) ?? $0) == repoCanonical })
        else {
            return String(localized: "Its repository is no longer in any folder where Airy looks for projects.", bundle: .airyCore)
        }
        let deadline = ContinuousClock().now.advanced(by: Self.totalBudget)
        let qualified = await qualifying(in: repository, git: git, runner: context.runner, now: context.now,
                                         deadline: deadline)
        guard qualified.contains(where: { RiskPolicy.canonical($0.path) == RiskPolicy.canonical(path) }) else {
            return String(localized: "The worktree is no longer merged and clean, or it is locked or in use: \(name).", bundle: .airyCore)
        }
        return nil
    }
}
