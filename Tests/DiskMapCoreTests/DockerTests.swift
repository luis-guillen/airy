import Foundation
import Testing
@testable import DiskMapCore

// MARK: - Utilities

private let docker = "/usr/local/bin/docker"

private let dfFixture = """
{"Active":"3","Reclaimable":"1.2GB (40%)","Size":"3GB","TotalCount":"10","Type":"Images"}
{"Active":"1","Reclaimable":"200MB (100%)","Size":"250MB","TotalCount":"3","Type":"Containers"}
{"Active":"1","Reclaimable":"500MB (50%)","Size":"1GB","TotalCount":"2","Type":"Local Volumes"}
{"Active":"0","Reclaimable":"29.89GB","Size":"29.89GB","TotalCount":"120","Type":"Build Cache"}
"""

private func key(_ arguments: [String]) -> String { ([docker] + arguments).joined(separator: " ") }

private let versionArgs = ["version", "--format", "{{.Server.Version}}"]
private let dfArgs = ["system", "df", "--format", "{{json .}}"]
private let psArgs = ["ps", "-a", "--filter", "status=exited", "--filter", "status=created",
                      "--filter", "status=dead", "--format", "{{.Names}}"]
private let networkArgs = ["network", "ls", "--filter", "dangling=true", "--format", "{{.Name}}"]

private func ok(_ stdout: String) -> CommandOutput { CommandOutput(status: 0, stdout: stdout, stderr: "") }

/// Docker running with the test `df`, two stopped containers and one unused network.
private func runningOutputs(containers: String = "db-viejo\nweb\n",
                            networks: String = "bridge\nred-vieja\n") -> [String: CommandOutput] {
    [key(versionArgs): ok("27.3.1\n"), key(dfArgs): ok(dfFixture), key(psArgs): ok(containers),
     key(networkArgs): ok(networks)]
}

private func runner(_ outputs: [String: CommandOutput]) -> FakeRunner {
    FakeRunner(resolved: ["docker": docker], outputs: outputs)
}

private func tempDir() -> String {
    let url = TestTemp.url("airy-docker")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.path
}

private func dockerEntries(_ catalog: Catalog) -> [CatalogEntry] {
    catalog.entries.filter { $0.discovery == .docker }
}

private func scan(_ runner: FakeRunner, catalog: Catalog, settings: AirySettings = .defaults) async -> [CleanupItem] {
    let home = tempDir()
    let entries = dockerEntries(catalog)
    let docked = Catalog(entries: entries)
    return await CleanupScanner(
        catalog: docked, runner: runner, probes: FakeProbes(), references: ReferenceChecker(roots: []), home: home,
        classifier: RiskClassifier(catalog: docked, settings: settings, home: home)
    ).findItems(scan: nil)
}

private func executor(_ runner: FakeRunner, catalog: Catalog) -> CleanupExecutor {
    CleanupExecutor(
        runner: runner, probes: FakeProbes(),
        store: IndexStore(directory: URL(fileURLWithPath: tempDir())), catalog: catalog,
        references: ReferenceChecker(roots: []), home: tempDir(), settings: { .missing })
}

private func ran(_ runner: FakeRunner, _ prefix: [String]) -> Bool {
    runner.calls.contains { Array($0.arguments.prefix(prefix.count)) == prefix }
}

// MARK: - Tests

