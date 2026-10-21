import AppKit
import Foundation

/// Real sampler: every probe, with `ps` in parallel with the others.
public struct LiveSampler: PerformanceSampling {
    private let runner: any CommandRunning

    public init(runner: any CommandRunning = ProcessRunner()) {
        self.runner = runner
    }

    public func sample() async -> RawSample {
        async let system = ProcessProbe.systemProcesses(runner: runner)
        let date = Date()
        let uptime = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let processes = ProcessProbe.ownProcesses()
        // NSWorkspace is queried from the main thread; what it does not know, from LaunchServices on the spot (I1).
        let apps = await MainActor.run { ProcessProbe.runningApps(processes: processes) }
        let raw = RawSample(
            date: date, uptimeNs: uptime,
            memory: MemoryProbe.read() ?? MemoryStats(),
            thermal: ThermalProbe.read(),
            cores: CPUProbe.ticks() ?? [],
            topology: CPUProbe.topology(),
            bootTime: CPUProbe.bootTime(),
            processes: processes,
            system: nil,
            apps: apps,
            battery: BatteryProbe.cached(),
            disk: IOProbe.disk(),
            network: IOProbe.network())
        var result = raw
        result.system = await system
        return result
    }
}
