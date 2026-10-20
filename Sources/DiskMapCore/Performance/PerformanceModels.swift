import Foundation

public enum MemoryPressure: String, Codable, Sendable { case normal, warning, critical }   // sysctl 1 / 2 / 4

public struct MemoryStats: Sendable, Equatable {
    public var total, used, appMemory, wired, compressed, fileCache, free: Int64
    public var pressure: MemoryPressure?                  // nil = no se pudo leer
    public var swapUsed, swapTotal: Int64

    public init(total: Int64 = 0, used: Int64 = 0, appMemory: Int64 = 0, wired: Int64 = 0,
                compressed: Int64 = 0, fileCache: Int64 = 0, free: Int64 = 0,
                pressure: MemoryPressure? = nil, swapUsed: Int64 = 0, swapTotal: Int64 = 0) {
        self.total = total; self.used = used; self.appMemory = appMemory; self.wired = wired
        self.compressed = compressed; self.fileCache = fileCache; self.free = free
        self.pressure = pressure; self.swapUsed = swapUsed; self.swapTotal = swapTotal
    }

    /// Libre + caché de archivos (R4).
    public var available: Int64 { free + fileCache }
    public var availableFraction: Double { total > 0 ? Double(available) / Double(total) : 0 }
    public var swapFraction: Double? { swapTotal > 0 ? Double(swapUsed) / Double(swapTotal) : nil }
}

public enum ThermalLevel: String, Codable, Comparable, Sendable {
    case nominal, fair, serious, critical

    private var rank: Int {
        switch self { case .nominal: 0; case .fair: 1; case .serious: 2; case .critical: 3 }
    }
    public static func < (lhs: ThermalLevel, rhs: ThermalLevel) -> Bool { lhs.rank < rhs.rank }

    public var label: String {
        switch self {
        case .nominal: "Normal"
        case .fair: "Caliente"
        case .serious: "Muy caliente"
        case .critical: "Crítico"
        }
    }

    public var processInfoState: ProcessInfo.ThermalState {
        switch self {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        }
    }
}

public struct ThermalReading: Sendable, Equatable {
    public var level: ThermalLevel
    public var speedLimit: Int?
    public var throttling: Bool
    public init(level: ThermalLevel = .nominal, speedLimit: Int? = nil, throttling: Bool = false) {
        self.level = level; self.speedLimit = speedLimit; self.throttling = throttling
    }
}

public struct CoreTicks: Sendable, Equatable {
    public var user, system, idle, nice: UInt64
    public init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64 = 0) {
        self.user = user; self.system = system; self.idle = idle; self.nice = nice
    }
}

public struct CoreTopology: Sendable, Equatable {
    public var performance: Int
    public var efficiency: Int          // 0 en Intel
    public init(performance: Int, efficiency: Int) {
        self.performance = performance; self.efficiency = efficiency
    }
}

/// Proceso del usuario actual (libproc).
public struct OwnProcess: Sendable, Equatable {
    public var pid, ppid: Int32
    public var uid: UInt32
    public var name: String
    public var executablePath: String?
    public var startTime: Date
    public var cpuTimeNs: UInt64
    public var footprint: Int64
    public var energyNj: UInt64
    public var diskReadBytes, diskWriteBytes: UInt64
    public var workingDirectory: String?
    public var isZombie: Bool

    public init(pid: Int32, ppid: Int32 = 1, uid: UInt32 = 501, name: String, executablePath: String? = nil,
                startTime: Date = Date(timeIntervalSince1970: 0), cpuTimeNs: UInt64 = 0, footprint: Int64 = 0,
                energyNj: UInt64 = 0, diskReadBytes: UInt64 = 0, diskWriteBytes: UInt64 = 0,
                workingDirectory: String? = nil, isZombie: Bool = false) {
        self.pid = pid; self.ppid = ppid; self.uid = uid; self.name = name
        self.executablePath = executablePath; self.startTime = startTime; self.cpuTimeNs = cpuTimeNs
        self.footprint = footprint; self.energyNj = energyNj
        self.diskReadBytes = diskReadBytes; self.diskWriteBytes = diskWriteBytes
        self.workingDirectory = workingDirectory; self.isZombie = isZombie
    }
}

