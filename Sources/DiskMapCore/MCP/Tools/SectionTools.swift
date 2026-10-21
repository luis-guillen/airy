import Foundation
import Synchronization

// MCP tools for the phase 2 sections (Uninstaller, Large and old, Duplicates). They only read
// metadata (paths, sizes, dates, ids) or propose through `airy://`; they never read a file's contents,
// never quit or uninstall apps and never send Duplicates fingerprints.

private let sectionReadOnly = MCPToolAnnotations(readOnly: true, destructive: false, idempotent: true)

private func sectionSchema(_ properties: [String: JSONValue] = [:], required: [String] = []) -> JSONValue {
    var schema: [String: JSONValue] = [
        "type": .string("object"), "properties": .object(properties), "additionalProperties": .bool(false),
    ]
    if !required.isEmpty { schema["required"] = .array(required.map { .string($0) }) }
    return .object(schema)
}

private func integer(_ minimum: Int64, _ maximum: Int64? = nil, _ description: String) -> JSONValue {
    var schema: [String: JSONValue] = [
        "type": .string("integer"), "minimum": .number(Double(minimum)), "description": .string(description),
    ]
    if let maximum { schema["maximum"] = .number(Double(maximum)) }
    return .object(schema)
}

private let bundleIDSchema: JSONValue = .object([
    "type": .string("string"), "minLength": .number(1), "maxLength": .number(200),
    "description": .string("The app's bundle id (e.g. com.example.foo), as list_apps shows it."),
])

enum SectionText {
    static let unknownApp = "There is no installed app with that identifier."
    static let noIndex = "There is no saved scan yet. Open Airy or use rescan."
    static let noDuplicates = "There is no duplicates search yet. Run one in Airy › Duplicates."
}

extension MCPFormat {
    /// Same format as `risk(_:)` for a risk with its reason (leftovers, orphans).
    static func risk(_ risk: Risk, reasons: [String]) -> [String: JSONValue] {
        ["risk": .string(riskName(risk)), "risk_label": .string(risk.label), "protected_by": .null,
         "reasons": .array(reasons.map { .string($0) })]
    }

    static func source(_ app: AppRecord) -> String {
        app.caskToken != nil ? "homebrew" : app.isAppStore ? "app_store" : "other"
    }

    /// Fields shared by `list_apps` and `explain_app`.
    static func app(_ app: AppRecord, bytes: Int64?, running: Bool?, refusal: String?) -> [String: JSONValue] {
        [
            "name": .string(app.name), "bundle_id": .string(app.bundleID), "version": optional(app.version),
            "path": .string(app.path), "app_bytes": bytes.map(number) ?? .null, "last_used": iso(app.lastUsed),
            "running": running.map { .bool($0) } ?? .null, "source": .string(source(app)),
            "can_uninstall": .bool(refusal == nil), "refusal": optional(refusal),
        ]
    }

    /// Inventory apps with that bundle id (case-insensitive); the first one by path.
    static func findApp(_ id: String, in inventory: AppInventorySnapshot) -> AppRecord? {
        inventory.apps.filter { $0.bundleID.caseInsensitiveCompare(id) == .orderedSame }
            .sorted { $0.path < $1.path }.first
    }
}

// MARK: - list_apps

public struct ListAppsTool: MCPTool {
    public init() {}
    public var name: String { "list_apps" }
    public var description: String {
        "Lists the installed apps: name, bundle id, version, path, .app size, last use, whether it is open, "
            + "origin (Homebrew, App Store or other) and whether Airy could uninstall it. It does not compute leftovers (use explain_app)."
    }
    public var inputSchema: JSONValue {
        sectionSchema([
            "limit": integer(1, 500, "Maximum number of apps (100 by default)."),
            "sort": .object(["type": .string("string"), "enum": .array(["size", "name", "last_used"].map { .string($0) }),
                             "description": .string("size (default), name or last_used (least used first).")]),
        ])
    }
    public var annotations: MCPToolAnnotations { sectionReadOnly }

