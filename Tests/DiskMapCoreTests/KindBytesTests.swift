import Foundation
import Testing
@testable import DiskMapCore

@Suite struct KindBytesTests {
    @Test func behavesLikeTheTenValueArrayItReplaces() {
        var bytes = KindBytes()
        #expect(bytes.count == ContentKind.allCases.count)
        #expect(Array(bytes) == Array(repeating: 0, count: 10))
        bytes[ContentKind.video.index] = 7
        bytes[ContentKind.other.index] += 5
        #expect(Array(bytes) == [7, 0, 0, 0, 0, 0, 0, 0, 0, 5])
        #expect(bytes.description == [Int64(7), 0, 0, 0, 0, 0, 0, 0, 0, 5].description)
        #expect(bytes.total == 12 && bytes.reduce(0, +) == 12)
        #expect(bytes.max() == 7 && bytes.firstIndex(of: 7) == 0)
        var sum = KindBytes(.code, 3)
        sum.add(bytes)
        #expect(Array(sum) == [7, 0, 0, 3, 0, 0, 0, 0, 0, 5])
        // Short arrays are padded with zeros, long ones cut (what the index and the old initializer did).
        #expect(Array(KindBytes([1, 2])) == [1, 2, 0, 0, 0, 0, 0, 0, 0, 0])
        #expect(Array(KindBytes(Array(1...12))) == Array(1...10))
        #expect(KindBytes([1, 2]) == [1, 2, 0, 0, 0, 0, 0, 0, 0, 0])
    }

    /// The layout the node relies on to stay small (see `FileNode`'s field order).
    @Test func nodeStaysCompact() {
        #expect(MemoryLayout<KindBytes>.size == 80)
        #expect(class_getInstanceSize(FileNode.self) <= 176)
    }

    @Test func nodesBuiltFromArraysKeepTheirBreakdown() {
        let node = FileNode(name: "a", isDirectory: true, allocatedSize: 3, kindBytes: [1, 2])
        #expect(Array(node.kindBytes) == [1, 2, 0, 0, 0, 0, 0, 0, 0, 0])
        #expect(node.dominantKind == .images)
        let empty = FileNode(name: "b", isDirectory: false, kind: .code)
        #expect(empty.kindBytes.total == 0 && empty.dominantKind == .code)
    }
}
