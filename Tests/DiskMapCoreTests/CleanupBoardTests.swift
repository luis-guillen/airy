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

    @Test func blockedRowSaysWhyInline() {
        var blocked = item("pip", bytes: 100, risk: .safe)
        blocked.blockedReason = "pip se está ejecutando; ciérralo y vuelve a intentarlo."
        #expect(CleanupBoard.showsCheckbox(blocked) && !CleanupBoard.canSelect(blocked))
        #expect(CleanupBoard.blockedReasonText(blocked) == "pip se está ejecutando; ciérralo y vuelve a intentarlo.")
        #expect(CleanupBoard.blockedReasonText(item("logs", bytes: 1, risk: .safe)) == nil)
        // Protegida: manda el texto de la protección, no el bloqueo.
        blocked.protection = ProtectionMatch(source: .user, pattern: "~/x", reason: "Lo has protegido tú (~/x).")
        #expect(CleanupBoard.blockedReasonText(blocked) == nil)
    }

    // MARK: Grupos

    @Test func groupsByRiskInFixedOrderSortedBySize() {
        let board = CleanupBoard(items: sample)
        #expect(board.groups.map(\.risk) == [.safe, .yourCall, .doNotTouch])
        #expect(board.groups.map(\.title) == ["Sin problema", "Tú decides", "No borrar"])
        #expect(board.groups[0].items.map(\.id) == ["brave", "brew", "logs"])
        #expect(board.groups[1].items.map(\.id) == ["spotify"]) // ollama es de «Solo revisar"
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
    // MARK: Plan 3, tarea 7

    private func review(_ id: String, bytes: Int64, risk: Risk = .yourCall, hint: String? = nil) -> CleanupItem {
        var e = entry(id, risk: risk, cleanup: .info)
        e.reviewHint = hint
        return CleanupItem(id: id, entry: e, paths: ["/Library/Caches/\(id)"], bytes: bytes, risk: risk,
                           blockedByOpenApps: [], usedBy: [])
    }

    private func ready(_ id: String, bytes: Int64, risk: Risk, preselected: Bool = false) -> CleanupItem {
        var i = item(id, bytes: bytes, risk: risk)
        i.preselected = preselected
        return i
    }

    @Test func groupsUseTheThreeLabelsGreenFirst() {
        #expect(CleanupBoard(items: sample).groups.map(\.title) == ["Sin problema", "Tú decides", "No borrar"])
    }

    @Test func reviewOnlyItemsLiveInTheirOwnList() {
        let board = CleanupBoard(items: sample + [review("sys", bytes: 9000, risk: .doNotTouch, hint: "Hazlo tú.")])
        #expect(board.reviewItems.map(\.id) == ["sys", "ollama"]) // por tamaño
        #expect(!board.items.contains { $0.id == "ollama" || $0.id == "sys" })
        // Docker volumes (informativo en rojo, sin consejo) sigue en «No borrar».
        #expect(board.groups.last?.items.map(\.id).contains("docker-volumes") == true)
        #expect(board.displayItems.map(\.id).suffix(2) == ["sys", "ollama"])
        #expect(board.displayItems.count == sample.count + 1)
        #expect(CleanupBoard.isReviewOnly(review("x", bytes: 1, risk: .doNotTouch, hint: "h")))
        #expect(!CleanupBoard.isReviewOnly(review("x", bytes: 1, risk: .doNotTouch)))
    }

    @Test func selectAllNeverIncludesRedOrBlocked() {
        var protected = item("prot", bytes: 10, risk: .safe)
        protected.protection = ProtectionMatch(source: .airy, pattern: "x", reason: "y")
        let board = CleanupBoard(items: sample + [protected, item("amber", bytes: 5, risk: .yourCall)])
        // brave y spotify esperan a que cierres una app; ollama es de revisión; los rojos y el protegido no.
        #expect(board.fullSelection == ["logs", "brew", "amber"])
        #expect(board.greenSelection == ["logs", "brew"])
    }

    @Test func greenSelectionIsReadySafe() {
        let board = CleanupBoard(items: sample)
        #expect(board.greenSelection == Set(board.readySafeItems.map(\.id)))
    }

    @Test func preselectionAppliesOnlyToNewItems() {
        let a = ready("a", bytes: 3, risk: .safe, preselected: true)
        let b = ready("b", bytes: 2, risk: .safe, preselected: true)
        let first = CleanupBoard(items: [a, b]).nextSelection(current: [], seen: [])
        #expect(first.selection == ["a", "b"])
        // El usuario quita «b»; la misma detección no lo vuelve a marcar.
        let second = CleanupBoard(items: [a, b]).nextSelection(current: ["a"], seen: first.seen)
        #expect(second.selection == ["a"])
        // Aparece «c» preseleccionado y «a» desaparece.
        let c = ready("c", bytes: 1, risk: .safe, preselected: true)
        let third = CleanupBoard(items: [b, c]).nextSelection(current: second.selection, seen: second.seen)
        #expect(third.selection == ["c"])
        #expect(third.seen == ["a", "b", "c"])
        // Uno bloqueado no cuenta como visto: al desbloquearse se marca.
        let blocked = item("d", bytes: 1, risk: .safe, blocked: ["com.x"])
        let step = CleanupBoard(items: [blocked]).nextSelection(current: [], seen: [])
        #expect(step.selection.isEmpty && !step.seen.contains("d"))
    }

    @Test func deleteAllTitleSaysUpToWhenPartial() {
        let plain = item("logs", bytes: 3_000_000_000, risk: .safe)
        #expect(CleanupBoard.deleteAllTitle([plain]) == "Borrar todo · " + Format.bytes(3_000_000_000))
        #expect(CleanupBoard.deleteAllTitle([plain, partialItem("p", bytes: 10)])
            == "Borrar todo · hasta " + Format.bytes(3_000_000_010))
    }

    @Test func confirmSectionsSplitAmberAndHonourRemoval() {
        let a = item("A", bytes: 1, risk: .safe), b = item("B", bytes: 1, risk: .yourCall)
        let c = item("C", bytes: 1, risk: .yourCall), red = item("R", bytes: 1, risk: .doNotTouch)
        let all = [a, b, c, red]
        var sections = CleanupBoard.confirmSections(all, excluding: ["C"])
        #expect(sections.regular.map(\.id) == ["A"] && sections.review.map(\.id) == ["B"])
        sections = CleanupBoard.confirmSections(all, excluding: ["A", "B", "C"])
        #expect(sections.regular.isEmpty && sections.review.isEmpty)
        #expect(CleanupBoard.reviewBlockTitle == "Revisa: esto no se regenera solo o puede tener estado")
    }

    @Test func whyTextsFollowPriority() {
        var e = entry("x", risk: .yourCall)
        e.shortReason = "Motivo de la ficha."
        let protection = ProtectionMatch(source: .airy, pattern: "p", reason: "Protegida.")
        #expect(RiskExplanation.why(risk: .doNotTouch, entry: e, protection: protection, reason: "Guardia.", bytes: 1, personal: true) == "Guardia.")
        #expect(RiskExplanation.why(risk: .doNotTouch, entry: e, protection: protection, reason: nil, bytes: 1, personal: false) == "Protegida.")
        #expect(RiskExplanation.why(risk: .doNotTouch, entry: e, protection: nil, reason: nil, bytes: 1, personal: false) == "Motivo de la ficha.")
        #expect(RiskExplanation.why(risk: .doNotTouch, entry: nil, protection: nil, reason: nil, bytes: 1, personal: false)
            == "Es del sistema o guarda datos que no se recuperan.")
        #expect(RiskExplanation.why(risk: .yourCall, entry: e, protection: nil, reason: "Guardia.", bytes: 1, personal: true) == "Guardia.")
        #expect(RiskExplanation.why(risk: .yourCall, entry: e, protection: nil, reason: nil, bytes: 1, personal: true) == "Motivo de la ficha.")
        e.shortReason = nil
        #expect(RiskExplanation.why(risk: .yourCall, entry: e, protection: nil, reason: nil, bytes: 1, personal: true)
            == "Está en tus carpetas personales: solo tú sabes si lo necesitas.")
        #expect(RiskExplanation.why(risk: .yourCall, entry: e, protection: nil, reason: nil, bytes: 2_000_000_000, personal: false)
            == "Pierdes lo que hay dentro (\(Format.bytes(2_000_000_000))); no vuelve solo.")
        #expect(RiskExplanation.why(risk: .yourCall, entry: e, protection: nil, reason: nil, bytes: 0, personal: false)
            == "Pierdes lo que hay dentro; no vuelve solo.")
        #expect(RiskExplanation.why(risk: .safe, entry: e, protection: nil, reason: nil, bytes: 0, personal: false)
            == "Se vuelve a crear sola.")
        // Personal por ruta: Descargas es una carpeta personal.
        var downloads = item("d", bytes: 5, risk: .yourCall)
        downloads.paths = ["/Users/ana/Downloads/x.dmg"]
        #expect(RiskExplanation.why(downloads, home: "/Users/ana")
            == "Está en tus carpetas personales: solo tú sabes si lo necesitas.")
        // Las filas de revisión empiezan por su consejo.
        #expect(RiskExplanation.why(review("r", bytes: 1, hint: "Bórralo tú.")) == "Bórralo tú.")
    }

    @Test func lmStudioReasonCarriesTheSize() throws {
        let lm = try #require(try Catalog.bundled().entry(id: "lmstudio-models"))
        let i = CleanupItem(id: "lmstudio-models:x", entry: lm, paths: ["/Users/ana/.lmstudio/models/a/b"],
                            bytes: 4_200_000_000, risk: .yourCall, blockedByOpenApps: [], usedBy: [])
        #expect(RiskExplanation.why(i, home: "/Users/ana") == "Tendrías que volver a descargar \(Format.bytes(4_200_000_000)).")
    }

    @Test func summaryListsSuccessesAndProblems() {
        var summary = CleanupRunSummary()
        summary.record(id: "a", title: "A", outcome: .freed(2_000_000_000))
        summary.record(id: "b", title: "B", outcome: .movedToTrash(1_200_000_000))
        summary.record(id: "c", title: "C", outcome: .blocked(reason: "Cierra X"))
        summary.record(id: "d", title: "D", outcome: .failed("Fallo"))
        #expect(summary.successes.map(\.title) == ["A", "B"])
        #expect(summary.successes.map(\.text) == ["Liberados \(Format.bytes(2_000_000_000))", "\(Format.bytes(1_200_000_000)) a la Papelera"])
        #expect(summary.problems.map(\.title) == ["C", "D"])
    }

    @Test func sizeNoteOverridesSize() {
        var i = item("x", bytes: 5, risk: .safe)
        i.sizeNote = "No ocupa espacio en disco"
        #expect(CleanupBoard.sizeText(i) == "No ocupa espacio en disco")
        var partial = item("y", bytes: 1_000_000_000, risk: .safe)
        partial.sizeIsPartial = true
        #expect(CleanupBoard.sizeText(partial) == Format.bytes(1_000_000_000) + "+")
        #expect(Format.bytes(1_000_000_000, partial: true).hasSuffix("+"))
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
        #expect(CleanupBoard.yourCallNote(count: 1) == "Incluye 1 elemento marcado «Tú decides»: perderás algo al borrarlo.")
        #expect(CleanupBoard.yourCallNote(count: 3) == "Incluye 3 elementos marcados «Tú decides»: perderás algo al borrarlo.")
    }
}
