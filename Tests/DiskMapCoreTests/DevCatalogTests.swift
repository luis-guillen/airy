import Foundation
import Testing
@testable import DiskMapCore

/// Riesgo de catálogo de las 26 fichas de la fase 1 (las de `catalog.json` antes del plan 3). En modo
/// Prudente deben seguir dando exactamente este riesgo.
public enum Phase1Risks {
    public static let byID: [String: Risk] = [
        "docker-build-cache": .safe, "docker-volumes": .doNotTouch, "docker-images": .yourCall,
        "homebrew": .safe, "pip": .safe, "uv": .safe, "pnpm": .safe, "pnpm-cache": .safe, "npm": .safe,
        "cargo": .safe, "conda": .safe, "huggingface-model": .yourCall, "ollama-models": .yourCall,
        "whisper-cache": .yourCall, "playwright": .safe, "brave-cache": .safe, "chrome-cache": .safe,
        "safari-cache": .safe, "spotify-cache": .yourCall, "xcode-deriveddata": .safe, "xcode-simulators": .safe,
        "user-logs": .safe, "codex-stale-installs": .safe, "codex-runtime": .doNotTouch, "claude-vm": .yourCall,
        "time-machine-snapshots": .yourCall,
    ]
}

// MARK: - Utilidades

private let fakeHome = "/Users/ana"
private let xcrun = "/usr/bin/xcrun"

private func settings(_ mode: CleanupMode) -> AirySettings {
    var s = AirySettings()
    s.mode = mode
    return s
}

/// Rutas de muestra para los patrones de la ficha (como en `ClassifierTests`).
private func samplePaths(_ entry: CatalogEntry) -> [String] {
    entry.paths.map { p in
        (p.hasPrefix("~/") ? fakeHome + p.dropFirst() : p).replacingOccurrences(of: "*", with: "muestra")
    }
}

private func tempHome() -> String {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("airy-dev-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.path
}

/// Carpeta con un fichero de 4 KB dentro y fecha de modificación `age` segundos en el pasado.
private func makeFolder(_ path: String, age: TimeInterval = 0) {
    try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: path + "/datos", contents: Data(repeating: 1, count: 4096))
    let date = Date().addingTimeInterval(-age)
    try! FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path + "/datos")
    try! FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
}

private struct NoProcesses: ProcessListing {
    func processes() -> [RunningProcess]? { [] }
    func holders(ofPathsUnder paths: [String]) -> [RunningProcess]? { [] }
}

private func scan(_ runner: FakeRunner, home: String, catalog: Catalog) async -> [CleanupItem] {
    await CleanupScanner(
        catalog: catalog, runner: runner, probes: FakeProbes(), references: ReferenceChecker(roots: []), home: home,
        classifier: RiskClassifier(catalog: catalog, settings: .defaults, home: home), processListing: NoProcesses()
    ).findItems(scan: nil)
}

private func executor(_ runner: FakeRunner, home: String, catalog: Catalog) -> CleanupExecutor {
    CleanupExecutor(
        runner: runner, probes: FakeProbes(), store: IndexStore(directory: URL(fileURLWithPath: tempHome())),
        catalog: catalog, references: ReferenceChecker(roots: []), home: home, settings: { .missing },
        processGuard: ProcessGuard(listing: NoProcesses()), processListing: NoProcesses())
}

// Runtimes de simulador de prueba: R1 huérfano, R2 con un simulador, R3 no borrable.
private let r1 = "11111111-AAAA-4BBB-8CCC-111111111111"
private let r2 = "22222222-AAAA-4BBB-8CCC-222222222222"
private let r3 = "33333333-AAAA-4BBB-8CCC-333333333333"
private let ios17 = "com.apple.CoreSimulator.SimRuntime.iOS-17-0"
private let ios18 = "com.apple.CoreSimulator.SimRuntime.iOS-18-0"
private let watch10 = "com.apple.CoreSimulator.SimRuntime.watchOS-10-0"

private func runtimeJSON(_ r1Identifier: String = r1) -> String {
    """
    {
      "\(r1)": {"identifier": "\(r1Identifier)", "runtimeIdentifier": "\(ios17)",
                "platformIdentifier": "com.apple.platform.iphonesimulator", "version": "17.0",
                "sizeBytes": 7000000000, "deletable": true, "state": "Ready"},
      "\(r2)": {"identifier": "\(r2)", "runtimeIdentifier": "\(ios18)",
                "platformIdentifier": "com.apple.platform.iphonesimulator", "version": "18.0",
                "sizeBytes": 8000000000, "deletable": true},
      "\(r3)": {"identifier": "\(r3)", "runtimeIdentifier": "\(watch10)",
                "platformIdentifier": "com.apple.platform.watchsimulator", "version": "10.0",
                "sizeBytes": 3000000000, "deletable": false}
    }
    """
}

