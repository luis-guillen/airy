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
    /// Open groups (remembered across launches) and the open row of each group (one at a time).
    @ViewState private var disclosure = CleanupDisclosureStore.current
    @ViewState private var expandedRows: [CleanupDisclosure.Group: String] = [:]
    @Environment(\.airyTransientMotion) private var motion
    private static let topID = "cleanup-top"

    /// Opening and closing: the section spring, or no motion at all with Reduce Motion (or a hidden window).
    private var disclosureAnimation: Animation? { motion == .running ? Theme.sectionSpring : nil }

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
            // Spacing 0: the blocks bring their own gaps, so a group header sits close to its rows.
            // The group headers stay pinned at the top while their rows scroll under them.
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                SectionHeader(title: Section.cleanup.title, subtitle: subtitle(board)) {
                    PrimaryButton(model.isRefreshingCleanup ? "Searching…" : "Search Again",
                                  systemImage: "arrow.clockwise", style: .secondary,
                                  isBusy: model.isRefreshingCleanup) {
                        model.refreshCleanup()
                    }
                    .fixedSize()
                    .disabled(flow.isBusy || model.catalog == nil)
                }
                .padding(.bottom, Self.blockGap)
                .id(Self.topID)

                if model.catalog == nil {
                    unavailable
                } else {
                    HeroCard(board: board, selection: $selection,
                             isDetecting: model.isRefreshingCleanup && model.cleanupItems.isEmpty)
                        .padding(.bottom, Self.blockGap)

                    if let result = flow.lastResult {
                        ResultBanner(result: result) {
                            withAnimation(Theme.sectionSpring) { flow.lastResult = nil }
                        }
                        .padding(.bottom, Self.blockGap)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    if board.groups.isEmpty && board.reviewItems.isEmpty {
                        emptyState
                    }

                    ForEach(Array(board.groups.enumerated()), id: \.element.id) { index, group in
                        groupSection(group, index: index, selected: selected)
                    }

                    if !board.reviewItems.isEmpty {
                        reviewSection(board.reviewItems, index: board.groups.count)
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
            guard let target else { return }
            // A row in a closed group isn't drawn: open it first, then scroll once it has a place.
            reveal(target)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation(Theme.zoomSpring) { proxy.scrollTo(target, anchor: .center) }
            }
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
                                       currentSelection: { selection },
                                       reveal: { reveal($0) },
                                       setGroupOpen: { name, open in
                                           if let key = CleanupDisclosure.Group(rawValue: name) {
                                               withAnimation(disclosureAnimation) { disclosure.setOpen(open, for: key) }
                                           }
                                       }) }
        #endif
    }

    /// A risk group: its header (pinned while scrolling) and, if open, its rows.
    @ViewBuilder
    private func groupSection(_ group: CleanupBoard.Group, index: Int, selected: [CleanupItem]) -> some View {
        let key = CleanupDisclosure.Group(risk: group.risk)
        let open = disclosure.isOpen(key, count: group.items.count)
        SwiftUI.Section {
            if open {
                GroupCard(group: group, selection: $selection, expandedID: expandedRows[key]) { id in
                    toggleRow(id, in: key)
                }
                .padding(.bottom, Self.groupGap)
                .transition(.opacity)
                .opacity(appeared ? 1 : 0)
                .animation(Theme.stagger(index: index * 4 + 1), value: appeared)
            }
        } header: {
            GroupHeader(group: group, selected: selected.filter { $0.risk == group.risk },
                        isOpen: open, selection: $selection) { toggleGroup(key, count: group.items.count) }
                // A group's last row leaves with the whole group: also in leaves.
                .transition(.leafAway)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 10)
                .animation(Theme.stagger(index: index * 4), value: appeared)
        }
    }

    @ViewBuilder
    private func reviewSection(_ items: [CleanupItem], index: Int) -> some View {
        let open = disclosure.isOpen(.review, count: items.count)
        SwiftUI.Section {
            if open {
                ReviewCard(items: items, expandedID: expandedRows[.review]) { id in
                    toggleRow(id, in: .review)
                }
                .padding(.bottom, Self.groupGap)
                .transition(.opacity)
            }
        } header: {
            ReviewHeader(items: items, isOpen: open) { toggleGroup(.review, count: items.count) }
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 10)
                .animation(Theme.stagger(index: index * 4), value: appeared)
        }
    }

    private static let blockGap: CGFloat = 22
    private static let groupGap: CGFloat = 16

    private func toggleGroup(_ key: CleanupDisclosure.Group, count: Int) {
        withAnimation(disclosureAnimation) { disclosure.toggle(key, count: count) }
        CleanupDisclosureStore.save(disclosure)
    }

    /// One open row per group: opening another closes the previous one.
    private func toggleRow(_ id: String, in key: CleanupDisclosure.Group) {
        withAnimation(disclosureAnimation) {
            expandedRows[key] = expandedRows[key] == id ? nil : id
        }
    }

    #if DEBUG
    /// Opens the group of an item and its details (captures and `scrollto`); it isn't saved.
    private func reveal(_ id: String) {
        let board = board
        let key: CleanupDisclosure.Group
        if let item = board.items.first(where: { $0.id == id }) {
            key = CleanupDisclosure.Group(risk: item.risk)
        } else if board.reviewItems.contains(where: { $0.id == id }) {
            key = .review
        } else {
            return
        }
        withAnimation(disclosureAnimation) {
            disclosure.setOpen(true, for: key)
            expandedRows[key] = id
        }
    }
    #endif

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

