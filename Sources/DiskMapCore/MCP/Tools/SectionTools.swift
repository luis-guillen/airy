import Foundation
import Synchronization

// Herramientas MCP de las secciones de la fase 2 (Desinstalador, Grandes y viejos, Duplicados). Solo leen
// metadatos (rutas, tamaños, fechas, ids) o proponen por `airy://`; nunca leen el contenido de un archivo,
// nunca cierran ni desinstalan apps y nunca envían huellas de Duplicados.

private let sectionReadOnly = MCPToolAnnotations(readOnly: true, destructive: false, idempotent: true)

private func sectionSchema(_ properties: [String: JSONValue] = [:], required: [String] = []) -> JSONValue {
    var schema: [String: JSONValue] = [
        "type": .string("object"), "properties": .object(properties), "additionalProperties": .bool(false),
    ]
    if !required.isEmpty { schema["required"] = .array(required.map { .string($0) }) }
    return .object(schema)
}

private func integer(_ minimum: Int64, _ maximum: Int64? = nil, _ description: String) -> JSONValue {
    var schema: [String: JSONValue] = [
        "type": .string("integer"), "minimum": .number(Double(minimum)), "description": .string(description),
    ]
    if let maximum { schema["maximum"] = .number(Double(maximum)) }
    return .object(schema)
}

private let bundleIDSchema: JSONValue = .object([
    "type": .string("string"), "minLength": .number(1), "maxLength": .number(200),
    "description": .string("Bundle id de la app (p. ej. com.example.foo), tal como sale en list_apps."),
])

enum SectionText {
    static let unknownApp = "No hay ninguna app instalada con ese identificador."
    static let noIndex = "Aún no hay análisis guardado. Abre Airy o usa rescan."
    static let noDuplicates = "Aún no hay búsqueda de duplicados. Búscalos en Airy › Duplicados."
}

extension MCPFormat {
    /// Mismo formato que `risk(_:)` para un riesgo con su motivo (restos, huérfanos).
    static func risk(_ risk: Risk, reasons: [String]) -> [String: JSONValue] {
        ["risk": .string(riskName(risk)), "risk_label": .string(risk.label), "protected_by": .null,
         "reasons": .array(reasons.map { .string($0) })]
    }

    static func source(_ app: AppRecord) -> String {
        app.caskToken != nil ? "homebrew" : app.isAppStore ? "app_store" : "other"
    }

    /// Campos comunes de `list_apps` y `explain_app`.
    static func app(_ app: AppRecord, bytes: Int64?, running: Bool?, refusal: String?) -> [String: JSONValue] {
        [
            "name": .string(app.name), "bundle_id": .string(app.bundleID), "version": optional(app.version),
            "path": .string(app.path), "app_bytes": bytes.map(number) ?? .null, "last_used": iso(app.lastUsed),
            "running": running.map { .bool($0) } ?? .null, "source": .string(source(app)),
            "can_uninstall": .bool(refusal == nil), "refusal": optional(refusal),
        ]
    }

    /// Apps del inventario con ese bundle id (sin distinguir mayúsculas); la primera por ruta.
    static func findApp(_ id: String, in inventory: AppInventorySnapshot) -> AppRecord? {
        inventory.apps.filter { $0.bundleID.caseInsensitiveCompare(id) == .orderedSame }
            .sorted { $0.path < $1.path }.first
    }
}

// MARK: - list_apps

public struct ListAppsTool: MCPTool {
    public init() {}
    public var name: String { "list_apps" }
    public var description: String {
        "Lista las apps instaladas: nombre, bundle id, versión, ruta, tamaño del .app, último uso, si está abierta, "
            + "origen (Homebrew, App Store u otro) y si Airy podría desinstalarla. No calcula restos (usa explain_app)."
    }
    public var inputSchema: JSONValue {
        sectionSchema([
            "limit": integer(1, 500, "Máximo de apps (por defecto 100)."),
            "sort": .object(["type": .string("string"), "enum": .array(["size", "name", "last_used"].map { .string($0) }),
                             "description": .string("size (por defecto), name o last_used (las menos usadas primero).")]),
        ])
    }
    public var annotations: MCPToolAnnotations { sectionReadOnly }

