import AppKit
import SwiftUI
import DiskMapCore

// MARK: - Row

/// Row for a file that can be reviewed: checkbox (if it can be checked), kind icon, name, folder,
/// size, date and risk. Red or protected: no checkbox.
struct SelectableFileRow: View {
    @Environment(AppModel.self) private var model
    let file: ActionableFile
    let isSelected: Bool
    /// Large & Old: notes when the date is the modification date because Spotlight doesn't know the open date.
    var notesMissingOpenDate = false
    var onToggle: () -> Void

    @ViewState private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if file.canSelect {
                    Toggle("", isOn: Binding(get: { isSelected }, set: { _ in onToggle() }))
                        .toggleStyle(.airyCheckbox)
                        .labelsHidden()
                        .accessibilityLabel("Select \(file.name)")
                } else {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.Airy.riskInk(.doNotTouch))
                        .accessibilityHidden(true)
                }
            }
            .frame(width: 18)

            Image(systemName: Theme.symbol(for: file.kind))
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.ink(for: file.kind))
                .frame(width: 30, height: 30)
                .background(Theme.color(for: file.kind).opacity(0.16),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(Format.tildePath((file.path as NSString).deletingLastPathComponent))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(Format.bytes(file.bytes))
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                Text(dateLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if notesMissingOpenDate, file.lastOpened == nil {
                    Text("no open date; by modification")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            RiskBadge(risk: file.risk, compact: true, reason: file.reasons.first)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Theme.Airy.accent.opacity(isSelected ? 0.10 : (hovering ? 0.05 : 0)))
        .contentShape(Rectangle())
        .onTapGesture { if file.canSelect { onToggle() } }
        .onHover { hovering = $0 }
        .help(file.reasons.isEmpty ? file.risk.label : file.reasons.joined(separator: "\n"))
        .contextMenu {
            Button("Show in Finder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
            }
            Button("Show on Map", systemImage: "square.grid.3x3.square") {
                model.section = .map
                model.navigation.reveal(path: file.path)
            }
            if file.protection == nil {
                Divider()
                Button("Protect This", systemImage: "lock") { model.protect(path: file.path) }
            }
        }
    }

    /// "Opened 8 months ago" if Spotlight knows the open date; otherwise, "Modified 8 months ago".
    private var dateLine: String {
        if let opened = file.lastOpened { return String(localized: "Opened \(Theme.relative(opened))") }
        if let modified = file.lastModified { return String(localized: "Modified \(Theme.relative(modified))") }
        return String(localized: "No date")
    }
}

// MARK: - List by risk

/// Green, amber and red, each group with its header and total. Rows that leave go with the wind;
/// if several leave at once, the gust sways them.
struct RiskGroupedList: View {
    let files: [ActionableFile]
    @Binding var selection: FileSelection
    var gust: SectionGust?
    var notesMissingOpenDate = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(FileSelection.groups(files), id: \.risk) { group in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        RiskBadge(risk: group.risk)
                        Text(group.files.count == 1 ? "1 file" : "\(Theme.count(group.files.count)) files")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Text(Format.bytes(group.files.reduce(0) { $0 + $1.bytes }))
                            .font(.callout.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 4)

                    GlassCard(padding: 0) {
                        VStack(spacing: 0) {
                            ForEach(Array(group.files.enumerated()), id: \.element.id) { index, file in
                                VStack(spacing: 0) {
                                    if index > 0 { Divider().opacity(0.5).padding(.leading, 76) }
                                    SelectableFileRow(file: file, isSelected: selection.ids.contains(file.id),
                                                      notesMissingOpenDate: notesMissingOpenDate) {
                                        withAnimation(Theme.pressSpring) { selection.toggle(file) }
                                    }
                                }
                                .gustSway(index: gust?.order.firstIndex(of: file.id), start: gust?.start)
                                .transition(.leafAway)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                    }
                }
            }
        }
        .animation(Theme.zoomSpring, value: files.map(\.id))
    }
}

// MARK: - Selection bar

/// Selection shortcuts and "Move to Trash · size". `CleanupFlow` opens the confirmation.
struct SelectionBar: View {
    @Environment(CleanupFlow.self) private var flow
    let files: [ActionableFile]
    @Binding var selection: FileSelection
    /// Set when a batch of several rows is confirmed (gust); it removes itself.
    @Binding var gust: SectionGust?

    var body: some View {
        let selected = selection.selected(in: files)
        let bytes = selection.bytes(in: files)
        HStack(spacing: 14) {
            Button("Select All Green") { withAnimation(Theme.pressSpring) { selection.selectAllGreen(files) } }
                .disabled(!files.contains { $0.canSelect && $0.risk == .safe })
            Button("Select All") { withAnimation(Theme.pressSpring) { selection.selectAll(files) } }
                .disabled(!files.contains(where: \.canSelect))
            Button("Clear Selection") { withAnimation(Theme.pressSpring) { selection.clear() } }
                .disabled(selected.isEmpty)
            Spacer(minLength: 8)
            PrimaryButton("Move to Trash · \(Format.bytes(bytes))", systemImage: "trash") {
                requestTrash(selected)
            }
            .fixedSize()
            .disabled(selected.isEmpty || flow.isBusy)
        }
        .buttonStyle(.plain)
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.leading, 20)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.75))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
    }

    private func requestTrash(_ selected: [ActionableFile]) {
        guard !selected.isEmpty else { return }
        let paths = selected.map(\.path)
        let title = selected.count == 1 ? selected[0].name : String(localized: "\(selected.count) files")
        let ids = selected.map(\.id)
        flow.requestTrash(paths: paths, title: title, onConfirm: {
            guard let order = BatchMotion.gustOrder(ids: ids) else { return }
            let next = SectionGust(start: .now, order: order)
            gust = next
            let lifetime = WindMotion.gustLifetime(rowCount: order.count)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(lifetime))
                if gust == next { gust = nil }
            }
        }, onOutcome: { _ in
            // What is no longer in place leaves the selection (what is blocked stays checked).
            selection.prune(to: files.filter { FileManager.default.fileExists(atPath: $0.path) })
        })
    }
}
