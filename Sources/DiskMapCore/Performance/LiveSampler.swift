import AppKit
import Foundation

/// Muestreador real: todas las sondas, con `ps` en paralelo con las demás.
public struct LiveSampler: PerformanceSampling {
    private let runner: any CommandRunning

    public init(runner: any CommandRunning = ProcessRunner()) {
        self.runner = runner
    }

    public func sample() async -> RawSample {
        async let system = ProcessProbe.systemProcesses(runner: runner)
        let date = Date()
        let uptime = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        // NSWorkspace se consulta desde el hilo principal.
        let apps = await MainActor.run { ProcessProbe.runningApps() }
        let raw = RawSample(
            date: date, uptimeNs: uptime,
            memory: MemoryProbe.read() ?? MemoryStats(),
            thermal: ThermalProbe.read(),
            cores: CPUProbe.ticks() ?? [],
            topology: CPUProbe.topology(),
            bootTime: CPUProbe.bootTime(),
            processes: ProcessProbe.ownProcesses(),
            system: nil,
            apps: apps,
            battery: BatteryProbe.read(),
            disk: IOProbe.disk(),
            network: IOProbe.network())
        var result = raw
        result.system = await system
        return result
    }
}
