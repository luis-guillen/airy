import Foundation
import Testing
@testable import DiskMapCore

private let kib = 1024

/// Carpeta temporal con un home y ficheros reales; el índice se construye con `DiskScanner` (sin agrupar
/// los pequeños), como el que guarda la app.
private struct Fixture {
    let tmp: String
    var home: String { tmp + "/home" }

    init() {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dup-\(UUID().uuidString)").path
        try! FileManager.default.createDirectory(atPath: tmp + "/home", withIntermediateDirectories: true)
    }

    /// Escribe `data` en `home/rel` y devuelve la ruta.
    @discardableResult
    func write(_ rel: String, _ data: Data) -> String {
        let full = home + "/" + rel
        try! FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        try! data.write(to: URL(fileURLWithPath: full))
        return full
    }

    func index() async -> FileNode {
        let options = ScanOptions(roots: [URL(fileURLWithPath: home)], excludedPrefixes: [], pruneThreshold: 0)
        return try! await DiskScanner(options: options).scan { _ in }.root
    }

    func finder(protected: [String] = []) -> DuplicateFinder {
        var settings = AirySettings()
        settings.protectedPaths = protected
        let catalog = Catalog(entries: [])
        let classifier = RiskClassifier(catalog: catalog, settings: settings, home: home)
        let gate = PathGate(home: home, catalog: catalog, userProtected: ProtectList(patterns: protected, home: home))
        return DuplicateFinder(home: home, classifier: classifier, gate: gate)
    }

    var search: DuplicateSearch { DuplicateSearch(roots: [home], minBytes: 100_000) }

    func find(protected: [String] = []) async -> DuplicateResult {
        let root = await index()
        return await finder(protected: protected).find(search, in: root)
    }
}

/// 200 KiB pseudoaleatorios, distintos por `seed`.
private func blob(_ seed: UInt8, size: Int = 200 * kib) -> Data {
    var state = UInt32(seed) &* 2_654_435_761 &+ 1
    return Data((0..<size).map { _ in
        state = state &* 1_664_525 &+ 1_013_904_223
        return UInt8(truncatingIfNeeded: state >> 24)
    })
}

private func copy(_ path: String, created: Date? = nil, risk: Risk = .yourCall, protected: Bool = false,
                  bytes: Int64 = 10) -> DuplicateCopy {
    DuplicateCopy(path: path, created: created, modified: nil, reclaimableBytes: bytes, risk: protected ? .doNotTouch : risk,
                  protection: protected ? ProtectionMatch(source: .user, pattern: path, reason: "r") : nil)
}

private func group(_ copies: [DuplicateCopy], keeper: String? = nil) -> DuplicateGroup {
    let keep = keeper ?? copies[0].path
    return DuplicateGroup(size: 10, copies: copies, keeper: keep)
}

@Suite struct DuplicateTests {
    @Test func identicalFilesAreGrouped() async {
        let f = Fixture()
        let a = f.write("Documents/a.bin", blob(1))
        let b = f.write("Downloads/b.bin", blob(1))
        f.write("Documents/other.bin", blob(2))
        let result = await f.find()
        #expect(result.complete)
        #expect(result.groups.count == 1)
        let g = result.groups[0]
        #expect(Set(g.copies.map(\.path)) == [a, b])
        #expect(g.size == Int64(200 * kib))
        #expect(g.keeper == a)                        // la de Descargas no se propone conservar
        #expect(g.copies.first?.path == g.keeper)
        #expect(g.wastedBytes > 0)
        #expect(result.filesExamined == 3)
    }

    @Test func sameEndsDifferentMiddleAreNotDuplicates() async {
        let f = Fixture()
        var one = blob(3), two = blob(3)
        let middle = one.count / 2
        one[middle] = 0x00; two[middle] = 0xFF
        f.write("a.bin", one)
        f.write("b.bin", two)
        let result = await f.find()
        #expect(result.groups.isEmpty)
        #expect(result.complete)
    }

    @Test func hardLinksAreNotDuplicates() async {
        let f = Fixture()
        let a = f.write("a.bin", blob(4))
        #expect(link(a, f.home + "/b.bin") == 0)
        let result = await f.find()
        #expect(result.groups.isEmpty)
    }

