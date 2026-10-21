import SwiftUI
import DiskMapCore

/// A restrained celebration when space is freed: a ring that fills, the `BytesCounter` counting and
/// soft particles for 1.2 s (all in a single `Canvas`). It follows the motion gatekeeper
/// (`airyTransientMotion`): with "Reduce motion" only fades (ring already full, no particles);
/// with the window hidden or covered, nothing animates and the particles are removed. It closes by itself or on click.
struct FreedCelebration: View {
    let bytes: Int64
    var onDone: () -> Void

    @Environment(\.airyTransientMotion) private var motion
    @Environment(\.colorScheme) private var colorScheme
    @ViewState private var fill: CGFloat = 0
    @ViewState private var shown = false
    @ViewState private var particlesStart: Date?

    static let particleDuration: TimeInterval = 1.2
    static let visibleDuration: TimeInterval = 2.6
    private let ringSize: CGFloat = 168

    var body: some View {
        ZStack {
            Color.black.opacity(shown ? (colorScheme == .dark ? 0.28 : 0.12) : 0)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onDone)

            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .stroke(.primary.opacity(0.08), lineWidth: 14)
                    Circle()
                        .trim(from: 0, to: fill)
                        .stroke(LinearGradient(colors: [Theme.Airy.riskFill(.safe), Theme.Airy.sky],
                                               startPoint: .topLeading, endPoint: .bottomTrailing),
                                style: StrokeStyle(lineWidth: 14, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 2) {
                        Image(systemName: "leaf.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Theme.Airy.riskInk(.safe))
                        BytesCounter(bytes: bytes, font: .system(size: 30, weight: .bold, design: .rounded),
                                     countsUpOnAppear: motion == .running)
                        Text("freed")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: ringSize, height: ringSize)
                // Behind and larger than the ring, without changing its size.
                .background {
                    if let particlesStart {
                        ParticleBurst(start: particlesStart, ringRadius: ringSize / 2)
                            .frame(width: ringSize * 2.4, height: ringSize * 2.4)
                            .allowsHitTesting(false)
                    }
                }

                Text("That space is now free on your disk.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 30)
            // Opaque background and no soft shadows: nothing to blur again every frame.
            .background {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 0.75)
            }
            .scaleEffect(shown || motion != .running ? 1 : 0.92)
            .opacity(shown ? 1 : 0)
            .onTapGesture(perform: onDone)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Freed \(Format.bytes(bytes))")
        .accessibilityAddTraits(.isModal)
        .onAppear(perform: start)
        // If the window stops being visible (or motion is reduced) halfway, the particles go right away.
        .onChange(of: motion) { _, now in if now != .running { particlesStart = nil; fill = 1 } }
    }

    private func start() {
        switch motion {
        case .paused:
            // Nothing to animate with the window hidden: it appears already complete.
            fill = 1
            shown = true
        case .reduced:
            fill = 1
            withAnimation(.easeOut(duration: 0.2)) { shown = true }
        case .running:
            withAnimation(Theme.zoomSpring) { shown = true }
            withAnimation(.spring(response: 1.0, dampingFraction: 0.92).delay(0.1)) { fill = 1 }
            particlesStart = Date()
            // Main queue (not the cooperative *pool*): the end arrives on time even during a scan.
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.particleDuration) { particlesStart = nil }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.visibleDuration) { onDone() }
    }
}

/// A few dozen soft particles that leave the ring and fade out in 1.2 s.
/// A single `Canvas` inside a `TimelineView` that only exists while it lasts.
private struct ParticleBurst: View {
    let start: Date
    let ringRadius: CGFloat
    @Environment(\.airyTransientMotion) private var motion

    private static let count = 42
    private static let colors: [Color] = [
        Theme.Airy.riskFill(.safe), Theme.Airy.sky, Theme.Airy.accent,
        Theme.Airy.leafSky, Theme.Airy.logoTop,
    ]

    var body: some View {
        // It pauses with the gatekeeper; the view also disappears at 1.2 s or if motion stops.
        TimelineView(.animation(minimumInterval: nil, paused: motion != .running)) { context in
            Canvas(rendersAsynchronously: true) { canvas, size in
                let elapsed = context.date.timeIntervalSince(start)
                let progress = min(max(elapsed / FreedCelebration.particleDuration, 0), 1)
                guard progress < 1 else { return }
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let eased = 1 - pow(1 - progress, 3)
                for index in 0..<Self.count {
                    let r = Self.random(index)
                    let angle = Double(index) / Double(Self.count) * 2 * .pi + (r.0 - 0.5) * 0.35
                    let distance = ringRadius + 8 + CGFloat(eased) * (36 + 70 * r.1)
                    let drift = CGFloat(progress * progress) * 18 // drops a little at the end
                    let point = CGPoint(x: center.x + cos(angle) * distance,
                                        y: center.y + sin(angle) * distance + drift)
                    let radius = (2 + 2.6 * r.2) * (1 - 0.4 * progress)
                    let alpha = (1 - progress) * (0.55 + 0.4 * r.0)
                    let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
                    canvas.fill(Path(ellipseIn: rect),
                                with: .color(Self.colors[index % Self.colors.count].opacity(alpha)))
                }
            }
        }
    }

    /// Three deterministic numbers in [0, 1) per particle (no state or generator).
    private static func random(_ index: Int) -> (Double, Double, Double) {
        func hash(_ x: UInt64) -> Double {
            var z = x &+ 0x9E37_79B9_7F4A_7C15
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return Double(z % 10_000) / 10_000
        }
        let base = UInt64(index) &* 3
        return (hash(base), hash(base + 1), hash(base + 2))
    }
}
