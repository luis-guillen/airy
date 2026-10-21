import Foundation
import Synchronization

/// Finds an app's leftovers in the home folder (and, for information only, in `/Library`) and builds the
/// uninstall plan with its real size. Leftovers are deduced from the identifier of the app and its helpers
/// (and, with less confidence, from its name); never from a link's target.
public struct LeftoverFinder: Sendable {
    private let home: String
    private let gate: PathGate
    private let runner: any CommandRunning
    private let appRoots: [String]
    private let systemLibrary: String
    private let budget: Duration

    public init(home: String, gate: PathGate, runner: any CommandRunning, appRoots: [String],
                systemLibrary: String = "/Library", budget: Duration = TimeBudget.sizeMeasure) {
        self.home = home
        self.gate = gate
        self.runner = runner
        self.appRoots = appRoots
        self.systemLibrary = systemLibrary
        self.budget = budget
    }

    static let pkgutil = "/usr/sbin/pkgutil"
    static let pkgutilTimeout: TimeInterval = 10

    // MARK: - Location table

    private enum Match { case id, name }

    /// A row of the table: a folder under `~/Library` and how it recognizes an entry (in lowercase).
    private struct Row: Sendable {
        let kind: Leftover.Kind
        let folder: String
        let risk: Risk
        let preselected: Bool
        let reason: String
        /// The row matches by id and by name (a name-only match lowers the confidence).
        var byIDAndName = false
        let match: @Sendable (_ entry: String, _ ids: [String], _ names: Set<String>) -> Match?
    }

    /// Exact `x + suffix` for some id (or, if `names`, some name).
    private static func exact(_ suffixes: [String], names useNames: Bool = false)
        -> @Sendable (String, [String], Set<String>) -> Match? {
        { entry, ids, names in
            for suffix in suffixes {
                if ids.contains(where: { entry == $0 + suffix }) { return .id }
            }
            if useNames, suffixes.contains(where: { suffix in names.contains { entry == $0 + suffix } }) {
                return .name
            }
            return nil
        }
    }

    private static var rows: [Row] { [
        Row(kind: .appSupport, folder: "Application Support", risk: .yourCall, preselected: true,
            reason: String(localized: "App data and settings; if you reinstall it, it will start from scratch.", bundle: .airyCore), byIDAndName: true,
            match: exact([""], names: true)),
        Row(kind: .caches, folder: "Caches", risk: .safe, preselected: true, reason: String(localized: "Cache: it regenerates.", bundle: .airyCore),
            byIDAndName: true, match: exact([""], names: true)),
        Row(kind: .containers, folder: "Containers", risk: .yourCall, preselected: true,
            reason: String(localized: "App data (sandbox).", bundle: .airyCore), match: exact([""])),
        Row(kind: .preferences, folder: "Preferences", risk: .yourCall, preselected: true,
            reason: String(localized: "App settings.", bundle: .airyCore), match: exact([".plist"])),
        Row(kind: .byHost, folder: "Preferences/ByHost", risk: .yourCall, preselected: true,
            reason: String(localized: "App settings on this Mac.", bundle: .airyCore),
            match: { entry, ids, _ in
                ids.contains { entry.hasPrefix($0 + ".") && entry.hasSuffix(".plist") } ? .id : nil
            }),
        Row(kind: .savedState, folder: "Saved Application State", risk: .safe, preselected: true,
            reason: String(localized: "Window state: it regenerates.", bundle: .airyCore), match: exact([".savedstate"])),
        Row(kind: .httpStorage, folder: "HTTPStorages", risk: .safe, preselected: true,
            reason: String(localized: "The app's network data.", bundle: .airyCore), match: exact(["", ".binarycookies"])),
        Row(kind: .logs, folder: "Logs", risk: .safe, preselected: true, reason: String(localized: "Logs.", bundle: .airyCore), byIDAndName: true,
            match: exact([""], names: true)),
        Row(kind: .webKit, folder: "WebKit", risk: .safe, preselected: true, reason: String(localized: "The app's web cache.", bundle: .airyCore),
            match: exact([""])),
        Row(kind: .webKit, folder: "WebKit/com.apple.WebKit.WebContent", risk: .safe, preselected: true,
            reason: String(localized: "The app's web cache.", bundle: .airyCore), match: exact([""])),
        Row(kind: .cookies, folder: "Cookies", risk: .safe, preselected: true, reason: String(localized: "The app's cookies.", bundle: .airyCore),
            match: exact([".binarycookies"])),
        Row(kind: .applicationScripts, folder: "Application Scripts", risk: .yourCall, preselected: true,
            reason: String(localized: "The app's scripts.", bundle: .airyCore), match: exact([""])),
        Row(kind: .autosave, folder: "Autosave Information", risk: .yourCall, preselected: false,
            reason: String(localized: "It may hold unsaved documents.", bundle: .airyCore), match: exact([""])),
        Row(kind: .syncedPreferences, folder: "SyncedPreferences", risk: .yourCall, preselected: true,
            reason: String(localized: "Synced settings.", bundle: .airyCore), match: exact([".plist"])),
    ] + pluginRows }

