import Foundation

/// Lo único que «¿Por qué va lento?» envía a Claude: números y nombres de apps. Nunca rutas, PIDs,
/// argumentos, carpetas de trabajo ni identificadores de bundle.
public enum PerformanceAIContext {
    public static let appLimit = 10

    public static func build(_ snapshot: PerformanceSnapshot, verdict: HealthVerdict) -> String {
        let gb = { (bytes: Int64) in round(Double(bytes) / 1_073_741_824 * 10) / 10 }
        let m = snapshot.memory
        var memory: [String: Any] = [
            "total_gb": gb(m.total), "used_gb": gb(m.used), "file_cache_gb": gb(m.fileCache),
            "swap_used_gb": gb(m.swapUsed), "swap_total_gb": gb(m.swapTotal),
        ]
        memory["pressure"] = m.pressure?.rawValue ?? NSNull()
        let thermal: [String: Any] = ["state": snapshot.thermal.level.rawValue, "throttling": snapshot.thermal.throttling]
        let cpu: [String: Any] = ["total_percent": snapshot.cpu.map { round($0.total * 10) / 10 } as Any? ?? NSNull()]
        let cores = snapshot.raw.cores.count
        let apps = snapshot.groups
            .sorted { $0.impact(totalMemory: m.total, logicalCores: cores) > $1.impact(totalMemory: m.total, logicalCores: cores) }
            .prefix(appLimit)
            .map { g -> [String: Any] in
                [
                    "name": sanitized(g.name),
                    "memory_mb": Int((Double(g.memory) / 1_048_576).rounded()),
                    "cpu_percent": g.cpuPercent.map { round($0 * 10) / 10 } as Any? ?? NSNull(),
                    "processes": g.pids.count,
                ]
            }
        let object: [String: Any] = [
            "memory": memory, "thermal": thermal, "cpu": cpu, "apps": apps,
            "findings": verdict.findings.map(\.sentence),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Un nombre con aspecto de ruta se queda en su último componente.
    static func sanitized(_ name: String) -> String {
        name.contains("/") ? (name as NSString).lastPathComponent : name
    }
}
