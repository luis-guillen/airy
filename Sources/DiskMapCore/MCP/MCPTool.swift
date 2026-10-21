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

    /// `text` = summary + line break + the value as indented JSON.
    public static func ok(_ value: JSONValue, summary: String) -> MCPToolResult {
        MCPToolResult(text: summary + "\n" + value.prettyString(), structured: value, isError: false)
    }

    public static func error(_ message: String) -> MCPToolResult {
        MCPToolResult(text: message, structured: nil, isError: true)
    }
}

public struct MCPCallContext: Sendable {
    public let environment: AiryEnvironment
    /// Name of the MCP client (sanitized `clientInfo.name`), for the operation log.
    public let client: String

    public init(environment: AiryEnvironment, client: String) {
        self.environment = environment
        self.client = client
    }
}

/// An Airy MCP tool. The server validates the arguments against `inputSchema` before calling it.
public protocol MCPTool: Sendable {
    var name: String { get }
    /// Always in English (agents work best with stable English).
    var description: String { get }
    /// `type: object`, `additionalProperties: false`.
    var inputSchema: JSONValue { get }
    var annotations: MCPToolAnnotations { get }
    func call(_ arguments: [String: JSONValue], context: MCPCallContext) async -> MCPToolResult
}

public struct MCPToolRegistry: Sendable {
    public private(set) var tools: [any MCPTool]

    /// If two tools share a name, the last one wins.
    public init(_ tools: [any MCPTool]) {
        self.tools = []
        for tool in tools { self = self.adding(tool) }
    }

    /// Adds (or replaces, if there is already one with that name) a tool.
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

    /// Airy's tools. Task 12 adds the read tools, Task 13 the action tools.
    /// Plan 4 adds the Performance ones (`performanceTools()`).
    public static func standard() -> MCPToolRegistry {
        MCPToolRegistry(readTools() + actionTools() + performanceTools() + sectionTools())
    }

    /// Performance (plan 4): read and propose; an agent never quits an app.
    static func performanceTools() -> [any MCPTool] {
        [GetPerformanceTool(), ProposeQuitAppTool()]
    }

    /// Phase 2 sections: read apps, orphans, large files and duplicates, and propose uninstalling.
    static func sectionTools() -> [any MCPTool] {
        [ListAppsTool(), ExplainAppTool(), ListOrphansTool(), ListLargeOldTool(), ListDuplicatesTool(),
         ProposeUninstallTool()]
    }

    /// Read-only tools (Task 12).
    static func readTools() -> [any MCPTool] {
        [GetDiskSummaryTool(), ListLargestTool(), ExplainPathTool(), ListCleanupItemsTool()]
    }

    /// Action tools, always behind the safety funnel (Task 13).
    static func actionTools() -> [any MCPTool] {
        [RunSafeCleanupTool(), RunSafeCleanupAllTool(), ProposeCleanupTool(), ShowInAppTool(), RescanTool()]
    }
}

/// Validation of arguments against the subset of JSON Schema that Airy's tools use:
/// `type`, `properties`, `required`, `additionalProperties: false`, `enum`, `items`, `minimum`, `maximum`,
/// `minLength`, `maxLength`, `maxItems`. Returns the first problem, in English, or `nil`.
enum MCPSchemaValidator {
    static func violation(of value: JSONValue, against schema: JSONValue, at path: String = "arguments") -> String? {
        if let type = schema["type"]?.stringValue, !matches(value, type: type) {
            return "\(path): expected \(typeName(type))."
        }
        if case .array(let options)? = schema["enum"], !options.contains(value) {
            return "\(path): value not allowed."
        }
        if case .number(let n) = value {
            if case .number(let min)? = schema["minimum"], n < min { return "\(path): must be at least \(format(min))." }
            if case .number(let max)? = schema["maximum"], n > max { return "\(path): must be at most \(format(max))." }
        }
        if case .string(let s) = value {
            if let min = schema["minLength"]?.intValue, s.count < min { return "\(path): too short." }
            if let max = schema["maxLength"]?.intValue, s.count > max { return "\(path): too long (maximum \(max))." }
        }
        if case .array(let items) = value {
            if let max = schema["maxItems"]?.intValue, items.count > max { return "\(path): at most \(max) items." }
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
                    return "\(path): missing “\(key)”."
                }
            }
            if schema["additionalProperties"] == .bool(false) {
                for key in object.keys.sorted() where properties[key] == nil {
                    return "\(path): unknown parameter “\(key)”."
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
        case "object": "an object"
        case "array": "a list"
        case "string": "a string"
        case "boolean": "true or false"
        case "integer": "an integer"
        case "number": "a number"
        default: type
        }
    }

    private static func format(_ n: Double) -> String {
        n.rounded() == n ? String(Int64(n)) : String(n)
    }
}