private func devicesJSON(inUse: [String] = [ios18]) -> String {
    let rows = inUse.map { "\"\($0)\": [{\"udid\": \"D-\($0)\", \"name\": \"iPhone\", \"isAvailable\": true}]" }
    return "{\"devices\": {\(rows.joined(separator: ", "))\(rows.isEmpty ? "" : ", ")\"\(watch10)\": []}}"
}

private func simctl(runtimes: String = runtimeJSON(), devices: String = devicesJSON()) -> FakeRunner {
    let ok = { (s: String) in CommandOutput(status: 0, stdout: s, stderr: "") }
    return FakeRunner(resolved: ["xcrun": xcrun], outputs: [
        "\(xcrun) simctl runtime list -j": ok(runtimes),
        "\(xcrun) simctl list devices -j": ok(devices),
    ])
}

// MARK: - Pruebas

@Suite struct DevCatalogTests {
    @Test func phase1EntriesKeepPhase1RiskInPrudent() throws {
        let catalog = try Catalog.bundled()
        let c = RiskClassifier(catalog: catalog, settings: settings(.prudent), home: fakeHome)
        #expect(Phase1Risks.byID.count == 26)
        for (id, risk) in Phase1Risks.byID {
            let entry = try #require(catalog.entry(id: id), "\(id)")
            #expect(entry.risk == risk, "\(id)")
            #expect(c.baseRisk(of: entry) == risk, "\(id)")
        }
    }

    @Test func prudentNeverPreselectsAmber() throws {
        let catalog = try Catalog.bundled()
        let c = RiskClassifier(catalog: catalog, settings: settings(.prudent), home: fakeHome)
        for entry in catalog.entries {
            let verdict = c.classify(entry: entry, paths: [])
            #expect(!(verdict.risk == .yourCall && verdict.preselected), "\(entry.id)")
            let withPaths = c.classify(entry: entry, paths: samplePaths(entry))
            #expect(!(withPaths.risk == .yourCall && withPaths.preselected), "\(entry.id)")
        }
    }

    /// Spec §2.5: clasificación en modo Agresivo (con rutas de muestra, así cuentan protecciones y suelos).
    @Test func aggressiveClassificationTable() throws {
        let catalog = try Catalog.bundled()
        let c = RiskClassifier(catalog: catalog, settings: settings(.aggressive), home: fakeHome)
        func verdict(_ id: String) throws -> Classification {
            let entry = try #require(catalog.entry(id: id), "\(id)")
            return c.classify(entry: entry, paths: samplePaths(entry))
        }
        for id in ["docker-build-cache", "docker-images", "docker-networks", "npm", "pnpm", "yarn", "bun", "uv", "pip",
                   "conda", "cargo", "homebrew", "xcode-deriveddata", "xcode-simulators", "xcode-device-support",
                   "go-mod-cache"] {
            let v = try verdict(id)
            #expect(v.risk == .safe, "\(id): \(v.risk)")
            #expect(v.preselected, "\(id)")
        }
        for id in ["docker-containers"] {
            let v = try verdict(id)
            #expect(v.risk == .yourCall && v.preselected, "\(id)")
        }
        for id in ["docker-volumes", "codex-runtime"] {
            let v = try verdict(id)
            #expect(v.risk == .doNotTouch && !v.preselected, "\(id)")
        }
        // Lo que no se regenera o tarda en volver se queda en ámbar sin marcar.
        for id in ["gradle-caches", "jetbrains-caches", "xcode-orphan-runtimes", "xcode-archives"] {
            let v = try verdict(id)
            #expect(v.risk == .yourCall && !v.preselected, "\(id)")
        }
    }

