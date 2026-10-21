import SwiftUI
import DiskMapCore

/// Confirmation sheet before any deletion: what is done, how much it takes and with which method.
/// It is the app's only one (Cleanup, sidebar, map and assistant). If the request carries a warning
/// ("This is your call"), it shows it first and the real confirmation comes after "Yes, Move It…".
struct ConfirmSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(CleanupFlow.self) private var flow
    let request: CleanupFlow.ConfirmRequest
    @ViewState private var warningAccepted = false
    /// The executor's preview (same plan as on confirmation), per row. `nil` while it is computed.
    @ViewState private var previews: [String: CleanupPreview]?
    /// Rows that won't be done (item id, individual path or "trash") with their reason.
    @ViewState private var blockReasons: [String: String]?
    /// Rows removed with a click ("Remove"): they aren't deleted and leave the total.
    @ViewState private var removed: Set<String> = []

    var body: some View {
        Group {
            if isQuit {
                QuitConfirmation(request: request)
            } else if let warning = request.warning, !warningAccepted {
                warningStep(warning)
                    .transition(.opacity.combined(with: .offset(x: -12)))
            } else if isUninstallerKind {
                UninstallConfirmContent(request: request)
                    .transition(.opacity.combined(with: .offset(x: 12)))
            } else {
                confirmation
                    .transition(.opacity.combined(with: .offset(x: 12)))
            }
        }
        .padding(24)
        .frame(width: 540)
        .animation(Theme.sectionSpring, value: warningAccepted)
        // With a prior warning ("This is your call", a proposal by link), the preview waits for the
        // user to accept it: opening the sheet doesn't query the executor.
        .task(id: warningAccepted) {
            guard !isQuit, request.warning == nil || warningAccepted, blockReasons == nil else { return }
            await loadPreview()
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .airyAssistantDebug)) { note in
            switch note.userInfo?["action"] as? String {
            case "second": warningAccepted = true
            case "cancel": flow.cancelSheet()
            default: break
            }
        }
        #endif
    }

    // MARK: First step ("Your call")

    private func warningStep(_ warning: CleanupFlow.ConfirmRequest.Warning) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Circle().fill(Theme.Airy.riskFill(.yourCall).opacity(0.16))
                    Image(systemName: Theme.symbol(for: .yourCall))
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Theme.Airy.riskInk(.yourCall))
                }
                .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(warning.title)
                        .font(.system(.title2, design: .rounded, weight: .bold))
                    Text(warning.subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Text("“\(warning.reason)”")
                .font(.callout)
                .foregroundStyle(.primary.opacity(0.85))
                .lineLimit(nil)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.Airy.riskFill(.yourCall).opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(warning.note)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(nil)
            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") { flow.cancelSheet() }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
                PrimaryButton(warning.continueTitle, systemImage: "arrow.right", style: .secondary) {
                    warningAccepted = true
                }
                .fixedSize()
            }
        }
    }

    // MARK: Confirmation

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            if isItems {
                // Up to four rows fit without scrolling; with more, a fixed height.
                if rows.count + reviewRows.count <= 4 {
                    itemBlocks
                } else {
                    ScrollView { itemBlocks }
                        .scrollBounceBehavior(.basedOnSize)
                        .frame(height: 340)
                }
            } else {
                Group {
                    if rows.count <= 4 {
                        rowList
                    } else {
                        ScrollView { rowList }
                            .scrollBounceBehavior(.basedOnSize)
                            .frame(height: 300)
                    }
                }
                .modifier(RowBox())
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(notes, id: \.text) { note in
                    Label {
                        Text(note.text)
                    } icon: {
                        Image(systemName: note.symbol).foregroundStyle(note.tint)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") { flow.cancelSheet() }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
                // Return only confirms what can be undone (everything to the Trash). Emptying the Trash or
                // running an official command is irreversible: the button has to be clicked.
                if returnConfirms {
                    confirmButton.keyboardShortcut(.defaultAction)
                } else {
                    confirmButton
                }
            }
        }
    }

    private var confirmButton: some View {
        PrimaryButton(confirmTitle, systemImage: confirmSymbol, style: isEmptyTrash ? .destructive : .primary) {
            flow.confirm(request, model: model, blocked: Set((blockReasons ?? [:]).keys), excluding: excluded)
        }
        .fixedSize()
        // No confirming until the preview is there; if everything is blocked or removed, there is nothing to do.
        .disabled(blockReasons == nil || (rows + reviewRows).allSatisfy { blockReasons?[$0.id] != nil })
    }

    // MARK: Preview

    /// Asks the executor what each row would do now, with the batch's `runID`. What is blocked shows
    /// struck through with its reason and doesn't run.
    private func loadPreview() async {
        var reasons: [String: String] = [:]
        switch request.kind {
        case .items(let items):
            let previews = await model.preview(items, context: request.context)
            guard !Task.isCancelled else { return }
            for (id, preview) in previews { if case .blocked(let reason) = preview { reasons[id] = reason } }
            self.previews = previews
        case .trashPaths(let paths, _):
            for path in paths {
                if let refusal = model.destructiveRefusal ?? model.trashRefusal(path: path) { reasons[path] = refusal }
            }
        case .emptyTrash:
            if let refusal = model.destructiveRefusal { reasons["trash"] = refusal }
        case .uninstall, .orphans, .brokenLinks, .duplicates:
            break  // `UninstallConfirmContent` decides what is blocked.
        case .quitApps, .forceQuitApps: break
        }
        blockReasons = reasons
    }

    /// `true` only if everything goes to the Trash (recoverable): neither emptying it nor official commands.
    private var returnConfirms: Bool {
        switch request.kind {
        case .emptyTrash, .uninstall, .brokenLinks, .quitApps, .forceQuitApps: return false
        case .trashPaths, .orphans, .duplicates: return true
        case .items:
            return keptItems.allSatisfy { if case .trash = liveMethod($0) { true } else { false } }
        }
    }

    // MARK: Content

    private var rowList: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Divider().opacity(0.5).padding(.leading, 52) }
                ConfirmRowView(row: row, onRemove: isItems ? { remove([row.id]) } : nil)
            }
        }
    }

    /// The green list and, separately, the highlighted amber block (each row with its "why").
    private var itemBlocks: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !rows.isEmpty { rowList.modifier(RowBox()) }
            if !reviewRows.isEmpty {
                let amber = Theme.color(for: .yourCall)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: Theme.symbol(for: .yourCall))
                            .foregroundStyle(Theme.Airy.riskInk(.yourCall))
                        Text(CleanupBoard.reviewBlockTitle)
                            .font(.callout.weight(.semibold))
                            .lineLimit(nil)
                        Spacer(minLength: 8)
                        Button("Remove All Amber") { remove(reviewRows.map(\.id)) }
                            .buttonStyle(.plain)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.Airy.riskInk(.yourCall))
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 4)
                    ForEach(Array(reviewRows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider().opacity(0.5).padding(.leading, 52) }
                        ConfirmRowView(row: row, onRemove: { remove([row.id]) })
                    }
                }
                .background(amber.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(amber.opacity(0.6), lineWidth: 1)
                }
            }
            if rows.isEmpty && reviewRows.isEmpty {
                Text("You’ve removed everything: there’s nothing left to delete.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(12)
            }
        }
    }

    private func remove(_ ids: [String]) {
        withAnimation(Theme.pressSpring) { removed.formUnion(ids) }
    }

    private var isItems: Bool { if case .items = request.kind { true } else { false } }

    /// Green and amber items still in the sheet (removed ones and those that can't be checked don't count).
    private var sections: (regular: [CleanupItem], review: [CleanupItem]) {
        CleanupBoard.confirmSections(items, excluding: removed)
    }

    private var keptItems: [CleanupItem] { let s = sections; return s.regular + s.review }

    /// What will really run: without what the preview left blocked (shown struck through).
    private var runnableItems: [CleanupItem] { keptItems.filter { blockReasons?[$0.id] == nil } }

    /// What doesn't run: what was removed and what the sheet doesn't show (red, protected or blocked).
    private var excluded: Set<String> {
        let kept = Set(keptItems.map(\.id))
        return Set(items.map(\.id).filter { !kept.contains($0) })
    }

    private var isEmptyTrash: Bool { if case .emptyTrash = request.kind { true } else { false } }

    private var isUninstallerKind: Bool {
        switch request.kind {
        case .uninstall, .orphans, .brokenLinks, .duplicates: true
        case .items, .emptyTrash, .trashPaths: false
        case .quitApps, .forceQuitApps: false
        }
    }

    private var isQuit: Bool {
        switch request.kind {
        case .quitApps, .forceQuitApps: true
        default: false
        }
    }

    private var items: [CleanupItem] {
        if case .items(let items) = request.kind { return items }
        return []
    }

    private func liveMethod(_ item: CleanupItem) -> CleanupMethod {
        model.catalog?.entry(id: item.entry.id)?.cleanup ?? item.entry.cleanup
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(isEmptyTrash
                              ? AnyShapeStyle(Theme.Airy.destructiveGradient)
                              : AnyShapeStyle(Theme.brand))
                Image(systemName: isEmptyTrash ? "trash.fill" : "sparkles")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(.title2, design: .rounded, weight: .bold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var title: String {
        switch request.kind {
        case .emptyTrash: return String(localized: "Empty the Trash?")
        case .trashPaths(let paths, let title):
            return paths.count == 1 ? String(localized: "Move “\(title)” to the Trash?")
                                     : String(localized: "Move \(Theme.count(paths.count)) items to the Trash?")
        case .items:
            let count = runnableItems.count
            return count == 1 ? String(localized: "Delete 1 item?") : String(localized: "Delete \(Theme.count(count)) items?")
        case .uninstall, .orphans, .brokenLinks, .duplicates: return ""
        case .quitApps, .forceQuitApps: return ""
        }
    }

    private var subtitle: String {
        switch request.kind {
        case .emptyTrash(let bytes):
            return bytes.map { String(localized: "\(Format.bytes($0)) will be permanently deleted.") }
                ?? String(localized: "Airy can’t read the Trash, so it doesn’t know how much it takes up.")
        case .quitApps, .forceQuitApps: return ""
        case .trashPaths(let paths, _):
            let total = paths.compactMap { model.node(atPath: $0)?.allocatedSize }.reduce(0, +)
            return total > 0 ? String(localized: "\(Format.bytes(total)) will go to the Trash. The space is freed when you empty it.")
                             : String(localized: "It will go to the Trash. The space is freed when you empty it.")
        case .items:
            let items = keptItems
            guard !items.isEmpty else { return String(localized: "There’s nothing left to delete.") }
            // With partial cleanups (e.g. `pnpm store prune`) the figure is only a maximum: "up to X".
            let (total, upperBound) = CleanupBoard.total(items)
            let trash = items.filter { if case .trash = liveMethod($0) { true } else { false } }
            if trash.count == items.count { return String(localized: "\(Format.bytes(total)) will go to the Trash. The space is freed when you empty it.") }
            if trash.isEmpty {
                guard total > 0 else { return String(localized: "This is what will be done:") }
                return upperBound ? String(localized: "Up to \(Format.bytes(total)) will be freed.")
                                  : String(localized: "About \(Format.bytes(total)) will be freed.")
            }
            return upperBound
                ? String(localized: "Up to \(Format.bytes(total)) in total. What goes to the Trash is freed when you empty it.")
                : String(localized: "About \(Format.bytes(total)) in total. What goes to the Trash is freed when you empty it.")
        case .uninstall, .orphans, .brokenLinks, .duplicates: return ""
        }
    }

    private var rows: [ConfirmRow] {
        switch request.kind {
        case .quitApps, .forceQuitApps: return []
        case .emptyTrash(let bytes):
            return [ConfirmRow(id: "trash", title: String(localized: "Empty Trash"), symbol: "trash.fill",
                               tint: Theme.Airy.riskInk(.doNotTouch),
                               size: bytes.map(Format.bytes) ?? String(localized: "Unknown size"),
                               method: .text(bytes == nil ? String(localized: "Finder does it, on every disk")
                                                          : String(localized: "Permanent deletion")),
                               location: "~/.Trash", blockedReason: blockReasons?["trash"])]
        case .trashPaths(let paths, _):
            return paths.map { path in
                ConfirmRow(id: path, title: (path as NSString).lastPathComponent, symbol: "doc", tint: Theme.Airy.accent,
                           size: model.node(atPath: path).map { Format.bytes($0.allocatedSize) } ?? "—",
                           method: .text(blockReasons == nil ? String(localized: "To the Trash")
                                                              : String(localized: "Will go to the Trash")),
                           location: Format.tildePath(path), blockedReason: blockReasons?[path])
            }
        case .items:
            return sections.regular.map(itemRow)
        case .uninstall, .orphans, .brokenLinks, .duplicates: return []
        }
    }

    /// The sheet's amber block (empty for every other request).
    private var reviewRows: [ConfirmRow] {
        isItems ? sections.review.map(itemRow) : []
    }

    private func itemRow(_ item: CleanupItem) -> ConfirmRow {
                let method = liveMethod(item)
                let size = item.id == TrashFollowUp.snapshotEntryID
                    ? (item.bytes > 0 ? "≈ \(Format.bytes(item.bytes))" : String(localized: "Unknown size"))
                    : CleanupBoard.sizeText(item)
                let planned: ConfirmRow.Method? = switch previews?[item.id] {
                case .wouldTrash: .text(String(localized: "Will go to the Trash"))
                case .wouldRun(let command, _, _): .willRun(CleanupBoard.commandLine(command))
                case .blocked, nil: nil
                }
                return ConfirmRow(id: item.id, title: item.title, symbol: CleanupIcon.symbol(for: item.entry),
                                  tint: Theme.ink(for: item.entry.kind), size: size,
                                  method: planned ?? CleanupBoard.commandLine(method).map(ConfirmRow.Method.command)
                                      ?? .text(CleanupBoard.methodDescription(method)),
                                  // Where: essential when an entry spans many folders (e.g. ~/Library/Logs/*).
                                  location: CleanupBoard.locationSummary(item),
                                  blockedReason: blockReasons?[item.id],
                                  // Amber: always; green with a command: its short reason (e.g. that the Docker
                                  // images have to be downloaded again).
                                  why: item.risk == .yourCall || (item.risk == .safe && item.entry.shortReason != nil)
                                      ? RiskExplanation.why(item) : nil,
                                  whyIsWarning: item.risk == .yourCall,
                                  detail: Self.detailLine(item))
    }

    /// "Stopped containers: a, b and c" (Docker); for the rest, nothing.
    static func detailLine(_ item: CleanupItem) -> String? {
        guard item.entry.id == "docker-containers", !item.details.isEmpty else { return nil }
        let list = item.details.formatted(.list(type: .and).locale(Theme.locale))
        return String(localized: "Stopped containers: \(list)")
    }

    private struct Note { let symbol: String; let tint: Color; let text: String }

    private var notes: [Note] {
        previewNotes + kindNotes
    }

    private var previewNotes: [Note] {
        guard let blockReasons else {
            return [Note(symbol: "hourglass", tint: .secondary, text: String(localized: "Checking what will be done with each item…"))]
        }
        guard !blockReasons.isEmpty else { return [] }
        return [Note(symbol: "nosign", tint: Theme.Airy.riskInk(.doNotTouch),
                     text: String(localized: "What’s struck through won’t be done: Airy can’t do it right now."))]
    }

    private var kindNotes: [Note] {
        switch request.kind {
        case .quitApps, .forceQuitApps: return []
        case .emptyTrash(let bytes):
            let red = Theme.Airy.riskInk(.doNotTouch)
            if bytes == nil {
                return [Note(symbol: "exclamationmark.triangle.fill", tint: red,
                             text: String(localized: "Without Full Disk Access, Finder will be asked to do it, and it permanently empties the Trash on every disk, external ones included.")),
                        Note(symbol: "arrow.uturn.backward.circle", tint: red, text: String(localized: "This can’t be undone."))]
            }
            return [Note(symbol: "arrow.uturn.backward.circle", tint: red, text: String(localized: "This can’t be undone.")),
                    Note(symbol: "externaldrive", tint: .secondary,
                         text: String(localized: "If a file won’t delete, Finder will be asked to do it, and it also empties the Trash on external disks."))]
        case .trashPaths:
            return [Note(symbol: "arrow.uturn.backward.circle", tint: Theme.Airy.riskInk(.safe),
                         text: String(localized: "What goes to the Trash can be recovered until you empty it."))]
        case .items:
            let items = keptItems
            var notes: [Note] = []
            let methods = items.map(liveMethod)
            if methods.contains(where: { if case .trash = $0 { true } else { false } }) {
                notes.append(Note(symbol: "arrow.uturn.backward.circle", tint: Theme.Airy.riskInk(.safe),
                                  text: String(localized: "What goes to the Trash can be recovered until you empty it.")))
            }
            if items.allSatisfy({ $0.entry.section == .maintenance }) {
                // M4: only settings (`defaults`) and files sent to the Trash can be undone; reindexing Spotlight
                // (a command) can't be undone, but it doesn't delete anything either.
                let isCommand = { (item: CleanupItem) in
                    if case .command = liveMethod(item) { true } else { false }
                }
                if items.contains(where: { !isCommand($0) }) {
                    notes.append(Note(symbol: "arrow.uturn.backward.circle", tint: Theme.Airy.riskInk(.safe),
                                      text: String(localized: "Settings can be undone: the explanation says how.")))
                }
                if items.contains(where: isCommand) {
                    notes.append(Note(symbol: "magnifyingglass", tint: Theme.Airy.accent,
                                      text: String(localized: "Reindexing Spotlight can’t be undone, but it deletes nothing: it rebuilds the index and, meanwhile, searches may be incomplete and the Mac will be somewhat busier.")))
                }
            } else if methods.contains(where: { if case .command = $0 { true } else { false } }) {
                notes.append(Note(symbol: "terminal", tint: Theme.Airy.accent,
                                  text: String(localized: "Official commands free the space at once and can’t be undone.")))
            }
            if items.contains(where: CleanupBoard.isPartial) {
                notes.append(Note(symbol: "chart.bar.xaxis", tint: .secondary,
                                  text: String(localized: "“Up to”: that command only removes what’s no longer used, so it may free less.")))
            }
            if items.count > 1 {
                notes.append(Note(symbol: "list.number", tint: .secondary,
                                  text: String(localized: "They run one at a time; before each one Airy checks again that it’s still safe.")))
            }
            return notes
        case .uninstall, .orphans, .brokenLinks, .duplicates: return []
        }
    }

    private var confirmTitle: String {
        switch request.kind {
        case .emptyTrash(let bytes): return bytes == nil ? String(localized: "Empty with Finder") : String(localized: "Empty Trash")
        case .trashPaths: return String(localized: "Move to Trash")
        case .items:
            if keptItems.allSatisfy({ $0.entry.section == .maintenance }) { return String(localized: "Apply") }
            let (bytes, upperBound) = CleanupBoard.total(runnableItems)
            return String(localized: "Delete \(Theme.count(runnableItems.count)) · \(CleanupBoard.amountText(bytes, upperBound: upperBound))")
        case .uninstall, .orphans, .brokenLinks, .duplicates: return ""
        case .quitApps, .forceQuitApps: return ""
        }
    }

    private var confirmSymbol: String { isEmptyTrash ? "trash.slash" : "sparkles" }
}

struct ConfirmRow: Identifiable {
    /// `command`: the catalog's command; `willRun`: the one the executor confirmed in the preview.
    enum Method { case text(String), command(String), willRun(String) }
    let id: String
    let title: String
    let symbol: String
    let tint: Color
    let size: String
    let method: Method
    /// Where what is touched lives ("~/Library/Logs/A", "Everything in ~/Library/Logs (17 items)").
    var location: String?
    /// The preview says it won't be done (and why): the row shows struck through.
    var blockedReason: String?
    /// Why it is amber, or the short reason of a green row that has one.
    var why: String?
    /// Amber: in its color; green: in secondary.
    var whyIsWarning = true
    /// Extra line, e.g. "Stopped containers: a, b and c".
    var detail: String?
}

/// Box around the sheet's row list.
private struct RowBox: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.primary.opacity(0.07), lineWidth: 0.75)
            }
    }
}

