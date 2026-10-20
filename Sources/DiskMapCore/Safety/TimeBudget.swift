import Foundation

/// Presupuestos de tiempo de las comprobaciones previas a limpiar.
public enum TimeBudget {
    public static let processScan: Duration = .seconds(3)
    public static let sizeMeasure: Duration = .seconds(30)
    public static let references: TimeInterval = 10
    /// Detección de versiones de herramientas de desarrollo (inventario, uso, `brew uses`).
    public static let toolchains: Duration = .seconds(20)

    /// Resultado de `operation`, o `nil` si no termina a tiempo (la tarea se cancela).
    /// No usa un grupo de tareas: un grupo esperaría a una llamada bloqueante (libproc) aunque haya vencido el plazo.
    /// Si la operación no coopera con la cancelación, queda abandonada en segundo plano, pero quien llama vuelve ya.
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

    /// Reanuda la continuación exactamente una vez y cancela las tareas en carrera.
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