/// Proceso de cualquier usuario (`/bin/ps`).
public struct SystemProcess: Sendable, Equatable {
    public var pid, ppid: Int32
    public var uid: UInt32
    public var cpuPercent: Double
    public var rssBytes: Int64
    public var state: String
    public var name: String
    public var isZombie: Bool { state.hasPrefix("Z") }

    public init(pid: Int32, ppid: Int32 = 1, uid: UInt32 = 0, cpuPercent: Double = 0, rssBytes: Int64 = 0,
                state: String = "S", name: String) {
        self.pid = pid; self.ppid = ppid; self.uid = uid; self.cpuPercent = cpuPercent
        self.rssBytes = rssBytes; self.state = state; self.name = name
    }
}

public struct RunningAppInfo: Sendable, Equatable {
    public enum Policy: String, Sendable { case regular, accessory, prohibited }
    public var pid: Int32
    public var bundleID: String?
    public var name: String
    public var bundlePath: String?
    public var policy: Policy
    public init(pid: Int32, bundleID: String? = nil, name: String, bundlePath: String? = nil, policy: Policy = .regular) {
        self.pid = pid; self.bundleID = bundleID; self.name = name
        self.bundlePath = bundlePath; self.policy = policy
    }
}

public struct BatteryReading: Sendable, Equatable {
    public var percent: Int
    public var isCharging: Bool
    public var onACPower: Bool
    public var cycleCount: Int?
    public var healthPercent: Int?
    public init(percent: Int, isCharging: Bool, onACPower: Bool, cycleCount: Int? = nil, healthPercent: Int? = nil) {
        self.percent = percent; self.isCharging = isCharging; self.onACPower = onACPower
        self.cycleCount = cycleCount; self.healthPercent = healthPercent
    }
}

/// Disco: leídos/escritos. Red: bajada/subida.
public struct IOCounters: Sendable, Equatable {
    public var read: UInt64
    public var written: UInt64
    public init(read: UInt64, written: UInt64) { self.read = read; self.written = written }
}

public struct RawSample: Sendable, Equatable {
    public var date: Date
    public var uptimeNs: UInt64                 // CLOCK_UPTIME_RAW
    public var memory: MemoryStats
    public var thermal: ThermalReading
    public var cores: [CoreTicks]
    public var topology: CoreTopology?
    public var bootTime: Date?
    public var processes: [OwnProcess]
    public var system: [SystemProcess]?         // nil = ps falló
    public var apps: [RunningAppInfo]
    public var battery: BatteryReading?
    public var disk: IOCounters?
    public var network: IOCounters?

    public init(date: Date, uptimeNs: UInt64, memory: MemoryStats = MemoryStats(),
                thermal: ThermalReading = ThermalReading(), cores: [CoreTicks] = [],
                topology: CoreTopology? = nil, bootTime: Date? = nil,
                processes: [OwnProcess] = [], system: [SystemProcess]? = nil,
                apps: [RunningAppInfo] = [], battery: BatteryReading? = nil,
                disk: IOCounters? = nil, network: IOCounters? = nil) {
        self.date = date; self.uptimeNs = uptimeNs; self.memory = memory; self.thermal = thermal
        self.cores = cores; self.topology = topology; self.bootTime = bootTime
        self.processes = processes; self.system = system; self.apps = apps; self.battery = battery
        self.disk = disk; self.network = network
    }
}

public struct Rate: Sendable, Equatable {
    public var readPerSecond: Double
    public var writePerSecond: Double
    public init(readPerSecond: Double, writePerSecond: Double) {
        self.readPerSecond = readPerSecond; self.writePerSecond = writePerSecond
    }
}

