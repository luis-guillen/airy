import AppKit
import SwiftUI
import DiskMapCore

/// Cleanup section: how much can be freed safely and every detected item, grouped by
/// risk, with its explanation. Every deletion goes through `CleanupFlow` (confirmation and batch).
struct CleanupView: View {
    @Environment(AppModel.self) private var model
    @Environment(CleanupFlow.self) private var flow

    @ViewState private var selection: Set<String> = []
    /// Preselected items the user has already seen: not checked again if they unchecked them (`nextSelection`).
    @ViewState private var seen: Set<String> = []
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
                SectionHeader(title: Section.cleanup.title, subtitle: subtitle(board)) {
                    PrimaryButton(model.isRefreshingCleanup ? "Searching…" : "Search Again",
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
                    HeroCard(board: board, selection: $selection,
                             isDetecting: model.isRefreshingCleanup && model.cleanupItems.isEmpty)

                    if let result = flow.lastResult {
                        ResultBanner(result: result) {
                            withAnimation(Theme.sectionSpring) { flow.lastResult = nil }
                        }
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    if board.groups.isEmpty && board.reviewItems.isEmpty {
                        emptyState
                    }

                    ForEach(Array(board.groups.enumerated()), id: \.element.id) { index, group in
                        GroupSection(group: group, selection: $selection)
                            // A group's last row leaves with the whole group: also in leaves.
                            .transition(.leafAway)
                            .opacity(appeared ? 1 : 0)
                            .offset(y: appeared ? 0 : 10)
                            .animation(Theme.stagger(index: index * 4), value: appeared)
                    }

                    if !board.reviewItems.isEmpty {
                        ReviewSection(items: board.reviewItems)
                            .opacity(appeared ? 1 : 0)
                            .offset(y: appeared ? 0 : 10)
                            .animation(Theme.stagger(index: board.groups.count * 4), value: appeared)
                    }
                }
            }
            .padding(.horizontal, Theme.contentPadding)
            .padding(.top, 34)
            // The selection bar or the batch pill don't cover the last row.
            .padding(.bottom, selected.isEmpty && !showsBatchPill ? 28 : 96)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(Theme.sectionSpring, value: flow.lastResult?.id)
        }
        .scrollContentBackground(.hidden)
        // A batch result appears at the top: scroll up to see it.
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
            // Batch gust: it crosses the list and disappears; it doesn't receive clicks.
            if let gust = flow.gust(for: .items) {
                GustSweep(start: gust.start)
                    .id(gust.id)
            }
        }
        .overlay(alignment: .bottom) {
            // The animations go in here: they only move the bar or the pill, not the whole list.
            Group {
                if !selected.isEmpty {
                    CleanupSelectionBar(items: selected) { selection = [] }
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
            if !refreshing {
                flow.detectionFinished()
                applyNextSelection()
            }
        }
        .onAppear {
            // Opening Cleanup while automatic detection waits for a scan brings it forward (user QoS).
            model.cleanupOpened()
            if !model.isRefreshingCleanup { applyNextSelection() }
        }
        .onChange(of: flow.isRunning) { _, running in
            if running { selection = [] }
        }
        #if DEBUG
        .task { CleanupDebugScript.run(model: model, flow: flow,
                                       select: { selection.formSymmetricDifference([$0]) },
                                       replaceSelection: { selection = $0 },
                                       currentSelection: { selection }) }
        #endif
    }

    /// When each detection ends: removes what no longer applies and checks preselected items not yet seen.
    private func applyNextSelection() {
        guard !flow.isBusy else { return }
        let next = CleanupBoard(items: model.cleanupItems).nextSelection(current: selection, seen: seen)
        selection = next.selection
        seen = next.seen
    }

    /// The pill goes up with each deleted row while the batch lasts.
    private var showsBatchPill: Bool { flow.isRunning && flow.batchFreed > 0 }

    private func subtitle(_ board: CleanupBoard) -> String {
        if model.catalogError != nil { return String(localized: "Unavailable: couldn’t load the catalog") }
        if model.isRefreshingCleanup && model.cleanupItems.isEmpty { return String(localized: "Searching for caches and leftovers…") }
        let count = board.displayItems.count
        return count == 1 ? String(localized: "1 item found") : String(localized: "\(Theme.count(count)) items found")
    }

    private var unavailable: some View {
        GlassCard {
            Label(model.catalogError ?? String(localized: "Couldn’t load the cleanup catalog."),
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.Airy.riskInk(.yourCall))
        }
    }

    @ViewBuilder private var emptyState: some View {
        if model.isRefreshingCleanup {
            GlassCard {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text("Searching for caches, logs and leftovers…")
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
                        Text("Nothing to Clean").font(.title3.weight(.semibold))
                        Text("No known cache or leftover taking up space was found.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - "You can free" header

private struct HeroCard: View {
    @Environment(CleanupFlow.self) private var flow
    @Environment(\.airyQuietShadows) private var quietShadows
    let board: CleanupBoard
    @Binding var selection: Set<String>
    /// First detection in progress: how much there is isn't known yet (never a "0 kB" that looks real).
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
                    // With partial cleanups in the sum (e.g. `pnpm store prune`) it is only a maximum.
                    Text(board.safeBytesIsUpperBound && !isDetecting ? "You can free up to" : "You can free")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                    if isDetecting {
                        Text("Calculating…")
                            .font(.system(size: 38, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                    } else {
                        BytesCounter(bytes: board.safeBytes,
                                     font: .system(size: 38, weight: .bold, design: .rounded))
                    }
                    Text(isDetecting ? String(localized: "Looking at caches, logs and known leftovers.") : detail(ready: ready))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 16)

                VStack(alignment: .trailing, spacing: 8) {
                    let green = board.greenSelection
                    let full = board.fullSelection
                    PrimaryButton("Select All Green", systemImage: "checkmark.circle", isBusy: flow.isRunning) {
                        selection = green
                    }
                    .fixedSize()
                    .disabled(green.isEmpty || flow.isBusy)
                    .help(green.isEmpty ? "Nothing green is ready to clean" : "Checks the green items; review before deleting")
                    PrimaryButton("Select All", systemImage: "checklist", style: .secondary) {
                        selection = full
                    }
                    .fixedSize()
                    .disabled(full.isEmpty || flow.isBusy)
                    .help("The green and amber items that can be deleted now; never the red ones")
                }
            }
        }
    }

    private func detail(ready: [CleanupItem]) -> String {
        let safeCount = board.groups.first { $0.risk == .safe }?.items.count ?? 0
        guard safeCount > 0 else { return String(localized: "Nothing marked “Safe to remove” right now.") }
        let waiting = board.items.filter { $0.risk == .safe && CleanupBoard.showsCheckbox($0) && !$0.blockedByOpenApps.isEmpty }
        let base = safeCount == 1 ? String(localized: "Safe to remove, in 1 item")
                                  : String(localized: "Safe to remove, in \(Theme.count(safeCount)) items")
        guard !waiting.isEmpty else { return base }
        let bytes = waiting.reduce(Int64(0)) { $0 + $1.bytes }
        return String(localized: "\(base) · \(Format.bytes(bytes)) waiting for you to quit an app")
    }
}

// MARK: - Group

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
                if group.risk != .doNotTouch {
                    let selectable = Set(group.items.filter(CleanupBoard.canSelect).map(\.id))
                    Button("Select This Group") { selection.formUnion(selectable) }
                        .buttonStyle(.plain)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Theme.Airy.accent)
                        .disabled(selectable.isEmpty || flow.isBusy)
                }
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
                        .gustSway(index: flow.gust(for: .items)?.order.firstIndex(of: item.id), start: flow.gust(for: .items)?.start)
                        .id(item.id)
                        // When deleted, the wind carries the row away (with the same spring that collapses it).
                        .transition(.leafAway)
                    }
                }
                // The spring for rows that arrive or leave with a new detection, only in this group
                // (a batch's deletions already arrive inside `withAnimation`).
                .animation(Theme.zoomSpring, value: group.items.map(\.id))
                .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            }
        }
    }

    static func blurb(_ risk: Risk) -> String {
        switch risk {
        case .safe: String(localized: "It recreates itself: delete it without worry.")
        case .yourCall: String(localized: "It can be deleted, but you lose something: read what.")
        case .doNotTouch: String(localized: "It isn’t deleted: Airy tells you why.")
        }
    }
}

