import Foundation
import Synchronization
import Testing
@testable import DiskMapCore

// MARK: - Test double

/// Runner that returns a fixed output (or throws) and records arguments, stdin and directory.
final class AIFakeRunner: CommandRunning, Sendable {
    struct Call: Sendable {
        var executable: String
        var arguments: [String]
        var stdin: String?
        var workingDirectory: String?
        var timeout: TimeInterval
    }

    private let state = Mutex<[Call]>([])
    let stdout: String
    let status: Int32
    let error: (any Error & Sendable)?
    let lines: [String]

    init(stdout: String = "", status: Int32 = 0, error: (any Error & Sendable)? = nil, lines: [String] = []) {
        self.stdout = stdout
        self.status = status
        self.error = error
        self.lines = lines
    }

    var calls: [Call] { state.withLock { $0 } }

    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> CommandOutput {
        try await run(executable, arguments, stdin: nil, workingDirectory: nil, timeout: timeout)
    }

    func run(_ executable: String, _ arguments: [String], stdin: String?, workingDirectory: String?,
             timeout: TimeInterval) async throws -> CommandOutput {
        state.withLock {
            $0.append(Call(executable: executable, arguments: arguments, stdin: stdin,
                           workingDirectory: workingDirectory, timeout: timeout))
        }
        if let error { throw error }
        return CommandOutput(status: status, stdout: stdout, stderr: "")
    }

    func stream(_ executable: String, _ arguments: [String], stdin: String?, workingDirectory: String?,
                timeout: TimeInterval) -> AsyncThrowingStream<String, Error> {
        state.withLock {
            $0.append(Call(executable: executable, arguments: arguments, stdin: stdin,
                           workingDirectory: workingDirectory, timeout: timeout))
        }
        let lines = lines
        let error = error
        return AsyncThrowingStream { continuation in
            for line in lines { continuation.yield(line) }
            if let error { continuation.finish(throwing: error) } else { continuation.finish() }
        }
    }

    func resolve(_ executable: String) async -> String? { nil }
}

// MARK: - Utilities

