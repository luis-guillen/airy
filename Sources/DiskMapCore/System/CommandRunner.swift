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
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                do {
                    continuation.resume(returning: try Self.runBlocking(executable, arguments, timeout: timeout))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Tras salir el proceso, cuánto se espera a que se cierren las tuberías (nietos que las heredan).
    static let drainGrace: TimeInterval = 2

    /// `posix_spawn` en un grupo de procesos propio para poder matar también a los nietos.
    /// Las tuberías se leen con `poll` y nunca más allá del plazo.
    private static func runBlocking(_ executable: String, _ arguments: [String],
                                    timeout: TimeInterval) throws -> CommandOutput {
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
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
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
                } else if count == 0 || (errno != EINTR && errno != EAGAIN) {
                    close(fds[index])
                    fds[index] = -1
                }
            }
        }

        // Estado al estilo de la shell: código de salida, o 128 + señal.
        let signal = status & 0x7f
        let code = signal == 0 ? (status >> 8) & 0xff : 128 + signal
        return CommandOutput(
            status: code,
            stdout: String(decoding: buffers[0], as: UTF8.self),
            stderr: String(decoding: buffers[1], as: UTF8.self))
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