// MARK: - Review only

/// The informational items: what it is and how to do it yourself. No checkbox or delete button; only "Show in Finder".
private struct ReviewSection: View {
    let items: [CleanupItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "eye")
                    .foregroundStyle(.secondary)
                Text("Review Only")
                    .font(.system(.title3, design: .rounded, weight: .bold))
                Text("Airy tells you what it is and how to do it yourself; there’s no delete button here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 4)

            GlassCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider().opacity(0.5).padding(.leading, 68) }
                        ReviewRow(item: item).id(item.id)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            }
        }
    }
}

private struct ReviewRow: View {
    let item: CleanupItem

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            CleanupIcon(entry: item.entry, dimmed: true)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(item.title)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    RiskBadge(risk: item.risk, reason: RiskExplanation.why(item))
                    Spacer(minLength: 8)
                    Text(CleanupBoard.sizeText(item))
                        .font(.system(.title3, design: .rounded, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Text(item.entry.reviewHint ?? RiskExplanation.why(item))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .frame(maxWidth: 640, alignment: .leading)
                if !item.paths.isEmpty {
                    Button("Show in Finder", systemImage: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting(item.paths.prefix(20).map { URL(fileURLWithPath: $0) })
                    }
                    .buttonStyle(.plain)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Theme.Airy.accent)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
    }
}

// MARK: - Selection bar

private struct CleanupSelectionBar: View {
    @Environment(CleanupFlow.self) private var flow
    let items: [CleanupItem]
    var onClear: () -> Void

