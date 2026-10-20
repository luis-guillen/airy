import CoreGraphics
import Foundation

public struct TreemapTile: Sendable, Identifiable {
    public let id: Int
    public let rect: CGRect
    /// `nil` ⇒ tesela "Otros (N elementos)".
    public let node: FileNode?
    public let othersCount: Int
    /// Bytes que representa la tesela (los del nodo o la suma del grupo "Otros").
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
                let minA = min(areas[end - 1], a) // …y el último de la fila, el menor
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

    /// Hijos de un nodo copiados en el hilo que es dueño del árbol (el principal), para calcular
    /// el layout en otro hilo sin leer `FileNode` mientras alguien lo modifica (p. ej. tras
    /// enviar algo a la Papelera). Las referencias a los nodos solo viajan, no se leen.
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

    /// Mayor primero; a igual tamaño decide el id, para que hermanos iguales no se reordenen
    /// entre un cálculo y otro (el zoom anima por id y saltarían de sitio).
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

        // Los hijos están ordenados: los diminutos son la cola.
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