    public func call(_ arguments: [String: JSONValue], context: MCPCallContext) async -> MCPToolResult {
        let env = context.environment
        let limit = arguments["limit"]?.intValue ?? 100
        let sort = arguments["sort"]?.stringValue ?? "size"
        let inventory = await env.inventorySnapshot()
        let apps = inventory.apps.filter { !$0.isSystem }
        // Only the .app's size, with a time budget: what there is no time to measure comes out as null.
        final class Sizes: Sendable { let values = Mutex<[String: Int64]>([:]) }
        let box = Sizes()
        // By name or by use, only the returned rows are measured (not every app on every query).
        let paths: [String] = switch sort {
        case "name": apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .prefix(max(limit, 0)).map(\.path)
        case "last_used": apps.sorted { ($0.lastUsed ?? .distantFuture) < ($1.lastUsed ?? .distantFuture) }
            .prefix(max(limit, 0)).map(\.path)
        default: apps.map(\.path)
        }
        let measured = await TimeBudget.run(.seconds(20)) {
            for path in paths {
                if Task.isCancelled { return false }
                if let bytes = AllocatedSize.of(path) { box.values.withLock { $0[path] = bytes } }
            }
            return true
        } ?? false
        let sizes = box.values.withLock { $0 }
        let sorted: [AppRecord]
        switch sort {
        case "name": sorted = apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case "last_used": sorted = apps.sorted { ($0.lastUsed ?? .distantFuture) < ($1.lastUsed ?? .distantFuture) }
        default: sorted = apps.sorted { (sizes[$0.path] ?? -1, $1.name) > (sizes[$1.path] ?? -1, $0.name) }
        }
        let finder = env.leftoverFinder()
        let rows: [JSONValue] = sorted.prefix(limit).map { app in
            .object(MCPFormat.app(app, bytes: sizes[app.path], running: env.runningApps.isRunning(bundleID: app.bundleID),
                                  refusal: finder.refusal(for: app)))
        }
        let value: JSONValue = .object([
            "complete": .bool(inventory.complete && measured), "apps": .array(rows),
        ])
        return .ok(value, summary: "\(rows.count) of \(apps.count) apps.")
    }
}

// MARK: - explain_app

public struct ExplainAppTool: MCPTool {
    public init() {}
    public var name: String { "explain_app" }
    public var description: String {
        "Explains an installed app (by bundle id): its real size with leftovers, each leftover with its risk and whether it comes "
            + "preselected, who it shares data with and whether Airy would uninstall it. It only reads; it changes nothing."
    }
    public var inputSchema: JSONValue { sectionSchema(["bundle_id": bundleIDSchema], required: ["bundle_id"]) }
    public var annotations: MCPToolAnnotations { sectionReadOnly }

    public func call(_ arguments: [String: JSONValue], context: MCPCallContext) async -> MCPToolResult {
        let env = context.environment
        let id = arguments["bundle_id"]?.stringValue ?? ""
        let inventory = await env.inventorySnapshot()
        guard let app = MCPFormat.findApp(id, in: inventory) else { return .error(SectionText.unknownApp) }
        let plan = await env.leftoverFinder().plan(for: app, inventory: inventory)
        var object = MCPFormat.app(app, bytes: plan.appBytes, running: env.runningApps.isRunning(bundleID: app.bundleID),
                                   refusal: plan.refusal)
        object["real_bytes"] = MCPFormat.number(plan.realBytes)
        object["leftover_bytes"] = MCPFormat.number(plan.leftoverBytes)
        object["size_complete"] = .bool(plan.sizeComplete)
        object["shared_with"] = MCPFormat.optional(plan.sharedWith)
        object["last_opened"] = MCPFormat.iso(env.usage.lastUsed(bundlePath: app.path))
        object["leftovers"] = .array(plan.leftovers.map { leftover in
            var row: [String: JSONValue] = [
                "kind": .string(leftover.kind.rawValue), "path": .string(leftover.path),
                "bytes": MCPFormat.number(leftover.bytes), "preselected": .bool(leftover.preselected),
                "matched_by_name": .bool(leftover.matchedByName), "reason": .string(leftover.reason),
            ]
            row.merge(MCPFormat.risk(leftover.risk, reasons: [leftover.reason])) { _, new in new }
            return .object(row)
        })
        let summary = plan.refusal.map { "“\(app.name)”: \($0)" }
            ?? "“\(app.name)” takes up \(Format.bytes(plan.realBytes)) with its leftovers."
        return .ok(.object(object), summary: summary)
    }
}

// MARK: - list_orphans

public struct ListOrphansTool: MCPTool {
    public init() {}
    public var name: String { "list_orphans" }
    public var description: String {
        "Lists leftovers of apps that are no longer installed (caches, logs and saved state unused for a long "
            + "time). If the app inventory is not reliable, it does not decide. It only reads."
    }
    public var inputSchema: JSONValue { sectionSchema() }
    public var annotations: MCPToolAnnotations { sectionReadOnly }