/// Which groups are open survives relaunches (`UserDefaults`, small UI state). With `AIRY_SUPPORT_DIR` (DEBUG)
/// the real defaults aren't touched: the choice lives in memory only.
@MainActor
enum CleanupDisclosureStore {
    private static let key = "cleanupOpenGroups"
    private static var touchesDefaults: Bool { AppPaths.standard().legacySupport != nil }

    /// Read once per process; it keeps the last choice when the section is left and opened again.
    private(set) static var current: CleanupDisclosure = {
        guard touchesDefaults, let raw = UserDefaults.standard.dictionary(forKey: key) as? [String: Bool] else {
            return CleanupDisclosure()
        }
        return CleanupDisclosure(stored: raw)
    }()

    static func save(_ disclosure: CleanupDisclosure) {
        current = disclosure
        guard touchesDefaults else { return }
        UserDefaults.standard.set(disclosure.stored, forKey: key)
    }
}

/// A group's header bar: it stays pinned while its rows scroll. A click anywhere but its buttons opens or
/// closes the group; it shows the items, the total and how much of it is selected even when closed.
private struct GroupHeader: View {
    @Environment(CleanupFlow.self) private var flow
    let group: CleanupBoard.Group
    /// The selected items of this group.
    let selected: [CleanupItem]
    let isOpen: Bool
    @Binding var selection: Set<String>
    var onToggle: () -> Void

    var body: some View {
        let upperBound = group.items.contains(where: CleanupBoard.isPartial)
        DisclosureHeaderBar(isOpen: isOpen, symbol: Theme.symbol(for: group.risk),
                            ink: Theme.Airy.riskInk(group.risk), fill: Theme.Airy.riskFill(group.risk),
                            title: group.title, blurb: Self.blurb(group.risk), count: group.items.count,
                            amount: CleanupBoard.amountText(group.bytes, upperBound: upperBound),
                            bytes: group.bytes, onToggle: onToggle) {
            if let note {
                Text(note)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.Airy.accent)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Theme.Airy.accentFill.opacity(0.14), in: Capsule())
                    .fixedSize()
            }
            if group.risk != .doNotTouch {
                let selectable = Set(group.items.filter(CleanupBoard.canSelect).map(\.id))
                Button("Select This Group") {
                    withAnimation(Theme.pressSpring) { selection.formUnion(selectable) }
                }
                .buttonStyle(.plain)
                .font(.callout.weight(.medium))
                .foregroundStyle(Theme.Airy.accent)
                .fixedSize()
                .disabled(selectable.isEmpty || selectable.isSubset(of: selection) || flow.isBusy)
            }
        }
    }

    /// "Cleaning…" while a batch works on this group; otherwise "2 selected · 1.2 GB" if something is checked.
    private var note: String? {
        if let current = flow.currentID, group.items.contains(where: { $0.id == current }) {
            return String(localized: "Cleaning…")
        }
        guard !selected.isEmpty else { return nil }
        let (bytes, upperBound) = CleanupBoard.total(selected)
        let amount = CleanupBoard.amountText(bytes, upperBound: upperBound)
        return selected.count == 1 ? String(localized: "1 selected · \(amount)")
                                   : String(localized: "\(Theme.count(selected.count)) selected · \(amount)")
    }

    static func blurb(_ risk: Risk) -> String {
        switch risk {
        case .safe: String(localized: "It recreates itself: delete it without worry.")
        case .yourCall: String(localized: "It can be deleted, but you lose something: read what.")
        case .doNotTouch: String(localized: "It isn’t deleted: Airy tells you why.")
        }
    }
}

