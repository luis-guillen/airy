import Foundation

/// How hard a scan pushes. Airy has to be light: not even the scan the user asks for
/// takes every core.
/// - `background`: automatic rescans (on launch, on disk change, the one an agent asks for).
/// - `normal`: the user pressed "Scan" or there is no index to show in the meantime.
public enum ScanIntensity: String, Sendable, Equatable {
    case background, normal
}

/// Threads and quality of service the scanner uses for `readdir`/`fstatat`.
public struct ScanBudget: Sendable, Equatable {
    /// Absolute cap on scan threads, whatever the machine.
    public static let maxWorkers = 4
    /// Threads in the background, and with Low Power Mode or a hot Mac.
    public static let lightWorkers = 2

    public let workers: Int
    public let qos: QualityOfService

    public init(workers: Int, qos: QualityOfService) {
        self.workers = workers
        self.qos = qos
    }

    /// Pure rule:
    /// - `background` = 2 threads at QoS `.background`: efficiency cores and disk I/O
    ///   throttled by the system, so as not to compete with what the user is doing. It takes longer
    ///   (~30 s versus ~11 s with `.utility` on ~/Library, 580,000 items), and that is accepted.
    /// - `normal` = up to 4 threads (never more than the performance cores) at `.utility`: the
    ///   user is waiting in front of the progress.
    /// With Low Power Mode or a `.serious` or worse temperature, at most 2 threads.
    public static func resolve(
        _ intensity: ScanIntensity,
        performanceCores: Int,
        lowPowerMode: Bool,
        thermalState: ProcessInfo.ThermalState
    ) -> ScanBudget {
        let constrained = lowPowerMode || thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        switch intensity {
        case .background:
            return ScanBudget(workers: lightWorkers, qos: .background)
        case .normal:
            let cores = max(1, performanceCores)
            let workers = constrained ? min(lightWorkers, cores) : min(maxWorkers, cores)
            return ScanBudget(workers: workers, qos: .utility)
        }
    }

    /// The rule with the Mac's current state (performance cores, Low Power Mode, temperature).
    public static func current(_ intensity: ScanIntensity) -> ScanBudget {
        let info = ProcessInfo.processInfo
        return resolve(intensity, performanceCores: performanceCoreCount(),
                       lowPowerMode: info.isLowPowerModeEnabled, thermalState: info.thermalState)
    }

    /// Performance cores (Apple silicon); on a Mac without levels, the active cores.
    static func performanceCoreCount() -> Int {
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &count, &size, nil, 0) == 0, count > 0 {
            return Int(count)
        }
        return ProcessInfo.processInfo.activeProcessorCount
    }
}

/// What asked for the scan: decides whether it is needed and how hard.
public enum ScanTrigger: Sendable, Equatable {
    /// On app launch or on disk change.
    case automatic
    /// `airy://rescan` (e.g. the MCP server's `rescan` tool).
    case agent
    /// The user pressed "Scan".
    case user
}

public enum ScanPlan: Sendable, Equatable {
    /// The saved index is recent: it is shown and not rescanned.
    case skip
    case scan(ScanIntensity)
}

public enum ScanSchedule {
    /// An index younger than this is not rescanned automatically on launch.
    public static let freshness: TimeInterval = 6 * 3600

    /// - Parameters:
    ///   - hasIndex: there is a saved index already being shown.
    ///   - indexDate: that index's date (`nil` if unknown: treated as old).
    public static func plan(_ trigger: ScanTrigger, hasIndex: Bool, indexDate: Date?, now: Date) -> ScanPlan {
        switch trigger {
        case .user:
            return .scan(.normal)
        case .agent:
            return .scan(.background)
        case .automatic:
            // With nothing to show, the user is waiting in front of the progress.
            guard hasIndex else { return .scan(.normal) }
            guard let indexDate else { return .scan(.background) }
            let age = now.timeIntervalSince(indexDate)
            // A future date (changed clock) does not count as recent.
            return age >= 0 && age < freshness ? .skip : .scan(.background)
        }
    }
}

#if DEBUG
/// `AIRY_SCAN_ROOTS` (DEBUG only): `:`-separated paths that replace the whole disk, so that
/// the app's checks scan a small folder. `~` is expanded.
public enum ScanRootsOverride {
    public static let variable = "AIRY_SCAN_ROOTS"

    public static func roots(from environment: [String: String]) -> [URL]? {
        guard let raw = environment[variable] else { return nil }
        let roots = raw.split(separator: ":")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        return roots.isEmpty ? nil : roots
    }

    /// With replaced roots, the index is only saved in a temporary data folder
    /// (`AIRY_SUPPORT_DIR`): a partial tree never overwrites the real index.
    public static func allowsSaving(environment: [String: String]) -> Bool {
        guard roots(from: environment) != nil else { return true }
        return !(environment["AIRY_SUPPORT_DIR"] ?? "").isEmpty
    }
}
#endif
