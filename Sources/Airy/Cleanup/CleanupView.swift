import SwiftUI
import DiskMapCore

/// Sección Limpieza: cuánto se puede liberar sin riesgo y cada elemento detectado, agrupado por
/// riesgo, con su explicación. Todo borrado pasa por `CleanupFlow` (confirmación y tanda).
struct CleanupView: View {
    @Environment(AppModel.self) private var model
    @Environment(CleanupFlow.self) private var flow

    @ViewState private var selection: Set<String> = []
    @ViewState private var appeared = false
    private static let topID = "cleanup-top"

    private var board: CleanupBoard {
        #if DEBUG
        if !flow.debugBlocked.isEmpty {
            let items = model.cleanupItems.map { item -> CleanupItem in
                var copy = item
                if let fake = flow.debugBlocked[item.id] { copy.blockedByOpenApps = fake }
                return copy
            }
            return CleanupBoard(items: items, hidden: flow.hiddenIDs)
        }
        #endif
        return CleanupBoard(items: model.cleanupItems, hidden: flow.hiddenIDs)
    }

    var body: some View {
        let board = board
        let selected = board.selected(selection)
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                SectionHeader(title: "Limpieza", subtitle: subtitle(board)) {
                    PrimaryButton(model.isRefreshingCleanup ? "Buscando…" : "Buscar de nuevo",
                                  systemImage: "arrow.clockwise", style: .secondary,
                                  isBusy: model.isRefreshingCleanup) {
                        model.refreshCleanup()
                    }
                    .fixedSize()
                    .disabled(flow.isBusy || model.catalog == nil)
                }
                .id(Self.topID)

                if model.catalog == nil {
                    unavailable
                } else {
                    HeroCard(board: board, isDetecting: model.isRefreshingCleanup && model.cleanupItems.isEmpty)

                    if let result = flow.lastResult {
                        ResultBanner(result: result) {
                            withAnimation(Theme.sectionSpring) { flow.lastResult = nil }
                        }
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    if board.groups.isEmpty {
                        emptyState
                    }

                    ForEach(Array(board.groups.enumerated()), id: \.element.id) { index, group in
                        GroupSection(group: group, selection: $selection)
                            // La última fila de un grupo se va con el grupo entero: también en hojas.
                            .transition(.leafAway)
                            .opacity(appeared ? 1 : 0)
                            .offset(y: appeared ? 0 : 10)
                            .animation(Theme.stagger(index: index * 4), value: appeared)
                    }
                }
            }
            .padding(.horizontal, Theme.contentPadding)
            .padding(.top, 34)
            // La barra de selección o la píldora de la tanda no tapan la última fila.
            .padding(.bottom, selected.isEmpty && !showsBatchPill ? 28 : 96)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(Theme.sectionSpring, value: flow.lastResult?.id)
        }
        .scrollContentBackground(.hidden)
        // El resultado de una tanda aparece arriba: se sube para verlo.
        .onChange(of: flow.lastResult?.id) { _, id in
            if id != nil { withAnimation(Theme.zoomSpring) { proxy.scrollTo(Self.topID, anchor: .top) } }
        }
        #if DEBUG
        .onChange(of: flow.debugScrollTarget) { _, target in
            if let target { withAnimation(Theme.zoomSpring) { proxy.scrollTo(target, anchor: .center) } }
        }
        #endif
        }
        .overlay {
            // Ráfaga de la tanda: cruza la lista y desaparece; no recibe clics.
            if let gust = flow.gust {
                GustSweep(start: gust.start)
                    .id(gust.id)
            }
        }
        .overlay(alignment: .bottom) {
            // Las animaciones van aquí dentro: solo mueven la barra o la píldora, no toda la lista.
            Group {
                if !selected.isEmpty {
                    SelectionBar(items: selected) { selection = [] }
                        .padding(.bottom, 18)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if showsBatchPill {
                    BatchFreedPill(tally: flow.batchTally)
                        .padding(.bottom, 18)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(Theme.sectionSpring, value: selected.isEmpty)
            .animation(Theme.sectionSpring, value: showsBatchPill)
        }
        .environment(\.airyQuietShadows, flow.isRunning)
        .onAppear { withAnimation(Theme.zoomSpring) { appeared = true } }
        .onChange(of: model.cleanupItems.map(\.id)) { _, _ in
            selection = CleanupBoard(items: model.cleanupItems).pruned(selection)
        }
        .onChange(of: model.isRefreshingCleanup) { _, refreshing in
            if !refreshing { flow.detectionFinished() }
        }
        .onChange(of: flow.isRunning) { _, running in
            if running { selection = [] }
        }
        #if DEBUG
        .task { CleanupDebugScript.run(model: model, flow: flow,
                                       select: { selection.formSymmetricDifference([$0]) }) }
        #endif
    }

    /// La píldora sube con cada fila borrada mientras dura la tanda.
    private var showsBatchPill: Bool { flow.isRunning && flow.batchFreed > 0 }

    private func subtitle(_ board: CleanupBoard) -> String {
        if model.catalogError != nil { return "No disponible: no se pudo cargar el catálogo" }
        if model.isRefreshingCleanup && model.cleanupItems.isEmpty { return "Buscando cachés y restos…" }
        let count = board.items.count
        return count == 1 ? "1 elemento detectado" : "\(Theme.count(count)) elementos detectados"
    }

    private var unavailable: some View {
        GlassCard {
            Label(model.catalogError ?? "No se pudo cargar el catálogo de limpiezas.",
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.Airy.riskInk(.yourCall))
        }
    }

    @ViewBuilder private var emptyState: some View {
        if model.isRefreshingCleanup {
            GlassCard {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text("Buscando cachés, registros y restos…")
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            GlassCard {
                HStack(spacing: 16) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(Theme.Airy.riskInk(.safe))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Nada que limpiar").font(.title3.weight(.semibold))
                        Text("No se ha encontrado ninguna caché ni resto conocido que ocupe espacio.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - Cabecera "Puedes liberar"

private struct HeroCard: View {
    @Environment(CleanupFlow.self) private var flow
    @Environment(\.airyQuietShadows) private var quietShadows
    let board: CleanupBoard
    /// Primera detección en curso: aún no se sabe cuánto hay (nunca un "0 kB" que parezca real).
    var isDetecting = false

    var body: some View {
        let ready = board.readySafeItems
        GlassCard(padding: 22) {
            HStack(alignment: .center, spacing: 20) {
                ZStack {
                    Circle().fill(LinearGradient(colors: [Theme.Airy.riskFill(.safe), Theme.Airy.sky],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: "sparkles")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(Theme.Airy.night)
                }
                .frame(width: 56, height: 56)
                .shadow(color: Theme.Airy.riskFill(.safe).opacity(quietShadows ? 0 : 0.35), radius: quietShadows ? 0 : 12,
                        y: quietShadows ? 0 : 5)

                VStack(alignment: .leading, spacing: 2) {
                    // Con limpiezas parciales en la suma (p. ej. `pnpm store prune`) es solo un máximo.
                    Text(board.safeBytesIsUpperBound && !isDetecting ? "Puedes liberar hasta" : "Puedes liberar")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                    if isDetecting {
                        Text("Calculando…")
                            .font(.system(size: 38, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                    } else {
                        BytesCounter(bytes: board.safeBytes,
                                     font: .system(size: 38, weight: .bold, design: .rounded))
                    }
                    Text(isDetecting ? "Mirando cachés, registros y restos conocidos." : detail(ready: ready))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 16)

                PrimaryButton("Limpiar todo lo seguro", systemImage: "sparkles", isBusy: flow.isRunning) {
                    flow.requestClean(ready)
                }
                .fixedSize()
                .disabled(ready.isEmpty || flow.isBusy)
                .help(ready.isEmpty ? "No hay nada seguro listo para limpiar" : "Revisa la lista antes de confirmar")
            }
        }
    }

    private func detail(ready: [CleanupItem]) -> String {
        let safeCount = board.groups.first { $0.risk == .safe }?.items.count ?? 0
        guard safeCount > 0 else { return "Nada marcado como «Borrar sin riesgo» ahora mismo." }
        let waiting = board.items.filter { $0.risk == .safe && CleanupBoard.showsCheckbox($0) && !$0.blockedByOpenApps.isEmpty }
        let base = "sin riesgo, en \(Theme.count(safeCount)) \(safeCount == 1 ? "elemento" : "elementos")"
        guard !waiting.isEmpty else { return base }
        let bytes = waiting.reduce(Int64(0)) { $0 + $1.bytes }
        return base + " · \(Format.bytes(bytes)) esperan a que cierres una app"
    }
}

// MARK: - Grupo

private struct GroupSection: View {
    @Environment(CleanupFlow.self) private var flow
    let group: CleanupBoard.Group
    @Binding var selection: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: Theme.symbol(for: group.risk))
                    .foregroundStyle(Theme.Airy.riskInk(group.risk))
                Text(group.title)
                    .font(.system(.title3, design: .rounded, weight: .bold))
                Text(Self.blurb(group.risk))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(CleanupBoard.amountText(group.bytes, upperBound: group.items.contains(where: CleanupBoard.isPartial)))
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText(value: Double(group.bytes)))
            }
            .padding(.horizontal, 4)

            GlassCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                        VStack(spacing: 0) {
                            if index > 0 { Divider().opacity(0.5).padding(.leading, 90) }
                            CleanupRow(item: item, isSelected: selection.contains(item.id)) {
                                withAnimation(Theme.pressSpring) { selection.formSymmetricDifference([item.id]) }
                            }
                        }
                        .gustSway(index: flow.gust?.order.firstIndex(of: item.id), start: flow.gust?.start)
                        .id(item.id)
                        // Al borrarse, la fila se la lleva el viento (con el mismo muelle que la colapsa).
                        .transition(.leafAway)
                    }
                }
                // El muelle de las filas que llegan o se van con una nueva detección, solo en este grupo
                // (los borrados de una tanda ya llegan dentro de `withAnimation`).
                .animation(Theme.zoomSpring, value: group.items.map(\.id))
                .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            }
        }
    }

    static func blurb(_ risk: Risk) -> String {
        switch risk {
        case .safe: "Se regenera solo; puedes borrarlo sin pensarlo."
        case .yourCall: "Se puede borrar, pero pierdes algo: lee qué es."
        case .doNotTouch: "Airy solo te lo enseña."
        }
    }
}

// MARK: - Barra de selección

private struct SelectionBar: View {
    @Environment(CleanupFlow.self) private var flow
    let items: [CleanupItem]
    var onClear: () -> Void

    var body: some View {
        let (bytes, upperBound) = CleanupBoard.total(items)
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                Text(items.count == 1 ? "1 seleccionado" : "\(Theme.count(items.count)) seleccionados")
                    .font(.callout.weight(.semibold))
                Text(CleanupBoard.amountText(bytes, upperBound: upperBound))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Button("Quitar selección", action: onClear)
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(.secondary)
            PrimaryButton("Limpiar seleccionados", systemImage: "sparkles") {
                flow.requestClean(items)
            }
            .fixedSize()
            .disabled(flow.isBusy)
        }
        .padding(.leading, 20)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.75))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
    }
}