    private static var pluginReason: String { String(localized: "Other apps may use this plug-in.", bundle: .airyCore) }

    private static var pluginRows: [Row] {
        let named: (String, String) -> Row = { folder, ext in
            Row(kind: .plugin, folder: folder, risk: .yourCall, preselected: false, reason: pluginReason,
                match: { entry, _, names in names.contains { entry == $0 + ext } ? .name : nil })
        }
        let audio: (String) -> Row = { folder in
            Row(kind: .plugin, folder: "Audio/Plug-Ins/" + folder, risk: .yourCall, preselected: false,
                reason: pluginReason,
                match: { entry, _, names in
                    let ext = (entry as NSString).pathExtension
                    return !ext.isEmpty && names.contains((entry as NSString).deletingPathExtension) ? .name : nil
                })
        }
        return [named("Services", ".workflow"), named("QuickLook", ".qlgenerator"),
                audio("Components"), audio("VST"), audio("VST3")]
    }

    static let systemFolders = ["Application Support", "Caches", "Logs", "Preferences", "LaunchAgents",
                                "LaunchDaemons", "PrivilegedHelperTools"]

    // MARK: - Plan

    /// A leftover found, before labelling it.
    private struct Candidate {
        let path: String
        let kind: Leftover.Kind
        let matchedByName: Bool
        var risk: Risk
        var preselected: Bool
        var reason: String
        var launchLabel: String? = nil
        /// Disk path that is measured (not for receipts).
        var measured = true
        /// Name of another installed app whose identifier also claims this leftover.
        var claimedBy: String? = nil
    }

    /// Identifiers (lowercase) of the other installed apps and their helpers → app name.
    private struct OtherOwners {
        let owners: [(id: String, name: String)]
        let ownIDs: [String]

        init(apps: [AppRecord], ownIDs: [String]) {
            var seen = Set<String>()
            var owners: [(String, String)] = []
            for app in apps {
                for id in [app.bundleID] + app.helperBundleIDs {
                    let lower = id.lowercased()
                    if !lower.isEmpty, seen.insert(lower).inserted { owners.append((lower, app.name)) }
                }
            }
            // Longest first: the most specific owner.
            self.owners = owners.sorted { $0.0.count != $1.0.count ? $0.0.count > $1.0.count : $0.0 < $1.0 }
            self.ownIDs = ownIDs
        }

        /// The installed app `entry` also belongs to (lowercase). The most specific id that names it
        /// wins (`entry` is the id or starts with `<id>.`): if another app's id is just as long (shared) or
        /// longer than our own (`com.example.foo.pro` versus `com.example.foo`), it belongs to that app; a shorter
        /// id (`com.example`) does not claim what belongs to this one.
        func claimant(of entry: String) -> String? {
            func names(_ id: String) -> Bool { entry == id || entry.hasPrefix(id + ".") }
            let own = ownIDs.filter(names).map(\.count).max() ?? 0
            return owners.first { names($0.id) && $0.id.count >= own }?.name
        }
    }

    /// Why Airy would not uninstall this app (same text as `plan(for:).refusal`), without looking for leftovers.
    public func refusal(for app: AppRecord) -> String? {
        ProtectionWaiver.uninstall(app, appRoots: appRoots) == nil ? refusalText(for: app) : nil
    }

