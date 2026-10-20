import Foundation

/// Cuánto empuja un análisis. Airy tiene que ser ligera: ni el análisis que pide el usuario
/// ocupa todos los núcleos.
/// - `background`: reanálisis automáticos (al abrir, al cambiar de disco, el que pide un agente).
/// - `normal`: el usuario pulsó «Analizar» o no hay índice que enseñar mientras tanto.
public enum ScanIntensity: String, Sendable, Equatable {
    case background, normal
}

/// Hilos y calidad de servicio con los que el escáner hace `readdir`/`fstatat`.
public struct ScanBudget: Sendable, Equatable {
    /// Tope absoluto de hilos de análisis, sea cual sea la máquina.
    public static let maxWorkers = 4
    /// Hilos en segundo plano, y con Bajo consumo o el Mac caliente.
    public static let lightWorkers = 2

    public let workers: Int
    public let qos: QualityOfService

    public init(workers: Int, qos: QualityOfService) {
        self.workers = workers
        self.qos = qos
    }

    /// Regla pura: `background` = 2 hilos; `normal` = hasta 4 (sin pasar de los núcleos de
    /// rendimiento). Con Bajo consumo o temperatura `.serious` o peor, 2. Siempre QoS `.utility`:
    /// medido sobre ~/Library (580 000 elementos), 2 hilos `.background` caen en los núcleos de
    /// eficiencia y gastan 3,6 veces más CPU (37 s frente a 10 s) a más %CPU visible (~140 % frente
    /// a ~100 %) y tardan 3 veces más que 2 hilos `.utility`.
    public static func resolve(
        _ intensity: ScanIntensity,
        performanceCores: Int,
        lowPowerMode: Bool,
        thermalState: ProcessInfo.ThermalState
    ) -> ScanBudget {
        let constrained = lowPowerMode || thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        switch intensity {
        case .background:
            return ScanBudget(workers: lightWorkers, qos: .utility)
        case .normal:
            let cores = max(1, performanceCores)
            let workers = constrained ? min(lightWorkers, cores) : min(maxWorkers, cores)
            return ScanBudget(workers: workers, qos: .utility)
        }
    }

    /// La regla con el estado actual del Mac (núcleos de rendimiento, Bajo consumo, temperatura).
    public static func current(_ intensity: ScanIntensity) -> ScanBudget {
        let info = ProcessInfo.processInfo
        return resolve(intensity, performanceCores: performanceCoreCount(),
                       lowPowerMode: info.isLowPowerModeEnabled, thermalState: info.thermalState)
    }

    /// Núcleos de rendimiento (Apple silicon); en un Mac sin niveles, los núcleos activos.
    static func performanceCoreCount() -> Int {
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &count, &size, nil, 0) == 0, count > 0 {
            return Int(count)
        }
        return ProcessInfo.processInfo.activeProcessorCount
    }
}

/// Qué pidió el análisis: decide si hace falta y con qué intensidad.
public enum ScanTrigger: Sendable, Equatable {
    /// Al abrir la app o al cambiar de disco.
    case automatic
    /// `airy://rescan` (p. ej. la herramienta `rescan` del servidor MCP).
    case agent
    /// El usuario pulsó «Analizar».
    case user
}

public enum ScanPlan: Sendable, Equatable {
    /// El índice guardado es reciente: se enseña y no se reanaliza.
    case skip
    case scan(ScanIntensity)
}

public enum ScanSchedule {
    /// Un índice más joven que esto no se reanaliza solo al abrir.
    public static let freshness: TimeInterval = 6 * 3600

    /// - Parameters:
    ///   - hasIndex: hay un índice guardado que ya se está enseñando.
    ///   - indexDate: fecha de ese índice (`nil` si no se sabe: se trata como viejo).
    public static func plan(_ trigger: ScanTrigger, hasIndex: Bool, indexDate: Date?, now: Date) -> ScanPlan {
        switch trigger {
        case .user:
            return .scan(.normal)
        case .agent:
            return .scan(.background)
        case .automatic:
            // Sin nada que enseñar el usuario espera delante del progreso.
            guard hasIndex else { return .scan(.normal) }
            guard let indexDate else { return .scan(.background) }
            let age = now.timeIntervalSince(indexDate)
            // Una fecha futura (reloj cambiado) no cuenta como reciente.
            return age >= 0 && age < freshness ? .skip : .scan(.background)
        }
    }
}

#if DEBUG
/// `AIRY_SCAN_ROOTS` (solo DEBUG): rutas separadas por `:` que sustituyen al disco entero, para
/// que las comprobaciones de la app analicen una carpeta pequeña. `~` se expande.
public enum ScanRootsOverride {
    public static let variable = "AIRY_SCAN_ROOTS"

    public static func roots(from environment: [String: String]) -> [URL]? {
        guard let raw = environment[variable] else { return nil }
        let roots = raw.split(separator: ":")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        return roots.isEmpty ? nil : roots
    }
}
#endif
