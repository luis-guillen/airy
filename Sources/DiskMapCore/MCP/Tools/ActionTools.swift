import Foundation

// Action MCP tools. An agent can only run what is "Safe to remove" (green) and not
// blocked, always through `CleanupExecutor`; everything else is proposed to the user in Airy through
// `airy://`. No tool accepts commands or paths to delete.
//
// Records: the executor records each run or preview; these tools only record their
// own refusals and the commands they hand to the app (`propose`, `show`, `rescan`).

/// Common gate: agents switch and readable settings, read on every call.
public enum AgentGate {
    static let agentsOff =
        "You have turned off agent actions in Airy (Settings › Agents)."
    static let unreadable = "Airy cannot read its settings; nothing runs until you check them in the app."

    /// `nil` if an agent can act now; otherwise, the reason for the user.
    public static func refusal(_ env: AiryEnvironment) -> String? {
        let load = env.settings.load()
        if load.isUnreadable { return unreadable }
        if !load.allowsAgentActions { return agentsOff }
        return nil
    }
}

enum ActionText {
    static func yourCall(_ title: String) -> String {
        "“\(title)” is “Your call”: only what is marked “Safe to remove” runs. Use propose_cleanup so that the user decides in Airy."
    }
    static func doNotTouch(_ title: String) -> String { "“\(title)” is “Don't delete”: Airy does not touch it." }
    static let proposed = "Proposal sent to Airy; waiting for the user's confirmation."
    static let rescan = "Scan requested from Airy. When it finishes, get_disk_summary will show the new date."
    static let noApp = "Could not open Airy (is it installed in /Applications?)."
    static let notFound = "There is no cleanup with that id right now. Use list_cleanup_items."
    static let noCatalog = "The catalog is not available."
}

extension MCPFormat {
    /// Verdict the agent sees for a detected item: the stricter of the live classifier and
    /// the detection.
    static func verdict(for item: CleanupItem, classifier: RiskClassifier) -> Classification {
        var verdict = classifier.classify(entry: item.entry, paths: item.paths)
        verdict.risk = .strictest(verdict.risk, item.risk)
        verdict.protection = item.protection ?? verdict.protection
        return verdict
    }

    /// Fresh detection, in the order of the Cleanup screen. `nil` without a catalog.
    static func detect(_ env: AiryEnvironment) async -> [CleanupItem]? {
        guard let scanner = env.makeScanner() else { return nil }
        let tree = loadIndex(env).scan?.root
        return CleanupBoard(items: await scanner.findItems(scan: tree)).items
    }

    /// Why an agent cannot run this item, or `nil`.
    static func agentRefusal(_ item: CleanupItem, classifier: RiskClassifier) -> String? {
        let verdict = verdict(for: item, classifier: classifier)
        if verdict.risk == .doNotTouch || !CleanupBoard.showsCheckbox(item) { return ActionText.doNotTouch(item.title) }
        if verdict.risk != .safe { return ActionText.yourCall(item.title) }
        guard CleanupBoard.canSelect(item) else {
            if let reason = item.blockedReason { return "“\(item.title)” cannot be cleaned right now: \(reason)" }
            if !item.blockedByOpenApps.isEmpty {
                return "“\(item.title)” cannot be cleaned right now: quit \(item.blockedByOpenApps.joined(separator: ", ")) first."
            }
            if !item.usedBy.isEmpty { return "“\(item.title)” is used by: \(item.usedBy.joined(separator: ", "))." }
            return "“\(item.title)” cannot be cleaned right now."
        }
        return nil
    }
}

private func actionSchema(_ properties: [String: JSONValue] = [:], required: [String] = []) -> JSONValue {
    var all = properties
    all["dry_run"] = .object([
        "type": .string("boolean"),
        "description": .string("true: only says what it would do, without doing it (false by default)."),
    ])
    var schema: [String: JSONValue] = [
        "type": .string("object"), "properties": .object(all), "additionalProperties": .bool(false),
    ]
    if !required.isEmpty { schema["required"] = .array(required.map { .string($0) }) }
    return .object(schema)
}

