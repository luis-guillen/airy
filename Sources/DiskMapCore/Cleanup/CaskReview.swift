import Foundation

/// Qué hace Airy con una app de Homebrew: `brew uninstall --cask <token>` (nunca `--zap`) o, si Homebrew haría
/// algo que Airy no puede comprobar, el camino normal (el `.app` a la Papelera con la dispensa).
public enum CaskVerdict: Sendable, Equatable {
    case useBrew
    case fallback(reason: String)

    public var usesBrew: Bool { self == .useBrew }
}

/// Lee los metadatos del cask (`brew info --cask --json=v2 <token>`, solo lectura) y decide si Airy puede dejar
/// que Homebrew la desinstale. Fallo cerrado: cualquier cosa que no entienda ⇒ `.fallback`.
public enum CaskReview {
    public static let unsafeReason =
        "Homebrew haría más cosas de las que Airy puede comprobar; la app se mueve a la Papelera."
    public static let unreadableReason =
        "Airy no pudo leer qué haría Homebrew al desinstalarla; la app se mueve a la Papelera."
    public static let brewMissingReason = "Homebrew no está disponible; la app va a la Papelera."

    static let infoTimeout: TimeInterval = 60

    /// Argumentos de la consulta de solo lectura.
    static func infoArguments(token: String) -> [String] { ["info", "--cask", "--json=v2", token] }

    /// Token con caracteres seguros (taps incluidos: `usuario/tap/token`); nunca empieza por `-`.
    static func isValidToken(_ token: String) -> Bool {
        guard !token.isEmpty, !token.hasPrefix("-"), token.utf8.count <= 200 else { return false }
        return token.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || "-_.@+/".unicodeScalars.contains($0)
        }
    }

    /// Artefactos cuya retirada Airy entiende. Otros (`suite`, `artifact`, `font`, `prefpane`…) mueven o borran
    /// rutas que Airy no comprueba, y `uninstall_preflight`/`uninstall_postflight` ejecutan código.
    static let knownArtifacts: Set<String> = [
        "app", "binary", "manpage", "bash_completion", "zsh_completion", "fish_completion", "uninstall", "zap",
        "preflight", "postflight", "pkg", "installer", "stage_only",
    ]

    /// Claves de `uninstall` que Airy entiende; `signal`, `script`, `early_script` y cualquier otra ⇒ fallback.
    static let pathKeys: Set<String> = ["delete", "trash", "rmdir"]
    static let idKeys: Set<String> = ["quit", "launchctl", "pkgutil", "kext"]
    static let harmlessKeys: Set<String> = ["login_item"]

    /// - Parameters:
    ///   - json: salida de `brew info --cask --json=v2 <token>`.
    ///   - refusal: comprobación completa sin dispensa (`PathGate`); devuelve el motivo si la ruta está protegida.
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
                    // Solo el propio `.app`: si el cask trae otras apps, Homebrew las borraría también.
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
                    // `zap` nunca se ejecuta (Airy no pasa `--zap`); el resto no borra nada al desinstalar.
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

    /// Una ruta de `delete`/`trash`/`rmdir`: el propio `.app`, o una ruta que pasa todas las protecciones.
    /// Con comodines: el patrón tal cual y cada coincidencia que exista ahora.
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

    /// Una cadena o una lista de cadenas; otra forma ⇒ `nil`.
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

    /// Nombres de los `.app` del artefacto `app`: `"X.app"`, `{"target": "Y.app"}` o `["X.app", {"target": …}]`.
    private static func appTargets(_ value: Any) -> [String]? {
        guard let items = value as? [Any] else { return nil }
        var names: [String] = []
        var index = 0
        while index < items.count {
            let item = items[index]
            if let text = item as? String {
                // `["X.app", {"target": "Y.app"}]` aplanado: el destino manda.
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
