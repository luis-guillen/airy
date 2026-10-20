import Foundation

/// Órdenes que Airy acepta por URL (`airy://…`). Una URL puede venir de una web o de otra app, así
/// que se trata como entrada hostil: aquí solo se valida y se limpia; la app nunca actúa por sí
/// misma, solo muestra la confirmación al usuario.
///
/// - `airy://propose?item=<id>&reason=<r>&agent=<a>` / `airy://propose?path=<p>&reason=<r>&agent=<a>`
/// - `airy://show?path=<p>`
/// - `airy://rescan`
/// - `airy://quit?app=<bundle id o nombre>&reason=<r>&agent=<a>` (solo prepara la confirmación de cierre)
public enum AiryURLCommand: Sendable, Equatable {
    public enum ProposeTarget: Sendable, Equatable { case item(String), path(String) }

    case propose(target: ProposeTarget, reason: String, agent: String?)
    case show(path: String)
    case rescan
    case proposeQuit(app: String, reason: String, agent: String?)

    public static let scheme = "airy"
    public static let maxReason = 500, maxAgent = 64, maxPath = 1024, maxItemID = 200

    /// `nil` si la URL no es una orden válida (esquema, destino, ruta o id fuera de las reglas).
    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil, components.port == nil,
              components.path.isEmpty || components.path == "/",
              let host = components.host?.lowercased() else { return nil }

        // Un parámetro repetido es ambiguo: se rechaza en vez de elegir uno.
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard query[item.name] == nil else { return nil }
            query[item.name] = item.value ?? ""
        }

        switch host {
        case "rescan":
            self = .rescan
        case "show":
            guard let path = query["path"], Self.isSafePath(path) else { return nil }
            self = .show(path: path)
        case "propose":
            let target: ProposeTarget
            switch (query["item"], query["path"]) {
            case (let id?, nil):
                guard Self.isSafeItemID(id) else { return nil }
                target = .item(id)
            case (nil, let path?):
                guard Self.isSafePath(path) else { return nil }
                target = .path(path)
            default:
                return nil
            }
            let agent = query["agent"].map { Self.sanitised($0, limit: Self.maxAgent) }
            self = .propose(target: target,
                            reason: Self.sanitised(query["reason"] ?? "", limit: Self.maxReason),
                            agent: (agent?.isEmpty ?? true) ? nil : agent)
        case "quit":
            guard let app = query["app"], Self.isSafeItemID(app) else { return nil }
            let agent = query["agent"].map { Self.sanitised($0, limit: Self.maxAgent) }
            self = .proposeQuit(app: app, reason: Self.sanitised(query["reason"] ?? "", limit: Self.maxReason),
                                agent: (agent?.isEmpty ?? true) ? nil : agent)
        default:
            return nil
        }
    }

    public var url: URL {
        var items: [(String, String)] = []
        let host: String
        switch self {
        case .rescan:
            host = "rescan"
        case .show(let path):
            host = "show"
            items = [("path", path)]
        case .propose(let target, let reason, let agent):
            host = "propose"
            switch target {
            case .item(let id): items.append(("item", id))
            case .path(let path): items.append(("path", path))
            }
            if !reason.isEmpty { items.append(("reason", reason)) }
            if let agent { items.append(("agent", agent)) }
        case .proposeQuit(let app, let reason, let agent):
            host = "quit"
            items = [("app", app)]
            if !reason.isEmpty { items.append(("reason", reason)) }
            if let agent { items.append(("agent", agent)) }
        }
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = host
        if !items.isEmpty {
            // Codificación propia y estricta: `&`, `+`, `#` o `=` dentro de un valor no deben
            // poder cambiar la estructura de la consulta.
            components.percentEncodedQuery = items
                .map { "\($0.0)=\(Self.percentEncoded($0.1))" }
                .joined(separator: "&")
        }
        return components.url!
    }

    // MARK: Validación y limpieza

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func percentEncoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    /// Controles C0/C1, separadores de línea y párrafo, y controles de dirección de texto (permiten
    /// suplantar lo que lee el usuario en la hoja de confirmación).
    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x061C, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069: return true
        default: break
        }
        switch scalar.properties.generalCategory {
        case .control, .lineSeparator, .paragraphSeparator: return true
        default: return false
        }
    }

    private static func isSafePath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path.count <= maxPath,
              !path.unicodeScalars.contains(where: isControl) else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: true).contains("..")
    }

    private static func isSafeItemID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= maxItemID && !id.unicodeScalars.contains(where: isControl)
    }

    /// Control → espacio, recorte de espacios y truncado a `limit` caracteres con «…».
    private static func sanitised(_ text: String, limit: Int) -> String {
        var cleaned = String.UnicodeScalarView()
        for scalar in text.unicodeScalars { cleaned.append(isControl(scalar) ? " " : scalar) }
        let trimmed = String(cleaned).trimmingCharacters(in: .whitespaces)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
