import Foundation

/// Action proposed by the AI. It is only returned as data: `CleanupExecutor` runs it later,
/// repeating its own checks.
public enum AIAction: Codable, Sendable, Equatable {
    case trash(path: String)
    case runCatalogCommand(id: String)

    private enum CodingKeys: String, CodingKey { case type, path, id }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "trash": self = .trash(path: try c.decode(String.self, forKey: .path))
        case "runCatalogCommand": self = .runCatalogCommand(id: try c.decode(String.self, forKey: .id))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown action: \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .trash(let path):
            try c.encode("trash", forKey: .type)
            try c.encode(path, forKey: .path)
        case .runCatalogCommand(let id):
            try c.encode("runCatalogCommand", forKey: .type)
            try c.encode(id, forKey: .id)
        }
    }
}

public struct AIRecommendation: Codable, Sendable, Identifiable {
    public var id: String
    /// Absolute path (after validation, always a path present in the context).
    public var path: String
    public var verdict: Risk
    public var reason: String
    public var bytes: Int64
    public var action: AIAction?

    public init(id: String, path: String, verdict: Risk, reason: String, bytes: Int64, action: AIAction?) {
        self.id = id; self.path = path; self.verdict = verdict; self.reason = reason
        self.bytes = bytes; self.action = action
    }

    private enum CodingKeys: String, CodingKey { case id, path, verdict, reason, bytes, action }

    /// `verdict` comes as text ("safe" | "yourCall" | "doNotTouch"); `id` is optional (defaults to the path).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? path
        let name = try c.decode(String.self, forKey: .verdict)
        guard let verdict = Risk(jsonName: name) else {
            throw DecodingError.dataCorruptedError(forKey: .verdict, in: c, debugDescription: "Unknown verdict: \(name)")
        }
        self.verdict = verdict
        reason = try c.decode(String.self, forKey: .reason)
        bytes = try c.decode(Int64.self, forKey: .bytes)
        action = try c.decodeIfPresent(AIAction.self, forKey: .action)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(path, forKey: .path)
        try c.encode(verdict.jsonName, forKey: .verdict)
        try c.encode(reason, forKey: .reason)
        try c.encode(bytes, forKey: .bytes)
        try c.encodeIfPresent(action, forKey: .action)
    }
}

public struct AIReport: Codable, Sendable {
    public var summary: String
    public var recommendations: [AIRecommendation]
    public var reclaimableBytes: Int64

    public init(summary: String, recommendations: [AIRecommendation], reclaimableBytes: Int64) {
        self.summary = summary; self.recommendations = recommendations; self.reclaimableBytes = reclaimableBytes
    }
}

public enum AIError: Error, Sendable, CustomStringConvertible {
    case notInstalled, timedOut, invalidResponse(String), failed(String)

    public var description: String {
        switch self {
        case .notInstalled: String(localized: "Claude Code was not found on this Mac.", bundle: .airyCore)
        case .timedOut: String(localized: "Claude took too long to reply.", bundle: .airyCore)
        case .invalidResponse(let detail): String(localized: "Claude returned a reply that cannot be understood: \(detail)", bundle: .airyCore)
        case .failed(let detail): String(localized: "Claude could not reply: \(detail)", bundle: .airyCore)
        }
    }
}

public struct ChatMessage: Codable, Sendable, Equatable {
    public enum Role: String, Codable, Sendable { case user, assistant }
    public var role: Role
    public var text: String

    public init(role: Role, text: String) { self.role = role; self.text = text }
}

/// Assistant based on `claude -p` without tools: it only receives metadata and only returns data.
public struct AIAssistant: Sendable {
    public static let timeout: TimeInterval = 120

