import CoreServices
import Foundation

public struct AppRecord: Sendable, Equatable, Identifiable {
    public let bundleID: String
    public let name: String
    public let version: String?
    public let path: String
    public let helperBundleIDs: [String]
    public let isSystem: Bool
    public let isAppStore: Bool
    public let caskToken: String?
    public let lastUsed: Date?
    public var id: String { path }

    public init(bundleID: String, name: String, version: String?, path: String, helperBundleIDs: [String],
                isSystem: Bool, isAppStore: Bool, caskToken: String?, lastUsed: Date?) {
        self.bundleID = bundleID
        self.name = name
        self.version = version
        self.path = path
        self.helperBundleIDs = helperBundleIDs
        self.isSystem = isSystem
        self.isAppStore = isAppStore
        self.caskToken = caskToken
        self.lastUsed = lastUsed
    }
}

public struct AppInventorySnapshot: Sendable, Equatable {
    public let apps: [AppRecord]
    public let complete: Bool
    public let problems: [String]

    public init(apps: [AppRecord], complete: Bool, problems: [String]) {
        self.apps = apps
        self.complete = complete
        self.problems = problems
    }

    /// Identifiers of every app and its helpers, in lowercase.
    public var installedIDs: Set<String> {
        var ids = Set<String>()
        for app in apps {
            ids.insert(app.bundleID.lowercased())
            for helper in app.helperBundleIDs { ids.insert(helper.lowercased()) }
        }
        return ids
    }
}

public protocol AppUsageReading: Sendable {
    func lastUsed(bundlePath: String) -> Date?
}

/// Last use according to Spotlight (`kMDItemLastUsedDate`), without launching processes.
public struct SpotlightUsage: AppUsageReading {
    public init() {}

    public func lastUsed(bundlePath: String) -> Date? {
        guard let item = MDItemCreateWithURL(nil, URL(fileURLWithPath: bundlePath) as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }
}

public struct AppInventory: Sendable {
    public static func standardRoots(home: String) -> [String] {
        ["/Applications", "/System/Applications", home + "/Applications", "/opt/homebrew/Caskroom",
         "/usr/local/Caskroom", home + "/Library/Application Support/Setapp/Applications"]
    }

    public static let systemCriticalBundleIDs: Set<String> = [
        "com.apple.Safari", "com.apple.finder", "com.apple.systempreferences", "com.apple.SystemSettings",
        "com.apple.AppStore", "com.apple.ActivityMonitor", "com.apple.Terminal", "com.apple.mail",
        "com.apple.MobileSMS", "com.apple.Photos", "com.apple.iCal", "com.apple.AddressBook",
        "com.apple.keychainaccess", "com.apple.backup.launcher", "com.apple.DiskUtility",
    ]

    public static let officialUninstallerPrefixes: [String] = [
        "com.crowdstrike.", "com.sentinelone.", "com.sentinel-labs.", "com.eset.", "com.jamf.",
        "com.jamfsoftware.", "com.paloaltonetworks.", "com.cisco.anyconnect", "com.cisco.secureclient",
    ]

    private static let genericNames: Set<String> = [
        "notes", "mail", "music", "photos", "preview", "books", "news", "home", "files", "app", "helper",
    ]

    /// Maximum search depth for `*.app` under each root.
    private static let maxDepth = 3

    private let roots: [String]
    private let usage: any AppUsageReading
    private let casks: [String: String]
    private let budget: Duration

    public init(roots: [String], usage: any AppUsageReading = SpotlightUsage(), casks: [String: String] = [:],
                budget: Duration = .seconds(5)) {
        self.roots = roots
        self.usage = usage
        self.casks = casks
        self.budget = budget
    }

    public func snapshot() async -> AppInventorySnapshot {
        let roots = roots, usage = usage, casks = casks
        let outcome: Walk? = budget > .zero
            ? await TimeBudget.run(budget) { Self.walk(roots: roots, usage: usage, casks: casks) }
            : nil
        guard let walk = outcome, !walk.cancelled else {
            return AppInventorySnapshot(
                apps: [], complete: false,
                problems: [String(localized: "The app inventory did not finish in time.", bundle: .airyCore)])
        }
        let apps = walk.apps.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.path < $1.path : order == .orderedAscending
        }
        return AppInventorySnapshot(apps: apps, complete: walk.problems.isEmpty, problems: walk.problems)
    }

