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

    /// Identificadores de todas las apps y sus ayudantes, en minúsculas.
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

/// Último uso según Spotlight (`kMDItemLastUsedDate`), sin lanzar procesos.
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

    /// Profundidad máxima de búsqueda de `*.app` bajo cada raíz.
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
                problems: ["El inventario de apps no terminó a tiempo."])
        }
        let apps = walk.apps.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.path < $1.path : order == .orderedAscending
        }
        return AppInventorySnapshot(apps: apps, complete: walk.problems.isEmpty, problems: walk.problems)
    }

    /// Tal cual, sin espacios, espacios → "_", espacios → "-", y en minúsculas; vacío si el nombre tiene
    /// menos de 4 caracteres o es genérico.
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

    // MARK: - Recorrido

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

    private enum EntryKind { case directory, other }

    private static func kind(of path: String) -> EntryKind {
        var info = stat()
        guard lstat(path, &info) == 0 else { return .other }
        return (info.st_mode & S_IFMT) == S_IFDIR ? .directory : .other
    }

    /// Nombres de un directorio, o el `errno` con el que falló.
    private static func listing(_ path: String) -> Result<[String], POSIXError> {
        guard let dir = opendir(path) else { return .failure(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)) }
        defer { closedir(dir) }
        var names: [String] = []
        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return .success(names)
    }

    private static func scan(directory: String, depth: Int, isRoot: Bool, usage: any AppUsageReading,
                             casks: [String: String], seen: inout Set<String>, walk: inout Walk) {
        let names: [String]
        switch listing(directory) {
        case .success(let found): names = found
        case .failure(let error):
            if error.code == .ENOENT { return }
            if isRoot || error.code == .EACCES || error.code == .EPERM {
                walk.problems.append("No se pudo leer «\(directory)».")
            }
            return
        }
        for name in names.sorted() {
            if Task.isCancelled { walk.cancelled = true; return }
            let path = directory + "/" + name
            guard kind(of: path) == .directory else { continue }   // ni enlaces ni ficheros
            if name.hasSuffix(".app") {
                guard seen.insert(path).inserted else { continue }
                record(app: path, usage: usage, casks: casks, walk: &walk)
            } else if depth < maxDepth, !name.hasPrefix(".") {
                scan(directory: path, depth: depth + 1, isRoot: false, usage: usage, casks: casks,
                     seen: &seen, walk: &walk)
                if walk.cancelled { return }
            }
        }
    }

    private static func readPlist(_ path: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = object as? [String: Any] else { return nil }
        return dict
    }

    /// `Contents/Info.plist`; si falta y es una app de iOS, el del envoltorio `Wrapper/*.app`.
    private static func infoPlist(ofApp path: String) -> [String: Any]? {
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

    private static func helperIDs(ofApp path: String) -> [String] {
        var ids: [String] = []
        for (folder, ext) in [("Contents/Library/LoginItems", ".app"), ("Contents/Helpers", ".app"),
                              ("Contents/XPCServices", ".xpc")] {
            guard case .success(let names) = listing(path + "/" + folder) else { continue }
            for name in names.sorted() where name.hasSuffix(ext) {
                let base = path + "/" + folder + "/" + name
                let plist = readPlist(base + "/Contents/Info.plist") ?? readPlist(base + "/Info.plist")
                if let id = plist?["CFBundleIdentifier"] as? String, !id.isEmpty, !ids.contains(id) {
                    ids.append(id)
                }
            }
        }
        return ids
    }

    private static func record(app path: String, usage: any AppUsageReading, casks: [String: String],
                               walk: inout Walk) {
        let fileName = (path as NSString).lastPathComponent
        guard let plist = infoPlist(ofApp: path) else {
            walk.problems.append("No se pudo leer el Info.plist de «\(fileName)».")
            return
        }
        guard let bundleID = plist["CFBundleIdentifier"] as? String, !bundleID.isEmpty else {
            walk.problems.append("«\(fileName)» no tiene identificador de paquete.")
            return
        }
        let fallback = (fileName as NSString).deletingPathExtension
        func text(_ key: String) -> String? {
            (plist[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        let name = text("CFBundleDisplayName") ?? text("CFBundleName") ?? fallback
        let isSystem = path.hasPrefix("/System/Applications/")
            || systemCriticalBundleIDs.contains { $0.caseInsensitiveCompare(bundleID) == .orderedSame }
        walk.apps.append(AppRecord(
            bundleID: bundleID, name: name, version: text("CFBundleShortVersionString"), path: path,
            helperBundleIDs: helperIDs(ofApp: path), isSystem: isSystem,
            isAppStore: FileManager.default.fileExists(atPath: path + "/Contents/_MASReceipt/receipt"),
            caskToken: casks[fileName], lastUsed: usage.lastUsed(bundlePath: path)))
    }
}
