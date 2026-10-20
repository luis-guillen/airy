import Testing
import Foundation
@testable import DiskMapCore

@Suite struct ScannerTests {
    private static let mb: Int64 = 1_048_576

    /// Carpeta temporal única que se borra al terminar, restaurando permisos antes.
    private final class TempTree {
        let url: URL
        var path: String { url.path }

        init() throws {
            url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("DiskMapScannerTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        deinit {
            if let enumerator = FileManager.default.enumerator(atPath: url.path) {
                for case let relative as String in enumerator {
                    chmod(url.appendingPathComponent(relative).path, 0o755)
                }
            }
            try? FileManager.default.removeItem(at: url)
        }

        @discardableResult
        func makeDirectory(_ relative: String) throws -> URL {
            let dir = url.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }

        @discardableResult
        func makeFile(_ relative: String, bytes: Int) throws -> URL {
            let file = url.appendingPathComponent(relative)
            try Data(repeating: 0xAB, count: bytes).write(to: file)
            return file
        }
    }

    private func scan(_ tree: TempTree, excluding: [String] = [], prune: Int64 = 1_048_576) async throws -> ScanResult {
        let options = ScanOptions(roots: [tree.url], excludedPrefixes: excluding, pruneThreshold: prune)
        return try await DiskScanner(options: options).scan { _ in }
    }

    private func findChild(_ node: FileNode, _ name: String) -> FileNode? {
        node.children.first { $0.name == name }
    }

    @Test func sumsAllocatedSizes() async throws {
        let tree = try TempTree()
        try tree.makeFile("a.bin", bytes: 3 * 1_048_576)
        try tree.makeFile("b.bin", bytes: 3 * 1_048_576)
        let result = try await scan(tree)
        #expect(result.root.allocatedSize >= 6 * Self.mb)
        #expect(result.root.allocatedSize <= 6 * Self.mb + Self.mb / 10)
        #expect(result.root.kindBytes.count == ContentKind.allCases.count)
        #expect(result.root.kindBytes.reduce(0, +) == result.root.allocatedSize)
    }

    @Test func countsHardLinkOnce() async throws {
        let tree = try TempTree()
        let original = try tree.makeFile("big.bin", bytes: 5 * 1_048_576)
        try FileManager.default.linkItem(at: original, to: tree.url.appendingPathComponent("link.bin"))
        let result = try await scan(tree)
        #expect(result.root.allocatedSize >= 5 * Self.mb)
        #expect(result.root.allocatedSize < 5 * Self.mb + Self.mb / 10)
    }

    @Test func sparseFileUsesAllocatedSize() async throws {
        let tree = try TempTree()
        let path = tree.url.appendingPathComponent("sparse.img").path
        let fd = open(path, O_CREAT | O_WRONLY, 0o644)
        #expect(fd >= 0)
        #expect(ftruncate(fd, 1 << 30) == 0)
        close(fd)
        let result = try await scan(tree)
        #expect(result.root.allocatedSize < Self.mb)
    }

    @Test func skipsSymlinkLoops() async throws {
        let tree = try TempTree()
        try tree.makeDirectory("a")
        try FileManager.default.createSymbolicLink(
            atPath: tree.url.appendingPathComponent("a/loop").path, withDestinationPath: "..")
        let result = try await scan(tree, prune: 0)
        let a = try #require(findChild(result.root, "a"))
        let loop = try #require(findChild(a, "loop"))
        #expect(!loop.isDirectory)
        #expect(loop.children.isEmpty)
    }

    @Test func excludesSystemVolumesPrefix() async throws {
        let tree = try TempTree()
        try tree.makeDirectory("keep")
        try tree.makeFile("keep/f.bin", bytes: 2 * 1_048_576)
        let skipped = try tree.makeDirectory("skip")
        try tree.makeFile("skip/f.bin", bytes: 2 * 1_048_576)
        let result = try await scan(tree, excluding: [skipped.path])
        #expect(findChild(result.root, "keep") != nil)
        #expect(findChild(result.root, "skip") == nil)
        #expect(result.root.allocatedSize < 3 * Self.mb)
    }