    /// As is, without spaces, spaces → "_", spaces → "-", and lowercased; empty if the name has
    /// fewer than 4 characters or is generic.
    public static func nameVariants(_ name: String) -> [String] {
        guard name.count >= 4, !genericNames.contains(name.lowercased()) else { return [] }
        let base = [
            name,
            name.replacingOccurrences(of: " ", with: ""),
            name.replacingOccurrences(of: " ", with: "_"),
            name.replacingOccurrences(of: " ", with: "-"),
        ]
        var result: [String] = []
        for variant in base + base.map({ $0.lowercased() }) where !result.contains(variant) {
            result.append(variant)
        }
        return result
    }

    // MARK: - Walk

    private struct Walk: Sendable {
        var apps: [AppRecord] = []
        var problems: [String] = []
        var cancelled = false
    }

    private static func walk(roots: [String], usage: any AppUsageReading, casks: [String: String]) -> Walk {
        var walk = Walk()
        var seen = Set<String>()
        for root in roots {
            if Task.isCancelled { walk.cancelled = true; return walk }
            scan(directory: root, depth: 1, isRoot: true, usage: usage, casks: casks, seen: &seen, walk: &walk)
            if walk.cancelled { return walk }
        }
        return walk
    }

    private enum EntryKind {
        case directory
        /// Symbolic link; `true` if it points to a folder.
        case link(toDirectory: Bool)
        case other
        case failed(Int32)
    }

    private static func kind(of path: String) -> EntryKind {
        var info = stat()
        guard lstat(path, &info) == 0 else { return .failed(errno) }
        switch info.st_mode & S_IFMT {
        case S_IFDIR: return .directory
        case S_IFLNK:
            var target = stat()
            return .link(toDirectory: stat(path, &target) == 0 && (target.st_mode & S_IFMT) == S_IFDIR)
        default: return .other
        }
    }

