import Foundation

/// Una fila de `docker system df` (bytes decimales; `nil` si no se pudo leer).
public struct DockerUsage: Sendable, Equatable {
    public var size: Int64?
    public var reclaimable: Int64?

    public init(size: Int64?, reclaimable: Int64?) {
        self.size = size; self.reclaimable = reclaimable
    }
}

/// Lo que dice Docker en una sola sonda por pasada.
public struct DockerSnapshot: Sendable, Equatable {
    /// Por "Type" de `docker system df` ("Images", "Containers", "Local Volumes", "Build Cache").
    public var usage: [String: DockerUsage]
    /// Nombres de los contenedores parados (exited, created, dead).
    public var stoppedContainers: [String]
    /// Nombres de las redes sin usar, sin las de Docker (bridge, host, none).
    public var unusedNetworks: [String]

    public init(usage: [String: DockerUsage], stoppedContainers: [String], unusedNetworks: [String]) {
        self.usage = usage; self.stoppedContainers = stoppedContainers; self.unusedNetworks = unusedNetworks
    }
}

public enum DockerState: Sendable, Equatable {
    case notInstalled, daemonDown, running(DockerSnapshot)
}

/// Sondas de solo lectura a `docker`. Nunca arranca Docker ni ejecuta limpiezas.
public enum DockerProbe {
    public static let timeout: TimeInterval = 20
    public static let unavailableMessage = "Abre Docker Desktop para limpiar esto"

    static let versionArguments = ["version", "--format", "{{.Server.Version}}"]
    static let dfArguments = ["system", "df", "--format", "{{json .}}"]
    static let stoppedArguments = ["ps", "-a", "--filter", "status=exited", "--filter", "status=created",
                                   "--filter", "status=dead", "--format", "{{.Names}}"]
    static let networkArguments = ["network", "ls", "--filter", "dangling=true", "--format", "{{.Name}}"]
    static let builtInNetworks: Set<String> = ["bridge", "host", "none"]

    /// Sin `docker` ⇒ `notInstalled`; si `version`, `df` o los listados fallan ⇒ `daemonDown` (fallo cerrado).
    public static func state(runner: any CommandRunning) async -> DockerState {
        guard let docker = await runner.resolve("docker") else { return .notInstalled }
        guard await responds(docker, runner: runner),
              let df = await output(docker, dfArguments, runner: runner),
              let stopped = await lines(docker, stoppedArguments, runner: runner),
              let networks = await lines(docker, networkArguments, runner: runner)
        else { return .daemonDown }
        return .running(DockerSnapshot(usage: parseDF(df), stoppedContainers: stopped,
                                       unusedNetworks: networks.filter { !builtInNetworks.contains($0) }))
    }

    /// `docker version --format {{.Server.Version}}`: estado 0 **y** salida no vacía.
    public static func daemonResponds(runner: any CommandRunning) async -> Bool {
        guard let docker = await runner.resolve("docker") else { return false }
        return await responds(docker, runner: runner)
    }

    /// Contenedores parados ahora, o `nil` si no se pudo saber.
    static func stoppedContainers(runner: any CommandRunning) async -> [String]? {
        guard let docker = await runner.resolve("docker") else { return nil }
        return await lines(docker, stoppedArguments, runner: runner)
    }

    /// Redes sin usar ahora (sin las de Docker), o `nil` si no se pudo saber.
    static func unusedNetworks(runner: any CommandRunning) async -> [String]? {
        guard let docker = await runner.resolve("docker") else { return nil }
        return await lines(docker, networkArguments, runner: runner)?.filter { !builtInNetworks.contains($0) }
    }

