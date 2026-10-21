import Foundation

// Read-only MCP tools. They work with the saved index, `lstat`, the catalog and the Cleanup
// detection: they never read the contents of any file.

/// Common format of the responses.
public enum MCPFormat {
    /// `{risk, risk_label, protected_by, reasons}` from the classifier's verdict.
    public static func risk(_ c: Classification) -> [String: JSONValue] {
        let riskName: String
        switch c.risk {
        case .safe: riskName = "safe"
        case .yourCall: riskName = "yourCall"
        case .doNotTouch: riskName = "doNotTouch"
        }
        let protectedBy: JSONValue = switch c.protection?.source {
        case .airy?: .string("airy")
        case .user?: .string("user")
        case nil: .null
        }
        return [
            "risk": .string(riskName),
            "risk_label": .string(c.risk.label),
            "protected_by": protectedBy,
            "reasons": .array(c.reasons.map { .string($0) }),
        ]
    }

    static func optional(_ text: String?) -> JSONValue { text.map { .string($0) } ?? .null }

    static func number(_ value: Int64) -> JSONValue { .number(Double(value)) }

    static func iso(_ date: Date?) -> JSONValue {
        guard let date else { return .null }
        return .string(ISO8601DateFormatter().string(from: date))
    }

    /// `~` and `~/…` are expanded; absolute paths only, without control characters; `.`, `..` and `//` are resolved
    /// in the text (without touching the disk). `nil` if it is not a valid path.
    static func normalisedPath(_ raw: String, home: String) -> String? {
        var path = raw
        if path == "~" { path = home } else if path.hasPrefix("~/") { path = home + path.dropFirst(1) }
        guard path.hasPrefix("/"), !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            return nil
        }
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { _ = parts.popLast(); continue }
            parts.append(part)
        }
        return "/" + parts.joined(separator: "/")
    }

    static func join(_ parent: String, _ name: String) -> String {
        parent == "/" ? "/" + name : parent + "/" + name
    }

    /// Index node for a normalized absolute path, or `nil` if it is not there.
    static func node(at path: String, in root: FileNode) -> FileNode? {
        if path == "/", root.name.isEmpty || root.name == "/" { return root }
        return CleanupScanner.node(at: path, in: root)
    }

    static func loadIndex(_ env: AiryEnvironment) -> (scan: ScanResult?, failure: String?) {
        do { return (try env.index.loadScan(), nil) } catch { return (nil, "Could not read the last scan.") }
    }
}

private func objectSchema(_ properties: [String: JSONValue] = [:], required: [String] = []) -> JSONValue {
    var schema: [String: JSONValue] = [
        "type": .string("object"),
        "properties": .object(properties),
        "additionalProperties": .bool(false),
    ]
    if !required.isEmpty { schema["required"] = .array(required.map { .string($0) }) }
    return .object(schema)
}

private let readOnly = MCPToolAnnotations(readOnly: true, destructive: false, idempotent: true)

// MARK: - get_disk_summary

public struct GetDiskSummaryTool: MCPTool {
    public init() {}
    public var name: String { "get_disk_summary" }
    public var description: String {
        "Disk summary: capacity, free and purgeable space, scanned bytes and breakdown by kind, according to Airy's last "
            + "saved scan. `scan_complete` is false if some folders could not be accessed in that scan. "
            + "`full_disk_access` is the permission of the agent's process (airy-mcp), not that of the Airy app."
    }
    public var inputSchema: JSONValue { objectSchema() }
    public var annotations: MCPToolAnnotations { readOnly }

