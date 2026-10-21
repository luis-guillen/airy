import SwiftUI
import DiskMapCore

/// File types: an animated ring with the legend beside it; choosing a kind shows its files below.
struct FileTypesView: View {
    @Environment(AppModel.self) private var model
    @ViewState private var hovered: ContentKind?

    private struct RefreshKey: Equatable {
        let root: ObjectIdentifier?
        let revision: Int
        let protected: [String]
    }

    var body: some View {
        let store = model.sections.fileTypes
        @Bindable var bindable = store
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SectionHeader(title: Section.types.title, subtitle: subtitle(store))
                if let breakdown = store.breakdown, !breakdown.slices.isEmpty {
                    GlassCard {
                        HStack(alignment: .center, spacing: 28) {
                            TypeDonut(slices: breakdown.slices, total: breakdown.total, chosen: store.chosen,
                                      hovered: $hovered) { kind in choose(kind, store) }
                                .frame(width: 240, height: 240)
                            legend(breakdown, store)
                        }
                    }
                    chosenList(store, selection: $bindable.selection)
                } else {
                    EmptySectionCard(symbol: Section.types.symbol, line: "Scan the disk to see which kinds take up the most space.")
                }
            }
            .padding(.horizontal, Theme.contentPadding)
            .padding(.top, 34)
            .padding(.bottom, store.files.isEmpty ? 28 : 96)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .overlay {
            if let gust = store.gust { GustSweep(start: gust.start).id(gust.id) }
        }
        .overlay(alignment: .bottom) {
            if store.chosen != nil, !store.files.isEmpty {
                SelectionBar(files: store.files, selection: $bindable.selection, gust: $bindable.gust)
                    .padding(.horizontal, Theme.contentPadding)
                    .padding(.bottom, 18)
                    .frame(maxWidth: 980)
            }
        }
        .task(id: RefreshKey(root: model.scan.map { ObjectIdentifier($0.root) }, revision: model.treeRevision,
                             protected: model.settings.protectedPaths)) {
            store.refresh(model: model)
        }
        .onDisappear { store.cancel() }
    }

    private func subtitle(_ store: FileTypesStore) -> String {
        guard let breakdown = store.breakdown else { return String(localized: "No scan yet") }
        let count = breakdown.slices.count
        return count == 1 ? String(localized: "\(Format.bytes(breakdown.total)) in 1 kind")
                          : String(localized: "\(Format.bytes(breakdown.total)) in \(count) kinds")
    }

    private func choose(_ kind: ContentKind, _ store: FileTypesStore) {
        withAnimation(Theme.sectionSpring) { store.choose(store.chosen == kind ? nil : kind, model: model) }
    }

    private func legend(_ breakdown: FileTypeBreakdown, _ store: FileTypesStore) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(breakdown.slices) { slice in
                let lit = hovered == slice.kind || store.chosen == slice.kind
                Button { choose(slice.kind, store) } label: {
                    HStack(spacing: 10) {
                        Circle().fill(Theme.color(for: slice.kind)).frame(width: 10, height: 10)
                        Image(systemName: Theme.symbol(for: slice.kind))
                            .foregroundStyle(Theme.ink(for: slice.kind))
                            .frame(width: 18)
                        Text(slice.kind.title)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(Format.bytes(slice.bytes))
                            .monospacedDigit()
                            .fontWeight(.semibold)
                        Text(TypeDonut.percent(slice.fraction))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .trailing)
                    }
                    .font(.callout)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Theme.Airy.accent.opacity(store.chosen == slice.kind ? 0.14 : (lit ? 0.07 : 0)),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    if inside { hovered = slice.kind } else if hovered == slice.kind { hovered = nil }
                }
                .accessibilityAddTraits(store.chosen == slice.kind ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func chosenList(_ store: FileTypesStore, selection: Binding<FileSelection>) -> some View {
        if let kind = store.chosen {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: Theme.symbol(for: kind)).foregroundStyle(Theme.ink(for: kind))
                    Text(kind.title)
                        .font(.system(.title3, design: .rounded, weight: .bold))
                    if store.isLoading { ProgressView().controlSize(.small) }
                }
                if store.files.isEmpty, !store.isLoading {
                    EmptySectionCard(symbol: "line.3.horizontal.decrease.circle", line: "Nothing to list for this kind.")
                } else {
                    RiskGroupedList(files: store.files, selection: selection, gust: store.gust)
                }
                if store.hiddenBytes > 0 {
                    Text("and \(Format.bytes(store.hiddenBytes)) in small files")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
            }
            .transition(.opacity.combined(with: .offset(y: 8)))
        }
    }
}
