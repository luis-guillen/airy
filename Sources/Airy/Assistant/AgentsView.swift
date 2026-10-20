import AppKit
import SwiftUI
import DiskMapCore

/// «Conectar agente»: cómo añadir el servidor MCP `airy-mcp` a Claude Code, Codex, opencode u otros
/// agentes, el interruptor de limpiezas seguras (el mismo ajuste que Ajustes › Agentes) y la actividad
/// que han dejado los agentes en el registro de operaciones.
struct AgentsView: View {
    @Environment(AppModel.self) private var model

    @ViewState private var records: [OperationRecord] = []
    @ViewState private var registration: ClaudeRegistration?
    @ViewState private var isRegistering = false
    @ViewState private var exportError: String?

    private var session: AssistantSession { model.assistant }

    /// `airy-mcp` va junto al ejecutable de la app (`Airy.app/Contents/MacOS/`).
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
                SnippetCard(title: "Codex", detail: "Añádelo a ~/.codex/config.toml.", text: snippets.codexTOML)
                SnippetCard(title: "opencode", detail: "Añádelo a opencode.json.", text: snippets.opencodeJSON)
                SnippetCard(title: "Otros agentes (mcpServers)",
                            detail: "Vale para cualquier cliente MCP que use un bloque mcpServers.",
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

    // MARK: Estado

    private var statusCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                if serverExists {
                    Label("Servidor MCP listo", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .foregroundStyle(Theme.color(for: .safe))
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
                        Text("Instala Airy en Aplicaciones para que esta ruta no cambie.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Label("No se encuentra airy-mcp junto a Airy. Vuelve a empaquetar con scripts/build-app.sh.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.color(for: .yourCall))
                }
            }
        }
    }

    private var togglesCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Permitir que los agentes ejecuten limpiezas seguras", isOn: agentsBinding)
                    .disabled(model.settingsLoad.isUnreadable)
                Text("Solo lo marcado «Borrar sin riesgo». Lo demás siempre te lo proponen aquí.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var agentsBinding: Binding<Bool> {
        Binding(get: { model.settings.agentsEnabled },
                set: { enabled in model.updateSettings { $0.agentsEnabled = enabled } })
    }

    // MARK: Tarjetas

    private var claudeCodeCard: some View {
        SnippetCard(title: "Claude Code", detail: "Pega el comando en una terminal, o añádelo desde aquí.",
                    text: snippets.claudeCode) {
            HStack(spacing: 10) {
                PrimaryButton("Añadir a Claude Code", systemImage: "plus", isBusy: isRegistering) { register() }
                    .fixedSize()
                    .disabled(claudePath == nil || !serverExists || isRegistering)
                if let registration {
                    Text(message(for: registration))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else if claudePath == nil {
                    Text("Claude Code no está localizado.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func message(for result: ClaudeRegistration) -> String {
        switch result {
        case .added: "Añadido a Claude Code"
        case .alreadyPresent: "Ya estaba añadido"
        case .failed(let reason): "No se pudo añadir: \(reason)"
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

    // MARK: Actividad

    private var activityCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Actividad de los agentes").font(.headline)
                    Spacer()
                    Button("Actualizar", systemImage: "arrow.clockwise") { refresh() }
                    Button("Exportar registro…", systemImage: "square.and.arrow.up") { export() }
                }
                if let exportError {
                    Text(exportError).font(.caption).foregroundStyle(Theme.color(for: .doNotTouch))
                }
                if records.isEmpty {
                    Text("Ningún agente ha usado Airy todavía.")
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

    /// Lo hecho o propuesto por agentes, lo más reciente primero, hasta 200.
    static func agentActivity(_ all: [OperationRecord]) -> [OperationRecord] {
        let mine = all.filter { record in
            if case .agent = record.actor { return true }
            return record.proposedBy != nil
        }
        return Array(mine.suffix(200).reversed())
    }

    private func export() {
        exportError = nil
        let panel = NSSavePanel()
        let day = Date.now.formatted(.iso8601.year().month().day())
        panel.nameFieldStringValue = "airy-registro-\(day).json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.operationLog.exportJSON().write(to: url, options: .atomic)
        } catch {
            exportError = "No se pudo exportar el registro: \(error.localizedDescription)"
        }
    }
}

// MARK: - Piezas

private struct CopyButton: View {
    let text: String
    @ViewState private var copied = false

    var body: some View {
        Button(copied ? "Copiado" : "Copiar", systemImage: copied ? "checkmark" : "doc.on.doc") {
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
    let title: String
    let detail: String
    let text: String
    @ViewBuilder var extra: Extra

    init(title: String, detail: String, text: String, @ViewBuilder extra: () -> Extra) {
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
    init(title: String, detail: String, text: String) {
        self.init(title: title, detail: detail, text: text) { EmptyView() }
    }
}

private struct ActivityRow: View {
    let record: OperationRecord

    private var agent: String {
        if case .agent(let client) = record.actor { return client.isEmpty ? "Agente" : client }
        return record.proposedBy ?? "Agente"
    }

    private var action: String {
        let base: String = switch record.action {
        case "clean": "Limpieza"
        case "trash_paths": "A la Papelera"
        case "empty_trash": "Vaciar Papelera"
        case "propose": "Propuesta"
        case "show": "Mostrar en Airy"
        case "rescan": "Reanálisis"
        default: record.action
        }
        return record.dryRun ? base + " (simulada)" : base
    }

    private var outcome: String {
        switch record.outcome {
        case "freed": "Liberado"
        case "moved_to_trash": "Movido a la Papelera"
        case "partial": "Parcial"
        case "blocked": "Bloqueado"
        case "failed": "Falló"
        case "would_trash": "Iría a la Papelera"
        case "would_run": "Se ejecutaría"
        case "pending_user": "Pendiente de ti"
        case "requested": "Solicitado"
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