private func tempDir(_ label: String = "airy-ai") -> String {
    let url = TestTemp.url("\(label)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.path
}

private let home = "/Users/prueba"

private let uvEntry = CatalogEntry(
    id: "uv", title: "uv cache", explanation: "Downloaded Python packages.", whoCreatesIt: "uv",
    regenerates: true, risk: .safe, kind: .caches, paths: ["~/.cache/uv"],
    cleanup: .command(executable: "uv", arguments: ["cache", "clean"], sizeProbe: nil))

private let snapshotsEntry = CatalogEntry(
    id: "snapshots", title: "Snapshots", explanation: "", whoCreatesIt: "Time Machine",
    regenerates: false, risk: .yourCall, kind: .system, paths: [], cleanup: .info)

private let xCacheEntry = CatalogEntry(
    id: "xcache", title: "X cache", explanation: "", whoCreatesIt: "X", regenerates: true,
    risk: .safe, kind: .caches, paths: ["~/Library/Caches/x"], cleanup: .trash)

private let homebrewEntry = CatalogEntry(
    id: "homebrew", title: "Homebrew", explanation: "", whoCreatesIt: "brew", regenerates: true,
    risk: .safe, kind: .caches, paths: ["~/Library/Caches/Homebrew"],
    cleanup: .command(executable: "brew", arguments: ["cleanup"], sizeProbe: nil))

private let dockerBuildEntry = CatalogEntry(
    id: "docker-build-cache", title: "Docker build cache", explanation: "", whoCreatesIt: "Docker",
    regenerates: true, risk: .safe, kind: .containers, paths: [],
    cleanup: .command(executable: "docker", arguments: ["builder", "prune", "-a", "-f"], sizeProbe: nil))

private let dockerVolumesEntry = CatalogEntry(
    id: "docker-volumes", title: "Docker volumes", explanation: "", whoCreatesIt: "Docker",
    regenerates: false, risk: .doNotTouch, kind: .containers,
    paths: ["~/Library/Containers/com.docker.docker"], cleanup: .info)

private let testCatalog = Catalog(entries: [
    uvEntry, snapshotsEntry, xCacheEntry, homebrewEntry, dockerBuildEntry, dockerVolumesEntry,
])

/// Tree: /Users/prueba → .cache/uv (5 GB), Documents/a.pdf (1 GB), Library/Caches/x (2 GB),
/// Library/Containers/com.docker.docker (3 GB), Library/Mobile Documents (4 GB).
private func sampleTree() -> FileNode {
    let uv = FileNode(name: "uv", isDirectory: true, allocatedSize: 5_000_000_000, kind: .caches)
    let cache = FileNode(name: ".cache", isDirectory: true, allocatedSize: 5_000_000_000, children: [uv])
    let pdf = FileNode(name: "a.pdf", isDirectory: false, allocatedSize: 1_000_000_000, kind: .documents)
    let docs = FileNode(name: "Documents", isDirectory: true, allocatedSize: 1_000_000_000, children: [pdf])
    let x = FileNode(name: "x", isDirectory: true, allocatedSize: 2_000_000_000, kind: .caches)
    let caches = FileNode(name: "Caches", isDirectory: true, allocatedSize: 2_000_000_000, children: [x])
    let docker = FileNode(name: "com.docker.docker", isDirectory: true, allocatedSize: 3_000_000_000, kind: .containers)
    let containers = FileNode(name: "Containers", isDirectory: true, allocatedSize: 3_000_000_000, children: [docker])
    let icloud = FileNode(name: "Mobile Documents", isDirectory: true, allocatedSize: 4_000_000_000, kind: .documents)
    let library = FileNode(name: "Library", isDirectory: true, allocatedSize: 9_000_000_000,
                           children: [caches, containers, icloud])
    return FileNode(name: home, isDirectory: true, allocatedSize: 15_000_000_000, children: [cache, docs, library])
}

private func sampleContext() -> String {
    let item = CleanupItem(id: "uv", entry: uvEntry, paths: [home + "/.cache/uv"], bytes: 5_000_000_000,
                           risk: .safe, blockedByOpenApps: [], usedBy: [])
    let build = CleanupItem(id: "docker-build-cache", entry: dockerBuildEntry, paths: [], bytes: 29_000_000_000,
                            risk: .safe, blockedByOpenApps: [], usedBy: [])
    return AIContextBuilder.context(scan: sampleTree(), items: [item, build], catalog: testCatalog, home: home)
}

/// Output of `claude -p --output-format json --json-schema …` with the given `structured_output`.
private func claudeResult(_ structured: String) -> String {
    """
    {"type":"result","subtype":"success","is_error":false,"result":"","total_cost_usd":0.01,\
    "structured_output":\(structured)}
    """
}

private func assistant(_ runner: AIFakeRunner) -> AIAssistant {
    AIAssistant(claudePath: "/opt/claude", runner: runner, catalog: testCatalog, home: home)
}

private func parse(_ json: String) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
}

/// Real trimmed sample of `--output-format stream-json --verbose --include-partial-messages`
/// (Claude Code 2.1.304), with the texts replaced by "Ho", "la", "!".
private let streamFixture = [
    #"{"type":"system","subtype":"init","cwd":"/tmp/x","session_id":"s","tools":[],"mcp_servers":[],"model":"claude-opus-5-5"}"#,
    #"{"type":"system","subtype":"status","status":"requesting","session_id":"s"}"#,
    #"{"type":"stream_event","event":{"type":"message_start","message":{"id":"msg_1","role":"assistant","content":[]}},"session_id":"s"}"#,
    #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}},"session_id":"s"}"#,
    #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Ho"}},"session_id":"s","parent_tool_use_id":null}"#,
    #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"la"}},"session_id":"s","parent_tool_use_id":null}"#,
    #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"!"}},"session_id":"s","parent_tool_use_id":null}"#,
    #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Hola!"}]},"session_id":"s"}"#,
    #"{"type":"stream_event","event":{"type":"content_block_stop","index":0},"session_id":"s"}"#,
    #"{"type":"stream_event","event":{"type":"message_delta","delta":{"stop_reason":"end_turn"}},"session_id":"s"}"#,
    #"{"type":"stream_event","event":{"type":"message_stop"},"session_id":"s"}"#,
    #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed"},"session_id":"s"}"#,
    #"{"type":"result","subtype":"success","is_error":false,"result":"Hola!","total_cost_usd":0.005,"session_id":"s"}"#,
]

