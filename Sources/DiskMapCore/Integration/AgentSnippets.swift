import Foundation

/// Instrucciones para conectar un agente al servidor MCP de Airy (`airy-mcp`). La ruta se escapa
/// según el formato de cada destino.
public struct AgentSnippets: Sendable, Equatable {
    public let serverPath: String

    public init(serverPath: String) { self.serverPath = serverPath }

    /// Argumentos para `claude` (alcance de usuario: vale para todos los proyectos).
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

    /// `'…'` con cada `'` como `'\''`.
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

    /// `claude mcp add -s user airy -- <ruta>` con array de argumentos (nunca una cadena de shell).
    public static func add(claude: String, snippets: AgentSnippets, runner: any CommandRunning) async -> ClaudeRegistration {
        do {
            let out = try await runner.run(claude, snippets.claudeCodeArguments, timeout: timeout)
            if out.status == 0 { return .added }
            if (out.stderr + out.stdout).localizedCaseInsensitiveContains("already exists") { return .alreadyPresent }
            let text = out.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(text.isEmpty ? "código de salida \(out.status)" : text)
        } catch {
            return .failed((error as? LocalizedError)?.errorDescription ?? String(describing: error))
        }
    }
}
