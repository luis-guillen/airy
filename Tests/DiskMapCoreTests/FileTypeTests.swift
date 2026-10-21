import Testing
@testable import DiskMapCore

@Suite struct FileTypeTests {
    private static func bytes(_ pairs: [(ContentKind, Int64)]) -> [Int64] {
        var result = Array(repeating: Int64(0), count: ContentKind.allCases.count)
        for (kind, size) in pairs { result[kind.index] += size }
        return result
    }

    private static func file(_ name: String, _ kind: ContentKind, _ size: Int64) -> FileNode {
        FileNode(name: name, isDirectory: false, allocatedSize: size, kind: kind, kindBytes: bytes([(kind, size)]))
    }

    private static func folder(_ name: String, kind: ContentKind = .other, _ children: [FileNode]) -> FileNode {
        var kindBytes = Array(repeating: Int64(0), count: ContentKind.allCases.count)
        for child in children { for index in kindBytes.indices { kindBytes[index] += child.kindBytes[index] } }
        return FileNode(name: name, isDirectory: true, allocatedSize: kindBytes.reduce(0, +), kind: kind,
                        kindBytes: kindBytes, children: children)
    }

    @Test func slicesSortedAndSumToOne() {
        let root = Self.folder("/", [Self.file("a.mov", .video, 600), Self.file("b.png", .images, 300),
                                     Self.file("c.txt", .documents, 100)])
        let breakdown = FileTypeBreakdown(root: root)
        #expect(breakdown.total == 1_000)
        #expect(breakdown.slices.map(\.kind) == [.video, .images, .documents])
        #expect(breakdown.slices.map(\.bytes) == [600, 300, 100])
        #expect(abs(breakdown.slices.map(\.fraction).reduce(0, +) - 1) < 1e-9)
    }

    @Test func zeroKindsDropped() {
        let root = Self.folder("/", [Self.file("a.mov", .video, 10)])
        let breakdown = FileTypeBreakdown(root: root)
        #expect(breakdown.slices.map(\.kind) == [.video])
        #expect(FileTypeBreakdown(root: Self.folder("/", [])).slices.isEmpty)
    }

    @Test func itemsOfKindSkipAggregatesAndStopAtApps() {
        let inner = Self.file("Foo", .apps, 500)
        let innerImage = Self.file("icon.png", .images, 40)
        let app = Self.folder("Foo.app", kind: .apps, [inner, innerImage])
        let aggregate = FileNode(name: "Otros (3 elementos)", isDirectory: false, allocatedSize: 30, kind: .apps,
                                 kindBytes: Self.bytes([(.apps, 30)]), aggregatedCount: 3)
        let root = Self.folder("/", [Self.folder("Applications", [app, aggregate]), Self.file("p.png", .images, 70)])

        let apps = FileTypeBreakdown.items(of: .apps, in: root)
        #expect(apps.items.map(\.name) == ["Foo.app"])
        #expect(apps.hiddenBytes == 30)

        let images = FileTypeBreakdown.items(of: .images, in: root)
        #expect(images.items.map(\.name) == ["p.png", "icon.png"])
        #expect(images.hiddenBytes == 0)
    }

    @Test func gitAndBuildFoldersAreNeverListed() {
        let git = Self.folder(".git", kind: .code, [Self.file("ORIG_HEAD", .code, 900), Self.file("hook.sh", .code, 5)])
        let build = Self.folder(".build", kind: .code, [Self.file("main.swift", .code, 50)])
        let root = Self.folder("/", [Self.folder("proj", [git, build, Self.file("app.swift", .code, 10)])])
        #expect(FileTypeBreakdown.items(of: .code, in: root).items.map(\.name) == ["app.swift"])
    }

    @Test func hiddenBytesAccountsForRest() {
        let files = (1...5).map { Self.file("f\($0).mov", .video, Int64($0) * 10) }
        let aggregate = FileNode(name: "Otros (9 elementos)", isDirectory: false, allocatedSize: 7, kind: .video,
                                 kindBytes: Self.bytes([(.video, 7)]), aggregatedCount: 9)
        let root = Self.folder("/", files + [aggregate])
        let result = FileTypeBreakdown.items(of: .video, in: root, limit: 2)
        #expect(result.items.map(\.name) == ["f5.mov", "f4.mov"])
        #expect(result.hiddenBytes == 10 + 20 + 30 + 7)
    }

    @Test func folderAttributedBytesAreListedAsTheFolder() {
        // Lo no reconocido de Caches pasó a .caches: el nodo hijo es .other, pero la carpeta tiene los bytes.
        let blob = Self.file("blob", .other, 400)
        let known = Self.file("x.cache", .caches, 100)
        var kb = Self.bytes([(.caches, 500)])
        kb[ContentKind.caches.index] = 500
        let caches = FileNode(name: "Caches", isDirectory: true, allocatedSize: 500, kind: .caches,
                              kindBytes: kb, children: [blob, known])
        let root = Self.folder("/", [caches])
        let result = FileTypeBreakdown.items(of: .caches, in: root)
        #expect(result.items.map(\.name) == ["Caches"])
        #expect(result.hiddenBytes == 0)
    }

    @Test func emptyRootAndZeroLimit() {
        let empty = Self.folder("/", [])
        #expect(FileTypeBreakdown.items(of: .video, in: empty).items.isEmpty)
        #expect(FileTypeBreakdown.items(of: .video, in: empty).hiddenBytes == 0)
        let root = Self.folder("/", [Self.file("a.mov", .video, 9)])
        let none = FileTypeBreakdown.items(of: .video, in: root, limit: 0)
        #expect(none.items.isEmpty && none.hiddenBytes == 9)
    }
}
