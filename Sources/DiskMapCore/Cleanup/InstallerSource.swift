import Foundation

/// Entry with `discovery {"type":"installers"}`: loose installers (`.dmg`, `.pkg`…) and `.zip` files with an installer
/// inside, in Downloads, Desktop and Documents (up to two levels). One item per file. It never follows
/// links nor enters what is in iCloud, and reading the `.zip` files (`zipinfo -1`) has a total time limit.
public struct InstallerSource: CleanupTargetSource {
    public static let extensions: Set<String> = ["dmg", "pkg", "mpkg", "iso", "xip"]
    public static let rootNames = ["Downloads", "Desktop", "Documents"]
    public static let zipListTimeout: TimeInterval = 5
    /// Total time limit to read `.zip` files in a pass, and maximum number of `.zip` files read.
    public static let zipTotalBudget: Duration = .seconds(20)
    public static let maxZipListings = 50

    private let totalBudget: Duration
    private let maxZips: Int
    private let isUbiquitous: @Sendable (String) -> Bool

    public init() {
        self.init(totalBudget: Self.zipTotalBudget, maxZips: Self.maxZipListings,
                  isUbiquitous: ProjectArtifactRules.isUbiquitous)
    }

    init(totalBudget: Duration, maxZips: Int, isUbiquitous: @escaping @Sendable (String) -> Bool) {
        self.totalBudget = totalBudget; self.maxZips = maxZips; self.isUbiquitous = isUbiquitous
    }

    // MARK: - Detection

    public func discover(_ entry: CatalogEntry, context: DiscoveryContext) async -> [DiscoveredTarget] {
        var found: [(path: String, modified: Date)] = []
        var zips: [(path: String, modified: Date)] = []
        for root in Self.rootNames.map({ context.home + "/" + $0 }) where ProjectArtifactRules.isRealDirectory(root) {
            for file in regularFiles(in: root) {
                let ext = (file.path as NSString).pathExtension.lowercased()
                if Self.extensions.contains(ext) {
                    found.append(file)
                } else if ext == "zip" {
                    zips.append(file)
                }
            }
        }
        if !zips.isEmpty, let zipinfo = await context.runner.resolve("zipinfo") {
            // Most recent first: if there are more than `maxZips`, the ones most likely to matter get in.
            zips.sort { $0.modified != $1.modified ? $0.modified > $1.modified : $0.path < $1.path }
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: totalBudget)
            for zip in zips.prefix(maxZips) {
                let remaining = clock.now.duration(to: deadline)
                guard remaining > .zero else { break }
                if await Self.zipHasInstaller(zip.path, zipinfo: zipinfo, runner: context.runner,
                                              timeout: min(Self.zipListTimeout, Self.seconds(remaining))) {
                    found.append(zip)
                }
            }
        }
        found.sort { $0.path < $1.path }
        return found.map { file in
            DiscoveredTarget(idSuffix: Format.tildePath(file.path, home: context.home), paths: [file.path],
                             details: [String(localized: "Downloaded \(Format.relativeDate(file.modified))", bundle: .airyCore)],
                             lastModified: file.modified)
        }
    }

    /// Regular files at depth ≤ 2 of `root` (those directly inside `root` are level 1), without links,
    /// without hidden folders or bundles (`.app`, libraries…) and without what is in iCloud.
    private func regularFiles(in root: String) -> [(path: String, modified: Date)] {
        var files: [(path: String, modified: Date)] = []
        func scan(_ folder: String, depth: Int) {
            guard DiskScope.allowsWalk(folder), let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return }
            for name in names.sorted() {
                let path = folder + "/" + name
                var info = stat()
                guard lstat(path, &info) == 0 else { continue }
                switch info.st_mode & S_IFMT {
                case S_IFREG:
                    guard !isUbiquitous(path) else { continue }
                    let seconds = TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9
                    files.append((path, Date(timeIntervalSince1970: seconds)))
                case S_IFDIR:
                    guard depth < 2, !name.hasPrefix("."), !Self.isPackage(path), !isUbiquitous(path) else { continue }
                    scan(path, depth: depth + 1)
                default:
                    continue
                }
            }
        }
        scan(root, depth: 1)
        return files
    }

    private static func isPackage(_ path: String) -> Bool {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isPackageKey]))?.isPackage == true
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }

    /// `zipinfo -1` lists the `.zip`'s paths. It is an installer if there is an app (`.app`) as a level 1 or 2
    /// component, or a `.pkg`, `.mpkg` or `.dmg` file at level ≤ 2. A failure or an exhausted time limit ⇒ it is not.
    static func zipHasInstaller(_ path: String, zipinfo: String, runner: any CommandRunning,
                                timeout: TimeInterval) async -> Bool {
        guard let output = try? await runner.run(zipinfo, ["-1", path], timeout: timeout), output.status == 0
        else { return false }
        for line in output.stdout.split(whereSeparator: \.isNewline) {
            let isFolder = line.hasSuffix("/")
            let components = line.split(separator: "/").map { $0.lowercased() }
            if components.prefix(2).contains(where: { $0.hasSuffix(".app") }) { return true }
            if !isFolder, components.count <= 2, let last = components.last,
               [".pkg", ".mpkg", ".dmg"].contains(where: last.hasSuffix) { return true }
        }
        return false
    }

    // MARK: - Before acting

    public func revalidate(_ entry: CatalogEntry, item: CleanupItem, context: DiscoveryContext) async -> String? {
        guard !item.paths.isEmpty else { return String(localized: "There is no installer to send to the Trash.", bundle: .airyCore) }
        let roots = Self.rootNames.map { RiskPolicy.canonical(context.home + "/" + $0) }
        for path in item.paths {
            let name = (path as NSString).lastPathComponent
            var info = stat()
            guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
                return String(localized: "It is no longer a regular file: \(name).", bundle: .airyCore)
            }
            // It must still be in Downloads, Desktop or Documents, at most in a subfolder.
            let canonical = RiskPolicy.canonical(path)
            guard roots.contains(where: { root in
                RiskPolicy.isInside(canonical, root: root)
                    && canonical.dropFirst(root.count).split(separator: "/").count <= 2
            }) else { return String(localized: "It is not in Downloads, Desktop or Documents: \(name).", bundle: .airyCore) }
            let ext = (path as NSString).pathExtension.lowercased()
            if Self.extensions.contains(ext) { continue }
            guard ext == "zip", let zipinfo = await context.runner.resolve("zipinfo"),
                  await Self.zipHasInstaller(path, zipinfo: zipinfo, runner: context.runner,
                                             timeout: Self.zipListTimeout) else {
                return String(localized: "It is no longer an installer: \(name).", bundle: .airyCore)
            }
        }
        return nil
    }
}
