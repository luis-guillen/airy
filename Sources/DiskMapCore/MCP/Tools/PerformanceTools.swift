import Foundation

// Herramientas MCP de Rendimiento. Un agente nunca cierra nada: `propose_quit_app` solo abre Airy con la
// confirmación preparada (`airy://quit`) y el usuario decide. Nada de rutas, PIDs ni argumentos en la salida.

enum PerformanceText {
    static func notOpen(_ app: String) -> String { "No hay ninguna app abierta llamada «\(app)»." }
    static func never(_ name: String, _ reason: String) -> String { "«\(name)» no se puede cerrar desde Airy: \(reason)" }
    static let proposed = "Propuesta enviada a Airy; el usuario decide si la cierra. Airy nunca cierra apps por su cuenta."
}

extension MCPFormat {
    static func riskName(_ risk: Risk) -> String {
        switch risk {
        case .safe: "safe"
        case .yourCall: "yourCall"
        case .doNotTouch: "doNotTouch"
        }
    }
}

// MARK: - propose_quit_app

public struct ProposeQuitAppTool: MCPTool {
    public init() {}
    public var name: String { "propose_quit_app" }
    public var description: String {
        "Propone al usuario cerrar una app abierta: abre Airy con la confirmación preparada. Nunca cierra nada; "
            + "el usuario decide en la app."
    }
    public var inputSchema: JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object([
                "app": .object([
                    "type": .string("string"), "minLength": .number(1),
                    "maxLength": .number(Double(AiryURLCommand.maxItemID)),
                    "description": .string("Bundle id (p. ej. com.spotify.client) o nombre de la app, sin distinguir mayúsculas."),
                ]),
                "reason": .object([
                    "type": .string("string"), "maxLength": .number(Double(AiryURLCommand.maxReason)),
                    "description": .string("Por qué lo propones; el usuario lo verá en la confirmación."),
                ]),
                "dry_run": .object([
                    "type": .string("boolean"),
                    "description": .string("true: devuelve el enlace sin abrir Airy (por defecto false)."),
                ]),
            ]),
            "required": .array([.string("app")]),
            "additionalProperties": .bool(false),
        ])
    }
    public var annotations: MCPToolAnnotations { MCPToolAnnotations(readOnly: false, destructive: false, idempotent: false) }

    public func call(_ arguments: [String: JSONValue], context: MCPCallContext) async -> MCPToolResult {
        let env = context.environment
        let dry = arguments["dry_run"]?.boolValue ?? false
        guard let app = arguments["app"]?.stringValue, !app.isEmpty else { return .error("Falta «app».") }
        let reason = arguments["reason"]?.stringValue ?? ""

        func refuse(_ message: String, group: AppGroup? = nil) -> MCPToolResult {
            log(context, group: group, fallback: app, dryRun: dry, outcome: "blocked", message: message)
            return .error(message)
        }

        if let refusal = AgentGate.refusal(env) { return refuse(refusal) }

        // Una muestra, solo durante la llamada.
        let raw = await env.sampler.sample()
        let groups = AppGrouper.group(raw, cpu: [:], energy: [:], catalog: env.appCatalog)
        let key = app.lowercased()
        guard let group = groups.filter({ $0.bundleID?.lowercased() == key || $0.name.lowercased() == key })
            .max(by: { $0.memory < $1.memory }) else { return refuse(PerformanceText.notOpen(app)) }

        let risk: Risk
        switch QuitPolicy().eligibility(group) {
        case .never(let why): return refuse(PerformanceText.never(group.name, why), group: group)
        case .allowed(let r): risk = r
        }

        let url = AiryURLCommand.proposeQuit(app: group.bundleID ?? group.name, reason: reason,
                                             agent: String(context.client.prefix(AiryURLCommand.maxAgent))).url
        // Ida y vuelta: lo que se abre es exactamente lo que la app aceptará.
        guard let command = AiryURLCommand(url: url), case .proposeQuit = command else {
            return refuse(PerformanceText.notOpen(app), group: group)
        }
        if !dry, await !env.urlOpener.open(url) {
            log(context, group: group, fallback: app, dryRun: dry, outcome: "failed", message: ActionText.noApp)
            return .error(ActionText.noApp)
        }
        log(context, group: group, fallback: app, dryRun: dry, outcome: "pending_user", message: PerformanceText.proposed)
        let value: JSONValue = .object([
            "status": .string("pending_user_confirmation"), "app": .string(group.name),
            "risk": .string(MCPFormat.riskName(risk)), "url": .string(url.absoluteString), "dry_run": .bool(dry),
            "message": .string(PerformanceText.proposed),
        ])
        return .ok(value, summary: dry ? "Sin abrir Airy (dry_run): \(url.absoluteString)" : PerformanceText.proposed)
    }

    private func log(_ context: MCPCallContext, group: AppGroup?, fallback: String, dryRun: Bool, outcome: String,
                     message: String) {
        try? context.environment.log.append(OperationRecord(
            runID: UUID(), date: Date(), actor: .agent(client: context.client), action: "propose_quit",
            itemID: group?.bundleID ?? group?.name ?? fallback, title: group?.name ?? fallback, paths: [],
            command: nil, dryRun: dryRun, outcome: outcome, bytes: group?.memory ?? 0, message: message,
            proposedBy: nil))
    }
}
