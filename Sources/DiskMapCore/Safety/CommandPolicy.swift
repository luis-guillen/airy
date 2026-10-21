import Foundation

/// The funnel's final veto on a cleanup command, even one from the catalog: checked in the plan and
/// again right before each `runner.run`.
public enum CommandPolicy {
    static var dockerVolumesReason: String { String(localized: "Airy never deletes Docker volumes.", bundle: .airyCore) }
    static var invalidReason: String { String(localized: "Invalid command.", bundle: .airyCore) }
    static var brewDependenciesReason: String { String(localized: "Airy never forces Homebrew to ignore dependencies.", bundle: .airyCore) }
    static var condaBaseReason: String { String(localized: "Airy never deletes the conda base environment.", bundle: .airyCore) }
    static var brewZapReason: String { String(localized: "Airy never uses Homebrew's --zap: Airy picks and checks the leftovers itself.", bundle: .airyCore) }

    /// Why this command must never run even if it comes from the catalog; `nil` if it is allowed.
    public static func refusal(executable: String, arguments: [String]) -> String? {
        // Control scalars (line breaks, NUL…) in any command: they are never legitimate.
        for text in [executable] + arguments where text.unicodeScalars.contains(where: {
            $0.properties.generalCategory == .control
        }) {
            return invalidReason
        }
        let name = (executable as NSString).lastPathComponent.lowercased()
        // `docker-compose down -v` and friends: Compose is left out entirely.
        if name.hasPrefix("docker-compose") { return dockerVolumesReason }
        if name == "brew", arguments.contains(where: { $0.hasPrefix("--ignore-dependencies") }) {
            return brewDependenciesReason
        }
        // `--zap` deletes the cask's list without going through Airy's protections.
        if name == "brew", arguments.contains(where: { $0 == "--zap" || $0.hasPrefix("--zap=") }) {
            return brewZapReason
        }
        // `conda env remove` / `conda remove`: never `--all` nor the base environment (`conda clean --all` is fine).
        if name == "conda", arguments.contains(where: { ["remove", "uninstall"].contains($0) }),
           arguments.contains(where: { $0 == "--all" || $0 == "base" || $0.hasPrefix("--name=base") }) {
            return condaBaseReason
        }
        // By path (`-p`/`--prefix`): only an environment hanging directly from an `envs` folder.
        if name == "conda", arguments.contains(where: { ["remove", "uninstall"].contains($0) }) {
            for (index, argument) in arguments.enumerated() {
                let value: String?
                if argument == "-p" || argument == "--prefix" {
                    value = index + 1 < arguments.count ? arguments[index + 1] : ""
                } else if argument.hasPrefix("--prefix=") {
                    value = String(argument.dropFirst("--prefix=".count))
                } else {
                    value = nil
                }
                // The catalog template (`-p {target}`) is checked again once substituted.
                guard let value, value != CleanupMethod.targetPlaceholder else { continue }
                let parent = (value as NSString).deletingLastPathComponent
                if !value.hasPrefix("/") || value.contains("/..") || value.hasSuffix("/")
                    || (parent as NSString).lastPathComponent != "envs" {
                    return condaBaseReason
                }
            }
        }
        guard name == "docker" else { return nil }
        for argument in arguments {
            // `volume …`, `--volumes…`, and `compose`/`rm` (which take volumes along with `-v`).
            if ["volume", "volumes", "compose", "rm"].contains(argument) || argument.hasPrefix("--volumes") {
                return dockerVolumesReason
            }
            // Short option with `v` in its group: `-v`, `-fv`, `-vf`…
            if argument.hasPrefix("-"), !argument.hasPrefix("--"), argument.dropFirst().contains("v") {
                return dockerVolumesReason
            }
        }
        // `system prune`, with or without options, can take them along.
        if let system = arguments.firstIndex(of: "system"), arguments[system...].contains("prune") {
            return dockerVolumesReason
        }
        return nil
    }
}
