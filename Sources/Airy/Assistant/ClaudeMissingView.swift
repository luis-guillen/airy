import AppKit
import SwiftUI
import DiskMapCore

/// Without Claude Code: one sentence, "Choose Executable…" (saved in `UserDefaults` as `claudePath`)
/// and "Try Again". The rest of the app works the same.
struct ClaudeMissingView: View {
    @Environment(AppModel.self) private var model
    /// Path chosen by the user that doesn't respond like Claude Code.
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
                        Text("Claude Code Is Missing")
                            .font(.title3.weight(.semibold))
                        Text(sentence)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    HStack(spacing: 10) {
                        PrimaryButton("Choose Executable…", systemImage: "folder") { choose() }
                            .fixedSize()
                        PrimaryButton("Try Again", systemImage: "arrow.clockwise", style: .secondary) {
                            session.locate()
                        }
                        .fixedSize()
                    }
                    .padding(.top, 4)

                    if chosen != nil {
                        Button("Find Automatically") { session.forgetChosenPath() }
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
            return String(localized: "The chosen executable (\(Format.tildePath(chosen))) doesn’t respond like Claude Code; choose another one or let Airy look for it.")
        }
        return String(localized: "The assistant uses the Claude Code installed on this Mac and I can’t find it; if you have it somewhere else, choose it.")
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose Claude Code")
        panel.message = String(localized: "Choose the “claude” executable (for example, ~/.local/bin/claude).")
        panel.prompt = String(localized: "Use This")
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
