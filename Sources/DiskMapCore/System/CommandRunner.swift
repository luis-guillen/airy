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
    /// Una línea de la salida en streaming superó `limit` bytes.
    case lineTooLong(executable: String, limit: Int)

    public var description: String {
        switch self {
        case .timedOut(let executable, let seconds):
            "\((executable as NSString).lastPathComponent) no terminó en \(Int(seconds)) s y se detuvo."
        case .launchFailed(let executable, let message):
            "No se pudo ejecutar \((executable as NSString).lastPathComponent): \(message)"
        case .lineTooLong(let executable, let limit):
            "\((executable as NSString).lastPathComponent) escribió una línea de más de \(limit / 1_048_576) MB y se detuvo."
        }
    }
}

/// Ejecuta herramientas externas. Siempre con array de argumentos: nunca una cadena de shell.
public protocol CommandRunning: Sendable {
    /// `executable` es una ruta absoluta (resuelta con `resolve`).
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> CommandOutput
    /// Igual que `run`, con texto para la entrada estándar y directorio de trabajo opcionales.
    func run(_ executable: String, _ arguments: [String], stdin: String?, workingDirectory: String?,
             timeout: TimeInterval) async throws -> CommandOutput
    /// Salida estándar línea a línea (sin el salto final) según llega. El plazo cubre toda la ejecución;
    /// al cancelar el consumo se mata el proceso. El código de salida no se comunica.
    func stream(_ executable: String, _ arguments: [String], stdin: String?, workingDirectory: String?,
                timeout: TimeInterval) -> AsyncThrowingStream<String, Error>
    /// Ruta absoluta de una herramienta por su nombre simple, o `nil` si no está instalada.
    func resolve(_ executable: String) async -> String?
}

extension CommandRunning {
    /// Por defecto (dobles de prueba antiguos) no admite `stdin` ni directorio: lanza en vez de ignorarlos.
    public func run(_ executable: String, _ arguments: [String], stdin: String?, workingDirectory: String?,
                    timeout: TimeInterval) async throws -> CommandOutput {
        guard stdin == nil, workingDirectory == nil else {
            throw CommandError.launchFailed(
                executable: executable, message: "este ejecutor no admite entrada estándar ni directorio de trabajo")
        }
        return try await run(executable, arguments, timeout: timeout)
    }