    /// Names in a directory, or the `errno` it failed with (when opening or halfway through reading).
    private static func listing(_ path: String) -> Result<[String], POSIXError> {
        guard let dir = opendir(path) else { return .failure(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)) }
        defer { closedir(dir) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(dir) else { break }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        if errno != 0 { return .failure(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)) }
        return .success(names)
    }

    private static func scan(directory: String, depth: Int, isRoot: Bool, usage: any AppUsageReading,
                             casks: [String: String], seen: inout Set<String>, walk: inout Walk) {
        let names: [String]
        switch listing(directory) {
        case .success(let found): names = found
        case .failure(let error):
            if error.code != .ENOENT { walk.problems.append(String(localized: "Could not read “\(directory)”.", bundle: .airyCore)) }
            return
        }
        for name in names.sorted() {
            if Task.isCancelled { walk.cancelled = true; return }
            let path = directory + "/" + name
            let isApp = name.hasSuffix(".app")
            switch kind(of: path) {
            case .directory:
                if isApp {
                    guard seen.insert(path).inserted else { continue }
                    record(app: path, usage: usage, casks: casks, walk: &walk)
                } else if depth < maxDepth, !name.hasPrefix(".") {
                    scan(directory: path, depth: depth + 1, isRoot: false, usage: usage, casks: casks,
                         seen: &seen, walk: &walk)
                    if walk.cancelled { return }
                }
            case .link(let toDirectory):
                // Linked folders are not followed; a linked app is included if it points to a folder.
                guard isApp else { continue }
                if toDirectory {
                    let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
                    guard seen.insert(real).inserted else { continue }
                    record(app: path, usage: usage, casks: casks, walk: &walk)
                } else {
                    walk.problems.append(String(localized: "The link “\(name)” does not point to a readable app.", bundle: .airyCore))
                }
            case .other:
                continue
            case .failed(let code):
                if code != ENOENT { walk.problems.append(String(localized: "Could not examine “\(path)”.", bundle: .airyCore)) }
            }
        }
    }

    private static func readPlist(_ path: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = object as? [String: Any] else { return nil }
        return dict
    }

    /// `CFBundleIdentifier` of the `.app` read right now (also of wrapped iOS apps), or `nil`.
    static func bundleIdentifier(ofApp path: String) -> String? {
        guard let id = infoPlist(ofApp: path)?["CFBundleIdentifier"] as? String, !id.isEmpty else { return nil }
        return id
    }

    /// Part of macOS: inside `/System` or with an essential system identifier.
    static func isSystemApp(path: String, bundleID: String) -> Bool {
        RiskPolicy.isInside(RiskPolicy.canonical(path), root: "/system")
            || systemCriticalBundleIDs.contains { $0.caseInsensitiveCompare(bundleID) == .orderedSame }
    }

    /// `Contents/Info.plist`; if missing and it is an iOS app, the one of the `Wrapper/*.app` wrapper.
    static func infoPlist(ofApp path: String) -> [String: Any]? {
        let main = path + "/Contents/Info.plist"
        if FileManager.default.fileExists(atPath: main) { return readPlist(main) }
        guard case .success(let inner) = listing(path + "/Wrapper") else { return nil }
        for name in inner.sorted() where name.hasSuffix(".app") {
            let base = path + "/Wrapper/" + name
            if let plist = readPlist(base + "/Info.plist") ?? readPlist(base + "/Contents/Info.plist") {
                return plist
            }
        }
        return nil
    }

    /// Identifiers of the helpers; any read failure is recorded in `problems`.
    private static func helperIDs(ofApp path: String, problems: inout [String]) -> [String] {
        var ids: [String] = []
        let fileName = (path as NSString).lastPathComponent
        for (folder, ext) in [("Contents/Library/LoginItems", ".app"), ("Contents/Helpers", ".app"),
                              ("Contents/XPCServices", ".xpc")] {
            let names: [String]
            switch listing(path + "/" + folder) {
            case .success(let found): names = found
            case .failure(let error):
                if error.code != .ENOENT && error.code != .ENOTDIR {
                    problems.append(String(localized: "Could not read “\(folder)” of “\(fileName)”.", bundle: .airyCore))
                }
                continue
            }
            for name in names.sorted() where name.hasSuffix(ext) {
                let base = path + "/" + folder + "/" + name
                let plist = readPlist(base + "/Contents/Info.plist") ?? readPlist(base + "/Info.plist")
                guard let id = plist?["CFBundleIdentifier"] as? String, !id.isEmpty else {
                    problems.append(String(localized: "Could not read the helper “\(name)” of “\(fileName)”.", bundle: .airyCore))
                    continue
                }
                if !ids.contains(id) { ids.append(id) }
            }
        }
        return ids
    }

    private static func record(app path: String, usage: any AppUsageReading, casks: [String: String],
                               walk: inout Walk) {
        let fileName = (path as NSString).lastPathComponent
        guard let plist = infoPlist(ofApp: path) else {
            walk.problems.append(String(localized: "Could not read the Info.plist of “\(fileName)”.", bundle: .airyCore))
            return
        }
        guard let bundleID = plist["CFBundleIdentifier"] as? String, !bundleID.isEmpty else {
            walk.problems.append(String(localized: "“\(fileName)” has no bundle identifier.", bundle: .airyCore))
            return
        }
        let fallback = (fileName as NSString).deletingPathExtension
        func text(_ key: String) -> String? {
            (plist[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        let name = text("CFBundleDisplayName") ?? text("CFBundleName") ?? fallback
        let isSystem = isSystemApp(path: path, bundleID: bundleID)
        let helpers = helperIDs(ofApp: path, problems: &walk.problems)
        walk.apps.append(AppRecord(
            bundleID: bundleID, name: name, version: text("CFBundleShortVersionString"), path: path,
            helperBundleIDs: helpers, isSystem: isSystem,
            isAppStore: FileManager.default.fileExists(atPath: path + "/Contents/_MASReceipt/receipt"),
            caskToken: casks[fileName], lastUsed: usage.lastUsed(bundlePath: path)))
    }
}
