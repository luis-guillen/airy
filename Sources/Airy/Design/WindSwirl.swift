import AppKit
import SwiftUI
import DiskMapCore

/// Remolino de Rendimiento: los tres arcos del logo y sus hojas girando a `speed` vueltas por segundo,
/// en el color `tint` (azul que se calienta con la temperatura). Lo gira el servidor de render
/// (`RenderServerLayer`): el remolino se rasteriza una vez y la app no trabaja por fotograma. Un
/// cambio de velocidad retoma el giro desde el ángulo que llevaba, sin saltos; sin movimiento
/// ambiente se dibuja una vista estática (y la animación desaparece). Con «Reducir movimiento» el
/// cambio de tinte es un fundido de 0,3 s.
/// Uso: `WindSwirl(speed: WindMotion.swirlRevolutionsPerSecond(cpuLoad: carga),
///                 tint: Theme.Airy.swirlTint(ProcessInfo.processInfo.thermalState))`.
struct WindSwirl: View {
    let speed: Double
    let tint: Color

    @Environment(\.airyAmbientMotion) private var motion
    @Environment(\.displayScale) private var displayScale
    /// Ángulo y velocidad vigentes; no observable: cambiarlos no redibuja nada.
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
        .accessibilityHidden(true)
    }
}

/// Estado del giro entre reconstrucciones de la capa (clase no observable).
@MainActor
final class SpinState {
    private var angle = 0.0
    private var speed = 0.0
    private var time: Double?

    /// Ángulo al instante `now` con la velocidad que llevaba; deja `speed` como la vigente.
    func angle(at now: Double, newSpeed: Double) -> Double {
        if let time { angle = (angle + 2 * .pi * speed * max(now - time, 0)).truncatingRemainder(dividingBy: 2 * .pi) }
        time = now
        speed = newSpeed
        return angle
    }

    /// Al pararse el giro, el ángulo se conserva y la velocidad vuelve a empezar de cero.
    func stop() {
        if let time { angle = (angle + 2 * .pi * speed * max(CACurrentMediaTime() - time, 0)).truncatingRemainder(dividingBy: 2 * .pi) }
        time = nil
        speed = 0
    }
}

private struct SpinningArt: View {
    let speed: Double
    let tint: Color
    let scale: CGFloat
    let state: SpinState

    var body: some View {
        RenderServerLayer(key: [AnyHashable(speed), AnyHashable(tint), AnyHashable(scale)]) { container, size in
            let renderer = ImageRenderer(content: SwirlArt(tint: tint).frame(width: size.width, height: size.height))
            renderer.scale = scale
            let layer = CALayer()
            layer.frame = CGRect(origin: .zero, size: size)
            layer.contents = renderer.cgImage
            layer.contentsGravity = .resizeAspect
            let start = state.angle(at: CACurrentMediaTime(), newSpeed: speed)
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            // Con y hacia abajo, un ángulo positivo gira en sentido horario, como los arcos.
            spin.fromValue = start
            spin.toValue = start + 2 * Double.pi
            spin.duration = 1 / speed
            spin.repeatCount = .infinity
            spin.isRemovedOnCompletion = false
            layer.add(spin, forKey: "spin")
            container.addSublayer(layer)
        }
    }
}

/// Arcos y hojas del logo (rejilla completa) en un solo color; ocupa todo el espacio que se le da.
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
