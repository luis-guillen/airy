import Foundation

// Herramientas MCP de solo lectura. Trabajan con el índice guardado, `lstat`, el catálogo y la
// detección de Limpieza: nunca leen el contenido de ningún archivo.

/// Formato común de las respuestas.
public enum MCPFormat {
    /// `{risk, risk_label, protected_by, reasons}` a partir del veredicto del clasificador.
    public static func risk(_ c: Classification) -> [String: JSONValue] {
        let riskName: String
        switch c.risk {
        case .safe: riskName = "safe"
        case .yourCall: riskName = "yourCall"
        case .doNotTouch: riskName = "doNotTouch"
        }
        let protectedBy: JSONValue = switch c.protection?.source {
        case .airy?: .string("airy")
        case .user?: .string("user")
        case nil: .null
        }
        return [
            "risk": .string(riskName),
            "risk_label": .string(c.risk.label),
            "protected_by": protectedBy,
            "reasons": .array(c.reasons.map { .string($0) }),
        ]
    }

    static func optional(_ text: String?) -> JSONValue { text.map { .string($0) } ?? .null }

    static func number(_ value: Int64) -> JSONValue { .number(Double(value)) }

    static func iso(_ date: Date?) -> JSONValue {
        guard let date else { return .null }
        return .string(ISO8601DateFormatter().string(from: date))
    }

    /// `~` y `~/…` se expanden; solo rutas absolutas, sin caracteres de control; `.`, `..` y `//` se resuelven
    /// en el texto (sin tocar el disco). `nil` si no es una ruta válida.
    static func normalisedPath(_ raw: String, home: String) -> String? {
        var path = raw
        if path == "~" { path = home } else if path.hasPrefix("~/") { path = home + path.dropFirst(1) }
        guard path.hasPrefix("/"), !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            return nil
        }
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { _ = parts.popLast(); continue }
            parts.append(part)
        }
        return "/" + parts.joined(separator: "/")
    }

    static func join(_ parent: String, _ name: String) -> String {
        parent == "/" ? "/" + name : parent + "/" + name
    }

    /// Nodo del índice para una ruta absoluta normalizada, o `nil` si no está.
    static func node(at path: String, in root: FileNode) -> FileNode? {
        if path == "/", root.name.isEmpty || root.name == "/" { return root }
        return CleanupScanner.node(at: path, in: root)
    }

    static func loadIndex(_ env: AiryEnvironment) -> (scan: ScanResult?, failure: String?) {
        do { return (try env.index.loadScan(), nil) } catch { return (nil, "No se pudo leer el último análisis.") }
    }
}

private func objectSchema(_ properties: [String: JSONValue] = [:], required: [String] = []) -> JSONValue {
    var schema: [String: JSONValue] = [
        "type": .string("object"),
        "properties": .object(properties),
        "additionalProperties": .bool(false),
    ]
    if !required.isEmpty { schema["required"] = .array(required.map { .string($0) }) }
    return .object(schema)
}

private let readOnly = MCPToolAnnotations(readOnly: true, destructive: false, idempotent: true)

// MARK: - get_disk_summary

public struct GetDiskSummaryTool: MCPTool {
    public init() {}
    public var name: String { "get_disk_summary" }
    public var description: String {
        "Resumen del disco: capacidad, espacio libre y purgable, bytes analizados y desglose por tipo, según el último "
            + "análisis guardado de Airy. `scan_complete` es false si hubo carpetas sin acceso en ese análisis. "
            + "`full_disk_access` es el permiso del proceso del agente (airy-mcp), no el de la app Airy."
    }
    public var inputSchema: JSONValue { objectSchema() }
    public var annotations: MCPToolAnnotations { readOnly }

    public func call(_ arguments: [String: JSONValue], context: MCPCallContext) async -> MCPToolResult {
        let env = context.environment
        let loaded = MCPFormat.loadIndex(env)
        if let failure = loaded.failure { return .error(failure) }
        guard let scan = loaded.scan else {
            return .ok(.object(["scan_available": .bool(false)]), summary: "Aún no hay análisis guardado. Abre Airy o usa rescan.")
        }
        let capacity = env.capacity()
        let lastScan = scan.scannedAt
        let kinds: [JSONValue] = zip(ContentKind.allCases, scan.root.kindBytes)
            .filter { $0.1 > 0 }
            .sorted { ($0.1, $1.0.rawValue) > ($1.1, $0.0.rawValue) }
            .map { .object(["kind": .string($0.0.rawValue), "title": .string($0.0.title), "bytes": MCPFormat.number($0.1)]) }
        let value: JSONValue = .object([
            "scan_available": .bool(true),
            "scan_complete": .bool(scan.inaccessible.isEmpty),
            "scan_status": .string(ScanCompleteness.of(scan).jsonName),
            "inaccessible_count": .number(Double(scan.inaccessible.count)),
            "last_scan": MCPFormat.iso(lastScan),
            "total_bytes": capacity.map { MCPFormat.number($0.total) } ?? .null,
            "free_bytes": capacity.map { MCPFormat.number($0.available) } ?? .null,
            "purgeable_bytes": capacity.map { MCPFormat.number(max(0, $0.importantAvailable - $0.available)) } ?? .null,
            "analyzed_bytes": MCPFormat.number(scan.root.allocatedSize),
            "by_kind": .array(kinds),
            "full_disk_access": .bool(env.probes.hasFullDiskAccess()),
        ])
        let note = scan.inaccessible.isEmpty ? "" : " (análisis incompleto: hay carpetas sin acceso)"
        return .ok(value, summary: "Resumen del disco a partir del último análisis\(note).")
    }
}

