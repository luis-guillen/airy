import Foundation
import Testing
@testable import DiskMapCore

/// Proyecto `~/Projects/<name>` con estos paquetes (`name@version`) en su node_modules.
private func project(_ home: String, _ name: String, _ packages: [String]) {
    let root = home + "/Projects/" + name
    tcWrite(root + "/package.json", "{}")
    for spec in packages {
        let at = spec.lastIndex(of: "@")!
        let pkg = String(spec[..<at]), version = String(spec[spec.index(after: at)...])
        tcWrite(root + "/node_modules/\(pkg)/package.json", #"{"name":"\#(pkg)","version":"\#(version)"}"#)
        tcWrite(root + "/node_modules/\(pkg)/index.js", String(repeating: "x", count: 9000))
    }
}

private func context(_ home: String, catalog: Catalog) -> DiscoveryContext {
    DiscoveryContext(catalog: catalog, home: home, runner: FakeRunner(), processListing: TCListing(), now: Date(),
                     scan: nil)
}

@Suite struct DependencyDuplicateTests {
    @Test func repeatedPackagesAcrossThreeProjectsMakeOneRow() async throws {
        let home = toolchainTempDir()
        project(home, "a", ["react@18.2.0", "lodash@4.17.21"])
        project(home, "b", ["react@18.2.0", "lodash@4.17.21"])
        project(home, "c", ["react@18.2.0"])
        let catalog = try tcCatalog("node-dependency-duplicates")
        let rows = await DependencyDuplicateSource().discover(catalog.entries[0], context: context(home, catalog: catalog))
        let row = try #require(rows.first)
        #expect(rows.count == 1 && row.paths.isEmpty && !row.preselectable && row.sizeNote == nil)
        let size = try #require(TreeWalk.summarize(home + "/Projects/a/node_modules/react", budget: .seconds(5))).bytes
        #expect(row.bytes == 2 * size)
        #expect(row.details == ["react@18.2.0 · 3 proyectos · \(Format.bytes(size)) cada copia"])
    }

    @Test func pnpmSymlinkedPackagesAreSkipped() async throws {
        let home = toolchainTempDir()
        project(home, "a", ["react@18.2.0"])
        project(home, "b", ["react@18.2.0"])
        project(home, "c", [])
        tcWrite(home + "/Projects/c/node_modules/.pnpm/react@18.2.0/node_modules/react/package.json",
                #"{"name":"react","version":"18.2.0"}"#)
        try FileManager.default.createSymbolicLink(
            atPath: home + "/Projects/c/node_modules/react",
            withDestinationPath: home + "/Projects/c/node_modules/.pnpm/react@18.2.0/node_modules/react")
        let catalog = try tcCatalog("node-dependency-duplicates")
        #expect(await DependencyDuplicateSource().discover(catalog.entries[0],
                                                           context: context(home, catalog: catalog)).isEmpty)
    }

    @Test func scopedPackagesAndBadJsonAreHandled() async throws {
        let home = toolchainTempDir()
        for name in ["a", "b", "c"] { project(home, name, ["@babel/core@7.23.0", "broken@1.0.0"]) }
        tcWrite(home + "/Projects/a/node_modules/broken/package.json", "{no es json")
        tcWrite(home + "/Projects/b/node_modules/broken/package.json",
                #"{"name":"broken","version":"1.0.0","x":""# + String(repeating: "y", count: 70_000) + "\"}")
        let catalog = try tcCatalog("node-dependency-duplicates")
        let rows = await DependencyDuplicateSource().discover(catalog.entries[0], context: context(home, catalog: catalog))
        #expect(rows.first?.details.count == 1)
        #expect(rows.first?.details.first?.hasPrefix("@babel/core@7.23.0 · 3 proyectos") == true)
    }

    @Test func duplicatesNeverActAndAgentOnlyLists() async throws {
        let home = toolchainTempDir()
        for name in ["a", "b", "c"] { project(home, name, ["react@18.2.0"]) }
        let catalog = try tcCatalog("node-dependency-duplicates")
        let items = await CleanupScanner(
            catalog: catalog, runner: FakeRunner(), probes: FakeProbes(), references: ReferenceChecker(roots: []),
            home: home, processListing: TCListing()).findItems(scan: nil)
        let item = try #require(items.first)
        #expect(item.risk == .yourCall && !item.preselected)
        let runner = FakeRunner()
        let load = SettingsLoad.loaded(AirySettings())
        let executor = CleanupExecutor(
            runner: runner, probes: FakeProbes(), store: IndexStore(directory: URL(fileURLWithPath: toolchainTempDir())),
            catalog: catalog, references: ReferenceChecker(roots: []), home: home, freeSpace: { 0 },
            settings: { load }, processGuard: ProcessGuard(listing: TCListing()), processListing: TCListing())
        for context in [OperationContext.user(), .agent("claude")] {
            guard case .blocked = await executor.execute(item, context: context) else {
                Issue.record("\(context)"); continue
            }
        }
        #expect(await executor.execute(item) == .blocked(reason: "Este elemento es solo informativo."))
        #expect(runner.calls.isEmpty)
    }
}
