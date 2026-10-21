import Foundation
import Synchronization
import Testing
@testable import DiskMapCore

private final class FakeFileUsage: FileUsageReading {
    private let dates: [String: Date]
    private let calls = Mutex<[String]>([])
    init(_ dates: [String: Date] = [:]) { self.dates = dates }
    var queried: [String] { calls.withLock { $0 } }
    func lastOpened(path: String) -> Date? {
        calls.withLock { $0.append(path) }
        return dates[path]
    }
}

private let day: TimeInterval = 86_400
private let nowDate = Date(timeIntervalSince1970: 1_800_000_000)

/// Temporary folder with a home and real files (the path gate does `lstat`) plus their `FileNode` tree.
private struct Fixture {
    let tmp: String
    var home: String { tmp + "/home" }
    let root: FileNode
    private let homeNode: FileNode

    init() {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("lo-\(UUID().uuidString)").path
        try! FileManager.default.createDirectory(atPath: tmp + "/home", withIntermediateDirectories: true)
        homeNode = FileNode(name: "home", isDirectory: true)
        root = FileNode(name: tmp, isDirectory: true, children: [homeNode])
    }

    /// Creates the file on disk and the node under `rel` (relative to `tmp`); creates the tree's intermediate folders.
    @discardableResult
    func file(_ rel: String, size: Int64, kind: ContentKind = .other, modified: Date? = nil) -> FileNode {
        let full = tmp + "/" + rel
        try! FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: full, contents: Data([1]))
        var parent = root
        let parts = rel.split(separator: "/").map(String.init)
        for name in parts.dropLast() {
            if let existing = parent.children.first(where: { $0.name == name }) { parent = existing; continue }
            let dir = FileNode(name: name, isDirectory: true)
            dir.parent = parent
            parent.children.append(dir)
            parent = dir
        }
        let node = FileNode(name: parts.last!, isDirectory: false, allocatedSize: size, lastModified: modified, kind: kind)
        node.parent = parent
        parent.children.append(node)
        return node
    }

    func finder(_ usage: FileUsageReading = FakeFileUsage(), protected: [String] = [], budget: Duration = .seconds(5))
        -> LargeOldFinder {
        var settings = AirySettings()
        settings.protectedPaths = protected
        let catalog = Catalog(entries: [])
        let classifier = RiskClassifier(catalog: catalog, settings: settings, home: home)
        let gate = PathGate(home: home, catalog: catalog, userProtected: ProtectList(patterns: protected, home: home))
        return LargeOldFinder(classifier: classifier, catalog: catalog, gate: gate, home: home, usage: usage,
                              now: { nowDate }, budget: budget)
    }
}

private func file(_ id: String, _ risk: Risk, bytes: Int64 = 10, protected: Bool = false) -> ActionableFile {
    ActionableFile(path: "/x/\(id)", name: id, bytes: bytes, kind: .other, lastModified: nil, lastOpened: nil, risk: risk,
                   protection: protected ? ProtectionMatch(source: .airy, pattern: id, reason: "r") : nil, reasons: [])
}

@Suite struct LargeOldTests {
    @Test func cancelledLookupStopsWalking() async {
        let f = Fixture()
        f.file("home/Downloads/big.bin", size: 200_000_000)
        let finder = f.finder()
        let root = f.root
        let task = Task.detached { () -> [ActionableFile] in
            withUnsafeCurrentTask { $0?.cancel() }
            return finder.find(in: root, query: LargeOldQuery())
        }
        #expect(await task.value.isEmpty)
        let types = Task.detached { () -> Int in
            withUnsafeCurrentTask { $0?.cancel() }
            return FileTypeBreakdown.items(of: .other, in: root).items.count
        }
        #expect(await types.value == 0)
    }

    @Test func findsOnlyFilesAboveMinimum() {
        let f = Fixture()
        f.file("home/Downloads/big.bin", size: 200_000_000)
        f.file("home/Downloads/small.bin", size: 50_000_000)
        var q = LargeOldQuery(); q.minBytes = 100_000_000
        #expect(f.finder().find(in: f.root, query: q).map(\.name) == ["big.bin"])
    }

