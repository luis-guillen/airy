import SwiftUI
import DiskMapCore

/// Confirmación pendiente de una acción del informe.
struct ReportConfirmation: Identifiable {
    enum Stage { case warning, final }

    let id = UUID()
    let rec: AIRecommendation
    let offer: AssistantActionOffer
    let title: String
    /// "Depende de ti" empieza por `.warning`: hace falta una segunda confirmación explícita.
    var stage: Stage
}

/// Hoja de confirmación del asistente: qué se hace, cuánto ocupa y con qué método.
/// (La limpieza tiene su propia `ConfirmSheet`; esta cubre las acciones del informe y añade el
/// paso previo de "Depende de ti".)
struct ReportConfirmSheet: View {
    @Environment(AppModel.self) private var model
    @ViewState var confirmation: ReportConfirmation
    var onConfirm: (ReportConfirmation) -> Void
    var onCancel: () -> Void

    init(confirmation: ReportConfirmation, onConfirm: @escaping (ReportConfirmation) -> Void,
         onCancel: @escaping () -> Void) {
        _confirmation = ViewState(initialValue: confirmation)
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            switch confirmation.stage {
            case .warning: warning.transition(.opacity.combined(with: .offset(x: -12)))
            case .final: summary.transition(.opacity.combined(with: .offset(x: 12)))
            }
        }
        .padding(26)
        .frame(width: 460)
        .animation(Theme.sectionSpring, value: confirmation.stage == .final)
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .diskMapAssistantDebug)) { note in
            switch note.userInfo?["action"] as? String {
            case "second": confirmation.stage = .final
            case "cancel": onCancel()
            default: break
            }
        }
        #endif
    }

    // MARK: Primer paso ("Depende de ti")

    private var warning: some View {
        VStack(alignment: .leading, spacing: 18) {
            header(symbol: Theme.symbol(for: .yourCall), tint: Theme.color(for: .yourCall),
                   title: "Esto depende de ti",
                   subtitle: "Claude no lo considera seguro de borrar.")
            Text("«\(confirmation.rec.reason)»")
                .font(.callout)
                .foregroundStyle(.primary.opacity(0.85))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.color(for: .yourCall).opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text("Revisa \(confirmation.title) antes de seguir. Si lo mueves a la Papelera podrás recuperarlo mientras no la vacíes.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancelar", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Sí, quiero moverlo…") { confirmation.stage = .final }
            }
            .controlSize(.large)
        }
    }

    // MARK: Paso final

    private var summary: some View {
        let offer = confirmation.offer
        return VStack(alignment: .leading, spacing: 18) {
            header(symbol: offer.isCommand ? "wand.and.sparkles" : "trash.fill",
                   tint: offer.isCommand ? Theme.userFilesColor : Theme.color(for: .doNotTouch),
                   title: offer.isCommand ? "¿Limpiar «\(confirmation.title)»?" : "¿Mover «\(confirmation.title)» a la Papelera?",
                   subtitle: confirmation.rec.verdict.title)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 9) {
                row("Qué", what)
                row("Cuánto", Format.bytes(confirmation.rec.bytes))
                row("Método", offer.method, monospaced: offer.isCommand)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text(note)
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancelar", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(offer.isCommand ? "Limpiar" : "Mover a la Papelera", role: .destructive) {
                    onConfirm(confirmation)
                }
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
    }

    private var what: String {
        switch confirmation.offer.action {
        case .perform(let item):
            item.paths.isEmpty ? item.title : item.paths.map { Format.tildePath($0) }.joined(separator: "\n")
        case .trashPaths(let paths):
            paths.map { Format.tildePath($0) }.joined(separator: "\n")
        }
    }

    private var note: String {
        if confirmation.offer.isCommand {
            if case .perform(let item) = confirmation.offer.action, item.entry.regenerates {
                return "DiskMap ejecuta el comando oficial de la herramienta. No se puede deshacer, pero la herramienta lo vuelve a crear cuando lo necesite."
            }
            return "DiskMap ejecuta el comando oficial de la herramienta. No se puede deshacer."
        }
        return "Antes de moverlo, DiskMap vuelve a comprobar la ruta y si alguna app lo está usando. El espacio no se libera hasta que vacíes la Papelera."
    }

    private func header(symbol: String, tint: Color, title: String, subtitle: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(tint.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        GridRow {
            Text(label)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .font(monospaced ? .callout.monospaced() : .callout)
                .textSelection(.enabled)
        }
    }
}