    @Test func catalogLint() throws {
        let catalog = try Catalog.bundled()
        var seen = Set<String>()
        for e in catalog.entries {
            #expect(seen.insert(e.id).inserted, "id repetido: \(e.id)")
            if let aggressive = e.aggressiveRisk, aggressive < e.risk {
                #expect(e.regenerates && e.risk != .doNotTouch, "\(e.id): baja en Agresivo sin regenerarse")
            }
            if let rule = e.retention { #expect(rule.keepNewest >= 1, "\(e.id)") }
            if Phase1Risks.byID[e.id] == nil { #expect(e.shortReason != nil, "\(e.id) sin shortReason") }
            if case .info = e.cleanup, e.risk != .doNotTouch { #expect(e.reviewHint != nil, "\(e.id) sin reviewHint") }
            #expect(!e.paths.contains { $0.contains(CleanupMethod.targetPlaceholder) }, "\(e.id)")
            #expect(!e.paths.contains { $0.contains("{") || $0.contains("}") }, "\(e.id): llaves sin expandir")
            if case .command(let executable, let arguments, let probe) = e.cleanup {
                #expect(!executable.contains("/") && !executable.isEmpty, "\(e.id)")
                #expect(arguments.filter { $0.contains(CleanupMethod.targetPlaceholder) }.count <= 1, "\(e.id)")
                #expect(arguments.allSatisfy { !$0.contains("{target}") || $0 == CleanupMethod.targetPlaceholder },
                        "\(e.id)")
                #expect(!(probe ?? []).contains { $0.contains(CleanupMethod.targetPlaceholder) }, "\(e.id)")
                if e.cleanup.usesTargets {
                    #expect(e.discovery != nil || !e.paths.isEmpty, "\(e.id): {target} sin objetivos")
                }
            }
        }
    }

    @Test func specCommandsAreExact() throws {
        let catalog = try Catalog.bundled()
        let expected: [String: (String, [String])] = [
            "npm": ("npm", ["cache", "clean", "--force"]),
            "pnpm": ("pnpm", ["store", "prune"]),
            "uv": ("uv", ["cache", "clean"]),
            "pip": ("pip3", ["cache", "purge"]),
            "conda": ("conda", ["clean", "--all", "-y"]),
            "homebrew": ("brew", ["cleanup", "--prune=all", "-s"]),
            "yarn": ("yarn", ["cache", "clean"]),
            "bun": ("bun", ["pm", "cache", "rm"]),
            "go-build-cache": ("go", ["clean", "-cache"]),
            "go-mod-cache": ("go", ["clean", "-modcache"]),
            "composer-cache": ("composer", ["clear-cache"]),
            "cocoapods-cache": ("pod", ["cache", "clean", "--all"]),
            "dart-pub-cache": ("dart", ["pub", "cache", "clean", "--force"]),
            "xcode-simulators": ("xcrun", ["simctl", "delete", "unavailable"]),
            "xcode-orphan-runtimes": ("xcrun", ["simctl", "runtime", "delete", "{target}"]),
        ]
        for (id, (executable, arguments)) in expected {
            let entry = try #require(catalog.entry(id: id), "\(id)")
            #expect(entry.cleanup == .command(executable: executable, arguments: arguments, sizeProbe: nil), "\(id)")
        }
        let cargo = try #require(catalog.entry(id: "cargo"))
        #expect(cargo.cleanup == .trash && cargo.paths == ["~/.cargo/registry", "~/.cargo/git"])
    }

    @Test func newEntriesMatchTheTable() throws {
        let catalog = try Catalog.bundled()
        // id: (riesgo, riesgo en Agresivo, se regenera, procesos)
        let table: [String: (Risk, Risk?, Bool, [String])] = [
            "yarn": (.safe, nil, true, ["yarn"]), "yarn-berry": (.safe, nil, true, ["yarn"]),
            "bun": (.safe, nil, true, ["bun"]), "corepack": (.safe, nil, true, ["corepack"]),
            "go-build-cache": (.safe, nil, true, ["go"]), "go-mod-cache": (.yourCall, .safe, true, ["go"]),
            "poetry-cache": (.safe, nil, true, ["poetry"]), "pyenv-cache": (.safe, nil, true, []),
            "bundler-cache": (.safe, nil, true, ["bundle", "bundler"]),
            "composer-cache": (.safe, nil, true, ["composer"]), "gradle-caches": (.yourCall, nil, true, ["gradle"]),
            "swiftpm-cache": (.safe, nil, true, ["swift-build", "swift-package"]),
            "cocoapods-cache": (.safe, nil, true, ["pod"]), "dart-pub-cache": (.yourCall, .safe, true, ["dart", "flutter"]),
            "electron-cache": (.safe, nil, true, []), "node-gyp-cache": (.safe, nil, true, []),
            "prisma-cache": (.safe, nil, true, []), "terraform-plugins": (.safe, nil, true, ["terraform"]),
            "expo-cache": (.safe, nil, true, ["expo"]), "android-build-cache": (.safe, nil, true, []),
            "jetbrains-caches": (.yourCall, nil, true, ["idea", "pycharm", "webstorm", "goland", "clion", "rider",
                                                         "phpstorm", "rubymine", "datagrip", "studio"]),
            "vscode-caches": (.safe, nil, true, []), "cursor-caches": (.safe, nil, true, []),
            "xcode-device-support": (.safe, nil, true, ["Xcode", "xcodebuild"]),
            "xcode-coresimulator-caches": (.safe, nil, true, ["Simulator", "xcodebuild"]),
            "xcode-test-devices": (.safe, nil, true, ["Xcode", "xcodebuild"]),
            "xcode-doc-cache": (.safe, nil, true, ["Xcode"]), "xcode-caches": (.safe, nil, true, ["Xcode"]),
            "xcode-orphan-runtimes": (.yourCall, nil, false, ["Simulator", "Xcode", "xcodebuild"]),
            "xcode-archives": (.yourCall, nil, false, []),
        ]
        for (id, row) in table {
            let e = try #require(catalog.entry(id: id), "\(id)")
            #expect(e.risk == row.0 && e.aggressiveRisk == row.1 && e.regenerates == row.2, "\(id)")
            #expect(e.processNames == row.3, "\(id)")
            #expect(e.profiles == [.developer], "\(id)")
        }
        let code = "~/Library/Application Support/Code/"
        #expect(catalog.entry(id: "vscode-caches")?.paths
            == ["Cache", "CachedData", "Code Cache", "GPUCache", "CachedExtensionVSIXs"].map { code + $0 })
        #expect(catalog.entry(id: "vscode-caches")?.mustBeClosed == ["com.microsoft.VSCode"])
        let cursor = "~/Library/Application Support/Cursor/"
        #expect(catalog.entry(id: "cursor-caches")?.paths
            == ["Cache", "CachedData", "Code Cache", "GPUCache", "CachedExtensionVSIXs"].map { cursor + $0 })
        #expect(catalog.entry(id: "cursor-caches")?.mustBeClosed == ["com.todesktop.230313mzl4w4u92"])
        #expect(catalog.entry(id: "xcode-device-support")?.paths == ["iOS", "watchOS", "tvOS", "visionOS"]
            .map { "~/Library/Developer/Xcode/\($0) DeviceSupport/*" })
        #expect(catalog.entry(id: "xcode-device-support")?.retention == RetentionRule(keepNewest: 2))
        #expect(catalog.entry(id: "xcode-orphan-runtimes")?.discovery == .simulatorRuntimes)
        #expect(catalog.entry(id: "xcode-archives")?.cleanup == .info)
        #expect(catalog.entry(id: "expo-cache")?.except == ["state.json"])
        #expect(catalog.entry(id: "gradle-caches")?.shortReason
            == "Gradle tarda en volver a bajarlo todo y lo que compilas sin conexión deja de funcionar.")
        #expect(catalog.entry(id: "xcode-archives")?.reviewHint
            == "Bórralos desde Xcode › Window › Organizer: ahí ves cuáles ya subiste.")
    }

    @Test func existingEntriesGainProfiles() throws {
        let catalog = try Catalog.bundled()
        let developer = ["npm", "pnpm", "pnpm-cache", "uv", "pip", "conda", "cargo", "homebrew", "xcode-deriveddata",
                         "xcode-simulators", "codex-stale-installs", "playwright"]
        for id in developer { #expect(catalog.entry(id: id)?.profiles == [.developer], "\(id)") }
        for id in ["huggingface-model", "ollama-models", "whisper-cache", "claude-vm"] {
            #expect(catalog.entry(id: id)?.profiles == [.localAI], "\(id)")
        }
        #expect(catalog.entry(id: "user-logs")?.profiles == [.basic])
        for id in developer + ["huggingface-model", "ollama-models", "whisper-cache", "claude-vm", "user-logs"] {
            #expect(catalog.entry(id: id)?.shortReason != nil, "\(id)")
        }
    }

    @Test func deviceSupportKeepsTwoNewest() async throws {
        let home = tempHome()
        let base = home + "/Library/Developer/Xcode/iOS DeviceSupport"
        makeFolder(base + "/15.0", age: 300 * 86_400)
        makeFolder(base + "/16.0", age: 200 * 86_400)
        makeFolder(base + "/17.0", age: 100 * 86_400)
        let items = await scan(FakeRunner(), home: home, catalog: try Catalog.bundled())
        let item = try #require(items.first { $0.id == "xcode-device-support" })
        #expect(item.paths == [base + "/15.0"])
        #expect(item.details == ["Se conservan: 17.0, 16.0"])
        #expect(item.risk == .safe)
        #expect(item.bytes > 0)
    }

    @Test func orphanRuntimeBecomesTargetedCommand() async throws {
        let catalog = try Catalog.bundled()
        let home = tempHome()
        let items = await scan(simctl(), home: home, catalog: catalog)
        let runtimes = items.filter { $0.entry.id == "xcode-orphan-runtimes" }
        #expect(runtimes.count == 1)
        let item = try #require(runtimes.first)
        #expect(item.id == "xcode-orphan-runtimes:iOS 17.0")
        #expect(item.targets == [r1])
        #expect(item.paths.isEmpty)
        #expect(item.bytes == 7_000_000_000)
        #expect(item.risk == .yourCall && !item.preselected)
        #expect(item.blockedReason == nil)

        let act = simctl()
        guard case .freed = await executor(act, home: home, catalog: catalog).execute(item) else {
            Issue.record("esperaba .freed"); return
        }
        #expect(act.calls.last?.executable == xcrun)
        #expect(act.calls.last?.arguments == ["simctl", "runtime", "delete", r1])
        #expect(act.calls.filter { $0.arguments.contains("delete") }.count == 1)
    }

    @Test func runtimeWithNewDeviceIsRefusedAtAct() async throws {
        let catalog = try Catalog.bundled()
        let home = tempHome()
        let item = try #require(await scan(simctl(), home: home, catalog: catalog)
            .first { $0.entry.id == "xcode-orphan-runtimes" })
        let later = simctl(devices: devicesJSON(inUse: [ios17, ios18]))
        let outcome = await executor(later, home: home, catalog: catalog).execute(item)
        #expect(outcome == .blocked(reason: "Ese runtime ya tiene simuladores o ya no está."))
        #expect(!later.calls.contains { $0.arguments.contains("delete") })

        // Ya no aparece en la lista (lo borró Xcode) ⇒ también se rechaza.
        let gone = simctl(runtimes: "{}")
        #expect(await executor(gone, home: home, catalog: catalog).execute(item)
            == .blocked(reason: "Ese runtime ya tiene simuladores o ya no está."))
        #expect(!gone.calls.contains { $0.arguments.contains("delete") })
    }

    @Test func malformedRuntimeIDIsDropped() async throws {
        let items = await scan(simctl(runtimes: runtimeJSON("x; rm -rf ~")), home: tempHome(),
                               catalog: try Catalog.bundled())
        #expect(!items.contains { $0.entry.id == "xcode-orphan-runtimes" })
    }

    @Test func failedOrMalformedProbesYieldNothing() async throws {
        let source = SimulatorRuntimeSource()
        let entry = try #require(try Catalog.bundled().entry(id: "xcode-orphan-runtimes"))
        func discover(_ runner: FakeRunner) async -> [DiscoveredTarget] {
            await source.discover(entry, context: DiscoveryContext(
                catalog: Catalog(entries: [entry]), home: tempHome(), runner: runner, processListing: NoProcesses(),
                now: Date(), scan: nil))
        }
        #expect(await discover(FakeRunner()).isEmpty) // sin xcrun
        #expect(await discover(simctl(runtimes: "no es JSON")).isEmpty)
        #expect(await discover(simctl(devices: "[]")).isEmpty)
        let failing = FakeRunner(resolved: ["xcrun": xcrun], outputs: [
            "\(xcrun) simctl runtime list -j": CommandOutput(status: 1, stdout: runtimeJSON(), stderr: "error"),
            "\(xcrun) simctl list devices -j": CommandOutput(status: 0, stdout: devicesJSON(), stderr: ""),
        ])
        #expect(await discover(failing).isEmpty)
        // Las sondas son exactamente estas dos, y nunca se borra nada al detectar.
        let probe = simctl()
        let found = await discover(probe)
        #expect(found.map(\.idSuffix) == ["iOS 17.0"])
        #expect(Set(probe.calls.map(\.arguments)) == [["simctl", "runtime", "list", "-j"],
                                                       ["simctl", "list", "devices", "-j"]])
    }

    @Test func expoKeepsStateJSON() async throws {
        let home = tempHome()
        makeFolder(home + "/.expo/cache")
        makeFolder(home + "/.expo/versions-cache")
        FileManager.default.createFile(atPath: home + "/.expo/state.json", contents: Data(repeating: 2, count: 4096))
        let item = try #require(await scan(FakeRunner(), home: home, catalog: try Catalog.bundled())
            .first { $0.id == "expo-cache" })
        #expect(item.paths == [home + "/.expo/cache", home + "/.expo/versions-cache"])
        #expect(!item.paths.contains { $0.hasSuffix("state.json") })
    }
}