    @Test func skipsAggregatesAndAppBundles() {
        let f = Fixture()
        f.file("home/Downloads/ok.bin", size: 300_000_000)
        f.file("home/Downloads/Foo.app/Contents/MacOS/Foo", size: 900_000_000)
        let other = FileNode(name: "Otros (40 elementos)", isDirectory: false, allocatedSize: 700_000_000, aggregatedCount: 40)
        other.parent = f.root.children[0]; f.root.children[0].children.append(other)
        let dir = f.root.children[0].children.first { $0.name == "Downloads" }!
        dir.allocatedSize = 5_000_000_000    // a large folder is not a file either
        #expect(f.finder().find(in: f.root, query: LargeOldQuery()).map(\.name) == ["ok.bin"])
    }

    @Test func idleFilterUsesNewestOfOpenedAndModified() {
        let f = Fixture()
        let old = nowDate.addingTimeInterval(-365 * day)
        let a = f.file("home/Downloads/opened.bin", size: 200_000_000, modified: old)
        f.file("home/Downloads/idle.bin", size: 200_000_000, modified: old)
        let usage = FakeFileUsage([a.path: nowDate.addingTimeInterval(-30 * day)])
        var q = LargeOldQuery(); q.minMonthsIdle = 6
        #expect(f.finder(usage).find(in: f.root, query: q).map(\.name) == ["idle.bin"])
        q.minMonthsIdle = nil
        #expect(f.finder(usage).find(in: f.root, query: q).count == 2)
    }

    @Test func noDatesNeverPassesAMonthsFilter() {
        let f = Fixture()
        f.file("home/Downloads/nodate.bin", size: 200_000_000)
        var q = LargeOldQuery(); q.minMonthsIdle = 3
        #expect(f.finder().find(in: f.root, query: q).isEmpty)
    }

    @Test func spotlightBudgetExhaustedMeansUnknownNotOld() {
        let f = Fixture()
        f.file("home/Downloads/a.bin", size: 200_000_000, modified: nowDate.addingTimeInterval(-900 * day))
        let usage = FakeFileUsage()
        var q = LargeOldQuery(); q.minMonthsIdle = 6
        #expect(f.finder(usage, budget: .zero).find(in: f.root, query: q).isEmpty)
        #expect(usage.queried.isEmpty)
        q.minMonthsIdle = nil
        let shown = f.finder(usage, budget: .zero).find(in: f.root, query: q)
        #expect(shown.count == 1 && shown[0].openDateUnknown && shown[0].lastOpened == nil)
    }

    @Test func sortsBySizeOldestAndName() {
        let f = Fixture()
        f.file("home/Downloads/b2.bin", size: 300_000_000, modified: nowDate.addingTimeInterval(-10 * day))
        f.file("home/Downloads/b10.bin", size: 100_000_000, modified: nowDate.addingTimeInterval(-500 * day))
        f.file("home/Downloads/a.bin", size: 200_000_000, modified: nowDate.addingTimeInterval(-100 * day))
        f.file("home/Downloads/z.bin", size: 150_000_000)   // without dates: last in "oldest"
        var q = LargeOldQuery()
        q.sort = .size
        #expect(f.finder().find(in: f.root, query: q).map(\.name) == ["b2.bin", "a.bin", "z.bin", "b10.bin"])
        q.sort = .oldest
        #expect(f.finder().find(in: f.root, query: q).map(\.name) == ["b10.bin", "a.bin", "b2.bin", "z.bin"])
        q.sort = .name
        #expect(f.finder().find(in: f.root, query: q).map(\.name) == ["a.bin", "b2.bin", "b10.bin", "z.bin"])
        q.limit = 2
        #expect(f.finder().find(in: f.root, query: q).count == 2)
    }

    @Test func kindFilterAndHomeScope() {
        let f = Fixture()
        f.file("home/Movies/v.mov", size: 400_000_000, kind: .video)
        f.file("home/Documents/d.pdf", size: 400_000_000, kind: .documents)
        f.file("shared/outside.bin", size: 400_000_000, kind: .video)
        var q = LargeOldQuery()
        #expect(Set(f.finder().find(in: f.root, query: q).map(\.name)) == ["v.mov", "d.pdf"])
        q.kinds = [.video]
        #expect(f.finder().find(in: f.root, query: q).map(\.name) == ["v.mov"])
        q.scope = .everything
        #expect(Set(f.finder().find(in: f.root, query: q).map(\.name)) == ["v.mov", "outside.bin"])
    }

