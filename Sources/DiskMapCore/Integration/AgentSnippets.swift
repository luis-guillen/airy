import Foundation

/// Instructions to connect an agent to Airy's MCP server (`airy-mcp`). The path is escaped
/// according to each destination's format.
public struct AgentSnippets: Sendable, Equatable {
    public let serverPath: String

    public init(serverPath: String) { self.serverPath = serverPath }

    /// Arguments for `claude` (user scope: valid for every project).
    public var claudeCodeArguments: [String] { ["mcp", "add", "-s", "user", "airy", "--", serverPath] }

    public var claudeCode: String { "claude mcp add -s user airy -- " + Self.shellQuote(serverPath) }

    public var codexTOML: String {
        """
        # ~/.codex/config.toml
        [mcp_servers.airy]
        command = "\(Self.tomlEscape(serverPath))"
        args = []
        """
    }

    public var opencodeJSON: String {
        Self.json(["$schema": "https://opencode.ai/config.json",
                   "mcp": ["airy": ["command": [serverPath], "enabled": true, "type": "local"] as [String: Any]]])
    }

    public var genericJSON: String {
        Self.json(["mcpServers": ["airy": ["args": [String](), "command": serverPath] as [String: Any]]])
    }

    /// `'…'` with each `'` as `'\''`.
    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func tomlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func json(_ object: [String: Any]) -> String {
        let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: options) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

public enum ClaudeRegistration: Sendable, Equatable {
    case added, alreadyPresent
    case failed(String)
}

public enum ClaudeMCP {
    static let timeout: TimeInterval = 30

    /// `claude mcp add -s user airy -- <path>` with an argument array (never a shell string).
    public static func add(claude: String, snippets: AgentSnippets, runner: any CommandRunning) async -> ClaudeRegistration {
        do {
            let out = try await runner.run(claude, snippets.claudeCodeArguments, timeout: timeout)
            if out.status == 0 { return .added }
            if (out.stderr + out.stdout).localizedCaseInsensitiveContains("already exists") { return .alreadyPresent }
            let text = out.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(text.isEmpty ? String(localized: "exit code \(out.status)", bundle: .airyCore) : text)
        } catch {
            return .failed((error as? LocalizedError)?.errorDescription ?? String(describing: error))
        }
    }
}
