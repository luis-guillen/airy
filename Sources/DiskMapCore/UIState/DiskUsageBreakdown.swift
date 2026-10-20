import Foundation

/// Reparto del disco para la tarjeta de la barra lateral, con cifras que cuadran:
/// `analyzedShown + (other ?? 0) + purgeable + free == total`.
///
/// - `free`: libre de verdad (`volumeAvailableCapacityKey`, lo que da `df`).
/// - `purgeable`: lo que macOS puede liberar solo si hace falta (instantáneas, cachés purgables):
///   `volumeAvailableCapacityForImportantUsageKey − volumeAvailableCapacityKey`. Está dentro de lo usado.
/// - `used = total − free` (incluye lo purgable).
/// - `analyzed`: lo que suma el análisis ("Analizado"); al analizar `/` incluye macOS y las apps.
/// - `other` ("Sistema y otros"): lo usado que ni es purgable ni sale en el análisis. `nil` cuando lo
///   analizado ya llega o pasa de ese resto (no se puede saber; la interfaz muestra "—", nunca "0").
public struct DiskUsageBreakdown: Sendable, Equatable {
    public let total: Int64
    public let free: Int64
    public let purgeable: Int64
    public let used: Int64
    public let analyzed: Int64
    public let other: Int64?

    public init(totalBytes: Int64, availableBytes: Int64, importantAvailableBytes: Int64, analyzedBytes: Int64) {
        let total = max(totalBytes, 0)
        let free = min(max(availableBytes, 0), total)
        let used = total - free
        // Lo "importante" incluye lo purgable; nunca puede pasar del total ni bajar de lo libre.
        let important = min(max(importantAvailableBytes, free), total)
        let purgeable = min(important - free, used)
        let analyzed = max(analyzedBytes, 0)
        let rest = used - purgeable
        self.total = total
        self.free = free
        self.purgeable = purgeable
        self.used = used
        self.analyzed = analyzed
        self.other = analyzed < rest ? rest - analyzed : nil
    }

    /// Lo analizado tal como entra en el anillo (nunca más de lo usado no purgable).
    public var analyzedShown: Int64 { min(analyzed, used - purgeable) }

    /// Fracciones del anillo, en orden: analizado, sistema y otros, purgable. Suman `used / total`.
    public var ringFractions: (analyzed: Double, other: Double, purgeable: Double) {
        guard total > 0 else { return (0, 0, 0) }
        let t = Double(total)
        return (Double(analyzedShown) / t, Double(other ?? 0) / t, Double(purgeable) / t)
    }

    public var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}
