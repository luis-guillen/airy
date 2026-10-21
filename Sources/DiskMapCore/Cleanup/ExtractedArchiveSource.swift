import Foundation

/// Entry with `discovery {"type":"extractedArchives"}`: archives (`.zip`, `.dmg`, `.tar`, `.tar.gz`, `.tar.xz`,
/// `.7z`, `.rar`) larger than `minimumBytes` in Downloads, Desktop and Documents (up to one subfolder deep) with a
/// real folder of the same base name next to them: the archive was most likely already extracted. One item per
/// archive, always "Your call" and never checked from the start.
/// For `.zip` and plain `.tar`, the archive's top-level names are compared with the folder's (one listing with a
/// time limit): clearly different contents ⇒ it is not offered; a listing that fails or runs out of time keeps
/// the name match alone.
public struct ExtractedArchiveSource: CleanupTargetSource {
    public static let minimumBytes: Int64 = 200 * 1_000_000
    public static let rootNames = ["Downloads", "Desktop", "Documents"]
    /// Longest suffixes first: `x.tar.gz` ⇒ `x`.
    static let suffixes = [".tar.gz", ".tar.xz", ".tgz", ".txz", ".tar", ".zip", ".dmg", ".7z", ".rar"]
    public static let listTimeout: TimeInterval = 5
    public static let totalBudget: Duration = .seconds(20)
    /// Share of the archive's top-level names that must exist in the folder.
    static let matchShare = 0.8
    static let maxComparedNames = 200

    private let minimum: Int64
    private let isUbiquitous: @Sendable (String) -> Bool

    public init() { self.init(minimumBytes: Self.minimumBytes, isUbiquitous: ProjectArtifactRules.isUbiquitous) }

    init(minimumBytes: Int64, isUbiquitous: @escaping @Sendable (String) -> Bool) {
        minimum = minimumBytes; self.isUbiquitous = isUbiquitous
    }

    /// The archive's name without its archive suffix (`Mario Kart 8.zip` ⇒ `Mario Kart 8`), or `nil`.
    static func baseName(_ fileName: String) -> String? {
        let lower = fileName.lowercased()
        guard let suffix = suffixes.first(where: { lower.hasSuffix($0) }), fileName.count > suffix.count else { return nil }
        return String(fileName.dropLast(suffix.count))
    }

    enum ContentCheck: Equatable { case matches, differs, unknown }

    // MARK: - Detection

