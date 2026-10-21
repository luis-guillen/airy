import Foundation

/// What the AI sees: metadata only (paths, sizes, dates, kinds and catalog entries).
/// The contents of a file are never read.
struct AIContextPayload: Codable {
    struct Disk: Codable {
        var totalBytes: Int64
        var freeBytes: Int64
    }

    struct Node: Codable {
        var path: String
        var bytes: Int64
        var isDirectory: Bool
        var kind: String
        var lastModified: String?
        var catalogId: String?
    }

    struct Item: Codable {
        var id: String
        var catalogId: String
        var title: String
        var explanation: String
        var paths: [String]
        var bytes: Int64
        var risk: String
        var cleanup: String
        var regenerates: Bool
        var blockedByOpenApps: [String]
        var usedByCount: Int
    }

    var disk: Disk
    var nodes: [Node]
    var cleanupItems: [Item]
}

public enum AIContextBuilder {
    static let maxDepth = 6

    /// JSON with the disk, the `maxNodes` largest nodes down to depth 6 (the scan root is 0)
    /// and the cleanup items. Paths under `home` are shown with `~`.
    public static func context(scan: FileNode?, items: [CleanupItem], catalog: Catalog, home: String,
                               maxNodes: Int = 400, diskTotal: Int64 = 0, diskFree: Int64 = 0) -> String {
        var candidates: [FileNode] = []
        if let scan {
            var stack: [(FileNode, Int)] = [(scan, 0)]
            while let (node, depth) = stack.popLast() {
                // The "Other (N items)" aggregate is not a real path.
                if node.aggregatedCount == 0 { candidates.append(node) }
                if depth < maxDepth { stack.append(contentsOf: node.children.map { ($0, depth + 1) }) }
            }
        }
        let largest = candidates
            .sorted { $0.allocatedSize != $1.allocatedSize ? $0.allocatedSize > $1.allocatedSize : $0.id < $1.id }
            .prefix(max(0, maxNodes))

        let nodes = largest.map { node -> AIContextPayload.Node in
            let path = node.path
            return AIContextPayload.Node(
                path: AIPaths.display(path, home: home), bytes: node.allocatedSize, isDirectory: node.isDirectory,
                kind: node.dominantKind.rawValue, lastModified: node.lastModified?.formatted(.iso8601),
                catalogId: catalog.match(path: path, home: home)?.id)
        }
        let cleanupItems = items.map { item in
            AIContextPayload.Item(
                id: item.id, catalogId: item.entry.id, title: item.title, explanation: item.entry.explanation,
                paths: item.paths.map { AIPaths.display($0, home: home) }, bytes: item.bytes,
                risk: item.risk.jsonName, cleanup: cleanupName(item.entry.cleanup),
                regenerates: item.entry.regenerates, blockedByOpenApps: item.blockedByOpenApps,
                usedByCount: item.usedBy.count)
        }
        let payload = AIContextPayload(
            disk: .init(totalBytes: diskTotal, freeBytes: diskFree), nodes: nodes, cleanupItems: cleanupItems)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Codable of simple types cannot fail; just in case, a valid empty JSON.
        guard let data = try? encoder.encode(payload) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    static func cleanupName(_ method: CleanupMethod) -> String {
        switch method {
        case .trash: "trash"
        case .command: "command"
        case .info: "info"
        }
    }
}

/// Conversion between absolute paths and paths with `~`.
enum AIPaths {
    static func base(_ home: String) -> String {
        home.count > 1 && home.hasSuffix("/") ? String(home.dropLast()) : home
    }

    static func display(_ path: String, home: String) -> String {
        let base = base(home)
        guard base != "/", !base.isEmpty else { return path }
        if path == base { return "~" }
        if path.hasPrefix(base + "/") { return "~" + path.dropFirst(base.count) }
        return path
    }

    static func expand(_ path: String, home: String) -> String {
        let base = base(home)
        if path == "~" { return base }
        if path.hasPrefix("~/") { return base + path.dropFirst(1) }
        return path
    }
}
