import Foundation

/// What Airy does with a Homebrew app: `brew uninstall --cask <token>` (never `--zap`) or, if Homebrew would do
/// something Airy cannot check, the normal path (the `.app` to the Trash with the waiver).
public enum CaskVerdict: Sendable, Equatable {
    case useBrew
    case fallback(reason: String)

    public var usesBrew: Bool { self == .useBrew }
}

/// Reads the cask's metadata (`brew info --cask --json=v2 <token>`, read-only) and decides whether Airy can let
/// Homebrew uninstall it. Fail closed: anything it does not understand ⇒ `.fallback`.
public enum CaskReview {
    public static var unsafeReason: String {
        String(localized: "Homebrew would do more than Airy can check; the app is moved to the Trash.", bundle: .airyCore) }
    public static var unreadableReason: String {
        String(localized: "Airy could not read what Homebrew would do when uninstalling it; the app is moved to the Trash.", bundle: .airyCore) }
    public static var brewMissingReason: String { String(localized: "Homebrew is not available; the app goes to the Trash.", bundle: .airyCore) }

    static let infoTimeout: TimeInterval = 60

    /// Arguments of the read-only query.
    static func infoArguments(token: String) -> [String] { ["info", "--cask", "--json=v2", token] }

    /// Token with safe characters (taps included: `user/tap/token`); it never starts with `-`.
    static func isValidToken(_ token: String) -> Bool {
        guard !token.isEmpty, !token.hasPrefix("-"), token.utf8.count <= 200 else { return false }
        return token.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || "-_.@+/".unicodeScalars.contains($0)
        }
    }

    /// Artifacts whose removal Airy understands. Others (`suite`, `artifact`, `font`, `prefpane`…) move or delete
    /// paths Airy does not check, and `uninstall_preflight`/`uninstall_postflight` run code.
    static let knownArtifacts: Set<String> = [
        "app", "binary", "manpage", "bash_completion", "zsh_completion", "fish_completion", "uninstall", "zap",
        "preflight", "postflight", "pkg", "installer", "stage_only",
    ]

    /// `uninstall` keys Airy understands; `signal`, `script`, `early_script` and any other ⇒ fallback.
    static let pathKeys: Set<String> = ["delete", "trash", "rmdir"]
    static let idKeys: Set<String> = ["quit", "launchctl", "pkgutil", "kext"]
    static let harmlessKeys: Set<String> = ["login_item"]

    /// - Parameters:
    ///   - json: output of `brew info --cask --json=v2 <token>`.
    ///   - refusal: full check without a waiver (`PathGate`); returns the reason if the path is protected.
    public static func verdict(json: String, token: String, app: AppRecord, home: String,
                               refusal: (String) -> String?) -> CaskVerdict {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let casks = root["casks"] as? [[String: Any]], casks.count == 1,
              let cask = casks.first,
              (cask["token"] as? String) == token || (cask["full_token"] as? String) == token,
              let artifacts = cask["artifacts"] as? [[String: Any]] else {
            return .fallback(reason: unreadableReason)
        }
        let bundleID = app.bundleID.lowercased()
        let appName = (app.path as NSString).lastPathComponent.lowercased()
        for artifact in artifacts {
            for (key, value) in artifact {
                guard knownArtifacts.contains(key) else { return .fallback(reason: unsafeReason) }
                switch key {
                case "app":
                    // Only the `.app` itself: if the cask brings other apps, Homebrew would delete them too.
                    guard let names = appTargets(value), !names.isEmpty,
                          names.allSatisfy({ $0.lowercased() == appName }) else {
                        return .fallback(reason: unsafeReason)
                    }
                case "uninstall":
                    guard let stanzas = value as? [Any] else { return .fallback(reason: unreadableReason) }
                    for stanza in stanzas {
                        guard let directives = stanza as? [String: Any] else { return .fallback(reason: unsafeReason) }
                        if !stanzaIsSafe(directives, bundleID: bundleID, app: app, home: home, refusal: refusal) {
                            return .fallback(reason: unsafeReason)
                        }
                    }
                default:
                    // `zap` never runs (Airy does not pass `--zap`); the rest deletes nothing when uninstalling.
                    continue
                }
            }
        }
        return .useBrew
    }

    private static func stanzaIsSafe(_ directives: [String: Any], bundleID: String, app: AppRecord, home: String,
                                     refusal: (String) -> String?) -> Bool {
        for (key, value) in directives {
            if harmlessKeys.contains(key) { continue }
            guard let entries = strings(value) else { return false }
            if idKeys.contains(key) {
                guard !bundleID.isEmpty else { return false }
                for entry in entries {
                    let lower = entry.lowercased()
                    guard lower == bundleID || lower.hasPrefix(bundleID + ".") else { return false }
                }
            } else if pathKeys.contains(key) {
                for entry in entries where !pathIsSafe(entry, app: app, home: home, refusal: refusal) { return false }
            } else {
                return false
            }
        }
        return true
    }

    /// A `delete`/`trash`/`rmdir` path: the `.app` itself, or a path that passes every protection.
    /// With wildcards: the pattern as is and every match that exists now.
    static func pathIsSafe(_ raw: String, app: AppRecord, home: String, refusal: (String) -> String?) -> Bool {
        var path = raw
        if path == "~" { path = home } else if path.hasPrefix("~/") { path = home + path.dropFirst(1) }
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        guard path.hasPrefix("/") else { return false }
        if RiskPolicy.canonical(path) == RiskPolicy.canonical(app.path) { return true }
        if refusal(path) != nil { return false }
        guard path.contains(where: { "*?[{".contains($0) }) else { return true }
        for match in globMatches(path) {
            if RiskPolicy.canonical(match) == RiskPolicy.canonical(app.path) { continue }
            if refusal(match) != nil { return false }
        }
        return true
    }

    private static func globMatches(_ pattern: String) -> [String] {
        var result = glob_t()
        defer { globfree(&result) }
        guard glob(pattern, GLOB_BRACE | GLOB_TILDE, nil, &result) == 0 else { return [] }
        return (0..<Int(result.gl_pathc)).compactMap { result.gl_pathv[$0].flatMap { String(cString: $0) } }
    }

    /// A string or a list of strings; any other shape ⇒ `nil`.
    private static func strings(_ value: Any) -> [String]? {
        if let one = value as? String { return [one] }
        guard let many = value as? [Any] else { return nil }
        var out: [String] = []
        for item in many {
            guard let text = item as? String else { return nil }
            out.append(text)
        }
        return out
    }

    /// Names of the `app` artifact's `.app` bundles: `"X.app"`, `{"target": "Y.app"}` or `["X.app", {"target": …}]`.
    private static func appTargets(_ value: Any) -> [String]? {
        guard let items = value as? [Any] else { return nil }
        var names: [String] = []
        var index = 0
        while index < items.count {
            let item = items[index]
            if let text = item as? String {
                // `["X.app", {"target": "Y.app"}]` flattened: the target rules.
                if index + 1 < items.count, let next = items[index + 1] as? [String: Any],
                   let target = next["target"] as? String {
                    names.append((target as NSString).lastPathComponent)
                    index += 2
                    continue
                }
                names.append((text as NSString).lastPathComponent)
            } else if let dict = item as? [String: Any], let target = dict["target"] as? String {
                names.append((target as NSString).lastPathComponent)
            } else if let pair = item as? [Any], let inner = appTargets(pair) {
                names.append(contentsOf: inner)
            } else {
                return nil
            }
            index += 1
        }
        return names
    }
}