    private static func responds(_ docker: String, runner: any CommandRunning) async -> Bool {
        guard let version = await output(docker, versionArguments, runner: runner) else { return false }
        return !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func output(_ docker: String, _ arguments: [String], runner: any CommandRunning) async -> String? {
        guard let result = try? await runner.run(docker, arguments, timeout: timeout), result.status == 0 else {
            return nil
        }
        return result.stdout
    }

    private static func lines(_ docker: String, _ arguments: [String], runner: any CommandRunning) async -> [String]? {
        await output(docker, arguments, runner: runner).map { text in
            text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
    }

    /// `docker system df --format {{json .}}`: un objeto JSON por línea con "Type", "Size" y "Reclaimable".
    static func parseDF(_ output: String) -> [String: DockerUsage] {
        var usage: [String: DockerUsage] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = object["Type"] as? String else { continue }
            usage[type] = DockerUsage(size: (object["Size"] as? String).flatMap(CleanupScanner.parseDockerSize),
                                      reclaimable: (object["Reclaimable"] as? String)
                                          .flatMap(CleanupScanner.parseDockerSize))
        }
        return usage
    }
}

/// Fichas `discovery {"type":"docker"}`: tamaños de `docker system df`, contenedores parados y redes sin
/// usar. Con el demonio caído, las fichas de comando salen bloqueadas y los volúmenes no salen.
public struct DockerSource: CleanupTargetSource {
    public init() {}

    enum Field { case size, reclaimable }

    /// Qué fila y qué campo de `docker system df` mide cada ficha (`docker-networks` no ocupa disco).
    static let measure: [String: (type: String, field: Field)] = [
        "docker-build-cache": ("Build Cache", .reclaimable),
        "docker-images": ("Images", .reclaimable),
        "docker-containers": ("Containers", .reclaimable),
        "docker-volumes": ("Local Volumes", .size),
    ]
    static let containersID = "docker-containers"
    static let networksID = "docker-networks"
    static let noDiskNote = "No ocupa espacio en disco"

    public func discover(_ entry: CatalogEntry, context: DiscoveryContext) async -> [DiscoveredTarget] {
        let state: DockerState
        if let known = context.docker { state = known } else { state = await DockerProbe.state(runner: context.runner) }
        let paths = CleanupTargets.livePaths(of: entry, home: context.home)
        switch state {
        case .notInstalled:
            return []
        case .daemonDown:
            // Solo lo que se limpia con comando; nunca se arranca Docker para medir.
            guard case .command = entry.cleanup else { return [] }
            return [DiscoveredTarget(paths: paths, bytes: 0, blockedReason: DockerProbe.unavailableMessage,
                                     sizeNote: "Tamaño desconocido")]
        case .running(let snapshot):
            if entry.id == Self.networksID {
                guard !snapshot.unusedNetworks.isEmpty else { return [] }
                return [DiscoveredTarget(paths: paths, bytes: 0, details: snapshot.unusedNetworks,
                                         sizeNote: Self.noDiskNote)]
            }
            guard let measure = Self.measure[entry.id], let usage = snapshot.usage[measure.type],
                  let bytes = measure.field == .size ? usage.size : usage.reclaimable else { return [] }
            if entry.id == Self.containersID {
                guard !snapshot.stoppedContainers.isEmpty else { return [] }
                return [DiscoveredTarget(paths: paths, bytes: bytes, details: snapshot.stoppedContainers)]
            }
            return [DiscoveredTarget(paths: paths, bytes: bytes)]
        }
    }

    /// Demonio arriba y, para contenedores y redes, nada nuevo que el usuario no haya visto en la confirmación.
    public func revalidate(_ entry: CatalogEntry, item: CleanupItem, context: DiscoveryContext) async -> String? {
        switch entry.cleanup {
        case .info:
            return nil
        case .trash:
            return "«\(entry.title)» solo se limpia con el comando oficial de Docker; no se toca."
        case .command:
            guard await DockerProbe.daemonResponds(runner: context.runner) else { return DockerProbe.unavailableMessage }
            let seen = Set(item.details)
            switch entry.id {
            case Self.containersID:
                guard let live = await DockerProbe.stoppedContainers(runner: context.runner) else {
                    return DockerProbe.unavailableMessage
                }
                return Set(live).isSubset(of: seen) ? nil : "Hay contenedores parados nuevos; vuelve a revisarlo."
            case Self.networksID:
                guard let live = await DockerProbe.unusedNetworks(runner: context.runner) else {
                    return DockerProbe.unavailableMessage
                }
                return Set(live).isSubset(of: seen) ? nil : "Hay redes sin usar nuevas; vuelve a revisarlo."
            default:
                return nil
            }
        }
    }
}
