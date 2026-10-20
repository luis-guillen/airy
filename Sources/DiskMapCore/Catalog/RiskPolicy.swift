import Foundation

/// Suelo de riesgo por ruta y combinación "gana el más estricto" entre catálogo e IA.
public enum RiskPolicy {
    private static let personalRoots = [
        "Documents", "Desktop", "Pictures", "Movies", "Music", "Downloads", "orca", "Projects",
    ]

    public static func minimumRisk(forPath path: String, home: String) -> Risk {
        if isInside(path, root: "/System") { return .doNotTouch }
        let base = home.hasSuffix("/") ? String(home.dropLast()) : home
        for name in personalRoots where isInside(path, root: base + "/" + name) {
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

    static func isInside(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }
}
