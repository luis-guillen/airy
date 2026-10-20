import Foundation

/// Busca el ejecutable de Claude Code. Descarta el envoltorio de cmux (un script de shell que
/// redirige a `cmux-claude-wrapper`) y exige que `--version` diga "Claude Code".
public enum ClaudeLocator {
    static let shimMarker = "cmux-claude-wrapper"
    /// Solo se leen los primeros bytes: el binario real pesa unos 200 MB.
    static let headerBytes = 65_536
    static let versionTimeout: TimeInterval = 10

    /// Ubicaciones habituales, en orden de preferencia (sin la ruta elegida por el usuario).
    public static func candidates(home: String) -> [String] {
        let base = home.hasSuffix("/") ? String(home.dropLast()) : home
        return [
            base + "/.local/bin/claude", base + "/.claude/local/claude", "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude", base + "/.npm-global/bin/claude",
        ]
    }

    /// Primera ruta válida: `override` y después `candidates(home:)`.
    public static func locate(override: String?, runner: CommandRunning,
                              home: String = NSHomeDirectory()) async -> String? {
        var seen = Set<String>()
        for candidate in ([override].compactMap { $0 } + candidates(home: home)) where seen.insert(candidate).inserted {
            guard candidate.hasPrefix("/"), isExecutableFile(candidate), !isCmuxShim(candidate) else { continue }
            guard let output = try? await runner.run(candidate, ["--version"], timeout: versionTimeout),
                  output.status == 0, output.stdout.contains("Claude Code") else { continue }
            return candidate
        }
        return nil
    }

    /// Fichero regular ejecutable tras seguir enlaces.
    static func isExecutableFile(_ path: String) -> Bool {
        var info = stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return false }
        return access(path, X_OK) == 0
    }

    /// Script (`#!`) que menciona el envoltorio de cmux en sus primeros 64 KB.
    static func isCmuxShim(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: headerBytes), data.starts(with: [0x23, 0x21]) else {
            return false
        }
        return data.range(of: Data(shimMarker.utf8)) != nil
    }
}
