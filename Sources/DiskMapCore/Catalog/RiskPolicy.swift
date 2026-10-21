import Foundation

/// Risk floor per path and "strictest wins" combination of catalog and AI.
public enum RiskPolicy {
    static let personalRoots = [
        "Documents", "Desktop", "Pictures", "Movies", "Music", "Downloads", "orca", "Projects",
    ]

    public static func minimumRisk(forPath rawPath: String, home rawHome: String) -> Risk {
        let path = canonical(rawPath)
        if isInside(path, root: "/system") { return .doNotTouch }
        let base = canonical(rawHome)
        for name in personalRoots where isInside(path, root: (base == "/" ? "" : base) + "/" + name.lowercased()) {
            return .yourCall
        }
        return .safe
    }

    /// The strictest of floor, catalog and AI. Without a catalog entry, at least `.yourCall`:
    /// the AI can only raise the risk, never leave an unknown path as "safe".
    public static func effectiveRisk(path: String, home: String, catalog: Risk?, ai: Risk?) -> Risk {
        var risk = minimumRisk(forPath: path, home: home)
        if catalog == nil { risk = .strictest(risk, .yourCall) }
        if let catalog { risk = .strictest(risk, catalog) }
        if let ai { risk = .strictest(risk, ai) }
        return risk
    }

    // MARK: - Protected locations (Trash)

    /// The user's temporary folder (resolved): the only exception inside `/private`.
    static var userTemporaryDirectory: String { HardProtections.userTemporaryDirectory }

    /// Why a canonical path cannot go to the Trash, or `nil`.
    /// `homes`: the home folder (and its resolved form, if different). Delegates to `HardProtections`
    /// (a single list of rules); `catalog` allows the exceptions the catalog declares.
    public static func trashRefusal(forCanonicalPath path: String, homes: [String], catalog: Catalog? = nil) -> String? {
        for home in homes {
            if let match = HardProtections.standard.match(canonicalPath: path, home: home, catalog: catalog) {
                return match.reason
            }
        }
        return nil
    }

    /// Collapses `.`, `..` and repeated slashes, and lowercases (APFS is case-insensitive).
    /// Does not resolve symbolic links nor strip `/private`.
    static func canonical(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { _ = parts.popLast(); continue }
            parts.append(part)
        }
        return "/" + parts.joined(separator: "/").lowercased()
    }

    static func isInside(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }
}
