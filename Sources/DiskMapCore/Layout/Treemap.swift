import CoreGraphics
import Foundation

public struct TreemapTile: Sendable, Identifiable {
    public let id: Int
    public let rect: CGRect
    /// `nil` ⇒ "Other (N items)" tile.
    public let node: FileNode?
    public let othersCount: Int
    /// Bytes the tile represents (the node's, or the sum of the "Other" group).
    public let size: Int64

    public init(id: Int, rect: CGRect, node: FileNode?, othersCount: Int = 0, size: Int64 = 0) {
        self.id = id
        self.rect = rect
        self.node = node
        self.othersCount = othersCount
        self.size = size
    }
}

public enum Treemap {
    /// "Squarified" treemap (Bruls, Huizing, van Wijk). The values should arrive
    /// sorted from largest to smallest; returns one rect per value, in the same order.
    public static func squarify(values: [Double], in rect: CGRect) -> [CGRect] {
        var result = Array(repeating: CGRect.zero, count: values.count)
        let total = values.reduce(0) { $0 + max($1, 0) }
        guard total > 0, rect.width > 0, rect.height > 0 else { return result }
        let scale = Double(rect.width * rect.height) / total
        let areas = values.map { max($0, 0) * scale }

        var free = rect
        var start = 0
        while start < areas.count {
            let side = Double(min(free.width, free.height))
            var end = start + 1
            var rowSum = areas[start]
            var best = worst(sum: rowSum, maxA: areas[start], minA: areas[start], side: side)
            while end < areas.count {
                let a = areas[end]
                let newSum = rowSum + a
                let maxA = max(areas[start], a)   // sorted: the first is the largest
                let minA = min(areas[end - 1], a) // …and the last in the row, the smallest
                let w = worst(sum: newSum, maxA: maxA, minA: minA, side: side)
                if w > best { break }
                best = w; rowSum = newSum; end += 1
            }
            // Lays the row out along the short side.
            if rowSum <= 0 {
                for i in start..<end { result[i] = CGRect(x: free.minX, y: free.minY, width: 0, height: 0) }
            } else if free.width >= free.height {
                let w = CGFloat(rowSum) / free.height
                var y = free.minY
                for i in start..<end {
                    let h = i == end - 1 ? free.maxY - y : CGFloat(areas[i]) / w
                    result[i] = CGRect(x: free.minX, y: y, width: w, height: h)
                    y += h
                }
                free = CGRect(x: free.minX + w, y: free.minY, width: max(free.width - w, 0), height: free.height)
            } else {
                let h = CGFloat(rowSum) / free.width
                var x = free.minX
                for i in start..<end {
                    let w = i == end - 1 ? free.maxX - x : CGFloat(areas[i]) / h
                    result[i] = CGRect(x: x, y: free.minY, width: w, height: h)
                    x += w
                }
                free = CGRect(x: free.minX, y: free.minY + h, width: free.width, height: max(free.height - h, 0))
            }
            start = end
        }
        return result
    }

    private static func worst(sum: Double, maxA: Double, minA: Double, side: Double) -> Double {
        guard sum > 0, minA > 0, side > 0 else { return .infinity }
        let s2 = side * side, sum2 = sum * sum
        return max(s2 * maxA / sum2, sum2 / (s2 * minA))
    }

    /// Children of a node copied on the thread that owns the tree (the main one), to compute
    /// the layout on another thread without reading `FileNode` while someone modifies it (e.g. after
    /// sending something to the Trash). The references to the nodes only travel; they are not read.
    public struct Snapshot: Sendable {
        public struct Child: Sendable {
            public let node: FileNode
            public let id: Int
            public let size: Int64
            public let aggregatedCount: Int
        }
        public let parentID: Int
        public let children: [Child]

        public init(of node: FileNode) {
            parentID = node.id
            children = node.children.map {
                Child(node: $0, id: $0.id, size: $0.allocatedSize, aggregatedCount: $0.aggregatedCount)
            }
        }
    }

    public static func tiles(
        for node: FileNode,
        in rect: CGRect,
        gap: CGFloat = 2,
        minTileArea: CGFloat = 36
    ) -> [TreemapTile] {
        tiles(for: Snapshot(of: node), in: rect, gap: gap, minTileArea: minTileArea)
    }

    /// Largest first; at equal size the id decides, so that equal siblings do not reorder
    /// between one computation and the next (the zoom animates by id and they would jump around).
    private static func before(_ a: (size: Int64, id: Int), _ b: (size: Int64, id: Int)) -> Bool {
        a.size != b.size ? a.size > b.size : a.id < b.id
    }

    public static func tiles(
        for snapshot: Snapshot,
        in rect: CGRect,
        gap: CGFloat = 2,
        minTileArea: CGFloat = 36
    ) -> [TreemapTile] {
        let kids = snapshot.children.filter { $0.size > 0 }
            .sorted { before(($0.size, $0.id), ($1.size, $1.id)) }
        let total = kids.reduce(Int64(0)) { $0 + $1.size }
        guard total > 0, rect.width > 0, rect.height > 0 else { return [] }
        let rectArea = Double(rect.width * rect.height)

        // The children are sorted: the tiny ones are the tail.
        var keep = kids.count
        while keep > 0, Double(kids[keep - 1].size) / Double(total) * rectArea < Double(minTileArea) {
            keep -= 1
        }
        let tail = Array(kids[keep...])
        let groupID = -snapshot.parentID - 1

        struct Entry { let size: Int64; let id: Int; let node: FileNode?; let count: Int }
        var entries = kids[..<keep].map { Entry(size: $0.size, id: $0.id, node: $0.node, count: 0) }
        if tail.count == 1 {
            entries.append(Entry(size: tail[0].size, id: tail[0].id, node: tail[0].node, count: 0))
        } else if !tail.isEmpty {
            let count = tail.reduce(0) { $0 + ($1.aggregatedCount > 0 ? $1.aggregatedCount : 1) }
            entries.append(Entry(size: tail.reduce(Int64(0)) { $0 + $1.size }, id: groupID, node: nil, count: count))
        }
        entries.sort { before(($0.size, $0.id), ($1.size, $1.id)) }

        let rects = squarify(values: entries.map { Double($0.size) }, in: rect)
        var tiles: [TreemapTile] = []
        tiles.reserveCapacity(entries.count)
        for (entry, r) in zip(entries, rects) {
            let inset = r.insetBy(dx: gap / 2, dy: gap / 2)
            guard inset.width >= 1, inset.height >= 1 else { continue }
            tiles.append(TreemapTile(id: entry.id, rect: inset, node: entry.node, othersCount: entry.count,
                                     size: entry.size))
        }
        return tiles
    }
}
