import AppKit
import SwiftUI
import DiskMapCore

/// Gust of a deletion batch: a wide band (≈ 40% of the width) of translucent sky with a
/// few leaves crosses the view from left to right in `WindMotion.gustBandDuration`, counting
/// from `start`. The render server animates it with a single one-way animation (nothing per frame
/// in the app) and nothing remains after its end. Without transient motion it isn't drawn. Whoever
/// shows it removes it when the gust ends; it doesn't receive clicks.
struct GustSweep: View {
    let start: Date

    @Environment(\.airyTransientMotion) private var motion
    @Environment(\.colorScheme) private var colorScheme

    static let bandFraction: CGFloat = 0.4
    static let leafCount = 5

    var body: some View {
        Group {
            if motion == .running {
                let dark = colorScheme == .dark
                let tokens = AiryPalette.tokens(dark ? .dark : .light)
                let leafColors: [UInt32] = dark ? [0xffffff, AiryPalette.leafSky] : [tokens.accent, tokens.sky]
                RenderServerLayer(key: [AnyHashable(start), AnyHashable(dark)]) { container, size in
                    Self.build(container, size: size, start: start, sky: tokens.sky, leafColors: leafColors)
                }
            } else {
                Color.clear
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// A band with leaves that travels from off the left edge to off the right edge. If the layer is
    /// rebuilt halfway (size change), it resumes from where the gust is.
    private static func build(_ container: CALayer, size: CGSize, start: Date, sky: UInt32, leafColors: [UInt32]) {
        let duration = WindMotion.gustBandDuration
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed < duration, duration > 0 else { return }
        let width = size.width * bandFraction
        let fromX = -width / 2, toX = size.width + width / 2

        let band = CALayer()
        band.bounds = CGRect(x: 0, y: 0, width: width, height: size.height)
        // At rest (before and after the animation) it stays out of view.
        band.position = CGPoint(x: toX, y: size.height / 2)

        let gradient = CAGradientLayer()
        gradient.frame = band.bounds
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        let skyColor = NSColor(Color(hex: sky))
        gradient.colors = [skyColor.withAlphaComponent(0).cgColor,
                           skyColor.withAlphaComponent(0.18).cgColor,
                           skyColor.withAlphaComponent(0).cgColor]
        band.addSublayer(gradient)

        // Aligned with `start`, even if the layer is mounted late or rebuilt.
        let begin = container.convertTime(CACurrentMediaTime(), from: nil) - max(elapsed, 0)
        let leafPath = AiryLogoGeometry.leafPath(length: 11, width: 5)
        for index in 0..<leafCount {
            let leaf = CAShapeLayer()
            leaf.bounds = .zero
            leaf.path = leafPath
            leaf.contentsScale = container.contentsScale
            leaf.fillColor = NSColor(Color(hex: leafColors[index % leafColors.count])).withAlphaComponent(0.7).cgColor
            let y = size.height * (Double(index) + 0.2 + 0.6 * WindMotion.noise(index, 30)) / Double(leafCount)
            leaf.position = CGPoint(x: width * (0.3 + 0.4 * WindMotion.noise(index, 31)), y: y)
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = (WindMotion.noise(index, 32) < 0.5 ? -1 : 1) * (1.5 + 2 * WindMotion.noise(index, 33))
            spin.duration = duration
            spin.beginTime = begin
            spin.fillMode = .backwards
            leaf.add(spin, forKey: "spin")
            band.addSublayer(leaf)
        }

        let travel = CABasicAnimation(keyPath: "position.x")
        travel.fromValue = fromX
        travel.toValue = toX
        travel.duration = duration
        travel.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        travel.beginTime = begin
        travel.fillMode = .backwards
        band.add(travel, forKey: "travel")
        container.addSublayer(band)
    }
}

// MARK: - Rows swaying with the gust

extension View {
    /// Row `index` sways to the right when the gust that started at `start` passes
    /// (`WindMotion.gustRowOffset`: the top one first). It is a one-shot animation that
    /// ends at `gustDuration`; with no index, no gust or no transient motion it does nothing.
    func gustSway(index: Int?, start: Date?) -> some View {
        modifier(GustSway(index: index, start: start))
    }
}

private struct GustSway: ViewModifier {
    let index: Int?
    let start: Date?

    @Environment(\.airyTransientMotion) private var motion
    @ViewState private var trigger = 0

    /// Offset samples per second; smooth curves between them.
    private static let samplesPerSecond = 30.0

    func body(content: Content) -> some View {
        let row = max(index ?? 0, 0)
        content
            .keyframeAnimator(initialValue: 0.0, trigger: trigger) { view, dx in
                view.offset(x: dx)
            } keyframes: { _ in
                KeyframeTrack {
                    // `gustRowOffset` doesn't depend on the total row count; the row ends at `gustDuration(row + 1)`.
                    let end = WindMotion.gustDuration(rowCount: row + 1)
                    let steps = max(Int((end * Self.samplesPerSecond).rounded(.up)), 1)
                    for step in 1...steps {
                        let time = end * Double(step) / Double(steps)
                        CubicKeyframe(WindMotion.gustRowOffset(row: row, rowCount: row + 1, elapsed: time),
                                      duration: end / Double(steps))
                    }
                }
            }
            .onChange(of: start) { _, now in
                if now != nil, index != nil, motion == .running { trigger += 1 }
            }
    }
}

// MARK: - Batch counter

/// Pill that goes up with each deleted row: a leaf, a rolling figure and "freed". If something went to the
/// Trash it says "cleared" and explains it below (nothing is freed until it is emptied).
struct BatchFreedPill: View {
    let tally: BatchMotion.Tally

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: "leaf.fill")
                    .foregroundStyle(Theme.Airy.accent)
                BytesCounter(bytes: tally.bytes, font: .system(.headline, design: .rounded, weight: .semibold),
                             countsUpOnAppear: false)
                    .foregroundStyle(Theme.Airy.text)
                Text(tally.label)
                    .font(.system(.headline, design: .rounded, weight: .regular))
                    .foregroundStyle(Theme.Airy.textSecondary)
            }
            if let help = tally.help {
                Text(help)
                    .font(.caption)
                    .foregroundStyle(Theme.Airy.textSecondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        // Radius of half a line's height: a capsule with one line, rounded corners with two.
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(Theme.Airy.sky.opacity(0.35), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }
}
