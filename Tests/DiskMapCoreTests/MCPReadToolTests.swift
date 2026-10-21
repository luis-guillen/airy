import Foundation
import Testing
@testable import DiskMapCore

// MARK: - Helpers

private struct ReadFixture {
    let home: String
    let env: AiryEnvironment

    var context: MCPCallContext { MCPCallContext(environment: env, client: "test") }

    func call(_ tool: any MCPTool, _ arguments: [String: JSONValue] = [:]) async -> MCPToolResult {
        await tool.call(arguments, context: context)
    }

    func saveScan(_ root: FileNode, inaccessible: [String] = []) throws {
        try env.index.saveScan(ScanResult(root: root, inaccessible: inaccessible, duration: 1, scannedAt: Date()))
    }
}

private func fixture(entries: [CatalogEntry] = [], protected: [String] = []) throws -> ReadFixture {
    let url = TestTemp.url("airy-read")
    let home = url.appendingPathComponent("home", isDirectory: true).path
    try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    let support = url.appendingPathComponent("support", isDirectory: true)
    let paths = AppPaths(support: support, legacySupport: nil)
    let settings = SettingsStore(file: paths.settingsFile)
    if !protected.isEmpty {
        var s = AirySettings()
        for p in protected { _ = s.protect(p, home: home) }
        try settings.save(s)
    }
    let env = AiryEnvironment(
        home: home, paths: paths, catalog: Catalog(entries: entries), catalogError: nil,
        settings: settings, index: IndexStore(directory: support),
        log: OperationLog(file: paths.operationsFile), runner: FakeRunner(), probes: FakeProbes(),
        processGuard: ProcessGuard(), references: ReferenceChecker(roots: []), urlOpener: FakeOpener(),
        capacity: { VolumeCapacity(total: 1000, available: 500, importantAvailable: 400) })
    return ReadFixture(home: home, env: env)
}

private func entry(
    _ id: String, risk: Risk = .safe, paths: [String], title: String? = nil, regenerates: Bool = true
) -> CatalogEntry {
    CatalogEntry(
        id: id, title: title ?? "Entry \(id)", explanation: "Explanation of \(id).", whoCreatesIt: "Created by \(id).",
        regenerates: regenerates, risk: risk, kind: .caches, paths: paths, cleanup: .trash)
}

private func dir(_ name: String, _ size: Int64, kind: ContentKind = .other, children: [FileNode] = [],
                 aggregated: Int = 0) -> FileNode {
    FileNode(name: name, isDirectory: true, allocatedSize: size, lastModified: Date(timeIntervalSince1970: 1_700_000_000),
             kind: kind, children: children, aggregatedCount: aggregated)
}

private func file(_ name: String, _ size: Int64, kind: ContentKind = .other) -> FileNode {
    FileNode(name: name, isDirectory: false, allocatedSize: size, kind: kind)
}

private func kindBytes(_ pairs: [ContentKind: Int64]) -> [Int64] {
    ContentKind.allCases.map { pairs[$0] ?? 0 }
}

private func texts(_ result: MCPToolResult) -> String { result.text }

// MARK: - Tests

@Suite struct MCPReadToolTests {
    @Test func summaryWithoutIndex() async throws {
        let f = try fixture()
        let result = await f.call(GetDiskSummaryTool())
        #expect(!result.isError)
        #expect(result.structured?["scan_available"]?.boolValue == false)
        #expect(result.text.contains("There is no saved scan yet. Open Airy or use rescan."))
    }

    @Test func summaryReportsKindsAndDate() async throws {
        let f = try fixture()
        let root = FileNode(
            name: "/Users/x", isDirectory: true, allocatedSize: 300,
            kind: .other, kindBytes: kindBytes([.video: 200, .caches: 100]), children: [file("a", 300)])
        try f.saveScan(root, inaccessible: ["/Users/x/Library/Mail"])
        let result = await f.call(GetDiskSummaryTool())
        let s = try #require(result.structured)
        #expect(s["scan_available"]?.boolValue == true)
        #expect(s["scan_complete"]?.boolValue == false)
        #expect(s["total_bytes"]?.intValue == 1000)
        #expect(s["free_bytes"]?.intValue == 500)
        #expect(s["purgeable_bytes"]?.intValue == 0)
        #expect(s["analyzed_bytes"]?.intValue == 300)
        #expect(s["full_disk_access"]?.boolValue == true)
        guard case .array(let kinds)? = s["by_kind"] else { Issue.record("by_kind"); return }
        #expect(kinds.first?["kind"]?.stringValue == "video")
        #expect(kinds.first?["title"]?.stringValue == "Video")
        #expect(kinds.first?["bytes"]?.intValue == 200)
        #expect(kinds.count == 2)
        let date = try #require(s["last_scan"]?.stringValue)
        #expect(ISO8601DateFormatter().date(from: date) != nil)
        #expect(GetDiskSummaryTool().description.contains("the agent's process"))
    }

