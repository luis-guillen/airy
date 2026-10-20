import Foundation
import Testing
@testable import DiskMapCore

@Suite struct AgentSnippetsTests {
    let awkward = "/Applications/Mi Airy's.app/Contents/MacOS/airy-mcp"

    @Test func claudeCodeQuotesAwkwardPath() {
        let s = AgentSnippets(serverPath: awkward)
        #expect(s.claudeCode == "claude mcp add -s user airy -- '/Applications/Mi Airy'\\''s.app/Contents/MacOS/airy-mcp'")
        #expect(s.claudeCodeArguments == ["mcp", "add", "-s", "user", "airy", "--", awkward])
    }

    @Test func codexEscapesBackslashAndQuote() {
        let s = AgentSnippets(serverPath: "/a\\b/\"c\"/airy-mcp")
        #expect(s.codexTOML == """
        # ~/.codex/config.toml
        [mcp_servers.airy]
        command = "/a\\\\b/\\"c\\"/airy-mcp"
        args = []
        """)
    }

    @Test func jsonSnippetsParseAndPointToServer() throws {
        let s = AgentSnippets(serverPath: awkward)
        let open = try #require(JSONSerialization.jsonObject(with: Data(s.opencodeJSON.utf8)) as? [String: Any])
        let mcp = try #require(open["mcp"] as? [String: Any])
        let airy = try #require(mcp["airy"] as? [String: Any])
        #expect(airy["command"] as? [String] == [awkward])
        #expect(airy["type"] as? String == "local")
        #expect(airy["enabled"] as? Bool == true)
        #expect(open["$schema"] as? String == "https://opencode.ai/config.json")

        let gen = try #require(JSONSerialization.jsonObject(with: Data(s.genericJSON.utf8)) as? [String: Any])
        let servers = try #require(gen["mcpServers"] as? [String: Any])
        let entry = try #require(servers["airy"] as? [String: Any])
        #expect(entry["command"] as? String == awkward)
        #expect((entry["args"] as? [Any])?.isEmpty == true)
        #expect(!s.genericJSON.contains("\\/"))
    }

    @Test func claudeAddUsesArgumentArray() async {
        let s = AgentSnippets(serverPath: awkward)
        let runner = FakeRunner()
        let result = await ClaudeMCP.add(claude: "/fake/claude", snippets: s, runner: runner)
        #expect(result == .added)
        #expect(runner.calls.count == 1)
        #expect(runner.calls[0].executable == "/fake/claude")
        #expect(runner.calls[0].arguments == ["mcp", "add", "-s", "user", "airy", "--", awkward])
        #expect(runner.calls[0].timeout == 30)
    }

    @Test func claudeAddDetectsAlreadyPresentAndFailure() async {
        let s = AgentSnippets(serverPath: "/x/airy-mcp")
        let key = "/fake/claude mcp add -s user airy -- /x/airy-mcp"
        let present = FakeRunner(outputs: [key: CommandOutput(status: 1, stdout: "",
                                                              stderr: "MCP server airy already exists in user config")])
        #expect(await ClaudeMCP.add(claude: "/fake/claude", snippets: s, runner: present) == .alreadyPresent)
        let failing = FakeRunner(outputs: [key: CommandOutput(status: 2, stdout: "", stderr: "  boom \n")])
        #expect(await ClaudeMCP.add(claude: "/fake/claude", snippets: s, runner: failing) == .failed("boom"))
    }

    @Test func throwingRunnerIsFailure() async {
        struct Boom: Error {}
        final class Throwing: CommandRunning, Sendable {
            func run(_ e: String, _ a: [String], timeout: TimeInterval) async throws -> CommandOutput { throw Boom() }
            func resolve(_ e: String) async -> String? { nil }
        }
        let r = await ClaudeMCP.add(claude: "/fake/claude", snippets: AgentSnippets(serverPath: "/x"), runner: Throwing())
        guard case .failed = r else { Issue.record("expected failed"); return }
    }
}
