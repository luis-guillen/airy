import Testing
import Foundation
import Synchronization
@testable import DiskMapCore

@Suite struct ScannerTests {
    private static let mb: Int64 = 1_048_576

    /// A unique temporary folder deleted at the end, restoring permissions first.
    private final class TempTree {
        let url: URL
        var path: String { url.path }

        init() throws {
            url = URL(fileURLWithPath: TestTemp.directory("DiskMapScannerTests")).resolvingSymlinksInPath()
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
        // Real path, with `/private` in front, as the scanner sees it when walking `/`.
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

    @Test func workIsDoneOnBudgetThreadsWithItsQoS() async throws {
        let tree = try TempTree()
        for index in 0..<12 { try tree.makeDirectory("d\(index)/sub"); try tree.makeFile("d\(index)/sub/f.bin", bytes: 4096) }
        try tree.makeFile("top.bin", bytes: 4096)
        let seen = Mutex<[(String, QualityOfService)]>([])
        let options = ScanOptions(roots: [tree.url], excludedPrefixes: [])
        let scanner = DiskScanner(options: options, budget: ScanBudget(workers: 2, qos: .background))
        let result = try await scanner.scan { _ in
            seen.withLock { $0.append((Thread.current.name ?? "", Thread.current.qualityOfService)) }
        }
        let reports = seen.withLock { $0 }
        #expect(!reports.isEmpty)
        #expect(reports.allSatisfy { $0.0.hasPrefix("Airy scan ") && $0.1 == .background })
        #expect(result.root.descendantCount == 12 * 3 + 1)
    }

    @Test func resultDoesNotDependOnWorkerCount() async throws {
        let tree = try TempTree()
        for index in 0..<8 { try tree.makeDirectory("a\(index)/b/c"); try tree.makeFile("a\(index)/b/c/big.bin", bytes: 2 * Int(Self.mb)) }
        try tree.makeFile("a0/small.txt", bytes: 10)
        try tree.makeFile("a0/small2.txt", bytes: 10)
        let options = ScanOptions(roots: [tree.url], excludedPrefixes: [])
        let one = try await DiskScanner(options: options, budget: ScanBudget(workers: 1, qos: .utility)).scan { _ in }
        let four = try await DiskScanner(options: options, budget: ScanBudget(workers: 4, qos: .utility)).scan { _ in }
        #expect(one.root.allocatedSize == four.root.allocatedSize)
        #expect(one.root.descendantCount == four.root.descendantCount)
        #expect(one.root.children.map(\.allocatedSize) == four.root.children.map(\.allocatedSize))
    }

    /// Cancels with the threads running and folders half closed: it ends and throws `CancellationError`.
    @Test func cancellingMidScanStopsTheWalk() async throws {
        let tree = try TempTree()
        for index in 0..<300 { try tree.makeDirectory("d\(index)/e/f") }
        let options = ScanOptions(roots: [tree.url], excludedPrefixes: [])
        let scanner = DiskScanner(options: options, budget: ScanBudget(workers: 2, qos: .utility))
        let box = Mutex<Task<ScanResult, Error>?>(nil)
        let ready = DispatchSemaphore(value: 0)
        let reports = Mutex(0)
        let task = Task {
            try await scanner.scan { _ in
                // The first update arrives after reading the root: its 300 subfolders are still pending.
                guard reports.withLock({ $0 += 1; return $0 }) == 1 else { return }
                ready.wait()
                box.withLock { $0?.cancel() }
            }
        }
        box.withLock { $0 = task }
        ready.signal()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(reports.withLock { $0 } >= 1)
    }

    @Test func resultCarriesTheScanDate() async throws {
        let tree = try TempTree()
        let before = Date()
        let result = try await scan(tree)
        let scannedAt = try #require(result.scannedAt)
        #expect(scannedAt >= before && scannedAt <= Date())
    }

    @Test func cancellingStopsTheScan() async throws {
        let tree = try TempTree()
        for index in 0..<20 { try tree.makeDirectory("d\(index)/e"); try tree.makeFile("d\(index)/e/f.bin", bytes: 100) }
        let options = ScanOptions(roots: [tree.url], excludedPrefixes: [])
        let task = Task { try await DiskScanner(options: options, intensity: .background).scan { _ in } }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AIRY_REAL"] != nil))
    func realHome() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let result = try await DiskScanner(options: ScanOptions(roots: [home])).scan { _ in }
        print("realHome: \(Format.bytes(result.root.allocatedSize)) in \(String(format: "%.1f", result.duration)) s, \(result.root.descendantCount) items, \(result.inaccessible.count) inaccessible")
    }
}
