import AppKit
import SwiftUI
import DiskMapCore

/// Ráfaga de una tanda de borrado: una banda ancha (≈ 40 % del ancho) de cielo translúcido con unas
/// pocas hojas cruza la vista de izquierda a derecha en `WindMotion.gustBandDuration`, contando
/// desde `start`. La anima el servidor de render con una sola animación de ida (nada por fotograma
/// en la app) y no queda nada pasado su final. Sin movimiento transitorio no se dibuja. Quien la
/// muestra la retira al acabar la ráfaga; no recibe clics.
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

    /// Una banda con hojas que viaja de fuera por la izquierda a fuera por la derecha. Si la capa se
    /// rehace a mitad (cambio de tamaño), retoma desde donde va la ráfaga.
    private static func build(_ container: CALayer, size: CGSize, start: Date, sky: UInt32, leafColors: [UInt32]) {
        let duration = WindMotion.gustBandDuration
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed < duration, duration > 0 else { return }
        let width = size.width * bandFraction
        let fromX = -width / 2, toX = size.width + width / 2

        let band = CALayer()
        band.bounds = CGRect(x: 0, y: 0, width: width, height: size.height)
        // En reposo (antes y después de la animación) queda fuera de la vista.
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

        // Alineada con `start`, aunque la capa se monte tarde o se rehaga.
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

// MARK: - Balanceo de las filas con la ráfaga

extension View {
    /// La fila `index` se mece a la derecha cuando pasa la ráfaga que empezó en `start`
    /// (`WindMotion.gustRowOffset`: primero la de arriba). Es una animación de un solo disparo que
    /// termina en `gustDuration`; sin índice, sin ráfaga o sin movimiento transitorio no hace nada.
    func gustSway(index: Int?, start: Date?) -> some View {
        modifier(GustSway(index: index, start: start))
    }
}

private struct GustSway: ViewModifier {
    let index: Int?
    let start: Date?

    @Environment(\.airyTransientMotion) private var motion
    @ViewState private var trigger = 0

    /// Muestras por segundo del desplazamiento; entre ellas, curvas suaves.
    private static let samplesPerSecond = 30.0

    func body(content: Content) -> some View {
        let row = max(index ?? 0, 0)
        content
            .keyframeAnimator(initialValue: 0.0, trigger: trigger) { view, dx in
                view.offset(x: dx)
            } keyframes: { _ in
                KeyframeTrack {
                    // `gustRowOffset` no depende del total de filas; la fila acaba en `gustDuration(row + 1)`.
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

// MARK: - Contador de la tanda

/// Píldora que sube con cada fila borrada: hoja, cifra que rueda y «liberados». Si algo fue a la
/// Papelera dice «despejados» y lo explica debajo (no se libera hasta vaciarla).
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
        // Radio de media altura de una línea: cápsula con una línea, esquinas redondas con dos.
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(Theme.Airy.sky.opacity(0.35), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }
}
