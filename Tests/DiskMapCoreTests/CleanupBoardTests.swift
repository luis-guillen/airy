import Foundation
import Synchronization
import Testing
@testable import DiskMapCore

@Suite struct CleanupBoardTests {
    // MARK: Limpiezas parciales

    private func partialItem(_ id: String, bytes: Int64, risk: Risk = .safe) -> CleanupItem {
        let entry = CatalogEntry(id: id, title: "Título \(id)", explanation: "x", whoCreatesIt: "x", regenerates: true,
                                 risk: risk, kind: .caches, paths: ["~/Library/pnpm/store"],
                                 cleanup: .command(executable: "pnpm", arguments: ["store", "prune"], sizeProbe: nil),
                                 partialCleanup: true)
        return CleanupItem(id: id, entry: entry, paths: ["/Users/ana/Library/pnpm/store"], bytes: bytes, risk: risk,
                           blockedByOpenApps: [], usedBy: [])
    }

    @Test func partialItemsShowUpperBound() {
        let pnpm = partialItem("pnpm", bytes: 3_620_000_000)
        let logs = item("logs", bytes: 50_000_000, risk: .safe)
        #expect(CleanupBoard.isPartial(pnpm))
        #expect(!CleanupBoard.isPartial(logs))
        #expect(CleanupBoard.sizeText(pnpm) == "hasta " + Format.bytes(3_620_000_000))
        #expect(CleanupBoard.sizeText(logs) == Format.bytes(50_000_000))
        let mixed = CleanupBoard.total([pnpm, logs])
        #expect(mixed.bytes == 3_670_000_000)
        #expect(mixed.upperBound)
        #expect(!CleanupBoard.total([logs]).upperBound)
        #expect(CleanupBoard.amountText(10, upperBound: false) == Format.bytes(10))
    }