private let destructiveAction = MCPToolAnnotations(readOnly: false, destructive: true, idempotent: false)
private let appRequest = MCPToolAnnotations(readOnly: false, destructive: false, idempotent: false)

private func dryRun(_ arguments: [String: JSONValue]) -> Bool { arguments["dry_run"]?.boolValue ?? false }

/// Records the tool's own entry (a refusal or a command to the app).
private func logOwn(_ context: MCPCallContext, runID: UUID = UUID(), action: String, itemID: String? = nil,
                    title: String, paths: [String] = [], dryRun: Bool, outcome: String, message: String?) {
    try? context.environment.log.append(OperationRecord(
        runID: runID, date: Date(), actor: .agent(client: context.client), action: action, itemID: itemID,
        title: title, paths: paths, command: nil, dryRun: dryRun, outcome: outcome, bytes: 0, message: message,
        proposedBy: nil))
}

/// Recorded refusal: the message goes back to the agent as an error.
private func refuse(_ context: MCPCallContext, action: String, itemID: String? = nil, title: String,
                    paths: [String] = [], dryRun: Bool, _ message: String) -> MCPToolResult {
    logOwn(context, action: action, itemID: itemID, title: title, paths: paths, dryRun: dryRun,
           outcome: "blocked", message: message)
    return .error(message)
}

/// Result of an item: `outcome`, `bytes`, `message`.
private struct ItemResult {
    var outcome: String, bytes: Int64, message: String

    var isError: Bool { outcome == "blocked" || outcome == "failed" }

    init(_ preview: CleanupPreview) {
        switch preview {
        case .wouldTrash(_, let b): (outcome, bytes, message) = ("would_trash", b, "It would be sent to the Trash.")
        case .wouldRun(let command, let b, let upper):
            (outcome, bytes, message) = ("would_run", b, "It would run \(command.joined(separator: " "))"
                + (upper ? " (it frees at most that size)." : "."))
        case .blocked(let reason): (outcome, bytes, message) = ("blocked", 0, reason)
        }
    }

    init(_ outcome: CleanupOutcome) {
        switch outcome {
        case .freed(let b): (self.outcome, bytes, message) = ("freed", b, "Freed: \(Format.bytes(b)).")
        case .movedToTrash(let b):
            (self.outcome, bytes, message) = ("moved_to_trash", b,
                                              "Sent to the Trash (\(Format.bytes(b))); it is freed when emptied.")
        case .blocked(let reason): (self.outcome, bytes, message) = ("blocked", 0, reason)
        case .failed(let error): (self.outcome, bytes, message) = ("failed", 0, error)
        }
    }
}

private func runItem(_ item: CleanupItem, executor: CleanupExecutor, context: OperationContext,
                     dryRun: Bool, pass: RevalidationPass? = nil) async -> ItemResult {
    dryRun ? ItemResult(await executor.preview(item, context: context, pass: pass))
        : ItemResult(await executor.execute(item, context: context, pass: pass))
}

/// Opens the command in Airy (or only returns it with `dry_run`) and records the request.
private func sendToApp(_ command: AiryURLCommand, context: MCPCallContext, action: String, itemID: String? = nil,
                       title: String, paths: [String] = [], dryRun: Bool, outcome: String,
                       status: String, message: String) async -> MCPToolResult {
    let url = command.url
    if !dryRun, await !context.environment.urlOpener.open(url) {
        logOwn(context, action: action, itemID: itemID, title: title, paths: paths, dryRun: dryRun,
               outcome: "failed", message: ActionText.noApp)
        return .error(ActionText.noApp)
    }
    logOwn(context, action: action, itemID: itemID, title: title, paths: paths, dryRun: dryRun,
           outcome: outcome, message: message)
    let value: JSONValue = .object([
        "status": .string(status), "url": .string(url.absoluteString), "dry_run": .bool(dryRun),
        "message": .string(message),
    ])
    return .ok(value, summary: dryRun ? "Without opening Airy (dry_run): \(url.absoluteString)" : message)
}

