import Foundation

/// A row of `docker system df` (decimal bytes; `nil` if it could not be read).
public struct DockerUsage: Sendable, Equatable {
    public var size: Int64?
    public var reclaimable: Int64?

    public init(size: Int64?, reclaimable: Int64?) {
        self.size = size; self.reclaimable = reclaimable
    }
}

/// What Docker says in a single probe per pass.
public struct DockerSnapshot: Sendable, Equatable {
    /// By "Type" of `docker system df` ("Images", "Containers", "Local Volumes", "Build Cache").
    public var usage: [String: DockerUsage]
    /// Names of the stopped containers (exited, created, dead).
    public var stoppedContainers: [String]
    /// Names of the unused networks, without Docker's own (bridge, host, none).
    public var unusedNetworks: [String]

    public init(usage: [String: DockerUsage], stoppedContainers: [String], unusedNetworks: [String]) {
        self.usage = usage; self.stoppedContainers = stoppedContainers; self.unusedNetworks = unusedNetworks
    }
}

public enum DockerState: Sendable, Equatable {
    case notInstalled, daemonDown, running(DockerSnapshot)
}

/// Read-only probes to `docker`. It never starts Docker nor runs cleanups.
public enum DockerProbe {
    public static let timeout: TimeInterval = 20
    public static var unavailableMessage: String { String(localized: "Open Docker Desktop to clean this", bundle: .airyCore) }

    static let versionArguments = ["version", "--format", "{{.Server.Version}}"]
    static let dfArguments = ["system", "df", "--format", "{{json .}}"]
    static let stoppedArguments = ["ps", "-a", "--filter", "status=exited", "--filter", "status=created",
                                   "--filter", "status=dead", "--format", "{{.Names}}"]
    static let networkArguments = ["network", "ls", "--filter", "dangling=true", "--format", "{{.Name}}"]
    static let builtInNetworks: Set<String> = ["bridge", "host", "none"]

    /// Without `docker` ⇒ `notInstalled`; if `version`, `df` or the listings fail ⇒ `daemonDown` (fail closed).
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

    /// `docker version --format {{.Server.Version}}`: status 0 **and** non-empty output.
    public static func daemonResponds(runner: any CommandRunning) async -> Bool {
        guard let docker = await runner.resolve("docker") else { return false }
        return await responds(docker, runner: runner)
    }

    /// Containers stopped right now, or `nil` if it could not be known.
    static func stoppedContainers(runner: any CommandRunning) async -> [String]? {
        guard let docker = await runner.resolve("docker") else { return nil }
        return await lines(docker, stoppedArguments, runner: runner)
    }

    /// Networks unused right now (without Docker's own), or `nil` if it could not be known.
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

    /// `docker system df --format {{json .}}`: one JSON object per line with "Type", "Size" and "Reclaimable".
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

/// Entries with `discovery {"type":"docker"}`: sizes from `docker system df`, stopped containers and unused
/// networks. With the daemon down, the command entries come out blocked and the volumes do not appear.
public struct DockerSource: CleanupTargetSource {
    public init() {}

    enum Field { case size, reclaimable }

    /// Which `docker system df` row and field each entry measures (`docker-networks` takes no disk space).
    static let measure: [String: (type: String, field: Field)] = [
        "docker-build-cache": ("Build Cache", .reclaimable),
        "docker-images": ("Images", .reclaimable),
        "docker-containers": ("Containers", .reclaimable),
        "docker-volumes": ("Local Volumes", .size),
    ]
    static let containersID = "docker-containers"
    static let networksID = "docker-networks"
    static var noDiskNote: String { String(localized: "Takes no disk space", bundle: .airyCore) }

    public func discover(_ entry: CatalogEntry, context: DiscoveryContext) async -> [DiscoveredTarget] {
        let state: DockerState
        if let known = context.docker { state = known } else { state = await DockerProbe.state(runner: context.runner) }
        let paths = CleanupTargets.livePaths(of: entry, home: context.home)
        switch state {
        case .notInstalled:
            return []
        case .daemonDown:
            // Only what is cleaned with a command; Docker is never started to measure.
            guard case .command = entry.cleanup else { return [] }
            return [DiscoveredTarget(paths: paths, bytes: 0, blockedReason: DockerProbe.unavailableMessage,
                                     sizeNote: String(localized: "Unknown size", bundle: .airyCore))]
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

    /// Daemon up and, for containers and networks, nothing new the user has not seen in the confirmation.
    public func revalidate(_ entry: CatalogEntry, item: CleanupItem, context: DiscoveryContext) async -> String? {
        switch entry.cleanup {
        case .info:
            return nil
        case .trash:
            return String(localized: "“\(entry.title)” is only cleaned with Docker's official command; it is not touched.", bundle: .airyCore)
        case .command:
            guard await DockerProbe.daemonResponds(runner: context.runner) else { return DockerProbe.unavailableMessage }
            let seen = Set(item.details)
            switch entry.id {
            case Self.containersID:
                guard let live = await DockerProbe.stoppedContainers(runner: context.runner) else {
                    return DockerProbe.unavailableMessage
                }
                return Set(live).isSubset(of: seen) ? nil : String(localized: "There are new stopped containers; review it again.", bundle: .airyCore)
            case Self.networksID:
                guard let live = await DockerProbe.unusedNetworks(runner: context.runner) else {
                    return DockerProbe.unavailableMessage
                }
                return Set(live).isSubset(of: seen) ? nil : String(localized: "There are new unused networks; review it again.", bundle: .airyCore)
            default:
                return nil
            }
        }
    }
}