    public func call(_ arguments: [String: JSONValue], context: MCPCallContext) async -> MCPToolResult {
        let env = context.environment
        let loaded = MCPFormat.loadIndex(env)
        if let failure = loaded.failure { return .error(failure) }
        guard let scan = loaded.scan else {
            return .ok(.object(["scan_available": .bool(false)]), summary: "There is no saved scan yet. Open Airy or use rescan.")
        }
        let capacity = env.capacity()
        let lastScan = scan.scannedAt
        let kinds: [JSONValue] = zip(ContentKind.allCases, scan.root.kindBytes)
            .filter { $0.1 > 0 }
            .sorted { ($0.1, $1.0.rawValue) > ($1.1, $0.0.rawValue) }
            .map { .object(["kind": .string($0.0.rawValue), "title": .string($0.0.title), "bytes": MCPFormat.number($0.1)]) }
        let value: JSONValue = .object([
            "scan_available": .bool(true),
            "scan_complete": .bool(scan.inaccessible.isEmpty),
            "scan_status": .string(ScanCompleteness.of(scan).jsonName),
            "inaccessible_count": .number(Double(scan.inaccessible.count)),
            "last_scan": MCPFormat.iso(lastScan),
            "total_bytes": capacity.map { MCPFormat.number($0.total) } ?? .null,
            "free_bytes": capacity.map { MCPFormat.number($0.available) } ?? .null,
            "purgeable_bytes": capacity.map { MCPFormat.number(max(0, $0.importantAvailable - $0.available)) } ?? .null,
            "analyzed_bytes": MCPFormat.number(scan.root.allocatedSize),
            "by_kind": .array(kinds),
            "full_disk_access": .bool(env.probes.hasFullDiskAccess()),
        ])
        let note = scan.inaccessible.isEmpty ? "" : " (incomplete scan: some folders could not be accessed)"
        return .ok(value, summary: "Disk summary from the last scan\(note).")
    }
}

// MARK: - list_largest

public struct ListLargestTool: MCPTool {
    public init() {}
    public var name: String { "list_largest" }
    public var description: String {
        "Lists what takes the most space inside a folder of the last scan (by default the scan root), "
            + "largest to smallest, with the risk of deleting each item. Metadata only."
    }
    public var inputSchema: JSONValue {
        objectSchema([
            "path": .object(["type": .string("string"), "description": .string("Absolute path or starting with ~."), "maxLength": .number(4096)]),
            "limit": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(200)]),
        ])
    }
    public var annotations: MCPToolAnnotations { readOnly }

    public func call(_ arguments: [String: JSONValue], context: MCPCallContext) async -> MCPToolResult {
        let env = context.environment
        var limit = 20
        if let raw = arguments["limit"] {
            guard let n = raw.intValue, (1...200).contains(n) else { return .error("limit must be an integer between 1 and 200.") }
            limit = n
        }
        let loaded = MCPFormat.loadIndex(env)
        if let failure = loaded.failure { return .error(failure) }
        guard let scan = loaded.scan else { return .error("There is no saved scan yet. Open Airy or use rescan.") }
        guard let classifier = env.classifier() else { return .error(env.catalogError ?? "The catalog is not available.") }

        let path: String, node: FileNode
        if let raw = arguments["path"]?.stringValue {
            guard let normal = MCPFormat.normalisedPath(raw, home: env.home) else {
                return .error("The path must be absolute (or start with ~).")
            }
            guard let found = MCPFormat.node(at: normal, in: scan.root) else {
                return .error("That folder is not in the last scan.")
            }
            path = normal; node = found
        } else if let root = MCPFormat.node(at: "/", in: scan.root) {
            path = "/"; node = root
        } else {
            // The scan does not start at "/": its root is used.
            path = scan.root.name.isEmpty ? "/" : scan.root.name; node = scan.root
        }

        let partial = PartialScanIndex(inaccessible: scan.inaccessible)
        let children = node.children.sorted { ($0.allocatedSize, $1.name) > ($1.allocatedSize, $0.name) }.prefix(limit)
        let rows: [JSONValue] = children.map { child in
            if child.aggregatedCount > 0 {
                return .object([
                    "name": .string("Other"), "aggregated_count": .number(Double(child.aggregatedCount)),
                    "bytes": MCPFormat.number(child.allocatedSize), "path": .null,
                    "size_partial": .bool(partial.isPartial(path)),
                ])
            }
            let childPath = MCPFormat.join(path, child.name)
            var row: [String: JSONValue] = [
                "name": .string(child.name), "path": .string(childPath),
                "bytes": MCPFormat.number(child.allocatedSize), "kind": .string(child.dominantKind.rawValue),
                "last_modified": MCPFormat.iso(child.lastModified), "is_directory": .bool(child.isDirectory),
                "size_partial": .bool(partial.isPartial(childPath)),
            ]
            row.merge(MCPFormat.risk(classifier.classify(path: childPath))) { $1 }
            return .object(row)
        }
        let value: JSONValue = .object(["path": .string(path), "children": .array(rows)])
        return .ok(value, summary: "Largest items in \(Format.tildePath(path, home: env.home)) (\(rows.count) items).")
    }
}