/// The agent's name as it fits in the URL.
private func agentName(_ context: MCPCallContext) -> String { String(context.client.prefix(AiryURLCommand.maxAgent)) }

// MARK: - run_safe_cleanup

public struct RunSafeCleanupTool: MCPTool {
    public init() {}
    public var name: String { "run_safe_cleanup" }
    public var description: String {
        "Runs a cleanup from list_cleanup_items marked “Safe to remove” (actionable_by_agent: true): files to the "
            + "Trash or the tool's official command. Nothing “Your call” or “Don't delete”: for that, propose_cleanup. "
            + "dry_run: true only says what it would do."
    }
    public var inputSchema: JSONValue {
        actionSchema(["item_id": .object(["type": .string("string"), "minLength": .number(1),
                                          "maxLength": .number(Double(AiryURLCommand.maxItemID))])],
                     required: ["item_id"])
    }
    public var annotations: MCPToolAnnotations { destructiveAction }

    public func call(_ arguments: [String: JSONValue], context: MCPCallContext) async -> MCPToolResult {
        let env = context.environment
        let dry = dryRun(arguments)
        guard let id = arguments["item_id"]?.stringValue, !id.isEmpty else { return .error("Missing “item_id”.") }
        if let refusal = AgentGate.refusal(env) {
            return refuse(context, action: "clean", itemID: id, title: id, dryRun: dry, refusal)
        }
        guard let items = await MCPFormat.detect(env), let classifier = env.classifier(),
              let executor = env.makeExecutor() else {
            return refuse(context, action: "clean", itemID: id, title: id, dryRun: dry, env.catalogError ?? ActionText.noCatalog)
        }
        guard let item = items.first(where: { $0.id == id }) else {
            return refuse(context, action: "clean", itemID: id, title: id, dryRun: dry, ActionText.notFound)
        }
        if let refusal = MCPFormat.agentRefusal(item, classifier: classifier) {
            return refuse(context, action: "clean", itemID: id, title: item.title, paths: item.paths, dryRun: dry, refusal)
        }
        let runID = UUID()
        let result = await runItem(item, executor: executor, context: .agent(context.client, runID: runID), dryRun: dry)
        let value: JSONValue = .object([
            "run_id": .string(runID.uuidString), "item_id": .string(item.id), "title": .string(item.title),
            "dry_run": .bool(dry), "outcome": .string(result.outcome), "bytes": MCPFormat.number(result.bytes),
            "message": .string(result.message),
        ])
        return MCPToolResult(text: "\(item.title): \(result.message)\n" + value.prettyString(), structured: value,
                             isError: result.isError)
    }
}

// MARK: - run_safe_cleanup_all

public struct RunSafeCleanupAllTool: MCPTool {
    public init() {}
    public var name: String { "run_safe_cleanup_all" }
    public var description: String {
        "Runs, one after another, every “Safe to remove” cleanup ready now (the same as “Clean everything safe” "
            + "in Airy). It never touches “Your call” or “Don't delete” items. If the user turns agents off halfway, what "
            + "is left gets blocked. dry_run: true only says what it would do."
    }
    public var inputSchema: JSONValue { actionSchema() }
    public var annotations: MCPToolAnnotations { destructiveAction }

