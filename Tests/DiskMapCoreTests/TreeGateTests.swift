import Testing
import Foundation
@testable import DiskMapCore

/// Registro ordenado de lo que pasa, compartido entre hilos.
private final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

@MainActor
struct TreeGateTests {
    @Test func mutationWaitsForRunningReaders() async {
        let gate = TreeGate()
        let log = Log()
        _ = gate.read(cancellable: false) {
            try? await Task.sleep(for: .milliseconds(150))
            log.add("lectura")
        }
        await gate.mutate { log.add("cambio") }
        #expect(log.all == ["lectura", "cambio"])
        #expect(gate.activeReaders == 0)
    }

    @Test func cancellableReadersAreCancelledThenAwaited() async {
        let gate = TreeGate()
        let log = Log()
        _ = gate.read(cancellable: true) {
            for _ in 0..<500 {
                if Task.isCancelled { log.add("cancelada"); return }
                try? await Task.sleep(for: .milliseconds(10))
            }
            log.add("terminó sin cancelar")
        }
        try? await Task.sleep(for: .milliseconds(30))
        let start = Date()
        await gate.mutate { log.add("cambio") }
        #expect(log.all == ["cancelada", "cambio"])
        #expect(Date().timeIntervalSince(start) < 2)
    }

    @Test func readersStartedDuringAMutationWaitForIt() async {
        let gate = TreeGate()
        let log = Log()
        _ = gate.read(cancellable: false) {
            try? await Task.sleep(for: .milliseconds(150))
            log.add("lectura 1")
        }
        async let mutation: Void = gate.mutate { log.add("cambio") }
        try? await Task.sleep(for: .milliseconds(20))
        let late = gate.read(cancellable: false) { log.add("lectura 2") }
        await mutation
        await late.value
        #expect(log.all == ["lectura 1", "cambio", "lectura 2"])
    }

    @Test func mutationsRunOneAfterAnother() async {
        let gate = TreeGate()
        let log = Log()
        _ = gate.read(cancellable: false) {
            try? await Task.sleep(for: .milliseconds(80))
            log.add("lectura")
        }
        async let a: Void = gate.mutate { log.add("cambio A") }
        async let b: Void = gate.mutate { log.add("cambio B") }
        _ = await (a, b)
        #expect(log.all.first == "lectura")
        #expect(Set(log.all.dropFirst()) == ["cambio A", "cambio B"])
    }

    @Test func readReturnsItsValue() async {
        let gate = TreeGate()
        let value = await gate.read(cancellable: true) { 42 }.value
        #expect(value == 42)
    }
}
