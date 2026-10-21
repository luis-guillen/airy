import Foundation

/// Pure logic of the Cleanup view: groups by risk, what can be checked, what goes into
/// "Clean everything safe" and the blocking and method texts. No SwiftUI, so it can be tested.
public struct CleanupBoard: Sendable {
    public struct Group: Sendable, Identifiable {
        public let risk: Risk
        /// Profile highlights first; then largest to smallest (ties by id, for a stable order).
        public let items: [CleanupItem]
        public var id: Risk { risk }
        /// "Safe to remove", "Your call" or "Don't delete".
        public var title: String { risk.label }
        public var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
    }

    /// "Safe to remove", "Your call" and "Don't delete", in that order and without empty groups. "Review only"
    /// goes separately (`reviewItems`).
    public let groups: [Group]

    /// "Review only": informational items without an action, largest to smallest (ties by id).
    public let reviewItems: [CleanupItem]

    /// `hidden`: items already cleaned that are hidden right away, before the new detection arrives.
    public init(items: [CleanupItem], hidden: Set<String> = []) {
        let visible = items.filter { !hidden.contains($0.id) }
        reviewItems = visible.filter(Self.isReviewOnly).sorted { (a, b) in (a.bytes, b.id) > (b.bytes, a.id) }
        let actionable = visible.filter { !Self.isReviewOnly($0) }
        groups = [Risk.safe, .yourCall, .doNotTouch].compactMap { risk in
            // By size (the "For you" profile is retired: `highlighted` no longer sorts).
            let members = actionable.filter { $0.risk == risk }
                .sorted { a, b in (a.bytes, b.id) > (b.bytes, a.id) }
            return members.isEmpty ? nil : Group(risk: risk, items: members)
        }
    }

    /// Items with a group (without "Review only") in screen order.
    public var items: [CleanupItem] { groups.flatMap(\.items) }

    /// Everything that is shown: the groups (green, amber, red) and then "Review only".
    public var displayItems: [CleanupItem] { items + reviewItems }

    /// Informational item shown with its hint and no checkbox: `.info` with a `reviewHint`, or not "Do not touch"
    /// (Docker volumes and the like stay in "Don't delete"). Even if the protections leave it red, if it has
    /// a hint it is for review.
    public static func isReviewOnly(_ item: CleanupItem) -> Bool {
        guard case .info = item.entry.cleanup else { return false }
        return item.entry.reviewHint != nil || item.risk != .doNotTouch
    }

    // MARK: Header

    /// "You can free X": only `.safe` items with an action (including those waiting for you to close an
    /// app; not those a project uses).
    public var safeBytes: Int64 {
        items.filter { $0.risk == .safe && Self.showsCheckbox($0) && $0.usedBy.isEmpty }.reduce(0) { $0 + $1.bytes }
    }

    /// What "Clean everything safe" runs: `.safe`, with an action and not blocked.
    public var readySafeItems: [CleanupItem] {
        items.filter { $0.risk == .safe && Self.canSelect($0) }
    }

    public var readySafeBytes: Int64 { readySafeItems.reduce(0) { $0 + $1.bytes } }

    /// `true` if `safeBytes` includes partial cleanups: the header says "You can free up to".
    public var safeBytesIsUpperBound: Bool {
        items.contains { $0.risk == .safe && Self.showsCheckbox($0) && $0.usedBy.isEmpty && Self.isPartial($0) }
    }

    // MARK: Partial cleanups

    /// The official command only removes part (`partialCleanup` in the catalog): its size is a maximum.
    public static func isPartial(_ item: CleanupItem) -> Bool { item.entry.partialCleanup }

    /// `sizeNote` if there is one ("Unknown size"); otherwise "up to 3.6 GB" for partial cleanups, and "+" if the
    /// scan could not read all of it.
    public static func sizeText(_ item: CleanupItem) -> String {
        if let note = item.sizeNote { return note }
        return amountText(item.bytes, upperBound: isPartial(item)) + (item.sizeIsPartial ? "+" : "")
    }

    public static func amountText(_ bytes: Int64, upperBound: Bool) -> String {
        upperBound ? String(localized: "up to \(Format.bytes(bytes))", bundle: .airyCore) : Format.bytes(bytes)
    }

    /// Sum of the items and whether it is only a maximum (some are partial).
    public static func total(_ items: [CleanupItem]) -> (bytes: Int64, upperBound: Bool) {
        (items.reduce(0) { $0 + $1.bytes }, items.contains(where: isPartial))
    }

    // MARK: Selection

