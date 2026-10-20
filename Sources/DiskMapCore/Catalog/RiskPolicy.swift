import Foundation

/// Suelo de riesgo por ruta y combinación "gana el más estricto" entre catálogo e IA.
public enum RiskPolicy {
    private static let personalRoots = [
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

    /// El más estricto de suelo, catálogo e IA. Sin catálogo ni IA, al menos `.yourCall`.
    public static func effectiveRisk(path: String, home: String, catalog: Risk?, ai: Risk?) -> Risk {
        var risk = minimumRisk(forPath: path, home: home)
        if catalog == nil && ai == nil { risk = .strictest(risk, .yourCall) }
        if let catalog { risk = .strictest(risk, catalog) }
        if let ai { risk = .strictest(risk, ai) }
        return risk
    }

    /// Colapsa `.`, `..` y barras repetidas, y pasa a minúsculas (APFS no distingue mayúsculas).
    /// No resuelve enlaces simbólicos ni quita `/private`.
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
