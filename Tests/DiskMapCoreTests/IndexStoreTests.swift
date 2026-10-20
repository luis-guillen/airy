import Foundation
import Testing
@testable import DiskMapCore

@Suite struct IndexStoreTests {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("airy-store-\(UUID().uuidString)/nested")
    }

    private func sampleTree() -> FileNode {
        var kb = Array(repeating: Int64(0), count: ContentKind.allCases.count)
        kb[1] = 700; kb[3] = 300
        let photo = FileNode(name: "a.jpg", isDirectory: false, allocatedSize: 700,
                             lastModified: Date(timeIntervalSinceReferenceDate: 1234), kind: .images)
        let code = FileNode(name: "Música ñ.swift", isDirectory: false, allocatedSize: 300, kind: .code)
        let others = FileNode(name: "Otros (5 elementos)", isDirectory: false, allocatedSize: 50, aggregatedCount: 5)
        let sub = FileNode(name: "sub dir", isDirectory: true, allocatedSize: 1050,
                           kindBytes: kb, children: [photo, code, others], descendantCount: 3)
        let root = FileNode(name: "/Users/x", isDirectory: true, allocatedSize: 1050,
                            kindBytes: kb, children: [sub], descendantCount: 4)
        return root
    }

    private func collect(_ root: FileNode) -> [String] {
        var out: [String] = []
        var stack = [root]
        while let n = stack.popLast() {
            out.append("\(n.path)|\(n.isDirectory)|\(n.allocatedSize)|\(n.kind)|\(n.kindBytes)|\(n.lastModified?.timeIntervalSinceReferenceDate ?? -1)|\(n.descendantCount)|\(n.aggregatedCount)")
            stack.append(contentsOf: n.children.reversed())
        }
        return out
    }

    @Test func roundTripsTree() throws {
        let store = IndexStore(directory: tempDir())
        let root = sampleTree()
        try store.saveScan(ScanResult(root: root, inaccessible: ["/x/y"], duration: 3.5))
        let loaded = try #require(try store.loadScan())
        #expect(collect(loaded.root) == collect(root))
        #expect(loaded.inaccessible == ["/x/y"])
        #expect(loaded.duration == 3.5)
        #expect(loaded.root.children[0].parent === loaded.root)
        #expect(try store.lastScanDate() != nil)
    }

    @Test func syntheticRootPathRoundTrips() throws {
        let store = IndexStore(directory: tempDir())
        let a = FileNode(name: "/A", isDirectory: true, allocatedSize: 1)
        let b = FileNode(name: "/B", isDirectory: true, allocatedSize: 2)
        let root = FileNode(name: "", isDirectory: true, allocatedSize: 3, children: [a, b])
        try store.saveScan(ScanResult(root: root, inaccessible: [], duration: 0))
        let loaded = try #require(try store.loadScan())
        #expect(loaded.root.children.map(\.path) == root.children.map(\.path))
    }

    @Test func missingIndexReturnsNil() throws {
        let store = IndexStore(directory: tempDir())
        #expect(try store.loadScan() == nil)
        #expect(try store.lastScanDate() == nil)
        #expect(try store.history().isEmpty)
    }

    @Test func corruptIndexReturnsNilAndIsRemoved() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("scan.plist")
        try Data("basura".utf8).write(to: file)
        let store = IndexStore(directory: dir)
        #expect(try store.loadScan() == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func totalFreedIgnoresTrashPending() throws {
        let store = IndexStore(directory: tempDir())
        let gb: Int64 = 1_000_000_000
        try store.append(CleanupRecord(date: .now, title: "a", bytes: gb, wentToTrash: true))
        try store.append(CleanupRecord(date: .now, title: "b", bytes: 2 * gb, wentToTrash: false))
        #expect(try store.totalFreed() == 2 * gb)
        #expect(try store.history().count == 2)
    }

    @Test func saveAndLoadLargeTree() throws {
        let store = IndexStore(directory: tempDir())
        var dirs: [FileNode] = []
        for d in 0..<200 {
            let files = (0..<1000).map {
                FileNode(name: "file-\(d)-\($0).dat", isDirectory: false, allocatedSize: 4096,
                         lastModified: .now, kind: .other)
            }
            dirs.append(FileNode(name: "dir\(d)", isDirectory: true, allocatedSize: 4096 * 1000,
                                 children: files, descendantCount: 1000))
        }
        let root = FileNode(name: "/", isDirectory: true, children: dirs, descendantCount: 200_000)
        let clock = ContinuousClock()
        let result = ScanResult(root: root, inaccessible: [], duration: 1)
        let t0 = clock.now
        try store.saveScan(result)
        let t1 = clock.now
        let loaded = try #require(try store.loadScan())
        let t2 = clock.now
        print("IndexStore 200k nodes: save \(t1 - t0), load \(t2 - t1)")
        // Desglose por fases.
        let c0 = clock.now
        let flat = IndexStore.flatten(result)
        let c1 = clock.now
        let data = IndexStore.serialize(flat)
        let c2 = clock.now
        let parsed = try #require(IndexStore.parse(data))
        let c3 = clock.now
        _ = try #require(IndexStore.rebuild(parsed))
        let c4 = clock.now
        print("IndexStore phases: flatten \(c1 - c0), serialize \(c2 - c1), parse \(c3 - c2), rebuild \(c4 - c3), bytes \(data.count)")
        #expect(loaded.root.children.count == 200)
        #expect(loaded.root.children[199].children.count == 1000)
    }
}