    public func call(_ arguments: [String: JSONValue], context: MCPCallContext) async -> MCPToolResult {
        let env = context.environment
        let limit = arguments["limit"]?.intValue ?? 100
        let sort = arguments["sort"]?.stringValue ?? "size"
        let inventory = await env.inventorySnapshot()
        let apps = inventory.apps.filter { !$0.isSystem }
        // Solo el tamaño del .app, con presupuesto de tiempo: lo que no da tiempo a medir sale como null.
        final class Sizes: Sendable { let values = Mutex<[String: Int64]>([:]) }
        let box = Sizes()
        let paths = apps.map(\.path)
        let measured = await TimeBudget.run(.seconds(20)) {
            for path in paths {
                if Task.isCancelled { return false }
                if let bytes = AllocatedSize.of(path) { box.values.withLock { $0[path] = bytes } }
            }
            return true
        } ?? false
        let sizes = box.values.withLock { $0 }
        let sorted: [AppRecord]
        switch sort {
        case "name": sorted = apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case "last_used": sorted = apps.sorted { ($0.lastUsed ?? .distantFuture) < ($1.lastUsed ?? .distantFuture) }
        default: sorted = apps.sorted { (sizes[$0.path] ?? -1, $1.name) > (sizes[$1.path] ?? -1, $0.name) }
        }
        let finder = env.leftoverFinder()
        let rows: [JSONValue] = sorted.prefix(limit).map { app in
            .object(MCPFormat.app(app, bytes: sizes[app.path], running: env.runningApps.isRunning(bundleID: app.bundleID),
                                  refusal: finder.refusal(for: app)))
        }
        let value: JSONValue = .object([
            "complete": .bool(inventory.complete && measured), "apps": .array(rows),
        ])
        return .ok(value, summary: "\(rows.count) de \(apps.count) apps.")
    }
}

// MARK: - explain_app

public struct ExplainAppTool: MCPTool {
    public init() {}
    public var name: String { "explain_app" }
    public var description: String {
        "Explica una app instalada (por bundle id): su tamaño real con restos, cada resto con su riesgo y si viene "
            + "preseleccionado, con quién comparte datos y si Airy la desinstalaría. Solo lee; no cambia nada."
    }
    public var inputSchema: JSONValue { sectionSchema(["bundle_id": bundleIDSchema], required: ["bundle_id"]) }
    public var annotations: MCPToolAnnotations { sectionReadOnly }

    public func call(_ arguments: [String: JSONValue], context: MCPCallContext) async -> MCPToolResult {
        let env = context.environment
        let id = arguments["bundle_id"]?.stringValue ?? ""
        let inventory = await env.inventorySnapshot()
        guard let app = MCPFormat.findApp(id, in: inventory) else { return .error(SectionText.unknownApp) }
        let plan = await env.leftoverFinder().plan(for: app, inventory: inventory)
        var object = MCPFormat.app(app, bytes: plan.appBytes, running: env.runningApps.isRunning(bundleID: app.bundleID),
                                   refusal: plan.refusal)
        object["real_bytes"] = MCPFormat.number(plan.realBytes)
        object["leftover_bytes"] = MCPFormat.number(plan.leftoverBytes)
        object["size_complete"] = .bool(plan.sizeComplete)
        object["shared_with"] = MCPFormat.optional(plan.sharedWith)
        object["last_opened"] = MCPFormat.iso(env.usage.lastUsed(bundlePath: app.path))
        object["leftovers"] = .array(plan.leftovers.map { leftover in
            var row: [String: JSONValue] = [
                "kind": .string(leftover.kind.rawValue), "path": .string(leftover.path),
                "bytes": MCPFormat.number(leftover.bytes), "preselected": .bool(leftover.preselected),
                "matched_by_name": .bool(leftover.matchedByName), "reason": .string(leftover.reason),
            ]
            row.merge(MCPFormat.risk(leftover.risk, reasons: [leftover.reason])) { _, new in new }
            return .object(row)
        })
        let summary = plan.refusal.map { "«\(app.name)»: \($0)" }
            ?? "«\(app.name)» ocupa \(Format.bytes(plan.realBytes)) con sus restos."
        return .ok(.object(object), summary: summary)
    }
}

// MARK: - list_orphans

public struct ListOrphansTool: MCPTool {
    public init() {}
    public var name: String { "list_orphans" }
    public var description: String {
        "Lista restos de apps que ya no están instaladas (cachés, registros y estado guardado sin usar desde hace "
            + "tiempo). Si el inventario de apps no es fiable, no decide. Solo lee."
    }
    public var inputSchema: JSONValue { sectionSchema() }
    public var annotations: MCPToolAnnotations { sectionReadOnly }