// MARK: - explain_path

public struct ExplainPathTool: MCPTool {
    public init() {}
    public var name: String { "explain_path" }
    public var description: String {
        "Explains a path: what it is, who creates it, whether it regenerates, how much it takes up according to the last scan and the risk of "
            + "deleting it (Airy's traffic light). For a protected path, `protection_scope` says whether only the folder "
            + "as a whole is protected (`folder_only`: its contents can still be cleaned) or everything inside too "
            + "(`folder_and_contents`). It reads the contents of nothing."
    }
    public var inputSchema: JSONValue {
        objectSchema(["path": .object(["type": .string("string"), "minLength": .number(1), "maxLength": .number(4096)])],
                     required: ["path"])
    }
    public var annotations: MCPToolAnnotations { readOnly }

    public func call(_ arguments: [String: JSONValue], context: MCPCallContext) async -> MCPToolResult {
        let env = context.environment
        guard let raw = arguments["path"]?.stringValue,
              let path = MCPFormat.normalisedPath(raw, home: env.home) else {
            return .error("The path must be absolute (or start with ~).")
        }
        guard let classifier = env.classifier() else { return .error(env.catalogError ?? "The catalog is not available.") }

        let entry = env.catalog?.match(path: path, home: env.home)
        let folderText = FolderExplanations.text(for: path, home: env.home)
        let title = entry?.title ?? (path == "/" ? "/" : (path as NSString).lastPathComponent)
        let explanation = entry?.explanation ?? folderText ?? "This path is not in Airy's catalog."

        var size: JSONValue = .null
        if let scan = MCPFormat.loadIndex(env).scan, let node = MCPFormat.node(at: path, in: scan.root) {
            size = MCPFormat.number(node.allocatedSize)
        }
        var info = stat()
        let exists = lstat(path, &info) == 0

        var value: [String: JSONValue] = [
            "path": .string(path),
            "known": .bool(entry != nil || folderText != nil),
            "title": .string(title),
            "explanation": .string(explanation),
            "who_creates_it": MCPFormat.optional(entry?.whoCreatesIt),
            "regenerates": entry.map { .bool($0.regenerates) } ?? .null,
            "size_bytes": size,
            "exists": .bool(exists),
        ]
        let verdict = classifier.classify(path: path)
        value.merge(MCPFormat.risk(verdict)) { $1 }
        // Display only: whether the protection covers the contents too (`/Users`, the home or `~/Library` only
        // as a whole; `/System` or `~/Library/Mail` with everything inside).
        value["protection_scope"] = verdict.protection.map { .string($0.scope.rawValue) } ?? .null
        value["protection_scope_note"] = verdict.protection.map { .string(Self.scopeNote($0.scope)) } ?? .null
        return .ok(.object(value), summary: "\(title): \(explanation)")
    }

