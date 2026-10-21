import Foundation

/// Por qué una ruta está protegida y quién la protege.
public struct ProtectionMatch: Sendable, Equatable {
    public enum Source: String, Sendable { case airy, user }
    /// Qué regla de la lista dura coincidió (`.other` fuera de ella, p. ej. la lista del usuario).
    public enum Rule: String, Sendable { case critical, sealedSystem, sealedHome, upward, fragment, sensitiveAppData, other }
    public let source: Source
    public let pattern: String
    /// Motivo visible, en español.
    public let reason: String
    public let rule: Rule

    public init(source: Source, pattern: String, reason: String, rule: Rule = .other) {
        self.source = source; self.pattern = pattern; self.reason = reason; self.rule = rule
    }
}

/// Lista dura de Airy: lo que nunca se borra. No la edita el usuario y se aplica siempre, encima de sus
/// ajustes. Listas de rutas adaptadas de la investigación sobre Mole (§2.15); ningún código de Mole.
public struct HardProtections: Sendable {
    public static let standard = HardProtections(criticalRoots: defaultCriticalRoots)

    /// Rutas cuyo inodo nunca se borra (raíces críticas; `PathGate` añade el home y las resuelve con `stat`).
    public let criticalRoots: [String]
    /// Selladas del sistema: ni ella, ni nada de dentro, ni sus carpetas superiores.
    let sealedSystemLocations: [String]

    /// Solo para pruebas: otras raíces críticas (el resto de la lista dura no cambia).
    init(criticalRoots: [String]) {
        self.init(criticalRoots: criticalRoots, sealedSystemLocations: Self.defaultSealedSystemLocations)
    }

    /// Solo para pruebas: otras raíces críticas y otras ubicaciones selladas del sistema.
    init(criticalRoots: [String], sealedSystemLocations: [String]) {
        self.criticalRoots = criticalRoots
        self.sealedSystemLocations = sealedSystemLocations
        canonicalCriticalRoots = Set(criticalRoots.map(RiskPolicy.canonical))
    }

    private let canonicalCriticalRoots: Set<String>

    // MARK: - Listas

    static let defaultCriticalRoots = [
        "/", "/bin", "/dev", "/sbin", "/usr", "/System", "/System/Volumes/Data", "/Library", "/Library/Apple",
        "/Library/Application Support", "/Library/Extensions", "/Library/Keychains", "/Applications",
        "/Applications/Safari.app", "/Volumes", "/opt", "/opt/homebrew", "/Users", "/Users/Shared", "/Users/Guest",
        "/private", "/private/tmp", "/etc", "/var", "/var/db", "/var/audit", "/var/root", "/private/var",
        "/private/var/tmp", "/private/var/folders", "/private/var/db", "/private/var/audit", "/private/var/root",
        "/Network", "/cores", "/home", "/net", "/tmp",
    ]

    static let defaultSealedSystemLocations = [
        "/System", "/Applications", "/Library", "/usr", "/bin", "/sbin", "/private", "/opt/homebrew",
        "/private/var/db/powerlog",
    ]

    /// Selladas del home (relativas a home; `*` dentro de un componente): ni ella, ni dentro, ni superiores.
    static let sealedHomeLocations = [
        "Library/Containers/com.docker.docker", "Library/Group Containers/group.com.docker",
        "Library/Mobile Documents", "Library/Mail", "Library/Messages", "Library/Keychains", "Library/Accounts",
        "Library/Contacts", "Library/Calendars", "Library/Application Support/AddressBook", "Library/Photos",
        "Pictures/*.photoslibrary", "Library/Application Support/com.apple.idleassetsd",
        "Library/Application Support/com.apple.wallpaper", "Library/Preferences/com.apple.dock.plist",
        "Library/Preferences/com.apple.finder.plist", "Library/Preferences/ByHost/com.apple.bluetooth.*",
        "Library/Preferences/com.apple.wifi.*", "Library/Preferences/com.apple.networkextension*",
        "Library/Caches/pypoetry/virtualenvs", "Library/Caches/org.R-project.R/R/renv", ".prometheus/data",
        ".orbstack", "Library/Group Containers/*dev.orbstack", ".cache/codex-runtimes/codex-primary-runtime",
        ".codex/auth.json", ".codex/sessions", ".codex/history.jsonl", ".codex/config.toml", ".claude.json",
        ".claude/projects", ".ssh", ".gnupg", ".gitconfig.bak*", ".zsh_history.bak*", ".bash_history.bak*",
    ]