@Suite struct AITests {
    // MARK: Locator

    @Test func candidatesInOrder() {
        #expect(ClaudeLocator.candidates(home: "/Users/a") == [
            "/Users/a/.local/bin/claude", "/Users/a/.claude/local/claude", "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude", "/Users/a/.npm-global/bin/claude",
        ])
    }

    @Test func locatorSkipsCmuxShim() async throws {
        let dir = tempDir()
        let shim = dir + "/shim/claude"
        let real = dir + "/.local/bin/claude"
        for (path, text) in [
            (shim, "#!/usr/bin/env bash\ncmux_wrapper=\"/Applications/cmux.app/bin/cmux-claude-wrapper\"\n"),
            (real, "#!/bin/sh\necho real\n"),
        ] {
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: path, contents: Data(text.utf8),
                                           attributes: [.posixPermissions: 0o755])
        }
        let version = CommandOutput(status: 0, stdout: "2.1.304 (Claude Code)\n", stderr: "")
        let runner = FakeRunner(outputs: ["\(shim) --version": version, "\(real) --version": version])
        let found = await ClaudeLocator.locate(override: shim, runner: runner, home: dir)
        #expect(found == real)
        #expect(!runner.calls.contains { $0.executable == shim })
        #expect(runner.calls.first?.timeout == 10)
    }

    @Test func locatorRequiresClaudeCodeVersion() async throws {
        let dir = tempDir()
        let other = dir + "/claude"
        FileManager.default.createFile(atPath: other, contents: Data("#!/bin/sh\n".utf8),
                                       attributes: [.posixPermissions: 0o755])
        let runner = FakeRunner(outputs: ["\(other) --version": CommandOutput(status: 0, stdout: "1.0 other", stderr: "")])
        #expect(await ClaudeLocator.locate(override: other, runner: runner, home: dir + "/nadie") == nil)
    }

    // MARK: Invocation

    @Test func invokesWithoutTools() async throws {
        let runner = AIFakeRunner(stdout: claudeResult(#"{"summary":"ok","recommendations":[],"reclaimableBytes":0}"#))
        _ = try await assistant(runner).report(context: sampleContext())
        let call = try #require(runner.calls.first)
        let args = call.arguments
        let tools = try #require(args.firstIndex(of: "--tools"))
        #expect(args[tools + 1] == "")
        #expect(args.contains("--json-schema"))
        #expect(args.starts(with: ["-p"]))
        for flag in ["--strict-mcp-config", "--disable-slash-commands", "--no-session-persistence"] {
            #expect(args.contains(flag))
        }
        let format = try #require(args.firstIndex(of: "--output-format"))
        #expect(args[format + 1] == "json")
        let schema = try #require(args.firstIndex(of: "--json-schema"))
        let schemaJSON = try parse(args[schema + 1])
        #expect(schemaJSON["type"] as? String == "object")
        #expect(args[schema + 1].contains("doNotTouch"))
        let system = try #require(args.firstIndex(of: "--system-prompt"))
        #expect(args[system + 1].contains("Always reply in English"))
        // Airy computes the totals: Claude's summary does not give them.
        #expect(args[system + 1].contains("do not give totals"))
        // The prompt goes through stdin, not as an argument; never inside a user directory.
        #expect(call.stdin?.contains("~/.cache/uv") == true)
        #expect(!args.contains { $0.contains("~/.cache/uv") })
        #expect(call.timeout == 120)
        let cwd = try #require(call.workingDirectory)
        #expect(cwd.hasPrefix(NSTemporaryDirectory()) || cwd.hasPrefix("/private/var") || cwd.hasPrefix("/var"))
        #expect(!FileManager.default.fileExists(atPath: cwd))  // deleted at the end
    }

    // MARK: Context

    @Test func contextHasNoFileContents() async throws {
        let dir = tempDir()
        let file = dir + "/nota.txt"
        FileManager.default.createFile(atPath: file, contents: Data(String(repeating: "SECRET ", count: 2000).utf8))
        let scan = try await DiskScanner(options: ScanOptions(roots: [URL(fileURLWithPath: dir)], pruneThreshold: 0))
            .scan { _ in }
        let context = AIContextBuilder.context(scan: scan.root, items: [], catalog: testCatalog, home: home)
        #expect(!context.contains("SECRETO"))
        #expect(context.contains("nota.txt"))
        #expect(context.contains(scan.root.path + "/nota.txt"))
        _ = try parse(context)
    }

    @Test func contextKeepsUnicodePaths() throws {
        let leaf = FileNode(name: "diseño ñ", isDirectory: true, allocatedSize: 10_000)
        let music = FileNode(name: "Música", isDirectory: true, allocatedSize: 10_000, children: [leaf])
        let root = FileNode(name: home, isDirectory: true, allocatedSize: 10_000, children: [music])
        let context = AIContextBuilder.context(scan: root, items: [], catalog: testCatalog, home: home,
                                               diskTotal: 1_000, diskFree: 400)
        #expect(context.contains("~/Música/diseño ñ"))
        let json = try parse(context)
        let nodes = try #require(json["nodes"] as? [[String: Any]])
        #expect(nodes.contains { $0["path"] as? String == "~/Música/diseño ñ" })
        let disk = try #require(json["disk"] as? [String: Any])
        #expect(disk["totalBytes"] as? Int == 1_000)
        #expect(disk["freeBytes"] as? Int == 400)
    }

    @Test func contextIsBounded() throws {
        let children = (0..<10_000).map {
            FileNode(name: "f\($0)", isDirectory: false, allocatedSize: Int64($0 + 1))
        }
        let root = FileNode(name: "/datos", isDirectory: true, allocatedSize: 50_005_000, children: children)
        let context = AIContextBuilder.context(scan: root, items: [], catalog: testCatalog, home: home)
        let nodes = try #require(try parse(context)["nodes"] as? [[String: Any]])
        #expect(nodes.count <= 400)
        #expect(nodes.contains { $0["path"] as? String == "/datos/f9999" })  // the largest ones
        #expect(!nodes.contains { $0["path"] as? String == "/datos/f0" })
    }

    @Test func contextLimitsDepthAndListsCleanupItems() throws {
        var node = FileNode(name: "n8", isDirectory: true, allocatedSize: 100)
        for level in stride(from: 7, through: 1, by: -1) {
            node = FileNode(name: "n\(level)", isDirectory: true, allocatedSize: 100, children: [node])
        }
        let root = FileNode(name: home, isDirectory: true, allocatedSize: 100, children: [node])
        let item = CleanupItem(id: "uv", entry: uvEntry, paths: [home + "/.cache/uv"], bytes: 5,
                               risk: .safe, blockedByOpenApps: [], usedBy: [])
        let json = try parse(AIContextBuilder.context(scan: root, items: [item], catalog: testCatalog, home: home))
        let paths = try #require(json["nodes"] as? [[String: Any]]).compactMap { $0["path"] as? String }
        #expect(paths.contains("~/n1/n2/n3/n4/n5/n6"))
        #expect(!paths.contains("~/n1/n2/n3/n4/n5/n6/n7"))
        let items = try #require(json["cleanupItems"] as? [[String: Any]])
        #expect(items.first?["catalogId"] as? String == "uv")
        #expect(items.first?["paths"] as? [String] == ["~/.cache/uv"])
    }

    @Test func contextMarksCatalogMatches() throws {
        let json = try parse(sampleContext())
        let nodes = try #require(json["nodes"] as? [[String: Any]])
        let uv = try #require(nodes.first { $0["path"] as? String == "~/.cache/uv" })
        #expect(uv["catalogId"] as? String == "uv")
        #expect(uv["kind"] as? String == "caches")
    }

    // MARK: Post-validation of the report

    @Test func reportDropsUnknownPaths() async throws {
        let runner = AIFakeRunner(stdout: claudeResult("""
        {"summary":"s","reclaimableBytes":99999999999,"recommendations":[
          {"path":"~/.cache/uv","verdict":"safe","reason":"cache","bytes":5000000000,
           "action":{"type":"runCatalogCommand","id":"uv"}},
          {"path":"~/inventada","verdict":"safe","reason":"x","bytes":1,"action":{"type":"trash","path":"~/inventada"}},
          {"path":"/etc","verdict":"safe","reason":"x","bytes":1}
        ]}
        """))
        let report = try await assistant(runner).report(context: sampleContext())
        #expect(report.recommendations.map(\.path) == [home + "/.cache/uv"])
        #expect(report.recommendations.first?.action == .runCatalogCommand(id: "uv"))
        #expect(report.recommendations.first?.verdict == .safe)
        #expect(report.reclaimableBytes == 5_000_000_000)  // recomputed, not the AI's
    }

    @Test func reportDropsUnknownCatalogIds() async throws {
        let runner = AIFakeRunner(stdout: claudeResult("""
        {"summary":"s","reclaimableBytes":0,"recommendations":[
          {"path":"~/.cache/uv","verdict":"safe","reason":"r","bytes":1,"action":{"type":"runCatalogCommand","id":"rm-rf"}},
          {"path":"~/Library/Caches/x","verdict":"safe","reason":"r","bytes":1,
           "action":{"type":"runCatalogCommand","id":"snapshots"}}
        ]}
        """))
        let report = try await assistant(runner).report(context: sampleContext())
        #expect(report.recommendations.count == 2)
        #expect(report.recommendations.allSatisfy { $0.action == nil })  // nonexistent id or info kind
    }

    @Test func reportDropsTrashOfPathNotInContext() async throws {
        let runner = AIFakeRunner(stdout: claudeResult("""
        {"summary":"s","reclaimableBytes":0,"recommendations":[
          {"path":"~/Library/Caches","verdict":"safe","reason":"r","bytes":1,"action":{"type":"trash","path":"~/Library"}},
          {"path":"~/Documents","verdict":"safe","reason":"r","bytes":1,"action":{"type":"trash","path":"~/Documentos"}},
          {"path":"~/Library/Caches/x","verdict":"safe","reason":"r","bytes":1,"action":{"type":"trash","path":"~/Library/Caches/x"}}
        ]}
        """))
        let report = try await assistant(runner).report(context: sampleContext())
        #expect(report.recommendations.count == 3)
        #expect(report.recommendations[0].action == nil)  // ~/Library is in the context, but it is not the recommended path
        #expect(report.recommendations[1].action == nil)  // path not present in the context
        #expect(report.recommendations[1].verdict == .yourCall)
        let x = report.recommendations[2]
        #expect(x.action == .trash(path: home + "/Library/Caches/x"))  // Trash entry, safe
        #expect(x.verdict == .safe)
        #expect(x.bytes == 2_000_000_000)  // the context's size, not the AI's
        #expect(report.reclaimableBytes == 2_000_000_000)
    }

    @Test func reportNeverTrashesUncataloguedOrProtectedPaths() async throws {
        let runner = AIFakeRunner(stdout: claudeResult("""
        {"summary":"s","reclaimableBytes":0,"recommendations":[
          {"path":"~","verdict":"safe","reason":"r","bytes":1,"action":{"type":"trash","path":"~"}},
          {"path":"~/Library/Containers/com.docker.docker","verdict":"safe","reason":"r","bytes":1,
           "action":{"type":"trash","path":"~/Library/Containers/com.docker.docker"}},
          {"path":"~/Library/Mobile Documents","verdict":"safe","reason":"r","bytes":1,
           "action":{"type":"trash","path":"~/Library/Mobile Documents"}},
          {"path":"~/Library/Containers","verdict":"safe","reason":"r","bytes":1,
           "action":{"type":"trash","path":"~/Library/Containers"}}
        ]}
        """))
        let report = try await assistant(runner).report(context: sampleContext())
        #expect(report.recommendations.count == 4)
        for rec in report.recommendations {
            #expect(rec.action == nil, "\(rec.path)")
            #expect(rec.verdict != .safe, "\(rec.path)")
        }
        #expect(report.recommendations[1].verdict == .doNotTouch)  // docker-volumes entry
        #expect(report.reclaimableBytes == 0)
    }

    @Test func reportNeverTrashesCommandCaches() async throws {
        let runner = AIFakeRunner(stdout: claudeResult("""
        {"summary":"s","reclaimableBytes":0,"recommendations":[
          {"path":"~/.cache/uv","verdict":"safe","reason":"r","bytes":1,"action":{"type":"trash","path":"~/.cache/uv"}}
        ]}
        """))
        let rec = try #require(try await assistant(runner).report(context: sampleContext()).recommendations.first)
        #expect(rec.action == nil)  // uv is only cleaned with `uv cache clean`
        #expect(rec.verdict == .safe)
    }

    @Test func reportCommandMustMatchRecommendation() async throws {
        let runner = AIFakeRunner(stdout: claudeResult("""
        {"summary":"s","reclaimableBytes":0,"recommendations":[
          {"path":"~/Documents/a.pdf","verdict":"safe","reason":"r","bytes":1,"action":{"type":"runCatalogCommand","id":"homebrew"}},
          {"path":"~/.cache/uv","verdict":"safe","reason":"r","bytes":1,"action":{"type":"runCatalogCommand","id":"homebrew"}},
          {"path":"docker-build-cache","verdict":"safe","reason":"r","bytes":1,
           "action":{"type":"runCatalogCommand","id":"docker-build-cache"}}
        ]}
        """))
        let report = try await assistant(runner).report(context: sampleContext())
        #expect(report.recommendations.count == 3)
        #expect(report.recommendations[0].action == nil)
        #expect(report.recommendations[1].action == nil)
        let build = report.recommendations[2]
        #expect(build.action == .runCatalogCommand(id: "docker-build-cache"))
        #expect(build.verdict == .safe)
        #expect(build.bytes == 29_000_000_000)
        #expect(report.reclaimableBytes == 29_000_000_000)
    }

    @Test func reportCannotLowerRisk() async throws {
        let runner = AIFakeRunner(stdout: claudeResult("""
        {"summary":"s","reclaimableBytes":1000000000,"recommendations":[
          {"path":"~/Documents/a.pdf","verdict":"safe","reason":"old","bytes":1000000000,
           "action":{"type":"trash","path":"~/Documents/a.pdf"}}
        ]}
        """))
        let report = try await assistant(runner).report(context: sampleContext())
        let rec = try #require(report.recommendations.first)
        #expect(rec.verdict == .yourCall)
        #expect(rec.action == nil)
        #expect(report.reclaimableBytes == 0)
    }

    @Test func reportFailsGracefullyOnInvalidJSON() async throws {
        let runner = AIFakeRunner(stdout: "hola")
        await #expect {
            _ = try await assistant(runner).report(context: sampleContext())
        } throws: { error in
            if case AIError.invalidResponse = error { return true }
            return false
        }
    }

    @Test func reportFailsOnErrorResult() async throws {
        let runner = AIFakeRunner(
            stdout: #"{"type":"result","subtype":"success","is_error":true,"result":"Not logged in · Please run /login"}"#,
            status: 1)
        await #expect {
            _ = try await assistant(runner).report(context: sampleContext())
        } throws: { error in
            if case AIError.failed(let message) = error { return message.contains("Not logged in") }
            return false
        }
        let noStructured = AIFakeRunner(stdout: #"{"type":"result","is_error":false,"result":"texto"}"#)
        await #expect {
            _ = try await assistant(noStructured).report(context: sampleContext())
        } throws: { error in
            if case AIError.invalidResponse = error { return true }
            return false
        }
    }

    @Test func reportTimesOut() async throws {
        let runner = AIFakeRunner(error: CommandError.timedOut(executable: "/opt/claude", seconds: 120))
        await #expect {
            _ = try await assistant(runner).report(context: sampleContext())
        } throws: { error in
            if case AIError.timedOut = error { return true }
            return false
        }
    }

    @Test func recommendationDecodesVerdictNames() throws {
        let json = #"{"id":"a","path":"/x","verdict":"doNotTouch","reason":"r","bytes":3,"action":{"type":"trash","path":"/x"}}"#
        let rec = try JSONDecoder().decode(AIRecommendation.self, from: Data(json.utf8))
        #expect(rec.verdict == .doNotTouch)
        #expect(rec.action == .trash(path: "/x"))
        let encoded = String(decoding: try JSONEncoder().encode(rec), as: UTF8.self)
        #expect(encoded.contains("\"doNotTouch\""))
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(AIRecommendation.self, from: Data(#"{"path":"/x","verdict":"maybe","reason":"","bytes":0}"#.utf8))
        }
    }

    // MARK: Chat

    @Test func chatStreamsDeltas() async throws {
        let runner = AIFakeRunner(lines: streamFixture)
        let history = [
            ChatMessage(role: .user, text: "What takes the most space?"),
            ChatMessage(role: .assistant, text: "The uv cache."),
            ChatMessage(role: .user, text: "Can I delete it?"),
        ]
        var received: [String] = []
        for try await chunk in assistant(runner).chat(history: history, context: sampleContext()) {
            received.append(chunk)
        }
        #expect(received == ["Ho", "la", "!"])
        let call = try #require(runner.calls.first)
        let format = try #require(call.arguments.firstIndex(of: "--output-format"))
        #expect(call.arguments[format + 1] == "stream-json")
        for flag in ["--verbose", "--include-partial-messages", "--strict-mcp-config"] {
            #expect(call.arguments.contains(flag))
        }
        let tools = try #require(call.arguments.firstIndex(of: "--tools"))
        #expect(call.arguments[tools + 1] == "")
        let stdin = try #require(call.stdin)
        // Full history with labelled turns, and the context.
        for text in ["What takes the most space?", "The uv cache.", "Can I delete it?", "~/.cache/uv"] {
            #expect(stdin.contains(text))
        }
        #expect(stdin.contains("User:") && stdin.contains("Assistant:"))
        #expect(call.timeout == 120)
    }

    @Test func chatFailsOnErrorResult() async throws {
        let runner = AIFakeRunner(lines: [
            #"{"type":"result","subtype":"success","is_error":true,"result":"Not logged in"}"#,
        ])
        await #expect {
            for try await _ in assistant(runner).chat(history: [ChatMessage(role: .user, text: "hola")],
                                                      context: sampleContext()) {}
        } throws: { error in
            if case AIError.failed = error { return true }
            return false
        }
    }

    @Test func chatMapsTimeout() async throws {
        let runner = AIFakeRunner(error: CommandError.timedOut(executable: "/opt/claude", seconds: 120),
                                  lines: [streamFixture[4]])
        var received: [String] = []
        await #expect {
            for try await chunk in assistant(runner).chat(history: [ChatMessage(role: .user, text: "hola")],
                                                          context: sampleContext()) {
                received.append(chunk)
            }
        } throws: { error in
            if case AIError.timedOut = error { return true }
            return false
        }
        #expect(received == ["Ho"])
    }

    // MARK: ProcessRunner (stdin, directory and streaming)

    @Test func processRunnerPassesStdinAndDirectory() async throws {
        let dir = tempDir()
        let output = try await ProcessRunner().run(
            "/bin/sh", ["-c", "pwd; cat"], stdin: "line with ñ and \"quotes\"\n", workingDirectory: dir, timeout: 5)
        let lines = output.stdout.split(separator: "\n").map(String.init)
        #expect(lines.first.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
                == URL(fileURLWithPath: dir).resolvingSymlinksInPath().path)
        #expect(lines.last == "line with ñ and \"quotes\"")
    }

    @Test func processRunnerStreamsLines() async throws {
        var lines: [String] = []
        for try await line in ProcessRunner().stream(
            "/bin/sh", ["-c", "cat; echo dos; printf tres"], stdin: "uno\n", workingDirectory: nil, timeout: 5) {
            lines.append(line)
        }
        #expect(lines == ["uno", "dos", "tres"])
    }

    @Test func processRunnerStreamTimesOut() async throws {
        await #expect(throws: CommandError.self) {
            for try await _ in ProcessRunner().stream(
                "/bin/sh", ["-c", "echo uno; sleep 30"], stdin: nil, workingDirectory: nil, timeout: 1) {}
        }
    }

    @Test func processRunnerStreamCancelKillsProcess() async throws {
        let started = Date()
        var pid: pid_t = 0
        for try await line in ProcessRunner().stream(
            "/bin/sh", ["-c", "echo $$; exec /bin/sleep 30"], stdin: nil, workingDirectory: nil, timeout: 60) {
            pid = pid_t(line) ?? 0
            break  // the consumer stops reading: the stream is cancelled
        }
        #expect(pid > 0)
        var alive = true
        for _ in 0..<60 where alive {
            alive = kill(pid, 0) == 0
            if alive { try await Task.sleep(for: .milliseconds(50)) }
        }
        #expect(!alive)
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func processRunnerStreamCapsLineLength() async throws {
        await #expect {
            for try await _ in ProcessRunner().stream(
                "/bin/sh", ["-c", "head -c 5000000 /dev/zero | tr '\\0' a"], stdin: nil, workingDirectory: nil,
                timeout: 20) {}
        } throws: { error in
            if case CommandError.lineTooLong = error { return true }
            return false
        }
    }

    @Test func defaultRunnerRejectsStdinAndDirectory() async throws {
        // A runner that only implements the basic `run` (the cleanup `FakeRunner` already supports a directory).
        struct BasicRunner: CommandRunning {
            func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> CommandOutput {
                CommandOutput(status: 0, stdout: "", stderr: "")
            }
            func resolve(_ executable: String) async -> String? { nil }
        }
        await #expect(throws: CommandError.self) {
            _ = try await BasicRunner().run("/bin/cat", [], stdin: "x", workingDirectory: nil, timeout: 1)
        }
        await #expect(throws: CommandError.self) {
            _ = try await BasicRunner().run("/bin/cat", [], stdin: nil, workingDirectory: "/tmp", timeout: 1)
        }
        _ = try await BasicRunner().run("/bin/cat", [], stdin: nil, workingDirectory: nil, timeout: 1)
    }

    // MARK: Real tests (AIRY_REAL=1)

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AIRY_REAL"] == "1"))
    func realClaudeReport() async throws {
        let runner = ProcessRunner()
        let path = try #require(await ClaudeLocator.locate(override: nil, runner: runner))
        let catalog = try Catalog.bundled()
        let ai = AIAssistant(claudePath: path, runner: runner, catalog: catalog, home: home)
        let started = Date()
        let report = try await ai.report(context: sampleContext())
        print("realClaudeReport: \(String(format: "%.1f", Date().timeIntervalSince(started))) s; "
              + "summary: \(report.summary); recommendations: "
              + report.recommendations.map { "\($0.path) → \($0.verdict.jsonName) \(String(describing: $0.action))" }
                .joined(separator: " | ") + "; reclaimable: \(report.reclaimableBytes)")
        #expect(!report.summary.isEmpty)
        // Context paths, or the id of a cleanup item without paths.
        #expect(report.recommendations.allSatisfy { $0.path.hasPrefix(home) || $0.path == "docker-build-cache" })
        #expect(!report.recommendations.contains { $0.path.contains("Documents") && $0.verdict == .safe })
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AIRY_REAL"] == "1"))
    func realClaudeChat() async throws {
        let runner = ProcessRunner()
        let path = try #require(await ClaudeLocator.locate(override: nil, runner: runner))
        let ai = AIAssistant(claudePath: path, runner: runner, catalog: try Catalog.bundled(), home: home)
        var chunks: [String] = []
        for try await chunk in ai.chat(history: [ChatMessage(role: .user, text: "What takes the most space? One sentence.")],
                                       context: sampleContext()) {
            chunks.append(chunk)
        }
        print("realClaudeChat: \(chunks.count) chunks: \(chunks.joined())")
        #expect(!chunks.joined().isEmpty)
    }
}
