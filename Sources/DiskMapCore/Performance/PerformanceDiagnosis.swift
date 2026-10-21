import Foundation

/// Traffic light: green, amber, red.
public enum HealthLevel: String, Sendable, Codable, Comparable {
    case good, fair, poor

    private var rank: Int {
        switch self { case .good: 0; case .fair: 1; case .poor: 2 }
    }
    public static func < (lhs: HealthLevel, rhs: HealthLevel) -> Bool { lhs.rank < rhs.rank }
}

public struct Finding: Sendable, Equatable, Identifiable {
    public var id: String
    public var level: HealthLevel
    public var sentence: String
    public init(id: String, level: HealthLevel, sentence: String) {
        self.id = id; self.level = level; self.sentence = sentence
    }
}

public struct HealthVerdict: Sendable, Equatable {
    public var level: HealthLevel
    public var sentence: String
    public var findings: [Finding]
    public init(level: HealthLevel, sentence: String, findings: [Finding]) {
        self.level = level; self.sentence = sentence; self.findings = findings
    }
}

/// Data that does not come from the sample and is only requested when needed (`DiagnosisProbes`).
public struct DiagnosisExtras: Sendable, Equatable {
    public var dockerRunningContainers: Int?      // nil = unknown
    public var mountedDiskImages: [String]?       // names (last component), nil = unknown
    public init(dockerRunningContainers: Int?, mountedDiskImages: [String]?) {
        self.dockerRunningContainers = dockerRunningContainers; self.mountedDiskImages = mountedDiskImages
    }
    public static let unknown = DiagnosisExtras(dockerRunningContainers: nil, mountedDiskImages: nil)
}

/// Families of system processes watched with `ps` (R2).
public enum ProcessFamily: String, CaseIterable, Sendable {
    case syspolicyd, windowServer, spotlight, coreSimulator

    public var processNames: [String] {
        switch self {
        case .syspolicyd: ["syspolicyd"]
        case .windowServer: ["WindowServer"]
        case .spotlight: ["mds", "mds_stores", "mdworker", "mdworker_shared", "mdbulkimport"]
        case .coreSimulator: ["diskimagesiod", "simdiskimaged", "com.apple.CoreSimulator.CoreSimulatorService", "launchd_sim"]
        }
    }
}

/// Diagnosis by fixed rules (§2.9): no finding acts on anything.
public enum PerformanceDiagnosis {
    public static let familyThreshold = 25.0, swapThreshold = 0.5, availableThreshold = 0.15
    public static let dockerVMBytes: Int64 = 2 << 30, runawayAge: TimeInterval = 12 * 3600, runawayCPU = 25.0, busyCPU = 85.0

    static let dockerBundleID = "com.docker.docker"
    static let virtualMachineProcess = "com.apple.Virtualization.VirtualMachine"
    /// Other apps that also use Virtualization.framework: with any of them open, the VM is not attributed to Docker.
    static let otherVirtualizationBundleIDs: Set<String> = [
        "com.utmapp.UTM", "com.parallels.desktop.console", "com.vmware.fusion", "dev.kdrag0n.MacVirt",
    ]

    private static let order = [
        "thermal-critical", "thermal-throttling", "memory", "docker-vm", "runaway", "disk-images",
        "family-syspolicyd", "family-coreSimulator", "family-spotlight", "family-windowServer", "cpu-busy",
    ]

    /// CPU % (from `ps`) summed per family; families without processes do not appear.
    public static func familyCPU(_ system: [SystemProcess]) -> [ProcessFamily: Double] {
        var result: [ProcessFamily: Double] = [:]
        for family in ProcessFamily.allCases {
            let names = Set(family.processNames)
            let members = system.filter { names.contains($0.name) }
            guard !members.isEmpty else { continue }
            result[family] = members.reduce(0) { $0 + $1.cpuPercent }
        }
        return result
    }

    /// R9: memory of the Docker Desktop group + Virtualization.framework VMs; nil without a Docker group.
    public static func dockerVMMemory(_ snapshot: PerformanceSnapshot) -> Int64? {
        let docker = snapshot.groups.filter { $0.bundleID == dockerBundleID }
        guard !docker.isEmpty else { return nil }
        let counted = Set(docker.flatMap(\.pids))
        var total = docker.reduce(Int64(0)) { $0 + $1.memory }
        let openBundles = Set(snapshot.raw.apps.compactMap(\.bundleID) + snapshot.groups.compactMap(\.bundleID))
        if openBundles.isDisjoint(with: otherVirtualizationBundleIDs) {
            total += snapshot.raw.processes
                .filter { $0.name == virtualMachineProcess && !$0.isZombie && !counted.contains($0.pid) }
                .reduce(Int64(0)) { $0 + $1.footprint }
        }
        return total
    }

    /// `true` if the family exceeds the threshold in the last two samples (both with a `ps` list).
    static func sustained(_ family: ProcessFamily, _ history: [PerformanceSnapshot]) -> Bool {
        guard history.count >= 2 else { return false }
        return history.suffix(2).allSatisfy { snapshot in
            guard let system = snapshot.raw.system else { return false }
            return (familyCPU(system)[family] ?? 0) >= familyThreshold
        }
    }

