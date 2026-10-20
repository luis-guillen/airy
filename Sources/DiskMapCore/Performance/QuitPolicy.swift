import Foundation

public enum QuitEligibility: Sendable, Equatable {
    case allowed(Risk)          // .safe (app normal) o .yourCall (proceso suelto); nunca .doNotTouch
    case never(String)          // motivo visible

    public var isAllowed: Bool {
        if case .allowed = self { return true }
        return false
    }
}

/// Qué se puede ofrecer para cerrar desde Rendimiento. «Nunca» gana a todo lo demás.
public struct QuitPolicy: Sendable {
    public static let neverBundleIDs: Set<String> = [
        "com.apple.finder", "com.apple.dock", "com.apple.loginwindow", "com.apple.systemuiserver",
        "com.apple.controlcenter", "com.apple.notificationcenterui", "com.apple.WindowManager",
        "com.apple.Spotlight", "local.airy.Airy",
    ]
    /// En minúsculas; la comparación no distingue mayúsculas.
    public static let neverProcessNames: Set<String> = [
        "finder", "dock", "windowserver", "loginwindow", "systemuiserver", "controlcenter",
        "control center", "notificationcenter", "airy", "airy-mcp", "launchd", "kernel_task",
    ]
    public static let looseWarning = "Puede que estés usándolo: un servidor o un programa que lanzaste en la terminal."

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
            return .never("Es el propio Airy.")
        }
        if group.uid != currentUID { return .never("Es de otro usuario o del sistema.") }
        if group.kind == .system { return .never("Es parte de macOS.") }
        if group.kind == .background { return .never("Es un proceso de fondo; macOS lo vuelve a abrir solo.") }
        if let id = group.bundleID, Self.neverBundleIDs.contains(id) {
            return .never("macOS lo necesita para funcionar.")
        }
        if names.contains(where: Self.neverProcessNames.contains) {
            return .never("macOS lo necesita para funcionar.")
        }
        return group.kind == .looseProcess ? .allowed(.yourCall) : .allowed(.safe)
    }

    private static func isInsideAiryBundle(_ path: String?) -> Bool {
        guard let path else { return false }
        return (path + "/").contains("/Airy.app/")
    }
}
