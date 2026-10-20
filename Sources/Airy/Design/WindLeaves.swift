import SwiftUI
import DiskMapCore

/// Hojas de viento:
/// - `.orbit(radius:)`: giran alrededor del centro de la vista (movimiento ambiente). El giro lo
///   anima el servidor de render (`OrbitingLeaves`); en pausa quedan quietas y con «Reducir
///   movimiento» no se dibujan.
/// Las transitorias van en un único `Canvas` con un reloj que se pausa:
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
        let dark = colorScheme == .dark
        let colors: [Color] = dark ? [.white, Theme.Airy.leafSky] : [Theme.Airy.accent, Theme.Airy.sky]
        Group {
            switch mode {
            case .orbit(let radius):
                switch ambientMotion {
                case .running:
                    let tokens = AiryPalette.tokens(dark ? .dark : .light)
                    OrbitingLeaves(radius: radius, count: count,
                                   colors: dark ? [0xffffff, AiryPalette.leafSky] : [tokens.accent, tokens.sky])
                case .paused:
                    // Quietas donde empieza la órbita: sin reloj.
                    Canvas { canvas, size in
                        Self.draw(&canvas, size: size, mode: mode, count: count, date: Self.orbitEpoch, colors: colors)
                    }
                case .reduced:
                    Color.clear
                }
            default:
                TimelineView(.animation(minimumInterval: nil, paused: paused)) { context in
                    Canvas(rendersAsynchronously: true) { canvas, size in
                        #if DEBUG
                        FPSMeter.shared.tick()
                        #endif
                        Self.draw(&canvas, size: size, mode: mode, count: count, date: context.date, colors: colors)
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Instante en que `orbitLeaf` vale lo mismo que la primera pose de `OrbitingLeaves`.
    private static let orbitEpoch = Date(timeIntervalSinceReferenceDate: 0)

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
            let fade = WindMotion.launchLeafFade(elapsed: elapsed)
            leafScale = 1.6
            poses = (0..<count).map { index in
                let pose = WindMotion.launchLeaf(index: index, count: count, progress: progress)
                return LeafPose(x: center.x + pose.x * unit, y: center.y + pose.y * unit, rotation: pose.rotation,
                                scale: pose.scale, opacity: pose.opacity * fade)
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

/// Órbita que interpola el servidor de render (`RenderServerLayer`), como `WindMotion.orbitLeaf`:
/// un disco gira a `orbitAngularSpeed` y cada hoja, tangente a la órbita, respira ±6 % de radio.
/// La app no trabaja por fotograma; quien la usa la retira sin movimiento ambiente.
private struct OrbitingLeaves: View {
    let radius: CGFloat
    let count: Int
    let colors: [UInt32]

    var body: some View {
        RenderServerLayer(key: [AnyHashable(radius), AnyHashable(count), AnyHashable(colors)]) { container, size in
            let n = max(count, 1)
            let disc = CALayer()
            disc.frame = CGRect(origin: .zero, size: size)
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            // Con y hacia abajo, un ángulo positivo gira en sentido horario, como `orbitLeaf`.
            spin.toValue = 2 * Double.pi
            spin.duration = 2 * Double.pi / WindMotion.orbitAngularSpeed
            spin.repeatCount = .infinity
            spin.isRemovedOnCompletion = false
            disc.add(spin, forKey: "spin")

            let leafPath = AiryLogoGeometry.leafPath(length: 11, width: 5)
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            // Media onda de `sin(0.7 t)` por tramo, con ida y vuelta suaves.
            let breathHalf = Double.pi / 0.7
            for index in 0..<n {
                let arm = CALayer()
                arm.frame = disc.bounds
                arm.setAffineTransform(CGAffineTransform(rotationAngle: 2 * .pi * CGFloat(index) / CGFloat(n)))
                let leaf = CAShapeLayer()
                leaf.bounds = .zero
                leaf.position = CGPoint(x: center.x + radius, y: center.y)
                leaf.path = leafPath
                leaf.contentsScale = container.contentsScale
                leaf.fillColor = NSColor(Color(hex: colors[index % colors.count])).cgColor
                leaf.setAffineTransform(CGAffineTransform(rotationAngle: .pi / 2))
                let breath = CABasicAnimation(keyPath: "position.x")
                breath.fromValue = center.x + radius * 0.94
                breath.toValue = center.x + radius * 1.06
                breath.duration = breathHalf
                breath.autoreverses = true
                breath.repeatCount = .infinity
                breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                breath.timeOffset = 2 * breathHalf * WindMotion.noise(index, 3)
                breath.isRemovedOnCompletion = false
                leaf.add(breath, forKey: "breath")
                arm.addSublayer(leaf)
                disc.addSublayer(arm)
            }
            container.addSublayer(disc)
        }
    }
}
