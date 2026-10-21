import Foundation

// MARK: - Paths mentioned in a reply

/// Context paths Claude mentions in a reply, to offer "Show on map".
public enum AssistantRoutes {
    /// Absolute paths of the context sent to the AI (nodes and cleanup item paths),
    /// without repeats and in context order. An unreadable context yields none.
    public static func contextPaths(_ context: String, home: String) -> [String] {
        guard let payload = try? JSONDecoder().decode(AIContextPayload.self, from: Data(context.utf8)) else {
            return []
        }
        var seen = Set<String>()
        var paths: [String] = []
        for raw in payload.nodes.map(\.path) + payload.cleanupItems.flatMap(\.paths) {
            let absolute = AIPaths.expand(raw, home: home)
            guard absolute.hasPrefix("/"), seen.insert(absolute).inserted else { continue }
            paths.append(absolute)
        }
        return paths
    }

    /// Paths from `candidates` (absolute) that appear in `text` in their absolute form or with `~`,
    /// in order of first appearance. If one mention contains another
    /// ("~/Library/Containers" versus "~/Library"), the longer one wins. "/" and the
    /// home folder ("~") are ignored: too general to lead to the map.
    public static func mentioned(in text: String, candidates: [String], home: String, limit: Int = 6) -> [String] {
        let base = AIPaths.base(home)
        var matches: [(range: Range<String.Index>, path: String)] = []
        for path in Set(candidates) where path != "/" && path != base && path.hasPrefix("/") {
            for form in Set([path, AIPaths.display(path, home: home)]) {
                var start = text.startIndex
                while start < text.endIndex, let range = text.range(of: form, range: start..<text.endIndex) {
                    if isBoundedMention(range, in: text) { matches.append((range, path)) }
                    start = text.index(after: range.lowerBound)
                }
            }
        }
        // The longest mention keeps its piece of text.
        let kept = matches.filter { match in
            !matches.contains { other in
                other.path != match.path && other.range.lowerBound <= match.range.lowerBound
                    && other.range.upperBound >= match.range.upperBound
                    && (other.range.lowerBound < match.range.lowerBound || other.range.upperBound > match.range.upperBound)
            }
        }.sorted { $0.range.lowerBound < $1.range.lowerBound }

        var seen = Set<String>()
        var result: [String] = []
        for match in kept where seen.insert(match.path).inserted {
            result.append(match.path)
            if result.count == max(0, limit) { break }
        }
        return result
    }

    private static func isPathCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_" || c == "-" || c == "." || c == "/" || c == "~"
    }

    /// Neither starts in the middle of another path nor continues with more name (".cache/uvx", "uv.zip", "uv/archive").
    /// A trailing "." or "/" is fine if the path does not continue after it (end of sentence, quotes…).
    private static func isBoundedMention(_ range: Range<String.Index>, in text: String) -> Bool {
        if range.lowerBound > text.startIndex, isPathCharacter(text[text.index(before: range.lowerBound)]) {
            return false
        }
        guard range.upperBound < text.endIndex else { return true }
        let next = text[range.upperBound]
        if next.isLetter || next.isNumber || next == "_" || next == "-" { return false }
        if next == "." || next == "/" {
            let after = text.index(after: range.upperBound)
            return after == text.endIndex || !isPathCharacter(text[after])
        }
        return true
    }
}

// MARK: - Report columns

/// The report's three risk columns, always in the same order, even when empty.
public enum ReportColumns {
    public struct Column: Sendable, Identifiable {
        public var risk: Risk
        /// Largest to smallest.
        public var recommendations: [AIRecommendation]
        /// Sum without counting twice a path that lies inside another one in the same column.
        public var totalBytes: Int64
        public var id: Int { risk.rawValue }
    }

    public static func columns(_ report: AIReport) -> [Column] {
        [Risk.safe, .yourCall, .doNotTouch].map { risk in
            let recommendations = report.recommendations.filter { $0.verdict == risk }
                .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.path < $1.path }
            let total = recommendations.filter { rec in
                !recommendations.contains { other in
                    other.path != rec.path
                        && RiskPolicy.isInside(RiskPolicy.canonical(rec.path), root: RiskPolicy.canonical(other.path))
                }
            }.reduce(Int64(0)) { $0 + $1.bytes }
            return Column(risk: risk, recommendations: recommendations, totalBytes: total)
        }
    }
}

// MARK: - Button of each recommendation

/// What a recommendation's button does. It always goes through `AppModel` and `CleanupExecutor`,
/// which repeat all their checks right before acting.
public enum AssistantCleanupAction: Sendable {
    /// Catalog cleanup (`AppModel.perform`): revalidates entry, paths, open apps and references.
    case perform(CleanupItem)
    /// Loose paths to the Trash (`AppModel.trash(paths:title:)`).
    case trashPaths([String])
}

