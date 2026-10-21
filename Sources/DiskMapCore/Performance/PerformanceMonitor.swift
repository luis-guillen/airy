import Foundation

/// Measures only when asked (`refresh()`); it never has a timer of its own.
public actor PerformanceMonitor {
    private let sampler: any PerformanceSampling
    private let historyLimit: Int
    private let grouper: @Sendable (RawSample, [Int32: Double], [Int32: Double]) -> [AppGroup]
    private var previous: RawSample?
    private var snapshots: [PerformanceSnapshot] = []
    // F4: cache of the diagnosis probes (30 s per datum, measured with the sample's date).
    private var extras = DiagnosisExtras.unknown
    private var extrasDates: (docker: Date?, images: Date?) = (nil, nil)
    public static let extrasCacheSeconds: TimeInterval = 30

    public init(sampler: any PerformanceSampling, historyLimit: Int = 6,
                grouper: @escaping @Sendable (RawSample, [Int32: Double], [Int32: Double]) -> [AppGroup] = { _, _, _ in [] }) {
        self.sampler = sampler
        self.historyLimit = max(1, historyLimit)
        self.grouper = grouper
    }

    public var history: [PerformanceSnapshot] { snapshots }

    /// Forgets the previous sample and the history (M1: on return, "sustained" does not mix an old sample with a new one).
    public func reset() {
        previous = nil
        snapshots = []
    }

    /// The last snapshot if it was taken at `since` or later; otherwise, measures now (I2: a proposal is never
    /// resolved against a snapshot from a previous visit).
    public func snapshot(since: Date) async -> PerformanceSnapshot {
        if let last = snapshots.last, last.date >= since { return last }
        return await refresh()
    }

    /// One sample, with deltas against the previous one; it is added to the history.
    public func refresh() async -> PerformanceSnapshot {
        let raw = await sampler.sample()
        let prev = previous
        previous = raw

        var cpu: CPUUsage?
        var processCPU: [Int32: Double] = [:]
        var processEnergy: [Int32: Double] = [:]
        var disk: Rate?
        var network: Rate?

        if let prev {
            let dtNs = raw.uptimeNs > prev.uptimeNs ? raw.uptimeNs - prev.uptimeNs : 0
            cpu = Self.cpuUsage(prev: prev, now: raw)
            if dtNs > 0 {
                (processCPU, processEnergy) = Self.processDeltas(prev: prev, now: raw, dtNs: dtNs)
                let seconds = Double(dtNs) / 1_000_000_000
                disk = Self.rate(prev.disk, raw.disk, seconds: seconds)
                network = Self.rate(prev.network, raw.network, seconds: seconds)
            }
        }

        let snapshot = PerformanceSnapshot(
            date: raw.date, memory: raw.memory, thermal: raw.thermal, cpu: cpu,
            processCPU: processCPU, processEnergy: processEnergy, raw: raw,
            groups: grouper(raw, processCPU, processEnergy),
            battery: raw.battery, disk: disk, network: network,
            uptime: raw.bootTime.map { raw.date.timeIntervalSince($0) },
            zombies: Self.zombies(in: raw))
        snapshots.append(snapshot)
        if snapshots.count > historyLimit { snapshots.removeFirst(snapshots.count - historyLimit) }
        return snapshot
    }

    // MARK: - Diagnosis

    /// Calls docker only if dockerVMMemory > dockerVMBytes and hdiutil only if syspolicyd ≥ threshold in the last two; 30 s cache.
    public func verdict(probes: DiagnosisProbes?) async -> HealthVerdict {
        let history = snapshots
        guard let last = history.last else { return PerformanceDiagnosis.evaluate([], extras: .unknown) }
        let now = last.date
        func fresh(_ date: Date?) -> Bool {
            guard let date else { return false }
            let age = now.timeIntervalSince(date)
            return age >= 0 && age < Self.extrasCacheSeconds
        }

        var current = DiagnosisExtras.unknown
        if let vm = PerformanceDiagnosis.dockerVMMemory(last), vm > PerformanceDiagnosis.dockerVMBytes {
            if !fresh(extrasDates.docker), let probes {
                extras.dockerRunningContainers = await probes.dockerRunningContainers()
                extrasDates.docker = now
            }
            if fresh(extrasDates.docker) { current.dockerRunningContainers = extras.dockerRunningContainers }
        }
        if PerformanceDiagnosis.sustained(.syspolicyd, history) {
            if !fresh(extrasDates.images), let probes {
                extras.mountedDiskImages = await probes.mountedDiskImages()
                extrasDates.images = now
            }
            if fresh(extrasDates.images) { current.mountedDiskImages = extras.mountedDiskImages }
        }
        return PerformanceDiagnosis.evaluate(history, extras: current)
    }

    // MARK: - Deltas

    private static func cpuUsage(prev: RawSample, now: RawSample) -> CPUUsage? {
        guard !now.cores.isEmpty, now.cores.count == prev.cores.count else { return nil }
        func diff(_ a: UInt64, _ b: UInt64) -> UInt64 { b >= a ? b - a : 0 }
        var busy: [UInt64] = [], all: [UInt64] = []
        for (p, n) in zip(prev.cores, now.cores) {
            let b = diff(p.user, n.user) + diff(p.system, n.system) + diff(p.nice, n.nice)
            busy.append(b); all.append(b + diff(p.idle, n.idle))
        }
        func pct(_ range: Range<Int>) -> Double? {
            let total = all[range].reduce(0, +)
            guard total > 0 else { return nil }
            return Double(busy[range].reduce(0, +)) / Double(total) * 100
        }
        guard let total = pct(0..<busy.count) else { return nil }
        var performance: Double?, efficiency: Double?
        if let topology = now.topology, topology.efficiency > 0,
           topology.efficiency + topology.performance == now.cores.count {
            // R3: host_processor_info lists the efficiency cores first.
            efficiency = pct(0..<topology.efficiency)
            performance = pct(topology.efficiency..<now.cores.count)
        } else if let topology = now.topology, topology.performance == now.cores.count {
            performance = total
        }
        return CPUUsage(total: total, performance: performance, efficiency: efficiency, topology: now.topology)
    }

    private static func processDeltas(prev: RawSample, now: RawSample, dtNs: UInt64)
        -> ([Int32: Double], [Int32: Double]) {
        let before = Dictionary(prev.processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var cpu: [Int32: Double] = [:], energy: [Int32: Double] = [:]
        for p in now.processes {
            guard let old = before[p.pid], old.startTime == p.startTime else { continue }
            if p.cpuTimeNs >= old.cpuTimeNs {
                cpu[p.pid] = Double(p.cpuTimeNs - old.cpuTimeNs) / Double(dtNs) * 100
            }
            if p.energyNj >= old.energyNj {
                energy[p.pid] = Double(p.energyNj - old.energyNj) / Double(dtNs)   // nJ/ns = W
            }
        }
        return (cpu, energy)
    }

    private static func rate(_ a: IOCounters?, _ b: IOCounters?, seconds: Double) -> Rate? {
        guard let a, let b, seconds > 0, b.read >= a.read, b.written >= a.written else { return nil }
        return Rate(readPerSecond: Double(b.read - a.read) / seconds,
                    writePerSecond: Double(b.written - a.written) / seconds)
    }

    private static func zombies(in raw: RawSample) -> [Zombie] {
        if let system = raw.system {
            let names = Dictionary(system.map { ($0.pid, $0.name) }, uniquingKeysWith: { a, _ in a })
            return system.filter(\.isZombie).map {
                Zombie(pid: $0.pid, parentPID: $0.ppid, parentName: names[$0.ppid])
            }
        }
        let names = Dictionary(raw.processes.map { ($0.pid, $0.name) }, uniquingKeysWith: { a, _ in a })
        return raw.processes.filter(\.isZombie).map {
            Zombie(pid: $0.pid, parentPID: $0.ppid, parentName: names[$0.ppid])
        }
    }
}
