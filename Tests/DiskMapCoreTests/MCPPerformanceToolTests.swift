import Foundation
import Synchronization
import Testing
@testable import DiskMapCore

/// Opens nothing: it only records the URLs (F9: specific to this file).
private final class QuitRecordingOpener: URLOpening, Sendable {
    private let state = Mutex<[URL]>([])
    let succeeds: Bool
    init(succeeds: Bool = true) { self.succeeds = succeeds }
    var urls: [URL] { state.withLock { $0 } }
    func open(_ url: URL) async -> Bool {
        state.withLock { $0.append(url) }
        return succeeds
    }
}

private let me = getuid()
private let mb: Int64 = 1 << 20

/// Spotify, Finder, Airy, a loose airy-mcp and two loose `node` processes (one large); all of the current user.
private func sampleRaw(_ n: Int = 0) -> RawSample {
    let spotifyApp = "/Applications/Spotify.app", finderApp = "/System/Library/CoreServices/Finder.app"
    let airyApp = "/Applications/Airy.app"
    let processes = [
        OwnProcess(pid: 1000, uid: me, name: "Spotify", executablePath: spotifyApp + "/Contents/MacOS/Spotify",
                   footprint: 400 * mb),
        OwnProcess(pid: 1001, uid: me, name: "Finder", executablePath: finderApp + "/Contents/MacOS/Finder",
                   footprint: 100 * mb),
        OwnProcess(pid: 1002, uid: me, name: "Airy", executablePath: airyApp + "/Contents/MacOS/Airy", footprint: 50 * mb),
        OwnProcess(pid: 1003, uid: me, name: "airy-mcp", executablePath: "/Users/x/bin/airy-mcp", footprint: 5 * mb),
        OwnProcess(pid: 1004, uid: me, name: "node", executablePath: "/opt/homebrew/bin/node", footprint: 30 * mb,
                   workingDirectory: "/Users/x/proyecto-secreto"),
        OwnProcess(pid: 1005, uid: me, name: "node", executablePath: "/opt/homebrew/bin/node", footprint: 300 * mb,
                   workingDirectory: "/Users/x/otro"),
    ]
    let apps = [
        RunningAppInfo(pid: 1000, bundleID: "com.spotify.client", name: "Spotify", bundlePath: spotifyApp, policy: .regular),
        RunningAppInfo(pid: 1001, bundleID: "com.apple.finder", name: "Finder", bundlePath: finderApp, policy: .regular),
        RunningAppInfo(pid: 1002, bundleID: "local.airy.Airy", name: "Airy", bundlePath: airyApp, policy: .regular),
    ]
    let memory = MemoryStats(total: 16 << 30, used: 15 << 30, fileCache: 1 << 29, free: 1 << 28,
                             pressure: .critical, swapUsed: 3 << 30, swapTotal: 4 << 30)
    return RawSample(date: Date(timeIntervalSince1970: 1_000 + Double(n)), uptimeNs: UInt64(n + 1) * 1_000_000_000,
                     memory: memory,
                     cores: Array(repeating: CoreTicks(user: 0, system: 0, idle: 0), count: 4),
                     processes: processes, apps: apps)
}

private struct PerfFixture {
    let env: AiryEnvironment
    let opener: QuitRecordingOpener
    let sampler: FakeSampler
    var context: MCPCallContext { MCPCallContext(environment: env, client: "test-client") }
    func records() -> [OperationRecord] { (try? env.log.records()) ?? [] }
    func call(_ arguments: [String: JSONValue]) async -> MCPToolResult {
        await ProposeQuitAppTool().call(arguments, context: context)
    }
    func performance() async -> MCPToolResult {
        await GetPerformanceTool(interval: .milliseconds(1)).call([:], context: context)
    }
}

