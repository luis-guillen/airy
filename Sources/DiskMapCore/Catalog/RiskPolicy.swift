import Foundation

/// Suelo de riesgo por ruta y combinación "gana el más estricto" entre catálogo e IA.
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

    /// El más estricto de suelo, catálogo e IA. Sin ficha del catálogo, al menos `.yourCall`:
    /// la IA solo puede subir el riesgo, nunca dejar en "sin riesgo" una ruta desconocida.
    public static func effectiveRisk(path: String, home: String, catalog: Risk?, ai: Risk?) -> Risk {
        var risk = minimumRisk(forPath: path, home: home)
        if catalog == nil { risk = .strictest(risk, .yourCall) }
        if let catalog { risk = .strictest(risk, catalog) }
        if let ai { risk = .strictest(risk, ai) }
        return risk
    }

    // MARK: - Ubicaciones protegidas (Papelera)

    /// Selladas: no van a la Papelera ni ellas, ni nada de dentro, ni sus carpetas superiores.
    static let sealedHomeLocations = [
        "Library/Containers/com.docker.docker", "Library/Group Containers/group.com.docker",
        "Library/Mobile Documents", "Library/Mail", "Library/Messages", "Library/Keychains",
        "Library/Application Support/AddressBook", "Library/Calendars", "Library/Photos",
    ]
    static let sealedSystemLocations = ["/Applications", "/Library", "/usr", "/bin", "/sbin", "/private", "/opt/homebrew"]

    /// Protegidas hacia arriba: no van a la Papelera ni ellas ni sus carpetas superiores (su contenido sí puede).
    static let protectedSystemRoots = [
        "/", "/System", "/Users", "/Applications", "/Library", "/usr", "/bin", "/sbin", "/etc",
        "/var", "/private", "/private/var", "/private/etc", "/opt", "/Volumes", "/cores",
    ]

    /// Carpeta temporal del usuario (resuelta): única excepción dentro de `/private`.
    static let userTemporaryDirectory: String = {
        guard let real = realpath(NSTemporaryDirectory(), nil) else { return canonical(NSTemporaryDirectory()) }
        defer { free(real) }
        return canonical(String(decoding: Data(bytes: real, count: strlen(real)), as: UTF8.self))
    }()

    /// Motivo por el que una ruta canónica no puede ir a la Papelera, o `nil`.
    /// `homes`: la carpeta personal (y su forma resuelta, si difiere).
    public static func trashRefusal(forCanonicalPath path: String, homes: [String]) -> String? {
        let bases = homes.map(canonical)
        var sealed = sealedSystemLocations.map(canonical)
        var upward = protectedSystemRoots.map(canonical)
        for base in bases {
            let prefix = base == "/" ? "" : base
            sealed += sealedHomeLocations.map { canonical(prefix + "/" + $0) }
            upward.append(base)
            upward += (personalRoots + ["Library", "Applications", ".Trash"]).map { canonical(prefix + "/" + $0) }
        }
        if isInside(path, root: "/system") { return "Ruta del sistema." }
        for location in upward where isInside(location, root: path) {
            return "Carpeta protegida."
        }
        for location in sealed where isInside(location, root: path) || isInside(path, root: location) {
            if location == "/private" && isInside(path, root: userTemporaryDirectory) && path != userTemporaryDirectory {
                continue
            }
            return "Ubicación protegida: \(location)."
        }
        return nil
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
