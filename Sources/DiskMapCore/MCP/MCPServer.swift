import Foundation

/// Servidor MCP (JSON-RPC 2.0, un mensaje por línea). `handle(line:)` atiende un mensaje y
/// devuelve la respuesta en una línea, o `nil` para notificaciones y respuestas del cliente.
/// El transporte llama de una en una y en orden.
public actor MCPServer {
    public static let supportedProtocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    static let latestProtocolVersion = "2025-11-25"
    /// Desde esta versión los resultados llevan `structuredContent`.
    static let structuredContentVersion = "2025-06-18"
    static let defaultClientName = "agente"
    static let maxClientNameLength = 64
    static let instructions =
        "Airy consulta y limpia el disco de este Mac. Solo ejecuta lo marcado «Sin problema»; lo demás se propone al usuario en la app. Nunca recibes el contenido de los archivos."

    private let registry: MCPToolRegistry
    private let environment: AiryEnvironment
    private let serverVersion: String
    private var negotiatedVersion: String?
    private var clientName = MCPServer.defaultClientName

    public init(registry: MCPToolRegistry, environment: AiryEnvironment, serverVersion: String) {
        self.registry = registry
        self.environment = environment
        self.serverVersion = serverVersion
    }

    private enum RPCError {
        static let parse = -32700, invalidRequest = -32600, methodNotFound = -32601, invalidParams = -32602
    }

    public func handle(line: String) async -> String? {
        guard !line.allSatisfy(\.isWhitespace) else { return nil }
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)) else {
            return Self.error(id: .null, code: RPCError.parse, message: "JSON no válido.")
        }
        guard case .object(let request) = message else {
            // Los lotes (arrays) no se admiten.
            return Self.error(id: .null, code: RPCError.invalidRequest, message: "Petición no válida: se espera un objeto JSON-RPC.")
        }
        let id = request["id"]
        if let id, !Self.isValidID(id) {
            return Self.error(id: .null, code: RPCError.invalidRequest, message: "Petición no válida: id incorrecto.")
        }
        guard request["jsonrpc"] == .string("2.0") else {
            return Self.error(id: id ?? .null, code: RPCError.invalidRequest, message: "Petición no válida: falta \"jsonrpc\": \"2.0\".")
        }
        guard let methodValue = request["method"] else {
            // Respuesta del cliente (no le pedimos nada): se ignora.
            if request["result"] != nil || request["error"] != nil { return nil }
            return Self.error(id: id ?? .null, code: RPCError.invalidRequest, message: "Petición no válida: falta el método.")
        }
        guard let method = methodValue.stringValue else {
            return Self.error(id: id ?? .null, code: RPCError.invalidRequest, message: "Petición no válida: el método no es texto.")
        }
        let params = request["params"]
        if let params, case .object = params {} else if params != nil {
            return Self.error(id: id ?? .null, code: RPCError.invalidParams, message: "Los parámetros deben ser un objeto.")
        }
        // Notificación: no hay respuesta, sea cual sea el método.
        guard let id else { return nil }

        switch method {
        case "initialize": return Self.result(id: id, initialize(params))
        case "ping": return Self.result(id: id, .object([:]))
        case "tools/list": return Self.result(id: id, toolsList())
        case "tools/call": return await toolsCall(id: id, params: params)
        default: return Self.error(id: id, code: RPCError.methodNotFound, message: "Método desconocido: \(method).")
        }
    }

    // MARK: - Métodos

    private func initialize(_ params: JSONValue?) -> JSONValue {
        let requested = params?["protocolVersion"]?.stringValue
        let version = requested.flatMap { Self.supportedProtocolVersions.contains($0) ? $0 : nil } ?? Self.latestProtocolVersion
        negotiatedVersion = version
        clientName = Self.sanitisedClientName(params?["clientInfo"]?["name"]?.stringValue)
        return .object([
            "protocolVersion": .string(version),
            "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
            "serverInfo": .object([
                "name": .string("airy"), "title": .string("Airy"), "version": .string(serverVersion),
            ]),
            "instructions": .string(Self.instructions),
        ])
    }

    private func toolsList() -> JSONValue {
        .object(["tools": .array(registry.tools.map { tool in
            .object([
                "name": .string(tool.name),
                "description": .string(tool.description),
                "inputSchema": tool.inputSchema,
                "annotations": .object([
                    "readOnlyHint": .bool(tool.annotations.readOnly),
                    "destructiveHint": .bool(tool.annotations.destructive),
                    "idempotentHint": .bool(tool.annotations.idempotent),
                    "openWorldHint": .bool(false),
                ]),
            ])
        })])
    }

    private func toolsCall(id: JSONValue, params: JSONValue?) async -> String {
        guard let name = params?["name"]?.stringValue else {
            return Self.error(id: id, code: RPCError.invalidParams, message: "Falta el nombre de la herramienta.")
        }
        guard let tool = registry.tool(named: name) else {
            return Self.error(id: id, code: RPCError.invalidParams, message: "Herramienta desconocida: \(name).")
        }
        let arguments: [String: JSONValue]
        switch params?["arguments"] {
        case nil, .null?: arguments = [:]
        case .object(let object)?: arguments = object
        default:
            return Self.error(id: id, code: RPCError.invalidParams, message: "Los argumentos deben ser un objeto.")
        }
        let result: MCPToolResult
        if let problem = MCPSchemaValidator.violation(of: .object(arguments), against: tool.inputSchema) {
            result = .error("Argumentos no válidos para \(name): \(problem)")
        } else {
            result = await tool.call(arguments, context: MCPCallContext(environment: environment, client: clientName))
        }
        var payload: [String: JSONValue] = [
            "content": .array([.object(["type": .string("text"), "text": .string(result.text)])]),
            "isError": .bool(result.isError),
        ]
        // `structuredContent` debe ser un objeto y solo existe desde 2025-06-18.
        if let version = negotiatedVersion, version >= Self.structuredContentVersion,
           let structured = result.structured, case .object = structured {
            payload["structuredContent"] = structured
        }
        return Self.result(id: id, .object(payload))
    }

    // MARK: - Utilidades

    /// Sin caracteres de control, recortado y como mucho 64 caracteres; vacío ⇒ «agente».
    static func sanitisedClientName(_ raw: String?) -> String {
        guard let raw else { return defaultClientName }
        let scalars = raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let clean = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        let short = String(clean.prefix(maxClientNameLength))
        return short.isEmpty ? defaultClientName : short
    }

    private static func isValidID(_ id: JSONValue) -> Bool {
        switch id {
        case .string: true
        case .number: id.intValue != nil
        default: false
        }
    }

    private static func result(id: JSONValue, _ result: JSONValue) -> String {
        JSONValue.object(["jsonrpc": .string("2.0"), "id": id, "result": result]).compactString()
    }

    private static func error(id: JSONValue, code: Int, message: String) -> String {
        JSONValue.object([
            "jsonrpc": .string("2.0"), "id": id,
            "error": .object(["code": .number(Double(code)), "message": .string(message)]),
        ]).compactString()
    }
}
