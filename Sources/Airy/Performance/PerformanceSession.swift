import AppKit
import Foundation
import Observation
import DiskMapCore

/// Performance state. Lightness: it measures every 1.5 s **only** between `start()` and `stop()` (section in view,
/// window visible); outside of that there is no timer or live task.
@MainActor @Observable
final class PerformanceSession {
    static let interval: Duration = .milliseconds(1500)

    private(set) var snapshot: PerformanceSnapshot?
    private(set) var verdict: HealthVerdict?
    private(set) var board = PerformanceBoard(snapshot: nil, policy: QuitPolicy())
    var selection: Set<String> = []
    /// Ids that didn't quit with the normal quit (`.didNotClose`): they can be forced.
    private(set) var unresponsive: Set<String> = []
    /// Ids flying out of the list (they quit).
    private(set) var leaving: Set<String> = []
    /// Message of the last action per row (`.blocked`/`.failed`).
    private(set) var rowMessages: [String: String] = [:]
    /// Ids quitting right now.
    private(set) var closing: Set<String> = []
    private(set) var loginItems: [BrokenLoginItem] = []
    private(set) var maintenance: [CleanupItem] = []
    private(set) var maintenanceResults: [String: String] = [:]
    private(set) var spotlight: SpotlightDiagnosis?
    private(set) var isCheckingSpotlight = false

    let monitor: PerformanceMonitor
    @ObservationIgnored weak var model: AppModel?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let runner = ProcessRunner()
    @ObservationIgnored private let probes: DiagnosisProbes
    @ObservationIgnored private var maintenanceCheckedAt: Date?

    init() {
        let catalog = try? AppCatalog.bundled()
        monitor = PerformanceMonitor(sampler: LiveSampler(runner: runner)) { raw, cpu, energy in
            AppGrouper.group(raw, cpu: cpu, energy: energy, catalog: catalog)
        }
        probes = DiagnosisProbes(runner: runner)
    }

    var isRunning: Bool { task != nil }

    /// Idempotent: a single sampling task.
    func start() {
        guard task == nil else { return }
        Self.debugLog("start")
        let monitor = monitor
        let probes = probes
        task = Task { [weak self] in
            // M1: the history starts from scratch on each visit, before the first sample (no races with `stop()`).
            await monitor.reset()
            while !Task.isCancelled {
                let snapshot = await monitor.refresh()
                Self.debugLog("sample")
                let verdict = await monitor.verdict(probes: probes)
                Self.debugLog("verdict")
                guard !Task.isCancelled else { break }
                self?.publish(snapshot, verdict: verdict)
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    /// Stops everything: no measurement afterwards.
    func stop() {
        if task != nil { Self.debugLog("stop") }
        task?.cancel()
        task = nil
        // I2: nothing from one visit is used in the next (neither for the view nor for an `airy://quit` proposal).
        snapshot = nil
        verdict = nil
        board = PerformanceBoard(snapshot: nil, policy: QuitPolicy())
    }

    /// Debug only with `AIRY_PERF_LOG=1`: sampling trace (to check that it stops).
    nonisolated static func debugLog(_ event: String) {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["AIRY_PERF_LOG"] == "1" else { return }
        FileHandle.standardError.write(Data("[perf] \(Date().timeIntervalSince1970) \(event)\n".utf8))
        #endif
    }

    private func publish(_ snapshot: PerformanceSnapshot, verdict: HealthVerdict) {
        self.snapshot = snapshot
        self.verdict = verdict
        board = PerformanceBoard(snapshot: snapshot, policy: QuitPolicy())
        let alive = Set(snapshot.groups.map(\.id))
        // What no longer exists stops being selected, leaving or not responding.
        selection.formIntersection(alive)
        unresponsive.formIntersection(alive)
        if !leaving.isEmpty { leaving.formIntersection(alive) }
        rowMessages = rowMessages.filter { alive.contains($0.key) }
    }

    /// For `airy://quit`: a snapshot taken after the request (I2). It waits for the section's sampling
    /// one; if it doesn't arrive (window hidden, section not open), it measures once.
    func freshSnapshot() async -> PerformanceSnapshot {
        let requested = Date()
        for _ in 0..<20 {
            if let snapshot, snapshot.date >= requested { return snapshot }
            try? await Task.sleep(for: .milliseconds(150))
        }
        if let snapshot, snapshot.date >= requested { return snapshot }
        return await monitor.snapshot(since: requested)
    }

    // MARK: Quit

    func markClosing(_ id: String, _ on: Bool) {
        if on { closing.insert(id); rowMessages[id] = nil } else { closing.remove(id) }
    }

    func markClosed(_ id: String) {
        selection.remove(id)
        unresponsive.remove(id)
        _ = leaving.insert(id)
    }

    func markUnresponsive(_ id: String) { unresponsive.insert(id) }

    func setMessage(_ id: String, _ message: String) { rowMessages[id] = message }

    /// Visible rows: without the ones that already left.
    var visibleRows: [PerformanceRow] { board.rows.filter { !leaving.contains($0.id) } }

    // MARK: Maintenance

    /// On appearing with the window visible: only if the last check is more than a few minutes old (M9).
    func refreshMaintenanceIfStale() async {
        guard PerformanceSamplingGate.maintenanceIsStale(lastCheck: maintenanceCheckedAt, now: Date()) else { return }
        await refreshMaintenance()
    }

    /// `MaintenanceScanner` + broken login items (reads only). On appearing (with a cache) and after each action.
    func refreshMaintenance() async {
        maintenanceCheckedAt = Date()
        let onAC = snapshot?.battery?.onACPower ?? BatteryProbe.cached()?.onACPower ?? true
        let spotlight = spotlight
        let runner = runner
        let catalog = model?.catalog
        let classifier = model?.classifier
        let (items, broken) = await Task.detached(priority: .utility) { () -> ([CleanupItem], [BrokenLoginItem]) in
            var items: [CleanupItem] = []
            if let catalog {
                items = await MaintenanceScanner(catalog: catalog, runner: runner, home: NSHomeDirectory(),
                                                 classifier: classifier)
                    .findItems(spotlight: spotlight, onACPower: onAC)
            }
            return (items, LoginItemsAudit.broken(in: LoginItemsAudit.standardDirectories()))
        }.value
        maintenance = items
        loginItems = broken
    }

    func checkSpotlight() async {
        guard !isCheckingSpotlight else { return }
        isCheckingSpotlight = true
        spotlight = await SpotlightCheck(runner: runner).run()
        isCheckingSpotlight = false
        await refreshMaintenance()
    }

    func setMaintenanceResult(_ id: String, _ outcome: CleanupOutcome) {
        switch outcome {
        case .freed: maintenanceResults[id] = String(localized: "Done")
        case .movedToTrash: maintenanceResults[id] = String(localized: "Done: it’s in the Trash")
        case .blocked(let reason): maintenanceResults[id] = reason
        case .failed(let message): maintenanceResults[id] = message
        }
    }
}