private func makePerfFixture(opener: QuitRecordingOpener = QuitRecordingOpener()) -> PerfFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("airy-perf-\(UUID().uuidString)")
    let home = root.appendingPathComponent("home", isDirectory: true).path
    try! FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    let paths = AppPaths(support: root.appendingPathComponent("support", isDirectory: true), legacySupport: nil)
    let sampler = FakeSampler([sampleRaw(0), sampleRaw(1)])
    let env = AiryEnvironment(
        home: home, paths: paths, catalog: Catalog(entries: []), catalogError: nil,
        settings: SettingsStore(file: paths.settingsFile), index: IndexStore(directory: paths.support),
        log: OperationLog(file: paths.operationsFile), runner: FakeRunner(), probes: FakeProbes(),
        processGuard: ProcessGuard(), references: ReferenceChecker(roots: []), urlOpener: opener,
        capacity: { nil }, sampler: sampler, appCatalog: nil)
    return PerfFixture(env: env, opener: opener, sampler: sampler)
}

@Suite struct MCPPerformanceToolTests {
    @Test func getPerformanceSamplesItselfAndReportsHealth() async {
        let f = makePerfFixture()
        let result = await f.performance()
        #expect(!result.isError)
        #expect(f.sampler.calls == 2)
        // The same verdict the monitor gives with those two samples.
        let monitor = PerformanceMonitor(sampler: FakeSampler([sampleRaw(0), sampleRaw(1)]), grouper: { raw, cpu, energy in
            AppGrouper.group(raw, cpu: cpu, energy: energy, catalog: nil)
        })
        _ = await monitor.refresh(); _ = await monitor.refresh()
        let expected = await monitor.verdict(probes: nil)
        #expect(expected.findings.contains { $0.id == "memory" })
        #expect(result.structured?["health"]?["sentence"] == .string(expected.sentence))
        #expect(result.structured?["health"]?["light"] == .string(GetPerformanceTool.light(expected.level)))
        #expect(result.text.hasPrefix(expected.sentence))
        #expect(result.structured?["memory"]?["total_bytes"] == .number(Double(16 << 30)))
        #expect(result.structured?["memory"]?["available_bytes"] == .number(Double((1 << 29) + (1 << 28))))
        #expect(result.structured?["memory"]?["pressure"] == .string("critical"))
        #expect(result.structured?["thermal"]?["label"] == .string("Normal"))
        #expect(f.records().isEmpty)
        #expect(f.opener.urls.isEmpty)
    }

    @Test func getPerformanceNeverLeaksPathsOrArgs() async {
        let f = makePerfFixture()
        let result = await f.performance()
        let json = result.structured?.prettyString() ?? ""
        for leak in ["proyecto-secreto", "/opt/homebrew", "/Applications", "/Users/", "1000", "1004", "1005", "pid"] {
            #expect(!result.text.contains(leak), "\(leak)")
            #expect(!json.contains(leak), "\(leak)")
        }
    }

    @Test func getPerformanceMarksNeverClosable() async throws {
        let f = makePerfFixture()
        let result = await f.performance()
        guard case .array(let top)? = result.structured?["top_by_memory"] else {
            Issue.record("no top_by_memory"); return
        }
        #expect(top.count == 5)
        func row(_ name: String) -> JSONValue? { top.first { $0["name"] == .string(name) } }
        #expect(row("Finder")?["closable"] == .bool(false) && row("Finder")?["risk"] == .null)
        #expect(row("Spotify")?["closable"] == .bool(true) && row("Spotify")?["risk"] == .string("safe"))
        #expect(row("Spotify")?["bundle_id"] == .string("com.spotify.client"))
        #expect(row("node")?["risk"] == .string("yourCall"))
        #expect(row("Airy")?["closable"] == .bool(false))
    }

    @Test func getPerformanceWorksWithToggleOff() async throws {
        let f = makePerfFixture()
        var off = AirySettings()
        off.agentsEnabled = false
        try f.env.settings.save(off)
        let result = await f.performance()
        #expect(!result.isError)
        #expect(result.structured?["health"]?["sentence"] != nil)
        #expect(GetPerformanceTool().annotations == MCPToolAnnotations(readOnly: true, destructive: false, idempotent: true))
    }

