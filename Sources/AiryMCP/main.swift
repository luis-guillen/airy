import DiskMapCore
import Foundation

// Airy's stdio MCP server (`Airy.app/Contents/MacOS/airy-mcp`).
// Only JSON-RPC goes to stdout; diagnostics go to stderr. It ends when the input is closed.

// The MCP always speaks English, whatever the user's language: agents work best with stable English.
AiryLanguage.override = AiryLanguage.source

// If the client closes the output, `write` returns an error instead of killing the process.
signal(SIGPIPE, SIG_IGN)

func diagnose(_ message: String) {
    FileHandle.standardError.write(Data("airy-mcp: \(message)\n".utf8))
}

let paths = AppPaths.standard()
if case .failed(let reason) = DataMigration.migrateIfNeeded(paths) {
    diagnose("could not copy the old data: \(reason)")
}

/// Version of the Airy.app that contains it (`Contents/MacOS/airy-mcp` ⇒ `Contents/Info.plist`).
func containingAppVersion() -> String? {
    guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
    let contents = executable.deletingLastPathComponent().deletingLastPathComponent()
    guard contents.lastPathComponent == "Contents",
          contents.deletingLastPathComponent().pathExtension == "app",
          let info = NSDictionary(contentsOf: contents.appendingPathComponent("Info.plist")),
          let version = info["CFBundleShortVersionString"] as? String, !version.isEmpty else { return nil }
    return version
}

let environment = AiryEnvironment.live(paths: paths)
if let catalogError = environment.catalogError { diagnose(catalogError) }

let server = MCPServer(registry: .standard(), environment: environment,
                       serverVersion: containingAppVersion() ?? "0.2.0")
await StdioTransport.run(server: server)
