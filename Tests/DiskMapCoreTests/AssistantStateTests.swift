import Foundation
import Testing
@testable import DiskMapCore

private let home = "/Users/ana"

private func entry(_ id: String, _ risk: Risk, _ paths: [String], _ cleanup: CleanupMethod,
                   mustBeClosed: [String] = [], referenceCheck: String? = nil) -> CatalogEntry {
    CatalogEntry(id: id, title: "Ficha \(id)", explanation: "", whoCreatesIt: "", regenerates: true, risk: risk,
                 kind: .caches, paths: paths, cleanup: cleanup, mustBeClosed: mustBeClosed,
                 referenceCheck: referenceCheck)
}

private let uvCommand = CleanupMethod.command(executable: "uv", arguments: ["cache", "clean"], sizeProbe: nil)
private let dockerCommand = CleanupMethod.command(executable: "/usr/local/bin/docker",
                                                  arguments: ["builder", "prune", "-a", "-f"], sizeProbe: nil)

private let catalog = Catalog(entries: [
    entry("uv", .safe, ["~/.cache/uv"], uvCommand),
    entry("docker-build-cache", .safe, [], dockerCommand),
    entry("playwright", .safe, ["~/Library/Caches/ms-playwright"], .trash),
    entry("user-logs", .safe, ["~/Library/Logs/*"], .trash),
    entry("spotify-cache", .yourCall, ["~/Library/Caches/com.spotify.client"], .trash,
          mustBeClosed: ["com.spotify.client"]),
    entry("hf", .yourCall, ["~/.cache/huggingface/hub/models--*"], .trash, referenceCheck: "{name}"),
    entry("ollama", .yourCall, ["~/.ollama/models"], .info),
])

private func item(_ id: String, paths: [String], bytes: Int64 = 100, risk: Risk = .safe,
                  usedBy: [String] = []) -> CleanupItem {
    let entryID = String(id.split(separator: ":").first!)
    return CleanupItem(id: id, entry: catalog.entry(id: entryID)!, paths: paths, bytes: bytes, risk: risk,
                       blockedByOpenApps: [], usedBy: usedBy)
}

private func rec(_ path: String, _ verdict: Risk, bytes: Int64 = 100, action: AIAction? = nil) -> AIRecommendation {
    AIRecommendation(id: path, path: path, verdict: verdict, reason: "porque sí", bytes: bytes, action: action)
}

// MARK: - Rutas mencionadas

@Suite struct AssistantRoutesTests {
    let candidates = [
        "/Users/ana/Library", "/Users/ana/Library/Containers", "/Users/ana/.cache/uv",
        "/Users/ana/Library/Application Support", "/Users/ana/Música/diseño", "/Library/Caches", "/",
        "/Users/ana",
    ]