// MARK: - Resultado

private struct ResultBanner: View {
    @Environment(AppModel.self) private var model
    @Environment(CleanupFlow.self) private var flow
    let result: CleanupFlow.LastResult
    var onDismiss: () -> Void

    var body: some View {
        let summary = result.summary
        GlassCard(padding: 16, material: .thinMaterial) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: symbol(summary))
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(tint(summary))
                    Text(summary.headline ?? "No se pudo limpiar")
                        .font(.callout.weight(.semibold))
                    Spacer(minLength: 8)
                    if summary.movedToTrash > 0, (model.trashBytes ?? 1) > 0 {
                        PrimaryButton("Vaciar Papelera…", systemImage: "trash.slash", style: .secondary) {
                            flow.requestEmptyTrash(model)
                        }
                        .fixedSize()
                        .disabled(flow.isBusy)
                    }
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                            .background(.primary.opacity(0.06), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Ocultar")
                }
                ForEach(summary.problems) { problem in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.Airy.riskInk(.yourCall))
                        Text("\(problem.title): \(problem.message)")
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
        }
    }

    private func symbol(_ summary: CleanupRunSummary) -> String {
        if summary.succeededIDs.isEmpty { return "exclamationmark.triangle.fill" }
        return summary.freed > 0 ? "leaf.fill" : "trash.fill"
    }

    private func tint(_ summary: CleanupRunSummary) -> Color {
        summary.succeededIDs.isEmpty ? Theme.Airy.riskInk(.yourCall) : Theme.Airy.riskInk(.safe)
    }
}