private struct ConfirmRowView: View {
    let row: ConfirmRow
    /// "Remove" (one click): the row leaves the sheet and the total.
    var onRemove: (() -> Void)? = nil

    private func isWillRun(_ method: ConfirmRow.Method) -> Bool {
        if case .willRun = method { true } else { false }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(row.tint.opacity(0.18))
                Image(systemName: row.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(row.tint)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(row.title)
                        .font(.callout.weight(.semibold))
                        .strikethrough(row.blockedReason != nil)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(row.size)
                        .font(.callout.weight(.semibold))
                        .strikethrough(row.blockedReason != nil)
                        .monospacedDigit()
                    if let onRemove {
                        Button("Remove", action: onRemove)
                            .buttonStyle(.plain)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.Airy.accent)
                            .help("Don't delete this")
                    }
                }
                .foregroundStyle(row.blockedReason == nil ? .primary : .secondary)
                if let why = row.why {
                    Text(why)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(row.whyIsWarning ? AnyShapeStyle(Theme.Airy.riskInk(.yourCall))
                                                          : AnyShapeStyle(.secondary))
                        .lineLimit(nil)
                }
                if let detail = row.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                if let reason = row.blockedReason {
                    Label(reason, systemImage: "nosign")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.Airy.riskInk(.doNotTouch))
                        .lineLimit(3)
                }
                switch row.method {
                case .text(let text):
                    // The trash icon for "To the Trash" / "Will go to the Trash", in whichever language the text is in.
                    Label(text, systemImage: text.lowercased().hasSuffix(String(localized: "to the Trash").lowercased())
                          ? "trash" : "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .strikethrough(row.blockedReason != nil)
                case .command(let line), .willRun(let line):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(isWillRun(row.method) ? "Will run" : "Official command:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(line)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                }
                if let location = row.location {
                    Label(location, systemImage: "folder")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

// MARK: - Time Machine snapshots

/// After emptying the Trash, if the space hasn't shown up and there are local snapshots, it explains it
/// and offers to thin them with the catalog's `time-machine-snapshots` entry (with its confirmation).
struct SnapshotsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(CleanupFlow.self) private var flow
    let notice: CleanupFlow.SnapshotNotice

    var body: some View {
        let entry = model.catalog?.entry(id: TrashFollowUp.snapshotEntryID)
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Circle().fill(Theme.gradient(for: .system))
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text("The Space Hasn’t Shown Up Yet")
                        .font(.system(.title2, design: .rounded, weight: .bold))
                    Text("You emptied \(Format.bytes(notice.emptied)), but free space only went up by \(Format.bytes(notice.rose)).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            GlassCard(padding: 16, radius: 14, material: .thinMaterial) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label(notice.snapshotCount == 1 ? "1 local Time Machine snapshot"
                                  : "\(Theme.count(notice.snapshotCount)) local Time Machine snapshots",
                              systemImage: "camera.metering.matrix")
                            .font(.callout.weight(.semibold))
                        Spacer()
                        Text("≈ \(Format.bytes(notice.retained)) held")
                            .font(.callout.weight(.semibold))
                            .monospacedDigit()
                    }
                    Text("Snapshots keep a copy of what was on the disk, so what you just deleted keeps taking up space until they expire.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if let entry {
                        Text(entry.explanation)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            Text("Official command:").font(.caption).foregroundStyle(.secondary)
                            Text(CleanupBoard.commandLine(entry.cleanup) ?? "")
                                .font(.caption.monospaced())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        }
                    }
                }
            }

            HStack(spacing: 10) {
                RiskBadge(risk: entry?.risk ?? .yourCall)
                Spacer()
                Button("Not Now") { flow.cancelSheet() }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
                PrimaryButton("Thin Snapshots…", systemImage: "clock.arrow.circlepath") {
                    flow.requestSnapshotCleanup(notice, model: model)
                }
                .keyboardShortcut(.defaultAction)
                .fixedSize()
                .disabled(entry == nil)
            }
        }
        .padding(24)
        .frame(width: 540)
    }
}

