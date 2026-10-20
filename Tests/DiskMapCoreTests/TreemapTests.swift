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
        #expect(tiles.contains { $0.node === big })
    }

    @Test func othersCountAddsAggregatedChildren() {
        let big = FileNode(name: "big", isDirectory: false, allocatedSize: 1_000_000_000)
        let agg = FileNode(name: "Otros", isDirectory: false, allocatedSize: 50_000, aggregatedCount: 100)
        let tiny = FileNode(name: "t", isDirectory: false, allocatedSize: 20_000)
        let tiny2 = FileNode(name: "t2", isDirectory: false, allocatedSize: 20_000)
        let root = FileNode(name: "r", isDirectory: true, allocatedSize: 1_000_000_020, children: [big, agg, tiny, tiny2])
        let tiles = Treemap.tiles(for: root, in: CGRect(x: 0, y: 0, width: 800, height: 600))
        #expect(tiles.first { $0.node == nil }?.othersCount == 102)
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