    @Test func heroIsUpperBoundOnlyWithPartialSafeItems() {
        #expect(CleanupBoard(items: [item("logs", bytes: 50, risk: .safe)]).safeBytesIsUpperBound == false)
        #expect(CleanupBoard(items: [item("logs", bytes: 50, risk: .safe), partialItem("pnpm", bytes: 10)])
                    .safeBytesIsUpperBound)
        // Parcial pero "Depende de ti": no entra en "Puedes liberar", así que no lo vuelve un máximo.
        #expect(CleanupBoard(items: [item("logs", bytes: 50, risk: .safe), partialItem("x", bytes: 10, risk: .yourCall)])
                    .safeBytesIsUpperBound == false)
    }

    // MARK: Fixtures

    private func entry(_ id: String, risk: Risk, cleanup: CleanupMethod = .trash,
                       mustBeClosed: [String] = []) -> CatalogEntry {
        CatalogEntry(id: id, title: "Título \(id)", explanation: "Qué es \(id)", whoCreatesIt: "Alguien",
                     regenerates: true, risk: risk, kind: .caches, paths: ["~/Library/Caches/\(id)"],
                     cleanup: cleanup, mustBeClosed: mustBeClosed)
    }

    private func item(_ id: String, bytes: Int64, risk: Risk, cleanup: CleanupMethod = .trash,
                      blocked: [String] = [], usedBy: [String] = []) -> CleanupItem {
        CleanupItem(id: id, entry: entry(id, risk: risk, cleanup: cleanup, mustBeClosed: blocked),
                    paths: ["/Users/ana/Library/Caches/\(id)"], bytes: bytes, risk: risk,
                    blockedByOpenApps: blocked, usedBy: usedBy)
    }

    private var sample: [CleanupItem] {
        [
            item("logs", bytes: 50, risk: .safe),
            item("brew", bytes: 300, risk: .safe, cleanup: .command(executable: "brew", arguments: ["cleanup"], sizeProbe: nil)),
            item("brave", bytes: 900, risk: .safe, blocked: ["com.brave.Browser"]),
            item("spotify", bytes: 700, risk: .yourCall, blocked: ["com.spotify.client"]),
            item("hf:model", bytes: 400, risk: .doNotTouch, usedBy: ["/Users/ana/Projects/app/main.py"]),
            item("docker-volumes", bytes: 5000, risk: .doNotTouch, cleanup: .info),
            item("ollama", bytes: 2000, risk: .yourCall, cleanup: .info),
        ]
    }

    // MARK: Protegidos

    @Test func protectedItemHasNoCheckbox() {
        // Riesgo verde a propósito: solo la protección debe quitarle la casilla.
        var protected = item("mine", bytes: 800, risk: .safe)
        protected.protection = ProtectionMatch(source: .user, pattern: "~/Library/Caches/mine",
                                               reason: "Lo has protegido tú (~/Library/Caches/mine).")
        #expect(CleanupBoard.canSelect(protected) == false)
        #expect(CleanupBoard.showsCheckbox(protected) == false)
        let board = CleanupBoard(items: [protected, item("logs", bytes: 50, risk: .safe)])
        #expect(board.readySafeItems.map(\.id) == ["logs"])
        #expect(board.safeBytes == 50)
        #expect(CleanupBoard.protectionText(protected.protection!) == "Protegido por ti")
        #expect(CleanupBoard.protectionText(ProtectionMatch(source: .airy, pattern: "~/Library/Mail",
                                                            reason: "Correo de Mail."))
                == "Protegido por Airy: Correo de Mail.")
        #expect(CleanupBoard.commandLine(["uv", "cache", "clean"]) == "uv cache clean")
        #expect(CleanupBoard.commandLine(["echo", "a b"]) == "echo 'a b'")
    }

    // MARK: Grupos

    @Test func groupsByRiskInFixedOrderSortedBySize() {
        let board = CleanupBoard(items: sample)
        #expect(board.groups.map(\.risk) == [.safe, .yourCall, .doNotTouch])
        #expect(board.groups.map(\.title) == ["Borrar sin riesgo", "Depende de ti", "No tocar"])
        #expect(board.groups[0].items.map(\.id) == ["brave", "brew", "logs"])
        #expect(board.groups[1].items.map(\.id) == ["ollama", "spotify"])
        #expect(board.groups[2].items.map(\.id) == ["docker-volumes", "hf:model"])
        #expect(board.groups[0].bytes == 1250)
    }

    @Test func emptyGroupsAreOmittedAndHiddenItemsDisappear() {
        let board = CleanupBoard(items: [item("logs", bytes: 50, risk: .safe), item("brew", bytes: 9, risk: .safe)],
                                 hidden: ["logs"])
        #expect(board.groups.map(\.risk) == [.safe])
        #expect(board.items.map(\.id) == ["brew"])
        #expect(CleanupBoard(items: []).groups.isEmpty)
    }

    @Test func equalSizesKeepAStableOrder() {
        let a = CleanupBoard(items: [item("b", bytes: 5, risk: .safe), item("a", bytes: 5, risk: .safe)])
        let b = CleanupBoard(items: [item("a", bytes: 5, risk: .safe), item("b", bytes: 5, risk: .safe)])
        #expect(a.items.map(\.id) == ["a", "b"])
        #expect(b.items.map(\.id) == ["a", "b"])
    }

    // MARK: Cabecera y "Limpiar todo lo seguro"

    @Test func headerSumsOnlySafeActionableItems() {
        let board = CleanupBoard(items: sample)
        // logs + brew + brave (bloqueada, pero sigue siendo segura); nada de "Depende de ti" ni "No tocar".
        #expect(board.safeBytes == 1250)
    }

    @Test func cleanAllSafeSkipsBlockedUsedAndInfoItems() {
        var items = sample
        items.append(item("safe-info", bytes: 10, risk: .safe, cleanup: .info))
        items.append(item("safe-used", bytes: 10, risk: .safe, usedBy: ["/x"]))
        let board = CleanupBoard(items: items)
        #expect(board.readySafeItems.map(\.id) == ["brew", "logs"])
        #expect(board.readySafeBytes == 350)
        #expect(board.safeBytes == 1250)
    }

    // MARK: Casillas y selección

    @Test func checkboxesOnlyOnActionableRows() {
        let byID = Dictionary(uniqueKeysWithValues: sample.map { ($0.id, $0) })
        #expect(CleanupBoard.showsCheckbox(byID["logs"]!))
        #expect(CleanupBoard.showsCheckbox(byID["spotify"]!))
        #expect(!CleanupBoard.showsCheckbox(byID["hf:model"]!))       // No tocar
        #expect(!CleanupBoard.showsCheckbox(byID["docker-volumes"]!)) // info + No tocar
        #expect(!CleanupBoard.showsCheckbox(byID["ollama"]!))         // info aunque sea "Depende de ti"
    }

    @Test func blockedRowsCannotBeSelected() {
        let byID = Dictionary(uniqueKeysWithValues: sample.map { ($0.id, $0) })
        #expect(CleanupBoard.canSelect(byID["logs"]!))
        #expect(!CleanupBoard.canSelect(byID["spotify"]!))
        #expect(!CleanupBoard.canSelect(byID["brave"]!))
        #expect(!CleanupBoard.canSelect(byID["hf:model"]!))
        #expect(!CleanupBoard.canSelect(byID["ollama"]!))
    }

    @Test func selectionResolvesInDisplayOrderAndDropsInvalidIDs() {
        let board = CleanupBoard(items: sample)
        let ids: Set<String> = ["logs", "spotify", "brew", "docker-volumes", "gone"]
        #expect(board.selected(ids).map(\.id) == ["brew", "logs"])
        #expect(board.selectedBytes(ids) == 350)
        #expect(board.pruned(ids) == ["brew", "logs"])
    }

    // MARK: Textos

    @Test func blockedMessageNamesTheApps() {
        #expect(CleanupBoard.appName(forBundleID: "com.spotify.client") == "Spotify")
        #expect(CleanupBoard.appName(forBundleID: "com.brave.Browser") == "Brave")
        #expect(CleanupBoard.appName(forBundleID: "com.example.SuperApp") == "SuperApp")
        #expect(CleanupBoard.blockedMessage(appNames: []) == nil)
        #expect(CleanupBoard.blockedMessage(appNames: ["Spotify"]) == "Cierra Spotify para limpiar esto")
        #expect(CleanupBoard.blockedMessage(appNames: ["Spotify", "Brave"]) == "Cierra Spotify y Brave para limpiar esto")
        #expect(CleanupBoard.blockedMessage(appNames: ["A", "B", "C"]) == "Cierra A, B y C para limpiar esto")
    }

    @Test func usedByMessageShortensPaths() {
        #expect(CleanupBoard.usedByMessage([], home: "/Users/ana") == nil)
        #expect(CleanupBoard.usedByMessage(["/Users/ana/Projects/app/main.py"], home: "/Users/ana")
            == "Lo usa: ~/Projects/app/main.py")
        let many = (1...5).map { "/Users/ana/p\($0).py" }
        #expect(CleanupBoard.usedByMessage(many, home: "/Users/ana")
            == "Lo usa: ~/p1.py, ~/p2.py, ~/p3.py y 2 más")
    }

    @Test func methodDescriptionRendersTheLiveCommand() {
        #expect(CleanupBoard.methodDescription(.trash) == "A la Papelera")
        #expect(CleanupBoard.methodDescription(.info) == "Solo informativo")
        let docker = CleanupMethod.command(executable: "docker", arguments: ["builder", "prune", "-a", "-f"], sizeProbe: nil)
        #expect(CleanupBoard.commandLine(docker) == "docker builder prune -a -f")
        #expect(CleanupBoard.methodDescription(docker) == "Comando oficial: docker builder prune -a -f")
        let spaced = CleanupMethod.command(executable: "tool", arguments: ["a b", "it's"], sizeProbe: nil)
        #expect(CleanupBoard.commandLine(spaced) == "tool 'a b' 'it'\\''s'")
        #expect(CleanupBoard.commandLine(.trash) == nil)
    }

    // MARK: Instantáneas tras vaciar la Papelera

    @Test func snapshotsAreExplainedOnlyWhenSpaceDidNotRise() {
        let gb: Int64 = 1_000_000_000
        // Subió el 50 % de lo esperado y hay instantáneas.
        #expect(TrashFollowUp.shouldExplainSnapshots(expectedBytes: 10 * gb, freeBefore: 100 * gb,
                                                     freeAfter: 105 * gb, snapshotCount: 3))
        // Subió el 80 % exacto: no.
        #expect(!TrashFollowUp.shouldExplainSnapshots(expectedBytes: 10 * gb, freeBefore: 100 * gb,
                                                      freeAfter: 108 * gb, snapshotCount: 3))
        // Sin instantáneas: no.
        #expect(!TrashFollowUp.shouldExplainSnapshots(expectedBytes: 10 * gb, freeBefore: 100 * gb,
                                                      freeAfter: 100 * gb, snapshotCount: 0))
        // Sin saber cuánto había (Papelera ilegible) o nada que esperar: no.
        #expect(!TrashFollowUp.shouldExplainSnapshots(expectedBytes: nil, freeBefore: 100 * gb,
                                                      freeAfter: 100 * gb, snapshotCount: 3))
        #expect(!TrashFollowUp.shouldExplainSnapshots(expectedBytes: 0, freeBefore: 100 * gb,
                                                      freeAfter: 100 * gb, snapshotCount: 3))
        #expect(TrashFollowUp.retainedBytes(expectedBytes: 10 * gb, freeBefore: 100 * gb, freeAfter: 103 * gb) == 7 * gb)
        #expect(TrashFollowUp.retainedBytes(expectedBytes: 10 * gb, freeBefore: 100 * gb, freeAfter: 130 * gb) == 0)
    }

    @Test func snapshotItemComesFromTheLiveCatalog() throws {
        let catalog = try Catalog.bundled()
        let snapshot = try #require(TrashFollowUp.snapshotItem(catalog: catalog, retainedBytes: 42))
        #expect(snapshot.id == "time-machine-snapshots")
        #expect(snapshot.entry.id == "time-machine-snapshots")
        #expect(snapshot.risk == catalog.entry(id: "time-machine-snapshots")!.risk)
        #expect(snapshot.bytes == 42)
        #expect(snapshot.paths.isEmpty && snapshot.blockedByOpenApps.isEmpty && snapshot.usedBy.isEmpty)
        #expect(CleanupBoard.commandLine(snapshot.entry.cleanup) == "tmutil thinlocalsnapshots / 999999999999 4")
        #expect(TrashFollowUp.snapshotItem(catalog: Catalog(entries: []), retainedBytes: 1) == nil)
    }
}

