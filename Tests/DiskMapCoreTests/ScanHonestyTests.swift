import Foundation
import Testing
@testable import DiskMapCore

private final class NoListing: ProcessListing, Sendable {
    func processes() -> [RunningProcess]? { [] }
    func holders(ofPathsUnder paths: [String]) -> [RunningProcess]? { [] }
}

@Suite struct ScanHonestyTests {
    @Test func completenessFromResult() {
        let root = FileNode(name: "/x", isDirectory: true, allocatedSize: 1, kind: .other, children: [])
        #expect(ScanCompleteness.of(ScanResult(root: root, inaccessible: [], duration: 1)) == .complete)
        let partial = ScanCompleteness.of(ScanResult(root: root, inaccessible: ["/a", "/b", "/c"], duration: 1))
        #expect(partial == .partial(unreadable: 3))
        #expect(ScanCompleteness.of(nil) == .unavailable)
        #expect(ScanCompleteness.complete.label == "Análisis completo")
        #expect(partial.label == "Análisis parcial: no se pudieron leer 3 carpetas")
        #expect(ScanCompleteness.partial(unreadable: 1).label == "Análisis parcial: no se pudieron leer 1 carpeta")
        #expect(ScanCompleteness.unavailable.label == "Sin análisis")
        #expect([partial.jsonName, ScanCompleteness.complete.jsonName, ScanCompleteness.unavailable.jsonName]
            == ["partial", "complete", "unavailable"])
    }

    @Test func partialIndexMatchesSelfAndAncestorsOnly() {
        let i = PartialScanIndex(inaccessible: ["/Users/a/Library/Mail", "/Users/a/x"])
        #expect(i.isPartial("/Users/a") && i.isPartial("/Users/a/Library") && i.isPartial("/Users/a/Library/Mail"))
        #expect(i.isPartial("/") && i.isPartial("/Users/a/Library/"))
        #expect(!i.isPartial("/Users/a/Library/Caches") && !i.isPartial("/Users/a/xy"))
        #expect(!i.isPartial("/Users/a/Library/Mail/Sub") && !i.isPartial("/Users/b"))
        #expect(!PartialScanIndex(inaccessible: []).isPartial("/Users"))
    }

    @Test func plusSuffix() {
        #expect(Format.bytes(1_000_000_000, partial: true).hasSuffix("+"))
        #expect(Format.bytes(1_000_000_000, partial: false) == Format.bytes(1_000_000_000))
    }

    @Test func cleanupItemFromPartialIndexIsMarked() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("airy-honest-\(UUID().uuidString)").path
        for name in ["a", "b"] {
            try FileManager.default.createDirectory(atPath: home + "/Library/Caches/\(name)", withIntermediateDirectories: true)
            try Data(repeating: 1, count: 20_000).write(to: URL(fileURLWithPath: home + "/Library/Caches/\(name)/f"))
        }
        func leaf(_ name: String) -> FileNode {
            FileNode(name: name, isDirectory: true, allocatedSize: 20_000, kind: .caches, children: [])
        }
        let tree = FileNode(name: home, isDirectory: true, allocatedSize: 40_000, kind: .other, children: [
            FileNode(name: "Library", isDirectory: true, allocatedSize: 40_000, kind: .other, children: [
                FileNode(name: "Caches", isDirectory: true, allocatedSize: 40_000, kind: .caches, children: [leaf("a"), leaf("b")]),
            ]),
        ])
        func entry(_ id: String) -> CatalogEntry {
            CatalogEntry(id: id, title: id, explanation: "", whoCreatesIt: "", regenerates: true, risk: .safe,
                         kind: .caches, paths: ["~/Library/Caches/\(id)"], cleanup: .trash)
        }
        let scanner = CleanupScanner(catalog: Catalog(entries: [entry("a"), entry("b")]), runner: FakeRunner(),
                                     probes: FakeProbes(), references: ReferenceChecker(roots: []), home: home,
                                     processListing: NoListing())
        let items = await scanner.findItems(scan: tree, inaccessible: [home + "/Library/Caches/a/sub"])
        let byId = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        #expect(byId["a"]?.sizeIsPartial == true)
        #expect(byId["b"]?.sizeIsPartial == false)
        #expect(CleanupBoard.sizeText(try #require(byId["a"])).hasSuffix("+"))
        // Sin índice no hay marca: se midió el disco.
        #expect(await scanner.findItems(scan: nil, inaccessible: [home + "/Library/Caches/a/sub"]).allSatisfy { !$0.sizeIsPartial })
    }
}