    public func call(_ arguments: [String: JSONValue], context: MCPCallContext) async -> MCPToolResult {
        let env = context.environment
        let inventory = await env.inventorySnapshot()
        let finder = OrphanFinder(home: env.home, gate: env.pathGate(), lookup: env.bundleLookup)
        switch await finder.scan(inventory: inventory) {
        case .undecided(let reason):
            return .ok(.object(["decided": .bool(false), "reason": .string(reason), "groups": .array([])]),
                       summary: reason)
        case .found(let groups):
            let rows: [JSONValue] = groups.map { group in
                .object([
                    "bundle_id": .string(group.bundleID), "paths": .array(group.paths.map { .string($0) }),
                    "bytes": MCPFormat.number(group.bytes), "last_modified": MCPFormat.iso(group.lastModified),
                    "risk": .string(MCPFormat.riskName(group.risk)), "risk_label": .string(group.risk.label),
                ])
            }
            return .ok(.object(["decided": .bool(true), "groups": .array(rows)]),
                       summary: "\(rows.count) groups of orphaned leftovers.")
        }
    }
}

// MARK: - list_large_old

public struct ListLargeOldTool: MCPTool {
    public init() {}
    public var name: String { "list_large_old" }
    public var description: String {
        "Lists large, unused files from the last saved scan (it does not walk the disk), with their risk. "
            + "Filters: min_bytes, older_than_months, kind, scope (home or everything). It only reads."
    }
    public var inputSchema: JSONValue {
        sectionSchema([
            "min_bytes": integer(1_000_000, nil, "Minimum size in bytes (100000000 by default)."),
            "older_than_months": integer(0, 120, "Months without opening or modifying (0 = any date)."),
            "kind": .object(["type": .string("string"),
                             "enum": .array(ContentKind.allCases.map { .string($0.rawValue) }),
                             "description": .string("Content kind.")]),
            "scope": .object(["type": .string("string"), "enum": .array([.string("home"), .string("everything")]),
                              "description": .string("home (default) or everything.")]),
            "limit": integer(1, 200, "Maximum number of files (50 by default)."),
        ])
    }
    public var annotations: MCPToolAnnotations { sectionReadOnly }

    public func call(_ arguments: [String: JSONValue], context: MCPCallContext) async -> MCPToolResult {
        let env = context.environment
        let (scan, failure) = MCPFormat.loadIndex(env)
        if let failure { return .error(failure) }
        guard let scan else { return .error(SectionText.noIndex) }
        guard let classifier = env.classifier() else { return .error(env.catalogError ?? ActionText.noCatalog) }
        var query = LargeOldQuery()
        query.minBytes = Int64(arguments["min_bytes"]?.intValue ?? 100_000_000)
        let months = arguments["older_than_months"]?.intValue ?? 0
        query.minMonthsIdle = months > 0 ? months : nil
        if let kind = arguments["kind"]?.stringValue.flatMap(ContentKind.init(rawValue:)) { query.kinds = [kind] }
        query.scope = arguments["scope"]?.stringValue == "everything" ? .everything : .home
        query.limit = arguments["limit"]?.intValue ?? 50
        let finder = LargeOldFinder(classifier: classifier, catalog: env.catalog, gate: env.pathGate(), home: env.home,
                                    usage: env.fileUsage)
        let files = finder.find(in: scan.root, query: query)
        let rows: [JSONValue] = files.prefix(query.limit).map { file in
            var row: [String: JSONValue] = [
                "path": .string(file.path), "name": .string(file.name), "bytes": MCPFormat.number(file.bytes),
                "kind": .string(file.kind.rawValue), "last_modified": MCPFormat.iso(file.lastModified),
                "last_opened": MCPFormat.iso(file.lastOpened),
            ]
            row.merge(MCPFormat.risk(file.risk, reasons: file.reasons)) { _, new in new }
            if let protection = file.protection { row["protected_by"] = .string(protection.source.rawValue) }
            return .object(row)
        }
        return .ok(.object(["files": .array(rows)]), summary: "\(rows.count) large files.")
    }
}

// MARK: - list_duplicates

public struct ListDuplicatesTool: MCPTool {
    public init() {}
    public var name: String { "list_duplicates" }
    public var description: String {
        "Returns the last duplicates search done in Airy: per group, size, what would be freed, the copy "
            + "that would be kept and the other copies. Only paths and sizes; never the contents nor fingerprints."
    }
    public var inputSchema: JSONValue { sectionSchema(["limit": integer(1, 200, "Maximum number of groups (50 by default).")]) }
    public var annotations: MCPToolAnnotations { sectionReadOnly }

