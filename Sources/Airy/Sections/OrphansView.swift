import SwiftUI
import DiskMapCore

/// "Orphaned Leftovers" tab: folders of apps that are no longer installed (green only).
struct OrphansView: View {
    @Environment(CleanupFlow.self) private var flow
    let store: UninstallerStore

    var body: some View {
        Group {
            switch store.orphans {
            case nil:
                ProgressView("Looking for leftovers of uninstalled apps…").frame(maxWidth: .infinity, minHeight: 160)
            case .undecided(let reason):
                Label(reason, systemImage: "questionmark.circle")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            case .found(let groups) where groups.isEmpty:
                Text("There are no leftovers of uninstalled apps.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            case .found(let groups):
                ScrollView {
                    GlassCard(padding: 0) {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                                if index > 0 { Divider().opacity(0.5).padding(.leading, 40) }
                                row(group)
                            }
                        }
                    }
                    .padding(.bottom, 70)
                }
            }
        }
        .overlay(alignment: .bottom) {
            let selected = store.selectedOrphans
            if !selected.isEmpty {
                UninstallerSelectionBar(
                    count: selected.count,
                    detail: Format.bytes(selected.reduce(0) { $0 + $1.bytes }),
                    actionTitle: String(localized: "Move to Trash · \(Format.bytes(selected.reduce(0) { $0 + $1.bytes }))"),
                    onClear: { store.orphanSelection = [] }
                ) {
                    flow.requestTrashOrphans(selected) { outcome in
                        // Only the groups no longer on disk disappear (the ones that stopped being orphans
                        // when checked again are still there).
                        if case .movedToTrash = outcome {
                            let gone = selected.filter { group in
                                group.paths.allSatisfy { !FileManager.default.fileExists(atPath: $0) }
                            }
                            store.removeOrphans(Set(gone.map(\.id)))
                        }
                    }
                }
                .padding(.bottom, 18)
            }
        }
    }

    private func row(_ group: OrphanGroup) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(get: { store.orphanSelection.contains(group.id) },
                                     set: { _ in store.orphanSelection.formSymmetricDifference([group.id]) }))
                .toggleStyle(.airyCheckbox)
                .labelsHidden()
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.bundleID).font(.callout.weight(.semibold))
                Text(group.paths.map { Format.tildePath($0) }.joined(separator: "\n"))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .textSelection(.enabled)
                Text("Unused since \(group.lastModified.formatted(.dateTime.day().month(.wide).year().locale(Theme.locale)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(Format.bytes(group.bytes)).font(.callout.weight(.semibold)).monospacedDigit()
            RiskBadge(risk: group.risk)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

/// "Broken Links" tab for /usr/local/bin.
struct BrokenLinksView: View {
    @Environment(CleanupFlow.self) private var flow
    let store: UninstallerStore

    var body: some View {
        Group {
            if !store.linksLoaded {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            } else if store.links.isEmpty {
                Text("There are no broken links in /usr/local/bin.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ScrollView {
                        GlassCard(padding: 0) {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(store.links.enumerated()), id: \.element.id) { index, link in
                                    if index > 0 { Divider().opacity(0.5).padding(.leading, 40) }
                                    HStack(spacing: 10) {
                                        Toggle("", isOn: Binding(
                                            get: { store.linkSelection.contains(link.id) },
                                            set: { _ in store.linkSelection.formSymmetricDifference([link.id]) }))
                                            .toggleStyle(.airyCheckbox)
                                            .labelsHidden()
                                        Text("\((link.path as NSString).lastPathComponent) → \(link.target)")
                                            .font(.callout.monospaced())
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                            .textSelection(.enabled)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                }
                            }
                        }
                    }
                    HStack {
                        Spacer()
                        PrimaryButton("Remove Broken Links", systemImage: "link.badge.plus") {
                            let links = store.selectedLinks.isEmpty ? store.links : store.selectedLinks
                            flow.requestRemoveBrokenLinks(links) { outcome in
                                if case .freed = outcome {
                                    let gone = Set(links.map(\.id))
                                    store.links.removeAll { gone.contains($0.id) }
                                    store.linkSelection = []
                                }
                            }
                        }
                        .fixedSize()
                        .disabled(flow.isBusy)
                    }
                }
            }
        }
    }
}

/// The Uninstaller's selection bar (how many, how much and the action, which opens the confirmation).
struct UninstallerSelectionBar: View {
    @Environment(CleanupFlow.self) private var flow
    let count: Int
    let detail: String
    let actionTitle: String
    var onClear: () -> Void
    var action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                Text(count == 1 ? "1 selected" : "\(Theme.count(count)) selected")
                    .font(.callout.weight(.semibold))
                Text(detail).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            Button("Clear Selection", action: onClear)
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(.secondary)
            PrimaryButton(actionTitle, systemImage: "trash", action: action)
                .fixedSize()
                .disabled(flow.isBusy)
        }
        .padding(.leading, 20)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.75))
    }
}