    /// `history`: most recent at the end. The "sustained" rules require the last two samples.
    public static func evaluate(_ history: [PerformanceSnapshot], extras: DiagnosisExtras) -> HealthVerdict {
        guard let last = history.last else { return good }
        var findings: [Finding] = []

        // Temperature.
        if last.thermal.level == .critical {
            findings.append(Finding(id: "thermal-critical", level: .poor,
                                    sentence: String(localized: "Your Mac is very hot and is running much slower to cool down.", bundle: .airyCore)))
        } else if last.thermal.throttling {
            findings.append(Finding(id: "thermal-throttling", level: .fair,
                                    sentence: String(localized: "Your Mac is heating up and has slowed down.", bundle: .airyCore)))
        }

        // Memory.
        let memory = last.memory
        let pressured = memory.pressure == .warning || memory.pressure == .critical
        let swapping = (memory.swapFraction ?? 0) > swapThreshold
        let scarce = memory.total > 0 && memory.availableFraction < availableThreshold
        if pressured || swapping || scarce {
            findings.append(Finding(id: "memory", level: memory.pressure == .critical ? .poor : .fair,
                                    sentence: memorySentence(last)))
        }

        // Docker Desktop without containers.
        if let vm = dockerVMMemory(last), vm > dockerVMBytes, extras.dockerRunningContainers == 0 {
            findings.append(Finding(id: "docker-vm", level: .fair,
                                    sentence: String(localized: "Docker Desktop is holding \(Format.bytes(vm)) with no containers running: quit it if you are not using it.", bundle: .airyCore)))
        }

        // R8: runaway user processes.
        // Airy (and its airy-mcp) never points at itself.
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for p in last.raw.processes.sorted(by: { $0.pid < $1.pid })
        where !p.isZombie && p.pid != ownPID && !QuitPolicy.isAiry(p) {
            let age = last.date.timeIntervalSince(p.startTime)
            guard age >= runawayAge else { continue }
            let lifetimeCPU = Double(p.cpuTimeNs) / 1_000_000_000 / age * 100
            guard lifetimeCPU >= runawayCPU else { continue }
            findings.append(Finding(id: "runaway:\(p.pid)", level: .fair,
                                    sentence: String(localized: "\(AppGrouper.friendlyName(p, catalog: nil)) has been using a lot of CPU nonstop for \(Int(age / 3600)) h.", bundle: .airyCore)))
        }

        // System families (only with a `ps` list in the last two).
        if sustained(.syspolicyd, history) {
            findings.append(Finding(id: "family-syspolicyd", level: .fair,
                                    sentence: String(localized: "The app security check (syspolicyd) is working hard.", bundle: .airyCore)))
            if let images = extras.mountedDiskImages, !images.isEmpty {
                let names = images.prefix(3).joined(separator: ", ")
                findings.append(Finding(id: "disk-images", level: .fair,
                                        sentence: String(localized: "There are mounted disk images (\(names)) making it work: eject them in Finder if you no longer use them.", bundle: .airyCore)))
            }
        }
        if sustained(.windowServer, history) {
            findings.append(Finding(id: "family-windowServer", level: .fair,
                                    sentence: String(localized: "The display is working hard (WindowServer): usually because of many windows, external displays or effects.", bundle: .airyCore)))
        }
        if sustained(.spotlight, history) {
            findings.append(Finding(id: "family-spotlight", level: .fair,
                                    sentence: String(localized: "Spotlight is indexing and using a lot of CPU; it usually finishes by itself.", bundle: .airyCore)))
        }
        if sustained(.coreSimulator, history) {
            findings.append(Finding(id: "family-coreSimulator", level: .fair,
                                    sentence: String(localized: "The Xcode simulators are using a lot of CPU; quit them if you are not using them.", bundle: .airyCore)))
        }

        // CPU at full load.
        if history.count >= 2, history.suffix(2).allSatisfy({ ($0.cpu?.total ?? 0) >= busyCPU }) {
            // Airy (and its airy-mcp, which measures itself) never points at itself.
            let top = last.groups.filter { ($0.cpuPercent ?? 0) > 0 && !QuitPolicy.isAiry($0) }.max { ($0.cpuPercent ?? 0) < ($1.cpuPercent ?? 0) }
            let sentence = top.map { String(localized: "The CPU is at full load: \($0.name) is using it the most.", bundle: .airyCore) }
                ?? String(localized: "The CPU is at full load.", bundle: .airyCore)
            findings.append(Finding(id: "cpu-busy", level: .fair, sentence: sentence))
        }

        guard !findings.isEmpty else { return good }
        findings.sort { rank($0.id) < rank($1.id) }
        let level = findings.map(\.level).max() ?? .good
        return HealthVerdict(level: level, sentence: findings[0].sentence, findings: findings)
    }

    private static var good: HealthVerdict { HealthVerdict(level: .good, sentence: String(localized: "Your Mac is doing fine.", bundle: .airyCore), findings: []) }

    private static func rank(_ id: String) -> Int {
        let key = id.hasPrefix("runaway:") ? "runaway" : id
        return order.firstIndex(of: key) ?? order.count
    }

    private static func memorySentence(_ snapshot: PerformanceSnapshot) -> String {
        // Airy never points at itself.
        let top = snapshot.groups.filter { $0.memory > 0 && !QuitPolicy.isAiry($0) }.sorted { $0.memory > $1.memory }.prefix(2)
        let used = snapshot.memory.used
        guard !top.isEmpty, used > 0 else { return String(localized: "Your Mac is short on memory.", bundle: .airyCore) }
        let share = Int((Double(top.reduce(Int64(0)) { $0 + $1.memory }) / Double(used) * 100).rounded())
        if top.count == 1 {
            return String(localized: "Your Mac is short on memory: \(top[top.startIndex].name) takes \(share)%.", bundle: .airyCore)
        }
        return String(localized: "Your Mac is short on memory: \(top[top.startIndex].name) and \(top[top.startIndex + 1].name) take \(share)%.", bundle: .airyCore)
    }
}
