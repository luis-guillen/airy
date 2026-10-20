import SwiftUI
import DiskMapCore

/// Una fila de la limpieza: qué es, quién lo crea, si se regenera, cuánto ocupa, su riesgo y,
/// si hace falta, por qué no se puede limpiar ahora.
struct CleanupRow: View {
    @Environment(AppModel.self) private var model
    @Environment(CleanupFlow.self) private var flow

    let item: CleanupItem
    let isSelected: Bool
    var onToggle: () -> Void

    @ViewState private var hovering = false

    private var showsCheckbox: Bool { CleanupBoard.showsCheckbox(item) }
    private var canSelect: Bool { CleanupBoard.canSelect(item) && !flow.isBusy }
    private var isCurrent: Bool { flow.currentID == item.id }
    private var isQueued: Bool { flow.queuedIDs.contains(item.id) }
    private var isInfo: Bool { if case .info = item.entry.cleanup { true } else { false } }
    /// El método sale de la ficha viva del catálogo (la que usará el ejecutor).
    private var liveMethod: CleanupMethod { model.catalog?.entry(id: item.entry.id)?.cleanup ?? item.entry.cleanup }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            leading
                .frame(width: 22, height: 36)

            CleanupIcon(entry: item.entry, dimmed: item.risk == .doNotTouch)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(item.title)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(CleanupBoard.sizeText(item))
                        .font(.system(.title3, design: .rounded, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(item.risk == .doNotTouch ? .secondary : .primary)
                }

                Text(item.entry.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 640, alignment: .leading)

                metadata

                if let location {
                    Text(location)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                notices
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
        .background(.primary.opacity(hovering && canSelect ? 0.035 : 0))
        .contentShape(Rectangle())
        .onTapGesture { if canSelect { onToggle() } }
        .contextMenu {
            // No destructivo: sin confirmación. Lo ya protegido (o sin rutas, como Docker) no lo ofrece.
            if item.protection == nil, !item.paths.isEmpty {
                Button("Proteger esto", systemImage: "lock") { model.protect(paths: item.paths) }
            }
        }
        .onHover { hovering in withAnimation(Theme.pressSpring) { self.hovering = hovering } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(showsCheckbox ? .isButton : [])
        .accessibilityValue(showsCheckbox ? (isSelected ? "Seleccionado" : "No seleccionado") : "")
    }

    // MARK: Partes

    @ViewBuilder private var leading: some View {
        if isCurrent {
            ProgressView().controlSize(.small)
        } else if isQueued {
            Image(systemName: "clock")
                .foregroundStyle(.tertiary)
                .help("En cola")
        } else if showsCheckbox {
            CheckCircle(isOn: isSelected, enabled: canSelect)
                .onTapGesture { if canSelect { onToggle() } }
                .help(canSelect ? (isSelected ? "Quitar de la selección" : "Seleccionar") : CleanupBoard.blockedReasonText(item) ?? "No se puede limpiar ahora")
        } else {
            Image(systemName: isInfo && item.risk != .doNotTouch ? "info.circle" : "lock.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tertiary)
                .help(item.protection.map(CleanupBoard.protectionText) ?? (isInfo ? "Solo informativo" : "No tocar"))
        }
    }

    private var metadata: some View {
        HStack(spacing: 8) {
            MetaChip(symbol: "person.crop.circle", text: "Lo crea: \(item.entry.whoCreatesIt)")
            MetaChip(symbol: item.entry.regenerates ? "arrow.triangle.2.circlepath" : "exclamationmark.arrow.circlepath",
                     text: item.entry.regenerates ? "Se regenera" : "No se regenera")
            MethodChip(method: liveMethod)
            Spacer(minLength: 6)
            RiskBadge(risk: item.risk)
        }
    }

    @ViewBuilder private var notices: some View {
        let blocked = blockedApps
        if !blocked.isEmpty {
            let names = blocked.map(CleanupFlow.appName)
            HStack(spacing: 10) {
                Image(systemName: "lock.app.dashed")
                    .foregroundStyle(Theme.color(for: .yourCall))
                Text(CleanupBoard.blockedMessage(appNames: names) ?? "")
                    .font(.callout.weight(.medium))
                Spacer(minLength: 8)
                ForEach(blocked, id: \.self) { bundleID in
                    let closing = flow.closingApps.contains(bundleID)
                    PrimaryButton(closing ? "Cerrando…" : "Cerrar \(CleanupFlow.appName(bundleID))",
                                  systemImage: "xmark.circle", style: .secondary, isBusy: closing) {
                        flow.closeApp(bundleID, model: model)
                    }
                    .fixedSize()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.color(for: .yourCall).opacity(0.10),
                        in: RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous))
            ForEach(blocked, id: \.self) { bundleID in
                if let refusal = flow.appRefusals[bundleID] {
                    Label(refusal, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.color(for: .yourCall))
                }
            }
        }
        if let protection = item.protection {
            Label(CleanupBoard.protectionText(protection), systemImage: "lock.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        if let reason = CleanupBoard.blockedReasonText(item) {
            Label(reason, systemImage: "hand.raised.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(Theme.color(for: .yourCall))
                .lineLimit(3)
        }
        if let used = CleanupBoard.usedByMessage(item.usedBy) {
            Label(used, systemImage: "link")
                .font(.callout.weight(.medium))
                .foregroundStyle(Theme.color(for: .doNotTouch))
                .lineLimit(2)
                .truncationMode(.middle)
        }
        if isInfo {
            Label("Solo informativo: Airy no lo borra.", systemImage: "eye")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    private var blockedApps: [String] {
        #if DEBUG
        if let fake = flow.debugBlocked[item.id] { return fake }
        #endif
        return item.blockedByOpenApps
    }

    /// Dónde está (mismo texto que la confirmación).
    private var location: String? { CleanupBoard.locationSummary(item) }
}

// MARK: - Piezas

/// Casilla redonda con la marca y un pequeño muelle al marcar.
private struct CheckCircle: View {
    let isOn: Bool
    let enabled: Bool

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(.secondary.opacity(enabled ? 0.6 : 0.25), lineWidth: 1.5)
                .opacity(isOn ? 0 : 1)
            Circle()
                .fill(Theme.brand)
                .opacity(isOn ? 1 : 0)
                .scaleEffect(isOn ? 1 : 0.6)
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(.white)
                .opacity(isOn ? 1 : 0)
                .scaleEffect(isOn ? 1 : 0.4)
        }
        .frame(width: 20, height: 20)
        .opacity(enabled || isOn ? 1 : 0.5)
        .animation(Theme.pressSpring, value: isOn)
        .contentShape(Circle())
    }
}

/// Icono por tipo: un azulejo con el color de la paleta y un SF Symbol del elemento.
struct CleanupIcon: View {
    let entry: CatalogEntry
    var dimmed = false
    var size: CGFloat = 36

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(Theme.gradient(for: entry.kind))
                .saturation(dimmed ? 0.35 : 1)
            Image(systemName: Self.symbol(for: entry))
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundStyle(darkGlyph ? Color.black.opacity(0.72) : .white)
        }
        .frame(width: size, height: size)
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 0.75)
        }
        .shadow(color: Theme.color(for: entry.kind).opacity(dimmed ? 0 : 0.28), radius: 6, y: 3)
    }

    /// Texto oscuro sobre los tonos claros (amarillo, celeste, verde), como en el mapa.
    private var darkGlyph: Bool { [.documents, .aiModels, .caches].contains(entry.kind) }

    static func symbol(for entry: CatalogEntry) -> String {
        let id = entry.id
        if id.hasPrefix("docker-volumes") { return "cylinder.split.1x2" }
        if id.hasPrefix("docker") { return "shippingbox.fill" }
        if id == "homebrew" { return "mug.fill" }
        if ["pip", "uv", "conda"].contains(id) { return "puzzlepiece.extension.fill" }
        if ["npm", "pnpm"].contains(id) { return "cube.fill" }
        if id == "cargo" { return "gearshape.2.fill" }
        if id.hasPrefix("huggingface") || id.hasPrefix("ollama") { return "brain" }
        if id.hasPrefix("whisper") { return "waveform" }
        if id == "playwright" { return "theatermasks.fill" }
        if id.hasSuffix("-cache"), ["brave", "chrome", "safari"].contains(where: id.hasPrefix) { return "globe" }
        if id.hasPrefix("spotify") { return "music.note" }
        if id == "xcode-deriveddata" { return "hammer.fill" }
        if id == "xcode-simulators" { return "iphone" }
        if id == "user-logs" { return "doc.text.magnifyingglass" }
        if id.hasPrefix("codex") { return "terminal.fill" }
        if id == "claude-vm" { return "desktopcomputer" }
        if id == "time-machine-snapshots" { return "clock.arrow.circlepath" }
        return Theme.symbol(for: entry.kind)
    }
}

private struct MetaChip: View {
    let symbol: String
    let text: String

    var body: some View {
        Label {
            Text(text).lineLimit(1)
        } icon: {
            Image(systemName: symbol).imageScale(.small)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.primary.opacity(0.05), in: Capsule())
    }
}

/// "A la Papelera" o "Comando oficial" (la orden completa en la ayuda y en la confirmación).
private struct MethodChip: View {
    let method: CleanupMethod

    var body: some View {
        switch method {
        case .trash:
            MetaChip(symbol: "trash", text: "A la Papelera")
        case .command:
            MetaChip(symbol: "terminal", text: "Comando oficial")
                .help(CleanupBoard.methodDescription(method))
        case .info:
            EmptyView()
        }
    }
}