    public func call(_ arguments: [String: JSONValue], context: MCPCallContext) async -> MCPToolResult {
        let env = context.environment
        let inventory = await env.inventorySnapshot()
        let finder = OrphanFinder(home: env.home, gate: env.pathGate(), lookup: env.bundleLookup)
        switch await finder.scan(inventory: inventory) {
        case .undecided(let reason):
            return .ok(.object(["decided": .bool(false), "reason": .string(reason), "groups": .array([])]),
                       summary: reason)
        case .found(let groups):
            let rows: [JSONValue] = groups.map { group in
                .object([
                    "bundle_id": .string(group.bundleID), "paths": .array(group.paths.map { .string($0) }),
                    "bytes": MCPFormat.number(group.bytes), "last_modified": MCPFormat.iso(group.lastModified),
                    "risk": .string(MCPFormat.riskName(group.risk)), "risk_label": .string(group.risk.label),
                ])
            }
            return .ok(.object(["decided": .bool(true), "groups": .array(rows)]),
                       summary: "\(rows.count) grupos de restos huérfanos.")
        }
    }
}

// MARK: - list_large_old

public struct ListLargeOldTool: MCPTool {
    public init() {}
    public var name: String { "list_large_old" }
    public var description: String {
        "Lista archivos grandes y sin usar del último análisis guardado (no recorre el disco), con su riesgo. "
            + "Filtros: min_bytes, older_than_months, kind, scope (home o everything). Solo lee."
    }
    public var inputSchema: JSONValue {
        sectionSchema([
            "min_bytes": integer(1_000_000, nil, "Tamaño mínimo en bytes (por defecto 100000000)."),
            "older_than_months": integer(0, 120, "Meses sin abrir ni modificar (0 = cualquier fecha)."),
            "kind": .object(["type": .string("string"),
                             "enum": .array(ContentKind.allCases.map { .string($0.rawValue) }),
                             "description": .string("Tipo de contenido.")]),
            "scope": .object(["type": .string("string"), "enum": .array([.string("home"), .string("everything")]),
                              "description": .string("home (por defecto) o everything.")]),
            "limit": integer(1, 200, "Máximo de archivos (por defecto 50)."),
        ])
    }
    public var annotations: MCPToolAnnotations { sectionReadOnly }

    public func call(_ arguments: [String: JSONValue], context: MCPCallContext) async -> MCPToolResult {
        let env = context.environment
        let (scan, failure) = MCPFormat.loadIndex(env)
        if let failure { return .error(failure) }
        guard let scan else { return .error(SectionText.noIndex) }
        guard let classifier = env.classifier() else { return .error(env.catalogError ?? ActionText.noCatalog) }
        var query = LargeOldQuery()
        query.minBytes = Int64(arguments["min_bytes"]?.intValue ?? 100_000_000)
        let months = arguments["older_than_months"]?.intValue ?? 0
        query.minMonthsIdle = months > 0 ? months : nil
        if let kind = arguments["kind"]?.stringValue.flatMap(ContentKind.init(rawValue:)) { query.kinds = [kind] }
        query.scope = arguments["scope"]?.stringValue == "everything" ? .everything : .home
        query.limit = arguments["limit"]?.intValue ?? 50
        let finder = LargeOldFinder(classifier: classifier, catalog: env.catalog, gate: env.pathGate(), home: env.home,
                                    usage: env.fileUsage)
        let files = finder.find(in: scan.root, query: query)
        let rows: [JSONValue] = files.prefix(query.limit).map { file in
            var row: [String: JSONValue] = [
                "path": .string(file.path), "name": .string(file.name), "bytes": MCPFormat.number(file.bytes),
                "kind": .string(file.kind.rawValue), "last_modified": MCPFormat.iso(file.lastModified),
                "last_opened": MCPFormat.iso(file.lastOpened),
            ]
            row.merge(MCPFormat.risk(file.risk, reasons: file.reasons)) { _, new in new }
            if let protection = file.protection { row["protected_by"] = .string(protection.source.rawValue) }
            return .object(row)
        }
        return .ok(.object(["files": .array(rows)]), summary: "\(rows.count) archivos grandes.")
    }
}

// MARK: - list_duplicates

public struct ListDuplicatesTool: MCPTool {
    public init() {}
    public var name: String { "list_duplicates" }
    public var description: String {
        "Devuelve la última búsqueda de duplicados hecha en Airy: por grupo, tamaño, lo que se liberaría, la copia "
            + "que se conservaría y las demás copias. Solo rutas y tamaños; nunca el contenido ni huellas."
    }
    public var inputSchema: JSONValue { sectionSchema(["limit": integer(1, 200, "Máximo de grupos (por defecto 50).")]) }
    public var annotations: MCPToolAnnotations { sectionReadOnly }

