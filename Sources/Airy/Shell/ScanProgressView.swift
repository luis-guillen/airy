import SwiftUI
import DiskMapCore

/// Progreso del análisis: anillo vivo, contador de archivos y bytes y la ruta actual.
/// Los contadores cambian cada 100 ms, así que se muestran con cifras tabulares fijas; el anillo
/// y el porcentaje son los que se animan con muelle.
/// `.hero` ocupa el centro cuando aún no hay nada que enseñar; `.compact` es una píldora
/// sobre el contenido mientras se reanaliza un índice ya mostrado.
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

    /// Fracción estimada: lo analizado frente a lo ocupado del volumen (nunca llega al 100 % antes de acabar).
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
                    Text("\(Int((fraction * 100).rounded())) %")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: fraction))
                    Text("estimado")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 168, height: 168)
            // Hojas en órbita alrededor del anillo; el cuadro mayor no cambia la maqueta.
            .background {
                WindLeaves(mode: .orbit(radius: 98), count: 7)
                    .frame(width: 240, height: 240)
            }

            VStack(spacing: 8) {
                Text("Analizando \(model.currentVolume.name)")
                    .font(.system(.title2, design: .rounded, weight: .bold))
                HStack(spacing: 18) {
                    counter(value: Theme.count(files), label: "archivos")
                    Divider().frame(height: 26)
                    counter(value: Format.bytes(bytes), label: "analizados")
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
                    Text("Actualizando análisis")
                        .font(.callout.weight(.semibold))
                    // Llega cada 100 ms: cifras fijas (sin rodar) para que se lean.
                    Text("· \(Theme.count(files)) archivos · \(Format.bytes(bytes))")
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
            .help("Detener el análisis")
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .frame(width: 540) // ancho fijo: la ruta cambia cada 100 ms y la píldora no debe bailar
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.14), radius: 12, y: 5)
    }

    private func counter(value: String, label: String) -> some View {
        VStack(spacing: 0) {
            Text(value)
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Anillo con el avance estimado y un destello que gira sin parar mientras hay movimiento ambiente.
/// El giro lo interpola el servidor de render (`SpinningGlint`): ni el cuerpo ni la app trabajan
/// por fotograma (un `repeatForever` de SwiftUI costaba ≈ 10–16 % de CPU a 120 Hz, medido).
/// En pausa o con «Reducir movimiento» no hay destello.
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
                .animation(Theme.counterSpring, value: fraction)
            // Destello giratorio: indica actividad aunque la estimación avance despacio.
            if motion == .running {
                SpinningGlint(lineWidth: lineWidth)
            }
            center
        }
        .padding(lineWidth / 2)
        // Un solo bloque geométrico: al moverse el anillo (entrada de la píldora) sus capas no se separan.
        .geometryGroup()
    }
}

/// Arco blanco (12 % de la vuelta) que da una vuelta cada 1,4 s empezando arriba.
private struct SpinningGlint: View {
    let lineWidth: CGFloat

    static let period: Double = 1.4

    var body: some View {
        RenderServerLayer(key: lineWidth) { container, size in
            let arc = CAShapeLayer()
            arc.frame = CGRect(origin: .zero, size: size)
            // Como `Circle().stroke`: el trazo va centrado en el círculo inscrito.
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
            // Con y hacia abajo, positivo es horario: de las 12 en punto a las 12 en punto.
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
