import AppKit
import Darwin
import Foundation
import Synchronization

/// Who really asks to quit or force-quits a process. Tests use a double: never a real process.
public protocol ProcessTerminating: Sendable {
    /// Normal quit. App: `NSRunningApplication.terminate()` (it may ask to save). Loose: `SIGTERM`.
    func requestQuit(pid: Int32, isApp: Bool) -> Bool
    /// Force. App: `NSRunningApplication`'s `forceTerminate`. Loose: `SIGKILL`.
    func forceQuit(pid: Int32, isApp: Bool) -> Bool
    /// The same process is still alive: same PID and same start (±1 s), so as not to mistake it for a reused PID.
    func isAlive(pid: Int32, startedAt: Date) -> Bool
}

public struct LiveTerminator: ProcessTerminating {
    public init() {}

    public func requestQuit(pid: Int32, isApp: Bool) -> Bool {
        guard pid > 1 else { return false }   // kill(0)/kill(-1) would hit whole groups
        if isApp { return NSRunningApplication(processIdentifier: pid)?.terminate() ?? false }
        return kill(pid, SIGTERM) == 0
    }

    public func forceQuit(pid: Int32, isApp: Bool) -> Bool {
        guard pid > 1 else { return false }
        if isApp { return NSRunningApplication(processIdentifier: pid)?.forceTerminate() ?? false }
        return kill(pid, SIGKILL) == 0
    }

    public func isAlive(pid: Int32, startedAt: Date) -> Bool {
        guard pid > 0 else { return false }
        var bsd = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size else { return false }
        let start = TimeInterval(bsd.pbi_start_tvsec) + TimeInterval(bsd.pbi_start_tvusec) / 1_000_000
        return abs(start - startedAt.timeIntervalSince1970) <= 1
    }
}

public enum QuitOutcome: Sendable, Equatable {
    case closed
    case didNotClose            // did not respond within `wait`: now it can be forced
    case blocked(String)
    case failed(String)

    var logName: String {
        switch self {
        case .closed: "closed"
        case .didNotClose: "did_not_close"
        case .blocked: "blocked"
        case .failed: "failed"
        }
    }

    var message: String? {
        switch self {
        case .closed, .didNotClose: nil
        case .blocked(let m), .failed(let m): m
        }
    }
}

/// The app quit funnel (R6): revalidate when acting → normal quit first → force only what did not
/// respond within `wait` → record every attempt. Agents never quit anything. It is the only place that forces.
public final class QuitExecutor: Sendable {
    public static var agentRefusal: String { String(localized: "Quitting apps is always your decision, in Airy.", bundle: .airyCore) }
    public static var goneMessage: String { String(localized: "It is no longer open.", bundle: .airyCore) }
    public static var forceFirstMessage: String { String(localized: "You first have to try quitting it normally.", bundle: .airyCore) }
    public static var requestFailedMessage: String { String(localized: "Could not ask it to quit.", bundle: .airyCore) }
    public static var forceFailedMessage: String { String(localized: "Could not force it to quit.", bundle: .airyCore) }
    /// How long to wait for it to disappear after forcing (at most `wait`).
    static let forceGrace: Duration = .seconds(2)

    private enum Check { case ok(AppGroup), stop(QuitOutcome) }

    private struct Key: Hashable, Sendable {
        let pid: Int32
        let start: Date
    }

    private let terminator: any ProcessTerminating
    private let policy: QuitPolicy
    private let currentGroups: @Sendable () async -> [AppGroup]
    private let log: OperationLog?
    private let wait: Duration
    private let poll: Duration
    /// The ones that did not quit with the normal quit within `wait`: only these can be forced.
    private let unresponsive = Mutex<Set<Key>>([])

    public init(terminator: any ProcessTerminating = LiveTerminator(), policy: QuitPolicy = QuitPolicy(),
                currentGroups: @escaping @Sendable () async -> [AppGroup], log: OperationLog? = nil,
                wait: Duration = .seconds(10), poll: Duration = .milliseconds(250)) {
        self.terminator = terminator
        self.policy = policy
        self.currentGroups = currentGroups
        self.log = log
        self.wait = wait
        self.poll = poll
    }

    public func canForceQuit(_ group: AppGroup) -> Bool {
        unresponsive.withLock { $0.contains(Key(pid: group.leadPID, start: group.leadStart)) }
    }

