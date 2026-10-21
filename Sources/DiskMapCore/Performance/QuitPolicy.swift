import Foundation

public enum QuitEligibility: Sendable, Equatable {
    case allowed(Risk)          // .safe (normal app) or .yourCall (loose process); never .doNotTouch
    case never(String)          // visible reason

    public var isAllowed: Bool {
        if case .allowed = self { return true }
        return false
    }
}

/// What can be offered for quitting from Performance. "Never" beats everything else.
public struct QuitPolicy: Sendable {
    public static let neverBundleIDs: Set<String> = [
        "com.apple.finder", "com.apple.dock", "com.apple.loginwindow", "com.apple.systemuiserver",
        "com.apple.controlcenter", "com.apple.notificationcenterui", "com.apple.WindowManager",
        "com.apple.Spotlight", "local.airy.Airy",
    ]
    /// Lowercase; the comparison is case-insensitive.
    public static let neverProcessNames: Set<String> = [
        "finder", "dock", "windowserver", "loginwindow", "systemuiserver", "controlcenter",
        "control center", "notificationcenter", "airy", "airy-mcp", "launchd", "kernel_task",
    ]
    public static var looseWarning: String { String(localized: "You may be using it: a server or a program you launched in the terminal.", bundle: .airyCore) }

    private let currentUID: UInt32
    private let ownPIDs: Set<Int32>

    public init(currentUID: UInt32 = getuid(), ownPIDs: Set<Int32> = [ProcessInfo.processInfo.processIdentifier]) {
        self.currentUID = currentUID
        self.ownPIDs = ownPIDs
    }

    public func eligibility(_ group: AppGroup) -> QuitEligibility {
        let names = ([group.name] + group.processNames).map { $0.lowercased() }
        if ownPIDs.contains(group.leadPID) || !ownPIDs.isDisjoint(with: group.pids)
            || Self.isInsideAiryBundle(group.bundlePath) || names.contains("airy-mcp") {
            return .never(String(localized: "It is Airy itself.", bundle: .airyCore))
        }
        if group.uid != currentUID { return .never(String(localized: "It belongs to another user or to the system.", bundle: .airyCore)) }
        if group.kind == .system { return .never(String(localized: "It is part of macOS.", bundle: .airyCore)) }
        if group.kind == .background { return .never(String(localized: "It is a background process; macOS reopens it by itself.", bundle: .airyCore)) }
        if let id = group.bundleID, Self.neverBundleIDs.contains(id) {
            return .never(String(localized: "macOS needs it to work.", bundle: .airyCore))
        }
        if names.contains(where: Self.neverProcessNames.contains) {
            return .never(String(localized: "macOS needs it to work.", bundle: .airyCore))
        }
        return group.kind == .looseProcess ? .allowed(.yourCall) : .allowed(.safe)
    }

    /// Airy itself or its `airy-mcp` (by name or by being inside `Airy.app`).
    static func isAiry(_ p: OwnProcess) -> Bool {
        ["airy", "airy-mcp"].contains(p.name.lowercased()) || isInsideAiryBundle(p.executablePath)
    }

    /// A group that is Airy itself or its `airy-mcp` (own PID, inside `Airy.app` or by name). Used
    /// so that Airy never points at itself in the sentences nor in what is sent to Claude.
    public static func isAiry(_ group: AppGroup, ownPID: Int32 = ProcessInfo.processInfo.processIdentifier) -> Bool {
        group.leadPID == ownPID || group.pids.contains(ownPID) || isInsideAiryBundle(group.bundlePath)
            || ([group.name] + group.processNames).contains { ["airy", "airy-mcp"].contains($0.lowercased()) }
    }

    private static func isInsideAiryBundle(_ path: String?) -> Bool {
        guard let path else { return false }
        return (path + "/").contains("/Airy.app/")
    }
}
