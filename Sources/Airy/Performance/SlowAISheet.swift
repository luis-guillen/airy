import SwiftUI
import DiskMapCore

/// «¿Por qué va lento?»: enseña exactamente lo que se envía a Claude (solo números y nombres de apps) y la
/// respuesta en streaming. «Cerrar» cancela el stream.
struct SlowAISheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @ViewState private var context = ""
    @ViewState private var answer = ""
    @ViewState private var error: String?
    @ViewState private var finished = false
    @ViewState private var showsContext = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("¿Por qué va lento?").font(.system(.title2, design: .rounded, weight: .bold))
            DisclosureGroup("Se envía a Claude solo esto:", isExpanded: $showsContext) {
                ScrollView {
                    Text(context).font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 140)
            }
            ScrollView {
                Group {
                    if let error {
                        Text(error).foregroundStyle(Theme.Airy.riskInk(.doNotTouch))
                    } else if answer.isEmpty {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Preguntando a Claude…") }
                    } else {
                        Text(answer).textSelection(.enabled)
                    }
                }
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 160, maxHeight: 320)
            HStack {
                Spacer()
                Button("Cerrar") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
            }
        }
        .padding(24)
        .frame(width: 560)
        // La tarea se cancela al cerrar la hoja: el stream se corta y Claude se detiene.
        .task { await ask() }
    }

    private func ask() async {
        let session = model.performance
        guard let snapshot = session.snapshot, let verdict = session.verdict,
              case .ready(let path) = model.assistant.claude else {
            error = "No hay datos o no se encontró Claude Code."
            return
        }
        context = PerformanceAIContext.build(snapshot, verdict: verdict)
        let ai = AIAssistant(claudePath: path, runner: ProcessRunner(), catalog: model.catalog ?? Catalog(entries: []))
        do {
            for try await chunk in ai.explainSlowness(context: context) { answer += chunk }
            finished = true
        } catch is CancellationError {
        } catch {
            self.error = "No se pudo preguntar a Claude: \(error.localizedDescription)"
        }
    }
}
