import Foundation

/// Identity of an entry on disk (without following the last link) and of its parent folder.
public struct FileIdentity: Sendable, Equatable {
    public let device: UInt64, inode: UInt64, parentDevice: UInt64, parentInode: UInt64, isSymlink: Bool
}

/// A path that passed validation: its checked canonical forms and its identity at that moment.
public struct ValidatedPath: Sendable, Equatable {
    public let path: String
    public let forms: [String]
    public let identity: FileIdentity
}

public struct PathRefusal: Error, Sendable, Equatable {
    public let reason: String
    public init(reason: String) { self.reason = reason }
}

/// Bounded waiver that only the uninstall funnel builds: it lets through the exact `.app` being
/// uninstalled (with its `CFBundleIdentifier` checked at validation) and the sensitive data folders (layer C)
/// of that same app. It never waives critical roots, sealed home locations, parent folders, data
/// fragments, the user's list or the catalog rules.
public struct ProtectionWaiver: Sendable, Equatable {
    /// Canonical path of the `.app`.
    public let bundlePath: String
    public let bundleID: String
    /// Lowercase: `bundleID`, `helperBundleIDs` and `AppInventory.nameVariants(name)`.
    public let ownedNames: [String]
    /// The path exactly as chosen (only that one counts as the `.app`, with no case variants).
    let appPath: String
    /// Apps root (canonical) it hangs from; only its sealed location is waived for the `.app`.
    let appRoot: String

    /// Only `uninstall(_:appRoots:)` builds a waiver.
    private init(bundlePath: String, bundleID: String, ownedNames: [String], appPath: String, appRoot: String) {
        self.bundlePath = bundlePath; self.bundleID = bundleID; self.ownedNames = ownedNames
        self.appPath = appPath; self.appRoot = appRoot
    }

    /// `nil` (no waiver) if: app.isSystem; id with a prefix from officialUninstallerPrefixes; id with the prefix
    /// "local.airy."; or app.path does not hang from an element of `appRoots` at depth 1 or 2.
    /// Only roots whose last component is `Applications` count (`/Applications`, `~/Applications` or, in
    /// DEBUG, a temporary folder `…/Applications`). It does not trust `app.isSystem`: it recomputes it from the
    /// resolved path and the identifier on disk right now.
    public static func uninstall(_ app: AppRecord, appRoots: [String]) -> ProtectionWaiver? {
        let id = app.bundleID.lowercased()
        guard !app.isSystem, !id.isEmpty, !isRefusedID(id),
              PathGate.syntaxRefusal(app.path) == nil, app.path.lowercased().hasSuffix(".app") else { return nil }
        let path = RiskPolicy.canonical(app.path)
        let parts = HardProtections.components(path)
        let root = appRoots.lazy.map(RiskPolicy.canonical).first { root in
            let depth = parts.count - HardProtections.components(root).count
            return isAppRoot(root) && RiskPolicy.isInside(path, root: root) && (1...2).contains(depth)
        }
        guard let root, let resolved = resolvedPath(app.path),
              !AppInventory.isSystemApp(path: resolved, bundleID: app.bundleID) else { return nil }
        if let onDisk = AppInventory.bundleIdentifier(ofApp: app.path),
           AppInventory.isSystemApp(path: resolved, bundleID: onDisk) || isRefusedID(onDisk.lowercased()) {
            return nil
        }
        var owned: [String] = []
        for name in [app.bundleID] + app.helperBundleIDs + AppInventory.nameVariants(app.name) {
            let lower = name.lowercased()
            if !lower.isEmpty, !owned.contains(lower) { owned.append(lower) }
        }
        return ProtectionWaiver(bundlePath: path, bundleID: app.bundleID, ownedNames: owned, appPath: app.path,
                                appRoot: root)
    }

    public static func productionAppRoots(home: String) -> [String] { ["/Applications", home + "/Applications"] }

    /// Airy and the apps with an official uninstaller (lowercase id).
    private static func isRefusedID(_ id: String) -> Bool {
        id.hasPrefix("local.airy.") || AppInventory.officialUninstallerPrefixes.contains { id.hasPrefix($0.lowercased()) }
    }

    /// Canonical root whose last component is `applications`.
    private static func isAppRoot(_ root: String) -> Bool {
        HardProtections.components(root).last == "applications"
    }

    /// Real path of the `.app` (or, if it does not exist yet, its parent folder's plus its name); `nil` if it does not resolve.
    private static func resolvedPath(_ path: String) -> String? {
        func real(_ p: String) -> String? {
            guard let r = realpath(p, nil) else { return nil }
            defer { free(r) }
            return String(cString: r)
        }
        if let full = real(path) { return full }
        guard let parent = real((path as NSString).deletingLastPathComponent) else { return nil }
        return parent + "/" + (path as NSString).lastPathComponent
    }

