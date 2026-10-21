import Foundation

public struct BrokenLink: Sendable, Equatable, Identifiable {
    public let path: String, target: String, needsAdmin: Bool
    public var id: String { path }

    public init(path: String, target: String, needsAdmin: Bool) {
        self.path = path
        self.target = target
        self.needsAdmin = needsAdmin
    }
}

/// Broken symbolic links in `/usr/local/bin` (uninstalled tools that left their link behind).
public enum BrokenLinks {
    public static let directory = "/usr/local/bin"

    /// lstat S_IFLNK, readlink, stat == ENOENT ⇒ broken (other errors ⇒ not listed); needsAdmin = access(dir, W_OK) != 0.
    public static func find(in directory: String = BrokenLinks.directory) -> [BrokenLink] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }
        let needsAdmin = access(directory, W_OK) != 0
        var links: [BrokenLink] = []
        for name in names.sorted() where !name.contains("/") {
            let path = directory + "/" + name
            var info = stat()
            guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK,
                  let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else { continue }
            var resolved = stat()
            guard stat(path, &resolved) != 0, errno == ENOENT else { continue }
            links.append(BrokenLink(path: path, target: target, needsAdmin: needsAdmin))
        }
        return links
    }

    static let commandPrefix = ["/usr/bin/find"]
    static let commandFilter = ["-maxdepth", "1", "-type", "l", "("]
    static let commandSuffix = [")", "!", "-exec", "/bin/test", "-e", "{}", ";", "-delete"]

    /// ["/usr/bin/find", dir, "-maxdepth", "1", "-type", "l", "(", "-name", n1, "-o", "-name", n2, ")",
    ///  "!", "-exec", "/bin/test", "-e", "{}", ";", "-delete"]
    static func deleteCommand(directory: String, names: [String]) -> [String] {
        var middle: [String] = []
        for (index, name) in names.enumerated() {
            if index > 0 { middle.append("-o") }
            middle += ["-name", globEscaped(name)]
        }
        return commandPrefix + [directory] + commandFilter + middle + commandSuffix
    }

    /// \ * ? [ ] preceded by \
    static func globEscaped(_ name: String) -> String {
        var result = ""
        for character in name {
            if "\\*?[]".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }

    static func globUnescaped(_ pattern: String) -> String {
        var result = ""
        var escaping = false
        for character in pattern {
            if !escaping, character == "\\" { escaping = true; continue }
            escaping = false
            result.append(character)
        }
        return result
    }

    /// `true` only if `command` is exactly `deleteCommand(directory: "/usr/local/bin", names:)` for non-empty
    /// names without "/" (the only way to delete links the privileged runner accepts).
    static func isAllowedDeleteCommand(_ command: [String]) -> Bool {
        let head = commandPrefix + [directory] + commandFilter
        guard command.count > head.count + commandSuffix.count,
              Array(command.prefix(head.count)) == head,
              Array(command.suffix(commandSuffix.count)) == commandSuffix else { return false }
        let middle = Array(command.dropFirst(head.count).dropLast(commandSuffix.count))
        var names: [String] = []
        var index = 0
        while index < middle.count {
            if index > 0 {
                guard middle[index] == "-o" else { return false }
                index += 1
            }
            guard index + 1 < middle.count, middle[index] == "-name" else { return false }
            let name = globUnescaped(middle[index + 1])
            guard !name.isEmpty, !name.contains("/") else { return false }
            names.append(name)
            index += 2
        }
        return !names.isEmpty && deleteCommand(directory: directory, names: names) == command
    }
}
