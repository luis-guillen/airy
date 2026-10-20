import Foundation

/// Acción propuesta por la IA. Solo se devuelve como dato: la ejecuta después `CleanupExecutor`,
/// que repite sus propias comprobaciones.
public enum AIAction: Codable, Sendable, Equatable {
    case trash(path: String)
    case runCatalogCommand(id: String)

    private enum CodingKeys: String, CodingKey { case type, path, id }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "trash": self = .trash(path: try c.decode(String.self, forKey: .path))
        case "runCatalogCommand": self = .runCatalogCommand(id: try c.decode(String.self, forKey: .id))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Acción desconocida: \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .trash(let path):
            try c.encode("trash", forKey: .type)
            try c.encode(path, forKey: .path)
        case .runCatalogCommand(let id):
            try c.encode("runCatalogCommand", forKey: .type)
            try c.encode(id, forKey: .id)
        }
    }
}

public struct AIRecommendation: Codable, Sendable, Identifiable {
    public var id: String
    /// Ruta absoluta (tras validar, siempre una ruta presente en el contexto).
    public var path: String
    public var verdict: Risk
    public var reason: String
    public var bytes: Int64
    public var action: AIAction?

    public init(id: String, path: String, verdict: Risk, reason: String, bytes: Int64, action: AIAction?) {
        self.id = id; self.path = path; self.verdict = verdict; self.reason = reason
        self.bytes = bytes; self.action = action
    }

    private enum CodingKeys: String, CodingKey { case id, path, verdict, reason, bytes, action }

    /// `verdict` va como texto ("safe" | "yourCall" | "doNotTouch"); `id` es opcional (por defecto, la ruta).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? path
        let name = try c.decode(String.self, forKey: .verdict)
        guard let verdict = Risk(jsonName: name) else {
            throw DecodingError.dataCorruptedError(forKey: .verdict, in: c, debugDescription: "Veredicto desconocido: \(name)")
        }
        self.verdict = verdict
        reason = try c.decode(String.self, forKey: .reason)
        bytes = try c.decode(Int64.self, forKey: .bytes)
        action = try c.decodeIfPresent(AIAction.self, forKey: .action)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(path, forKey: .path)
        try c.encode(verdict.jsonName, forKey: .verdict)
        try c.encode(reason, forKey: .reason)
        try c.encode(bytes, forKey: .bytes)
        try c.encodeIfPresent(action, forKey: .action)
    }
}

public struct AIReport: Codable, Sendable {
    public var summary: String
    public var recommendations: [AIRecommendation]
    public var reclaimableBytes: Int64

    public init(summary: String, recommendations: [AIRecommendation], reclaimableBytes: Int64) {
        self.summary = summary; self.recommendations = recommendations; self.reclaimableBytes = reclaimableBytes
    }
}

public enum AIError: Error, Sendable, CustomStringConvertible {
    case notInstalled, timedOut, invalidResponse(String), failed(String)

    public var description: String {
        switch self {
        case .notInstalled: "No se encontró Claude Code en este Mac."
        case .timedOut: "Claude tardó demasiado en responder."
        case .invalidResponse(let detail): "Claude devolvió una respuesta que no se entiende: \(detail)"
        case .failed(let detail): "Claude no pudo responder: \(detail)"
        }
    }
}

public struct ChatMessage: Codable, Sendable, Equatable {
    public enum Role: String, Codable, Sendable { case user, assistant }
    public var role: Role
    public var text: String

    public init(role: Role, text: String) { self.role = role; self.text = text }
}

/// Asistente basado en `claude -p` sin herramientas: solo recibe metadatos y solo devuelve datos.
public struct AIAssistant: Sendable {
    public static let timeout: TimeInterval = 120

    static let systemPrompt = """
    Eres el asistente de Airy, una app de macOS que muestra qué ocupa espacio en el disco. \
    Solo ves metadatos (rutas, tamaños, fechas, tipos y fichas del catálogo de Airy), nunca el contenido de los archivos. \
    Clasifica cada elemento en "safe" (borrar sin riesgo), "yourCall" (depende de ti) o "doNotTouch" (no tocar). \
    Nunca recomiendes borrar archivos personales (Documentos, Escritorio, Imágenes, Películas, Música, Descargas, proyectos), \
    volúmenes de Docker ni nada de /System. \
    Las únicas acciones posibles son "trash" de una ruta que aparezca en el contexto o "runCatalogCommand" con un id del catálogo; \
    no inventes rutas ni comandos. \
    Explica en lenguaje sencillo, como a alguien no técnico. \
    Responde en español de España, en frases cortas, sin tecnicismos innecesarios.
    """

