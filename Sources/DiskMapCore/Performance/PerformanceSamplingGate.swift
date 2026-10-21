import Foundation

/// When Performance measures (I3) and when it repeats the maintenance check (M9).
public enum PerformanceSamplingGate {
    /// Only with the section in view and the window **confirmed** visible. `nil` = not known yet (the view has just
    /// been created and the window reader has not reported): nothing is measured until it is known.
    public static func shouldSample(appeared: Bool, windowVisible: Bool?) -> Bool {
        appeared && windowVisible == true
    }

    /// The maintenance check launches processes and reads preferences: at most every 5 min on appearing
    /// (after an action it always repeats).
    public static let maintenanceMaxAge: TimeInterval = 300

    public static func maintenanceIsStale(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck else { return true }
        let age = now.timeIntervalSince(lastCheck)
        return age < 0 || age >= maintenanceMaxAge
    }
}
