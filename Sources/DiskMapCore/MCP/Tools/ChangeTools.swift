import Foundation

// MARK: - what_changed

/// Read-only: what grew and shrank between the last two scans the app finished (by path and by kind). Metadata
/// only: paths, sizes and kinds from `scan-summary.json`; it never reads the disk or any file's contents.
public struct WhatChangedTool: MCPTool {
    public init() {}
    public var name: String { "what_changed" }
    public var description: String {
        "What changed on disk between Airy's last two finished scans: the folders and files that grew or shrank the "
            + "most (with the children that explain it) and the change per kind. Metadata only. `min_bytes` (default "
            + "1 GB) drops smaller changes; `limit` (default 5) caps each list."
    }
    public var inputSchema: JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object([
                "limit": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(50)]),
                "min_bytes": .object(["type": .string("integer"), "minimum": .number(1_000_000),
                                      "maximum": .number(1e15)]),
            ]),
            "additionalProperties": .bool(false),
        ])
    }
    public var annotations: MCPToolAnnotations { MCPToolAnnotations(readOnly: true, destructive: false, idempotent: true) }

    public func call(_ arguments: [String: JSONValue], context: MCPCallContext) async -> MCPToolResult {
        let limit = arguments["limit"]?.intValue ?? ScanChanges.defaultLimit
        let minimum = arguments["min_bytes"]?.intValue.map(Int64.init) ?? ScanChanges.defaultMinimumBytes
        let store = ScanChangeStore(directory: context.environment.paths.support)
        guard let record = store.load() else {
            return .ok(.object(["available": .bool(false)]),
                       summary: "There is no scan summary yet. It appears after Airy finishes a scan.")
        }
        guard let previous = record.previous,
              let changes = ScanChanges.compute(previous: previous, current: record.current, minimumBytes: minimum,
                                                limit: limit) else {
            return .ok(.object(["available": .bool(false), "scanned_at": MCPFormat.iso(record.current.scannedAt)]),
                       summary: "Only one scan so far: there is nothing to compare with yet.")
        }
        func row(_ change: PathChange) -> JSONValue {
            .object([
                "path": .string(change.path), "label": .string(ScanChanges.label(for: change.path)),
                "before_bytes": MCPFormat.number(change.before), "after_bytes": MCPFormat.number(change.after),
                "delta_bytes": MCPFormat.number(change.delta), "hints": .array(change.hints.map { .string($0) }),
            ])
        }
        let kinds: [JSONValue] = changes.kinds.map {
            .object(["kind": .string($0.kind.rawValue), "title": .string($0.kind.title),
                     "before_bytes": MCPFormat.number($0.before), "after_bytes": MCPFormat.number($0.after),
                     "delta_bytes": MCPFormat.number($0.delta)])
        }
        let value: JSONValue = .object([
            "available": .bool(true),
            "since": MCPFormat.iso(changes.since),
            "scanned_at": MCPFormat.iso(changes.scannedAt),
            "total_delta_bytes": MCPFormat.number(changes.totalDelta),
            "min_bytes": MCPFormat.number(minimum),
            "growth": .array(changes.growth.map(row)),
            "shrink": .array(changes.shrink.map(row)),
            "by_kind": .array(kinds),
        ])
        let headline = changes.growth.first.map { " Largest growth: \(ScanChanges.label(for: $0.path)) +\(Format.bytes($0.delta))." } ?? ""
        return .ok(value, summary: "Changes between the last two scans.\(headline)")
    }
}

// MARK: - recent_space_drop (part of get_disk_summary)

enum SpaceDropFormat {
    /// The last fast drop of free space the app noticed (within `SpaceDropStore.recentWindow`), or `null`.
    static func recent(_ env: AiryEnvironment, now: Date = Date()) -> JSONValue {
        guard let snapshot = SpaceDropStore(directory: env.paths.support).recent(now: now) else { return .null }
        return .object([
            "detected_at": MCPFormat.iso(snapshot.detectedAt),
            "dropped_bytes": MCPFormat.number(snapshot.droppedBytes),
            "minutes": .number(Double(snapshot.minutes)),
            "free_before_bytes": MCPFormat.number(snapshot.freeBefore),
            "free_after_bytes": MCPFormat.number(snapshot.freeAfter),
            "deleted_open_files_known": .bool(snapshot.filesKnown),
            "deleted_open_files": .array(snapshot.deletedOpenFiles.map {
                .object(["process": .string($0.process), "pid": .number(Double($0.pid)),
                         "bytes": MCPFormat.number($0.bytes), "path": .string($0.path)])
            }),
            "top_writers": .array(snapshot.topWriters.map {
                .object(["process": .string($0.process), "pid": .number(Double($0.pid)),
                         "bytes_written": MCPFormat.number($0.bytesWritten)])
            }),
            "summary": .string(snapshot.message),
        ])
    }
}
