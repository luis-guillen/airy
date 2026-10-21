import SwiftUI
import AppKit
import DiskMapCore

/// "What changed" on the Map: what grew and shrank the most since the previous scan, by folder and by kind.
/// Clicking a row reveals that folder in Finder. Read-only: it never offers to delete anything.
struct WhatChangedCard: View {
    let changes: ScanChanges
    let onDismiss: () -> Void

    private static let growthRows = 3
    private static let shrinkRows = 2

    var body: some View {
        GlassCard(padding: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Label("What changed", systemImage: "arrow.up.arrow.down.circle")
                        .font(.callout.weight(.semibold))
                    Text(sinceText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Hide until the next scan")
                    .accessibilityLabel(Text("Hide what changed"))
                }
                ForEach(Array(changes.growth.prefix(Self.growthRows)), id: \.path) { row($0) }
                ForEach(Array(changes.shrink.prefix(Self.shrinkRows)), id: \.path) { row($0) }
                if !changes.kinds.isEmpty {
                    Text(kindsText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private var sinceText: String {
        String(localized: "Since the scan \(Format.relativeDate(changes.since))")
    }

    private var kindsText: String {
        let parts = changes.kinds.prefix(4).map { "\($0.kind.title) \(Self.signed($0.delta))" }
        return String(localized: "By kind: \(parts.joined(separator: " · "))")
    }

    static func signed(_ delta: Int64) -> String {
        delta >= 0 ? "+" + Format.bytes(delta) : "−" + Format.bytes(-delta)
    }

    private func row(_ change: PathChange) -> some View {
        Button {
            Self.reveal(change.path)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: change.delta >= 0 ? "arrow.up.right" : "arrow.down.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(change.delta >= 0 ? Color.orange : Color.green)
                Text(ScanChanges.label(for: change.path))
                    .font(.callout.weight(.medium))
                Text(Self.signed(change.delta))
                    .font(.callout.monospacedDigit())
                if !change.hints.isEmpty {
                    Text("(\(change.hints.joined(separator: ", "))…)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(String(localized: "Show \(Format.tildePath(change.path)) in Finder"))
    }

    /// Selects the path in Finder; if it no longer exists, its closest existing folder.
    static func reveal(_ path: String) {
        var current = path
        while !current.isEmpty, current != "/", !FileManager.default.fileExists(atPath: current) {
            current = (current as NSString).deletingLastPathComponent
        }
        guard !current.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: current)])
    }
}
