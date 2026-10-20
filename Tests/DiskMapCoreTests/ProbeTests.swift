import Foundation
import Testing
@testable import DiskMapCore

@Suite struct ProbeTests {
    @Test func memoryStatsFollowActivityMonitor() {
        var vm = vm_statistics64()
        vm.internal_page_count = 1000
        vm.purgeable_count = 100
        vm.wire_count = 200
        vm.compressor_page_count = 300
        vm.external_page_count = 400
        let page: Int64 = 16384
        let s = MemoryProbe.stats(vm: vm, pageSize: page, total: 4000 * page, swap: nil, pressureLevel: 2)
        #expect(s.appMemory == 900 * page)
        #expect(s.wired == 200 * page)
        #expect(s.compressed == 300 * page)
        #expect(s.used == 1400 * page)
        #expect(s.fileCache == 500 * page)
        #expect(s.free == 2100 * page)
        #expect(s.available == 2600 * page)
        #expect(s.pressure == .warning)
        #expect(s.swapUsed == 0 && s.swapTotal == 0)
    }

    @Test func pressureLevels() {
        #expect(MemoryProbe.pressure(level: 1) == .normal)
        #expect(MemoryProbe.pressure(level: 2) == .warning)
        #expect(MemoryProbe.pressure(level: 4) == .critical)
        #expect(MemoryProbe.pressure(level: 7) == nil)
    }

    @Test func thermalMappingAndThrottling() {
        #expect(ThermalProbe.reading(state: .serious, speedLimit: nil).throttling)
        #expect(ThermalProbe.reading(state: .nominal, speedLimit: 80).throttling)
        #expect(!ThermalProbe.reading(state: .fair, speedLimit: 100).throttling)
        #expect(ThermalProbe.reading(state: .fair, speedLimit: 100).level == .fair)
        #expect(ThermalLevel.fair.label == "Caliente")
    }

    @Test func liveMemoryIsPlausible() throws {
        let s = try #require(MemoryProbe.read())
        #expect(s.total > 0)
        #expect(s.total == Int64(ProcessInfo.processInfo.physicalMemory))
        #expect(s.used + s.fileCache + s.free == s.total)
        #expect(s.swapUsed <= s.swapTotal)
    }

    @Test func liveTicksMatchCoreCount() throws {
        let ticks = try #require(CPUProbe.ticks())
        #expect(ticks.count == ProcessInfo.processInfo.activeProcessorCount)
    }

    @Test func liveTopologySumsToCores() {
        if let t = CPUProbe.topology() {
            #expect(t.performance + t.efficiency == ProcessInfo.processInfo.activeProcessorCount)
        }
    }

    @Test func liveBootTimeInThePast() throws {
        let boot = try #require(CPUProbe.bootTime())
        #expect(boot < Date())
    }

    // MARK: - Procesos

    @Test func parsesSpanishDecimalsAndSpaces() {
        let out = """
          603    1    88  41,4 117504 Ss   WindowServer
        83479 83371  501   0,0      0 Z+   <defunct>
          900    1   501  12.5   2048 S    Google Chrome Helper (Renderer)
        basura
        """
        let p = ProcessProbe.parsePS(out)
        #expect(p.count == 3)
        #expect(p[0].cpuPercent == 41.4 && p[0].rssBytes == 117504 * 1024 && p[0].uid == 88)
        #expect(p[1].isZombie && p[1].ppid == 83371)
        #expect(p[2].name == "Google Chrome Helper (Renderer)" && p[2].cpuPercent == 12.5)
    }

    @Test func psFailureMeansNoSystemList() async {
        let key = (["/bin/ps"] + ProcessProbe.psArguments).joined(separator: " ")
        let failed = FakeRunner(outputs: [key: CommandOutput(status: 1, stdout: "  1 0 0 0,0 10 Ss launchd\n", stderr: "")])
        #expect(await ProcessProbe.systemProcesses(runner: failed) == nil)
        let empty = FakeRunner(outputs: [key: CommandOutput(status: 0, stdout: "  \n", stderr: "")])
        #expect(await ProcessProbe.systemProcesses(runner: empty) == nil)
        let ok = FakeRunner(outputs: [key: CommandOutput(status: 0, stdout: "  1 0 0 0,0 10 Ss launchd\n", stderr: "")])
        #expect(await ProcessProbe.systemProcesses(runner: ok)?.first?.name == "launchd")
    }

