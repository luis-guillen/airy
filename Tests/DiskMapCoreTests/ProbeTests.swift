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
}
