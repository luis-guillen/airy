import CoreGraphics
import Foundation

/// Geometry of the Airy logo ("wind swirl with leaves"), on the icon's 1024 grid.
/// Angles in degrees, 0 = +x, with y pointing down (clockwise on screen).
/// `scripts/make-icon.swift` copies these numbers; the fingerprint test keeps them in sync.
public enum AiryLogoGeometry {
    public enum Variant: Sendable { case full, small }

    public struct Arc: Sendable, Equatable {
        public let radius, lineWidth, startDegrees, sweepDegrees, opacity: Double
    }

    public struct Leaf: Sendable, Equatable {
        public let radius, angleDegrees, length, width: Double
        public let tint: UInt32
    }

    public static let grid = 1024.0
    public static let squircleInset = 100.0
    public static let squircleRadius = 185.0
    public static let center = 512.0
    /// Half of the squircle: 1 normalized unit.
    public static let unit = 412.0

    public static func arcs(_ variant: Variant) -> [Arc] {
        switch variant {
        case .full:
            [Arc(radius: 300, lineWidth: 34, startDegrees: -20, sweepDegrees: 250, opacity: 0.90),
             Arc(radius: 220, lineWidth: 30, startDegrees: 70, sweepDegrees: 250, opacity: 0.70),
             Arc(radius: 140, lineWidth: 26, startDegrees: 160, sweepDegrees: 250, opacity: 0.50)]
        case .small:
            [Arc(radius: 230, lineWidth: 86, startDegrees: -30, sweepDegrees: 270, opacity: 0.95)]
        }
    }

    public static func leaves(_ variant: Variant) -> [Leaf] {
        switch variant {
        case .full:
            [Leaf(radius: 300, angleDegrees: 230, length: 132, width: 62, tint: 0xFFFFFF),
             Leaf(radius: 220, angleDegrees: 320, length: 112, width: 52, tint: AiryPalette.leafSky),
             Leaf(radius: 140, angleDegrees: 50, length: 92, width: 44, tint: 0xFFFFFF)]
        case .small:
            [Leaf(radius: 230, angleDegrees: 240, length: 230, width: 110, tint: 0xFFFFFF)]
        }
    }

    public static func variant(forPixelSize px: Double) -> Variant { px <= 64 ? .small : .full }

    /// Leaf centred on the origin along +x.
    public static func leafPath(length: Double, width: Double) -> CGPath {
        let l = CGFloat(length), w = CGFloat(width)
        let p = CGMutablePath()
        p.move(to: CGPoint(x: -l / 2, y: 0))
        p.addQuadCurve(to: CGPoint(x: l / 2, y: 0), control: CGPoint(x: 0, y: -w))
        p.addQuadCurve(to: CGPoint(x: -l / 2, y: 0), control: CGPoint(x: 0, y: 0.6 * w))
        p.closeSubpath()
        return p
    }

    private static func point(radius: Double, degrees: Double) -> CGPoint {
        let a = degrees * .pi / 180
        return CGPoint(x: center + radius * cos(a), y: center + radius * sin(a))
    }

    /// Centre of the leaf in grid coordinates.
    public static func leafCenter(_ leaf: Leaf) -> CGPoint {
        point(radius: leaf.radius, degrees: leaf.angleDegrees)
    }

    /// Rotation of the leaf: tangent to the arc, clockwise with y pointing down.
    public static func leafRotationDegrees(_ leaf: Leaf) -> Double { leaf.angleDegrees + 90 }

    /// Points in normalized units (centre 0, y pointing down): first the leaf centres
    /// and then points spread evenly along the arcs.
    public static func launchTargets(count: Int) -> [CGPoint] {
        func normalized(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - center) / unit, y: (p.y - center) / unit) }
        var result = leaves(.full).prefix(max(count, 0)).map { normalized(leafCenter($0)) }
        let rest = count - result.count
        guard rest > 0 else { return result }
        let arcs = arcs(.full)
        let lengths = arcs.map { $0.radius * $0.sweepDegrees * .pi / 180 }
        let total = lengths.reduce(0, +)
        for i in 0..<rest {
            var s = (Double(i) + 0.5) / Double(rest) * total
            for (arc, length) in zip(arcs, lengths) {
                if s <= length {
                    result.append(normalized(point(radius: arc.radius,
                                                   degrees: arc.startDegrees + arc.sweepDegrees * s / length)))
                    break
                }
                s -= length
            }
        }
        return result
    }

    /// Stable fingerprint of the geometry; `make-icon.swift` carries it in a comment.
    public static var fingerprint: String {
        func n(_ v: Double) -> String { String(format: "%g", v) }
        let parts = [Variant.full, .small].flatMap { variant -> [String] in
            let tag = variant == .full ? "full" : "small"
            return arcs(variant).map { "\(tag)-arc:\(n($0.radius)),\(n($0.lineWidth)),\(n($0.startDegrees)),\(n($0.sweepDegrees)),\(n($0.opacity))" }
                + leaves(variant).map { "\(tag)-leaf:\(n($0.radius)),\(n($0.angleDegrees)),\(n($0.length)),\(n($0.width)),\(String($0.tint, radix: 16))" }
        }
        return "airy-logo-v1|" + parts.joined(separator: "|")
    }
}