public struct AssistantActionOffer: Sendable {
    public var action: AssistantCleanupAction
    /// "Up to you": an explicit second confirmation is needed.
    public var needsSecondConfirmation: Bool
    /// Method for the confirmation: "To the Trash" or "Official command: …".
    public var method: String
    public var isCommand: Bool
    /// Size of what is actually touched (the cleanup item, or the loose path).
    public var bytes: Int64
}

/// Button (or lack of one) of a report recommendation, already validated by `AIAssistant`:
/// - "Do not touch": never a button.
/// - "Safe to delete" with an action: one tap (and the usual confirmation), through the cleanup item.
/// - "Up to you": only "Move to Trash…" (`AppModel.trash(paths:title:)`), with a second
///   confirmation, and never where the right cleanup is an official command or the entry is informational only.
public enum AssistantOffer: Sendable, Equatable {
    case none
    case offer(AssistantActionOffer)
    /// There would be a button, but it is not possible right now (not detected, used by a project…).
    case unavailable(String)

    static var notDetected: String { String(localized: "It does not show up in Cleanup right now. Scan the disk again.", bundle: .airyCore) }

    public static func make(for rec: AIRecommendation, items: [CleanupItem], catalog: Catalog?,
                            home: String) -> AssistantOffer {
        switch rec.verdict {
        case .doNotTouch:
            return .none
        case .safe:
            switch rec.action {
            case .runCatalogCommand(let id):
                // Only the item the card shows: the one for that path (or the id of an item without paths).
                let target = items.first { item in
                    item.entry.id == id && (item.id == rec.path || item.paths.contains { overlaps($0, rec.path) })
                }
                guard let target else { return .unavailable(notDetected) }
                if !target.usedBy.isEmpty { return .unavailable(usedByReason(target.usedBy)) }
                return .offer(AssistantActionOffer(action: .perform(target), needsSecondConfirmation: false,
                                                   method: method(for: target.entry.cleanup),
                                                   isCommand: !isTrash(target.entry.cleanup), bytes: target.bytes))
            case .trash(let path):
                // The detected item for that same path (revalidates open apps and entry) or, failing that, the
                // loose path: `trashPaths` applies open apps, references and protected locations all the same.
                if let detected = detectedTrashItem(exactly: path, items: items) {
                    if !detected.usedBy.isEmpty { return .unavailable(usedByReason(detected.usedBy)) }
                    return .offer(AssistantActionOffer(action: .perform(detected), needsSecondConfirmation: false,
                                                       method: method(for: .trash), isCommand: false,
                                                       bytes: detected.bytes))
                }
                return .offer(AssistantActionOffer(action: .trashPaths([path]), needsSecondConfirmation: false,
                                                   method: method(for: .trash), isCommand: false, bytes: rec.bytes))
            case nil:
                return .none
            }
        case .yourCall:
            let path = rec.path
            guard path.hasPrefix("/") else { return .none }
            // Where an official command rules (or there is only information), nothing is deleted by hand.
            let handsOff = items.contains { item in
                !isTrash(item.entry.cleanup) && item.paths.contains { overlaps($0, path) }
            }
            if handsOff { return .none }
            if let entry = catalog?.match(path: path, home: home), !isTrash(entry.cleanup) { return .none }
            if let detected = detectedTrashItem(exactly: path, items: items), !detected.usedBy.isEmpty {
                return .unavailable(usedByReason(detected.usedBy))
            }
            return .offer(AssistantActionOffer(action: .trashPaths([path]), needsSecondConfirmation: true,
                                               method: method(for: .trash), isCommand: false, bytes: rec.bytes))
        }
    }

    /// Detected item (with Trash) whose only path is exactly `path`.
    private static func detectedTrashItem(exactly path: String, items: [CleanupItem]) -> CleanupItem? {
        let key = RiskPolicy.canonical(path)
        return items.first { item in
            isTrash(item.entry.cleanup) && item.paths.count == 1 && RiskPolicy.canonical(item.paths[0]) == key
        }
    }

    static func method(for cleanup: CleanupMethod) -> String {
        switch cleanup {
        case .trash, .info: return String(localized: "To the Trash", bundle: .airyCore)
        case .command(let executable, let arguments, _):
            let name = (executable as NSString).lastPathComponent
            return String(localized: "Official command: \(([name] + arguments).joined(separator: " "))", bundle: .airyCore)
        }
    }

    private static func usedByReason(_ usedBy: [String]) -> String {
        String(localized: "Used by: \(usedBy.prefix(3).joined(separator: ", "))\(usedBy.count > 3 ? "…" : "").", bundle: .airyCore)
    }

    private static func isTrash(_ cleanup: CleanupMethod) -> Bool {
        if case .trash = cleanup { return true }
        return false
    }

    /// One path inside the other (or the same).
    private static func overlaps(_ a: String, _ b: String) -> Bool {
        let a = RiskPolicy.canonical(a), b = RiskPolicy.canonical(b)
        return RiskPolicy.isInside(a, root: b) || RiskPolicy.isInside(b, root: a)
    }

