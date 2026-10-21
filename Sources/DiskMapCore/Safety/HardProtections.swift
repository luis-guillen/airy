import Foundation

/// Why a path is protected and who protects it.
public struct ProtectionMatch: Sendable, Equatable {
    public enum Source: String, Sendable { case airy, user }
    /// Which rule of the hard list matched (`.other` outside it, e.g. the user's list).
    public enum Rule: String, Sendable { case critical, sealedSystem, sealedHome, upward, fragment, sensitiveAppData, other }
    public let source: Source
    public let pattern: String
    /// Visible reason, localized.
    public let reason: String
    public let rule: Rule
    /// What the protection covers. Display information only: it never changes what is protected.
    public var scope: Scope

    /// `folderOnly`: the folder is not deleted as a whole (and neither are its parents), but what is inside
    /// can be cleaned (`/Users`, the home, `~/Library`…). `folderAndContents`: neither the folder nor anything
    /// inside it is touched (`/System`, `~/Library/Mail`, keys, browser profiles…).
    public enum Scope: String, Sendable { case folderOnly = "folder_only", folderAndContents = "folder_and_contents" }

    public init(source: Source, pattern: String, reason: String, rule: Rule = .other,
                scope: Scope = .folderAndContents) {
        self.source = source; self.pattern = pattern; self.reason = reason; self.rule = rule; self.scope = scope
    }
}

/// Airy's hard list: what is never deleted. The user does not edit it and it always applies, on top of their
/// settings. Path lists adapted from the research on Mole (§2.15); no Mole code.
public struct HardProtections: Sendable {
    public static let standard = HardProtections(criticalRoots: defaultCriticalRoots)

    /// Paths whose inode is never deleted (critical roots; `PathGate` adds the home and resolves them with `stat`).
    public let criticalRoots: [String]
    /// Sealed system locations: neither the location itself, nor anything inside, nor its parent folders.
    let sealedSystemLocations: [String]

    /// Tests only: other critical roots (the rest of the hard list does not change).
    init(criticalRoots: [String]) {
        self.init(criticalRoots: criticalRoots, sealedSystemLocations: Self.defaultSealedSystemLocations)
    }

    /// Tests only: other critical roots and other sealed system locations.
    init(criticalRoots: [String], sealedSystemLocations: [String]) {
        self.criticalRoots = criticalRoots
        self.sealedSystemLocations = sealedSystemLocations
        canonicalCriticalRoots = Set(criticalRoots.map(RiskPolicy.canonical))
    }

    private let canonicalCriticalRoots: Set<String>

    // MARK: - Lists

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

    /// Sealed home locations (relative to home; `*` within a component): neither itself, nor inside, nor parents.
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

    /// Upward (relative to home; `""` is the home): neither itself nor its parents; its contents are fine.
    static let upwardHomeLocations = [
        "", "Documents", "Desktop", "Pictures", "Movies", "Music", "Downloads", "orca", "Projects", "Library",
        "Applications", ".Trash", ".cache", ".config", ".local", ".local/bin", ".local/lib", ".local/share",
        ".local/state", "Library/Application Support", "Library/Caches", "Library/Containers",
        "Library/Group Containers", "Library/Preferences", "Library/Logs", "Library/Developer",
    ]

    /// Fragments: if any path component contains one (case-insensitive), it is not touched.
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

    /// Layer C: data folders of sensitive apps under these home roots.
    static let appDataRoots = ["Library/Application Support", "Library/Containers", "Library/Group Containers"]
    /// The folder's normalized name **contains** one of these.
    static let sensitiveAppNames = """
        1password onepassword agilebits bitwarden lastpass dashlane keepass authy yubico jetbrains vscode sublime typora cursor claude \
        chatgpt openai codex ollama lmstudio perplexity drawthings windsurf gemini postman insomnia charles \
        proxyman clash surge tailscale zerotier wireguard openvpn cloudflare nordvpn expressvpn protonvpn mullvad \
        githubdesktop gitkraken sublimemerge iterm2 kitty alacritty wezterm docker orbstack vmware parallels \
        virtualbox vagrant alfred raycast karabiner rectangle bartender obsidian notion logseq evernote dayone \
        goodnotes adobe figma sketch affinity pixelmator maxon autodesk nativeinstruments izotope fabfilter slack \
        discord teams telegram whatsapp wechat dropbox onedrive googledrive backblaze teamviewer anydesk \
        signal firefox mozilla vivaldi microsoftedge bravesoftware bravebrowser google safari thebrowser \
        operasoftware chromium
        """.split(separator: " ").map(String.init)
    /// The folder's last DNS component **is** one of these.
    static let sensitiveShortAppNames = ["jan", "box", "paw", "code", "bear", "zoom", "warp", "nova", "fork", "utm", "tower",
                                         "arc"]
    /// Sensitive folders outside the app data roots (relative to home): same as layer C, except what the
    /// catalog declares inside. `~/Library/Safari` keeps history, bookmarks and the last session.
    static let sensitiveHomeFolders: [(String, String)] = [("Library/Safari", "Safari")]
    /// Regenerable subtrees inside a sensitive app's folder, which can be touched.
    static let appDataCacheSubtrees = ["Caches", "Data/Library/Caches", "Data/tmp"]

