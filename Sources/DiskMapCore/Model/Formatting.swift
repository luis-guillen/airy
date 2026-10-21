import Foundation

public enum Format {
    /// Formatting locale for the language in use: the user's own locale when it speaks that language (so an
    /// English UI keeps the user's region), otherwise a default one (`es_ES`, `en_US`).
    static var locale: Locale {
        let language = AiryLanguage.current
        if Locale.current.language.languageCode?.identifier == language { return .current }
        return Locale(identifier: language == "es" ? "es_ES" : "en_US")
    }

    public static func bytes(_ value: Int64) -> String {
        // ByteCountFormatter takes no locale; its equivalent FormatStyle does.
        value.formatted(.byteCount(style: .file).locale(locale))
    }

    /// With "+" when the scan could not read everything inside: "12.3 GB+".
    public static func bytes(_ value: Int64, partial: Bool) -> String {
        bytes(value) + (partial ? "+" : "")
    }

    public static func relativeDate(_ date: Date?) -> String {
        guard let date else { return "—" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// Path with the home folder abbreviated as "~" ("/Users/ana/Library" → "~/Library").
    public static func tildePath(_ path: String, home: String = NSHomeDirectory()) -> String {
        let base = home.count > 1 && home.hasSuffix("/") ? String(home.dropLast()) : home
        guard !base.isEmpty, base != "/" else { return path }
        if path == base { return "~" }
        if path.hasPrefix(base + "/") { return "~" + path.dropFirst(base.count) }
        return path
    }
}