    public func call(_ arguments: [String: JSONValue], context: MCPCallContext) async -> MCPToolResult {
        let limit = arguments["limit"]?.intValue ?? 50
        let file: DuplicateReport.File?
        do { file = try DuplicateReport.load(from: context.environment.paths.duplicatesFile) } catch {
            return .error("No se pudo leer la última búsqueda de duplicados.")
        }
        guard let file else { return .error(SectionText.noDuplicates) }
        let rows: [JSONValue] = file.groups.prefix(limit).map { group in
            .object([
                "size": MCPFormat.number(group.size), "reclaimable_bytes": MCPFormat.number(group.reclaimableBytes),
                "keeper": .string(group.keeper), "copies": .array(group.copies.map { .string($0) }),
            ])
        }
        let value: JSONValue = .object([
            "date": MCPFormat.iso(file.date), "complete": .bool(file.complete), "groups": .array(rows),
        ])
        return .ok(value, summary: "\(rows.count) grupos de duplicados.")
    }
}

// MARK: - propose_uninstall

public struct ProposeUninstallTool: MCPTool {
    public init() {}
    public var name: String { "propose_uninstall" }
    public var description: String {
        "Propone al usuario desinstalar una app (por bundle id) con un motivo: abre Airy con la confirmación "
            + "preparada. Nunca cierra ni desinstala nada; el usuario decide. dry_run: true devuelve la URL sin abrirla."
    }
    public var inputSchema: JSONValue {
        sectionSchema([
            "bundle_id": bundleIDSchema,
            "reason": .object(["type": .string("string"), "minLength": .number(1),
                               "maxLength": .number(Double(AiryURLCommand.maxReason)),
                               "description": .string("Por qué lo propones; el usuario lo verá en la confirmación.")]),
            "dry_run": .object(["type": .string("boolean"),
                                "description": .string("true: devuelve el enlace sin abrir Airy (por defecto false).")]),
        ], required: ["bundle_id", "reason"])
    }
    public var annotations: MCPToolAnnotations { MCPToolAnnotations(readOnly: false, destructive: false, idempotent: false) }

    public func call(_ arguments: [String: JSONValue], context: MCPCallContext) async -> MCPToolResult {
        let env = context.environment
        let dry = arguments["dry_run"]?.boolValue ?? false
        let id = arguments["bundle_id"]?.stringValue ?? ""
        let reason = (arguments["reason"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        func log(_ title: String, outcome: String, message: String) {
            try? env.log.append(OperationRecord(
                runID: UUID(), date: Date(), actor: .agent(client: context.client), action: "propose",
                itemID: id, title: title, paths: [], command: nil, dryRun: dry, outcome: outcome, bytes: 0,
                message: message, proposedBy: nil))
        }
        func refuse(_ title: String, _ message: String) -> MCPToolResult {
            log(title, outcome: "blocked", message: message)
            return .error(message)
        }

        // El interruptor de agentes (o unos ajustes ilegibles) lo bloquea todo, también `dry_run`.
        if let refusal = AgentGate.refusal(env) { return refuse(id, refusal) }
        guard (1...AiryURLCommand.maxReason).contains(reason.count) else {
            return refuse(id, "«reason» es obligatorio (entre 1 y \(AiryURLCommand.maxReason) caracteres).")
        }
        let inventory = await env.inventorySnapshot()
        guard let app = MCPFormat.findApp(id, in: inventory) else { return refuse(id, SectionText.unknownApp) }
        if let refusal = env.leftoverFinder().refusal(for: app) { return refuse(app.name, refusal) }

        let command = AiryURLCommand.uninstall(bundleID: app.bundleID, reason: reason,
                                               agent: String(context.client.prefix(AiryURLCommand.maxAgent)))
        let url = command.url
        // Ida y vuelta: lo que se abre es exactamente lo que la app aceptará.
        guard let parsed = AiryURLCommand(url: url), case .uninstall = parsed else {
            return refuse(app.name, "Airy no aceptaría esa propuesta (identificador no válido).")
        }
        if !dry, await !env.urlOpener.open(url) {
            log(app.name, outcome: "failed", message: ActionText.noApp)
            return .error(ActionText.noApp)
        }
        log(app.name, outcome: "pending_user", message: ActionText.proposed)
        let value: JSONValue = .object([
            "status": .string("pending_user_confirmation"), "url": .string(url.absoluteString),
            "dry_run": .bool(dry), "message": .string(ActionText.proposed),
        ])
        return .ok(value, summary: dry ? "Sin abrir Airy (dry_run): \(url.absoluteString)" : ActionText.proposed)
    }
}
