import Foundation

/// MCP stdio transport: one JSON message per line on input, one response per line on output.
/// It serves the messages in order and one at a time; it ends at the end of input (EOF).
/// Only JSON-RPC goes to the output: diagnostics go to stderr.
/// A message longer than `maxLineBytes` (1 MiB) is not accumulated: it is discarded up to the next line
/// break and answered with a JSON-RPC parse error (-32700).
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
                              "message": .string("Message too long (more than \(limit) bytes): discarded.")]),
        ]).compactString()
    }

    /// `false` if it can no longer write (the client closed the output).
    private static func respond(to line: String, server: MCPServer, output: FileHandle) async throws -> Bool {
        guard let response = await server.handle(line: line) else { return true }
        return write(response, to: output)
    }

    /// `false` if it can no longer write (the client closed the output).
    private static func write(_ response: String, to output: FileHandle) -> Bool {
        do {
            try output.write(contentsOf: Data((response + "\n").utf8))
            return true
        } catch {
            FileHandle.standardError.write(Data("airy-mcp: could not write the response: \(error)\n".utf8))
            return false
        }
    }
}