    @Test func proposeQuitOpensURLAndNeverQuits() async {
        let f = makePerfFixture()
        let result = await f.call(["app": .string("com.spotify.client"), "reason": .string("pesa")])
        #expect(!result.isError, "\(result.text)")
        #expect(f.opener.urls == [URL(string: "airy://quit?app=com.spotify.client&reason=pesa&agent=test-client")!])
        #expect(result.structured?["status"] == .string("pending_user_confirmation"))
        #expect(result.structured?["risk"] == .string("safe"))
        #expect(result.structured?["app"] == .string("Spotify"))
        #expect(result.structured?["message"]
                == .string("Proposal sent to Airy; the user decides whether to quit it. Airy never quits apps on its own."))
        #expect(f.sampler.calls == 1)
        let records = f.records()
        #expect(records.count == 1)
        #expect(records.first?.action == "propose_quit" && records.first?.outcome == "pending_user")
        #expect(records.first?.actor == .agent(client: "test-client"))
        // The tool has no terminator at all: there is no path through which it could quit anything.
        #expect(!result.text.contains("1000") && !result.text.contains("/Applications"))
    }

    @Test func proposeQuitRefusesNeverClosableUnknownAndToggleOff() async throws {
        let f = makePerfFixture()
        for app in ["Finder", "airy-mcp", "Airy", "NoExiste"] {
            let result = await f.call(["app": .string(app)])
            #expect(result.isError, "\(app)")
        }
        #expect(await f.call(["app": .string("NoExiste")]).text == "There is no open app called “NoExiste”.")
        #expect(await f.call(["app": .string("finder")]).text.hasPrefix("“Finder” cannot be quit from Airy: "))

        var off = AirySettings()
        off.agentsEnabled = false
        try f.env.settings.save(off)
        let toggled = await f.call(["app": .string("Spotify")])
        #expect(toggled.isError)
        #expect(toggled.text == "You have turned off agent actions in Airy (Settings › Agents).")

        try Data("{\"agentsEnabled\": tru".utf8).write(to: f.env.paths.settingsFile)
        let unreadable = await f.call(["app": .string("Spotify"), "dry_run": .bool(true)])
        #expect(unreadable.isError)
        #expect(unreadable.text == "Airy cannot read its settings; nothing runs until you check them in the app.")

        #expect(f.opener.urls.isEmpty)
        #expect(f.records().allSatisfy { $0.action == "propose_quit" && $0.outcome == "blocked" })
    }

    @Test func proposeQuitDryRunDoesNotOpen() async {
        let f = makePerfFixture()
        let result = await f.call(["app": .string("spotify"), "dry_run": .bool(true)])
        #expect(!result.isError)
        #expect(f.opener.urls.isEmpty)
        #expect(result.structured?["url"] == .string("airy://quit?app=com.spotify.client&agent=test-client"))
        #expect(f.records().first?.dryRun == true)
    }

    @Test func proposeQuitPicksBiggestOnAmbiguousName() async {
        let f = makePerfFixture()
        let result = await f.call(["app": .string("node"), "dry_run": .bool(true)])
        #expect(!result.isError)
        #expect(result.structured?["risk"] == .string("yourCall"))
        #expect(f.records().first?.bytes == 300 * mb)
        // Neither the working folder nor the PID go out to the agent.
        #expect(!result.text.contains("otro") && !result.text.contains("proyecto-secreto") && !result.text.contains("1005"))
    }

    @Test func proposeQuitReportsWhenAiryCannotOpen() async {
        let f = makePerfFixture(opener: QuitRecordingOpener(succeeds: false))
        let result = await f.call(["app": .string("Spotify")])
        #expect(result.isError && result.text == "Could not open Airy (is it installed in /Applications?).")
        #expect(f.records().first?.outcome == "failed")
    }
}