    /// Por defecto: ejecuta entero y emite las líneas de la salida al final.
    public func stream(_ executable: String, _ arguments: [String], stdin: String?, workingDirectory: String?,
                       timeout: TimeInterval) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let output = try await run(executable, arguments, stdin: stdin,
                                               workingDirectory: workingDirectory, timeout: timeout)
                    var lines = output.stdout.split(separator: "\n", omittingEmptySubsequences: false)
                    if lines.last == "" { lines.removeLast() }
                    for line in lines { continuation.yield(String(line)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Bandera de cancelación compartida entre el consumidor y el hilo que espera al proceso.
final class CancelFlag: Sendable {
    private let value = Mutex(false)
    func set() { value.withLock { $0 = true } }
    var isSet: Bool { value.withLock { $0 } }
}

public struct ProcessRunner: CommandRunning {
    /// Directorios extra que el PATH del sistema no suele incluir (`~` se expande).
    public static let fallbackPatterns = [
        "~/anaconda3/bin", "~/miniconda3/bin", "/opt/homebrew/bin", "/usr/local/bin",
        "~/.local/bin", "~/.cargo/bin", "~/Library/pnpm",
    ]

    private let searchPath: [String]?
    private let home: String

    /// `searchPath` sustituye la búsqueda (PATH del sistema + respaldo); útil en pruebas.
    public init(searchPath: [String]? = nil, home: String = NSHomeDirectory()) {
        self.searchPath = searchPath
        self.home = home
    }

    public static func fallbackDirectories(home: String) -> [String] {
        let base = home.hasSuffix("/") ? String(home.dropLast()) : home
        return fallbackPatterns.map { $0.hasPrefix("~/") ? base + $0.dropFirst(1) : $0 }
    }

    /// Dónde se buscan las herramientas, sin lanzar ninguna shell (nunca se ejecutan los ficheros de
    /// arranque del usuario): `/etc/paths`, cada fichero de `/etc/paths.d` (en orden alfabético, como
    /// `path_helper`), el PATH con el que se abrió la app y los directorios de respaldo. Sin duplicados
    /// y solo rutas absolutas.
    public static func systemSearchPath(home: String, environmentPath: String?,
                                        etcPaths: String = "/etc/paths",
                                        etcPathsDirectory: String = "/etc/paths.d") -> [String] {
        var files = [etcPaths]
        if let names = try? FileManager.default.contentsOfDirectory(atPath: etcPathsDirectory) {
            files += names.filter { !$0.hasPrefix(".") }.sorted().map { etcPathsDirectory + "/" + $0 }
        }
        var dirs: [String] = []
        for file in files {
            guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
            dirs += text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        }
        dirs += (environmentPath ?? "").split(separator: ":").map(String.init)
        dirs += fallbackDirectories(home: home)
        var unique: [String] = []
        for dir in dirs where dir.hasPrefix("/") && !unique.contains(dir) { unique.append(dir) }
        return unique
    }

    public func resolve(_ executable: String) async -> String? {
        // Solo nombres simples: el catálogo nunca trae rutas.
        guard !executable.isEmpty, !executable.contains("/") else { return nil }
        let dirs = searchPath ?? Self.systemSearchPath(
            home: home, environmentPath: ProcessInfo.processInfo.environment["PATH"])
        for dir in dirs where dir.hasPrefix("/") {
            let candidate = (dir as NSString).appendingPathComponent(executable)
            var info = stat()
            // `stat` sigue el enlace (Homebrew instala enlaces); se exige fichero regular ejecutable.
            guard stat(candidate, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }
            if access(candidate, X_OK) == 0 { return candidate }
        }
        return nil
    }

    public func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> CommandOutput {
        try await run(executable, arguments, stdin: nil, workingDirectory: nil, timeout: timeout)
    }

    public func run(_ executable: String, _ arguments: [String], stdin: String?, workingDirectory: String?,
                    timeout: TimeInterval) async throws -> CommandOutput {
        let flag = CancelFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global().async {
                    do {
                        continuation.resume(returning: try Self.runBlocking(
                            executable, arguments, stdin: stdin, workingDirectory: workingDirectory,
                            timeout: timeout, cancel: flag, onLine: nil))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            flag.set()
        }
    }

    public func stream(_ executable: String, _ arguments: [String], stdin: String?, workingDirectory: String?,
                       timeout: TimeInterval) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let flag = CancelFlag()
            continuation.onTermination = { _ in flag.set() }
            DispatchQueue.global().async {
                do {
                    _ = try Self.runBlocking(
                        executable, arguments, stdin: stdin, workingDirectory: workingDirectory,
                        timeout: timeout, cancel: flag, onLine: { continuation.yield($0) })
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Máximo de una línea en streaming (protege la memoria ante una salida sin saltos de línea).
    static let maxStreamLineBytes = 4 * 1_048_576

    /// Tras salir el proceso, cuánto se espera a que se cierren las tuberías (nietos que las heredan).
    static let drainGrace: TimeInterval = 2

    /// `posix_spawn` en un grupo de procesos propio para poder matar también a los nietos.
    /// Las tuberías se leen con `poll` y nunca más allá del plazo.
    /// `stdin` se escribe en un fichero temporal privado (0600) que se borra nada más lanzar el proceso:
    /// así no hay tubería de entrada que pueda bloquear ni provocar SIGPIPE.
    /// Con `onLine`, la salida estándar se entrega por líneas y no se acumula en el resultado.
    private static func runBlocking(_ executable: String, _ arguments: [String], stdin: String?,
                                    workingDirectory: String?, timeout: TimeInterval, cancel: CancelFlag?,
                                    onLine: ((String) -> Void)?) throws -> CommandOutput {
        var stdinFile: String?
        if let stdin {
            var template = Array((NSTemporaryDirectory() + "diskmap-stdin-XXXXXX").utf8CString)
            let fd = mkstemp(&template)
            guard fd >= 0 else { throw launchError(executable, errno) }
            let path = String(decoding: template.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let bytes = Array(stdin.utf8)
            var written = 0
            while written < bytes.count {
                let n = bytes[written...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else {
                    let code = errno
                    close(fd); unlink(path)
                    throw launchError(executable, code)
                }
                written += n
            }
            close(fd)
            stdinFile = path
        }
        defer { if let stdinFile { unlink(stdinFile) } }

        var outPipe: [Int32] = [-1, -1]
        var errPipe: [Int32] = [-1, -1]
        guard pipe(&outPipe) == 0 else { throw launchError(executable, errno) }
        guard pipe(&errPipe) == 0 else {
            let code = errno
            close(outPipe[0]); close(outPipe[1])
            throw launchError(executable, code)
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, stdinFile ?? "/dev/null", O_RDONLY, 0)
        if let workingDirectory { posix_spawn_file_actions_addchdir_np(&actions, workingDirectory) }
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Grupo propio (pgid = pid), solo los descriptores 0-2 y señales por defecto en el hijo.
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF
            | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attributes, Int16(flags))
        posix_spawnattr_setpgroup(&attributes, 0)
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        posix_spawnattr_setsigmask(&attributes, &emptyMask)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)

        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = ProcessInfo.processInfo.environment
            .map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for pointer in argv + envp { free(pointer) } }

        var pid: pid_t = 0
        let spawnResult = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        close(outPipe[1]); close(errPipe[1])
        // El hijo ya tiene abierta su entrada: el fichero temporal sobra.
        if let stdinFile { unlink(stdinFile) }
        guard spawnResult == 0 else {
            close(outPipe[0]); close(errPipe[0])
            throw launchError(executable, spawnResult)
        }

        var fds = [outPipe[0], errPipe[0]]
        var buffers = [Data(), Data()]
        defer { for fd in fds where fd >= 0 { close(fd) } }

        let deadline = Date().addingTimeInterval(max(0, timeout))
        var status: Int32 = 0
        var exitedAt: Date?
        var chunk = [UInt8](repeating: 0, count: 65_536)

        while true {
            if exitedAt == nil, waitpid(pid, &status, WNOHANG) == pid { exitedAt = Date() }
            let open = fds.indices.filter { fds[$0] >= 0 }
            if exitedAt != nil && open.isEmpty { break }
            if let cancel, cancel.isSet {
                terminateGroup(pid, reaped: exitedAt != nil)
                throw CancellationError()
            }
            let now = Date()
            if exitedAt == nil && now >= deadline {
                terminateGroup(pid, reaped: false)
                throw CommandError.timedOut(executable: executable, seconds: timeout)
            }
            if let exitedAt, now >= min(deadline, exitedAt.addingTimeInterval(drainGrace)) {
                // El proceso terminó pero un nieto retiene la salida: se mata el grupo y se devuelve lo leído.
                kill(-pid, SIGKILL)
                break
            }
            var pollFds = open.map { pollfd(fd: fds[$0], events: Int16(POLLIN), revents: 0) }
            let ready = poll(&pollFds, nfds_t(pollFds.count), 50)
            guard ready > 0 else { continue }
            for (slot, index) in open.enumerated() where pollFds[slot].revents != 0 {
                let count = read(fds[index], &chunk, chunk.count)
                if count > 0 {
                    buffers[index].append(contentsOf: chunk[0..<count])
                    if index == 0, let onLine {
                        emitLines(&buffers[0], onLine)
                        if buffers[0].count > maxStreamLineBytes {
                            terminateGroup(pid, reaped: exitedAt != nil)
                            throw CommandError.lineTooLong(executable: executable, limit: maxStreamLineBytes)
                        }
                    }
                } else if count == 0 || (errno != EINTR && errno != EAGAIN) {
                    close(fds[index])
                    fds[index] = -1
                }
            }
        }

        if let onLine, !buffers[0].isEmpty {
            onLine(String(decoding: buffers[0], as: UTF8.self))
            buffers[0].removeAll()
        }

        // Estado al estilo de la shell: código de salida, o 128 + señal.
        let signal = status & 0x7f
        let code = signal == 0 ? (status >> 8) & 0xff : 128 + signal
        return CommandOutput(
            status: code,
            stdout: String(decoding: buffers[0], as: UTF8.self),
            stderr: String(decoding: buffers[1], as: UTF8.self))
    }

    /// Entrega las líneas completas del búfer (sin `\n` ni `\r` final) y deja el resto.
    private static func emitLines(_ buffer: inout Data, _ onLine: (String) -> Void) {
        while let newline = buffer.firstIndex(of: 0x0A) {
            var line = buffer[buffer.startIndex..<newline]
            if line.last == 0x0D { line = line.dropLast() }
            onLine(String(decoding: line, as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
    }

    /// SIGTERM al grupo, espera hasta 2 s y SIGKILL; recoge siempre al hijo.
    private static func terminateGroup(_ pid: pid_t, reaped: Bool) {
        kill(-pid, SIGTERM)
        var status: Int32 = 0
        let limit = Date().addingTimeInterval(2)
        var done = reaped
        while !done && Date() < limit {
            if waitpid(pid, &status, WNOHANG) == pid { done = true } else { usleep(20_000) }
        }
        kill(-pid, SIGKILL)
        if !done { waitpid(pid, &status, 0) }
    }

    private static func launchError(_ executable: String, _ code: Int32) -> CommandError {
        .launchFailed(executable: executable, message: String(cString: strerror(code)))
    }
}
