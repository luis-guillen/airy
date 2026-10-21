import Foundation

/// Commands Airy accepts by URL (`airy://…`). A URL can come from a website or from another app, so
/// it is treated as hostile input: here it is only validated and cleaned; the app never acts on its
/// own, it only shows the confirmation to the user.
///
/// - `airy://propose?item=<id>&reason=<r>&agent=<a>` / `airy://propose?path=<p>&reason=<r>&agent=<a>`
/// - `airy://show?path=<p>`
/// - `airy://rescan`
/// - `airy://quit?app=<bundle id or name>&reason=<r>&agent=<a>` (only prepares the quit confirmation)
/// - `airy://uninstall?bundle=<id>&reason=<r>&agent=<a>` (only prepares the uninstall confirmation)
public enum AiryURLCommand: Sendable, Equatable {
    public enum ProposeTarget: Sendable, Equatable { case item(String), path(String) }

    case propose(target: ProposeTarget, reason: String, agent: String?)
    case show(path: String)
    case rescan
    case proposeQuit(app: String, reason: String, agent: String?)
    case uninstall(bundleID: String, reason: String, agent: String?)

    public static let scheme = "airy"
    public static let maxReason = 500, maxAgent = 64, maxPath = 1024, maxItemID = 200

    /// `nil` if the URL is not a valid command (scheme, host, path or id outside the rules).
    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil, components.port == nil,
              components.path.isEmpty || components.path == "/",
              let host = components.host?.lowercased() else { return nil }

        // A repeated parameter is ambiguous: it is rejected instead of picking one.
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
        case "uninstall":
            guard let id = query["bundle"], Self.isSafeBundleID(id) else { return nil }
            let agent = query["agent"].map { Self.sanitised($0, limit: Self.maxAgent) }
            self = .uninstall(bundleID: id, reason: Self.sanitised(query["reason"] ?? "", limit: Self.maxReason),
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
        case .uninstall(let id, let reason, let agent):
            host = "uninstall"
            items = [("bundle", id)]
            if !reason.isEmpty { items.append(("reason", reason)) }
            if let agent { items.append(("agent", agent)) }
        }
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = host
        if !items.isEmpty {
            // Strict encoding of our own: `&`, `+`, `#` or `=` inside a value must not
            // be able to change the query's structure.
            components.percentEncodedQuery = items
                .map { "\($0.0)=\(Self.percentEncoded($0.1))" }
                .joined(separator: "&")
        }
        return components.url!
    }

    // MARK: Validation and cleaning

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func percentEncoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    /// C0/C1 controls, line and paragraph separators, and text direction controls (they allow
    /// spoofing what the user reads in the confirmation sheet).
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

    /// `^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$`
    static func isSafeBundleID(_ id: String) -> Bool {
        guard let first = id.unicodeScalars.first, id.unicodeScalars.count <= 200 else { return false }
        func alnum(_ s: Unicode.Scalar) -> Bool {
            ("a"..."z").contains(s) || ("A"..."Z").contains(s) || ("0"..."9").contains(s)
        }
        return alnum(first) && id.unicodeScalars.allSatisfy { alnum($0) || $0 == "." || $0 == "_" || $0 == "-" }
    }

    private static func isSafeItemID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= maxItemID && !id.unicodeScalars.contains(where: isControl)
    }

    /// Control → space, whitespace trimming and truncation to `limit` characters with "…".
    private static func sanitised(_ text: String, limit: Int) -> String {
        var cleaned = String.UnicodeScalarView()
        for scalar in text.unicodeScalars { cleaned.append(isControl(scalar) ? " " : scalar) }
        let trimmed = String(cleaned).trimmingCharacters(in: .whitespaces)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
