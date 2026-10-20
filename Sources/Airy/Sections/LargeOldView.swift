import SwiftUI
import DiskMapCore

/// Grandes y viejos: ficheros grandes y sin abrir del árbol ya analizado, agrupados por riesgo.
/// Se recalcula al aparecer y cuando cambian los filtros, el análisis, el árbol o la lista protegida.
struct LargeOldView: View {
    @Environment(AppModel.self) private var model

    /// Lo que obliga a recalcular.
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
        guard model.scan != nil else { return "Sin análisis todavía" }
        if store.isLoading && store.files.isEmpty { return "Buscando…" }
        let total = store.files.reduce(Int64(0)) { $0 + $1.bytes }
        let count = store.files.count == 1 ? "1 archivo" : "\(Theme.count(store.files.count)) archivos"
        return "\(count) · \(Format.bytes(total))"
    }

    @ViewBuilder
    private func content(_ store: LargeOldStore, selection: Binding<FileSelection>) -> some View {
        if model.scan == nil {
            EmptySectionCard(symbol: Section.largeOld.symbol, line: "Analiza el disco para ver los archivos grandes.")
        } else if store.files.isEmpty {
            if store.isLoading {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, alignment: .center).padding(.top, 30)
            } else {
                EmptySectionCard(symbol: "line.3.horizontal.decrease.circle", line: "Nada con estos filtros.")
            }
        } else {
            RiskGroupedList(files: store.files, selection: selection, gust: store.gust, notesMissingOpenDate: true)
        }
    }
}

// MARK: - Filtros

private struct LargeOldFilters: View {
    @Binding var query: LargeOldQuery

    var body: some View {
        HStack(spacing: 12) {
            Picker("Tamaño", selection: $query.minBytes) {
                ForEach(LargeOldQuery.sizeSteps, id: \.self) { Text("≥ \(Format.bytes($0))").tag($0) }
            }
            .fixedSize()

            Picker("Fecha", selection: $query.minMonthsIdle) {
                ForEach(LargeOldQuery.idleSteps, id: \.self) { Text(Self.idleTitle($0)).tag($0) }
            }
            .fixedSize()

            Menu {
                Button(query.kinds.isEmpty ? "✓ Todos los tipos" : "Todos los tipos") { query.kinds = [] }
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

            Picker("Dónde", selection: $query.scope) {
                Text("Tu carpeta").tag(LargeOldQuery.Scope.home)
                Text("Todo el disco").tag(LargeOldQuery.Scope.everything)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Spacer(minLength: 0)

            Picker("Orden", selection: $query.sort) {
                Text("Tamaño").tag(LargeOldQuery.Sort.size)
                Text("Más antiguos").tag(LargeOldQuery.Sort.oldest)
                Text("Nombre").tag(LargeOldQuery.Sort.name)
            }
            .fixedSize()
        }
        .labelsHidden()
        .controlSize(.regular)
    }

    private var kindsTitle: String {
        switch query.kinds.count {
        case 0: "Todos los tipos"
        case 1: query.kinds.first!.title
        default: "\(query.kinds.count) tipos"
        }
    }

    static func idleTitle(_ months: Int?) -> String {
        switch months {
        case nil: "Cualquier fecha"
        case 12?: "Sin abrir 1 año"
        case let m?: "Sin abrir \(m) meses"
        }
    }
}

// MARK: - Estado vacío

/// Tarjeta de cristal para «sin análisis» o «sin resultados».
struct EmptySectionCard: View {
    let symbol: String
    let line: String

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