// MARK: - Quit apps (Performance)

/// The two quit variants: normal ("Quit…?") and forced ("Force quit…?"). An agent's proposal
/// shows its warning at the top; nothing quits until the button is clicked.
struct QuitConfirmation: View {
    @Environment(AppModel.self) private var model
    @Environment(CleanupFlow.self) private var flow
    let request: CleanupFlow.ConfirmRequest

    private var groups: [AppGroup] {
        switch request.kind {
        case .quitApps(let g), .forceQuitApps(let g): g
        default: []
        }
    }

    private var isForce: Bool { if case .forceQuitApps = request.kind { true } else { false } }

    private var title: String {
        if isForce {
            return groups.count == 1 ? String(localized: "Force quit \(groups[0].name)?")
                                     : String(localized: "Force quit \(groups.count) apps?")
        }
        return groups.count == 1 ? String(localized: "Quit \(groups[0].name)?") : String(localized: "Quit \(groups.count) apps?")
    }

    var body: some View {
        let apps = groups.filter { $0.kind != .looseProcess }
        let loose = groups.filter { $0.kind == .looseProcess }
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Circle().fill(isForce ? AnyShapeStyle(Theme.Airy.destructiveGradient) : AnyShapeStyle(Theme.brand))
                    Image(systemName: isForce ? "xmark.octagon.fill" : "power")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 44, height: 44)
                Text(title)
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .lineLimit(2)
            }

            if let warning = request.warning {
                VStack(alignment: .leading, spacing: 4) {
                    Label(warning.title, systemImage: Theme.symbol(for: .yourCall))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Theme.Airy.riskInk(.yourCall))
                    Text(warning.subtitle).font(.callout).foregroundStyle(.secondary)
                    Text(warning.reason).font(.callout).lineLimit(nil)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.Airy.riskFill(.yourCall).opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            if !apps.isEmpty { rowBlock(apps) }
            if !loose.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Check: you may be using it", systemImage: Theme.symbol(for: .yourCall))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Theme.Airy.riskInk(.yourCall))
                    Text(QuitPolicy.looseWarning).font(.caption).foregroundStyle(.secondary).lineLimit(nil)
                    rowBlock(loose)
                }
                .padding(10)
                .background(Theme.Airy.riskFill(.yourCall).opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            Label(isForce ? "It didn’t respond to the normal quit. Anything unsaved will be lost."
                          : "Each app is asked to quit first; if it has unsaved work, it will ask you.",
                  systemImage: isForce ? "exclamationmark.triangle.fill" : "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(nil)

            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") { flow.cancelSheet() }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
                // Force quit: destructive role and no Return.
                PrimaryButton(isForce ? "Force Quit" : "Quit", systemImage: isForce ? "xmark.octagon" : "power",
                              style: isForce ? .destructive : .primary) {
                    flow.confirm(request, model: model)
                }
                .fixedSize()
            }
        }
    }

    private func rowBlock(_ groups: [AppGroup]) -> some View {
        VStack(spacing: 0) {
            ForEach(groups) { group in
                HStack {
                    Text(group.detail.map { "\(group.name) · \($0)" } ?? group.name)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    Text(group.pids.count == 1 ? "\(Format.bytes(group.memory)) · 1 process"
                                               : "\(Format.bytes(group.memory)) · \(group.pids.count) processes")
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
