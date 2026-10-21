import Foundation

/// Which Cleanup groups are open. Pure logic, so it can be tested: the view keeps the user's choices in
/// `UserDefaults` (`stored`) and asks here what to show.
///
/// Without a choice, "Safe to remove" is open, "Your call" is open only while it is small and "Don't delete"
/// and "Review only" are collapsed. A collapsed group still counts everywhere (header, "Select all"…): this
/// only decides what is drawn.
public struct CleanupDisclosure: Equatable, Sendable {
    public enum Group: String, CaseIterable, Sendable {
        case safe, yourCall, doNotTouch, review

        public init(risk: Risk) {
            switch risk {
            case .safe: self = .safe
            case .yourCall: self = .yourCall
            case .doNotTouch: self = .doNotTouch
            }
        }
    }

    /// Up to this many items, "Your call" opens by default.
    public static let smallGroupLimit = 5

    /// The groups the user opened or closed by hand. Missing ⇒ the default.
    public private(set) var choices: [Group: Bool]

    /// `stored`: what `stored` returned earlier (unknown keys are ignored).
    public init(stored: [String: Bool] = [:]) {
        var choices: [Group: Bool] = [:]
        for (key, open) in stored {
            if let group = Group(rawValue: key) { choices[group] = open }
        }
        self.choices = choices
    }

    public static func defaultOpen(_ group: Group, count: Int) -> Bool {
        switch group {
        case .safe: true
        case .yourCall: count <= smallGroupLimit
        case .doNotTouch, .review: false
        }
    }

    public func isOpen(_ group: Group, count: Int) -> Bool {
        choices[group] ?? Self.defaultOpen(group, count: count)
    }

    public mutating func setOpen(_ open: Bool, for group: Group) {
        choices[group] = open
    }

    /// Flips the group from what it shows now (`count`: its items, for the default).
    public mutating func toggle(_ group: Group, count: Int) {
        setOpen(!isOpen(group, count: count), for: group)
    }

    /// To save in `UserDefaults`.
    public var stored: [String: Bool] {
        Dictionary(uniqueKeysWithValues: choices.map { ($0.key.rawValue, $0.value) })
    }
}