    @Test func listLargestAndSummaryReportPartial() async throws {
        let f = try fixture()
        let root = dir("/Users/x", 300, children: [
            dir("Library", 200, children: [dir("Mail", 100)]), dir("Documents", 100),
        ])
        try f.saveScan(root, inaccessible: ["/Users/x/Library/Mail/Sub"])
        let summary = await f.call(GetDiskSummaryTool())
        #expect(summary.structured?["scan_status"]?.stringValue == "partial")
        let largest = await f.call(ListLargestTool(), ["path": .string("/Users/x")])
        guard case .array(let rows)? = largest.structured?["children"] else { Issue.record("children"); return }
        let byName = Dictionary(uniqueKeysWithValues: rows.map { ($0["name"]!.stringValue!, $0) })
        #expect(byName["Library"]?["size_partial"]?.boolValue == true)
        #expect(byName["Documents"]?["size_partial"]?.boolValue == false)
        let clean = try fixture()
        try clean.saveScan(dir("/Users/x", 10, children: [file("a", 10)]))
        #expect(await clean.call(GetDiskSummaryTool()).structured?["scan_status"]?.stringValue == "complete")
    }

    @Test func summaryScanCompleteWhenNothingInaccessible() async throws {
        let f = try fixture()
        try f.saveScan(dir("/Users/x", 10, children: [file("a", 10)]))
        let result = await f.call(GetDiskSummaryTool())
        #expect(result.structured?["scan_complete"]?.boolValue == true)
    }

    private func sampleIndex(_ f: ReadFixture) throws {
        let root = dir("/Users/x", 600, children: [
            dir("small", 100, children: [file("s", 100)]), file("big.bin", 300), dir("mid", 200),
        ])
        try f.saveScan(root)
    }

    @Test func listLargestSortsAndLimits() async throws {
        let f = try fixture()
        try sampleIndex(f)
        let result = await f.call(ListLargestTool(), ["path": .string("/Users/x"), "limit": .number(2)])
        #expect(!result.isError)
        guard case .array(let children)? = result.structured?["children"] else { Issue.record("children"); return }
        #expect(children.count == 2)
        #expect(children.map { $0["name"]?.stringValue } == ["big.bin", "mid"])
        #expect(children.first?["path"]?.stringValue == "/Users/x/big.bin")
        #expect(children.first?["risk"]?.stringValue != nil)
        #expect(children.first?["is_directory"]?.boolValue == false)
    }

    @Test func listLargestShowsAggregatedOthers() async throws {
        let f = try fixture()
        let root = dir("/Users/x", 500, children: [
            file("a", 300), FileNode(name: "Otros (40 elementos)", isDirectory: false, allocatedSize: 200, aggregatedCount: 40),
        ])
        try f.saveScan(root)
        let result = await f.call(ListLargestTool(), ["path": .string("/Users/x")])
        guard case .array(let children)? = result.structured?["children"] else { Issue.record("children"); return }
        let others = try #require(children.last)
        #expect(others["name"]?.stringValue == "Other")
        #expect(others["aggregated_count"]?.intValue == 40)
        #expect(others["path"] == .null)
        #expect(others["bytes"]?.intValue == 200)
    }

    @Test func listLargestCapsLimitAndRejectsUnknownPath() async throws {
        let f = try fixture()
        try sampleIndex(f)
        let schema = ListLargestTool().inputSchema
        #expect(MCPSchemaValidator.violation(of: .object(["limit": .number(500)]), against: schema) != nil)
        #expect(MCPSchemaValidator.violation(of: .object(["limit": .number(0)]), against: schema) != nil)
        // Straight to the tool: it rejects too.
        let capped = await f.call(ListLargestTool(), ["path": .string("/Users/x"), "limit": .number(500)])
        #expect(capped.isError)
        let missing = await f.call(ListLargestTool(), ["path": .string("/Users/x/nope")])
        #expect(missing.isError)
        #expect(missing.text == "That folder is not in the last scan.")
        let relative = await f.call(ListLargestTool(), ["path": .string("relativa/ruta")])
        #expect(relative.isError)
    }

    @Test func listLargestExpandsTilde() async throws {
        let f = try fixture()
        let root = dir(f.home, 100, children: [dir("Downloads", 100, children: [file("x", 100)])])
        try f.saveScan(root)
        let result = await f.call(ListLargestTool(), ["path": .string("~/Downloads")])
        #expect(!result.isError)
        #expect(result.structured?["path"]?.stringValue == f.home + "/Downloads")
    }

