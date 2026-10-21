import Foundation
import Testing
@testable import DiskMapCore

private let GB: Int64 = 1_000_000_000

private func dir(_ name: String, _ children: [FileNode], kind: ContentKind = .other) -> FileNode {
    let size = children.reduce(Int64(0)) { $0 + $1.allocatedSize }
    var bytes = Array(repeating: Int64(0), count: ContentKind.allCases.count)
    for child in children { for (i, b) in child.kindBytes.enumerated() { bytes[i] += b } }
    return FileNode(name: name, isDirectory: true, allocatedSize: size, kind: kind, kindBytes: bytes, children: children)
}

private func file(_ name: String, _ bytes: Int64, kind: ContentKind = .other) -> FileNode {
    var kinds = Array(repeating: Int64(0), count: ContentKind.allCases.count)
    kinds[ContentKind.allCases.firstIndex(of: kind)!] = bytes
    return FileNode(name: name, isDirectory: false, allocatedSize: bytes, kind: kind, kindBytes: kinds)
}

/// "/" with a home, a temp folder and some system data; `after` adds the day's growth.
private func tree(after: Bool) -> ScanResult {
    let desktop = dir("Desktop", after
        ? [file("Mario Kart 8.zip", 13 * GB), dir("Mario Kart 8", [file("game.bin", 13 * GB)]), file("notes.txt", 1 * GB)]
        : [file("notes.txt", 1 * GB)])
    let developer = dir("Developer", [dir("app", [dir(".claude", [dir("worktrees", [
        file("wt.bin", after ? 9 * GB : 1 * GB, kind: .code)])])])])
    let movies = dir("Movies", [file("old.mov", after ? 1 * GB : 6 * GB, kind: .video)])
    let home = dir("Users", [dir("ana", [desktop, developer, movies])])
    let temp = dir("private", [dir("var", [dir("folders", [dir("xy", [dir("abc", [dir("T", after
        ? [file("t1", 12 * GB, kind: .caches), file("t2", 13 * GB, kind: .caches)]
        : [file("t1", 1 * GB, kind: .caches)])])])])])])
    let other = FileNode(name: "Other (12 items)", isDirectory: true, allocatedSize: 5 * GB, aggregatedCount: 12)
    let root = dir("/", [home, temp, dir("System", [file("kernel", 5 * GB, kind: .system)]), other])
    return ScanResult(root: root, inaccessible: [], duration: 1,
                      scannedAt: Date(timeIntervalSince1970: after ? 1_800_086_400 : 1_800_000_000))
}

@Suite struct ScanChangesTests {
    @Test func summaryIsCompactAndSkipsAggregates() {
        let summary = ScanSummary.make(from: tree(after: true), maxDepth: 3)
        #expect(summary.root == "/")
        #expect(summary.entries.contains { $0.path == "/Users/ana/Desktop" })
        #expect(!summary.entries.contains { $0.path == "/Users/ana/Desktop/Mario Kart 8.zip" }) // depth 4
        #expect(!summary.entries.contains { $0.path.contains("Other") })
        #expect(summary.entries.allSatisfy { $0.bytes >= ScanSummary.minimumBytes })
        // Parents precede children and point to them.
        for entry in summary.entries where entry.parent >= 0 {
            let parent = summary.entries[Int(entry.parent)]
            #expect(entry.path.hasPrefix(parent.path + "/") || parent.path == "/")
        }
        let capped = ScanSummary.make(from: tree(after: true), maxEntries: 4)
        #expect(capped.entries.count <= 4)
        #expect(capped.floorBytes >= ScanSummary.minimumBytes)
        #expect(capped.entries.allSatisfy { $0.parent < 0 || capped.entries.indices.contains(Int($0.parent)) })
    }

