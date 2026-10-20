import Foundation

// Herramientas MCP de acción. Un agente solo puede ejecutar lo «Sin problema» (verde) que no esté
// bloqueado, siempre a través de `CleanupExecutor`; todo lo demás se propone al usuario en Airy por
// `airy://`. Ninguna herramienta acepta comandos ni rutas para borrar.
//
// Registros: el ejecutor anota cada ejecución o vista previa; estas herramientas solo anotan sus
// propios rechazos y las órdenes que pasan a la app (`propose`, `show`, `rescan`).

/// Puerta común: interruptor de agentes y ajustes legibles, leídos en cada llamada.
public enum AgentGate {
    static let agentsOff =
        "Has desactivado en Airy que los agentes ejecuten acciones (Ajustes › Agentes)."
    static let unreadable = "Airy no puede leer sus ajustes; no se ejecuta nada hasta que los revises en la app."

    /// `nil` si un agente puede actuar ahora; si no, el motivo para el usuario.
    public static func refusal(_ env: AiryEnvironment) -> String? {
        let load = env.settings.load()
        if load.isUnreadable { return unreadable }
        if !load.allowsAgentActions { return agentsOff }
        return nil
    }
}

enum ActionText {
    static func yourCall(_ title: String) -> String {
        "«\(title)» es «Tú decides»: solo se ejecuta lo marcado «Sin problema». Usa propose_cleanup para que el usuario decida en Airy."
    }
    static func doNotTouch(_ title: String) -> String { "«\(title)» es «No borrar»: Airy no lo toca." }
    static let proposed = "Propuesta enviada a Airy; pendiente de confirmación del usuario."
    static let rescan = "Análisis pedido a Airy. Cuando termine, get_disk_summary mostrará la fecha nueva."
    static let noApp = "No se pudo abrir Airy (¿está instalada en /Applications?)."
    static let notFound = "No hay ninguna limpieza con ese id ahora mismo. Usa list_cleanup_items."
    static let noCatalog = "El catálogo no está disponible."
}

extension MCPFormat {
    /// Veredicto que ve el agente para un elemento detectado: el más estricto entre el clasificador vivo y
    /// la detección.
    static func verdict(for item: CleanupItem, classifier: RiskClassifier) -> Classification {
        var verdict = classifier.classify(entry: item.entry, paths: item.paths)
        verdict.risk = .strictest(verdict.risk, item.risk)
        verdict.protection = item.protection ?? verdict.protection
        return verdict
    }

    /// Detección nueva, en el orden de la pantalla Limpieza. `nil` sin catálogo.
    static func detect(_ env: AiryEnvironment) async -> [CleanupItem]? {
        guard let scanner = env.makeScanner() else { return nil }
        let tree = loadIndex(env).scan?.root
        return CleanupBoard(items: await scanner.findItems(scan: tree)).items
    }

    /// Motivo por el que un agente no puede ejecutar este elemento, o `nil`.
    static func agentRefusal(_ item: CleanupItem, classifier: RiskClassifier) -> String? {
        let verdict = verdict(for: item, classifier: classifier)
        if verdict.risk == .doNotTouch || !CleanupBoard.showsCheckbox(item) { return ActionText.doNotTouch(item.title) }
        if verdict.risk != .safe { return ActionText.yourCall(item.title) }
        guard CleanupBoard.canSelect(item) else {
            if let reason = item.blockedReason { return "«\(item.title)» no se puede limpiar ahora: \(reason)" }
            if !item.blockedByOpenApps.isEmpty {
                return "«\(item.title)» no se puede limpiar ahora: cierra primero \(item.blockedByOpenApps.joined(separator: ", "))."
            }
            if !item.usedBy.isEmpty { return "«\(item.title)» lo usa: \(item.usedBy.joined(separator: ", "))." }
            return "«\(item.title)» no se puede limpiar ahora."
        }
        return nil
    }
}

private func actionSchema(_ properties: [String: JSONValue] = [:], required: [String] = []) -> JSONValue {
    var all = properties
    all["dry_run"] = .object([
        "type": .string("boolean"),
        "description": .string("true: solo dice lo que haría, sin hacerlo (por defecto false)."),
    ])
    var schema: [String: JSONValue] = [
        "type": .string("object"), "properties": .object(all), "additionalProperties": .bool(false),
    ]
    if !required.isEmpty { schema["required"] = .array(required.map { .string($0) }) }
    return .object(schema)
}

