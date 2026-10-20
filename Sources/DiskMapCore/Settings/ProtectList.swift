import Foundation

/// Lista «Proteger esto»: rutas (con `*` por componente) que ni la app ni los agentes tocan.
public struct ProtectList: Sendable, Equatable {
    private let entries: [(stored: String, components: [String])]

    public static func == (a: ProtectList, b: ProtectList) -> Bool {
        a.entries.map(\.stored) == b.entries.map(\.stored)
    }

    public init(patterns: [String], home: String) {
        entries = patterns.compactMap { raw in
            guard let stored = Self.normalise(raw, home: home) else { return nil }
            return (stored, Self.components(of: Self.expand(stored, home: home)))
        }
    }

    /// Recorta, expande `~`, exige absoluta, rechaza `..`/`.`/control, colapsa `//`, quita la `/` final;
    /// devuelve la forma guardada con `~/` si está bajo home.
    public static func normalise(_ raw: String, home: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return nil }
        let absolute = expand(trimmed, home: home)
        guard absolute.hasPrefix("/") else { return nil }
        let parts = absolute.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty, !parts.contains(".."), !parts.contains(".") else { return nil }
        let homeParts = components(of: home)
        if !homeParts.isEmpty, parts.count >= homeParts.count, Array(parts.prefix(homeParts.count)) == homeParts {
            let rest = parts.dropFirst(homeParts.count)
            return rest.isEmpty ? "~" : "~/" + rest.joined(separator: "/")
        }
        return "/" + parts.joined(separator: "/")
    }

    /// Patrón que cubre `path` (lo iguala o lo contiene) o que está dentro de `path` (es carpeta superior);
    /// sin distinguir mayúsculas; `*` dentro de un componente (fnmatch).
    public func match(_ path: String) -> String? {
        let target = Self.components(of: path)
        guard !target.isEmpty else { return nil }
        for entry in entries {
            let n = min(entry.components.count, target.count)
            if (0..<n).allSatisfy({ Self.componentMatches(entry.components[$0], target[$0]) }) { return entry.stored }
        }
        return nil
    }

    private static func expand(_ s: String, home: String) -> String {
        if s == "~" { return home }
        if s.hasPrefix("~/") { return home + "/" + s.dropFirst(2) }
        return s
    }

    private static func components(of path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    private static func componentMatches(_ pattern: String, _ name: String) -> Bool {
        // Solo `*` es comodín: `[`, `?` y `\` se tratan como texto literal.
        var escaped = ""
        for ch in pattern {
            if ch == "[" || ch == "?" || ch == "\\" { escaped.append("\\") }
            escaped.append(ch)
        }
        return fnmatch(escaped, name, FNM_CASEFOLD) == 0
    }
}