    /// Hacia arriba (relativas a home; `""` es el home): ni ella ni sus superiores; su contenido sí.
    static let upwardHomeLocations = [
        "", "Documents", "Desktop", "Pictures", "Movies", "Music", "Downloads", "orca", "Projects", "Library",
        "Applications", ".Trash", ".cache", ".config", ".local", ".local/bin", ".local/lib", ".local/share",
        ".local/state", "Library/Application Support", "Library/Caches", "Library/Containers",
        "Library/Group Containers", "Library/Preferences", "Library/Logs", "Library/Developer",
    ]

    /// Fragmentos: si algún componente de la ruta los contiene (sin mayúsculas), no se toca.
    static let fragments = [
        "systemsettings", "systempreferences", "controlcenter", "com.apple.settings", "com.apple.notes",
        "finder.cache", "dock.cache", "coreaudio", "com.apple.audio.", "com.apple.fontregistry", "spotlight",
        "cloudkit", "com.apple.containermanagerd", "com.apple.homed", "com.apple.ap.adprivacyd", "familycircle",
        "homekit", "shortcutssandboxcache", "gippseudonymousid", "cctclearcutlogger",
        "com.apple.e5rt.e5bundlecache", "com.crowdstrike.", "com.sentinelone.", "com.sentinel-labs.",
        "com.eset.", "com.jamf.", "com.jamfsoftware.", "com.paloaltonetworks.", "com.cisco.anyconnect",
        "com.cisco.secureclient", "1password", "onepassword", "agilebits", "keychain", "bitwarden", "lastpass",
        "keepass", "dashlane", "enpass", "gnupg",
    ]

    /// Capa C: carpetas de datos de apps sensibles bajo estas raíces del home.
    static let appDataRoots = ["Library/Application Support", "Library/Containers", "Library/Group Containers"]
    /// El nombre normalizado de la carpeta **contiene** uno de estos.
    static let sensitiveAppNames = """
        1password onepassword agilebits bitwarden lastpass dashlane keepass authy yubico jetbrains vscode sublime typora cursor claude \
        chatgpt openai codex ollama lmstudio perplexity drawthings windsurf gemini postman insomnia charles \
        proxyman clash surge tailscale zerotier wireguard openvpn cloudflare nordvpn expressvpn protonvpn mullvad \
        githubdesktop gitkraken sublimemerge iterm2 kitty alacritty wezterm docker orbstack vmware parallels \
        virtualbox vagrant alfred raycast karabiner rectangle bartender obsidian notion logseq evernote dayone \
        goodnotes adobe figma sketch affinity pixelmator maxon autodesk nativeinstruments izotope fabfilter slack \
        discord teams telegram whatsapp wechat dropbox onedrive googledrive backblaze teamviewer anydesk \
        signal firefox mozilla vivaldi microsoftedge bravesoftware bravebrowser google
        """.split(separator: " ").map(String.init)
    /// El último componente DNS de la carpeta **es** uno de estos.
    static let sensitiveShortAppNames = ["jan", "box", "paw", "code", "bear", "zoom", "warp", "nova", "fork", "utm", "tower"]
    /// Subárboles regenerables dentro de una carpeta de app sensible, que sí se pueden tocar.
    static let appDataCacheSubtrees = ["Caches", "Data/Library/Caches", "Data/tmp"]