private let destructiveAction = MCPToolAnnotations(readOnly: false, destructive: true, idempotent: false)
private let appRequest = MCPToolAnnotations(readOnly: false, destructive: false, idempotent: false)

private func dryRun(_ arguments: [String: JSONValue]) -> Bool { arguments["dry_run"]?.boolValue ?? false }

/// Anota un registro propio de la herramienta (rechazo u orden a la app).
private func logOwn(_ context: MCPCallContext, runID: UUID = UUID(), action: String, itemID: String? = nil,
                    title: String, paths: [String] = [], dryRun: Bool, outcome: String, message: String?) {
    try? context.environment.log.append(OperationRecord(
        runID: runID, date: Date(), actor: .agent(client: context.client), action: action, itemID: itemID,
        title: title, paths: paths, command: nil, dryRun: dryRun, outcome: outcome, bytes: 0, message: message,
        proposedBy: nil))
}

/// Rechazo anotado: el mensaje vuelve al agente como error.
private func refuse(_ context: MCPCallContext, action: String, itemID: String? = nil, title: String,
                    paths: [String] = [], dryRun: Bool, _ message: String) -> MCPToolResult {
    logOwn(context, action: action, itemID: itemID, title: title, paths: paths, dryRun: dryRun,
           outcome: "blocked", message: message)
    return .error(message)
}

/// Resultado de un elemento: `outcome`, `bytes`, `message`.
private struct ItemResult {
    var outcome: String, bytes: Int64, message: String

    var isError: Bool { outcome == "blocked" || outcome == "failed" }

    init(_ preview: CleanupPreview) {
        switch preview {
        case .wouldTrash(_, let b): (outcome, bytes, message) = ("would_trash", b, "Se enviaría a la Papelera.")
        case .wouldRun(let command, let b, let upper):
            (outcome, bytes, message) = ("would_run", b, "Se ejecutaría \(command.joined(separator: " "))"
                + (upper ? " (libera como máximo ese tamaño)." : "."))
        case .blocked(let reason): (outcome, bytes, message) = ("blocked", 0, reason)
        }
    }

    init(_ outcome: CleanupOutcome) {
        switch outcome {
        case .freed(let b): (self.outcome, bytes, message) = ("freed", b, "Liberado: \(Format.bytes(b)).")
        case .movedToTrash(let b):
            (self.outcome, bytes, message) = ("moved_to_trash", b,
                                              "Enviado a la Papelera (\(Format.bytes(b))); se libera al vaciarla.")
        case .blocked(let reason): (self.outcome, bytes, message) = ("blocked", 0, reason)
        case .failed(let error): (self.outcome, bytes, message) = ("failed", 0, error)
        }
    }
}

private func runItem(_ item: CleanupItem, executor: CleanupExecutor, context: OperationContext,
                     dryRun: Bool) async -> ItemResult {
    dryRun ? ItemResult(await executor.preview(item, context: context))
        : ItemResult(await executor.execute(item, context: context))
}

/// Abre la orden en Airy (o solo la devuelve con `dry_run`) y anota la petición.
private func sendToApp(_ command: AiryURLCommand, context: MCPCallContext, action: String, itemID: String? = nil,
                       title: String, paths: [String] = [], dryRun: Bool, outcome: String,
                       status: String, message: String) async -> MCPToolResult {
    let url = command.url
    if !dryRun, await !context.environment.urlOpener.open(url) {
        logOwn(context, action: action, itemID: itemID, title: title, paths: paths, dryRun: dryRun,
               outcome: "failed", message: ActionText.noApp)
        return .error(ActionText.noApp)
    }
    logOwn(context, action: action, itemID: itemID, title: title, paths: paths, dryRun: dryRun,
           outcome: outcome, message: message)
    let value: JSONValue = .object([
        "status": .string(status), "url": .string(url.absoluteString), "dry_run": .bool(dryRun),
        "message": .string(message),
    ])
    return .ok(value, summary: dryRun ? "Sin abrir Airy (dry_run): \(url.absoluteString)" : message)
}

