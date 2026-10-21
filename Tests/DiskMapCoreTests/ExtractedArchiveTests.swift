import Foundation
import Testing
@testable import DiskMapCore

private struct NoOpenFiles: ProcessListing {
    func processes() -> [RunningProcess]? { [] }
    func holders(ofPathsUnder paths: [String]) -> [RunningProcess]? { [] }
}

private func write(_ path: String, bytes: Int) {
    try! FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                             withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: path, contents: Data(repeating: 0x42, count: bytes))
}

private func makeDir(_ path: String) {
    try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
}

private let zipinfo = "/usr/bin/zipinfo"
private let tar = "/usr/bin/tar"

private func archiveEntry() throws -> CatalogEntry {
    try #require(try Catalog.bundled().entry(id: "extracted-archives"))
}

@Suite struct ExtractedArchiveTests {
    @Test func baseNames() {
        #expect(ExtractedArchiveSource.baseName("Mario Kart 8.zip") == "Mario Kart 8")
        #expect(ExtractedArchiveSource.baseName("data.TAR.GZ") == "data")
        #expect(ExtractedArchiveSource.baseName("x.tar.xz") == "x")
        #expect(ExtractedArchiveSource.baseName("Tool.dmg") == "Tool")
        #expect(ExtractedArchiveSource.baseName("a.7z") == "a" && ExtractedArchiveSource.baseName("b.rar") == "b")
        #expect(ExtractedArchiveSource.baseName("notes.txt") == nil)
        #expect(ExtractedArchiveSource.baseName(".zip") == nil)
    }

    @Test func contentComparison() {
        // Everything under a single top folder extracted as the sibling folder: its children are compared.
        let single = ["Game/", "Game/a.bin", "Game/b.bin", "__MACOSX/Game/._a.bin"]
        #expect(ExtractedArchiveSource.comparedNames(single, folderNames: ["a.bin", "b.bin"]) == ["a.bin", "b.bin"])
        #expect(ExtractedArchiveSource.comparedNames(single, folderNames: ["Game"]) == ["Game"])
        #expect(ExtractedArchiveSource.matches(archiveNames: ["a.bin", "b.bin"], folderNames: ["A.bin", "b.bin", "c"]))
        #expect(!ExtractedArchiveSource.matches(archiveNames: ["a", "b", "c", "d", "e"], folderNames: ["a"]))
        #expect(ExtractedArchiveSource.topLevelNames(["./x/y", "x/z", "w"]) == ["x", "w"])
    }

    @Test func findsLargeArchivesNextToTheirFolder() async throws {
        let home = TestTemp.directory("archives")
        let minimum: Int64 = 100_000
        // Matching zip, zip whose listing fails (name only), .tar.gz (name only), a differing zip, a small one,
        // one without a sibling folder and a link folder.
        write(home + "/Desktop/Mario Kart 8.zip", bytes: 300_000)
        write(home + "/Desktop/Mario Kart 8/game.bin", bytes: 10)
        write(home + "/Downloads/Broken.zip", bytes: 300_000)
        makeDir(home + "/Downloads/Broken")
        write(home + "/Downloads/sub/data.tar.gz", bytes: 300_000)
        makeDir(home + "/Downloads/sub/data")
        write(home + "/Downloads/Other.zip", bytes: 300_000)
        write(home + "/Downloads/Other/unrelated.txt", bytes: 10)
        write(home + "/Downloads/small.zip", bytes: 1_000)
        makeDir(home + "/Downloads/small")
        write(home + "/Downloads/alone.rar", bytes: 300_000)
        write(home + "/Documents/Linked.dmg", bytes: 300_000)
        makeDir(home + "/Documents/real-target")
        try FileManager.default.createSymbolicLink(atPath: home + "/Documents/Linked",
                                                   withDestinationPath: home + "/Documents/real-target")
        let runner = FakeRunner(resolved: ["zipinfo": zipinfo], outputs: [
            "\(zipinfo) -1 \(home)/Desktop/Mario Kart 8.zip": CommandOutput(status: 0, stdout: "Mario Kart 8/\nMario Kart 8/game.bin\n", stderr: ""),
            "\(zipinfo) -1 \(home)/Downloads/Broken.zip": CommandOutput(status: 9, stdout: "", stderr: "bad"),
            "\(zipinfo) -1 \(home)/Downloads/Other.zip": CommandOutput(status: 0, stdout: "x.doc\ny.doc\nz.doc\n", stderr: ""),
        ])
        let entry = try archiveEntry()
        let context = DiscoveryContext(catalog: Catalog(entries: [entry]), home: home, runner: runner,
                                       processListing: NoOpenFiles(), now: Date(), scan: nil)
        let source = ExtractedArchiveSource(minimumBytes: minimum, isUbiquitous: { _ in false })
        let targets = await source.discover(entry, context: context)
        #expect(targets.map(\.idSuffix) == ["~/Desktop/Mario Kart 8.zip", "~/Downloads/Broken.zip",
                                            "~/Downloads/sub/data.tar.gz"])
        #expect(targets.allSatisfy { $0.floor == .yourCall && !$0.preselectable && $0.bytes ?? 0 > minimum })
        #expect(targets[0].details.contains("Its contents match that folder."))
        #expect(targets[1].details.contains("Only the name matches: check the folder before removing it."))
        #expect(runner.calls.allSatisfy { $0.timeout <= ExtractedArchiveSource.listTimeout })

        // Never green, never checked, in either mode.
        for mode in CleanupMode.allCases {
            var settings = AirySettings()
            settings.mode = mode
            let verdict = RiskClassifier(catalog: Catalog(entries: [entry]), settings: settings, home: home)
                .classify(entry: entry, paths: [home + "/Desktop/Mario Kart 8.zip"], floor: .yourCall)
            #expect(verdict.risk == .yourCall && !verdict.preselected)
        }
        #expect(entry.cleanup == .trash && entry.aggressiveRisk == nil && !entry.regenerates)

        // Revalidation: still valid, then the folder goes away.
        let item = CleanupItem(id: "extracted-archives:x", entry: entry, paths: [home + "/Desktop/Mario Kart 8.zip"],
                               bytes: 1, risk: .yourCall, blockedByOpenApps: [], usedBy: [])
        #expect(await source.revalidate(entry, item: item, context: context) == nil)
        try FileManager.default.removeItem(atPath: home + "/Desktop/Mario Kart 8")
        #expect(await source.revalidate(entry, item: item, context: context) != nil)
    }

    @Test func plainTarIsListedWithTar() async throws {
        let home = TestTemp.directory("archives-tar")
        write(home + "/Downloads/pack.tar", bytes: 300_000)
        write(home + "/Downloads/pack/one.txt", bytes: 10)
        let runner = FakeRunner(resolved: ["tar": tar], outputs: [
            "\(tar) -tf \(home)/Downloads/pack.tar": CommandOutput(status: 0, stdout: "one.txt\n", stderr: ""),
        ])
        let check = await ExtractedArchiveSource.compareContents(home + "/Downloads/pack.tar",
                                                                 folder: home + "/Downloads/pack", runner: runner,
                                                                 timeout: 5)
        #expect(check == .matches)
    }
}
