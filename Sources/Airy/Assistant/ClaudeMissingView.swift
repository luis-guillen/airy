import AppKit
import SwiftUI
import DiskMapCore

/// Sin Claude Code: una frase, "Elegir ejecutable…" (se guarda en `UserDefaults` como `claudePath`)
/// y "Reintentar". El resto de la app funciona igual.
struct ClaudeMissingView: View {
    @Environment(AppModel.self) private var model
    /// Ruta elegida por el usuario que no responde como Claude Code.
    let chosen: String?

    @ViewState private var appeared = false

    private var session: AssistantSession { model.assistant }

    var body: some View {
        VStack {
            GlassCard(padding: 28) {
                VStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(Theme.color(for: .yourCall).opacity(0.14))
                        Image(systemName: "terminal")
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(Theme.Airy.riskInk(.yourCall))
                            .symbolEffect(.bounce, value: appeared)
                    }
                    .frame(width: 64, height: 64)

                    VStack(spacing: 6) {
                        Text("Falta Claude Code")
                            .font(.title3.weight(.semibold))
                        Text(sentence)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    HStack(spacing: 10) {
                        PrimaryButton("Elegir ejecutable…", systemImage: "folder") { choose() }
                            .fixedSize()
                        PrimaryButton("Reintentar", systemImage: "arrow.clockwise", style: .secondary) {
                            session.locate()
                        }
                        .fixedSize()
                    }
                    .padding(.top, 4)

                    if chosen != nil {
                        Button("Buscar automáticamente") { session.forgetChosenPath() }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: 520)
            Spacer(minLength: 0)
        }
        .padding(.top, 40)
        .frame(maxWidth: .infinity)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 8)
        .onAppear { withAnimation(Theme.zoomSpring) { appeared = true } }
    }

    private var sentence: String {
        if let chosen {
            return "El ejecutable elegido (\(Format.tildePath(chosen))) no responde como Claude Code; elige otro o deja que Airy lo busque."
        }
        return "El asistente usa Claude Code instalado en este Mac y no lo encuentro; si lo tienes en otro sitio, elígelo."
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.title = "Elegir Claude Code"
        panel.message = "Elige el ejecutable «claude» (por ejemplo, ~/.local/bin/claude)."
        panel.prompt = "Usar este"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/bin")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        session.choose(path: url.path)
    }
}