    /// Nombres visibles de algunas ubicaciones selladas (para el motivo).
    static let friendlyNames: [String: String] = [
        "Library/Containers/com.docker.docker": "datos de Docker",
        "Library/Group Containers/group.com.docker": "datos de Docker",
        "Library/Mobile Documents": "iCloud Drive", "Library/Mail": "Mail", "Library/Messages": "Mensajes",
        "Library/Keychains": "Llaveros", "Library/Accounts": "Cuentas", "Library/Contacts": "Contactos",
        "Library/Calendars": "Calendarios", "Library/Application Support/AddressBook": "Contactos",
        "Library/Photos": "Fotos", "Pictures/*.photoslibrary": "Fototeca", ".ssh": "claves SSH",
        ".gnupg": "claves GnuPG", ".orbstack": "datos de OrbStack", "Library/Group Containers/*dev.orbstack": "datos de OrbStack",
        ".cache/codex-runtimes/codex-primary-runtime": "runtime de Codex en uso",
    ]

    /// Carpeta temporal del usuario (resuelta): única excepción dentro de `/private`.
    static let userTemporaryDirectory: String = {
        guard let real = realpath(NSTemporaryDirectory(), nil) else { return RiskPolicy.canonical(NSTemporaryDirectory()) }
        defer { free(real) }
        return RiskPolicy.canonical(String(cString: real))
    }()

    // MARK: - Comprobación

    /// `canonicalPath` en minúsculas (RiskPolicy.canonical). `nil` si no está protegida.
    public func match(canonicalPath: String, home: String, catalog: Catalog?) -> ProtectionMatch? {
        matches(canonicalPath: canonicalPath, home: home, catalog: catalog).first
    }

    /// Todas las coincidencias, en el orden en que `match` las comprueba; `match(...) == matches(...).first`.
    public func matches(canonicalPath rawPath: String, home rawHome: String, catalog: Catalog?) -> [ProtectionMatch] {
        let path = RiskPolicy.canonical(rawPath)
        let home = RiskPolicy.canonical(rawHome)
        let prefix = home == "/" ? "" : home
        let parts = Self.components(path)
        var found: [ProtectionMatch] = []

        // Raíces críticas: la ruta es una de ellas, un `/Users/<nombre>` o el home.
        if canonicalCriticalRoots.contains(path) || path == home || (parts.count == 2 && parts[0] == "users") {
            found.append(airy(path, "Carpeta crítica del sistema.", .critical))
        }

        for location in sealedSystemLocations {
            let root = RiskPolicy.canonical(location)
            guard RiskPolicy.isInside(path, root: root) || RiskPolicy.isInside(root, root: path) else { continue }
            if root == "/private", RiskPolicy.isInside(path, root: Self.userTemporaryDirectory),
               path != Self.userTemporaryDirectory {
                continue
            }
            found.append(airy(location, "Ubicación protegida por Airy: \(location).", .sealedSystem))
        }

        for location in Self.sealedHomeLocations {
            let pattern = Self.components(RiskPolicy.canonical(prefix + "/" + location))
            // Igual, dentro (la ruta es más larga) o superior (más corta): todos los componentes comunes encajan.
            guard zip(pattern, parts).allSatisfy({ Self.componentMatches($0, $1) }) else { continue }
            let name = Self.friendlyNames[location] ?? "~/" + location
            found.append(airy("~/" + location, "Ubicación protegida por Airy: \(name).", .sealedHome))
        }

        for location in Self.upwardHomeLocations {
            let root = RiskPolicy.canonical(prefix + "/" + location)
            if RiskPolicy.isInside(root, root: path) {
                found.append(airy(location.isEmpty ? "~" : "~/" + location,
                                  "Carpeta protegida por Airy: no se borra entera.", .upward))
            }
        }

        // Capa C antes que los fragmentos (motivo más claro); sus excepciones no saltan los fragmentos.
        if let match = sensitiveAppData(path: path, parts: parts, home: home, catalog: catalog) { found.append(match) }

        for part in parts {
            for fragment in Self.fragments where part.contains(fragment) {
                found.append(airy("*\(fragment)*", "Componente protegido por Airy (\(fragment)).", .fragment))
            }
        }
        return found
    }

