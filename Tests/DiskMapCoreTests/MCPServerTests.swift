import Foundation
import Synchronization
import Testing
@testable import DiskMapCore

// MARK: - Dobles de prueba

/// Herramienta falsa: cuenta las llamadas y devuelve los argumentos recibidos.
final class FakeTool: MCPTool, Sendable {
    private let callCount = Mutex(0)
    var calls: Int { callCount.withLock { $0 } }

    var name: String { "fake_tool" }
    var description: String { "Herramienta de prueba." }
    var inputSchema: JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object(["type": .string("string")]),
                "limit": .object(["type": .string("integer")]),
                "dry_run": .object(["type": .string("boolean")]),
            ]),
            "required": .array([.string("path")]),
            "additionalProperties": .bool(false),
        ])
    }
    var annotations: MCPToolAnnotations { MCPToolAnnotations(readOnly: true, destructive: false, idempotent: true) }

    func call(_ arguments: [String: JSONValue], context: MCPCallContext) async -> MCPToolResult {
        callCount.withLock { $0 += 1 }
        return .ok(.object(["echo": arguments["path"] ?? .null, "client": .string(context.client)]), summary: "Hecho.")
    }
}

struct FakeOpener: URLOpening {
    func open(_ url: URL) async -> Bool { true }
}

func makeTestEnvironment(home: String) -> AiryEnvironment {
    let support = URL(fileURLWithPath: home).appendingPathComponent("support", isDirectory: true)
    let paths = AppPaths(support: support, legacySupport: nil)
    let runner = FakeRunner()
    return AiryEnvironment(
        home: home, paths: paths, catalog: Catalog(entries: []), catalogError: nil,
        settings: SettingsStore(file: paths.settingsFile), index: IndexStore(directory: support),
        log: OperationLog(file: paths.operationsFile), runner: runner, probes: FakeProbes(),
        processGuard: ProcessGuard(), references: ReferenceChecker(roots: []), urlOpener: FakeOpener(),
        capacity: { VolumeCapacity(total: 1000, available: 500, importantAvailable: 400) })
}

private func makeTempHome() -> String {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("airy-mcp-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.path
}

private func makeServer(_ tool: FakeTool = FakeTool()) -> MCPServer {
    MCPServer(registry: MCPToolRegistry([tool]), environment: makeTestEnvironment(home: makeTempHome()),
              serverVersion: "9.9.9")
}

private func parse(_ line: String?) throws -> JSONValue {
    let line = try #require(line)
    return try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
}

private func initialize(_ server: MCPServer, version: String) async throws -> JSONValue {
    let request = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"\#(version)","capabilities":{},"clientInfo":{"name":"prueba","version":"1"}}}"#
    return try parse(await server.handle(line: request))
}

