import CoreGraphics
import Foundation

public struct TreemapTile: Sendable, Identifiable {
    public let id: Int
    public let rect: CGRect
    /// `nil` ⇒ tesela "Otros (N elementos)".
    public let node: FileNode?
    public let othersCount: Int

    public init(id: Int, rect: CGRect, node: FileNode?, othersCount: Int = 0) {
        self.id = id
        self.rect = rect
        self.node = node
        self.othersCount = othersCount
    }
}

public enum Treemap {
    /// Treemap "squarified" (Bruls, Huizing, van Wijk). Los valores deberían llegar
    /// ordenados de mayor a menor; devuelve un rect por valor, en el mismo orden.
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
                let maxA = max(areas[start], a)   // ordenado: el primero es el mayor
                let minA = min(areas[start..<end].min() ?? a, a)
                let w = worst(sum: newSum, maxA: maxA, minA: minA, side: side)
                if w > best { break }
                best = w; rowSum = newSum; end += 1
            }
            // Coloca la fila a lo largo del lado corto.
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

    public static func tiles(
        for node: FileNode,
        in rect: CGRect,
        gap: CGFloat = 2,
        minTileArea: CGFloat = 36
    ) -> [TreemapTile] {
        let kids = node.children.filter { $0.allocatedSize > 0 }
            .sorted { $0.allocatedSize > $1.allocatedSize }
        let total = kids.reduce(Int64(0)) { $0 + $1.allocatedSize }
        guard total > 0, rect.width > 0, rect.height > 0 else { return [] }
        let rectArea = Double(rect.width * rect.height)

        // Los hijos están ordenados: los diminutos son la cola.
        var keep = kids.count
        while keep > 0, Double(kids[keep - 1].allocatedSize) / Double(total) * rectArea < Double(minTileArea) {
            keep -= 1
        }
        let tail = Array(kids[keep...])

        struct Entry { let size: Int64; let node: FileNode?; let count: Int }
        var entries = kids[..<keep].map { Entry(size: $0.allocatedSize, node: $0, count: 0) }
        if tail.count == 1 {
            entries.append(Entry(size: tail[0].allocatedSize, node: tail[0], count: 0))
        } else if !tail.isEmpty {
            let count = tail.reduce(0) { $0 + ($1.aggregatedCount > 0 ? $1.aggregatedCount : 1) }
            entries.append(Entry(size: tail.reduce(Int64(0)) { $0 + $1.allocatedSize }, node: nil, count: count))
        }
        entries.sort { $0.size > $1.size }

        let rects = squarify(values: entries.map { Double($0.size) }, in: rect)
        var tiles: [TreemapTile] = []
        for (entry, r) in zip(entries, rects) {
            let inset = r.insetBy(dx: gap / 2, dy: gap / 2)
            guard inset.width >= 1, inset.height >= 1 else { continue }
            tiles.append(TreemapTile(
                id: entry.node?.id ?? (-node.id - 1),
                rect: inset, node: entry.node, othersCount: entry.count))
        }
        return tiles
    }
}
