import Foundation

/// Semáforo: verde, ámbar, rojo.
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

/// Datos que no salen de la muestra y solo se piden cuando hacen falta (`DiagnosisProbes`).
public struct DiagnosisExtras: Sendable, Equatable {
    public var dockerRunningContainers: Int?      // nil = no se sabe
    public var mountedDiskImages: [String]?       // nombres (último componente), nil = no se sabe
    public init(dockerRunningContainers: Int?, mountedDiskImages: [String]?) {
        self.dockerRunningContainers = dockerRunningContainers; self.mountedDiskImages = mountedDiskImages
    }
    public static let unknown = DiagnosisExtras(dockerRunningContainers: nil, mountedDiskImages: nil)
}

/// Familias de procesos del sistema que se vigilan con `ps` (R2).
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

/// Diagnóstico por reglas fijas (§2.9): ningún hallazgo actúa sobre nada.
public enum PerformanceDiagnosis {
    public static let familyThreshold = 25.0, swapThreshold = 0.5, availableThreshold = 0.15
    public static let dockerVMBytes: Int64 = 2 << 30, runawayAge: TimeInterval = 12 * 3600, runawayCPU = 25.0, busyCPU = 85.0

    static let dockerBundleID = "com.docker.docker"
    static let virtualMachineProcess = "com.apple.Virtualization.VirtualMachine"
    /// Otras apps que también usan Virtualization.framework: con alguna abierta no se atribuye la VM a Docker.
    static let otherVirtualizationBundleIDs: Set<String> = [
        "com.utmapp.UTM", "com.parallels.desktop.console", "com.vmware.fusion", "dev.kdrag0n.MacVirt",
    ]

    private static let order = [
        "thermal-critical", "thermal-throttling", "memory", "docker-vm", "runaway", "disk-images",
        "family-syspolicyd", "family-coreSimulator", "family-spotlight", "family-windowServer", "cpu-busy",
    ]

    /// % de CPU (de `ps`) sumado por familia; las familias sin procesos no aparecen.
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

    /// R9: memoria del grupo Docker Desktop + VMs de Virtualization.framework; nil sin grupo Docker.
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

    /// `true` si la familia supera el umbral en las dos últimas muestras (ambas con lista de `ps`).
    static func sustained(_ family: ProcessFamily, _ history: [PerformanceSnapshot]) -> Bool {
        guard history.count >= 2 else { return false }
        return history.suffix(2).allSatisfy { snapshot in
            guard let system = snapshot.raw.system else { return false }
            return (familyCPU(system)[family] ?? 0) >= familyThreshold
        }
    }

