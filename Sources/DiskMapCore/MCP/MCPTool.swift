import Foundation

public struct MCPToolAnnotations: Sendable, Equatable {
    public var readOnly: Bool, destructive: Bool, idempotent: Bool

    public init(readOnly: Bool, destructive: Bool, idempotent: Bool) {
        self.readOnly = readOnly; self.destructive = destructive; self.idempotent = idempotent
    }
}

public struct MCPToolResult: Sendable, Equatable {
    public var text: String
    public var structured: JSONValue?
    public var isError: Bool

    public init(text: String, structured: JSONValue?, isError: Bool) {
        self.text = text; self.structured = structured; self.isError = isError
    }

    /// `text` = resumen + salto de línea + el valor como JSON con sangría.
    public static func ok(_ value: JSONValue, summary: String) -> MCPToolResult {
        MCPToolResult(text: summary + "\n" + value.prettyString(), structured: value, isError: false)
    }

    public static func error(_ message: String) -> MCPToolResult {
        MCPToolResult(text: message, structured: nil, isError: true)
    }
}

public struct MCPCallContext: Sendable {
    public let environment: AiryEnvironment
    /// Nombre del cliente MCP (`clientInfo.name` saneado), para el registro de operaciones.
    public let client: String

    public init(environment: AiryEnvironment, client: String) {
        self.environment = environment
        self.client = client
    }
}

/// Una herramienta MCP de Airy. El servidor valida los argumentos contra `inputSchema` antes de llamarla.
public protocol MCPTool: Sendable {
    var name: String { get }
    /// En español.
    var description: String { get }
    /// `type: object`, `additionalProperties: false`.
    var inputSchema: JSONValue { get }
    var annotations: MCPToolAnnotations { get }
    func call(_ arguments: [String: JSONValue], context: MCPCallContext) async -> MCPToolResult
}

public struct MCPToolRegistry: Sendable {
    public private(set) var tools: [any MCPTool]

    /// Si dos herramientas comparten nombre, gana la última.
    public init(_ tools: [any MCPTool]) {
        self.tools = []
        for tool in tools { self = self.adding(tool) }
    }

    /// Añade (o sustituye, si ya hay una con ese nombre) una herramienta.
    public func adding(_ tool: any MCPTool) -> MCPToolRegistry {
        var copy = self
        if let index = copy.tools.firstIndex(where: { $0.name == tool.name }) {
            copy.tools[index] = tool
        } else {
            copy.tools.append(tool)
        }
        return copy
    }

    public func tool(named name: String) -> (any MCPTool)? {
        tools.first { $0.name == name }
    }

    /// Herramientas de Airy. Task 12 añade las de lectura, Task 13 las de acción.
    /// Plan 4 añade las de Rendimiento (`performanceTools()`).
    public static func standard() -> MCPToolRegistry {
        MCPToolRegistry(readTools() + actionTools() + performanceTools())
    }

    /// Rendimiento (plan 4): leer y proponer; un agente nunca cierra una app.
    static func performanceTools() -> [any MCPTool] {
        [GetPerformanceTool(), ProposeQuitAppTool()]
    }

    /// Herramientas de solo lectura (Task 12).
    static func readTools() -> [any MCPTool] {
        [GetDiskSummaryTool(), ListLargestTool(), ExplainPathTool(), ListCleanupItemsTool()]
    }

    /// Herramientas de acción, siempre tras el embudo de seguridad (Task 13).
    static func actionTools() -> [any MCPTool] {
        [RunSafeCleanupTool(), RunSafeCleanupAllTool(), ProposeCleanupTool(), ShowInAppTool(), RescanTool()]
    }
}

/// Validación de argumentos contra el subconjunto de JSON Schema que usan las herramientas de Airy:
/// `type`, `properties`, `required`, `additionalProperties: false`, `enum`, `items`, `minimum`, `maximum`,
/// `minLength`, `maxLength`, `maxItems`. Devuelve el primer problema, en español, o `nil`.
enum MCPSchemaValidator {
    static func violation(of value: JSONValue, against schema: JSONValue, at path: String = "argumentos") -> String? {
        if let type = schema["type"]?.stringValue, !matches(value, type: type) {
            return "\(path): se esperaba \(typeName(type))."
        }
        if case .array(let options)? = schema["enum"], !options.contains(value) {
            return "\(path): valor no permitido."
        }
        if case .number(let n) = value {
            if case .number(let min)? = schema["minimum"], n < min { return "\(path): debe ser como mínimo \(format(min))." }
            if case .number(let max)? = schema["maximum"], n > max { return "\(path): debe ser como máximo \(format(max))." }
        }
        if case .string(let s) = value {
            if let min = schema["minLength"]?.intValue, s.count < min { return "\(path): demasiado corto." }
            if let max = schema["maxLength"]?.intValue, s.count > max { return "\(path): demasiado largo (máximo \(max))." }
        }
        if case .array(let items) = value {
            if let max = schema["maxItems"]?.intValue, items.count > max { return "\(path): como máximo \(max) elementos." }
            if let itemSchema = schema["items"] {
                for (i, item) in items.enumerated() {
                    if let problem = violation(of: item, against: itemSchema, at: "\(path)[\(i)]") { return problem }
                }
            }
        }
        if case .object(let object) = value {
            let properties: [String: JSONValue]
            if case .object(let p)? = schema["properties"] { properties = p } else { properties = [:] }
            if case .array(let required)? = schema["required"] {
                for key in required.compactMap(\.stringValue) where object[key] == nil {
                    return "\(path): falta «\(key)»."
                }
            }
            if schema["additionalProperties"] == .bool(false) {
                for key in object.keys.sorted() where properties[key] == nil {
                    return "\(path): parámetro desconocido «\(key)»."
                }
            }
            for key in object.keys.sorted() {
                if let propertySchema = properties[key], let child = object[key],
                   let problem = violation(of: child, against: propertySchema, at: key) {
                    return problem
                }
            }
        }
        return nil
    }

    private static func matches(_ value: JSONValue, type: String) -> Bool {
        switch (type, value) {
        case ("object", .object), ("array", .array), ("string", .string), ("boolean", .bool),
             ("number", .number), ("null", .null): true
        case ("integer", .number): value.intValue != nil
        default: false
        }
    }

    private static func typeName(_ type: String) -> String {
        switch type {
        case "object": "un objeto"
        case "array": "una lista"
        case "string": "un texto"
        case "boolean": "true o false"
        case "integer": "un número entero"
        case "number": "un número"
        default: type
        }
    }

    private static func format(_ n: Double) -> String {
        n.rounded() == n ? String(Int64(n)) : String(n)
    }
}