    static var bundleChanged: String { String(localized: "It is no longer the app you chose.", bundle: .airyCore) }

    /// `true` if the `.app` (which is not a link) has `CFBundleIdentifier == bundleID` right now, read
    /// the way the inventory reads it (also iOS apps wrapped in `Wrapper/*.app`).
    func bundleStillMatches(identity: FileIdentity) -> Bool {
        guard !identity.isSymlink, let id = AppInventory.bundleIdentifier(ofApp: appPath) else { return false }
        return id == bundleID
    }

    /// `true` if the waiver covers this hard-list match. `isBundle`: the path is the exact `.app`;
    /// `form`: the checked canonical form; `home`: the home form it was checked with.
    func waives(_ match: ProtectionMatch, form: String, isBundle: Bool, home: String) -> Bool {
        guard match.source == .airy else { return false }
        if isBundle {
            switch match.rule {
            case .sealedSystem:
                // Only the seal of the apps root itself (in practice, `/Applications`).
                let pattern = RiskPolicy.canonical(match.pattern)
                return pattern == appRoot && Self.isAppRoot(pattern)
            case .fragment:
                // Only if the fragment is in the `.app`'s name, not in a parent folder.
                let fragment = match.pattern.trimmingCharacters(in: CharacterSet(charactersIn: "*"))
                let parts = HardProtections.components(form)
                guard let last = parts.last, !fragment.isEmpty else { return false }
                return last.contains(fragment) && !parts.dropLast().contains { $0.contains(fragment) }
            default:
                return false
            }
        }
        // Another path: only the sensitive data folder itself, and only if it belongs to this app.
        guard match.rule == .sensitiveAppData, match.pattern.hasPrefix("~/") else { return false }
        let folder = RiskPolicy.canonical((home == "/" ? "" : home) + match.pattern.dropFirst(1))
        guard folder == form, var last = HardProtections.components(form).last else { return false }
        for suffix in [".savedstate", ".plist", ".binarycookies"] where last.hasSuffix(suffix) {
            last.removeLast(suffix.count)
            break
        }
        return last == bundleID.lowercased() || ownedNames.contains(last)
    }
}

extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

/// Path validation funnel before any destructive action: syntax, existence, canonical forms
/// (text, resolved parent, link target), Airy's hard list, the user's list, catalog rules
/// and `(st_dev, st_ino)` identity against the critical roots and the home.
public struct PathGate: Sendable {
    private struct InodeKey: Hashable, Sendable { let device: UInt64, inode: UInt64 }

    private let home: String
    /// Literal and resolved canonical home (if different).
    private let homeForms: [String]
    private let catalog: Catalog?
    private let userProtected: ProtectList
    private let protections: HardProtections
    /// Only for a command's `{target}`: the entry whose declared path counts as a layer C exception.
    private let commandTarget: CatalogEntry?
    /// Inode → critical root (or home) it belongs to; computed once with `stat`.
    private let criticalInodes: [InodeKey: String]
    /// Inode of `/Users`: no folder directly inside it is deleted.
    private let usersInode: InodeKey?

    public init(home: String, catalog: Catalog?, userProtected: ProtectList, protections: HardProtections = .standard,
                commandTarget: CatalogEntry? = nil) {
        self.commandTarget = commandTarget
        self.home = home
        self.catalog = catalog
        self.userProtected = userProtected
        self.protections = protections
        var homes = [RiskPolicy.canonical(home)]
        if let real = Self.realPath(home), !homes.contains(RiskPolicy.canonical(real)) {
            homes.append(RiskPolicy.canonical(real))
        }
        homeForms = homes
        var inodes: [InodeKey: String] = [:]
        for root in protections.criticalRoots + [home] {
            if let key = Self.statKey(root), inodes[key] == nil { inodes[key] = root }
        }
        criticalInodes = inodes
        usersInode = Self.statKey("/Users")
    }

    public func validate(_ path: String) -> Result<ValidatedPath, PathRefusal> {
        validate(path, waiver: nil)
    }