    public func plan(for app: AppRecord, inventory: AppInventorySnapshot) async -> UninstallPlan {
        let waiver = ProtectionWaiver.uninstall(app, appRoots: appRoots)
        let refusal = waiver == nil ? refusalText(for: app) : nil
        var ids: [String] = []
        for id in [app.bundleID] + app.helperBundleIDs {
            let lower = id.lowercased()
            if !lower.isEmpty, !ids.contains(lower) { ids.append(lower) }
        }
        let names = Set(AppInventory.nameVariants(app.name).map { $0.lowercased() })
        let canonicalPath = RiskPolicy.canonical(app.path)
        let otherApps = inventory.apps.filter { RiskPolicy.canonical($0.path) != canonicalPath }
        let others = OtherOwners(apps: otherApps, ownIDs: ids)

        var candidates: [Candidate] = []
        var seen = Set<String>()
        func add(_ candidate: Candidate) {
            if seen.insert(candidate.path).inserted { candidates.append(candidate) }
        }
        let library = home + "/Library"
        if !ids.isEmpty || !names.isEmpty {
            for row in Self.rows {
                let folder = library + "/" + row.folder
                for entry in Self.entries(of: folder) {
                    guard let match = row.match(entry.lowercased(), ids, names) else { continue }
                    var candidate = Candidate(path: folder + "/" + entry, kind: row.kind,
                                              matchedByName: match == .name, risk: row.risk,
                                              preselected: row.preselected, reason: row.reason)
                    if row.byIDAndName, match == .name {
                        candidate.risk = .yourCall
                        candidate.preselected = false
                        candidate.reason = String(localized: "Matches by name: check that it belongs to “\(app.name)”.", bundle: .airyCore)
                    }
                    if match == .id { candidate.claimedBy = others.claimant(of: entry.lowercased()) }
                    add(candidate)
                }
            }
            for agent in launchAgents(in: library + "/LaunchAgents", ids: ids, appPath: app.path, others: others) {
                add(agent)
            }
        }
        // Rules 2 and 3: the funnel (with and without a waiver) and the per-path floor.
        candidates = candidates.map(labelled(waiver: waiver, appName: app.name))
        // What also belongs to another installed app is never selected.
        candidates = candidates.map {
            guard let owner = $0.claimedBy else { return $0 }
            var copy = $0
            copy.risk = .doNotTouch
            copy.preselected = false
            copy.reason = String(localized: "Another installed app (“\(owner)”) also uses it.", bundle: .airyCore)
            return copy
        }
        if !ids.isEmpty || !names.isEmpty {
            for candidate in systemLocations(ids: ids, names: names) { add(candidate) }
        }
        for receipt in await receipts(for: app) { add(receipt) }

        // Rule 4: another installed copy; and links to apps outside the roots: informational only.
        let other = app.bundleID.isEmpty ? nil : otherApps.first {
            $0.bundleID.caseInsensitiveCompare(app.bundleID) == .orderedSame
        }
        let override: String? = if let other {
            String(localized: "Another copy installed at \(other.path) uses them.", bundle: .airyCore)
        } else if let refusal {
            refusal
        } else if linkIsInformational(app.path) {
            String(localized: "It is a link to an app outside Applications: its data is not touched.", bundle: .airyCore)
        } else {
            nil
        }
        if let override {
            candidates = candidates.map {
                var copy = $0
                copy.risk = .doNotTouch
                copy.preselected = false
                copy.reason = override
                return copy
            }
        }

        // Selectable items first: if time runs out, the informational ones are what is left unmeasured.
        let measured = candidates.filter(\.measured)
        let (sizes, complete) = await measure([app.path] + measured.filter { $0.risk != .doNotTouch }.map(\.path)
                                              + measured.filter { $0.risk == .doNotTouch }.map(\.path))
        let leftovers = candidates.map {
            Leftover(path: $0.path, kind: $0.kind, bytes: $0.measured ? sizes[$0.path] ?? 0 : 0, risk: $0.risk,
                     preselected: $0.preselected, matchedByName: $0.matchedByName, reason: $0.reason,
                     launchLabel: $0.launchLabel)
        }
        return UninstallPlan(app: app, appBytes: sizes[app.path] ?? 0, leftovers: leftovers, refusal: refusal,
                             sharedWith: other?.path, sizeComplete: complete)
    }

    private func labelled(waiver: ProtectionWaiver?, appName: String) -> (Candidate) -> Candidate {
        { candidate in
            var result = candidate
            switch gate.validate(candidate.path, waiver: waiver) {
            case .failure(let refusal):
                result.risk = .doNotTouch
                result.preselected = false
                result.reason = refusal.reason
            case .success:
                if waiver != nil, gate.validate(candidate.path, waiver: nil).failure != nil {
                    result.risk = .strictest(result.risk, .yourCall)
                    result.preselected = false
                    result.reason = String(localized: "Account data of “\(appName)”: if you reinstall it you will have to set it up again.", bundle: .airyCore)
                }
            }
            result.risk = .strictest(result.risk, RiskPolicy.minimumRisk(forPath: candidate.path, home: home))
            if result.risk == .doNotTouch { result.preselected = false }
            return result
        }
    }

