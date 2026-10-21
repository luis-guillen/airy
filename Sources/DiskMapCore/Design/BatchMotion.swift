import Foundation

/// Pure rules of a deletion batch in Cleanup: when there is a gust and what the counter says.
public enum BatchMotion {
    /// Ids in execution order if the batch deserves a gust (two rows or more); otherwise, `nil`.
    public static func gustOrder(ids: [String]) -> [String]? {
        ids.count >= 2 ? ids : nil
    }

    /// What a batch clears away. It adds up what was freed and what was moved to the Trash, but does not
    /// mix them up: what is in the Trash is not freed until it is emptied.
    public struct Tally: Equatable, Sendable {
        public private(set) var freed: Int64 = 0
        public private(set) var movedToTrash: Int64 = 0

        public init() {}

        public var bytes: Int64 { freed + movedToTrash }

        /// "freed" only if nothing went to the Trash; otherwise, "cleared".
        public var label: String { movedToTrash == 0 ? String(localized: "freed", bundle: .airyCore) : String(localized: "cleared", bundle: .airyCore) }

        public var help: String? {
            movedToTrash == 0 ? nil : String(localized: "What was moved to the Trash is freed when you empty it", bundle: .airyCore)
        }

        public mutating func add(_ outcome: CleanupOutcome) {
            switch outcome {
            case .freed(let bytes): freed += max(bytes, 0)
            case .movedToTrash(let bytes): movedToTrash += max(bytes, 0)
            case .blocked, .failed: break
            }
        }
    }

    public static func tally(_ outcomes: [CleanupOutcome]) -> Tally {
        outcomes.reduce(into: Tally()) { $0.add($1) }
    }
}