    @Test func personalFilesAtLeastAmber() {
        let f = Fixture()
        f.file("home/Movies/x.mov", size: 300_000_000)
        f.file("home/Library/Application Support/x.bin", size: 300_000_000)
        let found = f.finder().find(in: f.root, query: LargeOldQuery())
        #expect(found.count == 2)
        #expect(found.allSatisfy { $0.risk == .yourCall && $0.canSelect })
    }

    @Test func protectedFileIsRedWithoutCheckbox() {
        let f = Fixture()
        f.file("home/Library/Mail/x.emlx", size: 300_000_000)
        f.file("home/Documents/mine.bin", size: 300_000_000)
        let found = f.finder(protected: ["~/Documents/mine.bin"]).find(in: f.root, query: LargeOldQuery())
        #expect(found.count == 2)
        for item in found {
            #expect(item.risk == .doNotTouch && !item.canSelect && item.protection != nil, "\(item.path)")
        }
    }

    @Test func missingFileFailsTheGateAndIsRed() {
        let f = Fixture()
        let node = f.file("home/Downloads/gone.bin", size: 300_000_000)
        try? FileManager.default.removeItem(atPath: node.path)
        let found = f.finder().find(in: f.root, query: LargeOldQuery())
        #expect(found.first?.risk == .doNotTouch && found.first?.protection != nil)
    }

    @Test func usageOnlyQueriedForCandidates() {
        let f = Fixture()
        for i in 0..<3 { f.file("home/Downloads/big\(i).bin", size: 200_000_000) }
        for i in 0..<50 { f.file("home/Downloads/small\(i).bin", size: 1_000) }
        let usage = FakeFileUsage()
        _ = f.finder(usage).find(in: f.root, query: LargeOldQuery())
        #expect(usage.queried.count == 3)
    }

    @Test func selectAllNeverSelectsRed() {
        let files = [file("g", .safe), file("a", .yourCall), file("r", .doNotTouch), file("p", .yourCall, protected: true)]
        var sel = FileSelection()
        sel.selectAll(files)
        #expect(sel.ids == ["/x/g", "/x/a"])
        #expect(sel.bytes(in: files) == 20)
    }

    @Test func selectAllGreenOnlyGreen() {
        let files = [file("g", .safe), file("a", .yourCall), file("r", .doNotTouch)]
        var sel = FileSelection()
        sel.selectAllGreen(files)
        #expect(sel.ids == ["/x/g"])
        sel.clear()
        #expect(sel.ids.isEmpty)
    }

    @Test func toggleIgnoresRed() {
        var sel = FileSelection()
        sel.toggle(file("r", .doNotTouch))
        sel.toggle(file("p", .yourCall, protected: true))
        #expect(sel.ids.isEmpty)
        sel.toggle(file("a", .yourCall)); #expect(sel.ids == ["/x/a"])
        sel.toggle(file("a", .yourCall)); #expect(sel.ids.isEmpty)
    }

    @Test func pruneDropsVanished() {
        let files = [file("g", .safe), file("a", .yourCall)]
        var sel = FileSelection()
        sel.selectAll(files)
        sel.prune(to: [file("g", .safe), file("a", .doNotTouch)])
        #expect(sel.ids == ["/x/g"])
        #expect(sel.selected(in: files).map(\.name) == ["g"])
    }

    @Test func groupsGreenFirst() {
        let groups = FileSelection.groups([file("r", .doNotTouch), file("a", .yourCall), file("g", .safe), file("g2", .safe)])
        #expect(groups.map(\.risk) == [.safe, .yourCall, .doNotTouch])
        #expect(groups[0].files.map(\.name) == ["g", "g2"])
        #expect(FileSelection.groups([file("a", .yourCall)]).map(\.risk) == [.yourCall])
    }
}
