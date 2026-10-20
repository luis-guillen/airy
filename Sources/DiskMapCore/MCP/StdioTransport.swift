import Foundation

/// Transporte stdio de MCP: un mensaje JSON por línea en la entrada, una respuesta por línea en la salida.
/// Atiende los mensajes en orden y de uno en uno; termina con el fin de la entrada (EOF).
/// Por la salida solo va JSON-RPC: los diagnósticos van a stderr.
public enum StdioTransport {
    public static func run(server: MCPServer, input: FileHandle = .standardInput,
                           output: FileHandle = .standardOutput) async {
        var buffer = Data()
        do {
            for try await byte in input.bytes {
                guard byte == UInt8(ascii: "\n") else {
                    buffer.append(byte)
                    continue
                }
                let line = String(decoding: buffer, as: UTF8.self)
                buffer.removeAll(keepingCapacity: true)
                guard try await respond(to: line, server: server, output: output) else { return }
            }
            if !buffer.isEmpty {
                _ = try await respond(to: String(decoding: buffer, as: UTF8.self), server: server, output: output)
            }
        } catch {
            FileHandle.standardError.write(Data("airy-mcp: \(error)\n".utf8))
        }
    }

    /// `false` si ya no se puede escribir (el cliente cerró la salida).
    private static func respond(to line: String, server: MCPServer, output: FileHandle) async throws -> Bool {
        guard let response = await server.handle(line: line) else { return true }
        do {
            try output.write(contentsOf: Data((response + "\n").utf8))
            return true
        } catch {
            FileHandle.standardError.write(Data("airy-mcp: no se pudo escribir la respuesta: \(error)\n".utf8))
            return false
        }
    }
}