@Suite struct CleanupBatchTests {
    private func item(_ id: String) -> CleanupItem {
        CleanupItem(id: id, entry: CatalogEntry(id: id, title: "T-\(id)", explanation: "", whoCreatesIt: "",
                                                regenerates: true, risk: .safe, kind: .caches, paths: [],
                                                cleanup: .trash),
                    paths: [], bytes: 1, risk: .safe, blockedByOpenApps: [], usedBy: [])
    }

    @MainActor @Test func runsOneAfterAnotherAndSummarises() async {
        let log = Mutex<(order: [String], active: Int, maxActive: Int)>(([], 0, 0))
        let outcomes: [String: CleanupOutcome] = [
            "a": .freed(100), "b": .movedToTrash(50), "c": .blocked(reason: "Cierra primero: Spotify."),
            "d": .failed("boom"), "e": .freed(0),
        ]
        let items = ["a", "b", "c", "d", "e"].map(item)
        let progress = Mutex<[Int]>([])
        let summary = await CleanupBatch.run(items, onStart: { index in progress.withLock { $0.append(index) } }) { item in
            log.withLock { $0.active += 1; $0.maxActive = max($0.maxActive, $0.active); $0.order.append(item.id) }
            try? await Task.sleep(nanoseconds: 2_000_000)
            log.withLock { $0.active -= 1 }
            return outcomes[item.id]!
        }
        #expect(log.withLock { $0.order } == ["a", "b", "c", "d", "e"])
        #expect(log.withLock { $0.maxActive } == 1)
        #expect(progress.withLock { $0 } == [0, 1, 2, 3, 4])
        #expect(summary.freed == 100)
        #expect(summary.movedToTrash == 50)
        #expect(summary.succeededIDs == ["a", "b", "e"])
        #expect(summary.problems == [
            CleanupRunSummary.Problem(title: "T-c", message: "Cierra primero: Spotify."),
            CleanupRunSummary.Problem(title: "T-d", message: "boom"),
        ])
    }

    @Test func headlineIsHonestAboutTheTrash() {
        var summary = CleanupRunSummary()
        #expect(summary.headline == nil)
        summary.record(id: "x", title: "X", outcome: .movedToTrash(1_500_000))
        #expect(summary.headline == "1,5 MB en la Papelera. Se libera al vaciarla.")
        summary.record(id: "y", title: "Y", outcome: .freed(2_000_000))
        #expect(summary.headline == "Liberados 2 MB · 1,5 MB en la Papelera")
        var onlyFreed = CleanupRunSummary()
        onlyFreed.record(id: "y", title: "Y", outcome: .freed(2_000_000))
        #expect(onlyFreed.headline == "Liberados 2 MB")
        var nothing = CleanupRunSummary()
        nothing.record(id: "z", title: "Z", outcome: .freed(0))
        #expect(nothing.headline == "Hecho. El espacio libre no ha cambiado de forma apreciable.")
        var failed = CleanupRunSummary()
        failed.record(id: "w", title: "W", outcome: .failed("no"))
        #expect(failed.headline == nil)
        #expect(!failed.problems.isEmpty)
    }
}

