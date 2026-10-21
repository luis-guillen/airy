import AppKit
import SwiftUI
import DiskMapCore

/// Duplicates: identical files from the already scanned index. The search only starts with "Find Duplicates".
/// In each group one copy is kept (radio button) and is never checked; red or protected items have no checkbox.
/// What is checked goes through `CleanupFlow` (`.duplicates` sheet) → `AppModel.trashDuplicates` → `CleanupExecutor`.
struct DuplicatesView: View {
    @Environment(AppModel.self) private var model
    @Environment(CleanupFlow.self) private var flow

    var body: some View {
        let store = model.sections.duplicates
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SectionHeader(title: Section.duplicates.title, subtitle: subtitle(store))
                filters(store)
                if let result = flow.duplicatesResult { UninstallerResultBanner(summary: result.summary) }
                content(store)
            }
            .padding(.horizontal, Theme.contentPadding)
            .padding(.top, 34)
            .padding(.bottom, 96)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .overlay(alignment: .bottom) {
            if let result = store.result, !result.groups.isEmpty, !store.isSearching {
                bar(store)
                    .padding(.horizontal, Theme.contentPadding)
                    .padding(.bottom, 18)
                    .frame(maxWidth: 980)
            }
        }
    }

    private func subtitle(_ store: DuplicatesStore) -> String {
        guard model.scan != nil else { return String(localized: "No scan yet") }
        guard let result = store.result else { return String(localized: "Finds identical files in your folders.") }
        let groups = visibleGroups(store)
        let wasted = groups.reduce(Int64(0)) { $0 + $1.wastedBytes }
        let groupsText = groups.count == 1 ? String(localized: "1 group") : String(localized: "\(Theme.count(groups.count)) groups")
        return String(localized: "\(groupsText) · \(Theme.count(result.filesExamined)) files compared · \(Format.bytes(wasted)) duplicated")
    }

    // MARK: Filters

    private func filters(_ store: DuplicatesStore) -> some View {
        @Bindable var store = store
        return HStack(spacing: 10) {
            chip(String(localized: "Your Folder"), selected: store.place == .home) { store.place = .home }
            chip(folderTitle(store), selected: store.place != .home) { chooseFolder(store) }
                .help(store.search.roots.count == 1 ? Format.tildePath(store.search.roots[0]) : "")
            Picker("Minimum Size", selection: $store.search.minBytes) {
                ForEach(DuplicateSearch.sizeSteps, id: \.self) { Text("≥ \(Format.bytes($0))").tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            Spacer(minLength: 8)
            PrimaryButton("Find Duplicates", systemImage: "magnifyingglass") { store.start(model: model) }
                .fixedSize()
                .disabled(store.isSearching || model.scan == nil || flow.isBusy)
        }
        .disabled(store.isSearching)
    }

    private func folderTitle(_ store: DuplicatesStore) -> String {
        if case .folder(let path) = store.place { return (path as NSString).lastPathComponent }
        return String(localized: "Choose Folder…")
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(selected ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(selected ? AnyShapeStyle(Theme.Airy.accent.opacity(0.18)) : AnyShapeStyle(.primary.opacity(0.06)),
                            in: Capsule())
                .overlay(Capsule().strokeBorder(selected ? Theme.Airy.accent.opacity(0.5) : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    private func chooseFolder(_ store: DuplicatesStore) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        panel.prompt = String(localized: "Choose")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.place = .folder(url.standardizedFileURL.path)
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ store: DuplicatesStore) -> some View {
        if model.scan == nil {
            EmptySectionCard(symbol: Section.duplicates.symbol, line: "Scan the disk to look for duplicates.")
        } else if store.isSearching {
            progress(store)
        } else if let result = store.result {
            if !result.complete {
                Label("Incomplete search: it was cancelled or not everything could be read.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(Theme.Airy.riskInk(.yourCall))
            }
            let groups = visibleGroups(store)
            if groups.isEmpty {
                EmptySectionCard(symbol: "checkmark.circle", line: "There are no duplicate files.")
            } else {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(groups) { group in groupCard(group, store: store) }
                }
            }
        } else {
            EmptySectionCard(symbol: Section.duplicates.symbol,
                             line: "Choose where to look and click “Find Duplicates”.")
        }
    }

    private func visibleGroups(_ store: DuplicatesStore) -> [DuplicateGroup] {
        store.board.groups.filter { store.visibleCopies($0).count >= 2 }
    }

    private func progress(_ store: DuplicatesStore) -> some View {
        VStack(spacing: 22) {
            ScanRing(fraction: 0.25, lineWidth: 10) {
                Image(systemName: "doc.on.doc").font(.system(size: 28, weight: .semibold)).foregroundStyle(.secondary)
            }
            .frame(width: 120, height: 120)
            .background {
                WindLeaves(mode: .orbit(radius: 72), count: 6)
                    .frame(width: 180, height: 180)
            }
            Text("Comparing \(Theme.count(store.examined)) files…")
                .font(.headline)
                .monospacedDigit()
            Button("Cancel") { store.cancel() }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    private func groupCard(_ group: DuplicateGroup, store: DuplicatesStore) -> some View {
        let copies = store.visibleCopies(group)
        let keeper = store.board.keepers[group.id] ?? group.keeper
        let name = (keeper as NSString).lastPathComponent
        return GlassCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(.headline).lineLimit(1).truncationMode(.middle)
                        Text("\(copies.count) copies of \(Format.bytes(group.size))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("Frees \(Format.bytes(group.wastedBytes))")
                        .font(.callout.weight(.semibold)).monospacedDigit()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                ForEach(copies) { copy in
                    Divider().opacity(0.5)
                    copyRow(copy, group: group, keeper: keeper, store: store)
                }
            }
        }
    }

    private func copyRow(_ copy: DuplicateCopy, group: DuplicateGroup, keeper: String,
                         store: DuplicatesStore) -> some View {
        let isKeeper = copy.path == keeper
        return HStack(alignment: .center, spacing: 10) {
            Button { withAnimation(Theme.pressSpring) { store.board.keep(copy.path, in: group) } } label: {
                Image(systemName: isKeeper ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isKeeper ? Theme.Airy.accent : .secondary)
            }
            .buttonStyle(.plain)
            .help("Keep")
            .accessibilityLabel("Keep")
            if copy.canSelect {
                Toggle("", isOn: Binding(get: { store.board.selected.contains(copy.path) },
                                         set: { _ in store.board.toggle(copy.path, in: group) }))
                    .toggleStyle(.airyCheckbox)
                    .labelsHidden()
                    .disabled(isKeeper)
                    .frame(width: 18)
            } else {
                Image(systemName: "lock.fill").foregroundStyle(.secondary).frame(width: 18)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(Format.tildePath(copy.path))
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    if isKeeper { Text("Keep").font(.caption.weight(.semibold)).foregroundStyle(Theme.Airy.accent) }
                    if let date = copy.modified {
                        Text(date.formatted(.dateTime.day().month(.abbreviated).year().locale(Theme.locale)))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let protection = copy.protection {
                        Text(protection.reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    } else if copy.reclaimableBytes == 0 {
                        Text("APFS copy: takes no extra space").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 8)
            RiskBadge(risk: copy.risk, compact: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: Bar

    private func bar(_ store: DuplicatesStore) -> some View {
        let removals = store.board.removals()
        return HStack(spacing: 14) {
            Button("Select All Copies") { withAnimation(Theme.pressSpring) { store.selectAllCopies() } }
            Button("Clear Selection") { withAnimation(Theme.pressSpring) { store.board.clear() } }
                .disabled(store.board.selected.isEmpty)
            Spacer(minLength: 8)
            PrimaryButton("Move Copies to Trash · \(Format.bytes(store.board.reclaimableBytes))",
                          systemImage: "trash") {
                flow.requestRemoveDuplicates(removals) { _ in store.pruneMissing() }
            }
            .fixedSize()
            .disabled(removals.isEmpty || flow.isBusy)
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
}
