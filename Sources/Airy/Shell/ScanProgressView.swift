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

/// Anillo con el avance estimado y un destello que gira sin parar mientras se analiza.
/// El giro es una animación `repeatForever` que interpola el servidor de render: el cuerpo no se
/// recalcula en cada fotograma (con `TimelineView` el hilo principal se saturaba redibujando).
struct ScanRing<Center: View>: View {
    let fraction: Double
    var lineWidth: CGFloat
    @ViewBuilder var center: Center

    @ViewState private var spinning = false

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
            Circle()
                .trim(from: 0, to: 0.12)
                .stroke(.white.opacity(0.55), style: StrokeStyle(lineWidth: lineWidth * 0.45, lineCap: .round))
                // La animación infinita se limita al giro: si no, también arrastraría la posición del anillo.
                .animation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                    $0.rotationEffect(.degrees(spinning ? 270 : -90))
                }
            center
        }
        .padding(lineWidth / 2)
        // Un solo bloque geométrico: al moverse el anillo (entrada de la píldora) sus capas no se separan.
        .geometryGroup()
        .onAppear { spinning = true }
    }
}
