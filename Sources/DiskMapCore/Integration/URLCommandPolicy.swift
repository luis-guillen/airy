import Foundation

/// Limit on accepted `airy://` commands: any app or web page can open those links, so
/// a burst (also of `rescan`) must not leave the app unusable. At most `limit` commands every
/// `window` seconds; the extra ones are dropped (they do not count).
public struct URLCommandRateLimiter: Sendable {
    public static let defaultLimit = 3
    public static let defaultWindow: TimeInterval = 10

    public let limit: Int
    public let window: TimeInterval
    private var accepted: [Date] = []

    public init(limit: Int = URLCommandRateLimiter.defaultLimit,
                window: TimeInterval = URLCommandRateLimiter.defaultWindow) {
        self.limit = max(1, limit)
        self.window = window
    }

    /// `true` if the command arriving at `now` fits within the limit (and counts it).
    public mutating func allow(at now: Date = Date()) -> Bool {
        accepted.removeAll { now.timeIntervalSince($0) >= window || now < $0 }
        guard accepted.count < limit else { return false }
        accepted.append(now)
        return true
    }
}

/// Rules and texts of a proposal that arrived through `airy://propose`. The agent's name is set by whoever opens
/// the link and cannot be verified: it is shown and recorded as something it "claims to be", never as fact.
public enum URLProposalPolicy {
    public static var rateLimited: String { String(localized: "Airy received too many links in a row and ignored this one.", bundle: .airyCore) }
    public static var sheetOpen: String { String(localized: "A confirmation is already open; Airy ignored the proposal that arrived by link.", bundle: .airyCore) }
    public static var busy: String { String(localized: "Airy is cleaning; it ignored the proposal that arrived by link. Ask again in a moment.", bundle: .airyCore) }

    /// Reason to drop the proposal right now, or `nil`. It never replaces a sheet that is already open.
    public static func refusal(sheetOpen: Bool, busy: Bool) -> String? {
        if sheetOpen { return Self.sheetOpen }
        if busy { return Self.busy }
        return nil
    }

    /// Name the link carries, cleaned up for display (`nil` if it has none or it is empty).
    public static func claimedAgent(_ agent: String?) -> String? {
        guard let trimmed = agent?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Title and subtitle of the sheet's first step.
    public static func warningTitle() -> String { String(localized: "Proposal received by link", bundle: .airyCore) }

    public static func warningSubtitle(agent: String?, reason: String) -> String {
        let who = claimedAgent(agent).map { String(localized: "Claims to come from “\($0)” (Airy cannot verify it)", bundle: .airyCore) }
            ?? String(localized: "Proposed by an external app", bundle: .airyCore)
        let why = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(who) · \(why.isEmpty ? String(localized: "no reason", bundle: .airyCore) : why)"
    }

    public static var warningReason: String { String(localized: "Nothing is deleted until you confirm it here.", bundle: .airyCore) }
    public static var warningNote: String {
        String(localized: "Any app or web page can open an airy:// link. Check what it is before going on.", bundle: .airyCore) }

    /// Context with which what the user confirms is recorded: the name as an unverified claim.
    public static func context(runID: UUID, agent: String?) -> OperationContext {
        .user(runID: runID, proposedBy: claimedAgent(agent), proposedVia: OperationContext.viaUnverifiedURL)
    }

    /// Path trimmed for the notices (set by whoever opens the link): at most `limit` characters.
    public static func shortPath(_ path: String, limit: Int = 80) -> String {
        guard path.count > limit else { return path }
        let keep = max(1, limit - 1)
        return "…" + path.suffix(keep)
    }

    /// `true` if the record goes in "Agent activity": an agent did it, or the user confirmed something
    /// proposed by an agent or by link. The user's previews are not operations.
    public static func isAgentActivity(_ record: OperationRecord) -> Bool {
        if case .agent = record.actor { return true }
        return record.proposedBy != nil || record.proposedVia != nil
    }

    /// Who appears in "Agent activity" for a record.
    public static func activityAuthor(_ record: OperationRecord) -> String {
        if case .agent(let client) = record.actor { return client.isEmpty ? String(localized: "Agent", bundle: .airyCore) : client }
        if record.proposedVia == OperationContext.viaUnverifiedURL {
            let claim = claimedAgent(record.proposedBy).map { String(localized: "By link (claims to be “\($0)”)", bundle: .airyCore) } ?? String(localized: "By link from an external app", bundle: .airyCore)
            return String(localized: "\(claim) · confirmed by you", bundle: .airyCore)
        }
        let author = record.proposedBy ?? String(localized: "Agent", bundle: .airyCore)
        return String(localized: "\(author) · confirmed by you", bundle: .airyCore)
    }
}