    public func quit(_ group: AppGroup, context: OperationContext) async -> QuitOutcome {
        let (outcome, current) = await performQuit(group, context: context)
        record(outcome, action: "quit_app", group: current ?? group, context: context)
        return outcome
    }

    public func forceQuit(_ group: AppGroup, context: OperationContext) async -> QuitOutcome {
        let (outcome, current) = await performForce(group, context: context)
        record(outcome, action: "force_quit_app", group: current ?? group, context: context)
        return outcome
    }

    // MARK: - Steps

    /// Context, current group with the same id/PID/start, policy of the current group and process still alive.
    private func revalidate(_ group: AppGroup, context: OperationContext) async -> Check {
        if context.isAgent { return .stop(.blocked(Self.agentRefusal)) }
        let groups = await currentGroups()
        guard let current = groups.first(where: {
            $0.id == group.id && $0.leadPID == group.leadPID && $0.leadStart == group.leadStart
        }) else { return .stop(.blocked(Self.goneMessage)) }
        if case .never(let reason) = policy.eligibility(current) { return .stop(.blocked(reason)) }
        guard current.leadPID > 1, terminator.isAlive(pid: current.leadPID, startedAt: current.leadStart) else {
            return .stop(.blocked(Self.goneMessage))
        }
        return .ok(current)
    }

    private func performQuit(_ group: AppGroup, context: OperationContext) async -> (QuitOutcome, AppGroup?) {
        let current: AppGroup
        switch await revalidate(group, context: context) {
        case .stop(let outcome): return (outcome, nil)
        case .ok(let g): current = g
        }
        // Only the main process: helpers quit with their app; a loose one is a single PID.
        guard terminator.requestQuit(pid: current.leadPID, isApp: current.kind == .app) else {
            return (.failed(Self.requestFailedMessage), current)
        }
        let deadline = ContinuousClock.now + wait
        if await waitForExit(current, within: wait) { return (.closed, current) }
        // It only counts as "not responding" if the whole time limit was really waited (not if the wait was cancelled).
        if ContinuousClock.now >= deadline {
            unresponsive.withLock { _ = $0.insert(Key(pid: current.leadPID, start: current.leadStart)) }
        }
        return (.didNotClose, current)
    }

    private func performForce(_ group: AppGroup, context: OperationContext) async -> (QuitOutcome, AppGroup?) {
        let current: AppGroup
        switch await revalidate(group, context: context) {
        case .stop(let outcome): return (outcome, nil)
        case .ok(let g): current = g
        }
        let key = Key(pid: current.leadPID, start: current.leadStart)
        guard unresponsive.withLock({ $0.contains(key) }) else { return (.blocked(Self.forceFirstMessage), current) }
        guard terminator.forceQuit(pid: current.leadPID, isApp: current.kind == .app) else {
            return (.failed(Self.forceFailedMessage), current)
        }
        // Being sent is not enough: it is only called "quit" once the process is gone.
        guard await waitForExit(current, within: min(wait, Self.forceGrace)) else {
            return (.failed(Self.forceFailedMessage), current)
        }
        unresponsive.withLock { _ = $0.remove(key) }
        return (.closed, current)
    }

    /// Polls `isAlive` every `poll` until `within`; true if the process ended. A cancellation cuts the wait short.
    private func waitForExit(_ group: AppGroup, within: Duration) async -> Bool {
        let deadline = ContinuousClock.now + within
        while ContinuousClock.now < deadline {
            if !terminator.isAlive(pid: group.leadPID, startedAt: group.leadStart) { return true }
            do { try await Task.sleep(for: poll) } catch { break }
        }
        return !terminator.isAlive(pid: group.leadPID, startedAt: group.leadStart)
    }

    private func record(_ outcome: QuitOutcome, action: String, group: AppGroup, context: OperationContext) {
        // A failure stays pending in `log.takeWriteFailure()` so that the app warns about it.
        try? log?.append(OperationRecord(
            runID: context.runID, date: Date(), actor: context.actor, action: action, itemID: group.id,
            title: group.name, paths: [], command: nil, dryRun: false, outcome: outcome.logName,
            bytes: group.memory, message: outcome.message, proposedBy: context.proposedBy,
            proposedVia: context.proposedVia))
    }
}
