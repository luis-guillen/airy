import Foundation

public struct PerformanceRow: Sendable, Equatable, Identifiable {
    public var group: AppGroup
    public var eligibility: QuitEligibility
    public var id: String { group.id }

    public init(group: AppGroup, eligibility: QuitEligibility) {
        self.group = group
        self.eligibility = eligibility
    }
}

/// Lo que la sección Rendimiento enseña de una instantánea: qué pesa, qué se puede cerrar y qué no.
/// Los procesos del sistema nunca salen como filas (sí cuentan en las listas de CPU y energía).
public struct PerformanceBoard: Sendable, Equatable {
    public var rows: [PerformanceRow]            // .app, .looseProcess y .background por impact desc, hasta limit
    public var topByCPU: [AppGroup]              // 5, cpuPercent desc (sin nil)
    public var topByEnergy: [AppGroup]           // 5, energy desc (sin nil)
    /// Todas las filas posibles (sin el límite), para resolver propuestas de agente.
    private var allRows: [PerformanceRow]

    public init(snapshot: PerformanceSnapshot?, policy: QuitPolicy, limit: Int = 12) {
        guard let snapshot else {
            rows = []; topByCPU = []; topByEnergy = []; allRows = []
            return
        }
        let total = snapshot.memory.total, cores = snapshot.raw.cores.count
        let sorted = snapshot.groups.sorted {
            let a = $0.impact(totalMemory: total, logicalCores: cores)
            let b = $1.impact(totalMemory: total, logicalCores: cores)
            return a != b ? a > b : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        allRows = sorted.filter { $0.kind != .system }
            .map { PerformanceRow(group: $0, eligibility: policy.eligibility($0)) }
        rows = Array(allRows.prefix(max(0, limit)))
        topByCPU = Array(snapshot.groups.filter { $0.cpuPercent != nil }
            .sorted { ($0.cpuPercent ?? 0) > ($1.cpuPercent ?? 0) }.prefix(5))
        topByEnergy = Array(snapshot.groups.filter { $0.energy != nil }
            .sorted { ($0.energy ?? 0) > ($1.energy ?? 0) }.prefix(5))
    }

    public static func canSelect(_ row: PerformanceRow) -> Bool { row.eligibility.isAllowed }

    /// Solo filas que siguen existiendo y se pueden cerrar.
    public func selected(_ ids: Set<String>) -> [PerformanceRow] {
        rows.filter { ids.contains($0.id) && Self.canSelect($0) }
    }

    /// Propuesta de agente: fila por bundle id o nombre (sin mayúsculas); nil sin instantánea o sin coincidencia.
    /// Con varias coincidencias, la de más memoria. Devuelve también filas «nunca» (la vista dice por qué).
    public func row(matching app: String) -> PerformanceRow? {
        let key = app.lowercased()
        return allRows.filter { $0.group.bundleID?.lowercased() == key || $0.group.name.lowercased() == key }
            .max { $0.group.memory < $1.group.memory }
    }
}