    public func call(_ arguments: [String: JSONValue], context: MCPCallContext) async -> MCPToolResult {
        let limit = arguments["limit"]?.intValue ?? 50
        let file: DuplicateReport.File?
        do { file = try DuplicateReport.load(from: context.environment.paths.duplicatesFile) } catch {
            return .error("Could not read the last duplicates search.")
        }
        guard let file else { return .error(SectionText.noDuplicates) }
        let rows: [JSONValue] = file.groups.prefix(limit).map { group in
            .object([
                "size": MCPFormat.number(group.size), "reclaimable_bytes": MCPFormat.number(group.reclaimableBytes),
                "keeper": .string(group.keeper), "copies": .array(group.copies.map { .string($0) }),
            ])
        }
        let value: JSONValue = .object([
            "date": MCPFormat.iso(file.date), "complete": .bool(file.complete), "groups": .array(rows),
        ])
        return .ok(value, summary: "\(rows.count) groups of duplicates.")
    }
}

// MARK: - propose_uninstall

public struct ProposeUninstallTool: MCPTool {
    public init() {}
    public var name: String { "propose_uninstall" }
    public var description: String {
        "Proposes to the user to uninstall an app (by bundle id) with a reason: it opens Airy with the confirmation "
            + "prepared. It never quits or uninstalls anything; the user decides. dry_run: true returns the URL without opening it."
    }
    public var inputSchema: JSONValue {
        sectionSchema([
            "bundle_id": bundleIDSchema,
            "reason": .object(["type": .string("string"), "minLength": .number(1),
                               "maxLength": .number(Double(AiryURLCommand.maxReason)),
                               "description": .string("Why you propose it; the user will see it in the confirmation.")]),
            "dry_run": .object(["type": .string("boolean"),
                                "description": .string("true: returns the link without opening Airy (false by default).")]),
        ], required: ["bundle_id", "reason"])
    }
    public var annotations: MCPToolAnnotations { MCPToolAnnotations(readOnly: false, destructive: false, idempotent: false) }

    public func call(_ arguments: [String: JSONValue], context: MCPCallContext) async -> MCPToolResult {
        let env = context.environment
        let dry = arguments["dry_run"]?.boolValue ?? false
        let id = arguments["bundle_id"]?.stringValue ?? ""
        let reason = (arguments["reason"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        func log(_ title: String, outcome: String, message: String) {
            try? env.log.append(OperationRecord(
                runID: UUID(), date: Date(), actor: .agent(client: context.client), action: "propose",
                itemID: id, title: title, paths: [], command: nil, dryRun: dry, outcome: outcome, bytes: 0,
                message: message, proposedBy: nil))
        }
        func refuse(_ title: String, _ message: String) -> MCPToolResult {
            log(title, outcome: "blocked", message: message)
            return .error(message)
        }

        // The agents switch (or unreadable settings) blocks everything, `dry_run` included.
        if let refusal = AgentGate.refusal(env) { return refuse(id, refusal) }
        guard (1...AiryURLCommand.maxReason).contains(reason.count) else {
            return refuse(id, "“reason” is required (between 1 and \(AiryURLCommand.maxReason) characters).")
        }
        let inventory = await env.inventorySnapshot()
        guard let app = MCPFormat.findApp(id, in: inventory) else { return refuse(id, SectionText.unknownApp) }
        if let refusal = env.leftoverFinder().refusal(for: app) { return refuse(app.name, refusal) }

        let command = AiryURLCommand.uninstall(bundleID: app.bundleID, reason: reason,
                                               agent: String(context.client.prefix(AiryURLCommand.maxAgent)))
        let url = command.url
        // Round trip: what is opened is exactly what the app will accept.
        guard let parsed = AiryURLCommand(url: url), case .uninstall = parsed else {
            return refuse(app.name, "Airy would not accept that proposal (invalid identifier).")
        }
        if !dry, await !env.urlOpener.open(url) {
            log(app.name, outcome: "failed", message: ActionText.noApp)
            return .error(ActionText.noApp)
        }
        log(app.name, outcome: "pending_user", message: ActionText.proposed)
        let value: JSONValue = .object([
            "status": .string("pending_user_confirmation"), "url": .string(url.absoluteString),
            "dry_run": .bool(dry), "message": .string(ActionText.proposed),
        ])
        return .ok(value, summary: dry ? "Without opening Airy (dry_run): \(url.absoluteString)" : ActionText.proposed)
    }
}