    /// It has a checkbox if Airy can act on it: not "Do not touch", not protected, not informational only.
    public static func showsCheckbox(_ item: CleanupItem) -> Bool {
        guard item.risk != .doNotTouch, item.entry.risk != .doNotTouch, item.protection == nil else { return false }
        if case .info = item.entry.cleanup { return false }
        return true
    }

    /// Can be checked now: with a checkbox, without open apps blocking it, without projects using it,
    /// without protection and without any other block.
    public static func canSelect(_ item: CleanupItem) -> Bool {
        showsCheckbox(item) && item.blockedByOpenApps.isEmpty && item.usedBy.isEmpty
            && item.protection == nil && item.blockedReason == nil
    }

    /// The green items that can be cleaned right away.
    public var greenSelection: Set<String> { Set(readySafeItems.map(\.id)) }

    /// "Select all": green and amber items that can be checked. Never red, protected, blocked or informational.
    public var fullSelection: Set<String> {
        Set(items.filter { $0.risk != .doNotTouch && Self.canSelect($0) }.map(\.id))
    }

    /// After a new detection: drops what no longer applies and checks the preselected items the user had not
    /// seen yet (`seen`), so as not to re-check what they unchecked. Also returns the updated `seen`.
    public func nextSelection(current: Set<String>, seen: Set<String>) -> (selection: Set<String>, seen: Set<String>) {
        var selection = pruned(current)
        var seenNow = seen
        for item in items where Self.canSelect(item) {
            if item.preselected, !seen.contains(item.id) { selection.insert(item.id) }
            seenNow.insert(item.id)
        }
        return (selection, seenNow)
    }

    /// "Delete all · 3.2 GB", or "Delete all · up to 3.2 GB" if some cleanup is partial.
    public static func deleteAllTitle(_ items: [CleanupItem]) -> String {
        let sum = total(items)
        return String(localized: "Delete all · \(amountText(sum.bytes, upperBound: sum.upperBound))", bundle: .airyCore)
    }

    public static var reviewBlockTitle: String { String(localized: "Review: this does not regenerate by itself or may hold state", bundle: .airyCore) }

    /// Single confirmation: `regular` = green; `review` = amber, in the order received. What was removed (`removed`) and
    /// what cannot be checked (red, protected, blocked) are left out.
    public static func confirmSections(_ items: [CleanupItem], excluding removed: Set<String>)
        -> (regular: [CleanupItem], review: [CleanupItem]) {
        let kept = items.filter { !removed.contains($0.id) && canSelect($0) }
        return (kept.filter { $0.risk == .safe }, kept.filter { $0.risk == .yourCall })
    }

    /// The checked items that are still valid, in screen order.
    public func selected(_ ids: Set<String>) -> [CleanupItem] {
        items.filter { ids.contains($0.id) && Self.canSelect($0) }
    }

    public func selectedBytes(_ ids: Set<String>) -> Int64 {
        selected(ids).reduce(0) { $0 + $1.bytes }
    }

    /// The selection without what no longer exists or can no longer be checked (after a new detection).
    public func pruned(_ ids: Set<String>) -> Set<String> {
        Set(selected(ids).map(\.id))
    }

    // MARK: Texts

    private static let knownApps: [String: String] = [
        "com.spotify.client": "Spotify",
        "com.brave.Browser": "Brave",
        "com.google.Chrome": "Google Chrome",
        "com.apple.Safari": "Safari",
        "com.anthropic.claudefordesktop": "Claude",
        "com.openai.chat": "ChatGPT",
    ]

    /// Readable name of an app from its bundle ID (the view prefers the open app's own name).
    public static func appName(forBundleID bundleID: String) -> String {
        if let known = knownApps[bundleID] { return known }
        return bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    }

    /// "Quit Spotify to clean this" (or "Quit A, B and C …").
    public static func blockedMessage(appNames: [String]) -> String? {
        guard !appNames.isEmpty else { return nil }
        return String(localized: "Quit \(naturalList(appNames)) to clean this", bundle: .airyCore)
    }

    /// "Used by: ~/Projects/app/main.py" (at most three paths and "and N more").
    public static func usedByMessage(_ usedBy: [String], home: String = NSHomeDirectory()) -> String? {
        guard !usedBy.isEmpty else { return nil }
        let shown = usedBy.prefix(3).map { Format.tildePath($0, home: home) }
        let rest = usedBy.count - shown.count
        let list = shown.joined(separator: ", ")
        return rest > 0 ? String(localized: "Used by: \(list) and \(rest) more", bundle: .airyCore) : String(localized: "Used by: \(list)", bundle: .airyCore)
    }