    /// Visible names of some sealed locations (for the reason).
    static var friendlyNames: [String: String] {[
        "Library/Containers/com.docker.docker": String(localized: "Docker data", bundle: .airyCore),
        "Library/Group Containers/group.com.docker": String(localized: "Docker data", bundle: .airyCore),
        "Library/Mobile Documents": String(localized: "iCloud Drive", bundle: .airyCore), "Library/Mail": String(localized: "Mail", bundle: .airyCore), "Library/Messages": String(localized: "Messages", bundle: .airyCore),
        "Library/Keychains": String(localized: "Keychains", bundle: .airyCore), "Library/Accounts": String(localized: "Accounts", bundle: .airyCore), "Library/Contacts": String(localized: "Contacts", bundle: .airyCore),
        "Library/Calendars": String(localized: "Calendars", bundle: .airyCore), "Library/Application Support/AddressBook": String(localized: "Contacts", bundle: .airyCore),
        "Library/Photos": String(localized: "Photos", bundle: .airyCore), "Pictures/*.photoslibrary": String(localized: "Photos library", bundle: .airyCore), ".ssh": String(localized: "SSH keys", bundle: .airyCore),
        ".gnupg": String(localized: "GnuPG keys", bundle: .airyCore), ".orbstack": String(localized: "OrbStack data", bundle: .airyCore), "Library/Group Containers/*dev.orbstack": String(localized: "OrbStack data", bundle: .airyCore),
        ".cache/codex-runtimes/codex-primary-runtime": String(localized: "Codex runtime in use", bundle: .airyCore),
    ]}

    /// The user's temporary folder (resolved): the only exception inside `/private`.
    static let userTemporaryDirectory: String = {
        guard let real = realpath(NSTemporaryDirectory(), nil) else { return RiskPolicy.canonical(NSTemporaryDirectory()) }
        defer { free(real) }
        return RiskPolicy.canonical(String(cString: real))
    }()

    // MARK: - Check

    /// `canonicalPath` in lowercase (RiskPolicy.canonical). `nil` if it is not protected.
    /// `commandTarget`: the command entry whose `{target}` is being validated (its own declared path counts as a
    /// layer C exception, e.g. `~/Library/Safari/History.db` for `sqlite3 … VACUUM`). Never for the Trash.
    public func match(canonicalPath: String, home: String, catalog: Catalog?,
                      commandTarget: CatalogEntry? = nil) -> ProtectionMatch? {
        matches(canonicalPath: canonicalPath, home: home, catalog: catalog, commandTarget: commandTarget).first
    }

    /// Name of the child `contentsAreProtected` probes: no fragment, no sensitive app name, no catalog path.
    static let contentsProbeName = "airy-contents-probe-0"

    /// Display only: whether what is *inside* `path` is protected too. It probes an imaginary child of `path`:
    /// if no rule covers it, only the folder itself (and its parents) is protected, as with `/Users`, the home
    /// or `~/Library`. The critical-root rule never counts for the child (`/Users/<anything>` is a user folder,
    /// itself protected only as a whole). It never changes what `match`/`matches` protect.
    public func contentsAreProtected(path rawPath: String, home: String, catalog: Catalog?) -> Bool {
        let path = RiskPolicy.canonical(rawPath)
        let child = (path == "/" ? "" : path) + "/" + Self.contentsProbeName
        return rawMatches(canonicalPath: child, home: home, catalog: catalog, commandTarget: nil)
            .contains { $0.rule != .critical && $0.rule != .upward }
    }

    /// Every match, in the order `match` checks them; `match(...) == matches(...).first`. Each one carries the
    /// path's `scope` (display only).
    public func matches(canonicalPath rawPath: String, home rawHome: String, catalog: Catalog?,
                        commandTarget: CatalogEntry? = nil) -> [ProtectionMatch] {
        var found = rawMatches(canonicalPath: rawPath, home: rawHome, catalog: catalog, commandTarget: commandTarget)
        if !found.isEmpty, !contentsAreProtected(path: rawPath, home: rawHome, catalog: catalog) {
            for index in found.indices { found[index].scope = .folderOnly }
        }
        return found
    }

