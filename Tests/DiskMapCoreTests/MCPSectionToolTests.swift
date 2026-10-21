import Foundation
import Synchronization
import Testing
@testable import DiskMapCore

// MARK: - Literales (solo en este archivo, para leer mejor los argumentos)

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByBooleanLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

// MARK: - Dobles

private final class SectionOpener: URLOpening, Sendable {
    private let state = Mutex<[URL]>([])
    var urls: [URL] { state.withLock { $0 } }
    func open(_ url: URL) async -> Bool {
        state.withLock { $0.append(url) }
        return true
    }
}

private struct SectionAppUsage: AppUsageReading {
    var dates: [String: Date] = [:]
    func lastUsed(bundlePath: String) -> Date? { dates[bundlePath] }
}

private struct SectionFileUsage: FileUsageReading {
    func lastOpened(path: String) -> Date? { nil }
}

// MARK: - Fixture

private struct SectionFixture {
    let tmp: String
    var home: String { tmp + "/home" }
    let env: AiryEnvironment
    let opener: SectionOpener
    let runner: FakeRunner
    let quitter: FakeQuitter

    var context: MCPCallContext { MCPCallContext(environment: env, client: "test-client") }

    func call(_ tool: any MCPTool, _ arguments: [String: JSONValue] = [:]) async -> MCPToolResult {
        await tool.call(arguments, context: context)
    }

    func records() -> [OperationRecord] { (try? env.log.records()) ?? [] }
}

private func makeApp(_ path: String, id: String, name: String) {
    let plist = path + "/Contents/Info.plist"
    try! FileManager.default.createDirectory(atPath: (plist as NSString).deletingLastPathComponent,
                                             withIntermediateDirectories: true)
    let data = try! PropertyListSerialization.data(
        fromPropertyList: ["CFBundleIdentifier": id, "CFBundleName": name, "CFBundleShortVersionString": "1.0"],
        format: .xml, options: 0)
    try! data.write(to: URL(fileURLWithPath: plist))
}

private func write(_ path: String, bytes: Int = 4096) {
    try! FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                             withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: path, contents: Data(repeating: 7, count: bytes))
}

/// Home temporal con `~/Applications` (Foo, Bar) y un `/System/Applications` falso con Safari.
private func makeSectionFixture(agents: Bool = true, extraRoots: [String] = [],
                                lookup: FakeLookup = FakeLookup()) -> SectionFixture {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("airy-sec-\(UUID().uuidString)").path
    let home = tmp + "/home"
    makeApp(home + "/Applications/Foo.app", id: "com.example.foo", name: "Foo")
    write(home + "/Applications/Foo.app/Contents/MacOS/foo", bytes: 300_000)
    makeApp(home + "/Applications/Bar.app", id: "com.example.bar", name: "Bar")
    makeApp(tmp + "/System/Applications/Safari.app", id: "com.apple.Safari", name: "Safari")
    let paths = AppPaths(support: URL(fileURLWithPath: tmp + "/support", isDirectory: true), legacySupport: nil)
    let settings = SettingsStore(file: paths.settingsFile)
    if !agents {
        var s = AirySettings()
        s.agentsEnabled = false
        try! settings.save(s)
    }
    let opener = SectionOpener(), runner = FakeRunner(), quitter = FakeQuitter()
    let old = Date(timeIntervalSinceNow: -400 * 86_400)
    let env = AiryEnvironment(
        home: home, paths: paths, catalog: Catalog(entries: []), catalogError: nil, settings: settings,
        index: IndexStore(directory: paths.support), log: OperationLog(file: paths.operationsFile), runner: runner,
        probes: FakeProbes(), processGuard: ProcessGuard(), references: ReferenceChecker(roots: []),
        urlOpener: opener, capacity: { VolumeCapacity(total: 1000, available: 500, importantAvailable: 400) },
        appRoots: [home + "/Applications", tmp + "/System/Applications"] + extraRoots,
        usage: SectionAppUsage(dates: [home + "/Applications/Bar.app": old]), bundleLookup: lookup,
        runningApps: quitter, fileUsage: SectionFileUsage())
    return SectionFixture(tmp: tmp, env: env, opener: opener, runner: runner, quitter: quitter)
}

private func names(_ result: MCPToolResult) -> [String] {
    guard case .array(let apps)? = result.structured?["apps"] else { return [] }
    return apps.compactMap { $0["name"]?.stringValue }
}

// MARK: - Pruebas

