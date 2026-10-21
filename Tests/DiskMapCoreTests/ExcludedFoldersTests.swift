import Foundation
import Testing
@testable import DiskMapCore

/// Settings › Scanning › Excluded folders: the scanner never opens them.
@Suite struct ExcludedFoldersTests {
    private static let mb = 1_048_576

    /// A temporary folder (real path, `/private/var/…`), removed at the end with its permissions restored.
    private final class TempTree {
        let url: URL
        var path: String { url.path }

        init() throws {
            url = URL(fileURLWithPath: TestTemp.directory("AiryExcludedTests")).resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        deinit {
            if let enumerator = FileManager.default.enumerator(atPath: url.path) {
                for case let relative as String in enumerator { chmod(url.appendingPathComponent(relative).path, 0o755) }
            }
            chmod(url.path, 0o755)
            try? FileManager.default.removeItem(at: url)
        }

        @discardableResult
        func directory(_ relative: String) throws -> URL {
            let dir = url.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }

        func file(_ relative: String, bytes: Int) throws {
            try Data(repeating: 0xAB, count: bytes).write(to: url.appendingPathComponent(relative))
        }
    }

    private func scan(_ roots: [URL], excluding: [String]) async throws -> ScanResult {
        try await DiskScanner(options: ScanOptions(roots: roots, pruneThreshold: 0, userExcluded: excluding)).scan { _ in }
    }

    private func child(_ node: FileNode, _ name: String) -> FileNode? { node.children.first { $0.name == name } }

    @Test func excludedFolderIsShownEmptyAndItsContentIsNotCounted() async throws {
        let tree = try TempTree()
        try tree.directory("keep")
        try tree.file("keep/a.bin", bytes: 2 * Self.mb)
        try tree.directory("skip/deep")
        try tree.file("skip/deep/b.bin", bytes: 3 * Self.mb)
        let result = try await scan([tree.url], excluding: [tree.url.appendingPathComponent("skip").path])
        let skip = try #require(child(result.root, "skip"))
        #expect(skip.isDirectory && skip.children.isEmpty && skip.descendantCount == 0)
        #expect(skip.allocatedSize < Int64(Self.mb))
        #expect(child(result.root, "keep")?.allocatedSize ?? 0 >= Int64(2 * Self.mb))
        // Not "unreadable": the scan isn't partial because of an exclusion.
        #expect(result.inaccessible.isEmpty)
    }

    @Test func excludedFolderIsNeverOpened() async throws {
        // A locked folder inside the excluded one would be reported if the scanner tried to read it, and so would
        // the excluded folder itself when it is locked.
        let tree = try TempTree()
        let locked = try tree.directory("private")
        try tree.directory("private/inner")
        try tree.file("private/inner/x.bin", bytes: 1024)
        #expect(chmod(locked.path, 0) == 0)
        let result = try await scan([tree.url], excluding: [locked.path])
        #expect(result.inaccessible.isEmpty)
        #expect(child(result.root, "private")?.children.isEmpty == true)
        // Without the exclusion the same folder is unreadable (the check above means something).
        let control = try await scan([tree.url], excluding: [])
        #expect(control.inaccessible.contains(locked.path))
    }

    @Test func matchesCaseInsensitivelyAndThroughTheTrailingSlashAndLinks() async throws {
        let tree = try TempTree()
        try tree.directory("Projects/app")
        try tree.file("Projects/app/big.bin", bytes: 2 * Self.mb)
        let upper = tree.path + "/PROJECTS/"
        let result = try await scan([tree.url], excluding: [upper])
        #expect(child(result.root, "Projects")?.children.isEmpty == true)
        // The root spelled through `/var` (a link to `/private/var`), the exclusion with the real path.
        let real = tree.path
        if real.hasPrefix("/private/var/") {
            let viaLink = URL(fileURLWithPath: String(real.dropFirst("/private".count)))
            let linked = try await scan([viaLink], excluding: [real + "/Projects"])
            #expect(child(linked.root, "Projects")?.children.isEmpty == true)
        }
    }

    @Test func rootInsideAnExcludedFolderIsNotScanned() async throws {
        let tree = try TempTree()
        let root = try tree.directory("outer/root")
        try tree.file("outer/root/a.bin", bytes: 2 * Self.mb)
        let result = try await scan([root], excluding: [tree.path + "/outer"])
        #expect(result.root.children.isEmpty && result.root.allocatedSize == 0)
        #expect(result.inaccessible.isEmpty)
    }

    @Test func slashAndRelativePathsAreIgnoredByTheScanner() async throws {
        let tree = try TempTree()
        try tree.directory("a")
        try tree.file("a/f.bin", bytes: 2 * Self.mb)
        let result = try await scan([tree.url], excluding: ["/", "a", ""])
        #expect(child(result.root, "a")?.children.isEmpty == false)
    }

    // MARK: Settings

    @Test func normaliseRules() {
        let h = "/Users/test"
        #expect(ExcludedFolders.normalise(" /Volumes/Work// ", home: h) == "/Volumes/Work")
        #expect(ExcludedFolders.normalise("~/Movies/", home: h) == "/Users/test/Movies")
        #expect(ExcludedFolders.normalise("~", home: h) == "/Users/test")
        #expect(ExcludedFolders.normalise("/", home: h) == nil)
        #expect(ExcludedFolders.normalise("relative/x", home: h) == nil)
        #expect(ExcludedFolders.normalise("/a/../b", home: h) == nil)
        #expect(ExcludedFolders.normalise("/a/./b", home: h) == nil)
        #expect(ExcludedFolders.normalise("/a\u{7}b", home: h) == nil)
    }

    @Test func excludeDeduplicatesAndRemoves() {
        var s = AirySettings.defaults
        let first = s.exclude("/Users/test/Movies/", home: "/Users/test")
        let again = s.exclude("/users/test/movies", home: "/Users/test")
        let invalid = s.exclude("nope", home: "/Users/test")
        #expect(first && !again && !invalid)
        #expect(s.excludedPaths == ["/Users/test/Movies"])
        s.unexclude("/Users/test/Movies")
        #expect(s.excludedPaths.isEmpty)
    }
}
