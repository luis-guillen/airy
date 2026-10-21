import SwiftUI
import DiskMapCore

/// Brand background: night (or a light sky) with two soft halos and a few breeze strokes crossing
/// from left to right. The render server animates the crossing (`RenderServerLayer`): the app
/// doesn't work per frame, and at 30 fps at most (`CAAnimation.ambientFrameRate`). When paused
/// (window hidden or app inactive) the strokes freeze where they are and then continue without a jump; with
/// "Reduce motion" another, static view is drawn (the strokes still at their `phase`).
struct BreezeBackground: View {
    let intensity: BreezeIntensity

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.airyAmbientMotion) private var motion

    init(intensity: BreezeIntensity = .ambient) {
        self.intensity = intensity
    }

    var body: some View {
        let dark = colorScheme == .dark
        let streaks = WindMotion.breezeStreaks(intensity)
        ZStack {
            Theme.Airy.background
            RadialGradient(colors: [Theme.Airy.accent.opacity(dark ? 0.10 : 0.06), .clear],
                           center: .topTrailing, startRadius: 0, endRadius: 700)
            RadialGradient(colors: [Theme.Airy.logoBottom.opacity(dark ? 0.08 : 0.04), .clear],
                           center: .bottomLeading, startRadius: 0, endRadius: 600)
            if motion != .reduced {
                MovingStreaks(streaks: streaks, sky: AiryPalette.tokens(dark ? .dark : .light).sky,
                              paused: motion != .running)
            } else {
                StillStreaks(streaks: streaks)
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}

/// Shared geometry of a stroke: it enters from the left (x = −length) and leaves on the right.
private extension BreezeStreak {
    func length(in size: CGSize) -> CGFloat { CGFloat(lengthFraction) * size.width }
    /// Full travel of one pass.
    func lap(in size: CGSize) -> CGFloat { size.width + length(in: size) }
    func frame(in size: CGSize, at fraction: Double) -> CGRect {
        let length = length(in: size)
        return CGRect(x: -length + lap(in: size) * CGFloat(fraction),
                      y: CGFloat(yFraction) * size.height - CGFloat(thickness) / 2,
                      width: length, height: CGFloat(thickness))
    }
}

private struct StillStreaks: View {
    let streaks: [BreezeStreak]

    var body: some View {
        GeometryReader { proxy in
            ForEach(Array(streaks.enumerated()), id: \.offset) { _, streak in
                let frame = streak.frame(in: proxy.size, at: streak.phase)
                Capsule()
                    .fill(LinearGradient(colors: [.clear, Theme.Airy.sky.opacity(streak.opacity), .clear],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
            }
        }
    }
}

private struct MovingStreaks: View {
    let streaks: [BreezeStreak]
    let sky: UInt32
    let paused: Bool

    var body: some View {
        RenderServerLayer(key: sky, paused: paused) { container, size in
            let color = Color(hex: sky)
            for streak in streaks {
                let layer = CAGradientLayer()
                layer.frame = streak.frame(in: size, at: 0)
                layer.cornerRadius = CGFloat(streak.thickness) / 2
                layer.startPoint = CGPoint(x: 0, y: 0.5)
                layer.endPoint = CGPoint(x: 1, y: 0.5)
                layer.colors = [NSColor(color.opacity(0)).cgColor,
                                NSColor(color.opacity(streak.opacity)).cgColor,
                                NSColor(color.opacity(0)).cgColor]
                let cross = CABasicAnimation(keyPath: "transform.translation.x")
                cross.fromValue = 0
                cross.toValue = streak.lap(in: size)
                cross.duration = streak.period
                cross.repeatCount = .infinity
                // Offset by `phase` and, since it leaves and enters out of view, the loop isn't noticeable.
                // The phase comes from the layer's clock: when the window is resized it carries on where it was.
                cross.timeOffset = CAAnimation.continuousOffset(in: container, period: streak.period,
                                                                phase: streak.phase)
                cross.preferredFrameRateRange = CAAnimation.ambientFrameRate
                cross.isRemovedOnCompletion = false
                layer.add(cross, forKey: "cross")
                container.addSublayer(layer)
            }
        }
    }
}
