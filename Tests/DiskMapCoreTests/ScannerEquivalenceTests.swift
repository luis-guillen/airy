import Foundation
import Testing
@testable import DiskMapCore

/// Everything a scan publishes about a tree, with siblings in a fixed order (equal-size siblings can arrive in
/// any order from the worker threads). Two scans of the same folder must give the same dump.
func canonicalDump(_ node: FileNode) -> [String] {
    var lines: [String] = []
    func visit(_ node: FileNode, depth: Int) {
        let mtime = node.lastModified.map { String($0.timeIntervalSinceReferenceDate) } ?? "nil"
        lines.append("\(String(repeating: " ", count: depth))\(node.name)|dir=\(node.isDirectory)|size=\(node.allocatedSize)"
            + "|kind=\(node.kind)|bytes=\(node.kindBytes)|desc=\(node.descendantCount)|agg=\(node.aggregatedCount)|mtime=\(mtime)")
        let ordered = node.children.sorted {
            $0.allocatedSize != $1.allocatedSize ? $0.allocatedSize > $1.allocatedSize : $0.name < $1.name
        }
        for child in ordered {
            #expect(child.parent === node)
            visit(child, depth: depth + 1)
        }
    }
    visit(node, depth: 0)
    return lines
}

@Suite struct ScannerEquivalenceTests {
    /// A folder with every kind of entry the reader has to describe the way `fstatat` does.
    private static func mixedTree() throws -> String {
        let root = CleanupTargets.realPath(TestTemp.directory("scan-equivalence"))!
        let fm = FileManager.default
        func file(_ relative: String, _ bytes: Int, byte: UInt8 = 0xAB) throws {
            let path = root + "/" + relative
            try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try Data(repeating: byte, count: bytes).write(to: URL(fileURLWithPath: path))
        }
        try file("big.bin", 3 << 20)
        try file("exactly-threshold.bin", 1 << 20)
        try file("below-threshold.bin", (1 << 20) - 4096)
        try file("empty", 0)
        try file("Photo.JPG", 5000)
        try file(".hidden.swift", 100)
        try file("..dots", 100)
        try file("a..b.MP4", 2 << 20)
        try file("trailing.", 10)
        try file("with space.tXt ", 10)
        try file("ñandú.Pdf", 2 << 20)
        try file("Very.LongExtensionName", 2 << 20)
        try file("model.safetensors", 2 << 20)
        try file("docker/com.docker.docker/Data/vms/0/disk.RAW", 2 << 20)
        for index in 0..<300 { try file("many/small-\(index).js", 10 + index) }
        try file("many/one-big.bin", 2 << 20)
        try file("single-small/only.txt", 10)
        try file("single-small/nested/deep.bin", 2 << 20)
        try file("node_modules/pkg/index.js", 2000)
        try file("Caches/blob", 4 << 20)
        try file("excluded-file.bin", 2 << 20)
        try file("excluded-dir/inside.bin", 2 << 20)
        try file("user-excluded/inside.bin", 2 << 20)
        try file("locked/secret.bin", 2048)
        try fm.createDirectory(atPath: root + "/empty-dir", withIntermediateDirectories: true)
        // Hard links (counted once; in one folder, so which one counts doesn't depend on the threads),
        // symlinks (never followed), a FIFO, a sparse file and a clone.
        try file("links/original.bin", 3 << 20)
        #expect(link(root + "/links/original.bin", root + "/links/second.bin") == 0)
        #expect(link(root + "/links/original.bin", root + "/links/third.bin") == 0)
        try fm.createSymbolicLink(atPath: root + "/link-to-big", withDestinationPath: "big.bin")
        try fm.createSymbolicLink(atPath: root + "/many/loop", withDestinationPath: "..")
        #expect(mkfifo(root + "/fifo", 0o644) == 0)
        let sparse = open(root + "/sparse.img", O_CREAT | O_WRONLY, 0o644)
        #expect(ftruncate(sparse, 1 << 30) == 0)
        close(sparse)
        #expect(clonefile(root + "/big.bin", root + "/clone.bin", 0) == 0)
        #expect(setxattr(root + "/Photo.JPG", "com.airy.test", [UInt8](repeating: 7, count: 8000), 8000, 0, 0) == 0)
        #expect(chmod(root + "/locked", 0) == 0)
        return root
    }

