import SwiftUI
import DiskMapCore

/// "Why Is It Slow?": shows exactly what is sent to Claude (only numbers and app names) and the
/// streamed answer. "Close" cancels the stream.
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
            Text("Why Is It Slow?").font(.system(.title2, design: .rounded, weight: .bold))
            DisclosureGroup("Only this is sent to Claude:", isExpanded: $showsContext) {
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
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Asking Claude…") }
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
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
            }
        }
        .padding(24)
        .frame(width: 560)
        // The task is cancelled when the sheet closes: the stream is cut and Claude stops.
        .task { await ask() }
    }

    private func ask() async {
        let session = model.performance
        guard let snapshot = session.snapshot, let verdict = session.verdict,
              case .ready(let path) = model.assistant.claude else {
            error = String(localized: "There’s no data, or Claude Code wasn’t found.")
            return
        }
        context = PerformanceAIContext.build(snapshot, verdict: verdict)
        let ai = AIAssistant(claudePath: path, runner: ProcessRunner(), catalog: model.catalog ?? Catalog(entries: []))
        do {
            for try await chunk in ai.explainSlowness(context: context) { answer += chunk }
            finished = true
        } catch is CancellationError {
        } catch {
            self.error = String(localized: "Couldn’t ask Claude: \(error.localizedDescription)")
        }
    }
}