    @Test func findsTildeAndAbsoluteForms() {
        let text = "Lo que más ocupa es ~/.cache/uv. También /Library/Caches, que es del sistema."
        #expect(AssistantRoutes.mentioned(in: text, candidates: candidates, home: home)
                == ["/Users/ana/.cache/uv", "/Library/Caches"])
        let absolute = "Mira /Users/ana/Library/Containers: ahí está todo."
        #expect(AssistantRoutes.mentioned(in: absolute, candidates: candidates, home: home)
                == ["/Users/ana/Library/Containers"])
    }

    @Test func longestMatchWinsAndPrefixesDoNotLeak() {
        let text = "La carpeta ~/Library/Containers guarda datos de apps."
        #expect(AssistantRoutes.mentioned(in: text, candidates: candidates, home: home)
                == ["/Users/ana/Library/Containers"])
        // "~/Library/Caches" no es candidata: no se convierte en "~/Library".
        #expect(AssistantRoutes.mentioned(in: "Mira ~/Library/Caches/foo", candidates: candidates, home: home).isEmpty)
        // "/Library/Caches" dentro de "~/Library/Caches" no cuenta como la del sistema.
        #expect(AssistantRoutes.mentioned(in: "en ~/Library/Caches hay", candidates: candidates, home: home).isEmpty)
        // Un nombre que sigue (".cache/uvx") no es la ruta.
        #expect(AssistantRoutes.mentioned(in: "~/.cache/uvx y ~/.cache/uv.zip", candidates: candidates, home: home).isEmpty)
    }

    @Test func keepsSpacesUnicodeAndPunctuation() {
        let text = "Revisa «~/Library/Application Support» y `~/Música/diseño/`, y ~/Library."
        #expect(AssistantRoutes.mentioned(in: text, candidates: candidates, home: home)
                == ["/Users/ana/Library/Application Support", "/Users/ana/Música/diseño", "/Users/ana/Library"])
    }

    @Test func ignoresRootHomeAndDuplicatesAndRespectsLimit() {
        let text = "En / y en ~ hay cosas; ~/.cache/uv otra vez ~/.cache/uv y /Users/ana/.cache/uv."
        #expect(AssistantRoutes.mentioned(in: text, candidates: candidates, home: home) == ["/Users/ana/.cache/uv"])
        let many = (0..<10).map { "/Users/ana/c\($0)" }
        let all = many.map { "~/c\($0.last!)" }.joined(separator: " ")
        #expect(AssistantRoutes.mentioned(in: all, candidates: many, home: home, limit: 3).count == 3)
    }

    @Test func contextPathsAreExpandedAndIncludeCleanupItems() {
        let scan = FileNode(name: "/Users/ana", isDirectory: true, allocatedSize: 300, children: [
            FileNode(name: ".cache", isDirectory: true, allocatedSize: 300, children: [
                FileNode(name: "uv", isDirectory: true, allocatedSize: 300),
            ]),
        ])
        let context = AIContextBuilder.context(
            scan: scan, items: [item("playwright", paths: ["/Users/ana/Library/Caches/ms-playwright"])],
            catalog: catalog, home: home)
        let paths = AssistantRoutes.contextPaths(context, home: home)
        #expect(paths.contains("/Users/ana/.cache/uv"))
        #expect(paths.contains("/Users/ana/Library/Caches/ms-playwright"))
        #expect(!paths.contains { $0.hasPrefix("~") })
        #expect(AssistantRoutes.contextPaths("no es json", home: home).isEmpty)
    }
}

// MARK: - Columnas del informe

@Suite struct ReportColumnsTests {
    @Test func threeColumnsInRiskOrderSortedBySize() {
        let report = AIReport(summary: "", recommendations: [
            rec("/a", .yourCall, bytes: 5), rec("/b", .safe, bytes: 1), rec("/c", .safe, bytes: 9),
            rec("/d", .doNotTouch, bytes: 3),
        ], reclaimableBytes: 0)
        let columns = ReportColumns.columns(report)
        #expect(columns.map(\.risk) == [.safe, .yourCall, .doNotTouch])
        #expect(columns[0].recommendations.map(\.path) == ["/c", "/b"])
        #expect(columns[1].recommendations.map(\.path) == ["/a"])
        #expect(columns[2].totalBytes == 3)
    }

    @Test func emptyColumnsStillPresentAndNestedNotCountedTwice() {
        let report = AIReport(summary: "", recommendations: [
            rec("/x", .safe, bytes: 10), rec("/x/y", .safe, bytes: 4), rec("/z", .safe, bytes: 1),
        ], reclaimableBytes: 0)
        let columns = ReportColumns.columns(report)
        #expect(columns.count == 3)
        #expect(columns[1].recommendations.isEmpty)
        #expect(columns[0].totalBytes == 11)
    }
}

// MARK: - Botón de cada recomendación

@Suite struct AssistantActionOfferTests {
    @Test func doNotTouchNeverHasButton() {
        let r = rec("/Users/ana/Library/Logs/x", .doNotTouch, action: .trash(path: "/Users/ana/Library/Logs/x"))
        #expect(AssistantOffer.make(for: r, items: [], catalog: catalog, home: home) == .none)
    }

    @Test func safeCommandUsesDetectedItem() throws {
        let detected = item("docker-build-cache", paths: [], bytes: 5_000)
        let r = rec("docker-build-cache", .safe, action: .runCatalogCommand(id: "docker-build-cache"))
        guard case .offer(let offer) = AssistantOffer.make(for: r, items: [detected], catalog: catalog, home: home),
              case .perform(let target) = offer.action else { Issue.record("sin oferta"); return }
        #expect(target.id == "docker-build-cache")
        #expect(offer.isCommand)
        #expect(!offer.needsSecondConfirmation)
        #expect(offer.method == "Comando oficial: docker builder prune -a -f")
    }

