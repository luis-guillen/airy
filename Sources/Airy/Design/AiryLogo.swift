import SwiftUI
import DiskMapCore

/// Logo vectorial de Airy: squircle con degradado, arcos de viento y hojas (geometría de
/// `AiryLogoGeometry`, la misma que dibuja `scripts/make-icon.swift`). Sustituye al antiguo logotipo de bloques.
struct AiryLogo: View {
    let size: CGFloat
    /// Reservado: la animación del logo se enciende en otra tarea.
    var animated = false

    @Environment(\.displayScale) private var displayScale

    init(size: CGFloat, animated: Bool = false) {
        self.size = size
        self.animated = animated
    }

    var body: some View {
        let variant = AiryLogoGeometry.variant(forPixelSize: Double(size * displayScale))
        let scale = size / CGFloat(AiryLogoGeometry.grid - 2 * AiryLogoGeometry.squircleInset)
        let origin = CGFloat(AiryLogoGeometry.squircleInset)

        ZStack {
            RoundedRectangle(cornerRadius: size * CGFloat(AiryLogoGeometry.squircleRadius / 824), style: .continuous)
                .fill(Theme.Airy.logoGradient)
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
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.2), radius: size * 0.08, y: size * 0.04)
        .accessibilityHidden(true)
    }
}