    /// "To the Trash", "Official command: docker builder prune -a -f" or "Informational only".
    public static func methodDescription(_ method: CleanupMethod) -> String {
        switch method {
        case .trash: String(localized: "To the Trash", bundle: .airyCore)
        case .info: String(localized: "Informational only", bundle: .airyCore)
        case .command: String(localized: "Official command: \(commandLine(method) ?? "")", bundle: .airyCore)
        }
    }

    /// The command as it runs (executable and arguments), written to be read; `nil` if it is not a command.
    /// It is only text: the app runs it with `Process` and an argument array, never through a shell.
    public static func commandLine(_ method: CleanupMethod) -> String? {
        guard case .command(let executable, let arguments, _) = method else { return nil }
        return ([executable] + arguments).map(displayQuoted).joined(separator: " ")
    }

    /// The command of a preview (`CleanupPreview.wouldRun`), with the same quoting.
    public static func commandLine(_ argv: [String]) -> String {
        argv.map(displayQuoted).joined(separator: " ")
    }

    /// Why a row with a checkbox cannot be cleaned right now (open processes, incomplete
    /// check…), to show it in the row itself. `nil` if it is not blocked that way or is protected
    /// (then `protectionText` says so).
    public static func blockedReasonText(_ item: CleanupItem) -> String? {
        guard item.protection == nil, let reason = item.blockedReason, !reason.isEmpty else { return nil }
        return reason
    }

    /// What a protected row says: "Protected by you" or "Protected by Airy: <reason>".
    public static func protectionText(_ protection: ProtectionMatch) -> String {
        switch protection.source {
        case .user: String(localized: "Protected by you", bundle: .airyCore)
        case .airy: String(localized: "Protected by Airy: \(protection.reason)", bundle: .airyCore)
        }
    }

    /// What a protection covers, in one sentence (display only): only the folder as a whole, or the folder and
    /// everything inside it.
    public static func protectionScopeText(_ protection: ProtectionMatch) -> String {
        switch protection.scope {
        case .folderOnly: String(localized: "Airy won’t delete this whole folder, but you can clean what’s inside.", bundle: .airyCore)
        case .folderAndContents: String(localized: "Neither this folder nor anything inside it is deleted.", bundle: .airyCore)
        }
    }

    private static let plain = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./=:,@%+")