    @Test func symlinksIgnored() async {
        let f = Fixture()
        let a = f.write("a.bin", blob(5))
        #expect(symlink(a, f.home + "/b.bin") == 0)
        let result = await f.find()
        #expect(result.groups.isEmpty)
    }

    @Test func belowMinimumIgnored() async {
        let f = Fixture()
        f.write("a.bin", blob(6, size: 50 * kib))
        f.write("b.bin", blob(6, size: 50 * kib))
        let result = await f.find()
        #expect(result.groups.isEmpty)
        #expect(result.filesExamined == 0)
    }

    @Test func clonedCopyReclaimsNothing() async {
        let f = Fixture()
        let a = f.write("a.bin", blob(7))
        let b = f.home + "/b.bin"
        guard clonefile(a, b, 0) == 0 else {
            // Solo APFS clona; en otro sistema de ficheros no hay nada que comprobar.
            Issue.record("clonefile no disponible aquí (¿no es APFS?): errno \(errno)")
            return
        }
        let result = await f.find()
        #expect(result.groups.count == 1)
        #expect(result.groups.first?.wastedBytes == 0)
        #expect(result.groups.first?.copies.allSatisfy { $0.reclaimableBytes == 0 } == true)
    }

    @Test func keeperPrefersProtectedThenNotDownloadsThenOldest() {
        let home = "/Users/x"
        let old = Date(timeIntervalSince1970: 1_000), new = Date(timeIntervalSince1970: 2_000)
        // (1) lo protegido gana aunque esté en Descargas y sea más nuevo.
        let protectedFirst = [copy("/Users/x/Documents/a", created: old),
                              copy("/Users/x/Downloads/z", created: new, protected: true)]
        #expect(DuplicateFinder.suggestedKeeper(protectedFirst, home: home) == "/Users/x/Downloads/z")
        // (2) fuera de Descargas y Escritorio, aunque sea más nueva.
        let notDownloads = [copy("/Users/x/Downloads/a", created: old), copy("/Users/x/Desktop/b", created: old),
                            copy("/Users/x/Documents/long/path/c", created: new)]
        #expect(DuplicateFinder.suggestedKeeper(notDownloads, home: home) == "/Users/x/Documents/long/path/c")
        // (3) la más antigua; (4) la ruta más corta; (5) orden alfabético.
        let oldest = [copy("/Users/x/Documents/b", created: new), copy("/Users/x/Documents/long/a", created: old)]
        #expect(DuplicateFinder.suggestedKeeper(oldest, home: home) == "/Users/x/Documents/long/a")
        let shortest = [copy("/Users/x/Documents/long/a", created: old), copy("/Users/x/Documents/b", created: old)]
        #expect(DuplicateFinder.suggestedKeeper(shortest, home: home) == "/Users/x/Documents/b")
        let alphabetical = [copy("/Users/x/Documents/d"), copy("/Users/x/Documents/c")]
        #expect(DuplicateFinder.suggestedKeeper(alphabetical, home: home) == "/Users/x/Documents/c")
    }

    @Test func selectAllCopiesNeverSelectsKeeperOrProtected() {
        let g1 = group([copy("/a/1"), copy("/a/2"), copy("/a/3", protected: true), copy("/a/4", risk: .doNotTouch)])
        let g2 = group([copy("/b/1"), copy("/b/2")])
        var board = DuplicateBoard(groups: [g1, g2])
        board.selectAllCopies()
        #expect(board.selected == ["/a/2", "/b/2"])
        #expect(board.reclaimableBytes == 20)
    }

    @Test func toggleNeverSelectsWholeGroup() {
        let g = group([copy("/a/1"), copy("/a/2")])
        var board = DuplicateBoard(groups: [g])
        board.toggle("/a/1", in: g)                   // el conservado: no hace nada
        #expect(board.selected.isEmpty)
        board.toggle("/a/2", in: g)
        #expect(board.selected == ["/a/2"])
        board.keep("/a/2", in: g)                     // cambia el conservado y lo desmarca
        #expect(board.keepers[g.id] == "/a/2")
        #expect(board.selected.isEmpty)
        board.toggle("/a/1", in: g)
        board.toggle("/a/2", in: g)
        #expect(board.selected == ["/a/1"])
        board.toggle("/a/1", in: g)
        #expect(board.selected.isEmpty)
        // Lo protegido nunca se marca, y una ruta ajena al grupo tampoco.
        let p = group([copy("/p/1"), copy("/p/2", protected: true)])
        var other = DuplicateBoard(groups: [p])
        other.toggle("/p/2", in: p)
        other.toggle("/zzz", in: p)
        #expect(other.selected.isEmpty)
    }

