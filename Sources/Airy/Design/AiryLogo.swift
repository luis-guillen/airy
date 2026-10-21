import SwiftUI
import DiskMapCore

/// Logo vectorial de Airy: squircle con degradado, arcos de viento y hojas (geometría de
/// `AiryLogoGeometry`, la misma que dibuja `scripts/make-icon.swift`). Sustituye al antiguo logotipo de bloques.
/// Con `animated`, el remolino (arcos y sus hojas) gira despacio, una vuelta cada 20 s, mientras
/// hay movimiento ambiente; en pausa se congela en su ángulo y luego sigue desde ahí; con
/// «Reducir movimiento» se dibuja una vista estática.
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
                // La sombra va en el squircle: la capa del giro (una `NSView`) queda fuera de la de SwiftUI.
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

/// Giro infinito del remolino que interpola el servidor de render (`RenderServerLayer`): el
/// remolino se rasteriza una vez y la app no trabaja por fotograma.
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
            // Con y hacia abajo, un ángulo positivo gira en sentido horario, como los arcos.
            spin.toValue = 2 * Double.pi
            spin.duration = Self.period
            // Sigue en su ángulo si la capa se reconstruye (escala de pantalla, tamaño).
            spin.timeOffset = CAAnimation.continuousOffset(in: container, period: Self.period)
            // Una vuelta cada 20 s: 30 fps le sobran.
            spin.preferredFrameRateRange = CAAnimation.ambientFrameRate
            spin.repeatCount = .infinity
            spin.isRemovedOnCompletion = false
            layer.add(spin, forKey: "spin")
            container.addSublayer(layer)
        }
    }
}

/// Arcos de viento y hojas sobre el squircle.
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