    private static func displayQuoted(_ word: String) -> String {
        guard word.isEmpty || !word.allSatisfy(plain.contains) else { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Where what is about to be touched lives: the path, "first · and N more", or "Everything in
    /// ~/Library/Logs (N items)" when they are all the children of a catalog `folder/*` pattern.
    public static func locationSummary(_ item: CleanupItem, home: String = NSHomeDirectory()) -> String? {
        let paths = item.paths
        guard let first = paths.first else { return nil }
        if paths.count == 1 { return Format.tildePath(first, home: home) }
        let parent = (first as NSString).deletingLastPathComponent
        let base = home.count > 1 && home.hasSuffix("/") ? String(home.dropLast()) : home
        let wildcardParents = item.entry.paths.compactMap { pattern -> String? in
            guard pattern.hasSuffix("/*") else { return nil }
            let folder = String(pattern.dropLast(2))
            if folder == "~" { return base }
            return folder.hasPrefix("~/") ? base + folder.dropFirst(1) : folder
        }
        if wildcardParents.contains(parent),
           paths.allSatisfy({ ($0 as NSString).deletingLastPathComponent == parent }) {
            return String(localized: "Everything in \(Format.tildePath(parent, home: home)) (\(paths.count) items)", bundle: .airyCore)
        }
        return String(localized: "\(Format.tildePath(first, home: home)) · and \(paths.count - 1) more", bundle: .airyCore)
    }

    /// The item with only the paths that still exist (those that vanished since the
    /// detection do not block the rest); `nil` if none is left. Without paths (commands), as is.
    /// The executor validates every remaining path again.
    public static func withExistingPaths(_ item: CleanupItem, exists: (String) -> Bool) -> CleanupItem? {
        guard !item.paths.isEmpty else { return item }
        var copy = item
        copy.paths = item.paths.filter(exists)
        return copy.paths.isEmpty ? nil : copy
    }

    public static func yourCallNote(count: Int) -> String {
        count == 1
            ? String(localized: "Includes 1 item marked “Your call”: you will lose something by deleting it.", bundle: .airyCore)
            : String(localized: "Includes \(count) items marked “Your call”: you will lose something by deleting them.", bundle: .airyCore)
    }

    /// "A, B and C" in the language in use ("A, B y C" in Spanish).
    static func naturalList(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.formatted(.list(type: .and).locale(Format.locale))
    }
}

// MARK: - Batch execution

/// Result of a batch of cleanups, counted honestly: what went to the Trash is not freed.
public struct CleanupRunSummary: Sendable, Equatable {
    public struct Problem: Sendable, Equatable, Identifiable {
        public let title: String
        public let message: String
        public var id: String { title + "\u{1F}" + message }
        public init(title: String, message: String) { self.title = title; self.message = message }
    }

    public var freed: Int64 = 0
    public var movedToTrash: Int64 = 0
    public var succeededIDs: [String] = []
    public var successes: [Success] = []
    public var problems: [Problem] = []

    /// A cleanup that went well: title and what happened ("Freed 2 GB" / "1.2 GB to the Trash").
    public struct Success: Sendable, Equatable, Identifiable {
        public let title: String
        public let text: String
        public var id: String { title + "\u{1F}" + text }
        public init(title: String, text: String) { self.title = title; self.text = text }
    }

    public init() {}

    public mutating func record(id: String, title: String, outcome: CleanupOutcome) {
        switch outcome {
        case .freed(let bytes):
            freed += bytes
            succeededIDs.append(id)
            successes.append(Success(title: title, text: String(localized: "Freed \(Format.bytes(bytes))", bundle: .airyCore)))
        case .movedToTrash(let bytes):
            movedToTrash += bytes
            succeededIDs.append(id)
            successes.append(Success(title: title, text: String(localized: "\(Format.bytes(bytes)) to the Trash", bundle: .airyCore)))
        case .blocked(let reason):
            problems.append(Problem(title: title, message: reason))
        case .failed(let message):
            problems.append(Problem(title: title, message: message))
        }
    }

    /// Result sentence, or `nil` if nothing went well.
    public var headline: String? {
        guard !succeededIDs.isEmpty else { return nil }
        switch (freed > 0, movedToTrash > 0) {
        case (true, true): return String(localized: "Freed \(Format.bytes(freed)) · \(Format.bytes(movedToTrash)) in the Trash", bundle: .airyCore)
        case (true, false): return String(localized: "Freed \(Format.bytes(freed))", bundle: .airyCore)
        case (false, true): return String(localized: "\(Format.bytes(movedToTrash)) in the Trash. It is freed when you empty it.", bundle: .airyCore)
        case (false, false): return String(localized: "Done. The free space has not changed noticeably.", bundle: .airyCore)
        }
    }
}

public enum CleanupBatch {
    /// Runs the items one by one, in order (each one revalidates right before acting).
    /// `onStart` receives the index of the one starting. On the main thread: the UI drives it.
    @MainActor
    public static func run(
        _ items: [CleanupItem],
        onStart: @MainActor (Int) -> Void = { _ in },
        perform: @MainActor (CleanupItem) async -> CleanupOutcome
    ) async -> CleanupRunSummary {
        var summary = CleanupRunSummary()
        for (index, item) in items.enumerated() {
            onStart(index)
            summary.record(id: item.id, title: item.title, outcome: await perform(item))
        }
        return summary
    }
}

// MARK: - After emptying the Trash

public enum TrashFollowUp {
    /// If free space rises less than this fraction of what was expected, something is holding it.
    public static let expectedRiseFraction = 0.8
    public static let snapshotEntryID = "time-machine-snapshots"

    /// `true` if local snapshots are worth explaining: the Trash size was known,
    /// free space did not rise by at least 80% of that and `tmutil` lists snapshots.
    public static func shouldExplainSnapshots(expectedBytes: Int64?, freeBefore: Int64, freeAfter: Int64,
                                              snapshotCount: Int) -> Bool {
        guard let expectedBytes, expectedBytes > 0, snapshotCount > 0 else { return false }
        return Double(freeAfter - freeBefore) < Double(expectedBytes) * expectedRiseFraction
    }

    /// What was expected to be freed and did not show up as free space.
    public static func retainedBytes(expectedBytes: Int64, freeBefore: Int64, freeAfter: Int64) -> Int64 {
        max(0, expectedBytes - max(0, freeAfter - freeBefore))
    }

    /// Cleanup item for the live catalog's `time-machine-snapshots` entry.
    public static func snapshotItem(catalog: Catalog, retainedBytes: Int64) -> CleanupItem? {
        guard let entry = catalog.entry(id: snapshotEntryID) else { return nil }
        return CleanupItem(id: entry.id, entry: entry, paths: [], bytes: max(0, retainedBytes), risk: entry.risk,
                           blockedByOpenApps: [], usedBy: [])
    }
}