/// Nombre del agente tal como cabe en la URL.
private func agentName(_ context: MCPCallContext) -> String { String(context.client.prefix(AiryURLCommand.maxAgent)) }

// MARK: - run_safe_cleanup

public struct RunSafeCleanupTool: MCPTool {
    public init() {}
    public var name: String { "run_safe_cleanup" }
    public var description: String {
        "Ejecuta una limpieza de list_cleanup_items marcada «Sin problema» (actionable_by_agent: true): archivos a la "
            + "Papelera o el comando oficial de la herramienta. Nada «Tú decides» ni «No borrar»: para eso, propose_cleanup. "
            + "dry_run: true solo dice lo que haría."
    }
    public var inputSchema: JSONValue {
        actionSchema(["item_id": .object(["type": .string("string"), "minLength": .number(1),
                                          "maxLength": .number(Double(AiryURLCommand.maxItemID))])],
                     required: ["item_id"])
    }
    public var annotations: MCPToolAnnotations { destructiveAction }

    public func call(_ arguments: [String: JSONValue], context: MCPCallContext) async -> MCPToolResult {
        let env = context.environment
        let dry = dryRun(arguments)
        guard let id = arguments["item_id"]?.stringValue, !id.isEmpty else { return .error("Falta «item_id».") }
        if let refusal = AgentGate.refusal(env) {
            return refuse(context, action: "clean", itemID: id, title: id, dryRun: dry, refusal)
        }
        guard let items = await MCPFormat.detect(env), let classifier = env.classifier(),
              let executor = env.makeExecutor() else {
            return refuse(context, action: "clean", itemID: id, title: id, dryRun: dry, env.catalogError ?? ActionText.noCatalog)
        }
        guard let item = items.first(where: { $0.id == id }) else {
            return refuse(context, action: "clean", itemID: id, title: id, dryRun: dry, ActionText.notFound)
        }
        if let refusal = MCPFormat.agentRefusal(item, classifier: classifier) {
            return refuse(context, action: "clean", itemID: id, title: item.title, paths: item.paths, dryRun: dry, refusal)
        }
        let runID = UUID()
        let result = await runItem(item, executor: executor, context: .agent(context.client, runID: runID), dryRun: dry)
        let value: JSONValue = .object([
            "run_id": .string(runID.uuidString), "item_id": .string(item.id), "title": .string(item.title),
            "dry_run": .bool(dry), "outcome": .string(result.outcome), "bytes": MCPFormat.number(result.bytes),
            "message": .string(result.message),
        ])
        return MCPToolResult(text: "\(item.title): \(result.message)\n" + value.prettyString(), structured: value,
                             isError: result.isError)
    }
}

// MARK: - run_safe_cleanup_all

public struct RunSafeCleanupAllTool: MCPTool {
    public init() {}
    public var name: String { "run_safe_cleanup_all" }
    public var description: String {
        "Ejecuta, una tras otra, todas las limpiezas «Sin problema» listas ahora (lo mismo que «Limpiar todo lo seguro» "
            + "en Airy). Nunca toca lo «Tú decides» ni lo «No borrar». Si el usuario apaga los agentes a mitad, lo que "
            + "queda se bloquea. dry_run: true solo dice lo que haría."
    }
    public var inputSchema: JSONValue { actionSchema() }
    public var annotations: MCPToolAnnotations { destructiveAction }

