import Foundation

/// Veto final del embudo a una orden de limpieza, aunque venga del catálogo: se comprueba en el plan y
/// otra vez justo antes de cada `runner.run`.
public enum CommandPolicy {
    static let dockerVolumesReason = "Airy nunca borra volúmenes de Docker."
    static let invalidReason = "Orden no válida."

    /// Motivo para no ejecutar nunca esta orden aunque venga del catálogo; `nil` si se permite.
    public static func refusal(executable: String, arguments: [String]) -> String? {
        // Escalares de control (saltos de línea, NUL…) en cualquier orden: nunca son legítimos.
        for text in [executable] + arguments where text.unicodeScalars.contains(where: {
            $0.properties.generalCategory == .control
        }) {
            return invalidReason
        }
        guard (executable as NSString).lastPathComponent == "docker" else { return nil }
        // Volúmenes: ni `volume …`, ni `--volumes`, ni `system prune` (que con o sin opciones puede llevárselos).
        if arguments.contains(where: { $0 == "volume" || $0 == "volumes" || $0.hasPrefix("--volumes") }) {
            return dockerVolumesReason
        }
        if let system = arguments.firstIndex(of: "system"), arguments[system...].contains("prune") {
            return dockerVolumesReason
        }
        return nil
    }
}
