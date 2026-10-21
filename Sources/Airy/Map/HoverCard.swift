import SwiftUI
import DiskMapCore

// MARK: - Qué se cuenta de cada tesela

/// Lo que la tarjeta flotante y el menú contextual cuentan de una tesela.
struct TileDetails: Equatable {
    let id: Int
    let title: String
    let path: String?
    let tildePath: String?
    let bytes: Int64
    let percentText: String
    let modified: Date?
    let kind: ContentKind?
    let isFolder: Bool
    let risk: Risk?
    /// Protección (de Airy o del usuario) que la deja en «No tocar».
    let protection: ProtectionMatch?
    /// Por qué tiene esa etiqueta (`RiskExplanation`).
    let why: String?
    /// El análisis no pudo leer todo lo que hay dentro: el tamaño es un mínimo («+»).
    let sizeIsPartial: Bool
    let explanation: String
    let asksAssistant: Bool
    let isOthers: Bool

    @MainActor
    /// `classify`: el clasificador de la app (`AppModel.classify(path:)`), el mismo que usa Limpieza.
    /// `isPartial`: si el análisis dejó algo ilegible dentro de esa ruta (`AppModel.partialIndex`).
    init(tile: MapTile, parent: FileNode?, catalog: Catalog?, classify: (String) -> Classification,
         isPartial: (String) -> Bool = { _ in false }, home: String = NSHomeDirectory()) {
        id = tile.id
        title = tile.name
        bytes = tile.bytes
        isOthers = tile.isOthers
        let share = Double(tile.bytes) / Double(max(parent?.allocatedSize ?? 0, 1))
        let percent = share < 0.001 ? "< 0,1 %"
            : share.formatted(.percent.precision(.fractionLength(share < 0.1 ? 1 : 0)).locale(Theme.locale))
        let parentName = parent.map { $0.parent == nil ? "lo analizado" : $0.name } ?? "la carpeta"
        percentText = "\(percent) de \(parentName)"

        if let node = tile.node, !tile.isOthers {
            let fullPath = node.path
            path = fullPath
            tildePath = Format.tildePath(fullPath, home: home)
            modified = node.lastModified
            kind = node.isDirectory ? node.dominantKind : node.kind
            isFolder = node.isDirectory
            let entry = catalog?.match(path: fullPath, home: home)
            let verdict = classify(fullPath)
            risk = verdict.risk
            protection = verdict.protection
            sizeIsPartial = isPartial(fullPath)
            why = RiskExplanation.why(risk: verdict.risk, entry: entry, protection: verdict.protection, reason: nil,
                                      bytes: tile.bytes,
                                      personal: RiskPolicy.minimumRisk(forPath: fullPath, home: home) == .yourCall)
            if let entry {
                explanation = entry.explanation
                asksAssistant = false
            } else if let known = FolderExplanations.text(for: fullPath, home: home) {
                explanation = known
                asksAssistant = false
            } else {
                explanation = "Pregúntale al asistente"
                asksAssistant = true
            }
        } else {
            path = nil
            tildePath = nil
            modified = nil
            kind = nil
            isFolder = false
            risk = nil
            protection = nil
            why = nil
            sizeIsPartial = false
            explanation = "Archivos y carpetas pequeños agrupados"
            asksAssistant = false
        }
    }
}

// MARK: - Tarjeta

/// Tarjeta de cristal con los datos de la tesela bajo el ratón.
struct HoverCard: View {
    let details: TileDetails

    /// Glifo con contraste AA sobre los dos extremos del degradado del tipo.
    private var glyphInk: Color {
        let base = AiryPalette.kind(details.kind ?? .system)
        return Color(hex: AiryPalette.inkForFill([ColorMath.mix(base, 0xffffff, 0.18), base]))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(details.kind.map(Theme.gradient(for:)) ?? Theme.gradient(for: .system))
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(glyphInk)
                }
                .frame(width: 26, height: 26)
                Text(details.title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if let tildePath = details.tildePath {
                Text(tildePath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Format.bytes(details.bytes, partial: details.sizeIsPartial))
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .monospacedDigit()
                    .help(details.sizeIsPartial ? "Airy no pudo leer todo lo que hay dentro: puede ocupar más." : "")
                Text(details.percentText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if details.kind != nil || details.modified != nil {
                HStack(spacing: 12) {
                    if let kind = details.kind {
                        Label(kind.title, systemImage: Theme.symbol(for: kind))
                            .foregroundStyle(Theme.ink(for: kind))
                    }
                    if let modified = details.modified {
                        Label(Theme.relative(modified), systemImage: "clock")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .labelStyle(TightLabelStyle())
            }

            if let risk = details.risk {
                RiskBadge(risk: risk, reason: details.why)
                // Con protección ya lo dice la línea de abajo.
                if let why = details.why, details.protection == nil {
                    Text(why)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(risk == .safe ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.Airy.riskInk(risk)))
                        .lineLimit(3)
                }
            }
            if details.sizeIsPartial {
                Text("Airy no pudo leer todo lo que hay dentro: puede ocupar más.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let protection = details.protection {
                Label(CleanupBoard.protectionText(protection), systemImage: "lock.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Divider().opacity(0.6)

            HStack(alignment: .top, spacing: 7) {
                Image(systemName: details.asksAssistant ? "sparkles" : "info.circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(details.asksAssistant ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(.secondary))
                Text(details.explanation)
                    .font(.callout)
                    .foregroundStyle(details.asksAssistant ? .secondary : .primary)
                    .lineLimit(4)
            }
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.28), radius: 22, y: 10)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.32), .white.opacity(0.06)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
        }
    }

    private var symbol: String {
        if details.isOthers { return "square.stack.3d.down.right" }
        if details.isFolder { return "folder.fill" }
        return details.kind.map(Theme.symbol(for:)) ?? "doc"
    }
}

private struct TightLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
            configuration.title
        }
    }
}

// MARK: - Seguir al ratón

/// Posición del ratón sobre el lienzo, aparte del resto del estado para que moverlo
/// solo vuelva a dibujar la tarjeta, nunca el mapa.
@MainActor @Observable
final class HoverTracker {
    var location: CGPoint = .zero
    var details: TileDetails?
    /// Con un menú contextual abierto la tarjeta se aparta (los datos siguen para el menú).
    var menuOpen = false
    /// El puntero está sobre el lienzo (aunque ahora mismo no haya tarjeta, p. ej. durante un zoom).
    @ObservationIgnored var pointerInside = false
}

/// Capa que coloca la tarjeta junto al puntero, sin salirse del lienzo.
struct HoverCardLayer: View {
    let tracker: HoverTracker
    let canvasSize: CGSize
    @ViewState private var cardSize = CGSize(width: 300, height: 220)

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let details = tracker.details, !tracker.menuOpen {
                HoverCard(details: details)
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { cardSize = $0 }
                    .offset(offset)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(Theme.pressSpring, value: tracker.details == nil || tracker.menuOpen)
        .allowsHitTesting(false)
    }

    private var offset: CGSize {
        let gap: CGFloat = 18
        let p = tracker.location
        var x = p.x + gap
        if x + cardSize.width > canvasSize.width - 4 { x = p.x - gap - cardSize.width }
        var y = p.y + gap
        if y + cardSize.height > canvasSize.height - 4 { y = p.y - gap - cardSize.height }
        x = min(max(x, 4), max(canvasSize.width - cardSize.width - 4, 4))
        y = min(max(y, 4), max(canvasSize.height - cardSize.height - 4, 4))
        return CGSize(width: x, height: y)
    }
}
