import CoreGraphics
import Foundation

// Pure geometry of the animated map: the spring curve, rectangle interpolation,
// the index to find which tile is under the mouse and the order of the staggered entrance.
// All without SwiftUI so it can be tested and used from any thread.

/// Damped harmonic oscillator that starts at rest at 0 and goes towards 1: the same curve as
/// SwiftUI's `Animation.spring(response:dampingFraction:)` (ω₀ = 2π / response, ζ = dampingFraction),
/// so that what the `Canvas` interpolates by hand moves just like the rest of the interface.
public struct SpringCurve: Sendable, Equatable {
    public let response: Double
    public let dampingFraction: Double

    public init(response: Double, dampingFraction: Double) {
        self.response = max(response, 0.001)
        self.dampingFraction = max(dampingFraction, 0)
    }

    private var omega: Double { 2 * .pi / response }

    /// Progress at instant `t` (seconds since the start). Before starting, 0.
    public func value(at t: Double) -> Double {
        guard t > 0 else { return 0 }
        let w0 = omega, zeta = dampingFraction
        if zeta < 1 {
            let wd = w0 * (1 - zeta * zeta).squareRoot()
            let decay = exp(-zeta * w0 * t)
            return 1 - decay * (cos(wd * t) + (zeta * w0 / wd) * sin(wd * t))
        } else if zeta == 1 {
            return 1 - exp(-w0 * t) * (1 + w0 * t)
        } else {
            let root = (zeta * zeta - 1).squareRoot()
            let r1 = -w0 * (zeta - root), r2 = -w0 * (zeta + root)
            // x(0) = 0, x'(0) = 0
            let c1 = r2 / (r2 - r1), c2 = -r1 / (r2 - r1)
            return 1 - (c1 * exp(r1 * t) + c2 * exp(r2 * t))
        }
    }

    /// Time after which the spring stays within 0.1% of the target: how long it really lasts.
    public var settlingDuration: Double {
        let epsilon = 0.001
        let w0 = omega, zeta = dampingFraction
        if zeta < 1 {
            let wd = w0 * (1 - zeta * zeta).squareRoot()
            let amplitude = (1 + pow(zeta * w0 / wd, 2)).squareRoot()
            return log(amplitude / epsilon) / (zeta * w0)
        }
        // Without oscillation the curve is monotonic: it is enough to find the first instant near 1.
        var t = 0.0
        while t < 30, 1 - value(at: t) > epsilon { t += 0.005 }
        return t
    }
}

public enum RectMath {
    /// Linear interpolation (accepts `t` outside 0…1 for the spring's overshoot).
    public static func lerp(_ a: CGRect, _ b: CGRect, _ t: Double) -> CGRect {
        let t = CGFloat(t)
        return CGRect(x: a.minX + (b.minX - a.minX) * t,
                      y: a.minY + (b.minY - a.minY) * t,
                      width: a.width + (b.width - a.width) * t,
                      height: a.height + (b.height - a.height) * t)
    }

    /// Moves `rect` with the affine transform that turns `source` into `destination`
    /// (scale and translation per axis). With a degenerate source it returns `rect` untouched.
    public static func map(_ rect: CGRect, from source: CGRect, to destination: CGRect) -> CGRect {
        guard source.width > 0, source.height > 0 else { return rect }
        let sx = destination.width / source.width, sy = destination.height / source.height
        return CGRect(x: destination.minX + (rect.minX - source.minX) * sx,
                      y: destination.minY + (rect.minY - source.minY) * sy,
                      width: rect.width * sx,
                      height: rect.height * sy)
    }

    /// Scales around its own centre.
    public static func scaled(_ rect: CGRect, by factor: Double) -> CGRect {
        let f = CGFloat(factor)
        let w = rect.width * f, h = rect.height * f
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }
}

/// Grid of cells over the tiles to find, in O(1), the one under the mouse,
/// without one view per tile. Each cell keeps the indices of the tiles that touch it.
public struct TileHitIndex: Sendable {
    private let rects: [CGRect]
    private let bounds: CGRect
    private let cellSize: CGFloat
    private let columns: Int
    private let rows: Int
    private let cells: [[Int32]]

    public init(rects: [CGRect], bounds: CGRect, cellSize: CGFloat = 32) {
        self.rects = rects
        self.bounds = bounds
        self.cellSize = max(cellSize, 1)
        let columns = bounds.width > 0 ? Int((bounds.width / self.cellSize).rounded(.up)) : 0
        let rows = bounds.height > 0 ? Int((bounds.height / self.cellSize).rounded(.up)) : 0
        self.columns = columns
        self.rows = rows
        var cells = Array(repeating: [Int32](), count: columns * rows)
        if columns > 0, rows > 0 {
            for (index, rect) in rects.enumerated() {
                let r = rect.intersection(bounds)
                guard !r.isNull, r.width > 0, r.height > 0 else { continue }
                let c0 = max(Int((r.minX - bounds.minX) / self.cellSize), 0)
                let c1 = min(Int((r.maxX - bounds.minX) / self.cellSize), columns - 1)
                let r0 = max(Int((r.minY - bounds.minY) / self.cellSize), 0)
                let r1 = min(Int((r.maxY - bounds.minY) / self.cellSize), rows - 1)
                for row in r0...r1 {
                    for column in c0...c1 { cells[row * columns + column].append(Int32(index)) }
                }
            }
        }
        self.cells = cells
    }

    /// Index of the tile that contains `point`, or `nil` (gap between tiles or outside).
    public func hit(_ point: CGPoint) -> Int? {
        guard columns > 0, rows > 0, bounds.contains(point) else { return nil }
        let column = min(Int((point.x - bounds.minX) / cellSize), columns - 1)
        let row = min(Int((point.y - bounds.minY) / cellSize), rows - 1)
        for index in cells[row * columns + column] where rects[Int(index)].contains(point) {
            return Int(index)
        }
        return nil
    }
}

public enum EntranceOrder {
    /// Appearance rank of each rect (0 = the first): from the centre of the canvas outwards.
    /// At equal distance the index decides, so that the cascade is always the same.
    public static func ranks(for rects: [CGRect], in bounds: CGRect) -> [Int] {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let order = rects.indices.sorted { a, b in
            let da = hypot(rects[a].midX - center.x, rects[a].midY - center.y)
            let db = hypot(rects[b].midX - center.x, rects[b].midY - center.y)
            return da != db ? da < db : a < b
        }
        var ranks = Array(repeating: 0, count: rects.count)
        for (rank, index) in order.enumerated() { ranks[index] = rank }
        return ranks
    }
}