/// 0…100.
public struct CPUUsage: Sendable, Equatable {
    public var total: Double
    public var performance: Double?
    public var efficiency: Double?
    public var topology: CoreTopology?
    public init(total: Double, performance: Double? = nil, efficiency: Double? = nil, topology: CoreTopology? = nil) {
        self.total = total; self.performance = performance; self.efficiency = efficiency; self.topology = topology
    }
}

public struct Zombie: Sendable, Equatable {
    public var pid: Int32
    public var parentPID: Int32
    public var parentName: String?
    public init(pid: Int32, parentPID: Int32, parentName: String?) {
        self.pid = pid; self.parentPID = parentPID; self.parentName = parentName
    }
}

public enum AppGroupKind: String, Sendable, Codable { case app, background, looseProcess, system }

public struct AppGroup: Sendable, Equatable, Identifiable {
    public var id: String              // bundleID ?? "bundle:" + bundlePath  |  "pid:\(pid):\(startTime epoch)"
    public var name: String
    public var detail: String?
    public var bundleID: String?
    public var bundlePath: String?
    public var kind: AppGroupKind
    public var uid: UInt32
    public var leadPID: Int32
    public var leadStart: Date
    public var pids: [Int32]
    public var processNames: [String]
    public var memory: Int64           // Σ footprint
    public var cpuPercent: Double?     // Σ processCPU (nil si ninguno tiene delta)
    public var energy: Double?         // Σ processEnergy
    public var explanation: String?

    public init(id: String, name: String, detail: String? = nil, bundleID: String? = nil,
                bundlePath: String? = nil, kind: AppGroupKind, uid: UInt32, leadPID: Int32,
                leadStart: Date, pids: [Int32], processNames: [String], memory: Int64,
                cpuPercent: Double? = nil, energy: Double? = nil, explanation: String? = nil) {
        self.id = id; self.name = name; self.detail = detail; self.bundleID = bundleID
        self.bundlePath = bundlePath; self.kind = kind; self.uid = uid; self.leadPID = leadPID
        self.leadStart = leadStart; self.pids = pids; self.processNames = processNames
        self.memory = memory; self.cpuPercent = cpuPercent; self.energy = energy
        self.explanation = explanation
    }

    /// memory / totalMemory + (cpuPercent ?? 0) / (100 × max(1, logicalCores))
    public func impact(totalMemory: Int64, logicalCores: Int) -> Double {
        let mem = totalMemory > 0 ? Double(memory) / Double(totalMemory) : 0
        return mem + (cpuPercent ?? 0) / (100 * Double(max(1, logicalCores)))
    }
}

public struct PerformanceSnapshot: Sendable, Equatable {
    public var date: Date
    public var memory: MemoryStats
    public var thermal: ThermalReading
    public var cpu: CPUUsage?                         // nil en la primera muestra
    public var processCPU: [Int32: Double]            // % por PID propio (100 = un núcleo)
    public var processEnergy: [Int32: Double]         // vatios aprox.
    public var raw: RawSample
    public var groups: [AppGroup]
    public var battery: BatteryReading?
    public var disk: Rate?
    public var network: Rate?
    public var uptime: TimeInterval?
    public var zombies: [Zombie]

    public init(date: Date, memory: MemoryStats, thermal: ThermalReading, cpu: CPUUsage? = nil,
                processCPU: [Int32: Double] = [:], processEnergy: [Int32: Double] = [:],
                raw: RawSample, groups: [AppGroup] = [], battery: BatteryReading? = nil,
                disk: Rate? = nil, network: Rate? = nil, uptime: TimeInterval? = nil,
                zombies: [Zombie] = []) {
        self.date = date; self.memory = memory; self.thermal = thermal; self.cpu = cpu
        self.processCPU = processCPU; self.processEnergy = processEnergy; self.raw = raw
        self.groups = groups; self.battery = battery; self.disk = disk; self.network = network
        self.uptime = uptime; self.zombies = zombies
    }
}

public protocol PerformanceSampling: Sendable {
    func sample() async -> RawSample
}