    // MARK: - Special rows

    /// `LaunchAgents/*.plist` whose `Label` is an id or starts with `<id>.`, or whose program lies inside the
    /// `.app` (the path as is, without following links). Unreadable plists are skipped.
    private func launchAgents(in folder: String, ids: [String], appPath: String, others: OtherOwners) -> [Candidate] {
        let bundle = RiskPolicy.canonical(appPath)
        var result: [Candidate] = []
        for entry in Self.entries(of: folder) where entry.lowercased().hasSuffix(".plist") {
            let path = folder + "/" + entry
            guard let data = FileManager.default.contents(atPath: path),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let label = plist["Label"] as? String, !label.isEmpty else { continue }
            let lower = label.lowercased()
            let byLabel = ids.contains { lower == $0 || lower.hasPrefix($0 + ".") }
            let program = (plist["Program"] as? String) ?? ((plist["ProgramArguments"] as? [Any])?.first as? String)
            let byProgram = program.map {
                $0.hasPrefix("/") && RiskPolicy.canonical($0).hasPrefix(bundle + "/")
            } ?? false
            guard byLabel || byProgram else { continue }
            result.append(Candidate(path: path, kind: .launchAgent, matchedByName: false, risk: .yourCall,
                                    preselected: true, reason: String(localized: "It runs at login; it is stopped first.", bundle: .airyCore),
                                    launchLabel: label, claimedBy: others.claimant(of: lower)))
        }
        return result
    }

    /// `/Library` entries that start with an id or a name: informational only, never deleted.
    private func systemLocations(ids: [String], names: Set<String>) -> [Candidate] {
        var result: [Candidate] = []
        for sub in Self.systemFolders {
            let folder = systemLibrary + "/" + sub
            for entry in Self.entries(of: folder) {
                let lower = entry.lowercased()
                let byID = ids.contains { Self.startsWord(lower, $0) }
                guard byID || names.contains(where: { Self.startsWord(lower, $0) }) else { continue }
                result.append(Candidate(path: folder + "/" + entry, kind: .systemLocation, matchedByName: !byID,
                                        risk: .doNotTouch, preselected: false,
                                        reason: String(localized: "Outside your home folder: Airy does not delete it.", bundle: .airyCore)))
            }
        }
        return result
    }

    /// `entry` starts with `prefix` and is followed by the end or a separator (`.`, `-`, `_`, space).
    static func startsWord(_ entry: String, _ prefix: String) -> Bool {
        guard entry.hasPrefix(prefix) else { return false }
        guard let next = entry.dropFirst(prefix.count).first else { return true }
        return ".-_ ".contains(next)
    }