    /// English, like the rest of the MCP's own sentences.
    static func scopeNote(_ scope: ProtectionMatch.Scope) -> String {
        switch scope {
        case .folderOnly:
            "Airy won't delete this whole folder, but what is inside can still be cleaned: explain or list its children."
        case .folderAndContents: "Neither this folder nor anything inside it is deleted."
        }
    }
}

// MARK: - list_cleanup_items

public struct ListCleanupItemsTool: MCPTool {
    public init() {}
    public var name: String { "list_cleanup_items" }
    public var description: String {
        "Lists the cleanups Airy detects on this Mac right now, in the order of the Cleanup screen, with their risk, "
            + "size, method and whether an agent can run them (`actionable_by_agent`: only “Safe to remove” and not blocked). "
            + "Each item carries `verdict` (the label), `why` (the reason) and `short_reason` (what you lose), and `review_only` "
            + "marks the “Review only” ones, which Airy does not delete."
    }
    public var inputSchema: JSONValue { objectSchema() }
    public var annotations: MCPToolAnnotations { readOnly }

    public func call(_ arguments: [String: JSONValue], context: MCPCallContext) async -> MCPToolResult {
        let env = context.environment
        guard let scanner = env.makeScanner(), let classifier = env.classifier() else {
            return .error(env.catalogError ?? "The catalog is not available.")
        }
        let loaded = MCPFormat.loadIndex(env).scan
        let board = CleanupBoard(items: await scanner.findItems(scan: loaded?.root, inaccessible: loaded?.inaccessible ?? []))
        // With the switch off or the settings unreadable, no agent can run anything.
        let agentsEnabled = AgentGate.refusal(env) == nil
        let rows: [JSONValue] = board.displayItems.map { item in
            var verdict = classifier.classify(entry: item.entry, paths: item.paths)
            verdict.risk = .strictest(verdict.risk, item.risk)
            verdict.protection = item.protection ?? verdict.protection
            var shown = item // the risk and protection decided by the live classifier
            shown.risk = verdict.risk
            shown.protection = verdict.protection
            let method: String, command: JSONValue
            switch item.entry.cleanup {
            case .trash: method = "trash"; command = .null
            case .info: method = "info"; command = .null
            case .command(let executable, let args, _):
                method = "command"; command = .array(([executable] + args).map { .string($0) })
            }
            var row: [String: JSONValue] = [
                "id": .string(item.id), "title": .string(item.title), "bytes": MCPFormat.number(item.bytes),
                "size_text": .string(CleanupBoard.sizeText(item)),
                "upper_bound": .bool(CleanupBoard.isPartial(item)),
                "method": .string(method), "command": command,
                "blocked_by_open_apps": .array(item.blockedByOpenApps.map { .string($0) }),
                "used_by": .array(item.usedBy.map { .string($0) }),
                "blocked_reason": MCPFormat.optional(item.blockedReason),
                "preselected": .bool(item.preselected), "highlighted": .bool(item.highlighted),
                "actionable_by_agent": .bool(agentsEnabled && verdict.risk == .safe && CleanupBoard.canSelect(item)),
                "review_only": .bool(CleanupBoard.isReviewOnly(item)),
                "details": .array(item.details.map { .string($0) }),
                "size_note": MCPFormat.optional(item.sizeNote),
                "size_partial": .bool(item.sizeIsPartial),
                "verdict": .string(verdict.risk.label),
                "short_reason": MCPFormat.optional(item.entry.shortReason.map {
                    RiskExplanation.expand($0, bytes: item.bytes)
                }),
                "why": .string(RiskExplanation.why(shown, home: env.home)),
                "risk_reason": MCPFormat.optional(item.riskReason),
            ]
            row.merge(MCPFormat.risk(verdict)) { $1 }
            return .object(row)
        }
        let value: JSONValue = .object([
            "mode": .string(env.settings.load().effective.mode.rawValue), "agents_enabled": .bool(agentsEnabled),
            "items": .array(rows),
        ])
        return .ok(value, summary: "\(rows.count) cleanups detected.")
    }
}
