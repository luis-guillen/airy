import AppKit
import SwiftUI
import DiskMapCore

/// Performance swirl: the logo's three arcs and their leaves turning at `speed` revolutions per second,
/// in the `tint` color (blue that warms up with the temperature). The render server turns it
/// (`RenderServerLayer`): the swirl is rasterized once and the app doesn't work per frame. A
/// speed change resumes the spin from the angle it had, without jumps; without ambient
/// motion a static view is drawn (and the animation goes away). With "Reduce motion" the
/// tint change is a 0.3 s fade.
/// Usage: `WindSwirl(speed: WindMotion.swirlRevolutionsPerSecond(cpuLoad: load),
///                 tint: Theme.Airy.swirlTint(ProcessInfo.processInfo.thermalState))`.
struct WindSwirl: View {
    let speed: Double
    let tint: Color

    @Environment(\.airyAmbientMotion) private var motion
    @Environment(\.displayScale) private var displayScale
    /// Current angle and speed; not observable: changing them redraws nothing.
    @ViewState private var spin = SpinState()

    var body: some View {
        Group {
            if motion == .running, speed > 0, speed.isFinite {
                SpinningArt(speed: speed, tint: tint, scale: displayScale, state: spin)
            } else {
                SwirlArt(tint: tint)
                    .id(tint)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: tint)
        .onChange(of: motion) { _, now in if now != .running { spin.stop() } }
        // Speed 0 or non-finite: it stops cleanly (the angle is kept until the next valid one).
        .onChange(of: speed) { _, now in if !(now > 0 && now.isFinite) { spin.stop() } }
        .accessibilityHidden(true)
    }
}

/// Spin state across layer rebuilds (a non-observable class).
@MainActor
final class SpinState {
    private var angle = 0.0
    private var speed = 0.0
    private var time: Double?
    /// Layer spinning now (the rasterized one); a speed change only changes its animation.
    private weak var layer: CALayer?

    /// Angle at instant `now` with the speed it had; leaves `speed` as the current one.
    func angle(at now: Double, newSpeed: Double) -> Double {
        if let time { angle = (angle + 2 * .pi * speed * max(now - time, 0)).truncatingRemainder(dividingBy: 2 * .pi) }
        time = now
        speed = newSpeed
        return angle
    }

    /// When the spin stops, the angle is kept and the speed starts again from zero.
    func stop() {
        if let time { angle = (angle + 2 * .pi * speed * max(CACurrentMediaTime() - time, 0)).truncatingRemainder(dividingBy: 2 * .pi) }
        time = nil
        speed = 0
        layer = nil
    }

    /// Spins `layer` at `speed` from the accumulated angle, without rasterizing again.
    func spin(_ layer: CALayer, speed: Double) {
        self.layer = layer
        let start = angle(at: CACurrentMediaTime(), newSpeed: speed)
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        // With y pointing down, a positive angle turns clockwise, like the arcs.
        spin.fromValue = start
        spin.toValue = start + 2 * Double.pi
        spin.duration = 1 / speed
        // Up to 0.9 revolutions/s under high load: 60 fps at most, not the panel's 120 Hz.
        spin.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        layer.add(spin, forKey: "spin")
    }

    /// New speed for the layer already spinning (if any).
    func respin(speed: Double) {
        guard let layer, speed > 0, speed.isFinite else { return }
        spin(layer, speed: speed)
    }
}

private struct SpinningArt: View {
    let speed: Double
    let tint: Color
    let scale: CGFloat
    let state: SpinState

    var body: some View {
        // The speed isn't part of the key: the raster doesn't depend on it (the load arrives continuously).
        RenderServerLayer(key: [AnyHashable(tint), AnyHashable(scale)]) { container, size in
            let renderer = ImageRenderer(content: SwirlArt(tint: tint).frame(width: size.width, height: size.height))
            renderer.scale = scale
            let layer = CALayer()
            layer.frame = CGRect(origin: .zero, size: size)
            layer.contents = renderer.cgImage
            layer.contentsGravity = .resizeAspect
            state.spin(layer, speed: speed)
            container.addSublayer(layer)
        }
        .onChange(of: speed) { _, now in state.respin(speed: now) }
    }
}

/// The logo's arcs and leaves (full grid) in a single color; it fills all the space it is given.
private struct SwirlArt: View {
    let tint: Color

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let scale = side / CGFloat(AiryLogoGeometry.grid - 2 * AiryLogoGeometry.squircleInset)
            let origin = CGFloat(AiryLogoGeometry.squircleInset)
            let offset = CGPoint(x: (size.width - side) / 2, y: (size.height - side) / 2)
            func map(_ p: CGPoint) -> CGPoint {
                CGPoint(x: (p.x - origin) * scale + offset.x, y: (p.y - origin) * scale + offset.y)
            }
            let center = CGFloat(AiryLogoGeometry.center)
            for arc in AiryLogoGeometry.arcs(.full) {
                var path = Path()
                let steps = max(Int(arc.sweepDegrees / 3), 2)
                for step in 0...steps {
                    let radians = (arc.startDegrees + arc.sweepDegrees * Double(step) / Double(steps)) * .pi / 180
                    let point = map(CGPoint(x: center + CGFloat(arc.radius * cos(radians)),
                                            y: center + CGFloat(arc.radius * sin(radians))))
                    if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                context.stroke(path, with: .color(tint.opacity(arc.opacity)),
                               style: StrokeStyle(lineWidth: arc.lineWidth * scale, lineCap: .round, lineJoin: .round))
            }
            for leaf in AiryLogoGeometry.leaves(.full) {
                let c = map(AiryLogoGeometry.leafCenter(leaf))
                let transform = CGAffineTransform(translationX: c.x, y: c.y)
                    .rotated(by: AiryLogoGeometry.leafRotationDegrees(leaf) * .pi / 180)
                    .scaledBy(x: scale, y: scale)
                context.fill(Path(AiryLogoGeometry.leafPath(length: leaf.length, width: leaf.width)).applying(transform),
                             with: .color(tint))
            }
        }
    }
}
