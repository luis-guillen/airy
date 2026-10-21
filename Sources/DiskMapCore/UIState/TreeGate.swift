import Foundation
import Synchronization

/// Access turn for the scanned tree (`FileNode` is `@unchecked Sendable`: the compiler does not see
/// the races). Every reader that walks the tree in the background (saving the index, detecting
/// cleanups, preparing context for the AI…) goes through `read`; any change to the tree
/// (e.g. removing what was sent to the Trash) goes through `mutate`, which cancels the readers that
/// allow it, **waits** for all of them to finish and only then changes the tree. Readers that
/// arrive during a change wait for it to end. Changes go one at a time.
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

    /// Registered readers that have not been marked as finished yet.
    public var activeReaders: Int { readers.count }

    /// Runs `work` off the main thread as a tree reader.
    /// - `cancellable`: whether a change can cancel it (e.g. a detection that will be repeated
    ///   later); if `false` (saving the index), the change waits for it to finish completely.
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

    /// Changes the tree when no reader is walking it. `body` runs on the main thread.
    /// Careful: `body` runs in an unstructured task; cancelling the caller does not stop it (once
    /// the change is requested, it happens as soon as the readers finish).
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

/// Save turns per key (e.g. a volume): each save asks for a turn and, right before
/// writing, checks that it is still the latest request for that key. That way, if two saves
/// of the same index are chained, the oldest tree never stays on disk.
public final class SaveSequencer: Sendable {
    private let tickets = Mutex<[String: Int]>([:])

    public init() {}

    /// Asks for a turn for `key`; invalidates the previous ones for that same key.
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
