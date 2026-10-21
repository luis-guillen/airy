import Foundation

/// Time budgets of the checks before cleaning.
public enum TimeBudget {
    public static let processScan: Duration = .seconds(3)
    public static let sizeMeasure: Duration = .seconds(30)
    public static let references: TimeInterval = 10
    /// Detection of development tool versions (inventory, usage, `brew uses`).
    public static let toolchains: Duration = .seconds(20)

    /// Result of `operation`, or `nil` if it does not finish in time (the task is cancelled).
    /// It does not use a task group: a group would wait for a blocking call (libproc) even after the deadline.
    /// If the operation does not cooperate with cancellation, it is left running in the background, but the caller returns right away.
    public static func run<T: Sendable>(
        _ limit: Duration, _ operation: @escaping @Sendable () async -> T
    ) async -> T? {
        let gate = Gate<T>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
                gate.install(continuation)
                let work = Task.detached { gate.finish(await operation()) }
                let timer = Task.detached {
                    try? await Task.sleep(for: limit)
                    gate.finish(nil)
                }
                gate.track([work, timer])
            }
        } onCancel: {
            gate.finish(nil)
        }
    }

    /// Resumes the continuation exactly once and cancels the racing tasks.
    private final class Gate<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T?, Never>?
        private var tasks: [Task<Void, Never>] = []
        private var done = false
        private var earlyResult: T??

        func install(_ continuation: CheckedContinuation<T?, Never>) {
            lock.lock()
            if let early = earlyResult {
                lock.unlock()
                continuation.resume(returning: early)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        func track(_ new: [Task<Void, Never>]) {
            lock.lock()
            if done {
                lock.unlock()
                new.forEach { $0.cancel() }
                return
            }
            tasks = new
            lock.unlock()
        }

        func finish(_ value: T?) {
            lock.lock()
            guard !done else { lock.unlock(); return }
            done = true
            let pending = continuation
            continuation = nil
            if pending == nil { earlyResult = .some(value) }
            let toCancel = tasks
            tasks = []
            lock.unlock()
            toCancel.forEach { $0.cancel() }
            pending?.resume(returning: value)
        }
    }
}
