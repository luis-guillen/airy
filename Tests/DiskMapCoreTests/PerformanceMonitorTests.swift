import Foundation
import Synchronization
import Testing
@testable import DiskMapCore

/// Sampler guionizado: devuelve las muestras en orden (repite la última) y cuenta llamadas.
final class FakeSampler: PerformanceSampling, Sendable {
    private let state: Mutex<(samples: [RawSample], calls: Int)>
    init(_ samples: [RawSample]) { state = Mutex((samples, 0)) }
    var calls: Int { state.withLock { $0.calls } }
    func sample() async -> RawSample {
        state.withLock { s in
            let i = min(s.calls, s.samples.count - 1)
            s.calls += 1
            return s.samples[i]
        }
    }
}

private let t0 = Date(timeIntervalSince1970: 1_000_000)
private let second: UInt64 = 1_000_000_000

private func raw(_ n: Int = 0, cores: [CoreTicks] = [], topology: CoreTopology? = nil,
                 processes: [OwnProcess] = [], system: [SystemProcess]? = nil,
                 disk: IOCounters? = nil, network: IOCounters? = nil, uptimeNs: UInt64? = nil) -> RawSample {
    RawSample(date: t0.addingTimeInterval(Double(n)), uptimeNs: uptimeNs ?? UInt64(n) * second,
              cores: cores, topology: topology, bootTime: t0.addingTimeInterval(-3600),
              processes: processes, system: system, disk: disk, network: network)
}

@Suite struct PerformanceMonitorTests {
    @Test func monitorNeverSamplesUnasked() async throws {
        let sampler = FakeSampler([raw()])
        _ = PerformanceMonitor(sampler: sampler)
        try await Task.sleep(for: .milliseconds(300))
        #expect(sampler.calls == 0)
    }

    @Test func firstSnapshotHasNoCPUOrRates() async {
        let monitor = PerformanceMonitor(sampler: FakeSampler([
            raw(cores: [CoreTicks(user: 1, system: 1, idle: 1)],
                processes: [OwnProcess(pid: 5, name: "a", cpuTimeNs: 10)],
                disk: IOCounters(read: 1, written: 1), network: IOCounters(read: 1, written: 1))]))
        let s = await monitor.refresh()
        #expect(s.cpu == nil); #expect(s.disk == nil); #expect(s.network == nil)
        #expect(s.processCPU.isEmpty); #expect(s.uptime == 3600)
    }

    @Test func cpuTotalAndClustersFromTicks() async {
        let topo = CoreTopology(performance: 2, efficiency: 2)
        // Núcleos 0-1 eficiencia (50 %), 2-3 rendimiento (100 %).
        let a = [CoreTicks](repeating: CoreTicks(user: 0, system: 0, idle: 0), count: 4)
        let b = [CoreTicks(user: 30, system: 20, idle: 50), CoreTicks(user: 50, system: 0, idle: 50),
                 CoreTicks(user: 80, system: 10, idle: 0, nice: 10), CoreTicks(user: 100, system: 0, idle: 0)]
        let monitor = PerformanceMonitor(sampler: FakeSampler([raw(0, cores: a, topology: topo), raw(1, cores: b, topology: topo)]))
        _ = await monitor.refresh()
        let s = await monitor.refresh()
        #expect(s.cpu?.total == 75); #expect(s.cpu?.efficiency == 50); #expect(s.cpu?.performance == 100)
    }

    @Test func processCPUFromCPUTime() async {
        let start = t0.addingTimeInterval(-100)
        func p(_ cpu: UInt64, _ energy: UInt64) -> [OwnProcess] {
            [OwnProcess(pid: 7, name: "x", startTime: start, cpuTimeNs: cpu, energyNj: energy)]
        }
        let monitor = PerformanceMonitor(sampler: FakeSampler([
            raw(0, processes: p(0, 0)), raw(1, processes: p(second / 2, 2 * second))]))
        _ = await monitor.refresh()
        let s = await monitor.refresh()
        #expect(s.processCPU[7] == 50)
        #expect(s.processEnergy[7] == 2)
    }

    @Test func vanishedProcessHasNoCPU() async {
        let start = t0.addingTimeInterval(-100)
        let monitor = PerformanceMonitor(sampler: FakeSampler([
            raw(0, processes: [OwnProcess(pid: 1, name: "gone", startTime: start),
                               OwnProcess(pid: 2, name: "reused", startTime: start)]),
            raw(1, processes: [OwnProcess(pid: 2, name: "reused", startTime: start.addingTimeInterval(50), cpuTimeNs: second)])]))
        _ = await monitor.refresh()
        let s = await monitor.refresh()
        #expect(s.processCPU[1] == nil); #expect(s.processCPU[2] == nil)
    }

    @Test func countersGoingBackwardsGiveNoRate() async {
        let monitor = PerformanceMonitor(sampler: FakeSampler([
            raw(0, disk: IOCounters(read: 10, written: 10), network: IOCounters(read: 1, written: 1)),
            raw(1, disk: IOCounters(read: 5, written: 20)),
            raw(1, disk: IOCounters(read: 6, written: 21), network: IOCounters(read: 2, written: 2))]))
        _ = await monitor.refresh()
        let back = await monitor.refresh()
        #expect(back.disk == nil); #expect(back.network == nil)
        let sameUptime = await monitor.refresh()   // Δt = 0 ⇒ nil aunque haya contadores
        #expect(sameUptime.disk == nil)
    }

    @Test func ratesPerSecond() async {
        let monitor = PerformanceMonitor(sampler: FakeSampler([
            raw(0, disk: IOCounters(read: 0, written: 0)),
            raw(2, disk: IOCounters(read: 2 * 1_048_576, written: 4 * 1_048_576))]))
        _ = await monitor.refresh()
        let s = await monitor.refresh()
        #expect(s.disk?.readPerSecond == 1_048_576.0)
        #expect(s.disk?.writePerSecond == 2_097_152.0)
    }

    @Test func memoryDerivedValues() {
        let m = MemoryStats(total: 1000, fileCache: 100, free: 50, swapUsed: 1, swapTotal: 4)
        #expect(m.available == 150); #expect(m.availableFraction == 0.15); #expect(m.swapFraction == 0.25)
        let empty = MemoryStats()
        #expect(empty.availableFraction == 0); #expect(empty.swapFraction == nil)
    }

    @Test func zombiesNameTheirParent() async {
        let system = [SystemProcess(pid: 83479, ppid: 83371, state: "Z", name: "<defunct>"),
                      SystemProcess(pid: 83371, ppid: 1, state: "S", name: "node")]
        let monitor = PerformanceMonitor(sampler: FakeSampler([raw(system: system)]))
        let s = await monitor.refresh()
        #expect(s.zombies == [Zombie(pid: 83479, parentPID: 83371, parentName: "node")])
    }

    @Test func historyIsBounded() async {
        let monitor = PerformanceMonitor(sampler: FakeSampler((0..<8).map { raw($0) }), historyLimit: 6)
        for _ in 0..<8 { _ = await monitor.refresh() }
        let h = await monitor.history
        #expect(h.count == 6)
        #expect(h.last?.date == t0.addingTimeInterval(7))
    }
}
