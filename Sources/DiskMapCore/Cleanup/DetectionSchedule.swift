import Foundation

/// Who asked for a cleanup detection: it decides its QoS.
public enum DetectionTrigger: Sendable, Equatable {
    /// On app launch or after an automatic scan (or an agent's): nobody is waiting in front of it.
    case automatic
    /// The user opened Cleanup, pressed "Search again", changed a setting or just cleaned something.
    case user
}

public enum DetectionSchedule {
    /// Same rule as automatic rescans (`ScanBudget`):
    /// - `automatic`: QoS `.background` (efficiency cores, throttled I/O) and at most 2 walks at a time.
    /// - `user`: QoS `.utility` and at most 2 walks at a time.
    /// With Low Power Mode or a `.serious` or worse temperature, 1 walk.
    /// The detection walks one path at a time and its passes go one by one (a new one waits for the
    /// cancelled one to release the disk), so `workers` is a cap that is never exceeded, not a parallelism.
    public static func budget(_ trigger: DetectionTrigger, lowPowerMode: Bool,
                              thermalState: ProcessInfo.ThermalState) -> ScanBudget {
        let constrained = lowPowerMode || thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        let workers = constrained ? 1 : ScanBudget.lightWorkers
        switch trigger {
        case .automatic: return ScanBudget(workers: workers, qos: .background)
        case .user: return ScanBudget(workers: workers, qos: .utility)
        }
    }

    /// The rule with the Mac's current state.
    public static func current(_ trigger: DetectionTrigger) -> ScanBudget {
        let info = ProcessInfo.processInfo
        return budget(trigger, lowPowerMode: info.isLowPowerModeEnabled, thermalState: info.thermalState)
    }

    /// Task priority equivalent to the budget's QoS (also that of the waiting task: otherwise,
    /// waiting for it from the main thread would raise it).
    public static func priority(for budget: ScanBudget) -> TaskPriority {
        switch budget.qos {
        case .background: return .background
        case .utility: return .utility
        case .userInitiated, .userInteractive: return .userInitiated
        default: return .medium
        }
    }

    /// After a scan, who detects: what the user asked for still belongs to the user.
    public static func trigger(after scan: ScanTrigger) -> DetectionTrigger {
        scan == .user ? .user : .automatic
    }
}

/// When the automatic detection can start: never before there is a tree to reuse (the saved
/// index or the scan that just finished) and never on an index that a running scan is about to replace.
/// The user's detections do not go through here.
public struct DetectionGate: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        /// Reading the saved index: there is nothing to reuse yet.
        case waitingForIndex
        /// There is (or will be) a new scan: the automatic detection waits for it to finish.
        case waitingForScan
        /// Final tree published: the automatic detection can now run.
        case ready
    }

    public private(set) var phase: Phase = .waitingForIndex
    /// A detection already ran once for the user while waiting (opening Cleanup does not repeat it).
    private var servedWhileWaiting = false

    public init() {}

    /// A scan starts (or the reading of its index).
    public mutating func scanStarted() {
        phase = .waitingForIndex
        servedWhileWaiting = false
    }

    /// The saved index was read (or not) and it is known whether there will be a scan. Returns the detection to launch now.
    public mutating func indexRead(hasIndex: Bool, plan: ScanPlan) -> DetectionTrigger? {
        guard phase == .waitingForIndex else { return nil }
        if hasIndex, plan == .skip {
            phase = .ready
            return .automatic
        }
        phase = .waitingForScan
        return nil
    }

    /// The scan finished and its tree is published.
    public mutating func scanFinished(_ trigger: ScanTrigger) -> DetectionTrigger? {
        guard phase != .ready else { return nil }
        phase = .ready
        return DetectionSchedule.trigger(after: trigger)
    }

    /// The scan was cancelled or failed: detect on what is visible, if anything.
    public mutating func scanStopped(hasTree: Bool) -> DetectionTrigger? {
        guard phase != .ready else { return nil }
        phase = .ready
        return hasTree ? .automatic : nil
    }

    /// The user opened Cleanup while waiting for the scan: detect right away on the visible index
    /// (once per wait). With the final tree it is not needed: the automatic one already ran or is running.
    public mutating func cleanupOpened(hasTree: Bool) -> DetectionTrigger? {
        guard phase == .waitingForScan, hasTree, !servedWhileWaiting else { return nil }
        servedWhileWaiting = true
        return .user
    }

    /// An automatic detection requested from outside only runs with the final tree.
    public var allowsAutomatic: Bool { phase == .ready }
}

/// Roots outside of which the detection does not read the disk. Only set with `AIRY_SCAN_ROOTS` (DEBUG): that way
/// the app's checks and the tests never walk the real home (projects, catalog folders).
/// Without a scope (`current == nil`) everything is allowed, as always.
public struct DiskScope: Sendable, Equatable {
    /// Canonical paths (`RiskPolicy.canonical`), with and without resolving links (`/tmp` ⇒ `/private/tmp`).
    public let roots: [String]

    @TaskLocal public static var current: DiskScope?

    public init(roots: [String]) {
        var all: [String] = []
        for root in roots {
            for form in [root, CleanupTargets.realPath(root) ?? root] {
                let canonical = RiskPolicy.canonical(form)
                if !all.contains(canonical) { all.append(canonical) }
            }
        }
        self.roots = all
    }

    /// `path` lies inside some root (or is one): it can be walked.
    public func contains(_ path: String) -> Bool {
        let canonical = RiskPolicy.canonical(path)
        return roots.contains { RiskPolicy.isInside(canonical, root: $0) }
    }

    /// `path` lies inside a root or is an ancestor of one: it can be listed to reach it.
    public func reaches(_ path: String) -> Bool {
        let canonical = RiskPolicy.canonical(path)
        if canonical == "/" { return true }
        return roots.contains { RiskPolicy.isInside(canonical, root: $0) || RiskPolicy.isInside($0, root: canonical) }
    }

    /// `path` can be walked with this task's scope.
    public static func allowsWalk(_ path: String) -> Bool { current?.contains(path) ?? true }

    /// `path` can be listed with this task's scope.
    public static func allowsList(_ path: String) -> Bool { current?.reaches(path) ?? true }
}
