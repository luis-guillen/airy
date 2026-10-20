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

// MARK: - get_performance

public struct GetPerformanceTool: MCPTool {
    private let interval: Duration

    public init(interval: Duration = .seconds(1)) {
        self.interval = interval
    }

    public var name: String { "get_performance" }
    public var description: String {
        "Estado del Mac ahora: memoria, presión, swap, temperatura (sin grados), procesador y las apps que más pesan, "
            + "con una frase de diagnóstico. Solo lectura; mide durante 1 s."
    }
    public var inputSchema: JSONValue {
        .object(["type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false)])
    }
    public var annotations: MCPToolAnnotations { MCPToolAnnotations(readOnly: true, destructive: false, idempotent: true) }

    /// Solo lectura: sin `AgentGate`, funciona con la app cerrada y solo mide durante la llamada.
    public func call(_ arguments: [String: JSONValue], context: MCPCallContext) async -> MCPToolResult {
        let env = context.environment
        let catalog = env.appCatalog
        let monitor = PerformanceMonitor(sampler: env.sampler, grouper: { raw, cpu, energy in
            AppGrouper.group(raw, cpu: cpu, energy: energy, catalog: catalog)
        })
        _ = await monitor.refresh()
        try? await Task.sleep(for: interval)
        let snapshot = await monitor.refresh()
        let verdict = await monitor.verdict(probes: DiagnosisProbes(runner: env.runner))
        let policy = QuitPolicy()

        let memory = snapshot.memory
        let topology = snapshot.cpu?.topology ?? snapshot.raw.topology
        let value: JSONValue = .object([
            "health": .object([
                "level": .string(verdict.level.rawValue), "light": .string(Self.light(verdict.level)),
                "sentence": .string(verdict.sentence),
            ]),
            "findings": .array(verdict.findings.map {
                .object(["id": .string($0.id), "sentence": .string($0.sentence)])
            }),
            "memory": .object([
                "total_bytes": MCPFormat.number(memory.total), "used_bytes": MCPFormat.number(memory.used),
                "free_bytes": MCPFormat.number(memory.free), "file_cache_bytes": MCPFormat.number(memory.fileCache),
                "available_bytes": MCPFormat.number(memory.available),
                "pressure": memory.pressure.map { .string($0.rawValue) } ?? .null,
                "swap_used_bytes": MCPFormat.number(memory.swapUsed),
                "swap_total_bytes": MCPFormat.number(memory.swapTotal),
            ]),
            "thermal": .object([
                "state": .string(snapshot.thermal.level.rawValue), "label": .string(snapshot.thermal.level.label),
                "throttling": .bool(snapshot.thermal.throttling),
            ]),
            "cpu": .object([
                "total_percent": Self.optional(snapshot.cpu?.total),
                "performance_percent": Self.optional(snapshot.cpu?.performance),
                "efficiency_percent": Self.optional(snapshot.cpu?.efficiency),
                "performance_cores": topology.map { .number(Double($0.performance)) } ?? .null,
                "efficiency_cores": topology.map { .number(Double($0.efficiency)) } ?? .null,
            ]),
            "top_by_memory": .array(snapshot.groups.sorted { $0.memory > $1.memory }.prefix(5)
                .map { Self.app($0, policy: policy) }),
            "top_by_cpu": .array(snapshot.groups.filter { $0.cpuPercent != nil }
                .sorted { ($0.cpuPercent ?? 0) > ($1.cpuPercent ?? 0) }.prefix(5)
                .map { Self.app($0, policy: policy) }),
            "battery": snapshot.battery.map { b in
                .object([
                    "percent": .number(Double(b.percent)), "charging": .bool(b.isCharging),
                    "cycle_count": b.cycleCount.map { .number(Double($0)) } ?? .null,
                    "health_percent": b.healthPercent.map { .number(Double($0)) } ?? .null,
                ])
            } ?? .null,
            "uptime_seconds": Self.optional(snapshot.uptime),
            "zombie_count": .number(Double(snapshot.zombies.count)),
        ])
        return .ok(value, summary: verdict.sentence)
    }

    static func light(_ level: HealthLevel) -> String {
        switch level {
        case .good: "green"
        case .fair: "amber"
        case .poor: "red"
        }
    }

    private static func optional(_ value: Double?) -> JSONValue {
        guard let value, value.isFinite else { return .null }
        return .number((value * 10).rounded() / 10)
    }

    /// Nombre, bundle id y cifras: nunca rutas, PIDs, argumentos ni `detail` (la carpeta de trabajo).
    private static func app(_ group: AppGroup, policy: QuitPolicy) -> JSONValue {
        let eligibility = policy.eligibility(group)
        let risk: JSONValue
        if case .allowed(let r) = eligibility { risk = .string(MCPFormat.riskName(r)) } else { risk = .null }
        return .object([
            "name": .string(group.name), "bundle_id": group.bundleID.map { .string($0) } ?? .null,
            "memory_bytes": MCPFormat.number(group.memory), "cpu_percent": optional(group.cpuPercent),
            "process_count": .number(Double(group.pids.count)), "closable": .bool(eligibility.isAllowed),
            "risk": risk,
        ])
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