    public static func == (a: AssistantOffer, b: AssistantOffer) -> Bool {
        switch (a, b) {
        case (.none, .none): return true
        case (.unavailable(let x), .unavailable(let y)): return x == y
        case (.offer(let x), .offer(let y)):
            guard x.method == y.method, x.needsSecondConfirmation == y.needsSecondConfirmation,
                  x.bytes == y.bytes else { return false }
            switch (x.action, y.action) {
            case (.perform(let i), .perform(let j)): return i.id == j.id && i.paths == j.paths
            case (.trashPaths(let p), .trashPaths(let q)): return p == q
            default: return false
            }
        default: return false
        }
    }
}

// MARK: - Conversation

public struct ChatBubble: Identifiable, Sendable, Equatable {
    public enum Status: Sendable, Equatable { case streaming, done, stopped, failed(String) }

    public let id: Int
    public var role: ChatMessage.Role
    public var text: String
    public var status: Status
    /// Context paths mentioned in the reply (for "Show on map").
    public var routes: [String]
}

/// The chat conversation: bubbles, the reply that arrives by streaming and the history that is
/// sent to Claude on each turn (without the questions that were left unanswered).
public struct ChatTranscript: Sendable {
    public private(set) var bubbles: [ChatBubble] = []
    private var nextID = 0

    public init() {}

    public var isStreaming: Bool { bubbles.last?.status == .streaming }

    /// Adds the question and an empty in-progress reply; returns the history to send.
    /// `nil` if the question is empty or a reply is already in progress.
    public mutating func begin(_ question: String) -> [ChatMessage]? {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return nil }
        let history = answeredHistory(upTo: bubbles.count) + [ChatMessage(role: .user, text: text)]
        append(.user, text, .done)
        append(.assistant, "", .streaming)
        return history
    }

    public mutating func append(_ delta: String) {
        guard isStreaming else { return }
        bubbles[bubbles.count - 1].text += delta
    }

    public mutating func finish(routes: [String]) {
        guard isStreaming else { return }
        bubbles[bubbles.count - 1].status = .done
        bubbles[bubbles.count - 1].routes = routes
    }

    /// Stops the reply: what had arrived stays; if nothing had, the bubble disappears.
    public mutating func stop() {
        guard isStreaming else { return }
        if bubbles[bubbles.count - 1].text.isEmpty {
            bubbles.removeLast()
        } else {
            bubbles[bubbles.count - 1].status = .stopped
        }
    }

    public mutating func fail(_ message: String) {
        guard isStreaming else { return }
        bubbles[bubbles.count - 1].status = .failed(message)
    }

    /// Repeats the last question if its reply failed. Returns the history to send.
    public mutating func retry() -> [ChatMessage]? {
        guard bubbles.count >= 2, case .failed = bubbles[bubbles.count - 1].status,
              bubbles[bubbles.count - 2].role == .user else { return nil }
        let question = bubbles[bubbles.count - 2].text
        let history = answeredHistory(upTo: bubbles.count - 2) + [ChatMessage(role: .user, text: question)]
        bubbles[bubbles.count - 1].text = ""
        bubbles[bubbles.count - 1].routes = []
        bubbles[bubbles.count - 1].status = .streaming
        return history
    }

    /// Question-answer pairs with a reply (finished or stopped) among the first `end` bubbles.
    private func answeredHistory(upTo end: Int) -> [ChatMessage] {
        var history: [ChatMessage] = []
        var index = 0
        while index < end {
            let bubble = bubbles[index]
            if bubble.role == .user, index + 1 < end {
                let answer = bubbles[index + 1]
                if answer.role == .assistant, !answer.text.isEmpty,
                   answer.status == .done || answer.status == .stopped {
                    history.append(ChatMessage(role: .user, text: bubble.text))
                    history.append(ChatMessage(role: .assistant, text: answer.text))
                    index += 2
                    continue
                }
            }
            index += 1
        }
        return history
    }

    private mutating func append(_ role: ChatMessage.Role, _ text: String, _ status: ChatBubble.Status) {
        nextID += 1
        bubbles.append(ChatBubble(id: nextID, role: role, text: text, status: status, routes: []))
    }
}

// MARK: - Chat text

public enum ChatText {
    /// Inline-only Markdown (bold, italics, `code`), keeping line breaks and **without
    /// links**: a reply can never open anything outside the app (`file://…/x.command`, schemes…).
    public static func rendered(_ text: String) -> AttributedString {
        var result = (try? AttributedString(
            markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        result = stripLinks(result)
        return result
    }

    public static func stripLinks(_ text: AttributedString) -> AttributedString {
        var copy = text
        for run in copy.runs where run.link != nil {
            copy[run.range].link = nil
        }
        return copy
    }
}