    public func call(_ arguments: [String: JSONValue], context: MCPCallContext) async -> MCPToolResult {
        let env = context.environment
        let dry = dryRun(arguments)
        let title = "Limpiar todo lo seguro"
        if let refusal = AgentGate.refusal(env) {
            return refuse(context, action: "clean", title: title, dryRun: dry, refusal)
        }
        guard let items = await MCPFormat.detect(env), let classifier = env.classifier(),
              let executor = env.makeExecutor() else {
            return refuse(context, action: "clean", title: title, dryRun: dry, env.catalogError ?? ActionText.noCatalog)
        }
        let ready = CleanupBoard(items: items).readySafeItems
            .filter { MCPFormat.agentRefusal($0, classifier: classifier) == nil }
        let runID = UUID()
        let operation = OperationContext.agent(context.client, runID: runID)
        var rows: [JSONValue] = []
        var freed: Int64 = 0, trashed: Int64 = 0
        // En secuencia: el ejecutor relee los ajustes en cada elemento.
        for item in ready {
            let result = await runItem(item, executor: executor, context: operation, dryRun: dry)
            switch result.outcome {
            case "freed", "would_run": freed += result.bytes
            case "moved_to_trash", "would_trash": trashed += result.bytes
            default: break
            }
            rows.append(.object([
                "item_id": .string(item.id), "title": .string(item.title), "outcome": .string(result.outcome),
                "bytes": MCPFormat.number(result.bytes), "message": .string(result.message),
            ]))
        }
        let value: JSONValue = .object([
            "run_id": .string(runID.uuidString), "dry_run": .bool(dry), "results": .array(rows),
            "freed_bytes": MCPFormat.number(freed), "moved_to_trash_bytes": MCPFormat.number(trashed),
        ])
        let summary = ready.isEmpty
            ? "No hay limpiezas «Sin problema» listas ahora."
            : "\(ready.count) limpiezas «Sin problema»\(dry ? " (dry_run, sin hacer nada)" : ""): liberado "
                + "\(Format.bytes(freed)), a la Papelera \(Format.bytes(trashed))."
        return .ok(value, summary: summary)
    }
}

// MARK: - propose_cleanup

public struct ProposeCleanupTool: MCPTool {
    public init() {}
    public var name: String { "propose_cleanup" }
    public var description: String {
        "Propone al usuario, en Airy, limpiar un elemento de list_cleanup_items (item_id) o enviar una ruta a la "
            + "Papelera (path), con un motivo. No ejecuta nada: el usuario lo ve y decide en la app. Lo «No borrar» "
            + "y las rutas protegidas se rechazan."
    }
    public var inputSchema: JSONValue {
        actionSchema([
            "item_id": .object(["type": .string("string"), "minLength": .number(1),
                                "maxLength": .number(Double(AiryURLCommand.maxItemID))]),
            "path": .object(["type": .string("string"), "description": .string("Ruta absoluta o con ~."),
                             "minLength": .number(1), "maxLength": .number(Double(AiryURLCommand.maxPath))]),
            "reason": .object(["type": .string("string"), "minLength": .number(1),
                               "maxLength": .number(Double(AiryURLCommand.maxReason))]),
        ], required: ["reason"])
    }
    public var annotations: MCPToolAnnotations { appRequest }