    /// Capa C: datos de apps sensibles, salvo sus cachés y lo que el catálogo declara dentro.
    private func sensitiveAppData(path: String, parts: [String], home: String, catalog: Catalog?) -> ProtectionMatch? {
        let prefix = home == "/" ? "" : home
        for root in Self.appDataRoots {
            let rootPath = RiskPolicy.canonical(prefix + "/" + root)
            let rootParts = Self.components(rootPath)
            guard parts.count > rootParts.count, Array(parts.prefix(rootParts.count)) == rootParts else { continue }
            let folderLower = parts[rootParts.count]
            guard let appName = Self.sensitiveAppName(folderLower) else { continue }
            let folder = rootPath + "/" + folderLower
            for subtree in Self.appDataCacheSubtrees
            where RiskPolicy.isInside(path, root: RiskPolicy.canonical(folder + "/" + subtree)) {
                return nil
            }
            if let catalog, Self.catalogDeclares(path, inside: folder, catalog: catalog, home: home) { return nil }
            return airy("~/\(root)/\(folderLower)", "Datos de una app sensible (\(appName)).", .sensitiveAppData)
        }
        return nil
    }

    /// Nombre que hace sensible la carpeta, o `nil`.
    static func sensitiveAppName(_ folder: String) -> String? {
        let lower = folder.lowercased()
        let normalised = lower.filter { !" .-_".contains($0) }
        if let long = sensitiveAppNames.first(where: { normalised.contains($0) }) { return displayName(long) }
        let lastDNS = String(lower.split(separator: ".").last ?? "").filter { !" -_".contains($0) }
        if sensitiveShortAppNames.contains(lastDNS) { return displayName(lastDNS) }
        return nil
    }

    private static let displayNames = [
        "1password": "1Password", "microsoftedge": "Microsoft Edge", "bravesoftware": "Brave", "bravebrowser": "Brave",
    ]

    private static func displayName(_ name: String) -> String {
        displayNames[name] ?? name.prefix(1).uppercased() + name.dropFirst()
    }

    /// `true` si un patrón literal (sin `*`) de una ficha con acción declara una ruta dentro de `folder`
    /// y `path` es esa ruta o está dentro de ella.
    private static func catalogDeclares(_ path: String, inside folder: String, catalog: Catalog, home: String) -> Bool {
        for entry in catalog.entries where entry.cleanup != .info {
            for pattern in entry.paths {
                var expanded = pattern
                if pattern == "~" { expanded = home } else if pattern.hasPrefix("~/") { expanded = home + pattern.dropFirst(1) }
                let declared = RiskPolicy.canonical(expanded)
                if !pattern.contains("*") {
                    if declared != folder, RiskPolicy.isInside(declared, root: folder), RiskPolicy.isInside(path, root: declared) {
                        return true
                    }
                    continue
                }
                // Con comodín (p. ej. «Chrome/*/Code Cache»): solo si el último componente es literal, para
                // que el comodín nunca abarque la carpeta de un perfil entera.
                let patternParts = components(declared)
                let folderParts = components(folder)
                guard let last = patternParts.last, !last.contains("*"),
                      patternParts.count > folderParts.count + 1,
                      Array(patternParts.prefix(folderParts.count)) == folderParts else { continue }
                let parts = components(path)
                if parts.count >= patternParts.count,
                   zip(patternParts, parts).allSatisfy({ componentMatches($0, $1) }) {
                    return true
                }
            }
        }
        return false
    }

    private func airy(_ pattern: String, _ reason: String, _ rule: ProtectionMatch.Rule) -> ProtectionMatch {
        ProtectionMatch(source: .airy, pattern: pattern, reason: reason, rule: rule)
    }

    static func components(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// Ambos en minúsculas; `*` dentro de un componente (fnmatch, sin otros comodines).
    static func componentMatches(_ pattern: String, _ name: String) -> Bool {
        guard pattern.contains("*") else { return pattern == name }
        var escaped = ""
        for ch in pattern {
            if ch == "[" || ch == "?" || ch == "\\" { escaped.append("\\") }
            escaped.append(ch)
        }
        return fnmatch(escaped, name, 0) == 0
    }
}
