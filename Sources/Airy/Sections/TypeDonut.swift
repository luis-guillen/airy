import SwiftUI
import DiskMapCore

/// Anillo de espacio por tipo. Al aparecer y al cambiar los datos cada porción crece desde 0 grados con
/// `Theme.zoomSpring`, escalonada (`Theme.stagger`); sin movimiento transitorio solo hay un fundido.
/// Animaciones de un solo disparo: en reposo no se redibuja nada.
struct TypeDonut: View {
    let slices: [FileTypeSlice]
    let total: Int64
    var chosen: ContentKind?
    @Binding var hovered: ContentKind?
    var onChoose: (ContentKind) -> Void

    @Environment(\.airyTransientMotion) private var motion
    @ViewState private var grown = false
    @ViewState private var visible = false

    private static let lineWidth: CGFloat = 26
    private static let highlightExtra: CGFloat = 8
    /// Separación entre porciones, en fracción de vuelta.
    private static let gap = 0.004

    var body: some View {
        let starts = Self.starts(slices)
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                Circle()
                    .stroke(.primary.opacity(0.07), lineWidth: Self.lineWidth)
                    .padding(Self.lineWidth / 2 + Self.highlightExtra / 2)
                ForEach(Array(slices.enumerated()), id: \.element.kind) { index, slice in
                    let lit = hovered == slice.kind || chosen == slice.kind
                    let dimmed = (hovered ?? chosen) != nil && !lit
                    SliceArc(start: starts[index],
                             sweep: grown ? max(slice.fraction - Self.gap, 0.0005) : 0,
                             extra: lit ? Self.highlightExtra : 0,
                             color: Theme.color(for: slice.kind).opacity(dimmed ? 0.45 : 1),
                             lineWidth: Self.lineWidth, inset: Self.highlightExtra / 2)
                        .animation(motion == .running ? Theme.stagger(index: index) : nil, value: grown)
                        .animation(Theme.pressSpring, value: lit)
                }
                center
            }
            .contentShape(Circle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hovered = kind(at: point, in: size, starts: starts)
                case .ended: hovered = nil
                }
            }
            .onTapGesture { if let hovered { onChoose(hovered) } }
        }
        .aspectRatio(1, contentMode: .fit)
        .opacity(visible ? 1 : 0)
        .onAppear { play() }
        .onChange(of: slices) { _, _ in play() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Espacio por tipo: \(slices.map { "\($0.kind.title), \(Format.bytes($0.bytes))" }.joined(separator: "; "))")
    }

    @ViewBuilder private var center: some View {
        let shown = hovered.flatMap { kind in slices.first { $0.kind == kind } }
        VStack(spacing: 2) {
            if let shown {
                Text(shown.kind.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Theme.ink(for: shown.kind))
                Text(Format.bytes(shown.bytes))
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .monospacedDigit()
                Text(Self.percent(shown.fraction))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Total")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(Format.bytes(total))
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .monospacedDigit()
            }
        }
        .multilineTextAlignment(.center)
        .allowsHitTesting(false)
    }

    /// Crece desde 0 (o, sin movimiento, aparece con un fundido).
    private func play() {
        if motion == .running {
            visible = true
            grown = false
            DispatchQueue.main.async { grown = true }
        } else {
            grown = true
            visible = false
            withAnimation(.easeOut(duration: 0.35)) { visible = true }
        }
    }

    private func kind(at point: CGPoint, in size: CGSize, starts: [Double]) -> ContentKind? {
        let side = min(size.width, size.height)
        let dx = point.x - size.width / 2, dy = point.y - size.height / 2
        let distance = (dx * dx + dy * dy).squareRoot()
        let outer = side / 2
        guard distance <= outer, distance >= outer - Self.lineWidth - Self.highlightExtra * 1.5 else { return nil }
        // 0 arriba, en el sentido de las agujas del reloj.
        var turn = atan2(dy, dx) / (2 * .pi) + 0.25
        if turn < 0 { turn += 1 }
        for (index, slice) in slices.enumerated() where turn >= starts[index] && turn < starts[index] + slice.fraction {
            return slice.kind
        }
        return nil
    }

    static func starts(_ slices: [FileTypeSlice]) -> [Double] {
        var acc = 0.0
        return slices.map { slice in
            defer { acc += slice.fraction }
            return acc
        }
    }

    static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(fraction < 0.1 ? 1 : 0)).locale(Theme.locale))
    }
}

/// Un arco del anillo; anima su barrido y su grosor de resalte interpolando estos valores (sin reloj).
private struct SliceArc: View, Animatable {
    var start: Double
    var sweep: Double
    var extra: CGFloat
    let color: Color
    let lineWidth: CGFloat
    let inset: CGFloat

    nonisolated var animatableData: AnimatablePair<Double, CGFloat> {
        get { AnimatablePair(sweep, extra) }
        set { sweep = newValue.first; extra = newValue.second }
    }

    var body: some View {
        Canvas { context, size in
            guard sweep > 0 else { return }
            let width = lineWidth + extra
            let radius = min(size.width, size.height) / 2 - inset - lineWidth / 2
            var path = Path()
            path.addArc(center: CGPoint(x: size.width / 2, y: size.height / 2), radius: radius,
                        startAngle: .degrees(start * 360 - 90), endAngle: .degrees((start + sweep) * 360 - 90),
                        clockwise: false)
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .butt))
        }
        .allowsHitTesting(false)
    }
}