    public func discover(_ entry: CatalogEntry, context: DiscoveryContext) async -> [DiscoveredTarget] {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.totalBudget)
        var result: [DiscoveredTarget] = []
        for candidate in candidates(home: context.home) {
            if Task.isCancelled { return [] }
            let remaining = clock.now.duration(to: deadline)
            let check = remaining > .zero
                ? await Self.compareContents(candidate.path, folder: candidate.folder, runner: context.runner,
                                             timeout: min(Self.listTimeout, Self.seconds(remaining)))
                : .unknown
            if check == .differs { continue }
            let folderName = (candidate.folder as NSString).lastPathComponent
            var details = [String(localized: "Next to the folder “\(folderName)”", bundle: .airyCore)]
            details.append(check == .matches
                ? String(localized: "Its contents match that folder.", bundle: .airyCore)
                : String(localized: "Only the name matches: check the folder before removing it.", bundle: .airyCore))
            var target = DiscoveredTarget(
                idSuffix: Format.tildePath(candidate.path, home: context.home), paths: [candidate.path],
                bytes: candidate.bytes, details: details, lastModified: candidate.modified, floor: .yourCall,
                floorReason: String(localized: "There is a folder with the same name next to it: it was probably already extracted.", bundle: .airyCore))
            target.preselectable = false
            result.append(target)
        }
        return result
    }

    struct Candidate { var path: String; var folder: String; var bytes: Int64; var modified: Date }

    /// Archives at depth ≤ 2 of each root with a sibling real folder of the same base name (case-insensitive), without
    /// links, hidden folders, bundles or what is in iCloud.
    func candidates(home: String) -> [Candidate] {
        var found: [Candidate] = []
        func scan(_ folder: String, depth: Int) {
            guard DiskScope.allowsWalk(folder), let names = try? FileManager.default.contentsOfDirectory(atPath: folder)
            else { return }
            let sorted = names.sorted()
            var folders: [String: String] = [:]
            for name in sorted where ProjectArtifactRules.isRealDirectory(folder + "/" + name) {
                folders[name.lowercased()] = name
            }
            for name in sorted {
                let path = folder + "/" + name
                var info = stat()
                guard lstat(path, &info) == 0 else { continue }
                switch info.st_mode & S_IFMT {
                case S_IFREG:
                    let bytes = Int64(info.st_blocks) * 512
                    guard bytes > minimum, let base = Self.baseName(name), !base.isEmpty,
                          let sibling = folders[base.lowercased()], !isUbiquitous(path) else { continue }
                    let seconds = TimeInterval(info.st_mtimespec.tv_sec)
                    found.append(Candidate(path: path, folder: folder + "/" + sibling, bytes: bytes,
                                           modified: Date(timeIntervalSince1970: seconds)))
                case S_IFDIR:
                    guard depth < 2, !name.hasPrefix("."), !Self.isPackage(path), !isUbiquitous(path) else { continue }
                    scan(path, depth: depth + 1)
                default:
                    continue
                }
            }
        }
        for root in Self.rootNames.map({ home + "/" + $0 }) where ProjectArtifactRules.isRealDirectory(root) {
            scan(root, depth: 1)
        }
        return found.sorted { $0.path < $1.path }
    }

    private static func isPackage(_ path: String) -> Bool {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isPackageKey]))?.isPackage == true
    }

    static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }

    /// `.zip` (`zipinfo -1`) and plain `.tar` (`tar -tf`): the archive's top-level names (or, if everything hangs from
    /// a single folder, that folder's children) compared with the sibling folder's names. Other formats, a missing
    /// tool, a failure or the time limit ⇒ `.unknown`.
    static func compareContents(_ archive: String, folder: String, runner: any CommandRunning,
                                timeout: TimeInterval) async -> ContentCheck {
        let lower = archive.lowercased()
        let tool: (name: String, arguments: [String])
        if lower.hasSuffix(".zip") {
            tool = ("zipinfo", ["-1", archive])
        } else if lower.hasSuffix(".tar") {
            tool = ("tar", ["-tf", archive])
        } else {
            return .unknown
        }
        guard timeout > 0, let executable = await runner.resolve(tool.name),
              CommandPolicy.refusal(executable: executable, arguments: tool.arguments) == nil,
              let output = try? await runner.run(executable, tool.arguments, timeout: timeout), output.status == 0
        else { return .unknown }
        let entries = output.stdout.split(whereSeparator: \.isNewline).map(String.init)
        guard let children = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return .unknown }
        let names = comparedNames(entries, folderNames: children)
        guard !names.isEmpty else { return .unknown }
        return matches(archiveNames: names, folderNames: children) ? .matches : .differs
    }

    /// The names to look for in the folder: the archive's top-level names or, when everything hangs from a single
    /// top folder that the folder does not contain itself (it was extracted *as* the folder), that folder's children.
    static func comparedNames(_ entries: [String], folderNames: [String]) -> [String] {
        let names = topLevelNames(entries)
        guard names.count == 1, !folderNames.contains(where: { $0.lowercased() == names[0].lowercased() }) else {
            return names
        }
        let inner = namesUnderSingleTop(entries, top: names[0])
        return inner.isEmpty ? names : inner
    }

    /// Top-level names of a listing (without `./`, `__MACOSX` or `.DS_Store`).
    static func topLevelNames(_ entries: [String]) -> [String] {
        var names: [String] = []
        var seen = Set<String>()
        for entry in entries {
            var line = entry
            while line.hasPrefix("./") { line.removeFirst(2) }
            guard let first = line.split(separator: "/").first.map(String.init), !first.isEmpty,
                  first != "__MACOSX", first != ".DS_Store", first != "." else { continue }
            if seen.insert(first).inserted { names.append(first) }
        }
        return names
    }

    /// Children names of `top` in a listing.
    static func namesUnderSingleTop(_ entries: [String], top: String) -> [String] {
        var names: [String] = []
        var seen = Set<String>()
        for entry in entries {
            var line = entry
            while line.hasPrefix("./") { line.removeFirst(2) }
            let parts = line.split(separator: "/").map(String.init)
            guard parts.count >= 2, parts[0] == top, parts[1] != ".DS_Store" else { continue }
            if seen.insert(parts[1]).inserted { names.append(parts[1]) }
        }
        return names
    }

    /// The folder holds most of the archive's names (`matchShare` of the first `maxComparedNames`).
    static func matches(archiveNames: [String], folderNames: [String]) -> Bool {
        let folderSet = Set(folderNames.map { $0.lowercased() })
        let sample = archiveNames.prefix(maxComparedNames)
        let present = sample.filter { folderSet.contains($0.lowercased()) }.count
        return Double(present) >= matchShare * Double(sample.count)
    }

    // MARK: - Before acting

    public func revalidate(_ entry: CatalogEntry, item: CleanupItem, context: DiscoveryContext) async -> String? {
        guard item.paths.count == 1, let path = item.paths.first else {
            return String(localized: "“\(entry.title)” must be a single file.", bundle: .airyCore)
        }
        let name = (path as NSString).lastPathComponent
        let live = candidates(home: context.home)
        guard let candidate = live.first(where: { RiskPolicy.canonical($0.path) == RiskPolicy.canonical(path) }) else {
            return String(localized: "It is no longer a large archive next to a folder with its name: \(name).", bundle: .airyCore)
        }
        let check = await Self.compareContents(candidate.path, folder: candidate.folder, runner: context.runner,
                                               timeout: Self.listTimeout)
        if check == .differs {
            return String(localized: "Its contents no longer match the folder next to it: \(name).", bundle: .airyCore)
        }
        return nil
    }
}
