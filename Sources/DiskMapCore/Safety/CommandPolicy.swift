import Foundation

/// Veto final del embudo a una orden de limpieza, aunque venga del catálogo: se comprueba en el plan y
/// otra vez justo antes de cada `runner.run`.
public enum CommandPolicy {
    static let dockerVolumesReason = "Airy nunca borra volúmenes de Docker."
    static let invalidReason = "Orden no válida."
    static let brewDependenciesReason = "Airy nunca fuerza a Homebrew a ignorar dependencias."
    static let condaBaseReason = "Airy nunca borra el entorno base de conda."
    static let brewZapReason = "Airy nunca usa --zap de Homebrew: los restos los elige y comprueba Airy."

    /// Motivo para no ejecutar nunca esta orden aunque venga del catálogo; `nil` si se permite.
    public static func refusal(executable: String, arguments: [String]) -> String? {
        // Escalares de control (saltos de línea, NUL…) en cualquier orden: nunca son legítimos.
        for text in [executable] + arguments where text.unicodeScalars.contains(where: {
            $0.properties.generalCategory == .control
        }) {
            return invalidReason
        }
        let name = (executable as NSString).lastPathComponent.lowercased()
        // `docker-compose down -v` y compañía: Compose entero queda fuera.
        if name.hasPrefix("docker-compose") { return dockerVolumesReason }
        if name == "brew", arguments.contains(where: { $0.hasPrefix("--ignore-dependencies") }) {
            return brewDependenciesReason
        }
        // `--zap` borra la lista del cask sin pasar por las protecciones de Airy.
        if name == "brew", arguments.contains(where: { $0 == "--zap" || $0.hasPrefix("--zap=") }) {
            return brewZapReason
        }
        // `conda env remove` / `conda remove`: nunca `--all` ni el entorno base (`conda clean --all` sí vale).
        if name == "conda", arguments.contains(where: { ["remove", "uninstall"].contains($0) }),
           arguments.contains(where: { $0 == "--all" || $0 == "base" || $0.hasPrefix("--name=base") }) {
            return condaBaseReason
        }
        guard name == "docker" else { return nil }
        for argument in arguments {
            // `volume …`, `--volumes…`, y `compose`/`rm` (que con `-v` se llevan volúmenes).
            if ["volume", "volumes", "compose", "rm"].contains(argument) || argument.hasPrefix("--volumes") {
                return dockerVolumesReason
            }
            // Opción corta con `v` en su grupo: `-v`, `-fv`, `-vf`…
            if argument.hasPrefix("-"), !argument.hasPrefix("--"), argument.dropFirst().contains("v") {
                return dockerVolumesReason
            }
        }
        // `system prune`, con o sin opciones, puede llevárselos.
        if let system = arguments.firstIndex(of: "system"), arguments[system...].contains("prune") {
            return dockerVolumesReason
        }
        return nil
    }
}