    @Test func explainKnownCatalogPath() async throws {
        let f = try fixture(entries: [entry("npm", paths: ["~/.npm/_cacache"], title: "npm cache")])
        let result = await f.call(ExplainPathTool(), ["path": .string(f.home + "/.npm/_cacache")])
        let s = try #require(result.structured)
        #expect(s["known"]?.boolValue == true)
        #expect(s["title"]?.stringValue == "npm cache")
        #expect(s["explanation"]?.stringValue == "Explanation of npm.")
        #expect(s["who_creates_it"]?.stringValue == "Created by npm.")
        #expect(s["regenerates"]?.boolValue == true)
        #expect(s["risk"]?.stringValue == "safe")
        #expect(s["exists"]?.boolValue == false)
        #expect(s["size_bytes"] == .null)
    }

    @Test func explainPersonalPathIsYourCall() async throws {
        let f = try fixture()
        let result = await f.call(ExplainPathTool(), ["path": .string(f.home + "/Documents/x")])
        let s = try #require(result.structured)
        #expect(s["risk"]?.stringValue == "yourCall")
        #expect(s["risk_label"]?.stringValue == "Your call")
        #expect(s["protected_by"] == .null)
        #expect(s["known"]?.boolValue == false)
    }

    @Test func explainProtectedPathIsRed() async throws {
        let f = try fixture()
        let result = await f.call(ExplainPathTool(), ["path": .string(f.home + "/Library/Keychains")])
        let s = try #require(result.structured)
        #expect(s["risk"]?.stringValue == "doNotTouch")
        #expect(s["risk_label"]?.stringValue == "Don't delete")
        #expect(s["protected_by"]?.stringValue == "airy")
        guard case .array(let reasons)? = s["reasons"] else { Issue.record("reasons"); return }
        #expect(!reasons.isEmpty)
    }

    @Test func explainUserProtected() async throws {
        let f = try fixture(protected: ["~/Proyectos/secreto"])
        let result = await f.call(ExplainPathTool(), ["path": .string(f.home + "/Proyectos/secreto/app")])
        #expect(result.structured?["risk"]?.stringValue == "doNotTouch")
        #expect(result.structured?["protected_by"]?.stringValue == "user")
    }

    @Test func explainUsesIndexSizeAndLstat() async throws {
        let f = try fixture()
        let root = dir(f.home, 100, children: [dir("Downloads", 100, children: [file("x", 100)])])
        try f.saveScan(root)
        try FileManager.default.createDirectory(atPath: f.home + "/Downloads", withIntermediateDirectories: true)
        let result = await f.call(ExplainPathTool(), ["path": .string("~/Downloads")])
        #expect(result.structured?["size_bytes"]?.intValue == 100)
        #expect(result.structured?["exists"]?.boolValue == true)
        #expect(result.structured?["explanation"]?.stringValue == "What you have downloaded.")
        #expect(result.structured?["known"]?.boolValue == true)
    }

    private func cleanupFixture() throws -> ReadFixture {
        let f = try fixture(entries: [
            entry("alpha", risk: .safe, paths: ["~/Library/Caches/alpha"]),
            entry("beta", risk: .yourCall, paths: ["~/Library/Caches/beta"]),
            entry("gamma", risk: .safe, paths: ["~/Library/Caches/gamma"]),
        ])
        for (name, size) in [("alpha", 2000), ("beta", 3000), ("gamma", 9000)] {
            let folder = f.home + "/Library/Caches/" + name
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try Data(repeating: 65, count: size).write(to: URL(fileURLWithPath: folder + "/data.bin"))
        }
        return f
    }

    @Test func listCleanupItemsOrderedLikeBoard() async throws {
        let f = try cleanupFixture()
        let expected = CleanupBoard(items: await f.env.makeScanner()!.findItems(scan: nil)).displayItems.map(\.id)
        let result = await f.call(ListCleanupItemsTool())
        guard case .array(let items)? = result.structured?["items"] else { Issue.record("items"); return }
        #expect(items.compactMap { $0["id"]?.stringValue } == expected)
        #expect(expected.count == 3)
        #expect(result.structured?["mode"]?.stringValue == "aggressive")
        let first = try #require(items.first)
        #expect(first["method"]?.stringValue == "trash")
        #expect(first["command"] == .null)
        #expect(first["risk"]?.stringValue == "safe")
        #expect(first["title"]?.stringValue != nil)
        #expect(first["size_text"]?.stringValue != nil)
    }

    @Test func listCleanupItemsExplainsEachItem() async throws {
        let f = try cleanupFixture()
        let result = await f.call(ListCleanupItemsTool())
        guard case .array(let items)? = result.structured?["items"] else { Issue.record("items"); return }
        let byId = Dictionary(uniqueKeysWithValues: items.map { ($0["id"]!.stringValue!, $0) })
        let beta = try #require(byId["beta"])
        #expect(beta["verdict"]?.stringValue == "Your call")
        #expect(beta["review_only"]?.boolValue == false)
        #expect(beta["why"]?.stringValue?.hasPrefix("You lose what is inside") == true)
        #expect(byId["alpha"]?["verdict"]?.stringValue == "Safe to remove")
        #expect(byId["alpha"]?["why"]?.stringValue == "It recreates itself.")
        #expect(beta["details"] == .array([]) && beta["size_note"] == .null && beta["short_reason"] == .null)
    }

