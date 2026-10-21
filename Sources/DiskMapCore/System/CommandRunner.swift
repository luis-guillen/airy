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
    /// A line of the streamed output exceeded `limit` bytes.
    case lineTooLong(executable: String, limit: Int)

    public var description: String {
        switch self {
        case .timedOut(let executable, let seconds):
            String(localized: "\((executable as NSString).lastPathComponent) did not finish in \(Int(seconds)) s and was stopped.", bundle: .airyCore)
        case .launchFailed(let executable, let message):
            String(localized: "Could not run \((executable as NSString).lastPathComponent): \(message)", bundle: .airyCore)
        case .lineTooLong(let executable, let limit):
            String(localized: "\((executable as NSString).lastPathComponent) wrote a line longer than \(limit / 1_048_576) MB and was stopped.", bundle: .airyCore)
        }
    }
}

/// Runs external tools. Always with an argument array: never a shell string.
public protocol CommandRunning: Sendable {
    /// `executable` is an absolute path (resolved with `resolve`).
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> CommandOutput
    /// Same as `run`, with optional standard input text and working directory.
    func run(_ executable: String, _ arguments: [String], stdin: String?, workingDirectory: String?,
             timeout: TimeInterval) async throws -> CommandOutput
    /// Standard output line by line (without the final line break) as it arrives. The time limit covers the whole run;
    /// cancelling the consumer kills the process. The exit code is not reported.
    func stream(_ executable: String, _ arguments: [String], stdin: String?, workingDirectory: String?,
                timeout: TimeInterval) -> AsyncThrowingStream<String, Error>
    /// Absolute path of a tool by its bare name, or `nil` if it is not installed.
    func resolve(_ executable: String) async -> String?
}

extension CommandRunning {
    /// By default (old test doubles) it does not accept `stdin` nor a directory: it throws instead of ignoring them.
    public func run(_ executable: String, _ arguments: [String], stdin: String?, workingDirectory: String?,
                    timeout: TimeInterval) async throws -> CommandOutput {
        guard stdin == nil, workingDirectory == nil else {
            throw CommandError.launchFailed(
                executable: executable, message: "this runner does not support standard input or a working directory")
        }
        return try await run(executable, arguments, timeout: timeout)
    }

    /// By default: runs to completion and emits the output lines at the end.
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

/// Cancellation flag shared between the consumer and the thread waiting for the process.
final class CancelFlag: Sendable {
    private let value = Mutex(false)
    func set() { value.withLock { $0 = true } }
    var isSet: Bool { value.withLock { $0 } }
}

public struct ProcessRunner: CommandRunning {
    /// Extra directories the system PATH does not usually include (`~` is expanded).
    public static let fallbackPatterns = [
        "~/anaconda3/bin", "~/miniconda3/bin", "/opt/homebrew/bin", "/usr/local/bin",
        "~/.local/bin", "~/.cargo/bin", "~/Library/pnpm",
        "~/.pyenv/bin", "~/.rbenv/bin", "~/miniforge3/bin", "~/.volta/bin",
    ]

    private let searchPath: [String]?
    private let home: String

    /// `searchPath` replaces the lookup (system PATH + fallback); useful in tests.
    public init(searchPath: [String]? = nil, home: String = NSHomeDirectory()) {
        self.searchPath = searchPath
        self.home = home
    }

    public static func fallbackDirectories(home: String) -> [String] {
        let base = home.hasSuffix("/") ? String(home.dropLast()) : home
        return fallbackPatterns.map { $0.hasPrefix("~/") ? base + $0.dropFirst(1) : $0 }
    }

    /// Where tools are looked for, without launching any shell (the user's startup files are never
    /// run): `/etc/paths`, each file in `/etc/paths.d` (in alphabetical order, like
    /// `path_helper`), the PATH the app was opened with and the fallback directories. Without duplicates
    /// and absolute paths only.
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
        // Bare names only: the catalog never brings paths.
        guard !executable.isEmpty, !executable.contains("/") else { return nil }
        let dirs = searchPath ?? Self.systemSearchPath(
            home: home, environmentPath: ProcessInfo.processInfo.environment["PATH"])
        for dir in dirs where dir.hasPrefix("/") {
            let candidate = (dir as NSString).appendingPathComponent(executable)
            var info = stat()
            // `stat` follows the link (Homebrew installs links); a regular executable file is required.
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

    /// Maximum length of a streamed line (protects memory against output without line breaks).
    static let maxStreamLineBytes = 4 * 1_048_576

    /// After the process exits, how long to wait for the pipes to close (grandchildren that inherit them).
    static let drainGrace: TimeInterval = 2

    /// `posix_spawn` in its own process group so that grandchildren can be killed too.
    /// The pipes are read with `poll` and never past the time limit.
    /// `stdin` is written to a private temporary file (0600) that is deleted as soon as the process is launched:
    /// that way there is no input pipe that could block or cause SIGPIPE.
    /// With `onLine`, standard output is delivered line by line and not accumulated in the result.
    private static func runBlocking(_ executable: String, _ arguments: [String], stdin: String?,
                                    workingDirectory: String?, timeout: TimeInterval, cancel: CancelFlag?,
                                    onLine: ((String) -> Void)?) throws -> CommandOutput {
        var stdinFile: String?
        if let stdin {
            var template = Array((NSTemporaryDirectory() + "airy-stdin-XXXXXX").utf8CString)
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
        // Own group (pgid = pid), only descriptors 0-2 and default signals in the child.
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
        // The child already has its input open: the temporary file is no longer needed.
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
                // The process ended but a grandchild holds the output: kill the group and return what was read.
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

        // Shell-style status: exit code, or 128 + signal.
        let signal = status & 0x7f
        let code = signal == 0 ? (status >> 8) & 0xff : 128 + signal
        return CommandOutput(
            status: code,
            stdout: String(decoding: buffers[0], as: UTF8.self),
            stderr: String(decoding: buffers[1], as: UTF8.self))
    }

    /// Delivers the buffer's complete lines (without the trailing `\n` or `\r`) and keeps the rest.
    private static func emitLines(_ buffer: inout Data, _ onLine: (String) -> Void) {
        while let newline = buffer.firstIndex(of: 0x0A) {
            var line = buffer[buffer.startIndex..<newline]
            if line.last == 0x0D { line = line.dropLast() }
            onLine(String(decoding: line, as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
    }

    /// SIGTERM to the group, wait up to 2 s and SIGKILL; always reaps the child.
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