    @Test func growthIsAttributedToTheFolderThatExplainsIt() throws {
        let previous = ScanSummary.make(from: tree(after: false))
        let current = ScanSummary.make(from: tree(after: true))
        let changes = try #require(ScanChanges.compute(previous: previous, current: current))
        #expect(changes.growth.map(\.path) == ["/Users/ana/Desktop", "/private/var/folders/xy/abc/T",
                                               "/Users/ana/Developer/app/.claude/worktrees"])
        let desktop = changes.growth[0]
        #expect(desktop.delta == 26 * GB && desktop.before == 1 * GB)
        #expect(desktop.hints == ["Mario Kart 8", "Mario Kart 8.zip"])
        #expect(changes.growth[1].delta == 24 * GB)
        #expect(changes.shrink.map(\.path) == ["/Users/ana/Movies/old.mov"])
        #expect(changes.shrink[0].delta == -5 * GB)
        #expect(changes.kinds.map(\.kind) == [.other, .caches, .code, .video])
        #expect(changes.totalDelta == current.totalBytes - previous.totalBytes)
        #expect(changes.since == previous.scannedAt)
        // Thresholds and limits.
        let big = try #require(ScanChanges.compute(previous: previous, current: current, minimumBytes: 20 * GB, limit: 1))
        #expect(big.growth.map(\.path) == ["/Users/ana/Desktop"] && big.shrink.isEmpty)
        // Different roots are not compared.
        var other = current
        other.root = "/Volumes/X"
        #expect(ScanChanges.compute(previous: previous, current: other) == nil)
    }

    @Test func storeKeepsPreviousAndFallsBackToAnOldIndex() throws {
        let directory = TestTemp.url("changes")
        let index = IndexStore(directory: directory)
        // An index saved before summaries existed: only scan.plist (v3), then a legacy v2 one.
        try index.saveScan(tree(after: false))
        let store = ScanChangeStore(directory: directory)
        #expect(store.load() == nil && store.changes() == nil)
        let fallback = { (try? index.loadScan()).flatMap { $0 }.map { ScanSummary.make(from: $0) } }
        let first = try store.record(ScanSummary.make(from: tree(after: true)), fallbackPrevious: fallback)
        #expect(first.previous?.totalBytes == tree(after: false).root.allocatedSize)
        #expect(store.changes()?.growth.first?.path == "/Users/ana/Desktop")

        // A second record makes the stored current the previous one (the fallback is not used).
        let second = try store.record(ScanSummary.make(from: tree(after: false)), fallbackPrevious: {
            Issue.record("fallback used"); return nil
        })
        #expect(second.previous == first.current)
        #expect(store.changes()?.shrink.first?.path == "/Users/ana/Desktop")

        // Legacy v2 index (no date in the header) as the fallback.
        let legacyDir = TestTemp.url("changes-legacy")
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        var data = IndexStore.serialize(IndexStore.flatten(tree(after: false)))
        data.replaceSubrange(4..<8, with: withUnsafeBytes(of: UInt32(2)) { Data($0) })
        data.removeSubrange(32..<40)
        try data.write(to: legacyDir.appendingPathComponent("scan.plist"))
        let legacyIndex = IndexStore(directory: legacyDir)
        let legacy = ScanChangeStore(directory: legacyDir)
        let record = try legacy.record(ScanSummary.make(from: tree(after: true)), fallbackPrevious: {
            (try? legacyIndex.loadScan()).flatMap { $0 }.map { ScanSummary.make(from: $0) }
        })
        #expect(record.previous?.scannedAt == nil)
        #expect(legacy.changes()?.growth.count == 3)
    }

    @Test func oldOrForeignSummaryFilesDecodeOrAreIgnored() throws {
        let directory = TestTemp.directory("changes-files")
        let url = URL(fileURLWithPath: directory).appendingPathComponent(ScanChangeStore.fileName)
        // Minimal fields only: defaults fill the rest.
        try Data(#"{"version":1,"current":{"root":"/"}}"#.utf8).write(to: url)
        let minimal = try #require(ScanChangeStore(directory: URL(fileURLWithPath: directory)).load())
        #expect(minimal.current.entries.isEmpty && minimal.previous == nil)
        // A newer version or garbage is ignored, never a crash.
        try Data(#"{"version":99,"current":{"root":"/"}}"#.utf8).write(to: url)
        #expect(ScanChangeStore(directory: URL(fileURLWithPath: directory)).load() == nil)
        try Data("garbage".utf8).write(to: url)
        #expect(ScanChangeStore(directory: URL(fileURLWithPath: directory)).load() == nil)
        // A different root replaces the record without a previous summary.
        let store = ScanChangeStore(directory: URL(fileURLWithPath: directory))
        try store.record(ScanSummary.make(from: tree(after: false)), fallbackPrevious: { nil })
        var other = ScanSummary.make(from: tree(after: true))
        other.root = "/Volumes/X"
        #expect(try store.record(other, fallbackPrevious: { nil }).previous == nil)
    }

    @Test func labelsTheTemporaryFolder() {
        #expect(ScanChanges.label(for: NSTemporaryDirectory()) == "Temporary files")
        #expect(ScanChanges.label(for: "/Users/ana/Desktop") == "Desktop")
    }

    @Test func whatChangedToolIsMetadataOnly() async throws {
        let support = TestTemp.url("changes-mcp")
        let paths = AppPaths(support: support, legacySupport: nil)
        let env = AiryEnvironment(
            home: "/Users/ana", paths: paths, catalog: Catalog(entries: []), catalogError: nil,
            settings: SettingsStore(file: paths.settingsFile), index: IndexStore(directory: support),
            log: OperationLog(file: paths.operationsFile), runner: FakeRunner(), probes: FakeProbes(),
            processGuard: ProcessGuard(), references: ReferenceChecker(roots: []), urlOpener: FakeOpener(),
            capacity: { nil })
        let context = MCPCallContext(environment: env, client: "test")
        let none = await WhatChangedTool().call([:], context: context)
        #expect(!none.isError && none.structured?["available"]?.boolValue == false)

        let store = ScanChangeStore(directory: support)
        try store.record(ScanSummary.make(from: tree(after: false)), fallbackPrevious: { nil })
        let single = await WhatChangedTool().call([:], context: context)
        #expect(single.structured?["available"]?.boolValue == false)

        try store.record(ScanSummary.make(from: tree(after: true)), fallbackPrevious: { nil })
        let result = await WhatChangedTool().call(["limit": .number(2), "min_bytes": .number(Double(2 * GB))],
                                                  context: context)
        let value = try #require(result.structured)
        #expect(value["available"]?.boolValue == true)
        guard case .array(let growth)? = value["growth"] else { Issue.record("growth"); return }
        #expect(growth.count == 2)
        #expect(growth.first?["label"]?.stringValue == "Desktop")
        #expect(growth.first?["delta_bytes"]?.intValue == Int(26 * GB))
        #expect(result.text.contains("Largest growth: Desktop"))
        // Validation: limit out of range is rejected by the schema.
        #expect(MCPSchemaValidator.violation(of: .object(["limit": .number(0)]), against: WhatChangedTool().inputSchema) != nil)
    }
}