    public func call(_ arguments: [String: JSONValue], context: MCPCallContext) async -> MCPToolResult {
        let env = context.environment
        let dry = dryRun(arguments)
        let title = "Clean everything safe"
        if let refusal = AgentGate.refusal(env) {
            return refuse(context, action: "clean", title: title, dryRun: dry, refusal)
        }
        guard let items = await MCPFormat.detect(env), let classifier = env.classifier(),
              let executor = env.makeExecutor() else {
            return refuse(context, action: "clean", title: title, dryRun: dry, env.catalogError ?? ActionText.noCatalog)
        }
        let ready = CleanupBoard(items: items).readySafeItems
            .filter { MCPFormat.agentRefusal($0, classifier: classifier) == nil }
        let runID = UUID()
        let operation = OperationContext.agent(context.client, runID: runID)
        var rows: [JSONValue] = []
        var freed: Int64 = 0, trashed: Int64 = 0
        // In sequence: the executor rereads the settings for each item.
        let pass = RevalidationPass()
        for item in ready {
            let result = await runItem(item, executor: executor, context: operation, dryRun: dry, pass: pass)
            switch result.outcome {
            case "freed", "would_run": freed += result.bytes
            case "moved_to_trash", "would_trash": trashed += result.bytes
            default: break
            }
            rows.append(.object([
                "item_id": .string(item.id), "title": .string(item.title), "outcome": .string(result.outcome),
                "bytes": MCPFormat.number(result.bytes), "message": .string(result.message),
            ]))
        }
        let value: JSONValue = .object([
            "run_id": .string(runID.uuidString), "dry_run": .bool(dry), "results": .array(rows),
            "freed_bytes": MCPFormat.number(freed), "moved_to_trash_bytes": MCPFormat.number(trashed),
        ])
        let summary = ready.isEmpty
            ? "There are no “Safe to remove” cleanups ready right now."
            : "\(ready.count) “Safe to remove” cleanups\(dry ? " (dry_run, nothing done)" : ""): freed "
                + "\(Format.bytes(freed)), to the Trash \(Format.bytes(trashed))."
        return .ok(value, summary: summary)
    }
}

// MARK: - propose_cleanup

public struct ProposeCleanupTool: MCPTool {
    public init() {}
    public var name: String { "propose_cleanup" }
    public var description: String {
        "Proposes to the user, in Airy, to clean an item from list_cleanup_items (item_id) or to send a path to the "
            + "Trash (path), with a reason. It runs nothing: the user sees it and decides in the app. “Don't delete” items "
            + "and protected paths are rejected."
    }
    public var inputSchema: JSONValue {
        actionSchema([
            "item_id": .object(["type": .string("string"), "minLength": .number(1),
                                "maxLength": .number(Double(AiryURLCommand.maxItemID))]),
            "path": .object(["type": .string("string"), "description": .string("Absolute path or starting with ~."),
                             "minLength": .number(1), "maxLength": .number(Double(AiryURLCommand.maxPath))]),
            "reason": .object(["type": .string("string"), "minLength": .number(1),
                               "maxLength": .number(Double(AiryURLCommand.maxReason))]),
        ], required: ["reason"])
    }
    public var annotations: MCPToolAnnotations { appRequest }

