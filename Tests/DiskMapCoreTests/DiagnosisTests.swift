import Foundation
import Testing
@testable import DiskMapCore

private let t0 = Date(timeIntervalSince1970: 2_000_000)
private let gib: Int64 = 1 << 30

private func group(_ name: String, memory: Int64 = 0, cpu: Double? = nil, bundleID: String? = nil,
                   pids: [Int32] = []) -> AppGroup {
    AppGroup(id: bundleID ?? name, name: name, bundleID: bundleID, kind: .app, uid: 501,
             leadPID: pids.first ?? 1, leadStart: t0, pids: pids, processNames: [name], memory: memory, cpuPercent: cpu)
}

private func snap(_ n: Double = 0, memory: MemoryStats = MemoryStats(total: 16 * gib, used: 8 * gib, free: 8 * gib),
                  thermal: ThermalReading = ThermalReading(), cpu: Double? = nil,
                  system: [SystemProcess]? = [], processes: [OwnProcess] = [], apps: [RunningAppInfo] = [],
                  groups: [AppGroup] = []) -> PerformanceSnapshot {
    let date = t0.addingTimeInterval(n)
    let raw = RawSample(date: date, uptimeNs: UInt64(n * 1e9), memory: memory, thermal: thermal,
                        processes: processes, system: system, apps: apps)
    return PerformanceSnapshot(date: date, memory: memory, thermal: thermal, cpu: cpu.map { CPUUsage(total: $0) },
                               raw: raw, groups: groups)
}

private func ps(_ name: String, _ cpu: Double, pid: Int32 = 100) -> SystemProcess {
    SystemProcess(pid: pid, cpuPercent: cpu, name: name)
}

private func ids(_ v: HealthVerdict) -> [String] { v.findings.map(\.id) }

@Suite struct DiagnosisTests {
    @Test func goodWhenNothingFires() {
        let v = PerformanceDiagnosis.evaluate([snap(0), snap(1.5)], extras: .unknown)
        #expect(v.level == .good)
        #expect(v.sentence == "Tu Mac va bien.")
        #expect(v.findings.isEmpty)
        #expect(PerformanceDiagnosis.evaluate([], extras: .unknown).sentence == "Tu Mac va bien.")
    }

    @Test func familyNeedsTwoSustainedSamples() {
        let onlyLast = PerformanceDiagnosis.evaluate(
            [snap(0, system: [ps("syspolicyd", 5)]), snap(1.5, system: [ps("syspolicyd", 30)])], extras: .unknown)
        #expect(!ids(onlyLast).contains("family-syspolicyd"))
        #expect(!ids(PerformanceDiagnosis.evaluate([snap(0, system: [ps("syspolicyd", 30)])], extras: .unknown))
            .contains("family-syspolicyd"))

        let both = PerformanceDiagnosis.evaluate(
            [snap(0, system: [ps("syspolicyd", 30)]), snap(1.5, system: [ps("syspolicyd", 26)])], extras: .unknown)
        #expect(ids(both) == ["family-syspolicyd"])
        #expect(both.level == .fair)
        #expect(both.sentence == "La comprobación de seguridad de apps (syspolicyd) está trabajando mucho.")