    /// `validate(_:)` is `validate(_:waiver: nil)`. With a waiver, everything else stays the same (syntax, resolved
    /// forms, critical root inodes, the user's list, catalog); only the hard-list matches the waiver covers
    /// are skipped (see `ProtectionWaiver`).
    public func validate(_ path: String, waiver: ProtectionWaiver?) -> Result<ValidatedPath, PathRefusal> {
        if let reason = Self.syntaxRefusal(path) { return .failure(PathRefusal(reason: reason)) }
        guard let identity = Self.identity(of: path) else { return .failure(PathRefusal(reason: String(localized: "It does not exist.", bundle: .airyCore))) }
        // If the parent folder (or the target of an existing link) cannot be resolved, we do not know
        // where it really is: it is refused (fail closed).
        guard let forms = Self.forms(of: path, isSymlink: identity.isSymlink) else {
            return .failure(PathRefusal(reason: String(localized: "The real path cannot be resolved; it is not touched.", bundle: .airyCore)))
        }
        // Only the path exactly as chosen is the `.app`; neither case variants nor anything inside.
        let isBundle = waiver.map { path == $0.appPath } ?? false
        if isBundle, let waiver, !waiver.bundleStillMatches(identity: identity) {
            return .failure(PathRefusal(reason: ProtectionWaiver.bundleChanged))
        }
        for form in forms {
            if let reason = refusal(forForm: form, waiver: waiver, isBundle: isBundle) {
                return .failure(PathRefusal(reason: reason))
            }
        }
        if let reason = inodeRefusal(path, identity: identity) { return .failure(PathRefusal(reason: reason)) }
        return .success(ValidatedPath(path: path, forms: forms, identity: identity))
    }

    /// Check without a waiver of a path that may not exist (what another tool would delete, e.g.
    /// Homebrew): if it exists, the full `validate`; if not, syntax and every rule on its text form
    /// and on that of its nearest existing folder, resolved. `nil` if it is not protected.
    public func refusalWithoutWaiver(_ path: String) -> String? {
        if let reason = Self.syntaxRefusal(path) { return reason }
        if Self.identity(of: path) != nil { return validate(path, waiver: nil).failure?.reason }
        var forms = [RiskPolicy.canonical(path)]
        var parent = (path as NSString).deletingLastPathComponent
        var tail = [(path as NSString).lastPathComponent]
        // Walks up to the first folder that exists and resolves it (e.g. `/var` → `/private/var`).
        while parent != "/", !parent.isEmpty, Self.identity(of: parent) == nil {
            tail.insert((parent as NSString).lastPathComponent, at: 0)
            parent = (parent as NSString).deletingLastPathComponent
        }
        if let real = Self.realPath(parent.isEmpty ? "/" : parent) {
            let form = RiskPolicy.canonical(([real == "/" ? "" : real] + tail).joined(separator: "/"))
            if !forms.contains(form) { forms.append(form) }
        }
        for form in forms {
            if let reason = refusal(forForm: form, waiver: nil, isBundle: false) { return reason }
        }
        return nil
    }

    /// `lstat`s the path and its parent again right before acting; different ⇒ refusal.
    public func confirmUnchanged(_ validated: ValidatedPath) -> PathRefusal? {
        guard let now = Self.identity(of: validated.path) else {
            return PathRefusal(reason: String(localized: "It no longer exists.", bundle: .airyCore))
        }
        guard now == validated.identity else {
            return PathRefusal(reason: String(localized: "The path has changed since it was checked; it is not touched.", bundle: .airyCore))
        }
        return nil
    }

    // MARK: - Rules by form

    private func refusal(forForm form: String, waiver: ProtectionWaiver?, isBundle: Bool) -> String? {
        for base in homeForms {
            guard let waiver else {
                if let match = protections.match(canonicalPath: form, home: base, catalog: catalog,
                                                     commandTarget: commandTarget) {
                    return match.reason
                }
                continue
            }
            let matches = protections.matches(canonicalPath: form, home: base, catalog: catalog,
                                              commandTarget: commandTarget)
            if let match = matches.first(where: { !waiver.waives($0, form: form, isBundle: isBundle, home: base) }) {
                return match.reason
            }
        }
        for variant in homeVariants(of: form) {
            if let pattern = userProtected.match(variant) { return String(localized: "You protected it (\(pattern)).", bundle: .airyCore) }
        }
        if RiskPolicy.minimumRisk(forPath: form, home: home) == .doNotTouch { return String(localized: "Marked as “Do not touch”.", bundle: .airyCore) }
        guard let catalog else { return nil }
        if let entry = catalog.match(path: form, home: home), entry.risk == .doNotTouch {
            return String(localized: "Marked as “Do not touch” (\(entry.title)).", bundle: .airyCore)
        }
        // Caches with an official command are only cleaned with that command, never by hand.
        for entry in catalog.entries {
            guard case .command = entry.cleanup else { continue }
            if entry.paths.contains(where: { related(form, $0) }) {
                return String(localized: "“\(entry.title)” is only cleaned with its official command.", bundle: .airyCore)
            }
        }
        // Neither inside a "Do not touch" pattern nor a folder that contains one (whether it exists now or not).
        for entry in catalog.entries where entry.risk == .doNotTouch {
            if entry.paths.contains(where: { related(form, $0) }) {
                return String(localized: "It contains or is inside something marked as “Do not touch” (\(entry.title)).", bundle: .airyCore)
            }
        }
        return nil
    }