/// The shared bar of the group headers: chevron, risk icon, title, one-line description, items and total,
/// and the group's own controls (`trailing`) at the end.
private struct DisclosureHeaderBar<Trailing: View>: View {
    let isOpen: Bool
    let symbol: String
    let ink: Color
    let fill: Color
    let title: String
    let blurb: String
    let count: Int
    let amount: String
    let bytes: Int64
    var onToggle: () -> Void
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                DisclosureChevron(isExpanded: isOpen, size: 12)
                ZStack {
                    Circle().fill(fill.opacity(AiryPalette.badgeTintOpacity))
                    Circle().strokeBorder(fill.opacity(0.35), lineWidth: 0.5)
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ink)
                }
                .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(title)
                            .font(.system(.title3, design: .rounded, weight: .bold))
                            .lineLimit(1)
                            .fixedSize()
                        Text(count == 1 ? String(localized: "1 item · \(amount)")
                                        : String(localized: "\(Theme.count(count)) items · \(amount)"))
                            .font(.callout.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                            .contentTransition(.numericText(value: Double(bytes)))
                    }
                    Text(blurb)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits([.isHeader, .isButton])
            .accessibilityValue(isOpen ? String(localized: "Expanded") : String(localized: "Collapsed"))
            .accessibilityAction(.default, onToggle)

            Spacer(minLength: 8)
            trailing
        }
        .padding(.leading, 12)
        .padding(.trailing, 16)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .fill(.regularMaterial)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.04)],
                                             startPoint: .top, endPoint: .bottom),
                              lineWidth: 0.75)
        }
        .contentShape(Rectangle())
        // The buttons inside win their own clicks; anywhere else toggles the group.
        .onTapGesture(perform: onToggle)
        .padding(.bottom, 10)
    }
}

/// The rows of an open group, in one glass card.
private struct GroupCard: View {
    @Environment(CleanupFlow.self) private var flow
    let group: CleanupBoard.Group
    @Binding var selection: Set<String>
    let expandedID: String?
    var onExpand: (String) -> Void