        let below = PerformanceDiagnosis.evaluate(
            [snap(0, system: [ps("syspolicyd", 30)]), snap(1.5, system: [ps("syspolicyd", 24.9)])], extras: .unknown)
        #expect(below.findings.isEmpty)
    }

    @Test func spotlightFamilySumsWorkers() {
        let system = [ps("mds_stores", 15, pid: 1), ps("mdworker_shared", 12, pid: 2), ps("Finder", 50, pid: 3)]
        #expect(PerformanceDiagnosis.familyCPU(system)[.spotlight] == 27)
        #expect(PerformanceDiagnosis.familyCPU(system)[.windowServer] == nil)
        let v = PerformanceDiagnosis.evaluate([snap(0, system: system), snap(1.5, system: system)], extras: .unknown)
        #expect(ids(v) == ["family-spotlight"])
        #expect(v.sentence == "Spotlight está indexando y usa mucho procesador; suele terminar solo.")
    }

    @Test func swapAndAvailableThresholds() {
        func memory(_ m: MemoryStats) -> [String] { ids(PerformanceDiagnosis.evaluate([snap(0, memory: m)], extras: .unknown)) }
        let total = 100 * gib
        #expect(memory(MemoryStats(total: total, used: 50 * gib, free: 50 * gib, swapUsed: 51, swapTotal: 100)) == ["memory"])
        #expect(memory(MemoryStats(total: total, used: 50 * gib, free: 50 * gib, swapUsed: 50, swapTotal: 100)).isEmpty)
        #expect(memory(MemoryStats(total: total, used: 86 * gib, fileCache: 4 * gib, free: 10 * gib)) == ["memory"])
        #expect(memory(MemoryStats(total: total, used: 85 * gib, fileCache: 5 * gib, free: 10 * gib)).isEmpty)
        #expect(memory(MemoryStats(total: total, used: 50 * gib, free: 50 * gib, pressure: .warning)) == ["memory"])
        #expect(memory(MemoryStats(total: total, used: 50 * gib, free: 50 * gib, pressure: .normal)).isEmpty)
    }

    @Test func memorySentenceNamesTopTwo() {
        let m = MemoryStats(total: 16 * gib, used: 10 * gib, free: 6 * gib, pressure: .warning)
        let groups = [group("Safari", memory: 1 * gib), group("Google Chrome", memory: 4 * gib),
                      group("Docker Desktop", memory: 2 * gib)]
        let v = PerformanceDiagnosis.evaluate([snap(0, memory: m, groups: groups)], extras: .unknown)
        #expect(v.sentence == "Tu Mac va justo de memoria: Google Chrome y Docker Desktop se llevan el 60 %.")
        #expect(v.level == .fair)

        let one = PerformanceDiagnosis.evaluate([snap(0, memory: m, groups: [group("Xcode", memory: 3 * gib)])], extras: .unknown)
        #expect(one.sentence == "Tu Mac va justo de memoria: Xcode se lleva el 30 %.")
        let none = PerformanceDiagnosis.evaluate([snap(0, memory: m)], extras: .unknown)
        #expect(none.sentence == "Tu Mac va justo de memoria.")
    }

    @Test func criticalPressureIsRed() {
        let m = MemoryStats(total: 16 * gib, used: 10 * gib, free: 6 * gib, pressure: .critical)
        let v = PerformanceDiagnosis.evaluate([snap(0, memory: m)], extras: .unknown)
        #expect(ids(v) == ["memory"])
        #expect(v.level == .poor)
    }

    @Test func dockerVMOnlyWithZeroContainers() {
        let vm = OwnProcess(pid: 77, name: "com.apple.Virtualization.VirtualMachine", footprint: 2 * gib)
        let docker = group("Docker Desktop", memory: 1 * gib, bundleID: "com.docker.docker", pids: [10])
        let big = snap(0, processes: [vm], groups: [docker])
        #expect(PerformanceDiagnosis.dockerVMMemory(big) == 3 * gib)
        #expect(PerformanceDiagnosis.dockerVMMemory(snap(0, processes: [vm])) == nil)

        let fired = PerformanceDiagnosis.evaluate([big], extras: DiagnosisExtras(dockerRunningContainers: 0, mountedDiskImages: nil))
        #expect(ids(fired) == ["docker-vm"])
        #expect(fired.sentence == "Docker Desktop retiene \(Format.bytes(3 * gib)) sin contenedores en marcha: ciérralo si no lo usas.")
        #expect(PerformanceDiagnosis.evaluate([big], extras: .unknown).findings.isEmpty)
        #expect(PerformanceDiagnosis.evaluate([big], extras: DiagnosisExtras(dockerRunningContainers: 2, mountedDiskImages: nil))
            .findings.isEmpty)

        let small = snap(0, groups: [group("Docker Desktop", memory: 1 * gib, bundleID: "com.docker.docker")])
        #expect(PerformanceDiagnosis.evaluate([small], extras: DiagnosisExtras(dockerRunningContainers: 0, mountedDiskImages: nil))
            .findings.isEmpty)

        // Con UTM abierta la VM no se atribuye a Docker.
        let utm = snap(0, processes: [vm], apps: [RunningAppInfo(pid: 88, bundleID: "com.utmapp.UTM", name: "UTM")],
                       groups: [docker])
        #expect(PerformanceDiagnosis.dockerVMMemory(utm) == 1 * gib)
    }

    @Test func runawayNeedsAgeAndLifetimeCPU() {
        func verdict(hours: Double, cpu: Double) -> HealthVerdict {
            let age = hours * 3600
            let p = OwnProcess(pid: 42, name: "node", startTime: t0.addingTimeInterval(-age),
                               cpuTimeNs: UInt64(age * cpu / 100 * 1e9))
            return PerformanceDiagnosis.evaluate([snap(0, processes: [p])], extras: .unknown)
        }
        let yes = verdict(hours: 13, cpu: 30)
        #expect(ids(yes) == ["runaway:42"])
        #expect(yes.sentence == "node lleva 13 h usando mucho procesador sin parar.")
        #expect(verdict(hours: 11, cpu: 30).findings.isEmpty)
        #expect(verdict(hours: 13, cpu: 20).findings.isEmpty)
    }

    @Test func runawayNeverPointsAtAiry() {
        let age = 13.0 * 3600
        let cpu = UInt64(age * 0.5 * 1e9)
        let own = OwnProcess(pid: ProcessInfo.processInfo.processIdentifier, name: "xctest",
                             startTime: t0.addingTimeInterval(-age), cpuTimeNs: cpu)
        let airy = OwnProcess(pid: 43, name: "Airy", executablePath: "/Applications/Airy.app/Contents/MacOS/Airy",
                              startTime: t0.addingTimeInterval(-age), cpuTimeNs: cpu)
        let mcp = OwnProcess(pid: 44, name: "airy-mcp", startTime: t0.addingTimeInterval(-age), cpuTimeNs: cpu)
        #expect(PerformanceDiagnosis.evaluate([snap(0, processes: [own, airy, mcp])], extras: .unknown).findings.isEmpty)
    }

    @Test func diskImagesOnlyWithSyspolicyd() {
        let images = DiagnosisExtras(dockerRunningContainers: nil, mountedDiskImages: ["Xcode.dmg", "a.dmg", "b.dmg", "c.dmg"])
        let quiet = PerformanceDiagnosis.evaluate([snap(0), snap(1.5)], extras: images)
        #expect(quiet.findings.isEmpty)

        let busy = [snap(0, system: [ps("syspolicyd", 40)]), snap(1.5, system: [ps("syspolicyd", 40)])]
        let v = PerformanceDiagnosis.evaluate(busy, extras: images)
        #expect(ids(v) == ["disk-images", "family-syspolicyd"])
        #expect(v.sentence == "Hay imágenes de disco montadas (Xcode.dmg, a.dmg, b.dmg) que la hacen trabajar: expúlsalas en Finder si ya no las usas.")
        let empty = PerformanceDiagnosis.evaluate(busy, extras: DiagnosisExtras(dockerRunningContainers: nil, mountedDiskImages: []))
        #expect(ids(empty) == ["family-syspolicyd"])
    }

    @Test func thermalBeatsMemoryInSentence() {
        let m = MemoryStats(total: 16 * gib, used: 10 * gib, free: 6 * gib, pressure: .critical)
        let v = PerformanceDiagnosis.evaluate([snap(0, memory: m, thermal: ThermalReading(level: .serious, throttling: true))],
                                              extras: .unknown)
        #expect(ids(v) == ["thermal-throttling", "memory"])
        #expect(v.sentence == "Tu Mac se está calentando y ha bajado la velocidad.")
        #expect(v.level == .poor)

        let critical = PerformanceDiagnosis.evaluate([snap(0, thermal: ThermalReading(level: .critical, throttling: true))],
                                                     extras: .unknown)
        #expect(ids(critical) == ["thermal-critical"])
        #expect(critical.sentence == "Tu Mac está muy caliente y va mucho más lento para enfriarse.")
        #expect(critical.level == .poor)
    }

    @Test func noSystemListSkipsFamilies() {
        let hot = [ps("syspolicyd", 90, pid: 1), ps("WindowServer", 90, pid: 2), ps("mds", 90, pid: 3), ps("launchd_sim", 90, pid: 4)]
        let all = PerformanceDiagnosis.evaluate([snap(0, system: hot), snap(1.5, system: hot)], extras: .unknown)
        #expect(Set(ids(all)) == ["family-syspolicyd", "family-windowServer", "family-spotlight", "family-coreSimulator"])
        #expect(ids(all) == ["family-syspolicyd", "family-coreSimulator", "family-spotlight", "family-windowServer"])

        let blind = PerformanceDiagnosis.evaluate([snap(0, system: hot), snap(1.5, system: nil)], extras: .unknown)
        #expect(!ids(blind).contains { $0.hasPrefix("family-") })
        #expect(blind.findings.isEmpty)
    }

    @Test func cpuBusyNamesTopGroup() {
        let groups = [group("Safari", cpu: 20), group("Xcode", cpu: 300)]
        let v = PerformanceDiagnosis.evaluate([snap(0, cpu: 90), snap(1.5, cpu: 85, groups: groups)], extras: .unknown)
        #expect(ids(v) == ["cpu-busy"])
        #expect(v.sentence == "El procesador va al máximo: Xcode es lo que más lo usa.")
        #expect(PerformanceDiagnosis.evaluate([snap(0, cpu: 50), snap(1.5, cpu: 95, groups: groups)], extras: .unknown)
            .findings.isEmpty)
    }

    /// M2: airy-mcp se mide a sí mismo; nunca se señala como lo que más usa el procesador.
    @Test func cpuBusyNeverNamesAiry() {
        let groups = [group("Safari", cpu: 20), group("Airy", cpu: 300), group("airy-mcp", cpu: 250)]
        let v = PerformanceDiagnosis.evaluate([snap(0, cpu: 90), snap(1.5, cpu: 85, groups: groups)], extras: .unknown)
        #expect(v.sentence == "El procesador va al máximo: Safari es lo que más lo usa.")
    }

    @Test func probesAreCalledOnlyWhenNeeded() async {
        // Nada lo pide: ninguna llamada.
        let idle = FakeRunner(resolved: ["docker": "/usr/local/bin/docker"])
        let quiet = PerformanceMonitor(sampler: FakeSampler([snap(0).raw, snap(1.5).raw]))
        _ = await quiet.refresh(); _ = await quiet.refresh()
        let calm = await quiet.verdict(probes: DiagnosisProbes(runner: idle))
        #expect(calm.level == .good)
        #expect(idle.calls.isEmpty); #expect(idle.resolveCalls.isEmpty)

        // Docker grande y syspolicyd sostenido: una llamada a cada sonda, reutilizada durante 30 s.
        let runner = FakeRunner(resolved: ["docker": "/usr/local/bin/docker"])
        let hot = [ps("syspolicyd", 40)]
        let samples = [0, 1.5, 20, 31.5].map { snap($0, system: hot).raw }
        let docker = group("Docker Desktop", memory: 3 * gib, bundleID: "com.docker.docker")
        let monitor = PerformanceMonitor(sampler: FakeSampler(samples), grouper: { _, _, _ in [docker] })
        _ = await monitor.refresh(); _ = await monitor.refresh()
        let first = await monitor.verdict(probes: DiagnosisProbes(runner: runner))
        #expect(ids(first).contains("docker-vm"))
        #expect(runner.calls.map(\.arguments) == [["ps", "-q"], ["info", "-plist"]])
        #expect(runner.calls.map(\.executable) == ["/usr/local/bin/docker", "/usr/bin/hdiutil"])
        #expect(runner.calls.map(\.timeout) == [3, 5])

        _ = await monitor.verdict(probes: DiagnosisProbes(runner: runner))
        _ = await monitor.refresh()                       // 20 s: aún en caché
        let cached = await monitor.verdict(probes: DiagnosisProbes(runner: runner))
        #expect(ids(cached).contains("docker-vm"))
        #expect(runner.calls.count == 2)

        _ = await monitor.refresh()                       // 31,5 s: caducada
        _ = await monitor.verdict(probes: DiagnosisProbes(runner: runner))
        #expect(runner.calls.count == 4)

        // Sin sondas no se afirma nada que dependa de ellas.
        let unprobed = PerformanceMonitor(sampler: FakeSampler(samples), grouper: { _, _, _ in [docker] })
        _ = await unprobed.refresh(); _ = await unprobed.refresh()
        #expect(ids(await unprobed.verdict(probes: nil)) == ["family-syspolicyd"])
    }

    @Test func dockerProbeParsesCountAndFailure() async {
        let docker = "/usr/local/bin/docker"
        let ok = FakeRunner(resolved: ["docker": docker],
                            outputs: ["\(docker) ps -q": CommandOutput(status: 0, stdout: "abc\ndef\n", stderr: "")])
        #expect(await DiagnosisProbes(runner: ok).dockerRunningContainers() == 2)
        let none = FakeRunner(resolved: ["docker": docker],
                              outputs: ["\(docker) ps -q": CommandOutput(status: 0, stdout: "", stderr: "")])
        #expect(await DiagnosisProbes(runner: none).dockerRunningContainers() == 0)
        let failed = FakeRunner(resolved: ["docker": docker],
                                outputs: ["\(docker) ps -q": CommandOutput(status: 1, stdout: "", stderr: "Cannot connect")])
        #expect(await DiagnosisProbes(runner: failed).dockerRunningContainers() == nil)
        let missing = FakeRunner()
        #expect(await DiagnosisProbes(runner: missing).dockerRunningContainers() == nil)
        #expect(missing.calls.isEmpty)
    }

    @Test func diskImageProbeParsesPlist() async {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>images</key><array>
        <dict><key>image-path</key><string>/Users/ana/Downloads/Xcode_26.dmg</string></dict>
        <dict><key>image-path</key><string>/System/Library/AssetsV2/x.dmg</string></dict>
        <dict><key>image-path</key><string>/Library/Apple/y.dmg</string></dict>
        <dict><key>other</key><string>z</string></dict>
        </array></dict></plist>
        """
        let runner = FakeRunner(outputs: ["/usr/bin/hdiutil info -plist": CommandOutput(status: 0, stdout: plist, stderr: "")])
        #expect(await DiagnosisProbes(runner: runner).mountedDiskImages() == ["Xcode_26.dmg"])
        let failed = FakeRunner(outputs: ["/usr/bin/hdiutil info -plist": CommandOutput(status: 1, stdout: plist, stderr: "")])
        #expect(await DiagnosisProbes(runner: failed).mountedDiskImages() == nil)
        let garbage = FakeRunner(outputs: ["/usr/bin/hdiutil info -plist": CommandOutput(status: 0, stdout: "no", stderr: "")])
        #expect(await DiagnosisProbes(runner: garbage).mountedDiskImages() == nil)
    }
}