@Suite struct DockerTests {
    @Test func runningDaemonYieldsFourActionableItems() async throws {
        let catalog = try Catalog.bundled()
        let fake = runner(runningOutputs())
        let items = await scan(fake, catalog: catalog)
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        #expect(Set(byID.keys) == ["docker-build-cache", "docker-images", "docker-containers", "docker-networks",
                                   "docker-volumes"])
        #expect(byID["docker-build-cache"]?.bytes == 29_890_000_000)
        #expect(byID["docker-images"]?.bytes == 1_200_000_000)
        #expect(byID["docker-containers"]?.bytes == 200_000_000)
        #expect(byID["docker-containers"]?.details == ["db-viejo", "web"])
        #expect(byID["docker-networks"]?.bytes == 0)
        #expect(byID["docker-networks"]?.sizeNote == "Takes no disk space")
        #expect(byID["docker-networks"]?.details == ["red-vieja"])
        #expect(byID["docker-volumes"]?.bytes == 1_000_000_000)
        #expect(byID["docker-volumes"]?.risk == .doNotTouch)
        for id in ["docker-build-cache", "docker-images", "docker-containers", "docker-networks"] {
            #expect(byID[id]?.blockedReason == nil, "\(id)")
        }
        // A single probe per pass: four calls, none of them a cleanup.
        #expect(fake.calls.count == 4)
        #expect(!fake.calls.contains { $0.arguments.contains("prune") })
    }

    @Test func noUnusedNetworksMeansNoNetworkRow() async throws {
        let items = await scan(runner(runningOutputs(networks: "bridge\nhost\nnone\n")), catalog: try Catalog.bundled())
        #expect(!items.contains { $0.id == "docker-networks" })
    }

    @Test func daemonDownShowsBlockedRowsAndNoVolumes() async throws {
        var outputs = runningOutputs()
        outputs[key(versionArgs)] = CommandOutput(status: 1, stdout: "", stderr: "Cannot connect to the Docker daemon")
        let fake = runner(outputs)
        let items = await scan(fake, catalog: try Catalog.bundled())
        #expect(Set(items.map(\.id)) == ["docker-build-cache", "docker-images", "docker-containers", "docker-networks"])
        for item in items {
            #expect(item.bytes == 0)
            #expect(item.sizeNote == "Unknown size")
            #expect(item.blockedReason == "Open Docker Desktop to clean this")
            #expect(!CleanupBoard.canSelect(item))
        }
        // Docker is never started: it is only asked for its version.
        #expect(fake.calls.map(\.arguments) == [versionArgs])
    }

    @Test func emptyVersionOutputCountsAsDown() async throws {
        let fake = FakeRunner(resolved: ["docker": docker])
        #expect(await DockerProbe.state(runner: fake) == .daemonDown)
        #expect(await DockerProbe.daemonResponds(runner: fake) == false)
        var outputs = runningOutputs()
        outputs[key(dfArgs)] = CommandOutput(status: 1, stdout: "", stderr: "error")
        #expect(await DockerProbe.state(runner: runner(outputs)) == .daemonDown)
        #expect(await DockerProbe.daemonResponds(runner: runner(runningOutputs())))
    }

    @Test func notInstalledYieldsNothing() async throws {
        let fake = FakeRunner(resolved: [:])
        #expect(await DockerProbe.state(runner: fake) == .notInstalled)
        #expect(await scan(fake, catalog: try Catalog.bundled()).isEmpty)
        #expect(fake.calls.isEmpty)
    }

    @Test func probeParsesSnapshot() async throws {
        guard case .running(let snapshot) = await DockerProbe.state(runner: runner(runningOutputs())) else {
            Issue.record("expected .running"); return
        }
        #expect(snapshot.stoppedContainers == ["db-viejo", "web"])
        #expect(snapshot.unusedNetworks == ["red-vieja"])
        #expect(snapshot.usage["Images"] == DockerUsage(size: 3_000_000_000, reclaimable: 1_200_000_000))
        #expect(snapshot.usage["Local Volumes"]?.size == 1_000_000_000)
    }

    @Test func daemonStoppedAfterDetectionBlocksAtAct() async throws {
        let catalog = try Catalog.bundled()
        let items = await scan(runner(runningOutputs()), catalog: catalog)
        let images = try #require(items.first { $0.id == "docker-images" })
        var outputs = runningOutputs()
        outputs[key(versionArgs)] = CommandOutput(status: 1, stdout: "", stderr: "down")
        let later = runner(outputs)
        let outcome = await executor(later, catalog: catalog).execute(images)
        #expect(outcome == .blocked(reason: DockerProbe.unavailableMessage))
        #expect(!ran(later, ["image", "prune"]))
    }

    @Test func runningDaemonRunsTheOfficialPrune() async throws {
        let catalog = try Catalog.bundled()
        let fake = runner(runningOutputs())
        let images = try #require(await scan(fake, catalog: catalog).first { $0.id == "docker-images" })
        let act = runner(runningOutputs())
        guard case .freed = await executor(act, catalog: catalog).execute(images) else {
            Issue.record("expected .freed"); return
        }
        #expect(act.calls.last?.arguments == ["image", "prune", "-a", "-f"])
    }

    @Test func newStoppedContainerAfterDetectionBlocks() async throws {
        let catalog = try Catalog.bundled()
        let items = await scan(runner(runningOutputs()), catalog: catalog)
        let containers = try #require(items.first { $0.id == "docker-containers" })
        let networks = try #require(items.first { $0.id == "docker-networks" })

        let later = runner(runningOutputs(containers: "db-viejo\nweb\nnuevo\n", networks: "red-vieja\nred-nueva\n"))
        let exec = executor(later, catalog: catalog)
        #expect(await exec.execute(containers) == .blocked(reason: "There are new stopped containers; review it again."))
        #expect(await exec.execute(networks) == .blocked(reason: "There are new unused networks; review it again."))
        #expect(!later.calls.contains { $0.arguments.contains("prune") })

        // If one is no longer there (the user deleted it), it is still valid: nothing that was not seen is ever deleted.
        let fewer = runner(runningOutputs(containers: "web\n"))
        guard case .freed = await executor(fewer, catalog: catalog).execute(containers) else {
            Issue.record("expected .freed"); return
        }
        #expect(fewer.calls.last?.arguments == ["container", "prune", "-f"])
    }

    @Test func commandPolicyRefusesVolumes() {
        #expect(CommandPolicy.refusal(executable: "/usr/local/bin/docker", arguments: ["volume", "prune", "-f"]) != nil)
        #expect(CommandPolicy.refusal(executable: "docker", arguments: ["system", "prune", "-a", "--volumes"]) != nil)
        #expect(CommandPolicy.refusal(executable: "docker", arguments: ["system", "prune", "-a"])
            == "Airy never deletes Docker volumes.")
        #expect(CommandPolicy.refusal(executable: "docker", arguments: ["container", "rm", "--volumes=true", "x"]) != nil)
        #expect(CommandPolicy.refusal(executable: "docker", arguments: ["volumes"]) != nil)
        for args in [["rm", "-v", "web"], ["rm", "-fv", "web"], ["container", "rm", "web"], ["compose", "down", "-v"],
                     ["compose", "down"], ["container", "prune", "-vf"], ["run", "-v", "/x:/y", "img"]] {
            #expect(CommandPolicy.refusal(executable: "/usr/local/bin/docker", arguments: args)
                == "Airy never deletes Docker volumes.", "\(args)")
        }
        #expect(CommandPolicy.refusal(executable: "/usr/local/bin/docker-compose", arguments: ["down", "-v"]) != nil)
        #expect(CommandPolicy.refusal(executable: "docker-compose", arguments: ["down"]) != nil)
        #expect(CommandPolicy.refusal(executable: "docker", arguments: ["image", "prune", "-a", "-f"]) == nil)
        #expect(CommandPolicy.refusal(executable: "docker", arguments: ["container", "prune", "-f"]) == nil)
        #expect(CommandPolicy.refusal(executable: "docker", arguments: ["builder", "prune", "-a", "-f"]) == nil)
        #expect(CommandPolicy.refusal(executable: "docker", arguments: ["network", "prune", "-f"]) == nil)
        #expect(CommandPolicy.refusal(executable: "/usr/bin/xcrun", arguments: ["simctl", "delete\n", "x"])
            == "Invalid command.")
        #expect(CommandPolicy.refusal(executable: "uv", arguments: ["cache", "clean\u{0}"]) == "Invalid command.")
        #expect(CommandPolicy.refusal(executable: "uv", arguments: ["cache", "clean"]) == nil)
    }

    @Test func executorNeverRunsAVolumeCommandEvenFromCatalog() async throws {
        let rogue = CatalogEntry(
            id: "docker-builder", title: "Prueba", explanation: "", whoCreatesIt: "Docker", regenerates: true,
            risk: .safe, kind: .containers, paths: [],
            cleanup: .command(executable: "docker", arguments: ["builder", "prune", "--volumes"], sizeProbe: nil),
            discovery: .docker)
        let fake = runner(runningOutputs())
        let item = CleanupItem(id: rogue.id, entry: rogue, paths: [], bytes: 1, risk: .safe, blockedByOpenApps: [],
                               usedBy: [])
        let outcome = await executor(fake, catalog: Catalog(entries: [rogue])).execute(item)
        #expect(outcome == .blocked(reason: "Airy never deletes Docker volumes."))
        #expect(fake.calls.isEmpty)
    }

    @Test func bundledCatalogPassesCommandPolicy() throws {
        for entry in try Catalog.bundled().entries {
            guard case .command(let executable, let arguments, let probe) = entry.cleanup else { continue }
            #expect(CommandPolicy.refusal(executable: executable, arguments: arguments) == nil, "\(entry.id)")
            #expect(!(arguments + (probe ?? [])).contains { $0.lowercased().contains("volume") }, "\(entry.id)")
        }
    }

    @Test func aggressiveVsPrudentDockerRisks() async throws {
        let catalog = try Catalog.bundled()
        let aggressive = Dictionary(uniqueKeysWithValues: await scan(runner(runningOutputs()), catalog: catalog)
            .map { ($0.id, $0) })
        #expect(aggressive["docker-build-cache"]?.risk == .safe)
        #expect(aggressive["docker-images"]?.risk == .safe)
        #expect(aggressive["docker-containers"]?.risk == .yourCall)
        #expect(aggressive["docker-containers"]?.preselected == true)
        #expect(aggressive["docker-networks"]?.risk == .safe)
        #expect(aggressive["docker-volumes"]?.risk == .doNotTouch)
        #expect(aggressive["docker-volumes"]?.preselected == false)

        var prudentSettings = AirySettings()
        prudentSettings.mode = .prudent
        let prudent = await scan(runner(runningOutputs()), catalog: catalog, settings: prudentSettings)
        #expect(prudent.first { $0.id == "docker-images" }?.risk == .yourCall)
        #expect(!prudent.contains { $0.risk == .yourCall && $0.preselected })

        for entry in dockerEntries(catalog) {
            #expect(entry.profiles == [.developer], "\(entry.id)")
            #expect(entry.shortReason != nil, "\(entry.id)")
        }
        #expect(catalog.entry(id: "docker-images")?.regenerates == true)
        // It warns that every unused image goes and they have to be downloaded or built again.
        #expect(catalog.entry(id: "docker-images")?.shortReason?.contains("every image") == true)
    }
}
