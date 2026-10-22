import Foundation
import Testing
@testable import DiskMapCore

@Suite struct IndexStoreTests {
    private func tempDir() -> URL {
        TestTemp.url("airy-store").appendingPathComponent("nested")
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

    @Test func deleteScanRemovesOnlyTheIndex() throws {
        let dir = tempDir()
        let store = IndexStore(directory: dir)
        #expect(try store.deleteScan() == false)
        try store.saveScan(ScanResult(root: sampleTree(), inaccessible: [], duration: 1, scannedAt: Date()))
        try store.append(CleanupRecord(date: Date(), title: "npm", bytes: 10, wentToTrash: false))
        #expect(try store.deleteScan() == true)
        #expect(try store.loadScan() == nil)
        // The cleanup history ("Total freed") stays.
        #expect(try store.totalFreed() == 10)
    }

    @Test func roundTripsTree() throws {
        let store = IndexStore(directory: tempDir())
        let root = sampleTree()
        let scannedAt = Date(timeIntervalSinceReferenceDate: 800_000_000.25)
        try store.saveScan(ScanResult(root: root, inaccessible: ["/x/y"], duration: 3.5, scannedAt: scannedAt))
        let loaded = try #require(try store.loadScan())
        #expect(loaded.scannedAt == scannedAt)
        #expect(collect(loaded.root) == collect(root))
        #expect(loaded.inaccessible == ["/x/y"])
        #expect(loaded.duration == 3.5)
        #expect(loaded.root.children[0].parent === loaded.root)
        #expect(try store.lastScanDate() == scannedAt)
    }

    /// A cleanup or the Trash save the displayed tree again: the scan date does not change
    /// even if the file's does.
    @Test func resavingTheShownTreeKeepsTheScanDate() throws {
        let dir = tempDir()
        let store = IndexStore(directory: dir)
        let scannedAt = Date().addingTimeInterval(-3 * 86_400)
        try store.saveScan(ScanResult(root: sampleTree(), inaccessible: [], duration: 1, scannedAt: scannedAt))
        let shown = try #require(try store.loadScan())
        shown.root.children[0].children[0].removeFromParent()
        try store.saveScan(shown)
        let attributes = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("scan.plist").path)
        let mtime = try #require(attributes[.modificationDate] as? Date)
        #expect(Date().timeIntervalSince(mtime) < 60)
        #expect(try store.lastScanDate() == scannedAt)
        #expect(try store.loadScan()?.scannedAt == scannedAt)
        #expect(ScanSchedule.plan(.automatic, hasIndex: true, indexDate: try store.lastScanDate(), now: Date())
                == .scan(.background))
    }

    /// A v2 index (without a date inside) is still read, with an unknown date: it is rescanned.
    @Test func legacyIndexLoadsWithUnknownDate() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var data = IndexStore.serializeV3(IndexStore.flatten(
            ScanResult(root: sampleTree(), inaccessible: ["/z"], duration: 2, scannedAt: Date())))
        data.replaceSubrange(4..<8, with: withUnsafeBytes(of: UInt32(2)) { Data($0) })
        data.removeSubrange(32..<40)
        try data.write(to: dir.appendingPathComponent("scan.plist"))
        let store = IndexStore(directory: dir)
        let loaded = try #require(try store.loadScan())
        #expect(collect(loaded.root) == collect(sampleTree()))
        #expect(loaded.inaccessible == ["/z"])
        #expect(loaded.scannedAt == nil)
        #expect(try store.lastScanDate() == nil)
    }

    private func version(of file: URL) throws -> UInt32 {
        try Data(contentsOf: file).withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }
    }

    /// A tree like a real scan: folders with several kinds, files with one, "Other" aggregates.
    private func bigTree() -> FileNode {
        var folders: [FileNode] = []
        for d in 0..<300 {
            var files: [FileNode] = []
            for f in 0..<20 {
                let kind = ContentKind.allCases[(d + f) % ContentKind.count]
                files.append(FileNode(name: "file-\(f).bin", isDirectory: false, allocatedSize: Int64(4096 * (f + 1)),
                                      lastModified: Date(timeIntervalSinceReferenceDate: Double(d * 100 + f)),
                                      kind: kind, kindBytes: KindBytes(kind, Int64(4096 * (f + 1)))))
            }
            var mixed = KindBytes(.other, 10)
            mixed[ContentKind.code.index] = 20
            files.append(FileNode(name: "Other", isDirectory: false, allocatedSize: 30, kind: .code,
                                  kindBytes: mixed, descendantCount: 7, aggregatedCount: 40))
            var total = KindBytes()
            for file in files { total.add(file.kindBytes) }
            folders.append(FileNode(name: "folder \(d) ñ", isDirectory: true, allocatedSize: total.total,
                                    lastModified: Date(timeIntervalSinceReferenceDate: Double(d)), kind: .code,
                                    kindBytes: total, children: files, descendantCount: 47))
        }
        var total = KindBytes()
        for folder in folders { total.add(folder.kindBytes) }
        return FileNode(name: "/Users/x", isDirectory: true, allocatedSize: total.total, kindBytes: total,
                        children: folders, descendantCount: 300 * 48)
    }

    /// v4 stores exactly what v3 did, in about a third of the space.
    @Test func compactFormatRoundTripsAndIsSmaller() throws {
        let result = ScanResult(root: bigTree(), inaccessible: ["/a", "/b ñ"], duration: 4, scannedAt: Date())
        let flat = IndexStore.flatten(result)
        let compact = IndexStore.serialize(flat)
        let full = IndexStore.serializeV3(flat)
        #expect(compact.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) } == 4)
        #expect(Double(compact.count) < Double(full.count) * 0.45)
        let fromCompact = try #require(IndexStore.parse(compact).flatMap(IndexStore.rebuild))
        let fromFull = try #require(IndexStore.parse(full).flatMap(IndexStore.rebuild))
        #expect(collect(fromCompact.root) == collect(result.root))
        #expect(collect(fromFull.root) == collect(result.root))
        #expect(fromCompact.inaccessible == result.inaccessible && fromCompact.scannedAt == result.scannedAt)
    }

    /// An index written by the previous version (v3) loads the same and is rewritten as v4.
    @Test func fullWidthIndexIsReadAndMigrated() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("scan.plist")
        let scannedAt = Date(timeIntervalSinceReferenceDate: 812_345_678.5)
        let result = ScanResult(root: bigTree(), inaccessible: ["/q"], duration: 2, scannedAt: scannedAt)
        try IndexStore.serializeV3(IndexStore.flatten(result)).write(to: file)
        let store = IndexStore(directory: dir)
        #expect(try store.lastScanDate() == scannedAt)
        let loaded = try #require(try store.loadScan())
        #expect(collect(loaded.root) == collect(result.root))
        #expect(try version(of: file) == 4)
        #expect(try store.lastScanDate() == scannedAt)
        let again = try #require(try store.loadScan())
        #expect(collect(again.root) == collect(result.root))
        #expect(again.inaccessible == ["/q"] && again.scannedAt == scannedAt)
    }

    /// A count that does not fit in 32 bits keeps the full-width format: nothing is ever truncated.
    @Test func valuesTooWideForTheCompactFormatKeepV3() throws {
        let child = FileNode(name: "a", isDirectory: false, allocatedSize: 1)
        let root = FileNode(name: "/", isDirectory: true, allocatedSize: 1, children: [child],
                            descendantCount: Int(UInt32.max) + 5)
        let data = IndexStore.serialize(IndexStore.flatten(ScanResult(root: root, inaccessible: [], duration: 0)))
        #expect(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) } == 3)
        let loaded = try #require(IndexStore.parse(data).flatMap(IndexStore.rebuild))
        #expect(loaded.root.descendantCount == Int(UInt32.max) + 5)
    }

    @Test func truncatedCompactIndexIsRejected() throws {
        let data = IndexStore.serialize(IndexStore.flatten(ScanResult(root: bigTree(), inaccessible: [], duration: 0)))
        for cut in [41, data.count / 3, data.count / 2, data.count - 3] {
            #expect(IndexStore.parse(data.prefix(cut)) == nil)
        }
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
        // Breakdown by phases.
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