    @Test func catalogCommandOnTrashEntryIsShownAsTrash() {
        // La IA puede pedir "runCatalogCommand" de una ficha que se limpia con Papelera.
        let path = "/Users/ana/Library/Caches/ms-playwright"
        let detected = item("playwright", paths: [path])
        let r = rec(path, .safe, action: .runCatalogCommand(id: "playwright"))
        guard case .offer(let offer) = AssistantOffer.make(for: r, items: [detected], catalog: catalog, home: home)
        else { Issue.record("sin oferta"); return }
        #expect(!offer.isCommand)
        #expect(offer.method == "A la Papelera")
    }

    @Test func safeCommandNotDetectedIsUnavailable() {
        let r = rec("/Users/ana/.cache/uv", .safe, action: .runCatalogCommand(id: "uv"))
        guard case .unavailable = AssistantOffer.make(for: r, items: [], catalog: catalog, home: home) else {
            Issue.record("debería no estar disponible"); return
        }
    }

    @Test func safeTrashUsesDetectedItemOrNarrowsIt() {
        let path = "/Users/ana/Library/Logs/a"
        let detected = item("user-logs", paths: [path, "/Users/ana/Library/Logs/b"], bytes: 900)
        let r = rec(path, .safe, bytes: 300, action: .trash(path: path))
        guard case .offer(let offer) = AssistantOffer.make(for: r, items: [detected], catalog: catalog, home: home),
              case .perform(let target) = offer.action else { Issue.record("sin oferta"); return }
        #expect(target.id == "user-logs")
        #expect(target.paths == [path])
        #expect(target.bytes == 300)
        #expect(offer.method == "A la Papelera")
        #expect(!offer.isCommand)
    }

    @Test func safeTrashSynthesizesFromCatalogWhenNotDetected() {
        let path = "/Users/ana/Library/Caches/ms-playwright"
        let r = rec(path, .safe, action: .trash(path: path))
        guard case .offer(let offer) = AssistantOffer.make(for: r, items: [], catalog: catalog, home: home),
              case .perform(let target) = offer.action else { Issue.record("sin oferta"); return }
        #expect(target.entry.id == "playwright")
        #expect(target.paths == [path])
    }

    @Test func safeWithoutActionHasNoButton() {
        #expect(AssistantOffer.make(for: rec("/Users/ana/x", .safe), items: [], catalog: catalog, home: home) == .none)
    }

    @Test func yourCallPlainPathGoesToTrashPathsWithSecondConfirmation() {
        let path = "/Users/ana/Downloads/grande.iso"
        guard case .offer(let offer) = AssistantOffer.make(for: rec(path, .yourCall), items: [], catalog: catalog,
                                                           home: home),
              case .trashPaths(let paths) = offer.action else { Issue.record("sin oferta"); return }
        #expect(paths == [path])
        #expect(offer.needsSecondConfirmation)
    }

    @Test func yourCallCatalogTrashGoesThroughPerformToKeepAppChecks() {
        let path = "/Users/ana/Library/Caches/com.spotify.client"
        guard case .offer(let offer) = AssistantOffer.make(for: rec(path, .yourCall), items: [], catalog: catalog,
                                                           home: home),
              case .perform(let target) = offer.action else { Issue.record("sin oferta"); return }
        #expect(target.entry.id == "spotify-cache")
        #expect(offer.needsSecondConfirmation)
        // Dentro de la caché de Spotify (no es la ruta de la ficha) no hay forma segura: sin botón.
        #expect(AssistantOffer.make(for: rec(path + "/Data", .yourCall), items: [], catalog: catalog, home: home)
                == .none)
    }

    @Test func yourCallNeverTrashesCommandOrInfoLocations() {
        #expect(AssistantOffer.make(for: rec("/Users/ana/.cache/uv/archive", .yourCall), items: [], catalog: catalog,
                                    home: home) == .none)
        #expect(AssistantOffer.make(for: rec("/Users/ana/.ollama/models", .yourCall), items: [], catalog: catalog,
                                    home: home) == .none)
        // Un id de elemento (sin ruta) tampoco.
        #expect(AssistantOffer.make(for: rec("docker-build-cache", .yourCall), items: [], catalog: catalog,
                                    home: home) == .none)
        // Ni una carpeta que contiene una caché que se limpia con su comando.
        #expect(AssistantOffer.make(for: rec("/Users/ana/.cache", .yourCall),
                                    items: [item("uv", paths: ["/Users/ana/.cache/uv"])], catalog: catalog,
                                    home: home) == .none)
    }

    @Test func referencedItemsAreUnavailable() {
        let path = "/Users/ana/.cache/huggingface/hub/models--a--b"
        let used = item("hf:models--a--b", paths: [path], risk: .yourCall, usedBy: ["/p/train.py"])
        guard case .unavailable(let reason) = AssistantOffer.make(for: rec(path, .yourCall), items: [used],
                                                                   catalog: catalog, home: home) else {
            Issue.record("debería no estar disponible"); return
        }
        #expect(reason.contains("/p/train.py"))
        // Sin detección no se pudo comprobar quién lo usa: sin botón.
        #expect(AssistantOffer.make(for: rec(path, .yourCall), items: [], catalog: catalog, home: home) == .none)
    }
}