    @Test func listCleanupItemsMarksReviewOnlyAndExplainsRealEntries() async throws {
        var info = entry("revisar", risk: .yourCall, paths: ["~/Library/Caches/revisar"])
        info.cleanup = .info
        info.reviewHint = "Delete it yourself from the app."
        var images = entry("imagenes", risk: .yourCall, paths: ["~/Library/Caches/imagenes"])
        images.shortReason = "It deletes every unused image; you have to download them again."
        let f = try fixture(entries: [info, images, entry("alpha", risk: .safe, paths: ["~/Library/Caches/alpha"])])
        for name in ["revisar", "imagenes", "alpha"] {
            let folder = f.home + "/Library/Caches/" + name
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try Data(repeating: 65, count: 5000).write(to: URL(fileURLWithPath: folder + "/d"))
        }
        let result = await f.call(ListCleanupItemsTool())
        guard case .array(let items)? = result.structured?["items"] else { Issue.record("items"); return }
        let ids = items.compactMap { $0["id"]?.stringValue }
        #expect(ids.last == "revisar") // "Review only" at the end
        let byId = Dictionary(uniqueKeysWithValues: items.map { ($0["id"]!.stringValue!, $0) })
        #expect(byId["revisar"]?["review_only"]?.boolValue == true)
        #expect(byId["revisar"]?["actionable_by_agent"]?.boolValue == false)
        #expect(byId["revisar"]?["why"]?.stringValue == "Delete it yourself from the app.")
        #expect(byId["imagenes"]?["short_reason"]?.stringValue == images.shortReason)
        #expect(byId["imagenes"]?["why"]?.stringValue == images.shortReason)
    }

    @Test func yourCallIsNotActionableByAgent() async throws {
        let f = try cleanupFixture()
        let result = await f.call(ListCleanupItemsTool())
        guard case .array(let items)? = result.structured?["items"] else { Issue.record("items"); return }
        let byId = Dictionary(uniqueKeysWithValues: items.map { ($0["id"]!.stringValue!, $0) })
        #expect(byId["beta"]?["risk"]?.stringValue == "yourCall")
        #expect(byId["beta"]?["actionable_by_agent"]?.boolValue == false)
        #expect(byId["alpha"]?["actionable_by_agent"]?.boolValue == true)
    }

    @Test func agentSwitchOffMeansNothingIsActionable() async throws {
        let f = try cleanupFixture()
        var on = await f.call(ListCleanupItemsTool())
        #expect(on.structured?["agents_enabled"]?.boolValue == true)
        var settings = AirySettings()
        settings.agentsEnabled = false
        try f.env.settings.save(settings)
        on = await f.call(ListCleanupItemsTool())
        #expect(on.structured?["agents_enabled"]?.boolValue == false)
        guard case .array(let items)? = on.structured?["items"] else { Issue.record("items"); return }
        #expect(!items.isEmpty && items.allSatisfy { $0["actionable_by_agent"]?.boolValue == false })
    }

    @Test func outputsNeverContainFileContents() async throws {
        let f = try cleanupFixture()
        let secret = f.home + "/Library/Caches/alpha/data.bin"
        try Data("SECRETO-123".utf8).write(to: URL(fileURLWithPath: secret))
        let root = dir(f.home, 100, children: [dir("Library", 100, children: [
            dir("Caches", 100, children: [dir("alpha", 100, children: [file("data.bin", 11)])]),
        ])])
        try f.saveScan(root)
        var outputs: [String] = []
        outputs.append(await f.call(GetDiskSummaryTool()).text)
        outputs.append(await f.call(ListLargestTool(), ["path": .string(f.home + "/Library/Caches/alpha")]).text)
        outputs.append(await f.call(ExplainPathTool(), ["path": .string(secret)]).text)
        outputs.append(await f.call(ListCleanupItemsTool()).text)
        for output in outputs { #expect(!output.contains("SECRETO-123")) }
    }

    @Test func registryIncludesReadTools() {
        let names = MCPToolRegistry.standard().tools.map(\.name)
        for name in ["get_disk_summary", "list_largest", "explain_path", "list_cleanup_items"] {
            #expect(names.contains(name))
        }
        for tool in MCPToolRegistry.standard().tools where tool.name != "x" {
            if ["get_disk_summary", "list_largest", "explain_path", "list_cleanup_items"].contains(tool.name) {
                #expect(tool.annotations.readOnly && !tool.annotations.destructive)
            }
        }
    }
}