    public func call(_ arguments: [String: JSONValue], context: MCPCallContext) async -> MCPToolResult {
        let env = context.environment
        let dry = dryRun(arguments)
        let reason = (arguments["reason"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...AiryURLCommand.maxReason).contains(reason.count) else {
            return .error("“reason” is required (between 1 and \(AiryURLCommand.maxReason) characters).")
        }
        let itemID = arguments["item_id"]?.stringValue, rawPath = arguments["path"]?.stringValue
        guard (itemID == nil) != (rawPath == nil) else { return .error("Give exactly one of “item_id” or “path”.") }
        if let refusal = AgentGate.refusal(env) {
            return refuse(context, action: "propose", itemID: itemID, title: itemID ?? rawPath ?? "",
                          paths: rawPath.map { [$0] } ?? [], dryRun: dry, refusal)
        }

        let command: AiryURLCommand, title: String, paths: [String]
        if let itemID {
            guard let items = await MCPFormat.detect(env), let classifier = env.classifier() else {
                return refuse(context, action: "propose", itemID: itemID, title: itemID, dryRun: dry,
                              env.catalogError ?? ActionText.noCatalog)
            }
            guard let item = items.first(where: { $0.id == itemID }) else {
                return refuse(context, action: "propose", itemID: itemID, title: itemID, dryRun: dry, ActionText.notFound)
            }
            let verdict = MCPFormat.verdict(for: item, classifier: classifier)
            if verdict.risk == .doNotTouch || !CleanupBoard.showsCheckbox(item) {
                return refuse(context, action: "propose", itemID: itemID, title: item.title, paths: item.paths,
                              dryRun: dry, ActionText.doNotTouch(item.title))
            }
            command = .propose(target: .item(itemID), reason: reason, agent: agentName(context))
            title = item.title; paths = item.paths
        } else {
            let raw = rawPath ?? ""
            guard let path = MCPFormat.normalisedPath(raw, home: env.home) else {
                return refuse(context, action: "propose", title: raw, paths: [raw], dryRun: dry,
                              "The path must be absolute (or start with ~).")
            }
            guard let executor = env.makeExecutor() else {
                return refuse(context, action: "propose", title: path, paths: [path], dryRun: dry,
                              env.catalogError ?? ActionText.noCatalog)
            }
            if let unsafe = executor.unsafeTrashReason(path) {
                return refuse(context, action: "propose", title: path, paths: [path], dryRun: dry,
                              "Airy does not propose sending that path to the Trash: \(unsafe)")
            }
            command = .propose(target: .path(path), reason: reason, agent: agentName(context))
            title = (path as NSString).lastPathComponent; paths = [path]
        }
        // The app validates the URL again: if it would not accept it, it is not sent.
        guard AiryURLCommand(url: command.url) != nil else {
            return refuse(context, action: "propose", itemID: itemID, title: title, paths: paths, dryRun: dry,
                          "Airy would not accept that proposal (invalid id or path).")
        }
        return await sendToApp(command, context: context, action: "propose", itemID: itemID, title: title,
                               paths: paths, dryRun: dry, outcome: "pending_user",
                               status: "pending_user_confirmation", message: ActionText.proposed)
    }
}

// MARK: - show_in_app

public struct ShowInAppTool: MCPTool {
    public init() {}
    public var name: String { "show_in_app" }
    public var description: String {
        "Opens Airy showing a path on the disk map. It changes nothing. dry_run: true returns the URL without opening it."
    }
    public var inputSchema: JSONValue {
        actionSchema(["path": .object(["type": .string("string"), "description": .string("Absolute path or starting with ~."),
                                       "minLength": .number(1), "maxLength": .number(Double(AiryURLCommand.maxPath))])],
                     required: ["path"])
    }
    public var annotations: MCPToolAnnotations { appRequest }

    public func call(_ arguments: [String: JSONValue], context: MCPCallContext) async -> MCPToolResult {
        let env = context.environment
        let dry = dryRun(arguments)
        let raw = arguments["path"]?.stringValue ?? ""
        if let refusal = AgentGate.refusal(env) {
            return refuse(context, action: "show", title: raw, paths: [raw], dryRun: dry, refusal)
        }
        guard let path = MCPFormat.normalisedPath(raw, home: env.home),
              AiryURLCommand(url: AiryURLCommand.show(path: path).url) != nil else {
            return refuse(context, action: "show", title: raw, paths: [raw], dryRun: dry,
                          "The path must be absolute (or start with ~).")
        }
        return await sendToApp(.show(path: path), context: context, action: "show",
                               title: (path as NSString).lastPathComponent, paths: [path], dryRun: dry,
                               outcome: "requested", status: "show_requested",
                               message: "Airy shows \(Format.tildePath(path, home: env.home)).")
    }
}

// MARK: - rescan

public struct RescanTool: MCPTool {
    public init() {}
    public var name: String { "rescan" }
    public var description: String {
        "Asks Airy for a new scan of the disk (opens the app). It deletes nothing. dry_run: true returns the URL without opening it."
    }
    public var inputSchema: JSONValue { actionSchema() }
    public var annotations: MCPToolAnnotations { appRequest }

    public func call(_ arguments: [String: JSONValue], context: MCPCallContext) async -> MCPToolResult {
        let dry = dryRun(arguments)
        if let refusal = AgentGate.refusal(context.environment) {
            return refuse(context, action: "rescan", title: "Scan", dryRun: dry, refusal)
        }
        return await sendToApp(.rescan, context: context, action: "rescan", title: "Scan", dryRun: dry,
                               outcome: "requested", status: "scan_requested", message: ActionText.rescan)
    }
}