// MARK: - Conversación

@Suite struct ChatTranscriptTests {
    @Test func beginAppendsBubblesAndReturnsHistory() {
        var t = ChatTranscript()
        let history = t.begin("¿Qué ocupa más?")
        #expect(history == [ChatMessage(role: .user, text: "¿Qué ocupa más?")])
        #expect(t.bubbles.count == 2)
        #expect(t.isStreaming)
        #expect(t.begin("otra") == nil)
        t.append("Lo que ")
        t.append("más ocupa")
        t.finish(routes: ["/a"])
        #expect(!t.isStreaming)
        #expect(t.bubbles.last?.text == "Lo que más ocupa")
        #expect(t.bubbles.last?.routes == ["/a"])
        #expect(t.bubbles.last?.status == .done)
        let next = t.begin("¿Y eso?")
        #expect(next == [ChatMessage(role: .user, text: "¿Qué ocupa más?"),
                         ChatMessage(role: .assistant, text: "Lo que más ocupa"),
                         ChatMessage(role: .user, text: "¿Y eso?")])
    }

    @Test func emptyQuestionIsIgnoredAndTrimmed() {
        var t = ChatTranscript()
        #expect(t.begin("   \n") == nil)
        #expect(t.bubbles.isEmpty)
        #expect(t.begin("  hola \n") == [ChatMessage(role: .user, text: "hola")])
    }

    @Test func failedTurnsAreLeftOutOfLaterHistoryAndCanRetry() {
        var t = ChatTranscript()
        _ = t.begin("uno")
        t.append("parcial")
        t.fail("Claude tardó demasiado")
        #expect(t.bubbles.last?.status == .failed("Claude tardó demasiado"))
        #expect(!t.isStreaming)
        let retry = t.retry()
        #expect(retry == [ChatMessage(role: .user, text: "uno")])
        #expect(t.bubbles.count == 2)
        #expect(t.bubbles.last?.text == "")
        #expect(t.isStreaming)
        t.fail("otra vez")
        #expect(t.begin("dos") == [ChatMessage(role: .user, text: "dos")])
    }

    @Test func stopKeepsPartialTextOrDropsEmptyBubble() {
        var t = ChatTranscript()
        _ = t.begin("uno")
        t.append("algo")
        t.stop()
        #expect(t.bubbles.last?.status == .stopped)
        #expect(!t.isStreaming)
        #expect(t.retry() == nil)
        _ = t.begin("dos")
        t.stop()
        #expect(t.bubbles.count == 3)
        #expect(t.bubbles.last?.role == .user)
        // La pregunta sin respuesta no entra en el historial siguiente.
        #expect(t.begin("tres") == [ChatMessage(role: .user, text: "uno"),
                                    ChatMessage(role: .assistant, text: "algo"),
                                    ChatMessage(role: .user, text: "tres")])
    }

    @Test func lateDeltasAfterStopAreIgnored() {
        var t = ChatTranscript()
        _ = t.begin("uno")
        t.append("a")
        t.stop()
        t.append("b")
        t.finish(routes: ["/x"])
        #expect(t.bubbles.last?.text == "a")
        #expect(t.bubbles.last?.status == .stopped)
        #expect(t.bubbles.last?.routes == [])
    }
}