    private static func scan(_ root: String, prune: Int64, bulk: Bool, workers: Int) async throws -> ScanResult {
        var options = ScanOptions(roots: [URL(fileURLWithPath: root)],
                                  excludedPrefixes: [root + "/excluded-file.bin", root + "/excluded-dir"],
                                  pruneThreshold: prune, userExcluded: [root + "/User-Excluded"])
        options.usesBulkReader = bulk
        return try await DiskScanner(options: options, budget: ScanBudget(workers: workers, qos: .utility)).scan { _ in }
    }

    @Test(arguments: [Int64(0), 4096, 1 << 20])
    func bulkReaderMatchesReaddirAndFstatat(prune: Int64) async throws {
        let root = try Self.mixedTree()
        defer { chmod(root + "/locked", 0o755) }
        let reference = try await Self.scan(root, prune: prune, bulk: false, workers: 1)
        for workers in [1, 4] {
            let bulk = try await Self.scan(root, prune: prune, bulk: true, workers: workers)
            #expect(canonicalDump(bulk.root) == canonicalDump(reference.root))
            #expect(bulk.inaccessible == reference.inaccessible)
        }
        #expect(reference.inaccessible == [root + "/locked"])
    }

    @Test func foldedSmallFilesKeepTheOldShape() async throws {
        let root = try Self.mixedTree()
        defer { chmod(root + "/locked", 0o755) }
        let result = try await Self.scan(root, prune: 1 << 20, bulk: true, workers: 4)
        let many = try #require(result.root.children.first { $0.name == "many" })
        let other = try #require(many.children.first { $0.aggregatedCount > 0 })
        // 300 small files and the `loop` symlink.
        #expect(other.aggregatedCount == 301)
        #expect(other.name == "Other")
        #expect(other.kindBytes.reduce(0, +) == other.allocatedSize)
        #expect(many.descendantCount == 302)
        // A lone small file stays visible on its own.
        let single = try #require(result.root.children.first { $0.name == "single-small" })
        #expect(single.children.contains { $0.name == "only.txt" && $0.aggregatedCount == 0 })
        // Ids stay unique although four threads create nodes at once.
        var ids = Set<Int>()
        var stack = [result.root]
        while let node = stack.popLast() {
            #expect(ids.insert(node.id).inserted)
            stack.append(contentsOf: node.children)
        }
    }

    @Test func byteClassifierMatchesTheNSStringOne() {
        var names = ["a.txt", ".bashrc", "file.", "a.b.c", "noext", ".", "..", "a..b", ".a.b", "A.JPG", "x.tar.gz",
                     "é.Jpg", "a b.mp4", "..hidden", "a.", "a.tXt ", "x.ñ", "x.123", "x.PDF\u{200B}", "x.Safetensors",
                     "x.safetensorsX", "x.SAFETENSORS", "x.MoV", "disk.raw", "disk.RAW", "x.\u{0301}mp4", "x.m p4",
                     "x.mp4.", "x..", "...", ".x", "x.-", "x._a", "x.a_b", "x.JSON", "Package.resolved", "x.Lock"]
        var generator = SystemRandomNumberGenerator()
        let alphabet = Array("abcXYZ019._ -é")
        for _ in 0..<3000 {
            let length = Int.random(in: 1...10, using: &generator)
            names.append(String((0..<length).map { _ in alphabet.randomElement(using: &generator)! }))
        }
        for directory in ["/Users/a/Downloads", "/Users/a/Library/Containers/com.docker.docker/Data/vms/0"] {
            for name in names {
                let expected = FileKindClassifier.kind(forFileNamed: name, inDirectoryPath: directory)
                let bytes = Array(name.utf8)
                let fast = bytes.withUnsafeBufferPointer {
                    FileKindClassifier.kind(forFileNameBytes: $0, inDirectoryPath: directory)
                }
                #expect(fast == expected, "\(name) in \(directory)")
            }
        }
    }

    @Test func kindIndexMatchesAllCases() {
        for (position, kind) in ContentKind.allCases.enumerated() { #expect(kind.index == position) }
        #expect(ContentKind.count == ContentKind.allCases.count)
    }
}
