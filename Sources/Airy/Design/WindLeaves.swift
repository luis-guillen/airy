import SwiftUI
import DiskMapCore

/// Hojas de viento en un único `Canvas` con un reloj que se pausa:
/// - `.orbit(radius:)`: giran alrededor del centro de la vista (movimiento ambiente).
/// - `.launch(start:)`: llegan en espiral y forman el logo centrado en la vista (transitorio).
/// - `.burst(start:rect:)`: un rectángulo de la vista se deshace en hojas (transitorio).
/// Las transitorias no dibujan nada pasado su final; quien las muestra las retira (como `ParticleBurst`).
/// Vista hoja: solo valores de entrada, nada observable.
struct WindLeaves: View {
    enum Mode: Equatable {
        case orbit(radius: CGFloat)
        case launch(start: Date)
        case burst(start: Date, rect: CGRect)
    }

    /// Tamaño del logo que forman las hojas de `.launch`; la unidad normalizada es su mitad.
    static let launchLogoSize: CGFloat = 120

    let mode: Mode
    let count: Int

    @Environment(\.airyAmbientMotion) private var ambientMotion
    @Environment(\.airyTransientMotion) private var transientMotion
    @Environment(\.colorScheme) private var colorScheme

    init(mode: Mode, count: Int = 7) {
        self.mode = mode
        self.count = count
    }

    private var paused: Bool {
        if case .orbit = mode { return ambientMotion != .running }
        return transientMotion != .running
    }

    var body: some View {
        let colors: [Color] = colorScheme == .dark
            ? [.white, Theme.Airy.leafSky]
            : [Theme.Airy.accent, Theme.Airy.sky]
        TimelineView(.animation(minimumInterval: nil, paused: paused)) { context in
            Canvas(rendersAsynchronously: true) { canvas, size in
                #if DEBUG
                FPSMeter.shared.tick()
                #endif
                Self.draw(&canvas, size: size, mode: mode, count: count, date: context.date, colors: colors)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static func draw(_ canvas: inout GraphicsContext, size: CGSize, mode: Mode, count: Int,
                             date: Date, colors: [Color]) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        var leafScale: CGFloat = 1
        let poses: [LeafPose]
        switch mode {
        case .orbit(let radius):
            let time = date.timeIntervalSinceReferenceDate
            poses = (0..<count).map { index in
                let pose = WindMotion.orbitLeaf(index: index, count: count, time: time, radius: Double(radius))
                return LeafPose(x: center.x + pose.x, y: center.y + pose.y, rotation: pose.rotation,
                                scale: pose.scale, opacity: pose.opacity)
            }
        case .launch(let start):
            let timeline = WindMotion.launchTimeline(.running)
            let elapsed = date.timeIntervalSince(start)
            guard elapsed < timeline.gather + timeline.hold + timeline.fade else { return }
            let progress = elapsed / timeline.gather
            let unit = Double(launchLogoSize / 2)
            leafScale = 1.6
            poses = (0..<count).map { index in
                let pose = WindMotion.launchLeaf(index: index, count: count, progress: progress)
                return LeafPose(x: center.x + pose.x * unit, y: center.y + pose.y * unit, rotation: pose.rotation,
                                scale: pose.scale, opacity: pose.opacity)
            }
        case .burst(let start, let rect):
            let progress = date.timeIntervalSince(start) / WindMotion.dissolveDuration
            guard progress < 1 else { return }
            poses = (0..<count).map { WindMotion.dissolveLeaf(index: $0, count: count, progress: progress, in: rect) }
        }

        let leaf = Path(AiryLogoGeometry.leafPath(length: 11, width: 5))
        for (index, pose) in poses.enumerated() where pose.opacity > 0 {
            let scale = leafScale * CGFloat(pose.scale)
            let transform = CGAffineTransform(translationX: pose.x, y: pose.y)
                .rotated(by: pose.rotation)
                .scaledBy(x: scale, y: scale)
            canvas.fill(leaf.applying(transform),
                        with: .color(colors[index % colors.count].opacity(pose.opacity)))
        }
    }
}
