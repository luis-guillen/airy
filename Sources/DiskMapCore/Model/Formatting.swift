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
}
