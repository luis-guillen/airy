import Foundation
import Synchronization

public struct CommandOutput: Sendable, Equatable {
    public var status: Int32
    public var stdout: String
    public var stderr: String

    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

public enum CommandError: Error, Sendable, CustomStringConvertible {
    case timedOut(executable: String, seconds: TimeInterval)
    case launchFailed(executable: String, message: String)

    public var description: String {
        switch self {
        case .timedOut(let executable, let seconds):
            "\((executable as NSString).lastPathComponent) no terminó en \(Int(seconds)) s y se detuvo."
        case .launchFailed(let executable, let message):
            "No se pudo ejecutar \((executable as NSString).lastPathComponent): \(message)"
        }
    }
}

/// Ejecuta herramientas externas. Siempre con array de argumentos: nunca una cadena de shell.
public protocol CommandRunning: Sendable {
    /// `executable` es una ruta absoluta (resuelta con `resolve`).
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> CommandOutput
    /// Ruta absoluta de una herramienta por su nombre simple, o `nil` si no está instalada.
    func resolve(_ executable: String) async -> String?
}

public struct ProcessRunner: CommandRunning {
    /// Directorios extra por si el PATH de la shell de login no los incluye (`~` se expande).
    public static let fallbackPatterns = [
        "~/anaconda3/bin", "~/miniconda3/bin", "/opt/homebrew/bin", "/usr/local/bin",
        "~/.local/bin", "~/.cargo/bin", "~/Library/pnpm",
    ]

    /// PATH de la shell de login, calculado una vez por proceso.
    private static let loginPathCache = Mutex<[String]?>(nil)

    private let searchPath: [String]?
    private let home: String

    /// `searchPath` sustituye la búsqueda (PATH de login + respaldo); útil en pruebas.
    public init(searchPath: [String]? = nil, home: String = NSHomeDirectory()) {
        self.searchPath = searchPath
        self.home = home
    }

    public static func fallbackDirectories(home: String) -> [String] {
        let base = home.hasSuffix("/") ? String(home.dropLast()) : home
        return fallbackPatterns.map { $0.hasPrefix("~/") ? base + $0.dropFirst(1) : $0 }
    }

    public func resolve(_ executable: String) async -> String? {
        // Solo nombres simples: el catálogo nunca trae rutas.
        guard !executable.isEmpty, !executable.contains("/") else { return nil }
        let dirs: [String]
        if let searchPath {
            dirs = searchPath
        } else {
            dirs = await Self.loginPath() + Self.fallbackDirectories(home: home)
        }
        for dir in dirs where dir.hasPrefix("/") {
            let candidate = (dir as NSString).appendingPathComponent(executable)
            var info = stat()
            // `stat` sigue el enlace (Homebrew instala enlaces); se exige fichero regular ejecutable.
            guard stat(candidate, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }
            if access(candidate, X_OK) == 0 { return candidate }
        }
        return nil
    }

    private static func loginPath() async -> [String] {
        if let cached = loginPathCache.withLock({ $0 }) { return cached }
        var dirs: [String] = []
        if let output = try? await ProcessRunner(searchPath: []).run(
            "/bin/zsh", ["-lc", "printf %s \"$PATH\""], timeout: 10), output.status == 0 {
            // Lo que impriman los ficheros de perfil acaba en líneas anteriores: el PATH es la última.
            let last = output.stdout.split(separator: "\n", omittingEmptySubsequences: false).last ?? ""
            dirs = last.split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        }
        if dirs.isEmpty {
            dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
                .split(separator: ":").map(String.init)
        }
        loginPathCache.withLock { $0 = dirs }
        return dirs
    }

    public func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> CommandOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            throw CommandError.launchFailed(executable: executable, message: error.localizedDescription)
        }

        // Leer las tuberías en paralelo evita bloqueos si la salida llena el búfer.
        let outData = DataSink()
        let errData = DataSink()
        let reads = DispatchGroup()
        for (handle, sink) in [(outPipe.fileHandleForReading, outData), (errPipe.fileHandleForReading, errData)] {
            reads.enter()
            DispatchQueue.global().async {
                sink.set(handle.readDataToEndOfFile())
                reads.leave()
            }
        }

        let pid = process.processIdentifier
        let timedOut: Bool = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                if finished.wait(timeout: .now() + max(0, timeout)) == .success {
                    continuation.resume(returning: false)
                    return
                }
                // Tiempo agotado: SIGTERM y, si sigue vivo, SIGKILL.
                kill(pid, SIGTERM)
                if finished.wait(timeout: .now() + 2) != .success {
                    kill(pid, SIGKILL)
                    finished.wait()
                }
                continuation.resume(returning: true)
            }
        }
        if timedOut {
            throw CommandError.timedOut(executable: executable, seconds: timeout)
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            reads.notify(queue: .global()) { continuation.resume() }
        }
        return CommandOutput(
            status: process.terminationStatus,
            stdout: String(decoding: outData.get(), as: UTF8.self),
            stderr: String(decoding: errData.get(), as: UTF8.self))
    }
}

private final class DataSink: Sendable {
    private let data = Mutex(Data())
    func set(_ value: Data) { data.withLock { $0 = value } }
    func get() -> Data { data.withLock { $0 } }
}
