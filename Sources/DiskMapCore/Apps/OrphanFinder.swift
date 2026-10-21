import Foundation

/// Leftovers of an app that is no longer installed, grouped by its identifier.
public struct OrphanGroup: Sendable, Equatable, Identifiable {
    public let bundleID: String
    public let paths: [String]
    public let bytes: Int64
    public let lastModified: Date
    /// `.safe` (protected ones do not get here).
    public let risk: Risk
    public var id: String { bundleID }

    public init(bundleID: String, paths: [String], bytes: Int64, lastModified: Date, risk: Risk = .safe) {
        self.bundleID = bundleID
        self.paths = paths
        self.bytes = bytes
        self.lastModified = lastModified
        self.risk = risk
    }
}

public enum OrphanScan: Sendable, Equatable { case found([OrphanGroup]), undecided(String) }

/// `nil` = unknown.
public protocol BundleIDLookup: Sendable { func isInstalled(_ bundleID: String) async -> Bool? }

/// Spotlight: `/usr/bin/mdfind 'kMDItemCFBundleIdentifier == "<id>"'`.
public struct SpotlightLookup: BundleIDLookup {
    private let runner: any CommandRunning
    private let timeout: TimeInterval

    public init(runner: any CommandRunning, timeout: TimeInterval = 5) {
        self.runner = runner
        self.timeout = timeout
    }

    /// Non-empty output → `true`; empty with status 0 → `false`; anything else → `nil`.
    public func isInstalled(_ bundleID: String) async -> Bool? {
        guard OrphanFinder.bundleID(fromEntryName: bundleID) == bundleID else { return nil }
        guard let output = try? await runner.run("/usr/bin/mdfind", ["kMDItemCFBundleIdentifier == \"\(bundleID)\""],
                                                 timeout: timeout) else { return nil }
        if !output.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        return output.status == 0 ? false : nil
    }
}

/// Looks for orphaned leftovers in Caches, Logs and Saved Application State. Fixed decision tree: the first "no"
/// discards the id (and, if any of its entries does not pass, the whole id).
public struct OrphanFinder: Sendable {
    public static let minimumIdle: TimeInterval = 30 * 86_400
    public static let candidateFolders = ["Library/Caches", "Library/Logs", "Library/Saved Application State"]
    public static let sensitivePatterns = ["ssh", "gpg", "gnupg", "keychain", "1password", "bitwarden", "lastpass",
                                           "keepass", "dashlane", "enpass"]
    static var incompleteInventory: String {
        String(localized: "Could not read the full list of apps; Airy does not mark leftovers as orphaned.", bundle: .airyCore) }

    private let home: String
    private let gate: PathGate
    private let lookup: any BundleIDLookup
    private let now: @Sendable () -> Date

    public init(home: String, gate: PathGate, lookup: any BundleIDLookup, now: @escaping @Sendable () -> Date = Date.init) {
        self.home = home
        self.gate = gate
        self.lookup = lookup
        self.now = now
    }

    public func scan(inventory: AppInventorySnapshot) async -> OrphanScan {
        guard inventory.complete else { return .undecided(Self.incompleteInventory) }
        let entries = candidateEntries()
        var groups: [OrphanGroup] = []
        for id in entries.keys.sorted() {
            if Task.isCancelled { break }
            if let group = await decide(id, paths: entries[id] ?? [], inventory: inventory) { groups.append(group) }
        }
        return .found(groups)
    }

    /// Right before deleting: the same decision tree with a fresh inventory.
    public func stillOrphan(_ group: OrphanGroup, inventory: AppInventorySnapshot) async -> Bool {
        guard inventory.complete else { return false }
        let paths = candidateEntries()[group.bundleID] ?? []
        guard let fresh = await decide(group.bundleID, paths: paths, inventory: inventory) else { return false }
        return Set(group.paths).isSubset(of: Set(fresh.paths))
    }

    /// The groups that are still orphaned with `inventory` (the only thing the app should send to the Trash).
    public func confirmable(_ groups: [OrphanGroup], inventory: AppInventorySnapshot) async -> [OrphanGroup] {
        var result: [OrphanGroup] = []
        for group in groups where await stillOrphan(group, inventory: inventory) { result.append(group) }
        return result
    }

    /// "com.foo.bar" or "com.foo.bar.savedState" → id; only com|org|net|io, ≥ 3 components, [A-Za-z0-9._-].
    static func bundleID(fromEntryName name: String) -> String? {
        var id = name
        let suffix = ".savedstate"
        if id.lowercased().hasSuffix(suffix) { id.removeLast(suffix.count) }
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3, ["com", "org", "net", "io"].contains(parts[0].lowercased()),
              parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        let allowed = id.unicodeScalars.allSatisfy { s in
            ("a"..."z").contains(s) || ("A"..."Z").contains(s) || ("0"..."9").contains(s)
                || s == "." || s == "_" || s == "-"
        }
        return allowed ? id : nil
    }

    // MARK: - Decision tree

    /// Rule 2: only direct entries of the three folders that yield an id.
    private func candidateEntries() -> [String: [String]] {
        var result: [String: [String]] = [:]
        for folder in Self.candidateFolders {
            let base = home + "/" + folder
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: base)) ?? []).sorted()
            for name in names {
                guard let id = Self.bundleID(fromEntryName: name) else { continue }
                result[id, default: []].append(base + "/" + name)
            }
        }
        return result
    }

    private func decide(_ id: String, paths: [String], inventory: AppInventorySnapshot) async -> OrphanGroup? {
        guard !paths.isEmpty else { return nil }
        let lower = id.lowercased()
        // Rule 3.
        if lower.hasPrefix("com.apple.") || lower.hasPrefix("local.airy.") { return nil }
        if Self.sensitivePatterns.contains(where: { lower.contains($0) }) { return nil }
        // Rule 4.
        for path in paths where gate.validate(path).failure != nil { return nil }
        // Rule 5 (also if the id hangs from an installed one: `com.foo.app.log` from `com.foo.app`).
        let installed = inventory.installedIDs
        if installed.contains(lower) || installed.contains(where: { lower.hasPrefix($0 + ".") }) { return nil }
        // Rule 6.
        let threshold = now().addingTimeInterval(-Self.minimumIdle)
        var newest = Date.distantPast
        for path in paths {
            guard let date = Self.newestModification(path) else { return nil }
            newest = max(newest, date)
        }
        if newest > threshold { return nil }
        // Rule 7: a failure counts as installed.
        guard await lookup.isInstalled(id) == false else { return nil }
        let bytes = paths.reduce(Int64(0)) { $0 + (AllocatedSize.of($1) ?? 0) }
        return OrphanGroup(bundleID: id, paths: paths, bytes: bytes, lastModified: newest)
    }

    /// The most recent `mtime` among the entry and its direct children (with `lstat`); `nil` if it cannot be read.
    private static func newestModification(_ path: String) -> Date? {
        func mtime(_ p: String) -> Date? {
            var info = stat()
            guard lstat(p, &info) == 0 else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
        }
        guard var newest = mtime(path) else { return nil }
        var info = stat()
        if lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR {
            guard let children = try? FileManager.default.contentsOfDirectory(atPath: path) else { return nil }
            for child in children {
                if let date = mtime(path + "/" + child) { newest = max(newest, date) }
            }
        }
        return newest
    }
}