    /// En el informe, los totales los calcula Airy ("Recuperable"): el texto de Claude no da cifras sumadas
    /// que puedan contradecirlos.
    static let reportSystemPrompt = systemPrompt + " " + """
    En el resumen no des totales ni sumas de espacio (ni "en total puedes liberar X"): Airy calcula los totales \
    y los muestra aparte. Puedes citar el tamaño de un elemento concreto tal como aparece en el contexto.
    """

    /// En el chat Claude no puede hacer nada por su cuenta: solo explica.
    static let chatSystemPrompt = systemPrompt + " " + """
    En esta conversación no puedes realizar ninguna acción tú mismo y no debes ofrecerte a hacerla     ("¿quieres que lo borre?"); el usuario actúa desde la sección Limpieza o con los botones del Informe de Airy.
    """

    private let claudePath: String
    private let runner: any CommandRunning
    private let catalog: Catalog
    private let home: String
    /// Si existe, decide el veredicto (modo, protecciones del usuario y duras) en lugar de `RiskPolicy`.
    private let classifier: RiskClassifier?

    public init(claudePath: String, runner: any CommandRunning, catalog: Catalog, home: String = NSHomeDirectory(),
                classifier: RiskClassifier? = nil) {
        self.claudePath = claudePath
        self.runner = runner
        self.catalog = catalog
        self.home = home
        self.classifier = classifier
    }

    /// Argumentos comunes. `--setting-sources ""` evita hooks y plugins del usuario (verificado: mantiene
    /// la sesión iniciada, a diferencia de `--bare`). `--tools ""`: Claude no puede leer ni ejecutar nada.
    var baseArguments: [String] { arguments(systemPrompt: Self.systemPrompt) }

    func arguments(systemPrompt: String) -> [String] {
        ["-p", "--setting-sources", "", "--tools", "", "--strict-mcp-config", "--disable-slash-commands",
         "--no-session-persistence", "--system-prompt", systemPrompt]
    }

    // MARK: Informe