    var body: some View {
        let (bytes, upperBound) = CleanupBoard.total(items)
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                let amount = CleanupBoard.amountText(bytes, upperBound: upperBound)
                Text(items.count == 1 ? String(localized: "1 selected · \(amount)")
                                      : String(localized: "\(Theme.count(items.count)) selected · \(amount)"))
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
            }
            Button("Clear Selection", action: onClear)
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(.secondary)
            PrimaryButton(CleanupBoard.deleteAllTitle(items), systemImage: "sparkles") {
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

// MARK: - Result

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
                    Text(summary.headline ?? String(localized: "Couldn’t clean"))
                        .font(.callout.weight(.semibold))
                    Spacer(minLength: 8)
                    if summary.movedToTrash > 0, (model.trashBytes ?? 1) > 0 {
                        PrimaryButton("Empty Trash…", systemImage: "trash.slash", style: .secondary) {
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
                    .help("Hide")
                }
                if !summary.successes.isEmpty {
                    Text("Done").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(summary.successes) { success in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Theme.Airy.riskInk(.safe))
                            Text("\(success.title) · \(success.text)")
                                .foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                }
                if !summary.problems.isEmpty {
                    Text("Couldn’t Complete").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
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
    }

    private func symbol(_ summary: CleanupRunSummary) -> String {
        if summary.succeededIDs.isEmpty { return "exclamationmark.triangle.fill" }
        return summary.freed > 0 ? "leaf.fill" : "trash.fill"
    }

    private func tint(_ summary: CleanupRunSummary) -> Color {
        summary.succeededIDs.isEmpty ? Theme.Airy.riskInk(.yourCall) : Theme.Airy.riskInk(.safe)
    }
}

// MARK: - Debugging

#if DEBUG
/// Debug only, for captures: `AIRY_CLEANUP_SCRIPT="action[:arg]@seconds,…"`.
/// - `select:<id>`: checks or unchecks a row.
/// - `cleansafe` / `clean:<id>`: open the confirmation (they run nothing).
/// - `selectgreen` / `selectall`: "Select All Green" / "Select All".
/// - `deleteall`: opens the "Delete all" sheet with the selection (doesn't confirm).
/// - `scrollto:<id>`: scrolls the list to that row.
/// - `cleantest`: opens the `user-logs` confirmation narrowed to `~/Library/Logs/AiryPrueba`.
/// No step confirms anything: sheets open to be looked at and close with `cancel`.
/// - `emptytrash`: opens the Empty Trash confirmation (never confirms it).
/// - `snapshots:<n>:<bytes>`: shows the snapshots notice with sample data.
/// - `celebrate:<bytes>`: shows the celebration.
/// - `fakeblock:<id>:<bundleID>`: paints a row as blocked by an open app.
/// - `cancel`: closes the sheet.
/// - `section:<section>`: goes back to a section (e.g. if another instance receives stray clicks).
@MainActor
enum CleanupDebugScript {
    private static var started = false
    private static let testRoot = NSHomeDirectory() + "/Library/Logs/AiryPrueba"

    private static func isTestPath(_ path: String) -> Bool {
        path == testRoot || path.hasPrefix(testRoot + "/")
    }

    static func run(model: AppModel, flow: CleanupFlow, select: @escaping (String) -> Void,
                    replaceSelection: @escaping (Set<String>) -> Void,
                    currentSelection: @escaping () -> Set<String>) {
        guard !started, let script = ProcessInfo.processInfo.environment["AIRY_CLEANUP_SCRIPT"] else { return }
        started = true
        for raw in script.split(separator: ",") {
            let parts = raw.split(separator: "@")
            guard parts.count == 2, let time = Double(parts[1]) else { continue }
            let action = parts[0].split(separator: ":", maxSplits: 1).map(String.init)
            DebugSnapshot.at(time) {
                perform(action[0], action.count > 1 ? action[1] : nil, model: model, flow: flow,
                        board: CleanupBoard(items: model.cleanupItems, hidden: flow.hiddenIDs), select: select,
                        replaceSelection: replaceSelection, currentSelection: currentSelection)
            }
        }
    }

    private static func perform(_ action: String, _ argument: String?, model: AppModel, flow: CleanupFlow,
                                board: CleanupBoard, select: (String) -> Void,
                                replaceSelection: (Set<String>) -> Void, currentSelection: () -> Set<String>) {
        FileHandle.standardError.write(Data("[cleanup-script] \(action) \(argument ?? "")\n".utf8))
        switch action {
        case "select": if let argument { select(argument) }
        case "cleansafe": flow.requestClean(board.readySafeItems)
        case "selectgreen": replaceSelection(board.greenSelection)
        case "selectall": replaceSelection(board.fullSelection)
        // Only opens the "Delete all" sheet; no step confirms.
        case "deleteall": flow.requestClean(board.selected(currentSelection()))
        case "clean": flow.requestClean(board.items.filter { $0.id == argument })
        case "scrollto": flow.debugScrollTarget = argument
        case "cleantest":
            // Only the test folder: the `user-logs` item narrowed to what is in AiryPrueba.
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
