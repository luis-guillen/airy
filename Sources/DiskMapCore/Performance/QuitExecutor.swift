import AppKit
import Darwin
import Foundation
import Synchronization

/// Quien de verdad pide cerrar o fuerza un proceso. En pruebas se usa un doble: nunca un proceso real.
public protocol ProcessTerminating: Sendable {
    /// Cierre normal. App: `NSRunningApplication.terminate()` (puede pedir guardar). Suelto: `SIGTERM`.
    func requestQuit(pid: Int32, isApp: Bool) -> Bool
    /// Forzar. App: `forceTerminate` de `NSRunningApplication`. Suelto: `SIGKILL`.
    func forceQuit(pid: Int32, isApp: Bool) -> Bool
    /// Sigue vivo el mismo proceso: mismo PID y mismo inicio (±1 s), para no confundirlo con un PID reutilizado.
    func isAlive(pid: Int32, startedAt: Date) -> Bool
}

public struct LiveTerminator: ProcessTerminating {
    public init() {}

    public func requestQuit(pid: Int32, isApp: Bool) -> Bool {
        guard pid > 1 else { return false }   // kill(0)/kill(-1) irían a grupos enteros
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
    case didNotClose            // no respondió en `wait`: ahora se puede forzar
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

/// El embudo de cierre de apps (R6): revalidar al actuar → cierre normal primero → forzar solo lo que no
/// respondió en `wait` → registrar cada intento. Los agentes nunca cierran nada. Es el único sitio que fuerza.
public final class QuitExecutor: Sendable {
    public static let agentRefusal = "Cerrar apps siempre lo decides tú en Airy."
    public static let goneMessage = "Ya no está abierta."
    public static let forceFirstMessage = "Primero hay que intentar cerrarla normalmente."
    public static let requestFailedMessage = "No se pudo pedir que se cerrara."
    public static let forceFailedMessage = "No se pudo forzar el cierre."

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
    /// Los que no se cerraron con el cierre normal dentro de `wait`: solo estos se pueden forzar.
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

    // MARK: - Pasos

    /// Contexto, grupo actual con el mismo id/PID/inicio, política del grupo actual y proceso aún vivo.
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
        // Solo al proceso principal: las ayudantes se cierran con su app; un suelto es un solo PID.
        guard terminator.requestQuit(pid: current.leadPID, isApp: current.kind == .app) else {
            return (.failed(Self.requestFailedMessage), current)
        }
        let deadline = ContinuousClock.now + wait
        while ContinuousClock.now < deadline {
            if !terminator.isAlive(pid: current.leadPID, startedAt: current.leadStart) { return (.closed, current) }
            do { try await Task.sleep(for: poll) } catch { break }
        }
        if !terminator.isAlive(pid: current.leadPID, startedAt: current.leadStart) { return (.closed, current) }
        // Solo cuenta como «no responde» si de verdad se esperó todo el plazo (no si se canceló la espera).
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
        unresponsive.withLock { _ = $0.remove(key) }
        return (.closed, current)
    }

    private func record(_ outcome: QuitOutcome, action: String, group: AppGroup, context: OperationContext) {
        // Un fallo queda pendiente en `log.takeWriteFailure()` para que la app lo avise.
        try? log?.append(OperationRecord(
            runID: context.runID, date: Date(), actor: context.actor, action: action, itemID: group.id,
            title: group.name, paths: [], command: nil, dryRun: false, outcome: outcome.logName,
            bytes: group.memory, message: outcome.message, proposedBy: context.proposedBy,
            proposedVia: context.proposedVia))
    }
}