    /// The form as is and, if it lies under one of the home's forms, rewritten under the others (the user's list
    /// is saved with the literal home; the resolved form may start with `/private`).
    private func homeVariants(of form: String) -> [String] {
        var variants = [form]
        for from in homeForms where RiskPolicy.isInside(form, root: from) {
            for to in homeForms where to != from {
                variants.append(to + form.dropFirst(from.count))
            }
        }
        return variants
    }

    /// `true` if the canonical path lies inside the pattern (or equals it) or is one of its parent folders.
    private func related(_ canonicalPath: String, _ pattern: String) -> Bool {
        var expanded = pattern
        if pattern == "~" { expanded = home } else if pattern.hasPrefix("~/") { expanded = home + pattern.dropFirst(1) }
        let patternParts = HardProtections.components(RiskPolicy.canonical(expanded))
        let pathParts = HardProtections.components(canonicalPath)
        return zip(patternParts, pathParts).allSatisfy { HardProtections.componentMatches($0, $1) }
    }

    // MARK: - Identity

    private func inodeRefusal(_ path: String, identity: FileIdentity) -> String? {
        var keys = [InodeKey(device: identity.device, inode: identity.inode)]
        if identity.isSymlink, let target = Self.statKey(path) { keys.append(target) }
        for key in keys {
            if let root = criticalInodes[key] { return String(localized: "Critical system folder (the same as \(root)).", bundle: .airyCore) }
        }
        if let usersInode {
            guard let parent = Self.realPath((path as NSString).deletingLastPathComponent),
                  let parentKey = Self.statKey(parent) else {
                return String(localized: "The real path cannot be resolved; it is not touched.", bundle: .airyCore)
            }
            if parentKey == usersInode { return String(localized: "Critical system folder (a user's folder).", bundle: .airyCore) }
        }
        return nil
    }

    static func identity(of path: String) -> FileIdentity? {
        var item = stat()
        guard lstat(path, &item) == 0 else { return nil }
        var parent = stat()
        let parentPath = (path as NSString).deletingLastPathComponent
        guard lstat(parentPath.isEmpty ? "/" : parentPath, &parent) == 0 else { return nil }
        return FileIdentity(device: device(item), inode: UInt64(item.st_ino),
                            parentDevice: device(parent), parentInode: UInt64(parent.st_ino),
                            isSymlink: (item.st_mode & S_IFMT) == S_IFLNK)
    }

    private static func statKey(_ path: String) -> InodeKey? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return InodeKey(device: device(info), inode: UInt64(info.st_ino))
    }

    private static func device(_ info: stat) -> UInt64 { UInt64(UInt32(bitPattern: info.st_dev)) }

    // MARK: - Syntax and forms

    static let maxPathBytes = 1024

    static func syntaxRefusal(_ path: String) -> String? {
        if path.isEmpty { return String(localized: "Empty path.", bundle: .airyCore) }
        if path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            return String(localized: "The path contains control characters.", bundle: .airyCore)
        }
        guard path.hasPrefix("/") else { return String(localized: "Not an absolute path.", bundle: .airyCore) }
        if path == "/" { return String(localized: "Critical system folder.", bundle: .airyCore) }
        if path.utf8.count > maxPathBytes { return String(localized: "Path too long.", bundle: .airyCore) }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        if parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) {
            return String(localized: "Non-canonical path (empty components, “.” or “..”).", bundle: .airyCore)
        }
        return nil
    }

    /// Canonical forms: the path as is, with its parent folder resolved and, if it is a link, its target.
    /// `nil` if the parent folder cannot be resolved or the target exists but cannot be resolved.
    static func forms(of path: String, isSymlink: Bool) -> [String]? {
        var forms = [RiskPolicy.canonical(path)]
        func add(_ form: String) { if !forms.contains(form) { forms.append(form) } }
        let parent = (path as NSString).deletingLastPathComponent
        guard let resolvedParent = realPath(parent) else { return nil }
        add(RiskPolicy.canonical(resolvedParent + "/" + (path as NSString).lastPathComponent))
        if isSymlink {
            if let target = realPath(path) {
                add(RiskPolicy.canonical(target))
            } else {
                // Only a broken link (the target does not exist) is accepted unresolved: its target as text,
                // relative to the resolved parent folder.
                var info = stat()
                guard stat(path, &info) != 0, errno == ENOENT,
                      let raw = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else { return nil }
                add(RiskPolicy.canonical(raw.hasPrefix("/") ? raw : resolvedParent + "/" + raw))
            }
        }
        return forms
    }

    private static func realPath(_ path: String) -> String? {
        guard let real = realpath(path, nil) else { return nil }
        defer { free(real) }
        return String(cString: real)
    }
}
