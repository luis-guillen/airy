import Foundation

/// A file the user can review and send to the Trash (Large and old, File types).
public struct ActionableFile: Sendable, Equatable, Identifiable {
    public let path: String, name: String, bytes: Int64, kind: ContentKind
    public let lastModified: Date?, lastOpened: Date?
    public let risk: Risk, protection: ProtectionMatch?, reasons: [String]
    /// `true` if Spotlight did not answer in time: the last-used date is unknown (it is not "old").
    public let openDateUnknown: Bool
    public var id: String { path }
    public var canSelect: Bool { risk != .doNotTouch && protection == nil }
    /// The most recent of `lastModified` and `lastOpened`.
    public var lastActivity: Date? {
        switch (lastModified, lastOpened) {
        case let (a?, b?): max(a, b)
        case let (a?, nil): a
        case let (nil, b?): b
        case (nil, nil): nil
        }
    }

    public init(path: String, name: String, bytes: Int64, kind: ContentKind, lastModified: Date?, lastOpened: Date?,
                risk: Risk, protection: ProtectionMatch?, reasons: [String], openDateUnknown: Bool = false) {
        self.path = path; self.name = name; self.bytes = bytes; self.kind = kind
        self.lastModified = lastModified; self.lastOpened = lastOpened
        self.risk = risk; self.protection = protection; self.reasons = reasons
        self.openDateUnknown = openDateUnknown
    }

    /// risk = classifier.classify(path:).risk; if the catalog entry does not exist or does not `regenerates`, at least
    /// `.yourCall`; `gate.validate` fails ⇒ `.doNotTouch` with the protection and the refusal reasons.
    public static func make(node: FileNode, classifier: RiskClassifier, catalog: Catalog?, gate: PathGate,
                            lastOpened: Date?, home: String = NSHomeDirectory(),
                            openDateUnknown: Bool = false) -> ActionableFile {
        let path = node.path
        let classification = classifier.classify(path: path)
        var risk = classification.risk
        var protection = classification.protection
        var reasons = classification.reasons
        if let entry = catalog?.match(path: path, home: home) {
            if !entry.regenerates { risk = .strictest(risk, .yourCall) }
        } else {
            risk = .strictest(risk, .yourCall)
        }
        if protection == nil, case let .failure(refusal) = gate.validate(path) {
            protection = ProtectionMatch(source: .airy, pattern: path, reason: refusal.reason)
            reasons.append(refusal.reason)
        }
        if protection != nil { risk = .doNotTouch }
        if openDateUnknown { reasons.append(String(localized: "Could not tell when it was last opened.", bundle: .airyCore)) }
        return ActionableFile(path: path, name: node.name, bytes: node.allocatedSize, kind: node.kind,
                              lastModified: node.lastModified, lastOpened: lastOpened, risk: risk,
                              protection: protection, reasons: reasons, openDateUnknown: openDateUnknown)
    }
}

/// Selection shared by the file sections: it never contains red or protected items.
public struct FileSelection: Sendable, Equatable {
    public private(set) var ids: Set<String>
    public init() { ids = [] }

    public mutating func toggle(_ file: ActionableFile) {
        guard file.canSelect else { return }
        if ids.remove(file.id) == nil { ids.insert(file.id) }
    }

    public mutating func selectAllGreen(_ files: [ActionableFile]) {
        for file in files where file.canSelect && file.risk == .safe { ids.insert(file.id) }
    }

    /// Green + selectable amber.
    public mutating func selectAll(_ files: [ActionableFile]) {
        for file in files where file.canSelect && file.risk != .doNotTouch { ids.insert(file.id) }
    }

    public mutating func clear() { ids = [] }

    /// Removes what is no longer in `files` or can no longer be checked.
    public mutating func prune(to files: [ActionableFile]) {
        let valid = Set(files.filter(\.canSelect).map(\.id))
        ids.formIntersection(valid)
    }

    public func selected(in files: [ActionableFile]) -> [ActionableFile] {
        files.filter { ids.contains($0.id) && $0.canSelect }
    }

    public func bytes(in files: [ActionableFile]) -> Int64 {
        selected(in: files).reduce(0) { $0 + $1.bytes }
    }

    /// Green, amber and red, without empty groups.
    public static func groups(_ files: [ActionableFile]) -> [(risk: Risk, files: [ActionableFile])] {
        [Risk.safe, .yourCall, .doNotTouch].compactMap { risk in
            let group = files.filter { $0.risk == risk }
            return group.isEmpty ? nil : (risk, group)
        }
    }
}
