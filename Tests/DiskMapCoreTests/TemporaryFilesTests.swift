import Foundation
import Synchronization
import Testing
@testable import DiskMapCore

/// Listing whose open files are fixed (or unknown with `nil`), optionally slow.
private final class OpenFilesListing: ProcessListing, Sendable {
    let open: Set<String>?
    let delay: Duration
    init(open: Set<String>?, delay: Duration = .zero) { self.open = open; self.delay = delay }
    func processes() -> [RunningProcess]? { [] }
    func holders(ofPathsUnder paths: [String]) -> [RunningProcess]? { [] }
    func openPaths(under roots: [String]) -> Set<String>? {
        if delay > .zero { Thread.sleep(forTimeInterval: Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18) }
        return open
    }
}

private func write(_ path: String, bytes: Int = 20_000) {
    try! FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                             withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: path, contents: Data(repeating: 0x41, count: bytes))
}

private func age(_ path: String, days: Double) {
    try! FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-days * 86_400)],
                                           ofItemAtPath: path)
}

private func tempEntry() throws -> CatalogEntry {
    try #require(try Catalog.bundled().entry(id: "old-temporary-files"))
}

/// A fake temporary folder: two old entries, a fresh one, an old folder with a fresh file inside, an old file some
/// process has open, a FIFO and a system-managed folder. Returns the resolved root.
private func makeRoot() -> String {
    let made = TestTemp.directory("tempfiles")
    let root = CleanupTargets.realPath(made) ?? made
    write(root + "/old-build/a.o"); age(root + "/old-build/a.o", days: 5); age(root + "/old-build", days: 5)
    write(root + "/old.bin"); age(root + "/old.bin", days: 10)
    write(root + "/fresh.txt")
    write(root + "/mixed/inner.txt"); age(root + "/mixed", days: 9)
    write(root + "/open.log"); age(root + "/open.log", days: 6)
    mkfifo(root + "/pipe", 0o600); age(root + "/pipe", days: 6)
    write(root + "/com.apple.thing/x"); age(root + "/com.apple.thing/x", days: 8); age(root + "/com.apple.thing", days: 8)
    return root
}

private func context(_ listing: any ProcessListing, home: String, catalog: Catalog) -> DiscoveryContext {
    DiscoveryContext(catalog: catalog, home: home, runner: FakeRunner(), processListing: listing, now: Date(),
                     scan: nil)
}

@Suite struct TemporaryFilesTests {
    @Test func groupsOnlyOldUnopenedEntriesOwnedByTheUser() async throws {
        let root = makeRoot()
        let home = TestTemp.directory("tempfiles-home")
        let entry = try tempEntry()
        let catalog = Catalog(entries: [entry])
        let listing = OpenFilesListing(open: [root + "/open.log"])
        let items = await TemporaryFilesSource.$rootOverride.withValue(root) {
            await CleanupScanner(catalog: catalog, runner: FakeRunner(), probes: FakeProbes(),
                                 references: ReferenceChecker(roots: []), home: home, processListing: listing)
                .findItems(scan: nil)
        }
        let item = try #require(items.first)
        #expect(items.count == 1)
        #expect(item.id == "old-temporary-files")
        #expect(item.title == "Old temporary files")
        #expect(item.paths == [root + "/old-build", root + "/old.bin"])
        #expect(item.bytes > 0)
        #expect(item.details.first == "2 old items in the temporary folder")
        // Aggressive (the default) is green and checked; Careful is amber and unchecked.
        #expect(item.risk == .safe && item.preselected)
        var careful = AirySettings()
        careful.mode = .prudent
        let verdict = RiskClassifier(catalog: catalog, settings: careful, home: home)
            .classify(entry: entry, paths: item.paths)
        #expect(verdict.risk == .yourCall && !verdict.preselected)
        #expect(entry.cleanup == .trash)
    }

    @Test func unknownOrSlowOpenFilesOfferNothing() async throws {
        let root = makeRoot()
        let home = TestTemp.directory("tempfiles-home")
        let entry = try tempEntry()
        let catalog = Catalog(entries: [entry])
        await TemporaryFilesSource.$rootOverride.withValue(root) {
            let unknown = await TemporaryFilesSource().discover(
                entry, context: context(OpenFilesListing(open: nil), home: home, catalog: catalog))
            #expect(unknown.isEmpty)
            let slow = await TemporaryFilesSource(openFilesBudget: .milliseconds(50)).discover(
                entry, context: context(OpenFilesListing(open: [], delay: .seconds(1)), home: home, catalog: catalog))
            #expect(slow.isEmpty)
            // The default listing protocol implementation cannot tell: it fails closed too.
            struct Blind: ProcessListing {
                func processes() -> [RunningProcess]? { [] }
                func holders(ofPathsUnder paths: [String]) -> [RunningProcess]? { [] }
            }
            let blind = await TemporaryFilesSource().discover(entry, context: context(Blind(), home: home, catalog: catalog))
            #expect(blind.isEmpty)
        }
    }

    @Test func anotherHomeWithoutOverrideHasNoTemporaryFolder() async throws {
        #expect(TemporaryFilesSource.root(home: TestTemp.directory("tempfiles-home")) == nil)
        let real = try #require(TemporaryFilesSource.root(home: NSHomeDirectory()))
        // Exactly the folder `HardProtections` exempts inside `/private`, never wider.
        #expect(RiskPolicy.canonical(real) == HardProtections.userTemporaryDirectory)
        #expect(HardProtections.standard.match(canonicalPath: "/private/tmp/x", home: NSHomeDirectory(), catalog: nil) != nil)
        #expect(TemporaryFilesSource.isSkipped("airy-tests") && TemporaryFilesSource.isSkipped("com.apple.Safari"))
    }

    @Test func revalidationRejectsChangedOpenOrForeignPaths() async throws {
        let root = makeRoot()
        let home = TestTemp.directory("tempfiles-home")
        let entry = try tempEntry()
        let catalog = Catalog(entries: [entry])
        func item(_ paths: [String]) -> CleanupItem {
            CleanupItem(id: entry.id, entry: entry, paths: paths, bytes: 1, risk: .safe, blockedByOpenApps: [], usedBy: [])
        }
        await TemporaryFilesSource.$rootOverride.withValue(root) {
            let source = TemporaryFilesSource()
            let quiet = context(OpenFilesListing(open: []), home: home, catalog: catalog)
            #expect(await source.revalidate(entry, item: item([root + "/old-build", root + "/old.bin"]), context: quiet) == nil)
            // Something opened it since detection.
            let busy = context(OpenFilesListing(open: [root + "/old-build/a.o"]), home: home, catalog: catalog)
            #expect(await source.revalidate(entry, item: item([root + "/old-build"]), context: busy) != nil)
            // Outside the temporary folder, or nested deeper than its direct children.
            #expect(await source.revalidate(entry, item: item([home]), context: quiet) != nil)
            #expect(await source.revalidate(entry, item: item([root + "/old-build/a.o"]), context: quiet) != nil)
            // Special entries never qualify.
            #expect(await source.revalidate(entry, item: item([root + "/pipe"]), context: quiet) != nil)
            // Touched since detection.
            write(root + "/old-build/new.o")
            #expect(await source.revalidate(entry, item: item([root + "/old-build"]), context: quiet) != nil)
        }
    }
}
