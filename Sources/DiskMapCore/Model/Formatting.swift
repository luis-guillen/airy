import Foundation

public enum Format {
    private static let locale = Locale(identifier: "es_ES")

    public static func bytes(_ value: Int64) -> String {
        // ByteCountFormatter no admite locale; su FormatStyle equivalente sí.
        value.formatted(.byteCount(style: .file).locale(locale))
    }

    public static func relativeDate(_ date: Date?) -> String {
        guard let date else { return "—" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// Ruta con la carpeta personal abreviada como "~" ("/Users/ana/Library" → "~/Library").
    public static func tildePath(_ path: String, home: String = NSHomeDirectory()) -> String {
        let base = home.count > 1 && home.hasSuffix("/") ? String(home.dropLast()) : home
        guard !base.isEmpty, base != "/" else { return path }
        if path == base { return "~" }
        if path.hasPrefix(base + "/") { return "~" + path.dropFirst(base.count) }
        return path
    }
}