// MARK: - Depuración

#if DEBUG
/// Solo Debug, para capturas: `AIRY_CLEANUP_SCRIPT="accion[:arg]@segundos,…"`.
/// - `select:<id>`: marca o desmarca una fila.
/// - `cleansafe` / `clean:<id>`: abren la confirmación (no ejecutan nada).
/// - `scrollto:<id>`: desplaza la lista hasta esa fila.
/// - `cleantest`: abre la confirmación de `user-logs` reducida a `~/Library/Logs/AiryPrueba`.
/// Ningún paso confirma nada: las hojas se abren para verlas y se cierran con `cancel`.
/// - `emptytrash`: abre la confirmación de vaciar la Papelera (nunca la confirma).
/// - `snapshots:<n>:<bytes>`: muestra el aviso de instantáneas con datos de ejemplo.
/// - `celebrate:<bytes>`: muestra la celebración.
/// - `fakeblock:<id>:<bundleID>`: pinta una fila como bloqueada por una app abierta.
/// - `cancel`: cierra la hoja.
/// - `section:<sección>`: vuelve a una sección (p. ej. si otra instancia recibe clics ajenos).
@MainActor
enum CleanupDebugScript {
    private static var started = false
    private static let testRoot = NSHomeDirectory() + "/Library/Logs/AiryPrueba"

