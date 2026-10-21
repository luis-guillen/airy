import SwiftUI
import DiskMapCore

/// Large & Old: large, unopened files from the already scanned tree, grouped by risk.
/// Recomputed when it appears and when the filters, the scan, the tree or the protected list change.
struct LargeOldView: View {
    @Environment(AppModel.self) private var model

    /// What forces a recomputation.
    private struct RefreshKey: Equatable {
        let query: LargeOldQuery
        let root: ObjectIdentifier?
        let revision: Int
        let protected: [String]
    }

    var body: some View {
        let store = model.sections.largeOld
        @Bindable var bindable = store
        let selectedCount = store.selection.selected(in: store.files).count
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SectionHeader(title: Section.largeOld.title, subtitle: subtitle(store))
                LargeOldFilters(query: $bindable.query)
                content(store, selection: $bindable.selection)
            }
            .padding(.horizontal, Theme.contentPadding)
            .padding(.top, 34)
            .padding(.bottom, selectedCount == 0 ? 28 : 96)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .overlay {
            if let gust = store.gust { GustSweep(start: gust.start).id(gust.id) }
        }
        .overlay(alignment: .bottom) {
            if !store.files.isEmpty {
                SelectionBar(files: store.files, selection: $bindable.selection, gust: $bindable.gust)
                    .padding(.horizontal, Theme.contentPadding)
                    .padding(.bottom, 18)
                    .frame(maxWidth: 980)
            }
        }
        .task(id: RefreshKey(query: store.query, root: model.scan.map { ObjectIdentifier($0.root) },
                             revision: model.treeRevision, protected: model.settings.protectedPaths)) {
            store.refresh(model: model)
        }
        .onDisappear { store.cancel() }
    }

    private func subtitle(_ store: LargeOldStore) -> String {
        guard model.scan != nil else { return String(localized: "No scan yet") }
        if store.isLoading && store.files.isEmpty { return String(localized: "Searching…") }
        let total = store.files.reduce(Int64(0)) { $0 + $1.bytes }
        let count = store.files.count == 1 ? String(localized: "1 file") : String(localized: "\(Theme.count(store.files.count)) files")
        return "\(count) · \(Format.bytes(total))"
    }

    @ViewBuilder
    private func content(_ store: LargeOldStore, selection: Binding<FileSelection>) -> some View {
        if model.scan == nil {
            EmptySectionCard(symbol: Section.largeOld.symbol, line: "Scan the disk to see large files.")
        } else if store.files.isEmpty {
            if store.isLoading {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, alignment: .center).padding(.top, 30)
            } else {
                EmptySectionCard(symbol: "line.3.horizontal.decrease.circle", line: "Nothing matches these filters.")
            }
        } else {
            RiskGroupedList(files: store.files, selection: selection, gust: store.gust, notesMissingOpenDate: true)
        }
    }
}

// MARK: - Filters

private struct LargeOldFilters: View {
    @Binding var query: LargeOldQuery

    var body: some View {
        HStack(spacing: 12) {
            Picker("Size", selection: $query.minBytes) {
                ForEach(LargeOldQuery.sizeSteps, id: \.self) { Text("≥ \(Format.bytes($0))").tag($0) }
            }
            .fixedSize()

            Picker("Date", selection: $query.minMonthsIdle) {
                ForEach(LargeOldQuery.idleSteps, id: \.self) { Text(Self.idleTitle($0)).tag($0) }
            }
            .fixedSize()

            Menu {
                Button(query.kinds.isEmpty ? "✓ All Kinds" : "All Kinds") { query.kinds = [] }
                Divider()
                ForEach(ContentKind.allCases, id: \.self) { kind in
                    Toggle(kind.title, isOn: Binding(
                        get: { query.kinds.contains(kind) },
                        set: { on in if on { query.kinds.insert(kind) } else { query.kinds.remove(kind) } }))
                }
            } label: {
                Text(kindsTitle)
            }
            .fixedSize()

            Picker("Where", selection: $query.scope) {
                Text("Your Folder").tag(LargeOldQuery.Scope.home)
                Text("Whole Disk").tag(LargeOldQuery.Scope.everything)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Spacer(minLength: 0)

            Picker("Sort", selection: $query.sort) {
                Text("Size").tag(LargeOldQuery.Sort.size)
                Text("Oldest").tag(LargeOldQuery.Sort.oldest)
                Text("Name").tag(LargeOldQuery.Sort.name)
            }
            .fixedSize()
        }
        .labelsHidden()
        .controlSize(.regular)
    }

    private var kindsTitle: String {
        switch query.kinds.count {
        case 0: String(localized: "All Kinds")
        case 1: query.kinds.first!.title
        default: String(localized: "\(query.kinds.count) kinds")
        }
    }

    static func idleTitle(_ months: Int?) -> String {
        switch months {
        case nil: String(localized: "Any Date")
        case 12?: String(localized: "Unopened for 1 year")
        case let m?: String(localized: "Unopened for \(m) months")
        }
    }
}

// MARK: - Empty state

/// Glass card for "no scan" or "no results".
struct EmptySectionCard: View {
    let symbol: String
    let line: LocalizedStringKey

    var body: some View {
        GlassCard {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.Airy.accent)
                    .frame(width: 34)
                Text(line)
                    .font(.body)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: 680, alignment: .leading)
    }
}
