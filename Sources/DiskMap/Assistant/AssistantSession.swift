import Foundation
import Observation
import DiskMapCore

/// Estado del asistente que sobrevive a los cambios de sección: Claude localizado, el informe,
/// la conversación y las tareas en curso. Lo pesado (contexto, llamadas a Claude) va fuera del
/// hilo principal; aquí solo se publican los resultados.
@MainActor @Observable
final class AssistantSession {
    enum Mode: String, CaseIterable, Identifiable {
        case report, chat
        var id: String { rawValue }
        var title: String { self == .report ? "Informe" : "Chat" }
    }

    enum ClaudeStatus: Equatable {
        case unknown, searching
        case ready(String)
        /// `chosen`: ruta elegida por el usuario que no responde como Claude Code.
        case missing(chosen: String?)
    }

    enum ReportPhase {
        case idle, loading
        case loaded(AIReport, [ReportColumns.Column])
        case failed(String)
    }

    static let claudePathKey = "claudePath"

    var mode: Mode = .report
    private(set) var claude: ClaudeStatus = .unknown
    private(set) var report: ReportPhase = .idle
    private(set) var reportDate: Date?
    private(set) var transcript = ChatTranscript()
    var draft = ""
    /// Resultado de cada acción ejecutada desde el informe, por id de recomendación.
    private(set) var outcomes: [String: CleanupOutcome] = [:]
    private(set) var busyRecommendation: String?
    /// Sube con cada informe: un resultado que llega tarde no se pega a una tarjeta del informe nuevo.
    @ObservationIgnored private var reportGeneration = 0

    @ObservationIgnored private let runner = ProcessRunner()
    @ObservationIgnored private var reportTask: Task<Void, Never>?
    @ObservationIgnored private var chatTask: Task<Void, Never>?
    @ObservationIgnored private var locateTask: Task<Void, Never>?
    @ObservationIgnored private var queuedQuestion: String?
    @ObservationIgnored private var cached: (key: String, context: String, paths: [String])?
    @ObservationIgnored private let home = NSHomeDirectory()

    var isReportLoading: Bool { if case .loading = report { true } else { false } }

