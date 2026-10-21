import Foundation

/// Entries with `discovery {"type":"simulatorRuntimes"}`: orphaned simulator runtimes (deletable and without
/// any simulator using them), one per item, with its UUID as `{target}`. Read-only `simctl` probes only.
///
/// `xcrun` is never called on a Mac without Xcode: on one without tools, the `/usr/bin/xcrun` shim opens the
/// "Install developer tools" dialog, and with Xcode it starts CoreSimulatorService. First it needs
/// (1) some CoreSimulator folder (without launching anything) and (2) a valid `xcode-select -p` pointing to an
/// existing Xcode folder (not to the Command Line Tools, which do not ship `simctl`).
public struct SimulatorRuntimeSource: CleanupTargetSource {
    /// System CoreSimulator folders (besides `~/Library/Developer/CoreSimulator`).
    static let systemRoots = ["/Library/Developer/CoreSimulator"]
    static let userRoot = "/Library/Developer/CoreSimulator"
    static let xcodeSelectArguments = ["-p"]
    static let xcodeSelectTimeout: TimeInterval = 5

    private let systemRoots: [String]

    public init() { self.init(systemRoots: Self.systemRoots) }

    /// Tests: custom system folders (so as not to depend on the Mac where they run).
    init(systemRoots: [String]) { self.systemRoots = systemRoots }

    static let runtimeArguments = ["simctl", "runtime", "list", "-j"]
    static let deviceArguments = ["simctl", "list", "devices", "-j"]
    static let timeout: TimeInterval = 20
    static var goneMessage: String { String(localized: "That simulator runtime is already used by a simulator or is gone.", bundle: .airyCore) }
    static let platforms = [
        "com.apple.platform.iphonesimulator": "iOS",
        "com.apple.platform.watchsimulator": "watchOS",
        "com.apple.platform.appletvsimulator": "tvOS",
        "com.apple.platform.xrsimulator": "visionOS",
    ]

    struct Runtime: Equatable {
        var identifier: String
        var platform: String
        var version: String
        var bytes: Int64
        var label: String { "\(platform) \(version)" }
    }

    public func discover(_ entry: CatalogEntry, context: DiscoveryContext) async -> [DiscoveredTarget] {
        guard entry.cleanup.usesTargets else { return [] }
        var used = Set<String>()
        return await orphans(context).map { runtime in
            // Two runtimes with the same version (different builds) do not share an item id.
            var suffix = runtime.label
            if !used.insert(suffix).inserted { suffix += " (\(runtime.identifier.prefix(8)))" }
            return DiscoveredTarget(idSuffix: suffix, paths: [], targets: [runtime.identifier], bytes: runtime.bytes)
        }
    }

    /// Probes again: each target must still be orphaned and deletable.
    public func revalidate(_ entry: CatalogEntry, item: CleanupItem, context: DiscoveryContext) async -> String? {
        guard entry.cleanup.usesTargets, !item.targets.isEmpty else { return Self.goneMessage }
        let live = Set(await orphans(context).map(\.identifier))
        return item.targets.allSatisfy(live.contains) ? nil : Self.goneMessage
    }

    /// `xcrun` only if there is CoreSimulator and Xcode (see above); otherwise, `nil` and nothing else is launched.
    func xcrunIfXcode(_ context: DiscoveryContext) async -> String? {
        let roots = [context.home + Self.userRoot] + systemRoots
        guard roots.contains(where: Self.isDirectory) else { return nil }
        let runner = context.runner
        guard let select = await runner.resolve("xcode-select"),
              let output = try? await runner.run(select, Self.xcodeSelectArguments, timeout: Self.xcodeSelectTimeout),
              output.status == 0 else { return nil }
        let developer = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard developer.hasPrefix("/"), !developer.contains("CommandLineTools"), Self.isDirectory(developer)
        else { return nil }
        return await runner.resolve("xcrun")
    }

    func orphans(_ context: DiscoveryContext) async -> [Runtime] {
        guard let xcrun = await xcrunIfXcode(context) else { return [] }
        return await Self.orphans(xcrun: xcrun, runner: context.runner)
    }

    /// `deletable` runtimes without devices in their `runtimeIdentifier`, sorted. Any failure ⇒ `[]`.
    static func orphans(xcrun: String, runner: any CommandRunning) async -> [Runtime] {
        guard let runtimes = await json(xcrun, runtimeArguments, runner: runner) as? [String: Any],
              let devices = (await json(xcrun, deviceArguments, runner: runner) as? [String: Any])?["devices"]
                as? [String: Any]
        else { return [] }
        var result: [Runtime] = []
        for case let info as [String: Any] in runtimes.values {
            guard (info["deletable"] as? Bool) == true,
                  let identifier = info["identifier"] as? String, isUUID(identifier),
                  let runtimeIdentifier = info["runtimeIdentifier"] as? String,
                  let version = info["version"] as? String,
                  let bytes = (info["sizeBytes"] as? NSNumber)?.int64Value
            else { continue }
            // With some device (or a list that cannot be understood) it is not orphaned.
            if let list = devices[runtimeIdentifier] {
                guard let array = list as? [Any], array.isEmpty else { continue }
            }
            let platformID = info["platformIdentifier"] as? String ?? ""
            let platform = platforms[platformID] ?? "Simulator"
            result.append(Runtime(identifier: identifier, platform: platform, version: version, bytes: bytes))
        }
        return result.sorted { ($0.label, $0.identifier) < ($1.label, $1.identifier) }
    }

    /// `^[0-9A-Fa-f-]{36}$`: the only thing that arrives as an argument of `simctl runtime delete`.
    static func isUUID(_ text: String) -> Bool {
        text.utf8.count == 36 && text.unicodeScalars.allSatisfy { $0 == "-" || $0.properties.isASCIIHexDigit }
    }

    private static func isDirectory(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    private static func json(_ xcrun: String, _ arguments: [String], runner: any CommandRunning) async -> Any? {
        guard let output = try? await runner.run(xcrun, arguments, timeout: timeout), output.status == 0 else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: Data(output.stdout.utf8))
    }
}
