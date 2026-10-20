import Foundation

/// Transporte stdio de MCP: un mensaje JSON por línea en la entrada, una respuesta por línea en la salida.
/// Atiende los mensajes en orden y de uno en uno; termina con el fin de la entrada (EOF).
/// Por la salida solo va JSON-RPC: los diagnósticos van a stderr.
/// Un mensaje de más de `maxLineBytes` (1 MiB) no se acumula: se descarta hasta el siguiente salto de
/// línea y se contesta con un error JSON-RPC de análisis (-32700).
public enum StdioTransport {
    public static let maxLineBytes = 1 << 20

    public static func run(server: MCPServer, input: FileHandle = .standardInput,
                           output: FileHandle = .standardOutput, maxLineBytes: Int = StdioTransport.maxLineBytes) async {
        var buffer = Data()
        var overlong = false
        do {
            for try await byte in input.bytes {
                guard byte == UInt8(ascii: "\n") else {
                    if overlong { continue }
                    if buffer.count >= maxLineBytes {
                        overlong = true
                        buffer = Data()
                        continue
                    }
                    buffer.append(byte)
                    continue
                }
                if overlong {
                    overlong = false
                    guard write(overlongError(maxLineBytes), to: output) else { return }
                    continue
                }
                let line = String(decoding: buffer, as: UTF8.self)
                buffer.removeAll(keepingCapacity: true)
                guard try await respond(to: line, server: server, output: output) else { return }
            }
            if overlong {
                _ = write(overlongError(maxLineBytes), to: output)
            } else if !buffer.isEmpty {
                _ = try await respond(to: String(decoding: buffer, as: UTF8.self), server: server, output: output)
            }
        } catch {
            FileHandle.standardError.write(Data("airy-mcp: \(error)\n".utf8))
        }
    }

    static func overlongError(_ limit: Int) -> String {
        JSONValue.object([
            "jsonrpc": .string("2.0"), "id": .null,
            "error": .object(["code": .number(-32700),
                              "message": .string("Mensaje demasiado largo (más de \(limit) bytes): descartado.")]),
        ]).compactString()
    }

    /// `false` si ya no se puede escribir (el cliente cerró la salida).
    private static func respond(to line: String, server: MCPServer, output: FileHandle) async throws -> Bool {
        guard let response = await server.handle(line: line) else { return true }
        return write(response, to: output)
    }

    /// `false` si ya no se puede escribir (el cliente cerró la salida).
    private static func write(_ response: String, to output: FileHandle) -> Bool {
        do {
            try output.write(contentsOf: Data((response + "\n").utf8))
            return true
        } catch {
            FileHandle.standardError.write(Data("airy-mcp: no se pudo escribir la respuesta: \(error)\n".utf8))
            return false
        }
    }
}