    public func call(_ arguments: [String: JSONValue], context: MCPCallContext) async -> MCPToolResult {
        let env = context.environment
        let dry = dryRun(arguments)
        let reason = (arguments["reason"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...AiryURLCommand.maxReason).contains(reason.count) else {
            return .error("«reason» es obligatorio (entre 1 y \(AiryURLCommand.maxReason) caracteres).")
        }
        let itemID = arguments["item_id"]?.stringValue, rawPath = arguments["path"]?.stringValue
        guard (itemID == nil) != (rawPath == nil) else { return .error("Indica exactamente uno de «item_id» o «path».") }
        if let refusal = AgentGate.refusal(env) {
            return refuse(context, action: "propose", itemID: itemID, title: itemID ?? rawPath ?? "",
                          paths: rawPath.map { [$0] } ?? [], dryRun: dry, refusal)
        }

        let command: AiryURLCommand, title: String, paths: [String]
        if let itemID {
            guard let items = await MCPFormat.detect(env), let classifier = env.classifier() else {
                return refuse(context, action: "propose", itemID: itemID, title: itemID, dryRun: dry,
                              env.catalogError ?? ActionText.noCatalog)
            }
            guard let item = items.first(where: { $0.id == itemID }) else {
                return refuse(context, action: "propose", itemID: itemID, title: itemID, dryRun: dry, ActionText.notFound)
            }
            let verdict = MCPFormat.verdict(for: item, classifier: classifier)
            if verdict.risk == .doNotTouch || !CleanupBoard.showsCheckbox(item) {
                return refuse(context, action: "propose", itemID: itemID, title: item.title, paths: item.paths,
                              dryRun: dry, ActionText.doNotTouch(item.title))
            }
            command = .propose(target: .item(itemID), reason: reason, agent: agentName(context))
            title = item.title; paths = item.paths
        } else {
            let raw = rawPath ?? ""
            guard let path = MCPFormat.normalisedPath(raw, home: env.home) else {
                return refuse(context, action: "propose", title: raw, paths: [raw], dryRun: dry,
                              "La ruta debe ser absoluta (o empezar por ~).")
            }
            guard let executor = env.makeExecutor() else {
                return refuse(context, action: "propose", title: path, paths: [path], dryRun: dry,
                              env.catalogError ?? ActionText.noCatalog)
            }
            if let unsafe = executor.unsafeTrashReason(path) {
                return refuse(context, action: "propose", title: path, paths: [path], dryRun: dry,
                              "Airy no propone enviar esa ruta a la Papelera: \(unsafe)")
            }
            command = .propose(target: .path(path), reason: reason, agent: agentName(context))
            title = (path as NSString).lastPathComponent; paths = [path]
        }
        // La app vuelve a validar la URL: si no la aceptaría, no se envía.
        guard AiryURLCommand(url: command.url) != nil else {
            return refuse(context, action: "propose", itemID: itemID, title: title, paths: paths, dryRun: dry,
                          "Airy no aceptaría esa propuesta (id o ruta no válidos).")
        }
        return await sendToApp(command, context: context, action: "propose", itemID: itemID, title: title,
                               paths: paths, dryRun: dry, outcome: "pending_user",
                               status: "pending_user_confirmation", message: ActionText.proposed)
    }
}

// MARK: - show_in_app

public struct ShowInAppTool: MCPTool {
    public init() {}
    public var name: String { "show_in_app" }
    public var description: String {
        "Abre Airy mostrando una ruta en el mapa del disco. No cambia nada. dry_run: true devuelve la URL sin abrirla."
    }
    public var inputSchema: JSONValue {
        actionSchema(["path": .object(["type": .string("string"), "description": .string("Ruta absoluta o con ~."),
                                       "minLength": .number(1), "maxLength": .number(Double(AiryURLCommand.maxPath))])],
                     required: ["path"])
    }
    public var annotations: MCPToolAnnotations { appRequest }

    public func call(_ arguments: [String: JSONValue], context: MCPCallContext) async -> MCPToolResult {
        let env = context.environment
        let dry = dryRun(arguments)
        let raw = arguments["path"]?.stringValue ?? ""
        if let refusal = AgentGate.refusal(env) {
            return refuse(context, action: "show", title: raw, paths: [raw], dryRun: dry, refusal)
        }
        guard let path = MCPFormat.normalisedPath(raw, home: env.home),
              AiryURLCommand(url: AiryURLCommand.show(path: path).url) != nil else {
            return refuse(context, action: "show", title: raw, paths: [raw], dryRun: dry,
                          "La ruta debe ser absoluta (o empezar por ~).")
        }
        return await sendToApp(.show(path: path), context: context, action: "show",
                               title: (path as NSString).lastPathComponent, paths: [path], dryRun: dry,
                               outcome: "requested", status: "show_requested",
                               message: "Airy muestra \(Format.tildePath(path, home: env.home)).")
    }
}

// MARK: - rescan

public struct RescanTool: MCPTool {
    public init() {}
    public var name: String { "rescan" }
    public var description: String {
        "Pide a Airy un análisis nuevo del disco (abre la app). No borra nada. dry_run: true devuelve la URL sin abrirla."
    }
    public var inputSchema: JSONValue { actionSchema() }
    public var annotations: MCPToolAnnotations { appRequest }

    public func call(_ arguments: [String: JSONValue], context: MCPCallContext) async -> MCPToolResult {
        let dry = dryRun(arguments)
        if let refusal = AgentGate.refusal(context.environment) {
            return refuse(context, action: "rescan", title: "Analizar", dryRun: dry, refusal)
        }
        return await sendToApp(.rescan, context: context, action: "rescan", title: "Analizar", dryRun: dry,
                               outcome: "requested", status: "scan_requested", message: ActionText.rescan)
    }
}