    @Test func removalsNeverIncludeKeeper() {
        let g1 = group([copy("/a/1"), copy("/a/2"), copy("/a/3")])
        let g2 = group([copy("/b/1"), copy("/b/2")])
        var board = DuplicateBoard(groups: [g1, g2])
        board.selectAllCopies()
        board.keep("/a/3", in: g1)
        board.toggle("/a/1", in: g1)
        let removals = board.removals()
        #expect(removals.count == 2)
        for removal in removals { #expect(!removal.remove.contains(removal.keep)) }
        #expect(removals.first { $0.keep == "/a/3" }?.remove == ["/a/1", "/a/2"])
        #expect(removals.first { $0.keep == "/b/1" }?.remove == ["/b/2"])
        board.clear()
        #expect(board.removals().isEmpty && board.reclaimableBytes == 0)
    }

    @Test func verifyRejectsChangedFile() async throws {
        let f = Fixture()
        f.write("Documents/a.bin", blob(8))
        let b = f.write("Documents/sub/b.bin", blob(8))
        let c = f.write("Documents/sub/c.bin", blob(8))
        let result = await f.find()
        var board = DuplicateBoard(groups: result.groups)
        board.selectAllCopies()
        let removal = try #require(board.removals().first)
        #expect(Set(removal.remove) == [b, c])
        #expect(await f.finder().verify(removal).isEmpty)
        var changed = blob(8); changed[10] ^= 0xFF          // mismo tamaño, contenido distinto
        try changed.write(to: URL(fileURLWithPath: b))
        #expect(await f.finder().verify(removal) == [b: "Ha cambiado desde la búsqueda."])
        try blob(8, size: 100 * kib).write(to: URL(fileURLWithPath: c))
        let both = await f.finder().verify(removal)
        #expect(both == [b: "Ha cambiado desde la búsqueda.", c: "Ha cambiado desde la búsqueda."])
        try FileManager.default.removeItem(atPath: c)
        #expect(await f.finder().verify(removal)[c] == "Ya no existe.")
    }

    @Test func verifyRejectsMissingKeeper() async throws {
        let f = Fixture()
        let a = f.write("Documents/a.bin", blob(9))
        f.write("Documents/sub/b.bin", blob(9))
        let result = await f.find()
        var board = DuplicateBoard(groups: result.groups)
        board.selectAllCopies()
        let removal = try #require(board.removals().first)
        #expect(removal.keep == a)
        var changed = blob(9); changed[0] ^= 0xFF
        try changed.write(to: URL(fileURLWithPath: a))
        #expect(await f.finder().verify(removal)[a] == "La copia que conservas ha cambiado.")
        try FileManager.default.removeItem(atPath: a)
        #expect(await f.finder().verify(removal)[a] == "Ya no existe la copia que conservas.")
        let confirmable = await f.finder().confirmable([removal])
        #expect(confirmable.paths.isEmpty)
        #expect(confirmable.notes.count == 1)
    }

    @Test func verifyRefusesRemovingTheKeeper() async {
        let f = Fixture()
        let a = f.write("a.bin", blob(10))
        let b = f.write("b.bin", blob(10))
        let finder = f.finder()
        let removal = DuplicateRemoval(keep: a, remove: [a, b], size: Int64(200 * kib))
        #expect(await finder.verify(removal)[a] == "Es la copia que conservas.")
        // La misma copia con otra forma de la ruta (mayúsculas en APFS) también es la conservada.
        let variant = DuplicateRemoval(keep: a, remove: [f.home + "/A.bin"], size: Int64(200 * kib))
        if FileManager.default.fileExists(atPath: f.home + "/A.bin") {
            #expect(await finder.verify(variant)[f.home + "/A.bin"] == "Es la copia que conservas.")
        }
        #expect(await finder.confirmable([removal]).paths.isEmpty)
    }

    @Test func confirmablePassesOnlyVerifiedCopies() async throws {
        let f = Fixture()
        f.write("Documents/a.bin", blob(11))
        let b = f.write("Documents/sub/b.bin", blob(11))
        let c = f.write("Documents/sub/c.bin", blob(11))
        f.write("Music/x.bin", blob(12))
        let y = f.write("Music/sub/y.bin", blob(12))
        let result = await f.find()
        #expect(result.groups.count == 2)
        var board = DuplicateBoard(groups: result.groups)
        board.selectAllCopies()
        var changed = blob(11); changed[5] ^= 1
        try changed.write(to: URL(fileURLWithPath: b))
        let out = await f.finder().confirmable(board.removals())
        #expect(Set(out.paths) == [c, y])
        #expect(out.notes == ["~/Documents/sub/b.bin: Ha cambiado desde la búsqueda."])
    }

    @Test func protectedCopyIsKeptAndNeverSelectable() async {
        let f = Fixture()
        f.write("Documents/a.bin", blob(13))
        let b = f.write("Documents/sub/b.bin", blob(13))
        let result = await f.find(protected: ["~/Documents/sub"])
        let g = try! #require(result.groups.first)
        #expect(g.keeper == b)
        #expect(g.copies.first { $0.path == b }?.canSelect == false)
        #expect(g.copies.first { $0.path == b }?.risk == .doNotTouch)
        #expect(g.copies.allSatisfy { $0.risk >= .yourCall })
    }

    @Test func reportHasNoHashes() async throws {
        let f = Fixture()
        f.write("a.bin", blob(14))
        f.write("b.bin", blob(14))
        let result = await f.find()
        #expect(result.groups.count == 1)
        let url = URL(fileURLWithPath: f.tmp + "/support/duplicates.json")
        try FileManager.default.createDirectory(atPath: f.tmp + "/support", withIntermediateDirectories: true)
        #expect(try DuplicateReport.load(from: url) == nil)
        try DuplicateReport.save(result, to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.range(of: "[0-9a-fA-F]{64}", options: .regularExpression) == nil)
        #expect(!String(describing: result).contains("SHA"))
        let json = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(Set(json.keys) == ["date", "complete", "files_examined", "groups"])
        let groups = try #require(json["groups"] as? [[String: Any]])
        #expect(Set(groups[0].keys) == ["size", "reclaimable_bytes", "keeper", "copies"])
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        let loaded = try #require(try DuplicateReport.load(from: url))
        #expect(loaded.groups.first?.copies.count == 2)
        #expect(loaded.groups.first?.keeper == result.groups[0].keeper)
        #expect(loaded.complete && loaded.filesExamined == 2)
    }

    @Test func cancellationGivesIncomplete() async {
        let f = Fixture()
        for i in 0..<4 {
            f.write("d\(i)/a.bin", blob(UInt8(20 + i)))
            f.write("d\(i)/b.bin", blob(UInt8(20 + i)))
        }
        let root = await f.index()
        let finder = f.finder()
        let search = f.search
        let task = Task {
            try? await Task.sleep(for: .seconds(30))   // se corta al cancelar
            return await finder.find(search, in: root)
        }
        task.cancel()
        let result = await task.value
        #expect(!result.complete)
        #expect(result.groups.isEmpty)
    }

    @Test func defaultRootsSkipLibraryAndTrash() {
        let f = Fixture()
        f.write("Documents/x", Data([1]))
        f.write("Library/x", Data([1]))
        f.write(".Trash/x", Data([1]))
        f.write("Projects/x", Data([1]))
        #expect(DuplicateSearch.defaultRoots(home: f.home) == [f.home + "/Documents", f.home + "/Projects"])
    }

    @Test func skipsPackagesAndToolFolders() async {
        let f = Fixture()
        f.write("Thing.app/Contents/a.bin", blob(30))
        f.write("Thing.app/Contents/b.bin", blob(30))
        f.write("code/node_modules/a.bin", blob(31))
        f.write("code/node_modules/b.bin", blob(31))
        f.write("code/.git/a.bin", blob(32))
        f.write("code/b.bin", blob(32))
        let result = await f.find()
        #expect(result.groups.isEmpty)
    }
}
