import Foundation

/// Fichas `discovery {"type":"simulatorRuntimes"}`: entornos (runtimes) de simulador huérfanos (borrables y sin
/// ningún simulador que los use), uno por elemento, con su UUID como `{target}`. Solo sondas de lectura de `simctl`.
///
/// Nunca se llama a `xcrun` en un Mac sin Xcode: en uno sin herramientas, el atajo `/usr/bin/xcrun` abre el
/// diálogo «Instalar herramientas de desarrollo», y con Xcode arranca CoreSimulatorService. Antes hace falta
/// (1) alguna carpeta de CoreSimulator (sin lanzar nada) y (2) `xcode-select -p` correcto apuntando a una
/// carpeta de Xcode que existe (no a las Command Line Tools, que no traen `simctl`).
public struct SimulatorRuntimeSource: CleanupTargetSource {
    /// Carpetas de CoreSimulator del sistema (además de `~/Library/Developer/CoreSimulator`).
    static let systemRoots = ["/Library/Developer/CoreSimulator"]
    static let userRoot = "/Library/Developer/CoreSimulator"
    static let xcodeSelectArguments = ["-p"]
    static let xcodeSelectTimeout: TimeInterval = 5

    private let systemRoots: [String]

    public init() { self.init(systemRoots: Self.systemRoots) }

    /// Pruebas: carpetas del sistema propias (para no depender del Mac donde se ejecutan).
    init(systemRoots: [String]) { self.systemRoots = systemRoots }

    static let runtimeArguments = ["simctl", "runtime", "list", "-j"]
    static let deviceArguments = ["simctl", "list", "devices", "-j"]
    static let timeout: TimeInterval = 20
    static let goneMessage = "Ese entorno de simulador ya lo usa algún simulador o ya no está."
    static let platforms = [
        "com.apple.platform.iphonesimulator": "iOS",
        "com.apple.platform.watchsimulator": "watchOS",
        "com.apple.platform.appletvsimulator": "tvOS",
        "com.apple.platform.xrsimulator": "visionOS",
    ]

    struct Runtime: Equatable {
        var identifier: String
        var platform: String
        var version: String
        var bytes: Int64
        var label: String { "\(platform) \(version)" }
    }

    public func discover(_ entry: CatalogEntry, context: DiscoveryContext) async -> [DiscoveredTarget] {
        guard entry.cleanup.usesTargets else { return [] }
        var used = Set<String>()
        return await orphans(context).map { runtime in
            // Dos runtimes con la misma versión (builds distintas) no comparten id de elemento.
            var suffix = runtime.label
            if !used.insert(suffix).inserted { suffix += " (\(runtime.identifier.prefix(8)))" }
            return DiscoveredTarget(idSuffix: suffix, paths: [], targets: [runtime.identifier], bytes: runtime.bytes)
        }
    }

    /// Vuelve a sondear: cada objetivo debe seguir siendo huérfano y borrable.
    public func revalidate(_ entry: CatalogEntry, item: CleanupItem, context: DiscoveryContext) async -> String? {
        guard entry.cleanup.usesTargets, !item.targets.isEmpty else { return Self.goneMessage }
        let live = Set(await orphans(context).map(\.identifier))
        return item.targets.allSatisfy(live.contains) ? nil : Self.goneMessage
    }

    /// `xcrun` solo si hay CoreSimulator y Xcode (véase arriba); si no, `nil` y no se lanza nada más.
    func xcrunIfXcode(_ context: DiscoveryContext) async -> String? {
        let roots = [context.home + Self.userRoot] + systemRoots
        guard roots.contains(where: Self.isDirectory) else { return nil }
        let runner = context.runner
        guard let select = await runner.resolve("xcode-select"),
              let output = try? await runner.run(select, Self.xcodeSelectArguments, timeout: Self.xcodeSelectTimeout),
              output.status == 0 else { return nil }
        let developer = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard developer.hasPrefix("/"), !developer.contains("CommandLineTools"), Self.isDirectory(developer)
        else { return nil }
        return await runner.resolve("xcrun")
    }

    func orphans(_ context: DiscoveryContext) async -> [Runtime] {
        guard let xcrun = await xcrunIfXcode(context) else { return [] }
        return await Self.orphans(xcrun: xcrun, runner: context.runner)
    }

    /// Runtimes `deletable` sin dispositivos en su `runtimeIdentifier`, ordenados. Cualquier fallo ⇒ `[]`.
    static func orphans(xcrun: String, runner: any CommandRunning) async -> [Runtime] {
        guard let runtimes = await json(xcrun, runtimeArguments, runner: runner) as? [String: Any],
              let devices = (await json(xcrun, deviceArguments, runner: runner) as? [String: Any])?["devices"]
                as? [String: Any]
        else { return [] }
        var result: [Runtime] = []
        for case let info as [String: Any] in runtimes.values {
            guard (info["deletable"] as? Bool) == true,
                  let identifier = info["identifier"] as? String, isUUID(identifier),
                  let runtimeIdentifier = info["runtimeIdentifier"] as? String,
                  let version = info["version"] as? String,
                  let bytes = (info["sizeBytes"] as? NSNumber)?.int64Value
            else { continue }
            // Con algún dispositivo (o una lista que no se entiende) no es huérfano.
            if let list = devices[runtimeIdentifier] {
                guard let array = list as? [Any], array.isEmpty else { continue }
            }
            let platformID = info["platformIdentifier"] as? String ?? ""
            let platform = platforms[platformID] ?? "Simulador"
            result.append(Runtime(identifier: identifier, platform: platform, version: version, bytes: bytes))
        }
        return result.sorted { ($0.label, $0.identifier) < ($1.label, $1.identifier) }
    }

    /// `^[0-9A-Fa-f-]{36}$`: lo único que llega como argumento de `simctl runtime delete`.
    static func isUUID(_ text: String) -> Bool {
        text.utf8.count == 36 && text.unicodeScalars.allSatisfy { $0 == "-" || $0.properties.isASCIIHexDigit }
    }

    private static func isDirectory(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    private static func json(_ xcrun: String, _ arguments: [String], runner: any CommandRunning) async -> Any? {
        guard let output = try? await runner.run(xcrun, arguments, timeout: timeout), output.status == 0 else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: Data(output.stdout.utf8))
    }
}