    /// Ruta elegida en "Elegir ejecutable…" (`UserDefaults` `claudePath`).
    var chosenPath: String? {
        #if DEBUG
        // Solo para revisar la interfaz sin tocar los ajustes del usuario (p. ej. una ruta inexistente).
        if let override = ProcessInfo.processInfo.environment["DISKMAP_CLAUDE_PATH"] { return override }
        #endif
        return UserDefaults.standard.string(forKey: Self.claudePathKey).flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: Claude

    func locateIfNeeded() {
        if claude == .unknown { locate() }
    }

    /// Busca Claude Code. Si el usuario eligió un ejecutable, manda esa elección: si no responde,
    /// se dice (en vez de usar otro sin avisar).
    func locate() {
        locateTask?.cancel()
        claude = .searching
        let chosen = chosenPath
        let runner = runner
        locateTask = Task { [weak self] in
            let found = await ClaudeLocator.locate(override: chosen, runner: runner)
            guard let self, !Task.isCancelled else { return }
            if let chosen, found != chosen {
                self.claude = .missing(chosen: chosen)
            } else if let found {
                self.claude = .ready(found)
            } else {
                self.claude = .missing(chosen: nil)
            }
            if case .ready = self.claude, let question = self.queuedQuestion, let model = self.pendingModel {
                self.queuedQuestion = nil
                self.pendingModel = nil
                self.ask(question, model: model)
            }
        }
    }

    @ObservationIgnored private weak var pendingModel: AppModel?

    func choose(path: String) {
        UserDefaults.standard.set(path, forKey: Self.claudePathKey)
        locate()
    }

    func forgetChosenPath() {
        UserDefaults.standard.removeObject(forKey: Self.claudePathKey)
        locate()
    }

    private func claudeVanished() {
        claude = .missing(chosen: chosenPath)
    }

    // MARK: Contexto

    /// Contexto para la IA. Lee el árbol vivo, así que se prepara como lector de `treeGate`
    /// (fuera del hilo principal). Se reutiliza mientras no cambien el árbol ni la limpieza.
    private func context(model: AppModel) async -> (context: String, paths: [String])? {
        guard let catalog = model.catalog else { return nil }
        let root = model.scan?.root
        let items = model.cleanupItems
        let volume = model.currentVolume
        let rootID = root.map { String($0.id) } ?? "-"
        let key = "\(rootID)|\(model.treeRevision)|" + items.map { "\($0.id)=\($0.bytes)" }.joined(separator: ",")
        if let cached, cached.key == key { return (cached.context, cached.paths) }
        let home = home
        let job = model.treeGate.read(cancellable: false, priority: .userInitiated) { () -> (String, [String]) in
            let context = AIContextBuilder.context(scan: root, items: items, catalog: catalog, home: home,
                                                   diskTotal: volume.totalBytes, diskFree: volume.availableBytes)
            return (context, AssistantRoutes.contextPaths(context, home: home))
        }
        let (context, paths) = await job.value
        cached = (key, context, paths)
        return (context, paths)
    }

    private func assistant(path: String, model: AppModel) -> AIAssistant? {
        model.catalog.map { AIAssistant(claudePath: path, runner: runner, catalog: $0, home: home) }
    }

    private static let catalogMissing = "No se pudo cargar el catálogo de DiskMap, así que el asistente no puede validar lo que proponga Claude."

    // MARK: Informe

    func runReport(model: AppModel) {
        guard case .ready(let path) = claude else { locate(); return }
        reportTask?.cancel()
        report = .loading
        outcomes = [:]
        busyRecommendation = nil
        reportGeneration += 1
        reportTask = Task { [weak self] in
            guard let self else { return }
            guard let (context, _) = await self.context(model: model),
                  let assistant = self.assistant(path: path, model: model) else {
                self.report = .failed(Self.catalogMissing)
                return
            }
            do {
                #if DEBUG
                let replayed = try await DebugReplay.report()
                let result = if let replayed { replayed } else { try await assistant.report(context: context) }
                DebugReplay.save(report: result)
                #else
                let result = try await assistant.report(context: context)
                #endif
                guard !Task.isCancelled else { return }
                self.report = .loaded(result, ReportColumns.columns(result))
                self.reportDate = Date()
            } catch is CancellationError {
            } catch AIError.notInstalled {
                self.report = .idle
                self.claudeVanished()
            } catch {
                guard !Task.isCancelled else { return }
                self.report = .failed(String(describing: error))
            }
        }
    }

    func offer(for rec: AIRecommendation, model: AppModel) -> AssistantOffer {
        AssistantOffer.make(for: rec, items: model.cleanupItems, catalog: model.catalog, home: home)
    }

    /// Las acciones del informe se confirman y ejecutan en `CleanupFlow` (la misma hoja que Limpieza,
    /// siempre por `AppModel` y su `CleanupExecutor`); la tarjeta solo sigue su estado. Cada aviso lleva
    /// la generación del informe en que se pidió: un resultado de un informe anterior no se pinta.
    var generation: Int { reportGeneration }

    func actionConfirmed(for recID: String, generation: Int) {
        guard generation == reportGeneration else { return }
        busyRecommendation = recID
    }

    func record(_ outcome: CleanupOutcome, for recID: String, generation: Int) {
        guard generation == reportGeneration else { return }
        outcomes[recID] = outcome
        if busyRecommendation == recID { busyRecommendation = nil }
    }

    // MARK: Chat

    /// Pregunta desde fuera (sugerencias, "Explicar con IA"): si Claude aún se está buscando,
    /// se envía en cuanto aparezca; si falta, se deja escrita.
    func ask(_ question: String, model: AppModel) {
        switch claude {
        case .ready:
            if transcript.isStreaming { stop() }
            send(question, model: model)
        case .unknown, .searching:
            draft = question
            queuedQuestion = question
            pendingModel = model
            if claude == .unknown { locate() }
        case .missing:
            draft = question
        }
    }

    func send(_ question: String, model: AppModel) {
        guard case .ready(let path) = claude, let history = transcript.begin(question) else { return }
        draft = ""
        stream(history, path: path, model: model)
    }

    func retry(model: AppModel) {
        guard case .ready(let path) = claude, let history = transcript.retry() else { return }
        stream(history, path: path, model: model)
    }

    /// Detiene la respuesta: cancelar al consumidor termina el proceso de `claude`.
    func stop() {
        chatTask?.cancel()
        chatTask = nil
        transcript.stop()
    }

    private func stream(_ history: [ChatMessage], path: String, model: AppModel) {
        chatTask?.cancel()
        chatTask = Task { [weak self] in
            guard let self else { return }
            guard let (context, candidates) = await self.context(model: model),
                  let assistant = self.assistant(path: path, model: model) else {
                self.transcript.fail(Self.catalogMissing)
                return
            }
            guard !Task.isCancelled else { return }
            do {
                #if DEBUG
                let deltas = DebugReplay.chat() ?? assistant.chat(history: history, context: context)
                #else
                let deltas = assistant.chat(history: history, context: context)
                #endif
                for try await delta in deltas {
                    guard !Task.isCancelled else { return }
                    self.transcript.append(delta)
                }
                guard !Task.isCancelled else { return }
                let text = self.transcript.bubbles.last?.text ?? ""
                #if DEBUG
                DebugReplay.save(chat: text)
                #endif
                // Solo rutas que siguen en el árbol mostrado (se resuelven en el hilo principal).
                let routes = AssistantRoutes.mentioned(in: text, candidates: candidates, home: self.home)
                    .filter { model.node(atPath: $0) != nil }
                self.transcript.finish(routes: routes)
            } catch is CancellationError {
            } catch AIError.notInstalled {
                self.transcript.fail(AIError.notInstalled.description)
                self.claudeVanished()
            } catch {
                guard !Task.isCancelled else { return }
                self.transcript.fail(String(describing: error))
            }
        }
    }
}

extension AppModel {
    /// "Ver en el mapa": abre el Mapa con zoom a la carpeta (o a la carpeta que contiene el archivo).
    func showInMap(path: String) {
        guard let node = node(atPath: path) else { return }
        let target = node.isDirectory && node.aggregatedCount == 0 ? node : node.parent
        navigation.jump(to: 0)
        if let target, target !== navigation.root { navigation.zoom(into: target) }
        section = .map
    }
}

#if DEBUG
/// Solo en Debug: guarda la última respuesta real en `DISKMAP_SUPPORT_DIR` y, con
/// `DISKMAP_ASSISTANT_REPLAY=1`, la repite sin llamar a Claude (para revisar la interfaz sin coste).
enum DebugReplay {
    private static var directory: URL? {
        ProcessInfo.processInfo.environment["DISKMAP_SUPPORT_DIR"].map { URL(fileURLWithPath: $0) }
    }
    private static var replaying: Bool { ProcessInfo.processInfo.environment["DISKMAP_ASSISTANT_REPLAY"] == "1" }

    static func report() async throws -> AIReport? {
        guard replaying, let url = directory?.appendingPathComponent("assistant-report.json"),
              let data = try? Data(contentsOf: url) else { return nil }
        try await Task.sleep(for: .seconds(2.5))
        return try JSONDecoder().decode(AIReport.self, from: data)
    }

    static func save(report: AIReport) {
        guard !replaying, let url = directory?.appendingPathComponent("assistant-report.json") else { return }
        try? JSONEncoder().encode(report).write(to: url)
    }

    static func chat() -> AsyncThrowingStream<String, Error>? {
        guard replaying, let url = directory?.appendingPathComponent("assistant-chat.txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return AsyncThrowingStream { continuation in
            let task = Task {
                try? await Task.sleep(for: .seconds(1.2))
                var rest = Substring(text)
                while !rest.isEmpty, !Task.isCancelled {
                    continuation.yield(String(rest.prefix(6)))
                    rest = rest.dropFirst(6)
                    try? await Task.sleep(for: .milliseconds(25))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func save(chat text: String) {
        guard !replaying, let url = directory?.appendingPathComponent("assistant-chat.txt") else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}
#endif
