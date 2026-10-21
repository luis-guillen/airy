import AppKit
import SwiftUI
import DiskMapCore

/// "Heaviest Right Now": apps and loose processes by impact. Only what can be quit gets a checkbox and
/// "Quit"; what can't, its reason. On quitting, the row flies away like a leaf (`.leafAway`).
struct HeavyAppsList: View {
    @Environment(AppModel.self) private var model
    @Environment(CleanupFlow.self) private var flow

    var body: some View {
        let session = model.performance
        let rows = session.visibleRows
        let selected = session.board.selected(session.selection)
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Heaviest Right Now").font(.headline)
                    Spacer()
                    if !selected.isEmpty {
                        PrimaryButton("Quit Selected (\(selected.count))", systemImage: "power") {
                            flow.requestQuit(selected.map(\.group))
                        }
                        .fixedSize()
                        .disabled(flow.isBusy)
                    }
                }
                if rows.isEmpty {
                    Text(session.snapshot == nil ? "Measuring…" : "Nothing notable is open.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        HeavyAppRow(row: row)
                            .transition(.leafAway)
                        if row.id != rows.last?.id { Divider().opacity(0.4) }
                    }
                }
                .animation(Theme.zoomSpring, value: rows.map(\.id))
            }
        }
    }
}

private struct HeavyAppRow: View {
    @Environment(AppModel.self) private var model
    @Environment(CleanupFlow.self) private var flow
    let row: PerformanceRow

    var body: some View {
        let session = model.performance
        let group = row.group
        let closable = PerformanceBoard.canSelect(row)
        let unresponsive = session.unresponsive.contains(row.id)
        HStack(alignment: .top, spacing: 12) {
            if closable {
                Toggle("", isOn: Binding(
                    get: { session.selection.contains(row.id) },
                    set: { on in if on { session.selection.insert(row.id) } else { session.selection.remove(row.id) } }))
                    .labelsHidden()
                    .toggleStyle(.airyCheckbox)
                    .padding(.top, 8)
            }
            AppIcon(path: group.bundlePath)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(group.detail.map { "\(group.name) · \($0)" } ?? group.name)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    if case .allowed(let risk) = row.eligibility {
                        RiskBadge(risk: risk, compact: true,
                                  reason: group.kind == .looseProcess ? QuitPolicy.looseWarning : nil)
                    }
                }
                if let explanation = group.explanation {
                    Text(explanation).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Text(stats(group)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                if case .never(let reason) = row.eligibility {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
                if let message = session.rowMessages[row.id] {
                    Text(message).font(.caption.weight(.medium)).foregroundStyle(Theme.Airy.riskInk(.doNotTouch))
                }
            }
            Spacer(minLength: 8)
            if closable {
                if session.closing.contains(row.id) {
                    ProgressView().controlSize(.small).padding(.top, 6)
                } else if unresponsive {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("Not Responding").font(.caption.weight(.semibold)).foregroundStyle(Theme.Airy.riskInk(.yourCall))
                        PrimaryButton("Force Quit…", style: .destructive) { flow.requestForceQuit([group]) }
                            .fixedSize()
                            .disabled(flow.isBusy)
                    }
                } else {
                    PrimaryButton("Quit", style: .secondary) { flow.requestQuit([group]) }
                        .fixedSize()
                        .disabled(flow.isBusy)
                        .padding(.top, 4)
                }
            }
        }
        .padding(.vertical, 8)
    }

    private func stats(_ group: AppGroup) -> String {
        let cpu = group.cpuPercent.map { String(localized: "CPU \(Int($0.rounded()))%") } ?? "CPU —"
        let procs = group.pids.count == 1 ? String(localized: "1 process") : String(localized: "\(group.pids.count) processes")
        return "\(Format.bytes(group.memory)) · \(cpu) · \(procs)"
    }
}

/// The app's icon (from its `.app`) or a generic one; cached so it isn't read on every sample.
private struct AppIcon: View {
    let path: String?
    @MainActor private static var cache: [String: NSImage] = [:]

    var body: some View {
        if let path, let image = Self.icon(path) {
            Image(nsImage: image).resizable().interpolation(.high)
        } else {
            Image(systemName: "terminal")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }

    @MainActor private static func icon(_ path: String) -> NSImage? {
        if let cached = cache[path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache[path] = image
        return image
    }
}
