import Foundation

/// One sentence that explains why a row is green, amber or red. A single source for the list, the
/// Map card, the confirmation sheet and the MCP.
public enum RiskExplanation {
    /// In `shortReason`, "{size}" is replaced by the item's size ("You would have to download
    /// {size} again." ⇒ "… download 4.2 GB again."); without a size, "the contents".
    public static let sizePlaceholder = "{size}"

    /// Priority (first that applies): doNotTouch ⇒ reason, protection, entry, fixed text; yourCall ⇒ reason,
    /// entry, "it is in your personal folders", size; safe ⇒ entry, "It recreates itself.".
    public static func why(risk: Risk, entry: CatalogEntry?, protection: ProtectionMatch?, reason: String?,
                           bytes: Int64, personal: Bool) -> String {
        let short = entry?.shortReason.map { expand($0, bytes: bytes) }
        switch risk {
        case .doNotTouch:
            return nonEmpty(reason) ?? protection?.reason ?? short ?? String(localized: "It belongs to the system or holds data that cannot be recovered.", bundle: .airyCore)
        case .yourCall:
            if let text = nonEmpty(reason) ?? short { return text }
            if personal { return String(localized: "It is in your personal folders: only you know whether you need it.", bundle: .airyCore) }
            if bytes > 0 { return String(localized: "You lose what is inside (\(Format.bytes(bytes))); it does not come back by itself.", bundle: .airyCore) }
            return String(localized: "You lose what is inside; it does not come back by itself.", bundle: .airyCore)
        case .safe:
            return short ?? String(localized: "It recreates itself.", bundle: .airyCore)
        }
    }

    /// For a list item. "Review only" rows start with their entry's hint.
    public static func why(_ item: CleanupItem, home: String = NSHomeDirectory()) -> String {
        if CleanupBoard.isReviewOnly(item), let hint = item.entry.reviewHint, !hint.isEmpty { return hint }
        let personal = item.paths.contains { RiskPolicy.minimumRisk(forPath: $0, home: home) == .yourCall }
        return why(risk: item.risk, entry: item.entry, protection: item.protection, reason: item.riskReason,
                   bytes: item.bytes, personal: personal)
    }

    static func expand(_ text: String, bytes: Int64) -> String {
        text.replacingOccurrences(of: sizePlaceholder, with: bytes > 0 ? Format.bytes(bytes) : String(localized: "the contents", bundle: .airyCore))
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }
}