    /// The matches without their scope (`scope` stays `.folderAndContents`).
    private func rawMatches(canonicalPath rawPath: String, home rawHome: String, catalog: Catalog?,
                            commandTarget: CatalogEntry?) -> [ProtectionMatch] {
        let path = RiskPolicy.canonical(rawPath)
        let home = RiskPolicy.canonical(rawHome)
        let prefix = home == "/" ? "" : home
        let parts = Self.components(path)
        var found: [ProtectionMatch] = []

        // Critical roots: the path is one of them, a `/Users/<name>` or the home.
        if canonicalCriticalRoots.contains(path) || path == home || (parts.count == 2 && parts[0] == "users") {
            found.append(airy(path, String(localized: "Critical system folder.", bundle: .airyCore), .critical))
        }

        for location in sealedSystemLocations {
            let root = RiskPolicy.canonical(location)
            guard RiskPolicy.isInside(path, root: root) || RiskPolicy.isInside(root, root: path) else { continue }
            if root == "/private", RiskPolicy.isInside(path, root: Self.userTemporaryDirectory),
               path != Self.userTemporaryDirectory {
                continue
            }
            found.append(airy(location, String(localized: "Location protected by Airy: \(location).", bundle: .airyCore), .sealedSystem))
        }

        for location in Self.sealedHomeLocations {
            let pattern = Self.components(RiskPolicy.canonical(prefix + "/" + location))
            // Equal, inside (the path is longer) or parent (shorter): every shared component matches.
            guard zip(pattern, parts).allSatisfy({ Self.componentMatches($0, $1) }) else { continue }
            let name = Self.friendlyNames[location] ?? "~/" + location
            found.append(airy("~/" + location, String(localized: "Location protected by Airy: \(name).", bundle: .airyCore), .sealedHome))
        }

        for location in Self.upwardHomeLocations {
            let root = RiskPolicy.canonical(prefix + "/" + location)
            if RiskPolicy.isInside(root, root: path) {
                found.append(airy(location.isEmpty ? "~" : "~/" + location,
                                  String(localized: "Folder protected by Airy: it is not deleted as a whole.", bundle: .airyCore), .upward))
            }
        }

        // Layer C before the fragments (clearer reason); its exceptions do not bypass the fragments.
        if let match = sensitiveAppData(path: path, parts: parts, home: home, catalog: catalog,
                                        commandTarget: commandTarget) {
            found.append(match)
        }

        for part in parts {
            for fragment in Self.fragments where part.contains(fragment) {
                found.append(airy("*\(fragment)*", String(localized: "Component protected by Airy (\(fragment)).", bundle: .airyCore), .fragment))
            }
        }
        return found
    }

    /// Layer C: data of sensitive apps, except their caches and what the catalog declares inside.
    private func sensitiveAppData(path: String, parts: [String], home: String, catalog: Catalog?,
                                  commandTarget: CatalogEntry?) -> ProtectionMatch? {
        let prefix = home == "/" ? "" : home
        /// What the catalog declares inside `folder`, or the exact path of the entry whose `{target}` is being validated.
        func declared(inside folder: String) -> Bool {
            if let catalog, Self.catalogDeclares(path, inside: folder, catalog: catalog, home: home) { return true }
            if let commandTarget {
                return Self.catalogDeclares(path, inside: folder, catalog: Catalog(entries: [commandTarget]), home: home)
            }
            return false
        }
        for (location, name) in Self.sensitiveHomeFolders {
            let folder = RiskPolicy.canonical(prefix + "/" + location)
            guard RiskPolicy.isInside(path, root: folder) else { continue }
            if declared(inside: folder) { return nil }
            return airy("~/" + location, String(localized: "Data of a sensitive app (\(name)).", bundle: .airyCore), .sensitiveAppData)
        }
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
            if declared(inside: folder) { return nil }
            return airy("~/\(root)/\(folderLower)", String(localized: "Data of a sensitive app (\(appName)).", bundle: .airyCore), .sensitiveAppData)
        }
        return nil
    }

    /// Name that makes the folder sensitive, or `nil`.
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
        "thebrowser": "Arc", "operasoftware": "Opera",
    ]

    private static func displayName(_ name: String) -> String {
        displayNames[name] ?? name.prefix(1).uppercased() + name.dropFirst()
    }

    /// `true` if a literal pattern (without `*`) of an entry with an action declares a path inside `folder`
    /// and `path` is that path or lies inside it.
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
                // With a wildcard (e.g. "Chrome/*/Code Cache"): only if the last component is literal, so
                // the wildcard never spans a whole profile folder.
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

    /// Both lowercase; `*` within a component (fnmatch, no other wildcards).
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