// MARK: - list_largest

public struct ListLargestTool: MCPTool {
    public init() {}
    public var name: String { "list_largest" }
    public var description: String {
        "Lista lo que más ocupa dentro de una carpeta del último análisis (por defecto la raíz del análisis), "
            + "de mayor a menor, con el riesgo de borrar cada elemento. Solo metadatos."
    }
    public var inputSchema: JSONValue {
        objectSchema([
            "path": .object(["type": .string("string"), "description": .string("Ruta absoluta o con ~."), "maxLength": .number(4096)]),
            "limit": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(200)]),
        ])
    }
    public var annotations: MCPToolAnnotations { readOnly }

    public func call(_ arguments: [String: JSONValue], context: MCPCallContext) async -> MCPToolResult {
        let env = context.environment
        var limit = 20
        if let raw = arguments["limit"] {
            guard let n = raw.intValue, (1...200).contains(n) else { return .error("limit debe ser un entero entre 1 y 200.") }
            limit = n
        }
        let loaded = MCPFormat.loadIndex(env)
        if let failure = loaded.failure { return .error(failure) }
        guard let scan = loaded.scan else { return .error("Aún no hay análisis guardado. Abre Airy o usa rescan.") }
        guard let classifier = env.classifier() else { return .error(env.catalogError ?? "El catálogo no está disponible.") }

        let path: String, node: FileNode
        if let raw = arguments["path"]?.stringValue {
            guard let normal = MCPFormat.normalisedPath(raw, home: env.home) else {
                return .error("La ruta debe ser absoluta (o empezar por ~).")
            }
            guard let found = MCPFormat.node(at: normal, in: scan.root) else {
                return .error("Esa carpeta no está en el último análisis.")
            }
            path = normal; node = found
        } else if let root = MCPFormat.node(at: "/", in: scan.root) {
            path = "/"; node = root
        } else {
            // El análisis no empieza en «/»: se usa su raíz.
            path = scan.root.name.isEmpty ? "/" : scan.root.name; node = scan.root
        }

        let partial = PartialScanIndex(inaccessible: scan.inaccessible)
        let children = node.children.sorted { ($0.allocatedSize, $1.name) > ($1.allocatedSize, $0.name) }.prefix(limit)
        let rows: [JSONValue] = children.map { child in
            if child.aggregatedCount > 0 {
                return .object([
                    "name": .string("Otros"), "aggregated_count": .number(Double(child.aggregatedCount)),
                    "bytes": MCPFormat.number(child.allocatedSize), "path": .null,
                    "size_partial": .bool(partial.isPartial(path)),
                ])
            }
            let childPath = MCPFormat.join(path, child.name)
            var row: [String: JSONValue] = [
                "name": .string(child.name), "path": .string(childPath),
                "bytes": MCPFormat.number(child.allocatedSize), "kind": .string(child.dominantKind.rawValue),
                "last_modified": MCPFormat.iso(child.lastModified), "is_directory": .bool(child.isDirectory),
                "size_partial": .bool(partial.isPartial(childPath)),
            ]
            row.merge(MCPFormat.risk(classifier.classify(path: childPath))) { $1 }
            return .object(row)
        }
        let value: JSONValue = .object(["path": .string(path), "children": .array(rows)])
        return .ok(value, summary: "Lo más grande en \(Format.tildePath(path, home: env.home)) (\(rows.count) elementos).")
    }
}

// MARK: - explain_path

public struct ExplainPathTool: MCPTool {
    public init() {}
    public var name: String { "explain_path" }
    public var description: String {
        "Explica una ruta: qué es, quién la crea, si se regenera, cuánto ocupa según el último análisis y el riesgo de "
            + "borrarla (semáforo de Airy). No lee el contenido de nada."
    }
    public var inputSchema: JSONValue {
        objectSchema(["path": .object(["type": .string("string"), "minLength": .number(1), "maxLength": .number(4096)])],
                     required: ["path"])
    }
    public var annotations: MCPToolAnnotations { readOnly }