    /// Base instructions. Always in English; `language` (a code such as `"es"`) is the language Claude must reply in.
    static func systemPrompt(language: String) -> String {
        """
        You are the assistant of Airy, a macOS app that shows what takes up space on the disk. \
        You only see metadata (paths, sizes, dates, kinds and Airy's catalog entries), never the contents of the files. \
        Classify each item as "safe" (safe to delete), "yourCall" (up to the user) or "doNotTouch" (do not touch). \
        Never recommend deleting personal files (Documents, Desktop, Pictures, Movies, Music, Downloads, projects), \
        Docker volumes or anything in /System. \
        The only possible actions are "trash" of a path that appears in the context or "runCatalogCommand" with a catalog id; \
        do not make up paths or commands. \
        Explain in plain language, as you would to a non-technical person. \
        \(replyInstruction(language: language))
        """
    }

    /// The reply-language line shared by every prompt: the user's language, short sentences, no jargon.
    static func replyInstruction(language: String) -> String {
        let code = AiryLanguage.resolve([language])
        return "Always reply in \(AiryLanguage.englishName(of: code)) (language code \"\(code)\"), the user's language, "
            + "in short sentences and without unnecessary jargon."
    }

    /// In the report, Airy computes the totals ("Reclaimable"): Claude's text gives no added-up figures
    /// that could contradict them.
    static func reportSystemPrompt(language: String) -> String {
        systemPrompt(language: language) + " " + """
        In the summary do not give totals or sums of space (nor "in total you can free X"): Airy computes the totals \
        and shows them separately. You may quote the size of a specific item as it appears in the context.
        """
    }

    /// In the chat Claude cannot do anything on its own: it only explains.
    static func chatSystemPrompt(language: String) -> String {
        systemPrompt(language: language) + " " + """
        In this conversation you cannot perform any action yourself and you must not offer to do it \
        ("do you want me to delete it?"); the user acts from the Cleanup section or with the buttons of Airy's Report.
        """
    }

    /// The source-language (English) prompts, for tests and callers without a language.
    static var systemPrompt: String { systemPrompt(language: AiryLanguage.source) }
    static var reportSystemPrompt: String { reportSystemPrompt(language: AiryLanguage.source) }
    static var chatSystemPrompt: String { chatSystemPrompt(language: AiryLanguage.source) }

    private let claudePath: String
    private let runner: any CommandRunning
    private let catalog: Catalog
    private let home: String
    /// If present, it decides the verdict (mode, the user's and hard protections) instead of `RiskPolicy`.
    private let classifier: RiskClassifier?
    /// Language Claude replies in (a code such as `"es"`). The prompts themselves are always English.
    public let language: String

    public init(claudePath: String, runner: any CommandRunning, catalog: Catalog, home: String = NSHomeDirectory(),
                classifier: RiskClassifier? = nil, language: String? = nil) {
        self.claudePath = claudePath
        self.runner = runner
        self.catalog = catalog
        self.home = home
        self.classifier = classifier
        self.language = AiryLanguage.resolve([language ?? AiryLanguage.current])
    }

    /// Common arguments. `--setting-sources ""` avoids the user's hooks and plugins (verified: it keeps
    /// the session signed in, unlike `--bare`). `--tools ""`: Claude cannot read or run anything.
    var baseArguments: [String] { arguments(systemPrompt: Self.systemPrompt(language: language)) }

    func arguments(systemPrompt: String) -> [String] {
        ["-p", "--setting-sources", "", "--tools", "", "--strict-mcp-config", "--disable-slash-commands",
         "--no-session-persistence", "--system-prompt", systemPrompt]
    }

    // MARK: Report