@Suite struct CleanupLocationTests {
    private func entry(_ patterns: [String]) -> CatalogEntry {
        CatalogEntry(id: "user-logs", title: "Registros de apps", explanation: "", whoCreatesIt: "", regenerates: true,
                     risk: .safe, kind: .caches, paths: patterns, cleanup: .trash)
    }

    private func item(_ paths: [String], patterns: [String] = ["~/Library/Logs/*"]) -> CleanupItem {
        CleanupItem(id: "user-logs", entry: entry(patterns), paths: paths, bytes: 10, risk: .safe,
                    blockedByOpenApps: [], usedBy: [])
    }

    @Test func wildcardFolderSaysEverythingInside() {
        let summary = CleanupBoard.locationSummary(item(["/Users/ana/Library/Logs/A", "/Users/ana/Library/Logs/B",
                                                         "/Users/ana/Library/Logs/C"]), home: "/Users/ana")
        #expect(summary == "Todo lo que hay en ~/Library/Logs (3 elementos)")
    }

    @Test func singleAndSeveralPaths() {
        #expect(CleanupBoard.locationSummary(item(["/Users/ana/Library/Logs/A"]), home: "/Users/ana")
            == "~/Library/Logs/A")
        let mixed = item(["/Users/ana/Library/pnpm/store", "/Users/ana/.pnpm-store"],
                         patterns: ["~/Library/pnpm/store", "~/.pnpm-store"])
        #expect(CleanupBoard.locationSummary(mixed, home: "/Users/ana") == "~/Library/pnpm/store · y 1 más")
        #expect(CleanupBoard.locationSummary(item([]), home: "/Users/ana") == nil)
    }

    @Test func vanishedPathsAreDroppedBeforeRunning() {
        let original = item(["/a", "/b", "/c"])
        let kept = CleanupBoard.withExistingPaths(original) { $0 != "/b" }
        #expect(kept?.paths == ["/a", "/c"])
        #expect(CleanupBoard.withExistingPaths(original) { _ in false } == nil)
        // Sin rutas (comandos): se deja tal cual.
        let command = CleanupItem(id: "brew", entry: entry([]), paths: [], bytes: 1, risk: .safe,
                                  blockedByOpenApps: [], usedBy: [])
        #expect(CleanupBoard.withExistingPaths(command) { _ in false }?.id == "brew")
    }

    @Test func yourCallNoteUsesProperPlural() {
        #expect(CleanupBoard.yourCallNote(count: 1) == "Incluye 1 elemento marcado «Depende de ti»: perderás algo al borrarlo.")
        #expect(CleanupBoard.yourCallNote(count: 3) == "Incluye 3 elementos marcados «Depende de ti»: perderás algo al borrarlo.")
    }
}
