import AppKit
import Foundation

/// System state that cleanup detection and execution need (fakeable in tests).
public protocol SystemProbing: Sendable {
    func runningBundleIDs() -> Set<String>
    /// Open apps read right now (not a list that updates with the event loop), for the
    /// check right before cleaning. `nil` = cannot be known (the caller fails closed).
    func currentRunningBundleIDs() -> Set<String>?
    func hasFullDiskAccess() -> Bool
    func trashSize() -> Int64
    /// Like `trashSize`, but `nil` if `~/.Trash` exists and cannot be read (e.g. without Full Disk
    /// Access), so as not to confuse "unknown" with "empty".
    func trashSizeIfReadable() -> Int64?
    /// Permanently deletes the contents of `~/.Trash`. Returns the bytes freed.
    /// Without permission to read it, it falls back to Finder ("empty trash"), which empties the trash
    /// of **every** volume: the UI must warn about it before confirming.
    func emptyTrash() async throws -> Int64
    func localSnapshots() async -> [String]
}

public extension SystemProbing {
    func currentRunningBundleIDs() -> Set<String>? { runningBundleIDs() }
}

/// Bundle IDs of the running apps from the process list (libproc): each executable inside
/// `<X>.app/Contents/MacOS/` counts as the app `<X>.app` (its `CFBundleIdentifier`).
public enum RunningApps {
    /// `bundleIdentifier`: reads a `.app`'s identifier (by default, from its `Contents/Info.plist`).
    public static func bundleIDs(listing: any ProcessListing,
                                 bundleIdentifier: (String) -> String? = RunningApps.infoPlistIdentifier)
        -> Set<String>? {
        guard let processes = listing.processes() else { return nil }
        var bundles = Set<String>()
        for process in processes {
            if let path = process.executablePath, let bundle = appBundle(ofExecutable: path) { bundles.insert(bundle) }
        }
        return Set(bundles.compactMap(bundleIdentifier))
    }

    /// `/A/Safari.app/Contents/MacOS/Safari` ⇒ `/A/Safari.app`; otherwise, `nil`.
    public static func appBundle(ofExecutable path: String) -> String? {
        guard let range = path.range(of: ".app/Contents/MacOS/", options: .backwards) else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    public static func infoPlistIdentifier(_ bundlePath: String) -> String? {
        let info = NSDictionary(contentsOfFile: bundlePath + "/Contents/Info.plist")
        guard let id = info?["CFBundleIdentifier"] as? String, !id.isEmpty else { return nil }
        return id
    }
}

/// Volume capacity (bytes): total, available and available for important usage (what Finder shows).
public struct VolumeCapacity: Sendable, Equatable {
    public let total: Int64, available: Int64, importantAvailable: Int64

    public init(total: Int64, available: Int64, importantAvailable: Int64) {
        self.total = total; self.available = available; self.importantAvailable = importantAvailable
    }
}

/// Allocated size (`st_blocks * 512`) with `lstat`, without following symbolic links
/// and counting hard links only once.
public enum AllocatedSize {
    /// `nil` if the path does not exist or cannot be read with `lstat`.
    public static func of(_ path: String) -> Int64? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        var seen = Set<HardLinkKey>()
        return walk(path, info, &seen)
    }

    private struct HardLinkKey: Hashable { let device: dev_t; let inode: ino_t }

    private static func walk(_ path: String, _ info: stat, _ seen: inout Set<HardLinkKey>) -> Int64 {
        let type = info.st_mode & S_IFMT
        var total: Int64 = 0
        if type == S_IFREG, info.st_nlink > 1 {
            if seen.insert(HardLinkKey(device: info.st_dev, inode: info.st_ino)).inserted {
                total = Int64(info.st_blocks) * 512
            }
        } else {
            total = Int64(info.st_blocks) * 512
        }
        guard type == S_IFDIR, let dir = opendir(path) else { return total }
        defer { closedir(dir) }
        while let entry = readdir(dir) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            if name == "." || name == ".." { continue }
            let child = path == "/" ? "/" + name : path + "/" + name
            var childInfo = stat()
            guard lstat(child, &childInfo) == 0 else { continue }
            total += walk(child, childInfo, &seen)
        }
        return total
    }
}

public struct SystemProbes: SystemProbing {
    private let home: String
    private let runner: any CommandRunning
    private let allowFinderFallback: Bool
    private let processListing: any ProcessListing

    /// `allowFinderFallback`: without permission for `~/.Trash`, empty it with Finder (affects the real Trash).
    /// `processListing`: where the open apps are read from on the spot (libproc; fakeable in tests).
    public init(home: String = NSHomeDirectory(), runner: any CommandRunning = ProcessRunner(),
                allowFinderFallback: Bool = true, processListing: any ProcessListing = LibprocListing()) {
        self.home = home
        self.runner = runner
        self.allowFinderFallback = allowFinderFallback
        self.processListing = processListing
    }

    private var trashPath: String { (home as NSString).appendingPathComponent(".Trash") }

