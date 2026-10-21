import Foundation

/// Finds the Claude Code executable. It discards cmux's wrapper (a shell script that
/// redirects to `cmux-claude-wrapper`) and requires `--version` to say "Claude Code".
public enum ClaudeLocator {
    static let shimMarker = "cmux-claude-wrapper"
    /// Only the first bytes are read: the real binary weighs about 200 MB.
    static let headerBytes = 65_536
    static let versionTimeout: TimeInterval = 10

    /// Usual locations, in order of preference (without the path chosen by the user).
    public static func candidates(home: String) -> [String] {
        let base = home.hasSuffix("/") ? String(home.dropLast()) : home
        return [
            base + "/.local/bin/claude", base + "/.claude/local/claude", "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude", base + "/.npm-global/bin/claude",
        ]
    }

    /// First valid path: `override` and then `candidates(home:)`.
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

    /// Regular executable file after following links.
    static func isExecutableFile(_ path: String) -> Bool {
        var info = stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return false }
        return access(path, X_OK) == 0
    }

    /// Script (`#!`) that mentions cmux's wrapper in its first 64 KB.
    static func isCmuxShim(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: headerBytes), data.starts(with: [0x23, 0x21]) else {
            return false
        }
        return data.range(of: Data(shimMarker.utf8)) != nil
    }
}