    @Test func psUsesFixedArguments() async {
        let runner = FakeRunner()
        _ = await ProcessProbe.systemProcesses(runner: runner)
        #expect(runner.calls.count == 1)
        #expect(runner.calls.first?.executable == "/bin/ps")
        #expect(runner.calls.first?.arguments == ProcessProbe.psArguments)
        #expect(runner.calls.first?.timeout == 3)
    }

    @Test func ownProcessesIncludeSelfWithFootprint() {
        let me = ProcessProbe.ownProcesses().first { $0.pid == ProcessInfo.processInfo.processIdentifier }
        #expect(me != nil && me!.footprint > 0 && me!.uid == getuid())
    }

    @Test func ownProcessesNeverIncludeOtherUsers() {
        let all = ProcessProbe.ownProcesses()
        #expect(!all.isEmpty)
        #expect(all.allSatisfy { $0.uid == getuid() })
    }

    @Test func ownCPUTimeAdvances() {
        let pid = ProcessInfo.processInfo.processIdentifier
        func mine() -> UInt64? { ProcessProbe.ownProcesses().first { $0.pid == pid }?.cpuTimeNs }
        guard let before = mine() else { Issue.record("no se ve a sí mismo"); return }
        let deadline = Date().addingTimeInterval(2)
        var sink = 0.0
        var after = before
        while Date() < deadline, after < before + 100_000_000 {
            for i in 0..<200_000 { sink += Double(i).squareRoot() }
            after = mine() ?? after
        }
        #expect(sink > 0)
        #expect(after >= before + 100_000_000)
    }

    @Test func activationPolicyMapping() {
        #expect(ProcessProbe.policy(.regular) == .regular)
        #expect(ProcessProbe.policy(.accessory) == .accessory)
        #expect(ProcessProbe.policy(.prohibited) == .prohibited)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CI"] == nil)) func runningAppsHaveNamesAndPolicies() {
        let apps = ProcessProbe.runningApps()
        // Sin sesión gráfica la lista puede venir vacía; con sesión, todas traen nombre.
        #expect(apps.allSatisfy { !$0.name.isEmpty && $0.pid > 0 })
    }

    @Test func batteryHealthClamped() {
        #expect(BatteryProbe.health(rawMax: 4200, design: 5000) == 84)
        #expect(BatteryProbe.health(rawMax: 5200, design: 5000) == 100)
        #expect(BatteryProbe.health(rawMax: nil, design: 5000) == nil)
        #expect(BatteryProbe.health(rawMax: 4200, design: 0) == nil)
    }

    @Test func tunnelsAndLoopbackNotCounted() {
        #expect(!IOProbe.countsInterface(name: "lo0", isLoopback: true))
        #expect(!IOProbe.countsInterface(name: "utun3", isLoopback: false))
        #expect(!IOProbe.countsInterface(name: "ipsec0", isLoopback: false))
        #expect(IOProbe.countsInterface(name: "en0", isLoopback: false))
    }

    @Test func liveDiskAndNetworkReadable() {
        #expect(IOProbe.disk() != nil)
        #expect(IOProbe.network() != nil)
    }

    @Test func liveSamplerFillsEverything() async {
        let s = await LiveSampler().sample()
        #expect(s.memory.total > 0)
        #expect(!s.cores.isEmpty)
        #expect(s.processes.contains { $0.pid == getpid() })
        #expect(s.system != nil)
        #expect(s.uptimeNs > 0)
    }

    @Test func liveSamplerIsQuick() async {
        let start = ContinuousClock.now
        _ = await LiveSampler().sample()
        #expect(ContinuousClock.now - start < .seconds(3))   // F7
    }
}