    /// `pkgutil --file-info <app>` → `pkgid: X` lines. Ids with odd characters are discarded.
    private func receipts(for app: AppRecord) async -> [Candidate] {
        guard let output = try? await runner.run(Self.pkgutil, ["--file-info", app.path], timeout: Self.pkgutilTimeout),
              output.status == 0 else { return [] }
        var result: [Candidate] = []
        for line in output.stdout.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("pkgid:") else { continue }
            let id = text.dropFirst("pkgid:".count).trimmingCharacters(in: .whitespaces)
            guard Self.isValidPackageID(id), !result.contains(where: { $0.path == id }) else { continue }
            if id.lowercased().hasPrefix("com.apple.") {
                result.append(Candidate(path: id, kind: .receipt, matchedByName: false, risk: .doNotTouch,
                                        preselected: false, reason: String(localized: "It is part of macOS.", bundle: .airyCore), measured: false))
                continue
            }
            var receipt = Candidate(path: id, kind: .receipt, matchedByName: false, risk: .safe, preselected: true,
                                    reason: String(localized: "Install receipt; it asks for an administrator password.", bundle: .airyCore),
                                    measured: false)
            switch await otherBundles(inPackage: id, ownBundle: app.path) {
            case nil:
                receipt.risk = .yourCall
                receipt.preselected = false
                receipt.reason = String(localized: "Could not check whether this receipt includes other apps.", bundle: .airyCore)
            case let found? where !found.isEmpty:
                receipt.risk = .doNotTouch
                receipt.preselected = false
                receipt.reason = String(localized: "This receipt also includes other apps (\(found.joined(separator: ", "))).", bundle: .airyCore)
            default:
                break
            }
            result.append(receipt)
        }
        return result
    }

    /// `.app` bundles of the package (the first `*.app` component of each folder in `pkgutil --files <id> --only-dirs`)
    /// other than its own, sorted; `nil` if the query fails.
    private func otherBundles(inPackage id: String, ownBundle: String) async -> [String]? {
        guard let output = try? await runner.run(Self.pkgutil, ["--files", id, "--only-dirs"],
                                                 timeout: Self.pkgutilTimeout),
              output.status == 0 else { return nil }
        let own = (ownBundle as NSString).lastPathComponent.lowercased()
        var found = Set<String>()
        for line in output.stdout.split(whereSeparator: \.isNewline) {
            guard let bundle = line.split(separator: "/").first(where: { $0.lowercased().hasSuffix(".app") })
            else { continue }
            if bundle.lowercased() != own { found.insert(String(bundle)) }
        }
        return found.sorted()
    }

    /// `^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$`
    static func isValidPackageID(_ id: String) -> Bool {
        guard let first = id.unicodeScalars.first, id.unicodeScalars.count <= 200 else { return false }
        func ascii(_ s: Unicode.Scalar) -> Bool {
            ("a"..."z").contains(s) || ("A"..."Z").contains(s) || ("0"..."9").contains(s)
        }
        return ascii(first) && id.unicodeScalars.allSatisfy { ascii($0) || $0 == "." || $0 == "_" || $0 == "-" }
    }

    // MARK: - Refusals and links

    private func refusalText(for app: AppRecord) -> String {
        let resolved = Self.realPath(app.path) ?? app.path
        let onDisk = AppInventory.bundleIdentifier(ofApp: app.path)
        let ids = [app.bundleID] + (onDisk.map { [$0] } ?? [])
        if app.isSystem || ids.contains(where: {
            AppInventory.isSystemApp(path: app.path, bundleID: $0) || AppInventory.isSystemApp(path: resolved, bundleID: $0)
        }) {
            return String(localized: "It is part of macOS.", bundle: .airyCore)
        }
        let lower = ids.map { $0.lowercased() }
        if lower.contains(where: { id in
            AppInventory.officialUninstallerPrefixes.contains { id.hasPrefix($0.lowercased()) }
        }) {
            return String(localized: "Use the official uninstaller of “\(app.name)”.", bundle: .airyCore)
        }
        if lower.contains(where: { $0.hasPrefix("local.airy.") }) { return String(localized: "It is Airy.", bundle: .airyCore) }
        let setapp = RiskPolicy.canonical(home + "/Library/Application Support/Setapp")
        if RiskPolicy.isInside(RiskPolicy.canonical(app.path), root: setapp)
            || RiskPolicy.isInside(RiskPolicy.canonical(resolved), root: setapp) {
            return String(localized: "Uninstall it from Setapp.", bundle: .airyCore)
        }
        return String(localized: "Only apps in Applications are uninstalled.", bundle: .airyCore)
    }

    /// `true` if the `.app` is a link whose target lies outside the app roots, inside `/System`
    /// or cannot be resolved.
    private func linkIsInformational(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK else { return false }
        guard let target = Self.realPath(path) else { return true }
        let form = RiskPolicy.canonical(target)
        if RiskPolicy.isInside(form, root: "/system") { return true }
        let roots = appRoots.flatMap { root in [root] + (Self.realPath(root).map { [$0] } ?? []) }
            .map(RiskPolicy.canonical)
        return !roots.contains { form.hasPrefix($0 + "/") }
    }

    // MARK: - Utilities

    private static func entries(of folder: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted()
    }

    private static func realPath(_ path: String) -> String? {
        guard let real = realpath(path, nil) else { return nil }
        defer { free(real) }
        return String(cString: real)
    }

    /// Sizes within the budget; if it runs out, what was not measured does not appear (0 bytes).
    private func measure(_ paths: [String]) async -> (sizes: [String: Int64], complete: Bool) {
        guard budget > .zero else { return ([:], false) }
        final class Sizes: Sendable { let values = Mutex<[String: Int64]>([:]) }
        let box = Sizes()
        let finished = await TimeBudget.run(budget) {
            for path in paths {
                if Task.isCancelled { return false }
                let bytes = AllocatedSize.of(path) ?? 0
                box.values.withLock { $0[path] = bytes }
            }
            return true
        }
        return (box.values.withLock { $0 }, finished == true)
    }
}
