import Foundation

/// Cuándo mide Rendimiento (I3) y cuándo repite la comprobación de mantenimiento (M9).
public enum PerformanceSamplingGate {
    /// Solo con la sección a la vista y la ventana **comprobada** visible. `nil` = aún no se sabe (la vista acaba
    /// de crearse y el lector de la ventana no ha informado): no se mide hasta saberlo.
    public static func shouldSample(appeared: Bool, windowVisible: Bool?) -> Bool {
        appeared && windowVisible == true
    }

    /// La comprobación de mantenimiento lanza procesos y lee preferencias: como mucho cada 5 min al aparecer
    /// (tras una acción se repite siempre).
    public static let maintenanceMaxAge: TimeInterval = 300

    public static func maintenanceIsStale(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck else { return true }
        let age = now.timeIntervalSince(lastCheck)
        return age < 0 || age >= maintenanceMaxAge
    }
}
