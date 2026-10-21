import SwiftUI
import DiskMapCore

/// Airy's vector logo: a gradient squircle, wind arcs and leaves (geometry from
/// `AiryLogoGeometry`, the same that `scripts/make-icon.swift` draws). Replaces the old block logo.
/// With `animated`, the swirl (arcs and their leaves) turns slowly, one turn every 20 s, while
/// there is ambient motion; when paused it freezes at its angle and then continues from there; with
/// "Reduce motion" a static view is drawn.
struct AiryLogo: View {
    let size: CGFloat
    var animated = false

    @Environment(\.displayScale) private var displayScale
    @Environment(\.airyAmbientMotion) private var motion

    init(size: CGFloat, animated: Bool = false) {
        self.size = size
        self.animated = animated
    }

    var body: some View {
        let swirl = LogoSwirl(size: size, variant: AiryLogoGeometry.variant(forPixelSize: Double(size * displayScale)))
        ZStack {
            RoundedRectangle(cornerRadius: size * CGFloat(AiryLogoGeometry.squircleRadius / 824), style: .continuous)
                .fill(Theme.Airy.logoGradient)
                // The shadow goes on the squircle: the spin layer (an `NSView`) sits outside SwiftUI's.
                .shadow(color: .black.opacity(0.2), radius: size * 0.08, y: size * 0.04)
            if animated, motion != .reduced {
                SpinningSwirl(swirl: swirl, scale: displayScale, paused: motion != .running)
            } else {
                swirl
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Endless swirl spin interpolated by the render server (`RenderServerLayer`): the
/// swirl is rasterized once and the app doesn't work per frame.
private struct SpinningSwirl: View {
    let swirl: LogoSwirl
    let scale: CGFloat
    let paused: Bool

    static let period: Double = 20

    var body: some View {
        RenderServerLayer(key: [swirl.size, scale], paused: paused) { container, size in
            let renderer = ImageRenderer(content: swirl)
            renderer.scale = scale
            let layer = CALayer()
            layer.frame = CGRect(origin: .zero, size: size)
            layer.contents = renderer.cgImage
            layer.contentsGravity = .resizeAspect
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            // With y pointing down, a positive angle turns clockwise, like the arcs.
            spin.toValue = 2 * Double.pi
            spin.duration = Self.period
            // Keeps its angle if the layer is rebuilt (screen scale, size).
            spin.timeOffset = CAAnimation.continuousOffset(in: container, period: Self.period)
            // One turn every 20 s: 30 fps is more than enough.
            spin.preferredFrameRateRange = CAAnimation.ambientFrameRate
            spin.repeatCount = .infinity
            spin.isRemovedOnCompletion = false
            layer.add(spin, forKey: "spin")
            container.addSublayer(layer)
        }
    }
}

/// Wind arcs and leaves on the squircle.
private struct LogoSwirl: View {
    let size: CGFloat
    let variant: AiryLogoGeometry.Variant

    var body: some View {
        let scale = size / CGFloat(AiryLogoGeometry.grid - 2 * AiryLogoGeometry.squircleInset)
        let origin = CGFloat(AiryLogoGeometry.squircleInset)
        Canvas { context, _ in
            func map(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - origin) * scale, y: (p.y - origin) * scale) }
            let center = CGFloat(AiryLogoGeometry.center)

            for arc in AiryLogoGeometry.arcs(variant) {
                var path = Path()
                let steps = max(Int(arc.sweepDegrees / 3), 2)
                for step in 0...steps {
                    let degrees = arc.startDegrees + arc.sweepDegrees * Double(step) / Double(steps)
                    let radians = degrees * .pi / 180
                    let point = map(CGPoint(x: center + CGFloat(arc.radius * cos(radians)),
                                            y: center + CGFloat(arc.radius * sin(radians))))
                    if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                context.stroke(path, with: .color(.white.opacity(arc.opacity)),
                               style: StrokeStyle(lineWidth: arc.lineWidth * scale, lineCap: .round, lineJoin: .round))
            }

            for leaf in AiryLogoGeometry.leaves(variant) {
                let transform = CGAffineTransform(translationX: map(AiryLogoGeometry.leafCenter(leaf)).x,
                                                  y: map(AiryLogoGeometry.leafCenter(leaf)).y)
                    .rotated(by: AiryLogoGeometry.leafRotationDegrees(leaf) * .pi / 180)
                    .scaledBy(x: scale, y: scale)
                let path = Path(AiryLogoGeometry.leafPath(length: leaf.length, width: leaf.width)).applying(transform)
                context.fill(path, with: .color(Color(hex: leaf.tint)))
            }
        }
        .frame(width: size, height: size)
    }
}
