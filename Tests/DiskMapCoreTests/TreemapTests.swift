import Testing
import CoreGraphics
import Foundation
@testable import DiskMapCore

struct TreemapTests {
    let sample: [Double] = [6, 6, 4, 3, 2, 2, 1]

    @Test func areasAreProportional() {
        let rect = CGRect(x: 0, y: 0, width: 600, height: 400)
        let rects = Treemap.squarify(values: sample, in: rect)
        let sum = sample.reduce(0, +)
        #expect(rects.count == sample.count)
        for (v, r) in zip(sample, rects) {
            let ratio = Double(r.width * r.height) / Double(rect.width * rect.height)
            #expect(abs(ratio - v / sum) < 0.005)
        }
    }

    @Test func rectsStayInsideAndDontOverlap() {
        var state: UInt64 = 42
        func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 33) / Double(1 << 31) * 100 + 1
        }
        let values = (0..<200).map { _ in next() }.sorted(by: >)
        let rect = CGRect(x: 10, y: 20, width: 800, height: 600)
        let rects = Treemap.squarify(values: values, in: rect)
        let bounds = rect.insetBy(dx: -0.01, dy: -0.01)
        for r in rects { #expect(bounds.contains(r)) }
        for i in 0..<rects.count {
            for j in (i + 1)..<rects.count {
                let inter = rects[i].intersection(rects[j])
                #expect(inter.isNull || inter.width * inter.height <= 0.01)
            }
        }
    }

    @Test func aspectRatiosAreSquarish() {
        let rects = Treemap.squarify(values: sample, in: CGRect(x: 0, y: 0, width: 600, height: 400))
        let worst = rects.map { max($0.width / $0.height, $0.height / $0.width) }.max() ?? 0
        #expect(worst < 3)
    }

    @Test func groupsTinyEntriesIntoOthers() {
        let big = FileNode(name: "big", isDirectory: false, allocatedSize: 1_000_000_000)
        let small = (0..<5000).map { FileNode(name: "s\($0)", isDirectory: false, allocatedSize: 1024) }
        let root = FileNode(name: "root", isDirectory: true, allocatedSize: 1_005_120_000, children: [big] + small)
        let tiles = Treemap.tiles(for: root, in: CGRect(x: 0, y: 0, width: 800, height: 600))
        #expect(tiles.count <= 2)
        let others = tiles.first { $0.node == nil }
        #expect(others?.othersCount == 5000)
        #expect(others?.id == -root.id - 1)
        #expect(others?.size == Int64(5_120_000))
        #expect(tiles.first { $0.node === big }?.size == Int64(1_000_000_000))
        #expect(tiles.contains { $0.node === big })
    }

    @Test func othersCountAddsAggregatedChildren() {
        let big = FileNode(name: "big", isDirectory: false, allocatedSize: 1_000_000_000)
        let agg = FileNode(name: "Otros", isDirectory: false, allocatedSize: 50_000, aggregatedCount: 100)
        let tinies = (0..<99).map { FileNode(name: "t\($0)", isDirectory: false, allocatedSize: 60_000) }
        let root = FileNode(name: "r", isDirectory: true, allocatedSize: 1_006_000_000, children: [big, agg] + tinies)
        let tiles = Treemap.tiles(for: root, in: CGRect(x: 0, y: 0, width: 800, height: 600))
        #expect(tiles.first { $0.node == nil }?.othersCount == 199)
    }

    @Test func gapKeepsTilesApart() {
        let kids = (1...6).map { FileNode(name: "f\($0)", isDirectory: false, allocatedSize: Int64($0) * 1_000_000) }
        let root = FileNode(name: "r", isDirectory: true, allocatedSize: 21_000_000, children: kids)
        let tiles = Treemap.tiles(for: root, in: CGRect(x: 0, y: 0, width: 400, height: 300), gap: 2)
        for i in 0..<tiles.count {
            for j in (i + 1)..<tiles.count {
                #expect(!tiles[i].rect.intersects(tiles[j].rect))
            }
        }
    }

    @Test func emptyNodeGivesNoTiles() {
        let root = FileNode(name: "r", isDirectory: true)
        #expect(Treemap.tiles(for: root, in: CGRect(x: 0, y: 0, width: 100, height: 100)).isEmpty)
        let z = FileNode(name: "r", isDirectory: true, children: [FileNode(name: "z", isDirectory: false)])
        #expect(Treemap.tiles(for: z, in: CGRect(x: 0, y: 0, width: 100, height: 100)).isEmpty)
    }
}

struct TreemapStabilityTests {
    /// Hermanos del mismo tamaño: el orden (y por tanto la posición) no depende del orden de entrada.
    @Test func equalSizedSiblingsKeepStableOrder() {
        let kids = (0..<8).map { FileNode(name: "k\($0)", isDirectory: true, allocatedSize: 1_000_000) }
        let big = FileNode(name: "big", isDirectory: true, allocatedSize: 9_000_000)
        let root = FileNode(name: "r", isDirectory: true, allocatedSize: 17_000_000, children: [big] + kids)
        let rect = CGRect(x: 0, y: 0, width: 640, height: 400)
        let first = Treemap.tiles(for: root, in: rect)
        root.children = [kids[5], kids[2], big, kids[7], kids[0], kids[3], kids[6], kids[1], kids[4]]
        let second = Treemap.tiles(for: root, in: rect)
        root.children.reverse()
        let third = Treemap.tiles(for: root, in: rect)
        #expect(first.map(\.id) == second.map(\.id))
        #expect(first.map(\.id) == third.map(\.id))
        #expect(first.map(\.rect) == third.map(\.rect))
        // Empates: por id ascendente, tras el mayor.
        #expect(first.map(\.id) == [big.id] + kids.map(\.id).sorted())
    }

    /// El agregado "Otros" empata con un hijo real: también orden determinista.
    @Test func othersTileTiesAreDeterministic() {
        let a = FileNode(name: "a", isDirectory: false, allocatedSize: 1_000_000_000)
        let tiny = (0..<10).map { FileNode(name: "t\($0)", isDirectory: false, allocatedSize: 10) }
        let root = FileNode(name: "r", isDirectory: true, allocatedSize: 1_000_000_100, children: [a] + tiny)
        let rect = CGRect(x: 0, y: 0, width: 300, height: 200)
        let ids1 = Treemap.tiles(for: root, in: rect).map(\.id)
        root.children.shuffle()
        let ids2 = Treemap.tiles(for: root, in: rect).map(\.id)
        #expect(ids1 == ids2)
    }

    /// La instantánea (tomada en el hilo principal) da el mismo resultado que leer el nodo.
    @Test func snapshotLayoutMatchesNodeLayout() {
        let kids = (1...30).map { FileNode(name: "f\($0)", isDirectory: $0 % 2 == 0, allocatedSize: Int64($0 * $0) * 1000) }
        let root = FileNode(name: "r", isDirectory: true, allocatedSize: 9_455_000, children: kids)
        let rect = CGRect(x: 0, y: 0, width: 800, height: 500)
        let direct = Treemap.tiles(for: root, in: rect)
        let snap = Treemap.Snapshot(of: root)
        let viaSnapshot = Treemap.tiles(for: snap, in: rect)
        #expect(direct.map(\.id) == viaSnapshot.map(\.id))
        #expect(direct.map(\.rect) == viaSnapshot.map(\.rect))
        #expect(snap.parentID == root.id)
    }
}
