import AppKit
import SwiftUI
import DiskMapCore

/// "Connect Agent": how to add the `airy-mcp` MCP server to Claude Code, Codex, opencode or other
/// agents, the safe cleanups switch (the same setting as Settings › Agents) and the activity
/// agents have left in the operation log.
struct AgentsView: View {
    @Environment(AppModel.self) private var model

    @ViewState private var records: [OperationRecord] = []
    @ViewState private var registration: ClaudeRegistration?
    @ViewState private var isRegistering = false
    @ViewState private var exportError: String?

    private var session: AssistantSession { model.assistant }

    /// `airy-mcp` sits next to the app's executable (`Airy.app/Contents/MacOS/`).
    private var serverPath: String {
        let folder = Bundle.main.executableURL?.deletingLastPathComponent()
            ?? URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        return folder.appendingPathComponent("airy-mcp").path
    }

    private var serverExists: Bool { FileManager.default.isExecutableFile(atPath: serverPath) }

    private var snippets: AgentSnippets { AgentSnippets(serverPath: serverPath) }

    private var claudePath: String? {
        if case .ready(let path) = session.claude { path } else { nil }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                statusCard
                togglesCard
                claudeCodeCard
                SnippetCard(title: "Codex", detail: "Add it to ~/.codex/config.toml.", text: snippets.codexTOML)
                SnippetCard(title: "opencode", detail: "Add it to opencode.json.", text: snippets.opencodeJSON)
                SnippetCard(title: "Other Agents (mcpServers)",
                            detail: "Works with any MCP client that uses an mcpServers block.",
                            text: snippets.genericJSON)
                activityCard
            }
            .padding(.bottom, 8)
        }
        .scrollIndicators(.hidden)
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }

    // MARK: Status

    private var statusCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                if serverExists {
                    Label("MCP Server Ready", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .foregroundStyle(Theme.Airy.riskInk(.safe))
                    HStack(spacing: 10) {
                        Text(serverPath)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        CopyButton(text: serverPath)
                    }
                    if !serverPath.hasPrefix("/Applications/") {
                        Text("Install Airy in Applications so this path doesn’t change.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Label("airy-mcp wasn’t found next to Airy. Package it again with scripts/build-app.sh.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.Airy.riskInk(.yourCall))
                }
            }
        }
    }

    private var togglesCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Allow agents to run safe cleanups", isOn: agentsBinding)
                    .disabled(model.settingsLoad.isUnreadable)
                Text("Only items marked “Safe to remove”. Everything else is always proposed to you here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var agentsBinding: Binding<Bool> {
        Binding(get: { model.settings.agentsEnabled },
                set: { enabled in model.updateSettings { $0.agentsEnabled = enabled } })
    }

    // MARK: Cards

    private var claudeCodeCard: some View {
        SnippetCard(title: "Claude Code", detail: "Paste the command into a terminal, or add it from here.",
                    text: snippets.claudeCode) {
            HStack(spacing: 10) {
                PrimaryButton("Add to Claude Code", systemImage: "plus", isBusy: isRegistering) { register() }
                    .fixedSize()
                    .disabled(claudePath == nil || !serverExists || isRegistering)
                if let registration {
                    Text(message(for: registration))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else if claudePath == nil {
                    Text("Claude Code hasn’t been located.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func message(for result: ClaudeRegistration) -> String {
        switch result {
        case .added: String(localized: "Added to Claude Code")
        case .alreadyPresent: String(localized: "It was already added")
        case .failed(let reason): String(localized: "Couldn’t add it: \(reason)")
        }
    }

    private func register() {
        guard let claude = claudePath, !isRegistering else { return }
        isRegistering = true
        registration = nil
        let snippets = snippets
        Task {
            let result = await ClaudeMCP.add(claude: claude, snippets: snippets, runner: ProcessRunner())
            registration = result
            isRegistering = false
        }
    }

    // MARK: Activity

    private var activityCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Agent Activity").font(.headline)
                    Spacer()
                    Button("Refresh", systemImage: "arrow.clockwise") { refresh() }
                    Button("Export Log…", systemImage: "square.and.arrow.up") { export() }
                }
                if let exportError {
                    Text(exportError).font(.caption).foregroundStyle(Theme.Airy.riskInk(.doNotTouch))
                }
                if records.isEmpty {
                    Text("No agent has used Airy yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                } else {
                    ForEach(Array(records.enumerated()), id: \.offset) { _, record in
                        ActivityRow(record: record)
                        if record != records.last { Divider() }
                    }
                }
            }
        }
    }

    private func refresh() {
        let log = model.operationLog
        Task {
            let loaded = await Task.detached { (try? log.records()) ?? [] }.value
            records = Self.agentActivity(loaded)
        }
    }

    /// What agents did or proposed, most recent first, up to 200.
    static func agentActivity(_ all: [OperationRecord]) -> [OperationRecord] {
        let mine = all.filter(URLProposalPolicy.isAgentActivity)
        return Array(mine.suffix(200).reversed())
    }

    private func export() {
        exportError = nil
        let panel = NSSavePanel()
        let day = Date.now.formatted(.iso8601.year().month().day())
        panel.nameFieldStringValue = String(localized: "airy-log-\(day).json")
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.operationLog.exportJSON().write(to: url, options: .atomic)
        } catch {
            exportError = String(localized: "Couldn’t export the log: \(error.localizedDescription)")
        }
    }
}