    public func call(_ arguments: [String: JSONValue], context: MCPCallContext) async -> MCPToolResult {
        let env = context.environment
        guard let raw = arguments["path"]?.stringValue,
              let path = MCPFormat.normalisedPath(raw, home: env.home) else {
            return .error("La ruta debe ser absoluta (o empezar por ~).")
        }
        guard let classifier = env.classifier() else { return .error(env.catalogError ?? "El catálogo no está disponible.") }

        let entry = env.catalog?.match(path: path, home: env.home)
        let folderText = FolderExplanations.text(for: path, home: env.home)
        let title = entry?.title ?? (path == "/" ? "/" : (path as NSString).lastPathComponent)
        let explanation = entry?.explanation ?? folderText ?? "Esta ruta no está en el catálogo de Airy."

        var size: JSONValue = .null
        if let scan = MCPFormat.loadIndex(env).scan, let node = MCPFormat.node(at: path, in: scan.root) {
            size = MCPFormat.number(node.allocatedSize)
        }
        var info = stat()
        let exists = lstat(path, &info) == 0

        var value: [String: JSONValue] = [
            "path": .string(path),
            "known": .bool(entry != nil || folderText != nil),
            "title": .string(title),
            "explanation": .string(explanation),
            "who_creates_it": MCPFormat.optional(entry?.whoCreatesIt),
            "regenerates": entry.map { .bool($0.regenerates) } ?? .null,
            "size_bytes": size,
            "exists": .bool(exists),
        ]
        value.merge(MCPFormat.risk(classifier.classify(path: path))) { $1 }
        return .ok(.object(value), summary: "\(title): \(explanation)")
    }
}

// MARK: - list_cleanup_items

public struct ListCleanupItemsTool: MCPTool {
    public init() {}
    public var name: String { "list_cleanup_items" }
    public var description: String {
        "Lista las limpiezas que Airy detecta ahora en este Mac, en el orden de la pantalla Limpieza, con su riesgo, "
            + "tamaño, método y si un agente puede ejecutarla (`actionable_by_agent`: solo «Sin problema» sin bloqueo). "
            + "Cada elemento trae `verdict` (la etiqueta), `why` (por qué) y `short_reason` (qué pierdes), y `review_only` "
            + "marca los de «Solo revisar», que Airy no borra."
    }
    public var inputSchema: JSONValue { objectSchema() }
    public var annotations: MCPToolAnnotations { readOnly }

    public func call(_ arguments: [String: JSONValue], context: MCPCallContext) async -> MCPToolResult {
        let env = context.environment
        guard let scanner = env.makeScanner(), let classifier = env.classifier() else {
            return .error(env.catalogError ?? "El catálogo no está disponible.")
        }
        let loaded = MCPFormat.loadIndex(env).scan
        let board = CleanupBoard(items: await scanner.findItems(scan: loaded?.root, inaccessible: loaded?.inaccessible ?? []))
        // Con el interruptor apagado o los ajustes ilegibles, ningún agente puede ejecutar nada.
        let agentsEnabled = AgentGate.refusal(env) == nil
        let rows: [JSONValue] = board.displayItems.map { item in
            var verdict = classifier.classify(entry: item.entry, paths: item.paths)
            verdict.risk = .strictest(verdict.risk, item.risk)
            verdict.protection = item.protection ?? verdict.protection
            var shown = item // el riesgo y la protección que decide el clasificador vivo
            shown.risk = verdict.risk
            shown.protection = verdict.protection
            let method: String, command: JSONValue
            switch item.entry.cleanup {
            case .trash: method = "trash"; command = .null
            case .info: method = "info"; command = .null
            case .command(let executable, let args, _):
                method = "command"; command = .array(([executable] + args).map { .string($0) })
            }
            var row: [String: JSONValue] = [
                "id": .string(item.id), "title": .string(item.title), "bytes": MCPFormat.number(item.bytes),
                "size_text": .string(CleanupBoard.sizeText(item)),
                "upper_bound": .bool(CleanupBoard.isPartial(item)),
                "method": .string(method), "command": command,
                "blocked_by_open_apps": .array(item.blockedByOpenApps.map { .string($0) }),
                "used_by": .array(item.usedBy.map { .string($0) }),
                "blocked_reason": MCPFormat.optional(item.blockedReason),
                "preselected": .bool(item.preselected), "highlighted": .bool(item.highlighted),
                "actionable_by_agent": .bool(agentsEnabled && verdict.risk == .safe && CleanupBoard.canSelect(item)),
                "review_only": .bool(CleanupBoard.isReviewOnly(item)),
                "details": .array(item.details.map { .string($0) }),
                "size_note": MCPFormat.optional(item.sizeNote),
                "size_partial": .bool(item.sizeIsPartial),
                "verdict": .string(verdict.risk.label),
                "short_reason": MCPFormat.optional(item.entry.shortReason.map {
                    RiskExplanation.expand($0, bytes: item.bytes)
                }),
                "why": .string(RiskExplanation.why(shown, home: env.home)),
                "risk_reason": MCPFormat.optional(item.riskReason),
            ]
            row.merge(MCPFormat.risk(verdict)) { $1 }
            return .object(row)
        }
        let value: JSONValue = .object([
            "mode": .string(env.settings.load().effective.mode.rawValue), "agents_enabled": .bool(agentsEnabled),
            "items": .array(rows),
        ])
        return .ok(value, summary: "\(rows.count) limpiezas detectadas.")
    }
}