    /// For display in the UI: the on-the-spot reading or, if it fails, the one from `NSWorkspace`.
    public func runningBundleIDs() -> Set<String> {
        currentRunningBundleIDs() ?? Self.workspaceBundleIDs()
    }

    /// Process list read now (libproc), merged with what `NSWorkspace` knows (in a process without an
    /// AppKit loop, like `airy-mcp`, that list may not learn about apps opened after launch).
    /// `nil` if the process list cannot be read.
    public func currentRunningBundleIDs() -> Set<String>? {
        guard let fresh = RunningApps.bundleIDs(listing: processListing) else { return nil }
        return fresh.union(Self.workspaceBundleIDs())
    }

    private static func workspaceBundleIDs() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    public func hasFullDiskAccess() -> Bool {
        Self.checkFullDiskAccess(candidates: [
            (home as NSString).appendingPathComponent("Library/Containers/com.apple.stocks"),
            (home as NSString).appendingPathComponent("Library/Safari"),
        ])
    }

    /// No access if some protected folder gives `EPERM`/`EACCES` when listed; access if some can be read.
    /// If none exists it cannot be known and access is assumed.
    static func checkFullDiskAccess(candidates: [String]) -> Bool {
        for path in candidates {
            if let dir = opendir(path) {
                closedir(dir)
                return true
            }
            if errno == EPERM || errno == EACCES { return false }
        }
        return true
    }

    public func trashSizeIfReadable() -> Int64? {
        do {
            let names = try FileManager.default.contentsOfDirectory(atPath: trashPath)
            return names.reduce(0) { $0 + (AllocatedSize.of(trashPath + "/" + $1) ?? 0) }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return 0
        } catch {
            return nil
        }
    }

    public func trashSize() -> Int64 {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: trashPath) else { return 0 }
        return names.reduce(0) { $0 + (AllocatedSize.of(trashPath + "/" + $1) ?? 0) }
    }

    public static let finderTimeout: TimeInterval = 60

    public func emptyTrash() async throws -> Int64 {
        // Never through a link: `~/.Trash` must be a real folder of the current user.
        var info = stat()
        if lstat(trashPath, &info) != 0 {
            if errno == ENOENT { return 0 }
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: trashPath])
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else {
            throw CocoaError(.fileReadUnknown, userInfo: [
                NSFilePathErrorKey: trashPath,
                NSLocalizedDescriptionKey: String(localized: "The Trash is not a regular folder of the user; it is not touched.", bundle: .airyCore),
            ])
        }
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: trashPath)
        } catch let error as NSError where Self.isPermissionError(error) {
            return try await emptyWithFinder()
        }
        var freed: Int64 = 0
        for name in names {
            let path = trashPath + "/" + name
            let size = AllocatedSize.of(path) ?? 0
            do {
                // `removeItem` on the entry: a link is deleted as a link, never its target.
                try FileManager.default.removeItem(atPath: path)
                freed += size
            } catch let error as NSError where Self.isPermissionError(error) {
                return freed + (try await emptyWithFinder())
            }
        }
        return freed
    }

    private static func isPermissionError(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain,
           [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(error.code) { return true }
        let posix = (error.userInfo[NSUnderlyingErrorKey] as? NSError) ?? error
        return posix.domain == NSPOSIXErrorDomain && (posix.code == Int(EPERM) || posix.code == Int(EACCES))
    }

    /// Empties with Finder (every trash on every volume), with a time limit.
    private func emptyWithFinder() async throws -> Int64 {
        guard allowFinderFallback else {
            throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: trashPath])
        }
        let before = Self.availableCapacity(home: home)
        let output = try await runner.run(
            "/usr/bin/osascript", ["-e", "tell application \"Finder\" to empty trash"],
            timeout: Self.finderTimeout)
        guard output.status == 0 else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "Finder could not empty the Trash.", bundle: .airyCore),
            ])
        }
        return max(0, Self.availableCapacity(home: home) - before)
    }

    public func localSnapshots() async -> [String] {
        guard let output = try? await runner.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"], timeout: 30),
              output.status == 0 else { return [] }
        return Self.parseSnapshots(output.stdout)
    }

    static func parseSnapshots(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Snapshots for") }
    }

    /// Capacity of the volume that contains `home`, or `nil` if it cannot be read.
    public static func volumeCapacity(home: String) -> VolumeCapacity? {
        guard let values = try? URL(fileURLWithPath: home).resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        ]), let total = values.volumeTotalCapacity else { return nil }
        let available = Int64(values.volumeAvailableCapacity ?? 0)
        return VolumeCapacity(total: Int64(total), available: available,
                              importantAvailable: values.volumeAvailableCapacityForImportantUsage ?? available)
    }

    /// Available space (`volumeAvailableCapacityForImportantUsage`) of the volume that contains `home`.
    public static func availableCapacity(home: String) -> Int64 {
        let values = try? URL(fileURLWithPath: home)
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }
}
