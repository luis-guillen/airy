import Foundation

/// Searches the user's projects for whether something (e.g. a Hugging Face model) is referenced.
/// It only reads regular files < 1 MB, does not follow symbolic links and respects a time limit.
public struct ReferenceChecker: Sendable {
    public static let excludedDirectoryNames: Set<String> = [
        "node_modules", ".git", ".venv", "venv", ".build", "target", "Library",
    ]
    public static let maxFileSize: Int64 = 1_000_000

    public let roots: [String]

    public init(roots: [String]) {
        self.roots = roots
    }

    /// The default roots that exist: `~/Desktop`, `~/Documents`, `~/Projects`, `~/orca`.
    public init(home: String = NSHomeDirectory()) {
        self.init(roots: Self.defaultRoots(home: home))
    }

    public static func defaultRoots(home: String) -> [String] {
        ["Desktop", "Documents", "Projects", "orca"]
            .map { (home as NSString).appendingPathComponent($0) }
            .filter { path in
                var info = stat()
                return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
            }
    }

    /// Paths of files that contain `needle`. When `timeout` runs out it returns what was found so far.
    public func references(to needle: String, timeout: TimeInterval) async -> [String] {
        await references(toAny: [needle], timeout: timeout)[needle] ?? []
    }

    /// A single pass for several strings. The key is the string; the value, the files that contain it.
    public func references(toAny needles: [String], timeout: TimeInterval) async -> [String: [String]] {
        await referencesChecked(toAny: needles, timeout: timeout).found
    }

    /// Like `references(toAny:)`, and `complete == false` if time ran out or it was cancelled before walking everything.
    public func referencesChecked(
        toAny needles: [String], timeout: TimeInterval
    ) async -> (found: [String: [String]], complete: Bool) {
        let patterns = Array(Set(needles.filter { !$0.isEmpty }))
        guard !patterns.isEmpty else { return ([:], true) }
        let encoded = patterns.map { Data($0.utf8) }
        let deadline = Date().addingTimeInterval(timeout)
        var found: [String: [String]] = [:]
        var complete = true
        var stack = roots.reversed().map { $0 }
        while let path = stack.popLast() {
            if Date() >= deadline || Task.isCancelled { complete = false; break }
            // Outside the detection's scope (DEBUG, `AIRY_SCAN_ROOTS`) nothing is read.
            guard DiskScope.allowsWalk(path) else { continue }
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { continue }
                for name in names.sorted().reversed() where !Self.excludedDirectoryNames.contains(name) {
                    stack.append(path + "/" + name)
                }
            case S_IFREG:
                guard Int64(info.st_size) < Self.maxFileSize,
                      let data = FileManager.default.contents(atPath: path) else { continue }
                for (index, pattern) in encoded.enumerated() where data.range(of: pattern) != nil {
                    found[patterns[index], default: []].append(path)
                }
            default:
                continue // symbolic links and special files: never followed nor read
            }
        }
        return (found, complete)
    }
}