// MARK: - Pieces

private struct CopyButton: View {
    let text: String
    @ViewState private var copied = false

    var body: some View {
        Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        }
        .controlSize(.small)
    }
}

private struct SnippetCard<Extra: View>: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let text: String
    @ViewBuilder var extra: Extra

    init(title: LocalizedStringKey, detail: LocalizedStringKey, text: String, @ViewBuilder extra: () -> Extra) {
        self.title = title; self.detail = detail; self.text = text; self.extra = extra()
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    CopyButton(text: text)
                }
                Text(detail).font(.caption).foregroundStyle(.secondary)
                Text(text)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                extra
            }
        }
    }
}

extension SnippetCard where Extra == EmptyView {
    init(title: LocalizedStringKey, detail: LocalizedStringKey, text: String) {
        self.init(title: title, detail: detail, text: text) { EmptyView() }
    }
}

private struct ActivityRow: View {
    let record: OperationRecord

    /// The name an `airy://` link carries isn't verified: it is shown as "claims to be".
    private var agent: String { URLProposalPolicy.activityAuthor(record) }

    private var action: String {
        let base: String = switch record.action {
        case "clean": String(localized: "Cleanup")
        case "trash_paths": String(localized: "To the Trash")
        case "empty_trash": String(localized: "Empty Trash")
        case "propose": String(localized: "Proposal")
        case "show": String(localized: "Show in Airy")
        case "rescan": String(localized: "Rescan")
        default: record.action
        }
        return record.dryRun ? String(localized: "\(base) (simulated)") : base
    }

    private var outcome: String {
        switch record.outcome {
        case "freed": String(localized: "Freed")
        case "moved_to_trash": String(localized: "Moved to the Trash")
        case "partial": String(localized: "Partial")
        case "blocked": String(localized: "Blocked")
        case "failed": String(localized: "Failed")
        case "would_trash": String(localized: "Would go to the Trash")
        case "would_run": String(localized: "Would run")
        case "pending_user": String(localized: "Waiting for you")
        case "requested": String(localized: "Requested")
        default: record.outcome
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.title).font(.callout).lineLimit(1).truncationMode(.middle)
                Text("\(agent) · \(action) · \(Format.relativeDate(record.date))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(outcome).font(.caption.weight(.medium))
                if record.bytes > 0 {
                    Text(Format.bytes(record.bytes)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
