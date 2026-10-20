import Foundation

public enum PrivilegedOutcome: Sendable, Equatable {
    case ok(CommandOutput), cancelled, failed(String)
}

/// Órdenes con permisos de administrador. Solo admite dos formas exactas (lista blanca): olvidar un recibo de
/// instalación (`pkgutil --forget <id>`) y quitar enlaces rotos de `/usr/local/bin` (`BrokenLinks.deleteCommand`).
public protocol PrivilegedRunning: Sendable {
    /// Una sola petición de contraseña para todos los comandos; cada uno es [ejecutable, argumentos…].
    func run(_ commands: [[String]], prompt: String) async -> PrivilegedOutcome
}

/// Pide la contraseña con `osascript … with administrator privileges`. El texto AppleScript es fijo: los
/// comandos llegan como argumentos (`argv`) y cada argumento se cita con `quoted form of`, nunca se
/// interpola en el guion.
public struct OsascriptPrivilegedRunner: PrivilegedRunning {
    static let osascript = "/usr/bin/osascript"
    static let timeout: TimeInterval = 300
    static let notAllowed = "Orden no permitida."

    private let runner: any CommandRunning

    public init(runner: any CommandRunning = ProcessRunner()) {
        self.runner = runner
    }

    static let scriptLines: [String] = [
        "on run argv",
        "set thePrompt to item 1 of argv",
        "set theCommands to {}",
        "set i to 2",
        "repeat while i is less than or equal to (count of argv)",
        "set n to (item i of argv) as integer",
        "set theWords to {}",
        "repeat with j from (i + 1) to (i + n)",
        "set end of theWords to quoted form of (item j of argv)",
        "end repeat",
        "set AppleScript's text item delimiters to \" \"",
        "set end of theCommands to (theWords as text)",
        "set i to i + n + 1",
        "end repeat",
        "set AppleScript's text item delimiters to \" ; \"",
        "set theScript to (theCommands as text)",
        "set AppleScript's text item delimiters to \"\"",
        "do shell script theScript with administrator privileges with prompt thePrompt",
        "end run",
    ]

    /// ["-e", línea…, "--", prompt, "\(n1)", exe1, args1…, "\(n2)", exe2, args2…]; n = número de elementos del comando.
    static func arguments(for commands: [[String]], prompt: String) -> [String] {
        var args = scriptLines.flatMap { ["-e", $0] }
        args += ["--", prompt]
        for command in commands { args += ["\(command.count)"] + command }
        return args
    }

    /// `^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$`
    static func isPackageID(_ id: String) -> Bool {
        func alnum(_ s: Unicode.Scalar) -> Bool {
            ("a"..."z").contains(s) || ("A"..."Z").contains(s) || ("0"..."9").contains(s)
        }
        let scalars = Array(id.unicodeScalars)
        guard let first = scalars.first, alnum(first), scalars.count <= 200 else { return false }
        return scalars.allSatisfy { alnum($0) || $0 == "." || $0 == "_" || $0 == "-" }
    }

    /// `true` solo para las dos formas permitidas.
    static func isAllowed(_ command: [String]) -> Bool {
        if command.count == 3, command[0] == "/usr/sbin/pkgutil", command[1] == "--forget" {
            return isPackageID(command[2])
        }
        return BrokenLinks.isAllowedDeleteCommand(command)
    }

    public func run(_ commands: [[String]], prompt: String) async -> PrivilegedOutcome {
        guard !commands.isEmpty, commands.allSatisfy(Self.isAllowed) else { return .failed(Self.notAllowed) }
        let output: CommandOutput
        do {
            output = try await runner.run(Self.osascript, Self.arguments(for: commands, prompt: prompt),
                                          timeout: Self.timeout)
        } catch {
            return .failed(String(String(describing: error).prefix(300)))
        }
        if output.status == 0 { return .ok(output) }
        if output.stderr.contains("-128") { return .cancelled }
        return .failed(String(output.stderr.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)))
    }
}
