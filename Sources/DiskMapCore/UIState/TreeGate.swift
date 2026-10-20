import Foundation
import Synchronization

/// Turno de acceso al árbol analizado (`FileNode` es `@unchecked Sendable`: el compilador no ve
/// las carreras). Todo lector que recorra el árbol en segundo plano (guardar el índice, detectar
/// limpiezas, preparar contexto para la IA…) entra por `read`; cualquier cambio en el árbol
/// (p. ej. quitar lo enviado a la Papelera) entra por `mutate`, que cancela los lectores que
/// lo admiten, **espera** a que todos terminen y solo entonces cambia el árbol. Los lectores que
/// llegan durante un cambio esperan a que acabe. Los cambios van de uno en uno.
@MainActor
public final class TreeGate {
    private struct Reader {
        let cancellable: Bool
        let cancel: @Sendable () -> Void
        let wait: @Sendable () async -> Void
    }

    private var readers: [Int: Reader] = [:]
    private var nextID = 0
    private var mutation: Task<Void, Never>?

    public init() {}

    /// Lectores registrados que aún no se han dado por terminados.
    public var activeReaders: Int { readers.count }

    /// Lanza `work` fuera del hilo principal como lector del árbol.
    /// - `cancellable`: si un cambio puede cancelarlo (p. ej. una detección que se repetirá
    ///   después); si es `false` (guardar el índice), el cambio espera a que termine entero.
    @discardableResult
    public func read<T: Sendable>(cancellable: Bool, priority: TaskPriority = .utility,
                                  _ work: @escaping @Sendable () async -> T) -> Task<T, Never> {
        let pending = mutation
        let job = Task.detached(priority: priority) { () -> T in
            await pending?.value
            return await work()
        }
        nextID += 1
        let id = nextID
        readers[id] = Reader(cancellable: cancellable, cancel: { job.cancel() }, wait: { _ = await job.value })
        Task { [weak self] in
            _ = await job.value
            self?.readers[id] = nil
        }
        return job
    }

    /// Cambia el árbol cuando ningún lector lo está recorriendo. `body` corre en el hilo principal.
    /// Ojo: `body` va en una tarea no estructurada; cancelar a quien llama no lo detiene (una vez
    /// pedido el cambio, se hace en cuanto terminen los lectores).
    public func mutate(_ body: @escaping @MainActor () -> Void) async {
        let previous = mutation
        let current = readers
        let task = Task { @MainActor in
            await previous?.value
            for reader in current.values where reader.cancellable { reader.cancel() }
            for reader in current.values { await reader.wait() }
            body()
        }
        mutation = task
        await task.value
        for id in current.keys { readers[id] = nil }
        if mutation == task { mutation = nil }
    }
}

/// Turnos de guardado por clave (p. ej. un volumen): cada guardado pide un turno y, justo antes
/// de escribir, comprueba que sigue siendo el último pedido para esa clave. Así, si dos guardados
/// del mismo índice se encadenan, nunca queda en disco el árbol más antiguo.
public final class SaveSequencer: Sendable {
    private let tickets = Mutex<[String: Int]>([:])

    public init() {}

    /// Pide turno para `key`; invalida los anteriores de esa misma clave.
    public func begin(_ key: String) -> Int {
        tickets.withLock { state in
            let next = (state[key] ?? 0) + 1
            state[key] = next
            return next
        }
    }

    public func isLatest(_ ticket: Int, for key: String) -> Bool {
        tickets.withLock { $0[key] == ticket }
    }
}