@Suite struct MCPSectionToolTests {
    @Test func listAppsIsReadOnlyAndSorted() async {
        let f = makeSectionFixture()
        defer { try? FileManager.default.removeItem(atPath: f.tmp) }
        #expect(ListAppsTool().annotations.readOnly && !ListAppsTool().annotations.destructive)
        let bySize = await f.call(ListAppsTool())
        #expect(!bySize.isError)
        #expect(names(bySize) == ["Foo", "Bar"])
        #expect(names(await f.call(ListAppsTool(), ["sort": "name"])) == ["Bar", "Foo"])
        #expect(names(await f.call(ListAppsTool(), ["sort": "last_used"])) == ["Bar", "Foo"])
        #expect(names(await f.call(ListAppsTool(), ["limit": 1])) == ["Foo"])
        guard case .array(let apps)? = bySize.structured?["apps"], let foo = apps.first else {
            Issue.record("sin apps"); return
        }
        #expect(foo["bundle_id"] == "com.example.foo")
        #expect(foo["can_uninstall"] == .bool(true))
        #expect(foo["source"] == "other")
        #expect(foo["running"] == .bool(false))
        #expect(f.quitter.calls.isEmpty)
    }

    @Test func explainAppGivesPlanWithRisks() async {
        let f = makeSectionFixture()
        defer { try? FileManager.default.removeItem(atPath: f.tmp) }
        write(f.home + "/Library/Caches/com.example.foo/blob", bytes: 5000)
        write(f.home + "/Library/Application Support/com.example.foo/data", bytes: 3000)
        let result = await f.call(ExplainAppTool(), ["bundle_id": "com.example.foo"])
        #expect(!result.isError)
        guard case .array(let leftovers)? = result.structured?["leftovers"] else { Issue.record("sin restos"); return }
        let labels = Set(leftovers.compactMap { $0["risk_label"]?.stringValue })
        #expect(labels.contains("Sin problema"))
        #expect(labels.contains("Tú decides"))
        #expect(leftovers.allSatisfy { $0["preselected"] != nil && $0["reason"] != nil && $0["risk"] != nil })
        #expect(result.structured?["real_bytes"] != nil && result.structured?["leftover_bytes"] != nil)
    }

    @Test func explainUnknownAppIsError() async {
        let f = makeSectionFixture()
        defer { try? FileManager.default.removeItem(atPath: f.tmp) }
        let result = await f.call(ExplainAppTool(), ["bundle_id": "com.example.nada"])
        #expect(result.isError)
        #expect(result.text == "No hay ninguna app instalada con ese identificador.")
    }

    @Test func listOrphansUndecidedWhenIncomplete() async {
        // Una raíz que no es una carpeta: el inventario queda incompleto y no se decide nada.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("airy-sec-file-\(UUID().uuidString)").path
        FileManager.default.createFile(atPath: tmp, contents: Data([1]))
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let lookup = FakeLookup()
        let f = makeSectionFixture(extraRoots: [tmp], lookup: lookup)
        defer { try? FileManager.default.removeItem(atPath: f.tmp) }
        let result = await f.call(ListOrphansTool())
        #expect(!result.isError)
        #expect(result.structured?["decided"] == .bool(false))
        #expect(result.structured?["reason"]?.stringValue?.isEmpty == false)
        #expect(lookup.calls.isEmpty)
    }

    @Test func listLargeOldFromIndex() async throws {
        let f = makeSectionFixture()
        defer { try? FileManager.default.removeItem(atPath: f.tmp) }
        let old = Date(timeIntervalSinceNow: -700 * 86_400)
        var nodes: [FileNode] = []
        for (name, size, date) in [("viejo.mov", Int64(3_000_000_000), old), ("nuevo.mov", Int64(2_000_000_000), Date()),
                                   ("pequeño.mov", Int64(50_000_000), old)] {
            write(f.home + "/Movies/" + name, bytes: 1)
            nodes.append(FileNode(name: name, isDirectory: false, allocatedSize: size, lastModified: date, kind: .video))
        }
        let movies = FileNode(name: "Movies", isDirectory: true, children: nodes)
        let homeNode = FileNode(name: "home", isDirectory: true, children: [movies])
        let root = FileNode(name: f.tmp, isDirectory: true, children: [homeNode])
        try f.env.index.saveScan(ScanResult(root: root, inaccessible: [], duration: 1, scannedAt: Date()))

        func files(_ args: [String: JSONValue]) async -> [String] {
            let result = await f.call(ListLargeOldTool(), args)
            #expect(!result.isError, "\(result.text)")
            guard case .array(let files)? = result.structured?["files"] else { return [] }
            return files.compactMap { $0["name"]?.stringValue }
        }
        #expect(Set(await files([:])) == ["viejo.mov", "nuevo.mov"])
        #expect(await files(["older_than_months": 12]) == ["viejo.mov"])
        #expect(Set(await files(["min_bytes": 1_000_000])) == ["viejo.mov", "nuevo.mov", "pequeño.mov"])
        let one = await f.call(ListLargeOldTool(), ["limit": 1])
        if case .array(let rows)? = one.structured?["files"] {
            #expect(rows.count == 1)
            #expect(rows[0]["risk_label"] != nil && rows[0]["last_opened"] != nil)
        }
    }

    @Test func listLargeOldWithoutIndex() async {
        let f = makeSectionFixture()
        defer { try? FileManager.default.removeItem(atPath: f.tmp) }
        let result = await f.call(ListLargeOldTool())
        #expect(result.isError && result.text == "Aún no hay análisis guardado. Abre Airy o usa rescan.")
    }