    private static func isTestPath(_ path: String) -> Bool {
        path == testRoot || path.hasPrefix(testRoot + "/")
    }

    static func run(model: AppModel, flow: CleanupFlow, select: @escaping (String) -> Void) {
        guard !started, let script = ProcessInfo.processInfo.environment["AIRY_CLEANUP_SCRIPT"] else { return }
        started = true
        for raw in script.split(separator: ",") {
            let parts = raw.split(separator: "@")
            guard parts.count == 2, let time = Double(parts[1]) else { continue }
            let action = parts[0].split(separator: ":", maxSplits: 1).map(String.init)
            DebugSnapshot.at(time) {
                perform(action[0], action.count > 1 ? action[1] : nil, model: model, flow: flow,
                        board: CleanupBoard(items: model.cleanupItems, hidden: flow.hiddenIDs), select: select)
            }
        }
    }

    private static func perform(_ action: String, _ argument: String?, model: AppModel, flow: CleanupFlow,
                                board: CleanupBoard, select: (String) -> Void) {
        FileHandle.standardError.write(Data("[cleanup-script] \(action) \(argument ?? "")\n".utf8))
        switch action {
        case "select": if let argument { select(argument) }
        case "cleansafe": flow.requestClean(board.readySafeItems)
        case "clean": flow.requestClean(board.items.filter { $0.id == argument })
        case "scrollto": flow.debugScrollTarget = argument
        case "cleantest":
            // Solo la carpeta de prueba: el elemento `user-logs` reducido a lo que hay en AiryPrueba.
            let narrowed = board.items.compactMap { item -> CleanupItem? in
                guard item.entry.id == "user-logs" else { return nil }
                var copy = item
                copy.paths = item.paths.filter(isTestPath)
                copy.bytes = copy.paths.reduce(0) { $0 + (AllocatedSize.of($1) ?? 0) }
                return copy.paths.isEmpty ? nil : copy
            }
            flow.requestClean(narrowed)
        case "emptytrash": flow.requestEmptyTrash(model)
        case "snapshots":
            let values = (argument ?? "").split(separator: ":").compactMap { Int64($0) }
            flow.sheet = .snapshots(CleanupFlow.SnapshotNotice(
                emptied: (values.count > 1 ? values[1] : 0) + 400_000_000, rose: 400_000_000,
                retained: values.count > 1 ? values[1] : 0, snapshotCount: Int(values.first ?? 3)))
        case "snapshotclean":
            if case .snapshots(let notice)? = flow.sheet { flow.requestSnapshotCleanup(notice, model: model) }
        case "celebrate": flow.celebration = CleanupFlow.Celebration(bytes: Int64(argument ?? "") ?? 1_000_000_000)
        case "fakeblock":
            let values = (argument ?? "").split(separator: ":", maxSplits: 1).map(String.init)
            if values.count == 2 { flow.debugBlocked[values[0]] = [values[1]] }
        case "cancel": flow.cancelSheet()
        case "section": if let argument, let section = Section(rawValue: argument) { model.section = section }
        default: break
        }
    }
}
#endif