private func callTool(_ server: MCPServer, arguments: String, name: String = "fake_tool") async throws -> JSONValue {
    try parse(await server.handle(line: #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"\#(name)","arguments":\#(arguments)}}"#))
}

// MARK: - Pruebas

@Test func initializeNegotiatesVersion() async throws {
    let echoed = try await initialize(makeServer(), version: "2025-06-18")
    #expect(echoed["result"]?["protocolVersion"]?.stringValue == "2025-06-18")
    #expect(echoed["result"]?["serverInfo"]?["name"]?.stringValue == "airy")
    #expect(echoed["result"]?["serverInfo"]?["title"]?.stringValue == "Airy")
    #expect(echoed["result"]?["serverInfo"]?["version"]?.stringValue == "9.9.9")
    #expect(echoed["result"]?["capabilities"]?["tools"]?["listChanged"]?.boolValue == false)
    #expect(echoed["result"]?["instructions"]?.stringValue?.contains("Sin problema") == true)
    #expect(echoed["id"]?.intValue == 1)
    #expect(echoed["jsonrpc"]?.stringValue == "2.0")

    let fallback = try await initialize(makeServer(), version: "1999-01-01")
    #expect(fallback["result"]?["protocolVersion"]?.stringValue == "2025-11-25")
    #expect(fallback["result"]?["serverInfo"]?["name"]?.stringValue == "airy")
}

@Test func notificationsGetNoResponse() async {
    let server = makeServer()
    #expect(await server.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
    // Las respuestas del cliente tampoco se contestan.
    #expect(await server.handle(line: #"{"jsonrpc":"2.0","id":5,"result":{}}"#) == nil)
    #expect(await server.handle(line: "   ") == nil)
}

@Test func pingReturnsEmptyResult() async throws {
    let response = try parse(await makeServer().handle(line: #"{"jsonrpc":"2.0","id":"a","method":"ping"}"#))
    #expect(response["result"] == .object([:]))
    #expect(response["id"]?.stringValue == "a")
}

@Test func toolsListListsRegistry() async throws {
    let response = try parse(await makeServer().handle(line: #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))
    guard case .array(let tools)? = response["result"]?["tools"] else {
        Issue.record("sin lista de herramientas"); return
    }
    #expect(tools.count == 1)
    let tool = tools[0]
    #expect(tool["name"]?.stringValue == "fake_tool")
    #expect(tool["description"]?.stringValue == "Herramienta de prueba.")
    #expect(tool["inputSchema"] == FakeTool().inputSchema)
    #expect(tool["annotations"] == .object([
        "readOnlyHint": .bool(true), "destructiveHint": .bool(false),
        "idempotentHint": .bool(true), "openWorldHint": .bool(false),
    ]))
}

@Test func unknownMethodIs32601() async throws {
    let response = try parse(await makeServer().handle(line: #"{"jsonrpc":"2.0","id":3,"method":"resources/list"}"#))
    #expect(response["error"]?["code"]?.intValue == -32601)
    #expect(response["id"]?.intValue == 3)
}

@Test func parseErrorIs32700WithNullID() async throws {
    let response = try parse(await makeServer().handle(line: #"{"jsonrpc":"2.0","id":4,"method":"#))
    #expect(response["error"]?["code"]?.intValue == -32700)
    #expect(response["id"] == .null)
}

@Test func batchArrayIsRejected() async throws {
    let response = try parse(await makeServer().handle(line: #"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#))
    #expect(response["error"]?["code"]?.intValue == -32600)
    #expect(response["id"] == .null)
    // Tampoco vale una petición sin "jsonrpc": "2.0".
    let noVersion = try parse(await makeServer().handle(line: #"{"id":1,"method":"ping"}"#))
    #expect(noVersion["error"]?["code"]?.intValue == -32600)
}

@Test func unknownToolIs32602() async throws {
    let tool = FakeTool()
    let response = try await callTool(makeServer(tool), arguments: #"{"path":"/x"}"#, name: "rm_rf")
    #expect(response["error"]?["code"]?.intValue == -32602)
    #expect(response["id"]?.intValue == 7)
    #expect(tool.calls == 0)
}

@Test func schemaViolationIsToolError() async throws {
    let tool = FakeTool()
    let server = makeServer(tool)
    for bad in [#"{}"#, #"{"path":3}"#, #"{"path":"/x","limit":1.5}"#, #"{"path":"/x","extra":true}"#] {
        let response = try await callTool(server, arguments: bad)
        #expect(response["error"] == nil, "\(bad)")
        #expect(response["result"]?["isError"]?.boolValue == true, "\(bad)")
        guard case .array(let content)? = response["result"]?["content"] else {
            Issue.record("sin contenido: \(bad)"); continue
        }
        #expect(content.first?["type"]?.stringValue == "text")
        #expect(content.first?["text"]?.stringValue?.isEmpty == false)
    }
    #expect(tool.calls == 0)

    let good = try await callTool(server, arguments: #"{"path":"/x","limit":2,"dry_run":true}"#)
    #expect(good["result"]?["isError"]?.boolValue == false)
    #expect(tool.calls == 1)
}

@Test func structuredContentOnlyFromJune2025() async throws {
    let old = makeServer()
    _ = try await initialize(old, version: "2025-03-26")
    let oldResult = try await callTool(old, arguments: #"{"path":"/x"}"#)
    #expect(oldResult["result"]?["structuredContent"] == nil)
    guard case .array(let content)? = oldResult["result"]?["content"] else {
        Issue.record("sin contenido"); return
    }
    #expect(content.first?["text"]?.stringValue?.hasPrefix("Hecho.\n") == true)

    let new = makeServer()
    _ = try await initialize(new, version: "2025-06-18")
    let newResult = try await callTool(new, arguments: #"{"path":"/x"}"#)
    #expect(newResult["result"]?["structuredContent"]?["echo"]?.stringValue == "/x")
    // El nombre del cliente llega a la herramienta.
    #expect(newResult["result"]?["structuredContent"]?["client"]?.stringValue == "prueba")
}

@Test func transportWritesOneJSONLinePerResponse() async throws {
    let input = Pipe(), output = Pipe()
    let lines = [
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"prueba","version":"1"}}}"#,
        #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
        #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#,
    ]
    try input.fileHandleForWriting.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
    try input.fileHandleForWriting.close()
    await StdioTransport.run(server: makeServer(), input: input.fileHandleForReading, output: output.fileHandleForWriting)
    try output.fileHandleForWriting.close()
    let data = try output.fileHandleForReading.readToEnd() ?? Data()
    let text = String(decoding: data, as: UTF8.self)
    #expect(text.hasSuffix("\n"))
    let responses = text.split(separator: "\n").map(String.init)
    #expect(responses.count == 2)
    let first = try parse(responses.first)
    let second = try parse(responses.last)
    #expect(first["result"]?["serverInfo"]?["name"]?.stringValue == "airy")
    #expect(second["id"]?.intValue == 2)
    #expect(second["result"] == .object([:]))
}

@Test func catalogFoundFromBundledHelperLayout() throws {
    // Copia el bundle de recursos real a tmp/X.app/Contents/Resources y busca desde Contents/MacOS/airy-mcp.
    let source = try #require(
        Bundle.allBundles.map { $0.bundleURL.deletingLastPathComponent().appendingPathComponent(Catalog.bundleName) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
        ?? [Bundle(for: FakeTool.self).bundleURL.deletingLastPathComponent().appendingPathComponent(Catalog.bundleName)]
            .first { FileManager.default.fileExists(atPath: $0.path) })
    let app = URL(fileURLWithPath: makeTempHome()).appendingPathComponent("X.app/Contents", isDirectory: true)
    let resources = app.appendingPathComponent("Resources", isDirectory: true)
    let macOS = app.appendingPathComponent("MacOS", isDirectory: true)
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: source, to: resources.appendingPathComponent(Catalog.bundleName))
    let catalog = try Catalog.bundled(executableURL: macOS.appendingPathComponent("airy-mcp"), searchProcessBundles: false)
    #expect(!catalog.entries.isEmpty)

    // Sin el bundle en Resources (y sin buscar en los del proceso) no lo encuentra.
    let empty = URL(fileURLWithPath: makeTempHome()).appendingPathComponent("Y.app/Contents/MacOS/airy-mcp")
    #expect(throws: CatalogError.self) {
        try Catalog.bundled(executableURL: empty, searchProcessBundles: false)
    }
}