    public func report(context: String) async throws -> AIReport {
        let arguments = self.arguments(systemPrompt: Self.reportSystemPrompt)
            + ["--output-format", "json", "--json-schema", Self.reportSchema]
        let prompt = """
        Contexto del disco (JSON, solo metadatos):
        \(context)

        Tarea: escribe un resumen breve del estado del disco y recomienda qué se puede liberar. \
        Usa en "path" rutas exactamente como aparecen en el contexto; para un elemento de limpieza sin rutas, \
        pon en "path" su "id". "runCatalogCommand" solo con el catalogId de esa misma ruta o elemento. \
        En "bytes" pon el tamaño que indica el contexto.
        """
        let output: CommandOutput
        do {
            output = try await withScratchDirectory { dir in
                try await runner.run(claudePath, arguments, stdin: prompt, workingDirectory: dir, timeout: Self.timeout)
            }
        } catch {
            throw mapError(error)
        }

        guard let object = try? JSONSerialization.jsonObject(with: Data(output.stdout.utf8)) as? [String: Any] else {
            if output.status != 0 {
                throw AIError.failed(Self.snippet(output.stderr.isEmpty ? output.stdout : output.stderr))
            }
            throw AIError.invalidResponse(Self.snippet(output.stdout))
        }
        if object["is_error"] as? Bool == true {
            throw AIError.failed(Self.snippet(object["result"] as? String ?? output.stderr))
        }
        guard let structured = object["structured_output"] as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: structured),
              let raw = try? JSONDecoder().decode(AIReport.self, from: data) else {
            throw AIError.invalidResponse("falta structured_output o no cumple el esquema")
        }
        return validate(raw, context: context)
    }

    /// Lo que se sabe de una ruta del contexto (o del id de un elemento de limpieza sin rutas).
    struct Known {
        var path: String
        var bytes: Int64
        /// Riesgo del elemento de limpieza que la contiene (ya subido por `usedBy`, etc.).
        var itemRisk: Risk?
        /// Fichas de los elementos de limpieza que la contienen.
        var itemCatalogIds: Set<String> = []
        /// `true` si es el id de un elemento sin rutas (p. ej. `docker-build-cache`), no una ruta.
        var isItemID = false
    }

    /// Reglas aplicadas siempre en código, desconfiando de la IA:
    /// - solo rutas del contexto; el riesgo nunca baja del suelo, del catálogo ni del elemento de limpieza;
    /// - `trash` solo de la propia ruta, si su ficha del catálogo se limpia con Papelera y queda "sin riesgo",
    ///   y nunca de ubicaciones protegidas;
    /// - `runCatalogCommand` solo con la ficha de esa misma ruta (o de su elemento de limpieza) y nunca `.info`.
    func validate(_ raw: AIReport, context: String) -> AIReport {
        let payload = try? JSONDecoder().decode(AIContextPayload.self, from: Data(context.utf8))
        var known: [String: Known] = [:]
        for node in payload?.nodes ?? [] {
            let absolute = AIPaths.expand(node.path, home: home)
            known[RiskPolicy.canonical(absolute)] = Known(path: absolute, bytes: node.bytes)
        }
        var itemIDs: [String: Known] = [:]
        for item in payload?.cleanupItems ?? [] {
            let itemRisk = Risk(jsonName: item.risk) ?? .yourCall
            if item.paths.isEmpty {
                itemIDs[item.id] = Known(path: item.id, bytes: item.bytes, itemRisk: itemRisk,
                                         itemCatalogIds: [item.catalogId], isItemID: true)
            }
            for path in item.paths {
                let absolute = AIPaths.expand(path, home: home)
                let key = RiskPolicy.canonical(absolute)
                var entry = known[key] ?? Known(path: absolute, bytes: item.paths.count == 1 ? item.bytes : 0)
                entry.itemRisk = entry.itemRisk.map { Risk.strictest($0, itemRisk) } ?? itemRisk
                entry.itemCatalogIds.insert(item.catalogId)
                known[key] = entry
            }
        }
        func lookup(_ path: String) -> Known? {
            if let item = itemIDs[path] { return item }
            return known[RiskPolicy.canonical(AIPaths.expand(path, home: home))]
        }
        let homes = [home] + (realpath(home, nil).map { real in
            defer { free(real) }
            return [String(decoding: Data(bytes: real, count: strlen(real)), as: UTF8.self)]
        } ?? [])

        var seen = Set<String>()
        var recommendations: [AIRecommendation] = []
        for rec in raw.recommendations {
            guard let match = lookup(rec.path), seen.insert(match.path).inserted else { continue }
            let pathEntry = match.isItemID
                ? match.itemCatalogIds.first.flatMap { catalog.entry(id: $0) }
                : catalog.match(path: match.path, home: home)
            var verdict: Risk
            if let classifier, match.isItemID, let pathEntry {
                verdict = classifier.classify(entry: pathEntry, paths: [], ai: rec.verdict).risk
            } else if let classifier, !match.isItemID {
                verdict = classifier.classify(path: match.path, ai: rec.verdict).risk
            } else {
                verdict = RiskPolicy.effectiveRisk(path: match.path, home: home, catalog: pathEntry?.risk, ai: rec.verdict)
            }
            if let itemRisk = match.itemRisk { verdict = .strictest(verdict, itemRisk) }

            var action: AIAction?
            switch rec.action {
            case .trash(let path):
                // Solo la propia ruta (no "~/Library" para "~/Library/x"), con ficha de Papelera y fuera de lo protegido.
                if !match.isItemID, let target = lookup(path), target.path == match.path,
                   let pathEntry, case .trash = pathEntry.cleanup,
                   RiskPolicy.trashRefusal(forCanonicalPath: RiskPolicy.canonical(match.path), homes: homes, catalog: catalog) == nil {
                    action = .trash(path: match.path)
                }
            case .runCatalogCommand(let id):
                let related = id == pathEntry?.id || match.itemCatalogIds.contains(id)
                if related, let entry = catalog.entry(id: id), entry.cleanup != .info {
                    verdict = .strictest(verdict, classifier?.baseRisk(of: entry) ?? entry.risk)
                    action = .runCatalogCommand(id: id)
                }
            case nil:
                break
            }
            if case .trash = action, verdict != .safe { action = nil }
            if verdict == .doNotTouch { action = nil }
            recommendations.append(AIRecommendation(
                id: match.path, path: match.path, verdict: verdict, reason: rec.reason,
                bytes: match.bytes, action: action))
        }

        // Recuperable: recomendaciones seguras con acción, sin contar dos veces una ruta dentro de otra.
        let counted = recommendations.filter { $0.verdict == .safe && $0.action != nil }
        let reclaimable = counted.filter { rec in
            !counted.contains { other in
                other.path != rec.path && RiskPolicy.isInside(RiskPolicy.canonical(rec.path),
                                                              root: RiskPolicy.canonical(other.path))
            }
        }.reduce(Int64(0)) { $0 + $1.bytes }
        return AIReport(summary: raw.summary, recommendations: recommendations, reclaimableBytes: reclaimable)
    }

    // MARK: Chat

    /// Texto de la respuesta según llega. Se envía la conversación entera en cada turno.
    public func chat(history: [ChatMessage], context: String) -> AsyncThrowingStream<String, Error> {
        let arguments = arguments(systemPrompt: Self.chatSystemPrompt) + ["--output-format", "stream-json", "--verbose", "--include-partial-messages"]
        let conversation = history.map { "\($0.role == .user ? "Usuario" : "Asistente"): \($0.text)" }
            .joined(separator: "\n\n")
        let prompt = """
        Contexto del disco (JSON, solo metadatos):
        \(context)

        Conversación hasta ahora:
        \(conversation)

        Responde como Asistente al último mensaje del Usuario. No uses Markdown complejo.
        """
        let runner = runner
        let claudePath = claudePath
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await withScratchDirectory { dir in
                        var finished = false
                        for try await line in runner.stream(claudePath, arguments, stdin: prompt,
                                                            workingDirectory: dir, timeout: Self.timeout) {
                            switch try Self.parseStreamLine(line) {
                            case .text(let text): continuation.yield(text)
                            case .done: finished = true
                            case .ignore: break
                            }
                            if finished { break }
                        }
                        if !finished { throw AIError.invalidResponse("Claude terminó sin respuesta") }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: mapError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    enum StreamLine: Equatable { case text(String), done, ignore }

    /// Solo interesan los `text_delta` y el `result` final; el resto de líneas se ignora.
    static func parseStreamLine(_ line: String) throws -> StreamLine {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            return .ignore
        }
        switch object["type"] as? String {
        case "stream_event":
            guard let event = object["event"] as? [String: Any], event["type"] as? String == "content_block_delta",
                  let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String else { return .ignore }
            return .text(text)
        case "result":
            if object["is_error"] as? Bool == true {
                throw AIError.failed(snippet(object["result"] as? String ?? "error desconocido"))
            }
            return .done
        default:
            return .ignore
        }
    }

    // MARK: Utilidades

    /// Claude se ejecuta en un directorio vacío y recién creado, que se borra al terminar.
    private func withScratchDirectory<T>(_ body: (String) async throws -> T) async throws -> T {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("airy-claude-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: url) }
        return try await body(url.path)
    }

    private func mapError(_ error: Error) -> Error {
        switch error {
        case let error as AIError: return error
        case CommandError.timedOut: return AIError.timedOut
        case CommandError.lineTooLong: return AIError.invalidResponse("respuesta demasiado larga")
        case CommandError.launchFailed(_, let message):
            return ClaudeLocator.isExecutableFile(claudePath) ? AIError.failed(message) : AIError.notInstalled
        case is CancellationError: return error
        default: return AIError.failed(String(describing: error))
        }
    }

    static func snippet(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 300 ? String(trimmed.prefix(300)) + "…" : trimmed
    }

    /// Esquema de `AIReport` para `--json-schema` (veredictos como texto).
    static let reportSchema: String = {
        let action: [String: Any] = [
            "type": "object",
            "properties": [
                "type": ["type": "string", "enum": ["trash", "runCatalogCommand"]],
                "path": ["type": "string", "description": "Para trash: una ruta del contexto."],
                "id": ["type": "string", "description": "Para runCatalogCommand: un catalogId del contexto."],
            ],
            "required": ["type"],
            "additionalProperties": false,
        ]
        let recommendation: [String: Any] = [
            "type": "object",
            "properties": [
                "path": ["type": "string"],
                "verdict": ["type": "string", "enum": ["safe", "yourCall", "doNotTouch"]],
                "reason": ["type": "string"],
                "bytes": ["type": "integer"],
                "action": action,
            ],
            "required": ["path", "verdict", "reason", "bytes"],
            "additionalProperties": false,
        ]
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "summary": ["type": "string"],
                "recommendations": ["type": "array", "items": recommendation],
                "reclaimableBytes": ["type": "integer"],
            ],
            "required": ["summary", "recommendations", "reclaimableBytes"],
            "additionalProperties": false,
        ]
        let data = try! JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }()
}
