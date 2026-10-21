import Foundation

/// Quién pidió una detección de limpiezas: decide su QoS.
public enum DetectionTrigger: Sendable, Equatable {
    /// Al abrir la app o tras un análisis automático (o de un agente): nadie está esperando delante.
    case automatic
    /// El usuario abrió Limpieza, pulsó «Buscar de nuevo», cambió un ajuste o acaba de limpiar algo.
    case user
}

public enum DetectionSchedule {
    /// Misma regla que los reanálisis automáticos (`ScanBudget`):
    /// - `automatic`: QoS `.background` (núcleos de eficiencia, E/S moderada) y como mucho 2 paseos a la vez.
    /// - `user`: QoS `.utility` y como mucho 2 paseos a la vez.
    /// Con Bajo consumo o temperatura `.serious` o peor, 1 paseo.
    /// La detección recorre una ruta cada vez y sus pasadas van de una en una (una nueva espera a que la
    /// cancelada suelte el disco), así que `workers` es un tope que nunca se supera, no un paralelismo.
    public static func budget(_ trigger: DetectionTrigger, lowPowerMode: Bool,
                              thermalState: ProcessInfo.ThermalState) -> ScanBudget {
        let constrained = lowPowerMode || thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        let workers = constrained ? 1 : ScanBudget.lightWorkers
        switch trigger {
        case .automatic: return ScanBudget(workers: workers, qos: .background)
        case .user: return ScanBudget(workers: workers, qos: .utility)
        }
    }

    /// La regla con el estado actual del Mac.
    public static func current(_ trigger: DetectionTrigger) -> ScanBudget {
        let info = ProcessInfo.processInfo
        return budget(trigger, lowPowerMode: info.isLowPowerModeEnabled, thermalState: info.thermalState)
    }

    /// Prioridad de tarea equivalente a la QoS del presupuesto (la de la tarea que espera también: si no,
    /// esperarla desde el hilo principal la subiría).
    public static func priority(for budget: ScanBudget) -> TaskPriority {
        switch budget.qos {
        case .background: return .background
        case .utility: return .utility
        case .userInitiated, .userInteractive: return .userInitiated
        default: return .medium
        }
    }

    /// Tras un análisis, quién detecta: lo que pidió el usuario sigue siendo del usuario.
    public static func trigger(after scan: ScanTrigger) -> DetectionTrigger {
        scan == .user ? .user : .automatic
    }
}

/// Cuándo puede empezar la detección automática: nunca antes de tener un árbol que reutilizar (el índice
/// guardado o el análisis recién terminado) y nunca sobre un índice que va a sustituir un análisis en curso.
/// Las detecciones del usuario no pasan por aquí.
public struct DetectionGate: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        /// Leyendo el índice guardado: aún no hay nada que reutilizar.
        case waitingForIndex
        /// Hay (o habrá) un análisis nuevo: la detección automática espera a que termine.
        case waitingForScan
        /// Árbol definitivo publicado: la detección automática ya puede correr.
        case ready
    }

    public private(set) var phase: Phase = .waitingForIndex
    /// Ya se detectó una vez por el usuario mientras se esperaba (abrir Limpieza no repite).
    private var servedWhileWaiting = false

    public init() {}

    /// Empieza un análisis (o la lectura de su índice).
    public mutating func scanStarted() {
        phase = .waitingForIndex
        servedWhileWaiting = false
    }

    /// Se leyó (o no) el índice guardado y se sabe si habrá análisis. Devuelve la detección a lanzar ya.
    public mutating func indexRead(hasIndex: Bool, plan: ScanPlan) -> DetectionTrigger? {
        guard phase == .waitingForIndex else { return nil }
        if hasIndex, plan == .skip {
            phase = .ready
            return .automatic
        }
        phase = .waitingForScan
        return nil
    }

    /// El análisis terminó y su árbol está publicado.
    public mutating func scanFinished(_ trigger: ScanTrigger) -> DetectionTrigger? {
        guard phase != .ready else { return nil }
        phase = .ready
        return DetectionSchedule.trigger(after: trigger)
    }

    /// El análisis se canceló o falló: se detecta sobre lo que se ve, si hay algo.
    public mutating func scanStopped(hasTree: Bool) -> DetectionTrigger? {
        guard phase != .ready else { return nil }
        phase = .ready
        return hasTree ? .automatic : nil
    }

    /// El usuario abrió Limpieza mientras se espera al análisis: se detecta ya sobre el índice que se ve
    /// (una vez por espera). Con el árbol definitivo no hace falta: la automática ya corrió o está corriendo.
    public mutating func cleanupOpened(hasTree: Bool) -> DetectionTrigger? {
        guard phase == .waitingForScan, hasTree, !servedWhileWaiting else { return nil }
        servedWhileWaiting = true
        return .user
    }

    /// Una detección automática pedida desde fuera solo corre con el árbol definitivo.
    public var allowsAutomatic: Bool { phase == .ready }
}

/// Raíces fuera de las cuales la detección no lee el disco. Solo se fija con `AIRY_SCAN_ROOTS` (DEBUG): así
/// las comprobaciones de la app y las pruebas nunca recorren el home real (proyectos, carpetas del catálogo).
/// Sin ámbito (`current == nil`) todo está permitido, como siempre.
public struct DiskScope: Sendable, Equatable {
    /// Rutas canónicas (`RiskPolicy.canonical`), con y sin resolver enlaces (`/tmp` ⇒ `/private/tmp`).
    public let roots: [String]

    @TaskLocal public static var current: DiskScope?

    public init(roots: [String]) {
        var all: [String] = []
        for root in roots {
            for form in [root, CleanupTargets.realPath(root) ?? root] {
                let canonical = RiskPolicy.canonical(form)
                if !all.contains(canonical) { all.append(canonical) }
            }
        }
        self.roots = all
    }

    /// `path` está dentro de alguna raíz (o es una): se puede recorrer.
    public func contains(_ path: String) -> Bool {
        let canonical = RiskPolicy.canonical(path)
        return roots.contains { RiskPolicy.isInside(canonical, root: $0) }
    }

    /// `path` está dentro de una raíz o es un antepasado de una: se puede listar para llegar a ella.
    public func reaches(_ path: String) -> Bool {
        let canonical = RiskPolicy.canonical(path)
        if canonical == "/" { return true }
        return roots.contains { RiskPolicy.isInside(canonical, root: $0) || RiskPolicy.isInside($0, root: canonical) }
    }

    /// Se puede recorrer `path` con el ámbito de esta tarea.
    public static func allowsWalk(_ path: String) -> Bool { current?.contains(path) ?? true }

    /// Se puede listar `path` con el ámbito de esta tarea.
    public static func allowsList(_ path: String) -> Bool { current?.reaches(path) ?? true }
}