    var body: some View {
        GlassCard(padding: 0) {
            VStack(spacing: 0) {
                ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                    VStack(spacing: 0) {
                        if index > 0 { Divider().opacity(0.5).padding(.leading, CleanupRow.detailsInset) }
                        CleanupRow(item: item, isSelected: selection.contains(item.id),
                                   isExpanded: expandedID == item.id) {
                            withAnimation(Theme.pressSpring) { selection.formSymmetricDifference([item.id]) }
                        } onExpand: {
                            onExpand(item.id)
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

// MARK: - Review only

/// The informational items: what it is and how to do it yourself. No checkbox or delete button; only "Show in Finder".
private struct ReviewHeader: View {
    let items: [CleanupItem]
    let isOpen: Bool
    var onToggle: () -> Void

    var body: some View {
        let bytes = items.reduce(Int64(0)) { $0 + $1.bytes }
        DisclosureHeaderBar(isOpen: isOpen, symbol: "eye", ink: .secondary, fill: .secondary,
                            title: String(localized: "Review Only"),
                            blurb: String(localized: "Airy tells you what it is and how to do it yourself; there’s no delete button here."),
                            count: items.count, amount: Format.bytes(bytes), bytes: bytes, onToggle: onToggle) {
            EmptyView()
        }
    }
}

private struct ReviewCard: View {
    let items: [CleanupItem]
    let expandedID: String?
    var onExpand: (String) -> Void

    var body: some View {
        GlassCard(padding: 0) {
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider().opacity(0.5).padding(.leading, CleanupRow.detailsInset) }
                    ReviewRow(item: item, isExpanded: expandedID == item.id) { onExpand(item.id) }
                        .id(item.id)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        }
    }
}

private struct ReviewRow: View {
    let item: CleanupItem
    let isExpanded: Bool
    var onExpand: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "info.circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 24, height: 24)
                CleanupIcon(entry: item.entry, dimmed: true, size: 28)
                Text(item.title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                Spacer(minLength: 8)
                Text(CleanupBoard.sizeText(item))
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                RiskBadge(risk: item.risk, compact: true, reason: RiskExplanation.why(item))
                DisclosureChevron(isExpanded: isExpanded)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.primary.opacity(hovering ? 0.035 : 0))
            .contentShape(Rectangle())
            .onTapGesture(perform: onExpand)
            .onHover { hovering in withAnimation(Theme.pressSpring) { self.hovering = hovering } }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(isExpanded ? String(localized: "Expanded") : String(localized: "Collapsed"))

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.entry.reviewHint ?? RiskExplanation.why(item))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(nil)
                        .frame(maxWidth: 640, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if !item.paths.isEmpty {
                        Button("Show in Finder", systemImage: "folder") {
                            NSWorkspace.shared.activateFileViewerSelecting(item.paths.prefix(20).map { URL(fileURLWithPath: $0) })
                        }
                        .buttonStyle(.plain)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Theme.Airy.accent)
                    }
                }
                .padding(.leading, CleanupRow.detailsInset)
                .padding(.trailing, 18)
                .padding(.bottom, 14)
                .transition(.opacity)
            }
        }
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
/// - `scrollto:<id>`: opens that row (and its group) and scrolls the list to it.
/// - `expand:<id>`: opens that row and its group without scrolling.
/// - `open:<group>` / `close:<group>`: opens or closes a group (`safe`, `yourCall`, `doNotTouch`, `review`); not saved.
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
                    currentSelection: @escaping () -> Set<String>,
                    reveal: @escaping (String) -> Void,
                    setGroupOpen: @escaping (String, Bool) -> Void) {
        guard !started, let script = ProcessInfo.processInfo.environment["AIRY_CLEANUP_SCRIPT"] else { return }
        started = true
        for raw in script.split(separator: ",") {
            let parts = raw.split(separator: "@")
            guard parts.count == 2, let time = Double(parts[1]) else { continue }
            let action = parts[0].split(separator: ":", maxSplits: 1).map(String.init)
            DebugSnapshot.at(time) {
                perform(action[0], action.count > 1 ? action[1] : nil, model: model, flow: flow,
                        board: CleanupBoard(items: model.cleanupItems, hidden: flow.hiddenIDs), select: select,
                        replaceSelection: replaceSelection, currentSelection: currentSelection,
                        reveal: reveal, setGroupOpen: setGroupOpen)
            }
        }
    }

    private static func perform(_ action: String, _ argument: String?, model: AppModel, flow: CleanupFlow,
                                board: CleanupBoard, select: (String) -> Void,
                                replaceSelection: (Set<String>) -> Void, currentSelection: () -> Set<String>,
                                reveal: (String) -> Void, setGroupOpen: (String, Bool) -> Void) {
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
        case "expand": if let argument { reveal(argument) }
        case "open": if let argument { setGroupOpen(argument, true) }
        case "close": if let argument { setGroupOpen(argument, false) }
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
