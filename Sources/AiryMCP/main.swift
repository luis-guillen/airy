import DiskMapCore
import Foundation

// Servidor MCP de Airy por stdio (`Airy.app/Contents/MacOS/airy-mcp`).
// Por stdout solo va JSON-RPC; los diagnósticos, por stderr. Termina al cerrarse la entrada.

// Si el cliente cierra la salida, `write` devuelve error en vez de matar el proceso.
signal(SIGPIPE, SIG_IGN)

func diagnose(_ message: String) {
    FileHandle.standardError.write(Data("airy-mcp: \(message)\n".utf8))
}

let paths = AppPaths.standard()
if case .failed(let reason) = DataMigration.migrateIfNeeded(paths) {
    diagnose("no se pudieron copiar los datos antiguos: \(reason)")
}

/// Versión del Airy.app que lo contiene (`Contents/MacOS/airy-mcp` ⇒ `Contents/Info.plist`).
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