    @Test func listDuplicatesWithoutReport() async {
        let f = makeSectionFixture()
        defer { try? FileManager.default.removeItem(atPath: f.tmp) }
        let result = await f.call(ListDuplicatesTool())
        #expect(result.isError)
        #expect(result.text == "Aún no hay búsqueda de duplicados. Búscalos en Airy › Duplicados.")
    }

    @Test func listDuplicatesNeverExposesHashes() async throws {
        let f = makeSectionFixture()
        defer { try? FileManager.default.removeItem(atPath: f.tmp) }
        // Una búsqueda real (con huellas en memoria) sobre dos copias idénticas.
        let a = f.home + "/a/x.bin", b = f.home + "/b/x.bin"
        write(a, bytes: 2_000_000)
        write(b, bytes: 2_000_000)
        let gate = PathGate(home: f.home, catalog: nil, userProtected: ProtectList(patterns: [], home: f.home))
        let finder = DuplicateFinder(home: f.home, classifier: RiskClassifier(catalog: Catalog(entries: []),
                                     settings: AirySettings(), home: f.home), gate: gate)
        let found = await finder.find(DuplicateSearch(roots: [f.home]), candidates: [a, b])
        #expect(found.groups.count == 1)
        try FileManager.default.createDirectory(at: f.env.paths.support, withIntermediateDirectories: true)
        try DuplicateReport.save(found, to: f.env.paths.duplicatesFile)

        let result = await f.call(ListDuplicatesTool())
        #expect(!result.isError)
        guard case .array(let groups)? = result.structured?["groups"] else { Issue.record("sin grupos"); return }
        #expect(groups.count == 1)
        #expect(groups[0]["copies"] != nil && groups[0]["keeper"] != nil)
        let hex = try Regex("[0-9a-fA-F]{64}")
        #expect(result.text.firstMatch(of: hex) == nil)
        #expect(result.structured!.prettyString().firstMatch(of: hex) == nil)
        let disk = try String(contentsOf: f.env.paths.duplicatesFile, encoding: .utf8)
        #expect(disk.firstMatch(of: hex) == nil)
    }

    @Test func proposeUninstallOpensURLOnly() async {
        let f = makeSectionFixture()
        defer { try? FileManager.default.removeItem(atPath: f.tmp) }
        let result = await f.call(ProposeUninstallTool(), ["bundle_id": "com.example.foo", "reason": "No la usas"])
        #expect(!result.isError, "\(result.text)")
        #expect(result.structured?["status"] == "pending_user_confirmation")
        #expect(f.opener.urls.count == 1)
        let url = f.opener.urls.first?.absoluteString ?? ""
        #expect(url.hasPrefix("airy://uninstall?bundle=com.example.foo&"))
        #expect(url.hasSuffix("&agent=test-client"))
        #expect(FileManager.default.fileExists(atPath: f.home + "/Applications/Foo.app"))
        #expect(f.quitter.calls.isEmpty)
        #expect(f.runner.calls.isEmpty)
        #expect(f.records().last?.outcome == "pending_user")
        #expect(f.records().last?.action == "propose")

        let dry = await f.call(ProposeUninstallTool(),
                               ["bundle_id": "com.example.foo", "reason": "No la usas", "dry_run": true])
        #expect(!dry.isError)
        #expect(f.opener.urls.count == 1)
    }

    @Test func proposeUninstallRespectsToggle() async {
        let f = makeSectionFixture(agents: false)
        defer { try? FileManager.default.removeItem(atPath: f.tmp) }
        for dry in [false, true] {
            let result = await f.call(ProposeUninstallTool(),
                                      ["bundle_id": "com.example.foo", "reason": "x", "dry_run": .bool(dry)])
            #expect(result.isError)
        }
        #expect(f.opener.urls.isEmpty)
    }

    @Test func proposeUninstallRejectsSystemApp() async {
        let f = makeSectionFixture()
        defer { try? FileManager.default.removeItem(atPath: f.tmp) }
        let result = await f.call(ProposeUninstallTool(), ["bundle_id": "com.apple.Safari", "reason": "x"])
        #expect(result.isError)
        #expect(result.text.contains("Es parte de macOS."))
        #expect(f.opener.urls.isEmpty)
        let unknown = await f.call(ProposeUninstallTool(), ["bundle_id": "com.example.nada", "reason": "x"])
        #expect(unknown.isError && unknown.text == "No hay ninguna app instalada con ese identificador.")
    }

    @Test func sectionToolsAcceptNoArbitraryCommands() {
        for tool in MCPToolRegistry.sectionTools() {
            guard case .object(let properties)? = tool.inputSchema["properties"] else {
                Issue.record("\(tool.name) sin properties"); continue
            }
            for forbidden in ["command", "args", "paths", "path"] { #expect(properties[forbidden] == nil, "\(tool.name)") }
            #expect(tool.inputSchema["additionalProperties"] == .bool(false))
            #expect(!tool.annotations.destructive)
            #expect(tool.annotations.readOnly == (tool.name != "propose_uninstall"))
        }
    }
}