    /// `history`: más reciente al final. Las reglas «sostenidas» exigen las dos últimas muestras.
    public static func evaluate(_ history: [PerformanceSnapshot], extras: DiagnosisExtras) -> HealthVerdict {
        guard let last = history.last else { return good }
        var findings: [Finding] = []

        // Temperatura.
        if last.thermal.level == .critical {
            findings.append(Finding(id: "thermal-critical", level: .poor,
                                    sentence: "Tu Mac está muy caliente y va mucho más lento para enfriarse."))
        } else if last.thermal.throttling {
            findings.append(Finding(id: "thermal-throttling", level: .fair,
                                    sentence: "Tu Mac se está calentando y ha bajado la velocidad."))
        }

        // Memoria.
        let memory = last.memory
        let pressured = memory.pressure == .warning || memory.pressure == .critical
        let swapping = (memory.swapFraction ?? 0) > swapThreshold
        let scarce = memory.total > 0 && memory.availableFraction < availableThreshold
        if pressured || swapping || scarce {
            findings.append(Finding(id: "memory", level: memory.pressure == .critical ? .poor : .fair,
                                    sentence: memorySentence(last)))
        }

        // Docker Desktop sin contenedores.
        if let vm = dockerVMMemory(last), vm > dockerVMBytes, extras.dockerRunningContainers == 0 {
            findings.append(Finding(id: "docker-vm", level: .fair,
                                    sentence: "Docker Desktop retiene \(Format.bytes(vm)) sin contenedores en marcha: ciérralo si no lo usas."))
        }

        // R8: procesos propios desbocados.
        // Airy (y su airy-mcp) nunca se señala a sí misma.
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for p in last.raw.processes.sorted(by: { $0.pid < $1.pid })
        where !p.isZombie && p.pid != ownPID && !QuitPolicy.isAiry(p) {
            let age = last.date.timeIntervalSince(p.startTime)
            guard age >= runawayAge else { continue }
            let lifetimeCPU = Double(p.cpuTimeNs) / 1_000_000_000 / age * 100
            guard lifetimeCPU >= runawayCPU else { continue }
            findings.append(Finding(id: "runaway:\(p.pid)", level: .fair,
                                    sentence: "\(AppGrouper.friendlyName(p, catalog: nil)) lleva \(Int(age / 3600)) h usando mucho procesador sin parar."))
        }

        // Familias del sistema (solo con lista de `ps` en las dos últimas).
        if sustained(.syspolicyd, history) {
            findings.append(Finding(id: "family-syspolicyd", level: .fair,
                                    sentence: "La comprobación de seguridad de apps (syspolicyd) está trabajando mucho."))
            if let images = extras.mountedDiskImages, !images.isEmpty {
                let names = images.prefix(3).joined(separator: ", ")
                findings.append(Finding(id: "disk-images", level: .fair,
                                        sentence: "Hay imágenes de disco montadas (\(names)) que la hacen trabajar: expúlsalas en Finder si ya no las usas."))
            }
        }
        if sustained(.windowServer, history) {
            findings.append(Finding(id: "family-windowServer", level: .fair,
                                    sentence: "La pantalla está trabajando mucho (WindowServer): suele ser por muchas ventanas, pantallas externas o efectos."))
        }
        if sustained(.spotlight, history) {
            findings.append(Finding(id: "family-spotlight", level: .fair,
                                    sentence: "Spotlight está indexando y usa mucho procesador; suele terminar solo."))
        }
        if sustained(.coreSimulator, history) {
            findings.append(Finding(id: "family-coreSimulator", level: .fair,
                                    sentence: "Los simuladores de Xcode están usando mucho procesador; ciérralos si no los usas."))
        }

        // Procesador al máximo.
        if history.count >= 2, history.suffix(2).allSatisfy({ ($0.cpu?.total ?? 0) >= busyCPU }) {
            let top = last.groups.filter { ($0.cpuPercent ?? 0) > 0 }.max { ($0.cpuPercent ?? 0) < ($1.cpuPercent ?? 0) }
            let sentence = top.map { "El procesador va al máximo: \($0.name) es lo que más lo usa." }
                ?? "El procesador va al máximo."
            findings.append(Finding(id: "cpu-busy", level: .fair, sentence: sentence))
        }

        guard !findings.isEmpty else { return good }
        findings.sort { rank($0.id) < rank($1.id) }
        let level = findings.map(\.level).max() ?? .good
        return HealthVerdict(level: level, sentence: findings[0].sentence, findings: findings)
    }

    private static let good = HealthVerdict(level: .good, sentence: "Tu Mac va bien.", findings: [])

    private static func rank(_ id: String) -> Int {
        let key = id.hasPrefix("runaway:") ? "runaway" : id
        return order.firstIndex(of: key) ?? order.count
    }

    private static func memorySentence(_ snapshot: PerformanceSnapshot) -> String {
        // Airy nunca se señala a sí misma.
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let top = snapshot.groups.filter {
            $0.memory > 0 && !$0.pids.contains(ownPID)
                && !(["airy", "airy-mcp"].contains($0.name.lowercased()) || ($0.bundlePath ?? "").hasSuffix("/Airy.app"))
        }.sorted { $0.memory > $1.memory }.prefix(2)
        let used = snapshot.memory.used
        guard !top.isEmpty, used > 0 else { return "Tu Mac va justo de memoria." }
        let share = Int((Double(top.reduce(Int64(0)) { $0 + $1.memory }) / Double(used) * 100).rounded())
        if top.count == 1 {
            return "Tu Mac va justo de memoria: \(top[top.startIndex].name) se lleva el \(share) %."
        }
        return "Tu Mac va justo de memoria: \(top[top.startIndex].name) y \(top[top.startIndex + 1].name) se llevan el \(share) %."
    }
}
