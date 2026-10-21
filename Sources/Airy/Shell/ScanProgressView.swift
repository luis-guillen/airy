import SwiftUI
import DiskMapCore

/// Scan progress: a live ring, file and byte counters and the current path.
/// The counters change every 100 ms, so they are shown with fixed tabular digits; the ring
/// and the percentage are what animate with a spring.
/// `.hero` fills the center when there is nothing to show yet; `.compact` is a pill
/// over the content while an index already shown is rescanned.
struct ScanProgressView: View {
    enum Style { case hero, compact }

    @Environment(AppModel.self) private var model
    var style: Style = .hero

    var body: some View {
        switch style {
        case .hero: hero
        case .compact: compact
        }
    }

    /// Estimated fraction: what was scanned versus the volume's used space (never reaches 100% before finishing).
    private var fraction: Double {
        let used = Double(max(model.currentVolume.totalBytes - model.currentVolume.availableBytes, 1))
        let scanned = Double(model.progress?.bytesScanned ?? 0)
        return min(scanned / used, 0.97)
    }

    private var files: Int { model.progress?.filesScanned ?? 0 }
    private var bytes: Int64 { model.progress?.bytesScanned ?? 0 }
    private var path: String { model.progress?.currentPath ?? model.currentVolume.url.path }

    private var hero: some View {
        VStack(spacing: 26) {
            ScanRing(fraction: fraction, lineWidth: 14) {
                VStack(spacing: 2) {
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: fraction))
                    Text("estimated")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 168, height: 168)
            // Leaves orbiting around the ring; the larger frame doesn't change the layout.
            .background {
                WindLeaves(mode: .orbit(radius: 98), count: 7)
                    .frame(width: 240, height: 240)
            }

            VStack(spacing: 8) {
                Text("Scanning \(model.currentVolume.name)")
                    .font(.system(.title2, design: .rounded, weight: .bold))
                HStack(spacing: 18) {
                    counter(value: Theme.count(files), label: "files")
                    Divider().frame(height: 26)
                    counter(value: Format.bytes(bytes), label: "scanned")
                }
            }

            Text(path)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 460)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { BreezeBackground(intensity: .scan) }
    }

    private var compact: some View {
        HStack(spacing: 12) {
            ScanRing(fraction: fraction, lineWidth: 3.5) { EmptyView() }
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text("Updating Scan")
                        .font(.callout.weight(.semibold))
                    // Arrives every 100 ms: fixed digits (no rolling) so it can be read.
                    Text("· \(Theme.count(files)) files · \(Format.bytes(bytes))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Text(path)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                model.cancelScan()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(.primary.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Stop the scan")
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .frame(width: 540) // fixed width: the path changes every 100 ms and the pill must not jitter
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.14), radius: 12, y: 5)
    }

    private func counter(value: String, label: LocalizedStringKey) -> some View {
        VStack(spacing: 0) {
            Text(value)
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Ring with the estimated progress and a glint that spins nonstop while there is ambient motion.
/// The render server interpolates the spin (`SpinningGlint`): neither the body nor the app works
/// per frame (a SwiftUI `repeatForever` cost ≈ 10–16% CPU at 120 Hz, measured).
/// When paused or with "Reduce motion" there is no glint.
struct ScanRing<Center: View>: View {
    let fraction: Double
    var lineWidth: CGFloat
    @ViewBuilder var center: Center

    @Environment(\.airyAmbientMotion) private var motion

    var body: some View {
        ZStack {
            Circle()
                .stroke(.primary.opacity(0.08), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(fraction, 0.02))
                .stroke(Theme.Airy.logoGradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                // No SwiftUI animation: progress arrives every 100 ms and a chained spring would have the
                // whole window recomputing its layout every frame for the entire scan.
            // Spinning glint: shows activity even when the estimate advances slowly.
            if motion == .running {
                SpinningGlint(lineWidth: lineWidth)
            }
            center
        }
        .padding(lineWidth / 2)
        // A single geometry group: when the ring moves (pill entrance) its layers don't separate.
        .geometryGroup()
    }
}

/// White arc (12% of the turn) that makes one turn every 1.4 s starting at the top.
private struct SpinningGlint: View {
    let lineWidth: CGFloat

    static let period: Double = 1.4

    var body: some View {
        RenderServerLayer(key: lineWidth) { container, size in
            let arc = CAShapeLayer()
            arc.frame = CGRect(origin: .zero, size: size)
            // Like `Circle().stroke`: the stroke is centered on the inscribed circle.
            let radius = min(size.width, size.height) / 2
            let path = CGMutablePath()
            path.addArc(center: CGPoint(x: size.width / 2, y: size.height / 2), radius: radius,
                        startAngle: 0, endAngle: 0.12 * 2 * .pi, clockwise: false)
            arc.path = path
            arc.fillColor = nil
            arc.strokeColor = NSColor.white.withAlphaComponent(0.55).cgColor
            arc.lineWidth = lineWidth * 0.45
            arc.lineCap = .round
            arc.contentsScale = container.contentsScale
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            // With y pointing down, positive is clockwise: from 12 o'clock to 12 o'clock.
            spin.fromValue = -Double.pi / 2
            spin.toValue = 1.5 * Double.pi
            spin.duration = Self.period
            spin.preferredFrameRateRange = CAAnimation.ambientFrameRate
            spin.repeatCount = .infinity
            spin.isRemovedOnCompletion = false
            arc.add(spin, forKey: "spin")
            container.addSublayer(arc)
        }
    }
}