    public func report(context: String) async throws -> AIReport {
        let arguments = self.arguments(systemPrompt: Self.reportSystemPrompt(language: language))
            + ["--output-format", "json", "--json-schema", Self.reportSchema]
        let prompt = """
        Disk context (JSON, metadata only):
        \(context)

        Task: write a short summary of the state of the disk and recommend what can be freed. \
        In "path" use paths exactly as they appear in the context; for a cleanup item without paths, \
        put its "id" in "path". "runCatalogCommand" only with the catalogId of that same path or item. \
        In "bytes" put the size the context gives.
        """
        let output: CommandOutput
        do {
            output = try await withScratchDirectory { dir in
                try await runner.run(claudePath, arguments, stdin: prompt, workingDirectory: dir, timeout: Self.timeout)
            }
        } catch {
            throw mapError(error)
        }

        guard let object = try? JSONSerialization.jsonObject(with: Data(output.stdout.utf8)) as? [String: Any] else {
            if output.status != 0 {
                throw AIError.failed(Self.snippet(output.stderr.isEmpty ? output.stdout : output.stderr))
            }
            throw AIError.invalidResponse(Self.snippet(output.stdout))
        }
        if object["is_error"] as? Bool == true {
            throw AIError.failed(Self.snippet(object["result"] as? String ?? output.stderr))
        }
        guard let structured = object["structured_output"] as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: structured),
              let raw = try? JSONDecoder().decode(AIReport.self, from: data) else {
            throw AIError.invalidResponse(String(localized: "structured_output is missing or does not match the schema", bundle: .airyCore))
        }
        return validate(raw, context: context)
    }

    /// What is known about a context path (or about the id of a cleanup item without paths).
    struct Known {
        var path: String
        var bytes: Int64
        /// Risk of the cleanup item that contains it (already raised by `usedBy`, etc.).
        var itemRisk: Risk?
        /// Entries of the cleanup items that contain it.
        var itemCatalogIds: Set<String> = []
        /// `true` if it is the id of an item without paths (e.g. `docker-build-cache`), not a path.
        var isItemID = false
    }

    /// Rules always applied in code, distrusting the AI:
    /// - only context paths; the risk never drops below the floor, the catalog or the cleanup item;
    /// - `trash` only of the path itself, if its catalog entry is cleaned with the Trash and it ends up "safe",
    ///   and never of protected locations;
    /// - `runCatalogCommand` only with the entry of that same path (or of its cleanup item) and never `.info`.
    func validate(_ raw: AIReport, context: String) -> AIReport {
        let payload = try? JSONDecoder().decode(AIContextPayload.self, from: Data(context.utf8))
        var known: [String: Known] = [:]
        for node in payload?.nodes ?? [] {
            let absolute = AIPaths.expand(node.path, home: home)
            known[RiskPolicy.canonical(absolute)] = Known(path: absolute, bytes: node.bytes)
        }
        var itemIDs: [String: Known] = [:]
        for item in payload?.cleanupItems ?? [] {
            let itemRisk = Risk(jsonName: item.risk) ?? .yourCall
            if item.paths.isEmpty {
                itemIDs[item.id] = Known(path: item.id, bytes: item.bytes, itemRisk: itemRisk,
                                         itemCatalogIds: [item.catalogId], isItemID: true)
            }
            for path in item.paths {
                let absolute = AIPaths.expand(path, home: home)
                let key = RiskPolicy.canonical(absolute)
                var entry = known[key] ?? Known(path: absolute, bytes: item.paths.count == 1 ? item.bytes : 0)
                entry.itemRisk = entry.itemRisk.map { Risk.strictest($0, itemRisk) } ?? itemRisk
                entry.itemCatalogIds.insert(item.catalogId)
                known[key] = entry
            }
        }
        func lookup(_ path: String) -> Known? {
            if let item = itemIDs[path] { return item }
            return known[RiskPolicy.canonical(AIPaths.expand(path, home: home))]
        }
        let homes = [home] + (realpath(home, nil).map { real in
            defer { free(real) }
            return [String(decoding: Data(bytes: real, count: strlen(real)), as: UTF8.self)]
        } ?? [])

        var seen = Set<String>()
        var recommendations: [AIRecommendation] = []
        for rec in raw.recommendations {
            guard let match = lookup(rec.path), seen.insert(match.path).inserted else { continue }
            let pathEntry = match.isItemID
                ? match.itemCatalogIds.first.flatMap { catalog.entry(id: $0) }
                : catalog.match(path: match.path, home: home)
            var verdict: Risk
            if let classifier, match.isItemID, let pathEntry {
                verdict = classifier.classify(entry: pathEntry, paths: [], ai: rec.verdict).risk
            } else if let classifier, !match.isItemID {
                verdict = classifier.classify(path: match.path, ai: rec.verdict).risk
            } else {
                verdict = RiskPolicy.effectiveRisk(path: match.path, home: home, catalog: pathEntry?.risk, ai: rec.verdict)
            }
            if let itemRisk = match.itemRisk { verdict = .strictest(verdict, itemRisk) }

            var action: AIAction?
            switch rec.action {
            case .trash(let path):
                // Only the path itself (not "~/Library" for "~/Library/x"), with a Trash entry and outside what is protected.
                if !match.isItemID, let target = lookup(path), target.path == match.path,
                   let pathEntry, case .trash = pathEntry.cleanup,
                   RiskPolicy.trashRefusal(forCanonicalPath: RiskPolicy.canonical(match.path), homes: homes, catalog: catalog) == nil {
                    action = .trash(path: match.path)
                }
            case .runCatalogCommand(let id):
                let related = id == pathEntry?.id || match.itemCatalogIds.contains(id)
                if related, let entry = catalog.entry(id: id), entry.cleanup != .info {
                    verdict = .strictest(verdict, classifier?.baseRisk(of: entry) ?? entry.risk)
                    action = .runCatalogCommand(id: id)
                }
            case nil:
                break
            }
            if case .trash = action, verdict != .safe { action = nil }
            if verdict == .doNotTouch { action = nil }
            recommendations.append(AIRecommendation(
                id: match.path, path: match.path, verdict: verdict, reason: rec.reason,
                bytes: match.bytes, action: action))
        }

        // Reclaimable: safe recommendations with an action, without counting twice a path inside another.
        let counted = recommendations.filter { $0.verdict == .safe && $0.action != nil }
        let reclaimable = counted.filter { rec in
            !counted.contains { other in
                other.path != rec.path && RiskPolicy.isInside(RiskPolicy.canonical(rec.path),
                                                              root: RiskPolicy.canonical(other.path))
            }
        }.reduce(Int64(0)) { $0 + $1.bytes }
        return AIReport(summary: raw.summary, recommendations: recommendations, reclaimableBytes: reclaimable)
    }

    // MARK: Chat

    /// The reply's text as it arrives. The whole conversation is sent on every turn.
    public func chat(history: [ChatMessage], context: String) -> AsyncThrowingStream<String, Error> {
        let arguments = arguments(systemPrompt: Self.chatSystemPrompt(language: language)) + ["--output-format", "stream-json", "--verbose", "--include-partial-messages"]
        let conversation = history.map { "\($0.role == .user ? "User" : "Assistant"): \($0.text)" }
            .joined(separator: "\n\n")
        let prompt = """
        Disk context (JSON, metadata only):
        \(context)

        Conversation so far:
        \(conversation)

        Reply as the Assistant to the User's last message. Do not use complex Markdown.
        """
        return streamResponse(arguments: arguments, prompt: prompt)
    }

    // MARK: Performance

    static func performanceSystemPrompt(language: String) -> String {
        """
        You are the assistant of Airy, a macOS app. You only see memory, CPU and temperature figures and the names \
        of the open apps, never files or content. Explain in a few simple sentences why this Mac may be slow and \
        which apps would be worth quitting. Do not recommend "freeing RAM", `purge` or quitting system processes, \
        and you cannot do anything yourself: the user quits the apps from Performance. \
        \(replyInstruction(language: language))
        """
    }

    static var performanceSystemPrompt: String { performanceSystemPrompt(language: AiryLanguage.source) }

    /// "Why is it slow?": the same locked-down invocation as the chat; `context` = `PerformanceAIContext.build`.
    public func explainSlowness(context: String) -> AsyncThrowingStream<String, Error> {
        let arguments = arguments(systemPrompt: Self.performanceSystemPrompt(language: language))
            + ["--output-format", "stream-json", "--verbose", "--include-partial-messages"]
        let prompt = "State of the Mac (JSON, only figures and app names):\n\(context)\n\nWhy may it be slow and what would you do?"
        return streamResponse(arguments: arguments, prompt: prompt)
    }

    /// The text of a `stream-json` reply as it arrives, in an empty directory.
    private func streamResponse(arguments: [String], prompt: String) -> AsyncThrowingStream<String, Error> {
        let runner = runner
        let claudePath = claudePath
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await withScratchDirectory { dir in
                        var finished = false
                        for try await line in runner.stream(claudePath, arguments, stdin: prompt,
                                                            workingDirectory: dir, timeout: Self.timeout) {
                            switch try Self.parseStreamLine(line) {
                            case .text(let text): continuation.yield(text)
                            case .done: finished = true
                            case .ignore: break
                            }
                            if finished { break }
                        }
                        if !finished { throw AIError.invalidResponse(String(localized: "Claude finished without a reply", bundle: .airyCore)) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: mapError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    enum StreamLine: Equatable { case text(String), done, ignore }

    /// Only the `text_delta` events and the final `result` matter; every other line is ignored.
    static func parseStreamLine(_ line: String) throws -> StreamLine {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            return .ignore
        }
        switch object["type"] as? String {
        case "stream_event":
            guard let event = object["event"] as? [String: Any], event["type"] as? String == "content_block_delta",
                  let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String else { return .ignore }
            return .text(text)
        case "result":
            if object["is_error"] as? Bool == true {
                throw AIError.failed(snippet(object["result"] as? String ?? String(localized: "unknown error", bundle: .airyCore)))
            }
            return .done
        default:
            return .ignore
        }
    }

    // MARK: Utilities

    /// Claude runs in an empty, freshly created directory, which is deleted at the end.
    private func withScratchDirectory<T>(_ body: (String) async throws -> T) async throws -> T {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("airy-claude-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: url) }
        return try await body(url.path)
    }

    private func mapError(_ error: Error) -> Error {
        switch error {
        case let error as AIError: return error
        case CommandError.timedOut: return AIError.timedOut
        case CommandError.lineTooLong: return AIError.invalidResponse(String(localized: "reply too long", bundle: .airyCore))
        case CommandError.launchFailed(_, let message):
            return ClaudeLocator.isExecutableFile(claudePath) ? AIError.failed(message) : AIError.notInstalled
        case is CancellationError: return error
        default: return AIError.failed(String(describing: error))
        }
    }

    static func snippet(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 300 ? String(trimmed.prefix(300)) + "…" : trimmed
    }

    /// `AIReport` schema for `--json-schema` (verdicts as text).
    static let reportSchema: String = {
        let action: [String: Any] = [
            "type": "object",
            "properties": [
                "type": ["type": "string", "enum": ["trash", "runCatalogCommand"]],
                "path": ["type": "string", "description": "For trash: a path from the context."],
                "id": ["type": "string", "description": "For runCatalogCommand: a catalogId from the context."],
            ],
            "required": ["type"],
            "additionalProperties": false,
        ]
        let recommendation: [String: Any] = [
            "type": "object",
            "properties": [
                "path": ["type": "string"],
                "verdict": ["type": "string", "enum": ["safe", "yourCall", "doNotTouch"]],
                "reason": ["type": "string"],
                "bytes": ["type": "integer"],
                "action": action,
            ],
            "required": ["path", "verdict", "reason", "bytes"],
            "additionalProperties": false,
        ]
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "summary": ["type": "string"],
                "recommendations": ["type": "array", "items": recommendation],
                "reclaimableBytes": ["type": "integer"],
            ],
            "required": ["summary", "recommendations", "reclaimableBytes"],
            "additionalProperties": false,
        ]
        let data = try! JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }()
}