    @Test func unreadableDirectoryIsReportedNotFatal() async throws {
        let tree = try TempTree()
        let locked = try tree.makeDirectory("locked")
        try tree.makeFile("locked/secret.bin", bytes: 1024)
        try tree.makeDirectory("open")
        try tree.makeFile("open/f.bin", bytes: 2 * 1_048_576)
        #expect(chmod(locked.path, 0) == 0)
        let result = try await scan(tree, prune: 0)
        #expect(result.inaccessible.contains(locked.path))
        #expect(findChild(result.root, "open") != nil)
    }

    @Test func prunesSmallChildrenIntoAggregate() async throws {
        let tree = try TempTree()
        for index in 0..<500 { try tree.makeFile("small-\(index).txt", bytes: 1024) }
        try tree.makeFile("big.bin", bytes: 2 * 1_048_576)
        let result = try await scan(tree)
        #expect(result.root.children.count == 2)
        let aggregate = try #require(result.root.children.first { $0.aggregatedCount > 0 })
        #expect(aggregate.aggregatedCount == 500)
        #expect(aggregate.kindBytes.reduce(0, +) == aggregate.allocatedSize)
        #expect(aggregate.kindBytes[ContentKind.allCases.firstIndex(of: .documents)!] == aggregate.allocatedSize)
        #expect(result.root.descendantCount == 501)
    }

    @Test func classifiesKinds() {
        #expect(FileKindClassifier.kind(forFileNamed: "peli.MOV") == .video)
        #expect(FileKindClassifier.kind(forDirectoryPath: "/x/Foo.app") == .apps)
        #expect(FileKindClassifier.kind(forFileNamed: "m.gguf") == .aiModels)
        #expect(FileKindClassifier.kind(forFileNamed: "sin-extension") == .other)
        #expect(FileKindClassifier.kind(forDirectoryPath: "/Users/ana/proyecto/node_modules") == .code)
        #expect(FileKindClassifier.kind(forDirectoryPath: "/Library") == .system)
        #expect(FileKindClassifier.kind(forDirectoryPath: "/Users/ana/Documents") == nil)
    }

    @Test func privatePathsAreKeptAndExcluded() async throws {
        let tree = try TempTree()
        // Ruta real, con `/private` delante, como la ve el escáner al recorrer `/`.
        let real = try #require(tree.path.withCString { realpath($0, nil) }.map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        })
        #expect(real.hasPrefix("/private/"))
        try tree.makeDirectory("vm")
        try tree.makeFile("vm/swapfile0", bytes: 2 * 1_048_576)
        try tree.makeDirectory("keep")
        try tree.makeFile("keep/f.bin", bytes: 2 * 1_048_576)
        let options = ScanOptions(roots: [URL(fileURLWithPath: real)], excludedPrefixes: [real + "/vm"])
        let result = try await DiskScanner(options: options).scan { _ in }
        #expect(result.root.path == real)
        #expect(findChild(result.root, "vm") == nil)
        #expect(findChild(result.root, "keep")?.path == real + "/keep")
    }

    @Test func multipleRootsKeepAbsolutePaths() async throws {
        let first = try TempTree()
        let second = try TempTree()
        try first.makeFile("a.bin", bytes: 2 * 1_048_576)
        try second.makeFile("b.bin", bytes: 2 * 1_048_576)
        let options = ScanOptions(roots: [first.url, second.url], excludedPrefixes: [])
        let result = try await DiskScanner(options: options).scan { _ in }
        #expect(result.root.children.count == 2)
        let paths = Set(result.root.children.flatMap(\.children).map(\.path))
        #expect(paths == [first.path + "/a.bin", second.path + "/b.bin"])
        #expect(result.root.allocatedSize >= 4 * Self.mb)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AIRY_REAL"] != nil))
    func realHome() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let result = try await DiskScanner(options: ScanOptions(roots: [home])).scan { _ in }
        print("realHome: \(Format.bytes(result.root.allocatedSize)) en \(String(format: "%.1f", result.duration)) s, \(result.root.descendantCount) elementos, \(result.inaccessible.count) inaccesibles")
    }
}
