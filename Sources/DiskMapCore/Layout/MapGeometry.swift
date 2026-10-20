import CoreGraphics
import Foundation

// Geometría pura del mapa animado: la curva de muelle, la interpolación de rectángulos,
// el índice para saber qué tesela hay bajo el ratón y el orden de la entrada escalonada.
// Todo sin SwiftUI para poder probarlo y usarlo desde cualquier hilo.

/// Oscilador armónico amortiguado que parte del reposo en 0 y va hacia 1: la misma curva que
/// `Animation.spring(response:dampingFraction:)` de SwiftUI (ω₀ = 2π / response, ζ = dampingFraction),
/// para que lo que el `Canvas` interpola a mano se mueva igual que el resto de la interfaz.
public struct SpringCurve: Sendable, Equatable {
    public let response: Double
    public let dampingFraction: Double

    public init(response: Double, dampingFraction: Double) {
        self.response = max(response, 0.001)
        self.dampingFraction = max(dampingFraction, 0)
    }

    private var omega: Double { 2 * .pi / response }

    /// Progreso en el instante `t` (segundos desde el inicio). Antes de empezar, 0.
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

    /// Tiempo a partir del cual el muelle queda a menos de 0,1 % del destino: lo que dura de verdad.
    public var settlingDuration: Double {
        let epsilon = 0.001
        let w0 = omega, zeta = dampingFraction
        if zeta < 1 {
            let wd = w0 * (1 - zeta * zeta).squareRoot()
            let amplitude = (1 + pow(zeta * w0 / wd, 2)).squareRoot()
            return log(amplitude / epsilon) / (zeta * w0)
        }
        // Sin oscilación la curva es monótona: basta con buscar el primer instante cerca de 1.
        var t = 0.0
        while t < 30, 1 - value(at: t) > epsilon { t += 0.005 }
        return t
    }
}

public enum RectMath {
    /// Interpolación lineal (admite `t` fuera de 0…1 para el rebote del muelle).
    public static func lerp(_ a: CGRect, _ b: CGRect, _ t: Double) -> CGRect {
        let t = CGFloat(t)
        return CGRect(x: a.minX + (b.minX - a.minX) * t,
                      y: a.minY + (b.minY - a.minY) * t,
                      width: a.width + (b.width - a.width) * t,
                      height: a.height + (b.height - a.height) * t)
    }

    /// Lleva `rect` con la transformación afín que convierte `source` en `destination`
    /// (escala y traslación por eje). Con un origen degenerado devuelve `rect` sin tocar.
    public static func map(_ rect: CGRect, from source: CGRect, to destination: CGRect) -> CGRect {
        guard source.width > 0, source.height > 0 else { return rect }
        let sx = destination.width / source.width, sy = destination.height / source.height
        return CGRect(x: destination.minX + (rect.minX - source.minX) * sx,
                      y: destination.minY + (rect.minY - source.minY) * sy,
                      width: rect.width * sx,
                      height: rect.height * sy)
    }

    /// Escala respecto a su propio centro.
    public static func scaled(_ rect: CGRect, by factor: Double) -> CGRect {
        let f = CGFloat(factor)
        let w = rect.width * f, h = rect.height * f
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }
}

/// Rejilla de celdas sobre las teselas para encontrar en O(1) la que hay bajo el ratón,
/// sin una vista por tesela. Cada celda guarda los índices de las teselas que la tocan.
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

    /// Índice de la tesela que contiene `point`, o `nil` (hueco entre teselas o fuera).
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
    /// Puesto de aparición de cada rect (0 = el primero): del centro del lienzo hacia fuera.
    /// A igual distancia decide el índice, para que la cascada sea siempre la misma.
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
