import Foundation
import Observation
import DiskMapCore

/// Assistant state that survives section changes: the located Claude, the report,
/// the conversation and the tasks in progress. The heavy work (context, calls to Claude) runs off the
/// main thread; only the results are published here.
@MainActor @Observable
final class AssistantSession {
    enum Mode: String, CaseIterable, Identifiable {
        case report, chat, agents
        var id: String { rawValue }
        var title: String {
            switch self {
            case .report: String(localized: "Report")
            case .chat: String(localized: "Chat")
            case .agents: String(localized: "Connect Agent")
            }
        }
    }

    enum ClaudeStatus: Equatable {
        case unknown, searching
        case ready(String)
        /// `chosen`: path chosen by the user that doesn't respond like Claude Code.
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
    /// Result of each action run from the report, by recommendation id.
    private(set) var outcomes: [String: CleanupOutcome] = [:]
    private(set) var busyRecommendation: String?
    /// Bumps with each report: a result that arrives late doesn't stick to a card of the new report.
    @ObservationIgnored private var reportGeneration = 0

    @ObservationIgnored private let runner = ProcessRunner()
    @ObservationIgnored private var reportTask: Task<Void, Never>?
    @ObservationIgnored private var chatTask: Task<Void, Never>?
    @ObservationIgnored private var locateTask: Task<Void, Never>?
    @ObservationIgnored private var queuedQuestion: String?
    @ObservationIgnored private var cached: (key: String, context: String, paths: [String])?
    @ObservationIgnored private let home = NSHomeDirectory()

    init() {
        // With AIRY_SUPPORT_DIR (DEBUG) the real UserDefaults isn't touched.
        if AppPaths.standard().legacySupport != nil {
            _ = DataMigration.migrateDefaults(from: UserDefaults(suiteName: AppPaths.legacyBundleID),
                                              to: .standard, keys: [Self.claudePathKey])
        }
    }

    var isReportLoading: Bool { if case .loading = report { true } else { false } }

    /// Path chosen in "Choose Executable…" (`UserDefaults` `claudePath`).
    var chosenPath: String? {
        #if DEBUG
        // Only to review the UI without touching the user's settings (e.g. a nonexistent path).
        if let override = ProcessInfo.processInfo.environment["AIRY_CLAUDE_PATH"] { return override }
        #endif
        return UserDefaults.standard.string(forKey: Self.claudePathKey).flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: Claude

    func locateIfNeeded() {
        if claude == .unknown { locate() }
    }

    /// Looks for Claude Code. If the user chose an executable, that choice wins: if it doesn't respond,
    /// say so (instead of silently using another one).
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

    // MARK: Context

    /// Context for the AI. It reads the live tree, so it is prepared as a `treeGate` reader
    /// (off the main thread). It is reused as long as neither the tree nor the cleanup changes.
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
        model.catalog.map {
            AIAssistant(claudePath: path, runner: runner, catalog: $0, home: home,
                        classifier: RiskClassifier(catalog: $0, settings: model.settings, home: home))
        }
    }

    private static let catalogMissing = String(localized: "Couldn’t load Airy’s catalog, so the assistant can’t validate what Claude proposes.")

    // MARK: Report

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

    /// The report's actions are confirmed and run in `CleanupFlow` (the same sheet as Cleanup,
    /// always through `AppModel` and its `CleanupExecutor`); the card only follows their state. Each notice carries
    /// the generation of the report it was requested in: a result from an earlier report isn't drawn.
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

    /// A question from outside (suggestions, "Explain with AI"): if Claude is still being looked for,
    /// it is sent as soon as it shows up; if it is missing, it is left typed in.
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

    /// Stops the answer: cancelling the consumer ends the `claude` process.
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
                // Only paths still in the shown tree (resolved on the main thread).
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
    /// "Show on Map": opens the Map zoomed into the folder (or the folder containing the file).
    func showInMap(path: String) {
        guard let node = node(atPath: path) else { return }
        let target = node.isDirectory && node.aggregatedCount == 0 ? node : node.parent
        navigation.jump(to: 0)
        if let target, target !== navigation.root { navigation.zoom(into: target) }
        section = .map
    }
}

#if DEBUG
/// Debug only: saves the last real answer to `AIRY_SUPPORT_DIR` and, with
/// `AIRY_ASSISTANT_REPLAY=1`, replays it without calling Claude (to review the UI at no cost).
enum DebugReplay {
    private static var directory: URL? {
        ProcessInfo.processInfo.environment["AIRY_SUPPORT_DIR"].map { URL(fileURLWithPath: $0) }
    }
    private static var replaying: Bool { ProcessInfo.processInfo.environment["AIRY_ASSISTANT_REPLAY"] == "1" }

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
