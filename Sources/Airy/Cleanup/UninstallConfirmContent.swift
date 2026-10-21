import SwiftUI
import DiskMapCore

/// Confirmation for the Uninstaller (`.uninstall`, `.orphans`, `.brokenLinks`) and Duplicates (`.duplicates`)
/// inside `ConfirmSheet`.
/// It says what quits, what goes to the Trash, what Homebrew deletes directly and what stays.
struct UninstallConfirmContent: View {
    @Environment(AppModel.self) private var model
    @Environment(CleanupFlow.self) private var flow
    let request: CleanupFlow.ConfirmRequest
    /// Homebrew's verdict per app (`UninstallRequest.id`), read when the sheet opens (`brew info`, read-only).
    @State private var caskVerdicts: [String: CaskVerdict] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 14) { content }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 360)
            .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.primary.opacity(0.07), lineWidth: 0.75)
            }
            if let refusal = model.destructiveRefusal {
                Label(refusal, systemImage: "nosign")
                    .font(.callout)
                    .foregroundStyle(Theme.Airy.riskInk(.doNotTouch))
            }
            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") { flow.cancelSheet() }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
                // Return only confirms what goes entirely to the Trash (orphaned leftovers).
                if isTrashOnly {
                    confirmButton.keyboardShortcut(.defaultAction)
                } else {
                    confirmButton
                }
            }
        }
        .task { await loadCaskVerdicts() }
    }

    private var confirmButton: some View {
        PrimaryButton(confirmTitle, systemImage: "trash", style: isIrreversible ? .destructive : .primary) {
            flow.confirm(request, model: model, blocked: blocked)
        }
        .fixedSize()
        .disabled(model.destructiveRefusal != nil || nothingToDo || checkingHomebrew)
    }

    // MARK: Data

    private var isDuplicates: Bool { if case .duplicates = request.kind { true } else { false } }

    private var isTrashOnly: Bool {
        switch request.kind {
        case .orphans, .duplicates: true
        default: false
        }
    }

    /// What the checked copies would free (computed by the Duplicates board; 0 for APFS clones).
    private var duplicatesBytes: Int64 { model.sections.duplicates.board.reclaimableBytes }

    /// Apps Airy doesn't uninstall (the plan refused them): they don't run.
    private var blocked: Set<String> {
        guard case .uninstall(let requests) = request.kind else { return [] }
        return Set(requests.filter { $0.plan.refusal != nil }.map(\.id))
    }

    /// While it isn't known whether Homebrew will delete the app without the Trash, no confirming.
    private var checkingHomebrew: Bool {
        guard case .uninstall(let requests) = request.kind else { return false }
        return requests.contains {
            $0.plan.refusal == nil && $0.plan.app.caskToken != nil && caskVerdicts[$0.id] == nil
        }
    }

    private var nothingToDo: Bool {
        guard case .uninstall(let requests) = request.kind else { return false }
        return requests.allSatisfy { blocked.contains($0.id) }
    }

    /// Homebrew deletes the app without the Trash; until it is known what it will do, treat it as irreversible.
    private var isIrreversible: Bool {
        switch request.kind {
        case .brokenLinks: true
        case .uninstall(let requests):
            requests.contains { $0.plan.app.caskToken != nil && caskVerdicts[$0.id]?.usesBrew != false }
        default: false
        }
    }

    private func loadCaskVerdicts() async {
        guard case .uninstall(let requests) = request.kind else { return }
        for item in requests where item.plan.refusal == nil && item.plan.app.caskToken != nil {
            if Task.isCancelled { return }
            if let verdict = await model.caskVerdict(for: item.plan.app) { caskVerdicts[item.id] = verdict }
        }
    }

    private var title: String {
        switch request.kind {
        case .uninstall(let requests):
            requests.count == 1 ? String(localized: "Uninstall “\(requests[0].plan.app.name)”?")
                                : String(localized: "Uninstall \(Theme.count(requests.count)) apps?")
        case .orphans(let groups):
            groups.count == 1 ? String(localized: "Move the leftovers of “\(groups[0].bundleID)” to the Trash?")
                              : String(localized: "Move \(Theme.count(groups.count)) orphaned leftovers to the Trash?")
        case .brokenLinks(let links):
            links.count == 1 ? String(localized: "Remove 1 broken link?")
                             : String(localized: "Remove \(Theme.count(links.count)) broken links?")
        case .duplicates(let removals):
            removals.reduce(0) { $0 + $1.remove.count } == 1
                ? String(localized: "Move 1 copy to the Trash?")
                : String(localized: "Move \(Theme.count(removals.reduce(0) { $0 + $1.remove.count })) copies to the Trash?")
        default: ""
        }
    }

    private var subtitle: String {
        switch request.kind {
        case .uninstall(let requests):
            let total = requests.filter { !blocked.contains($0.id) }
                .reduce(Int64(0)) { $0 + $1.plan.bytes(selected: $1.selected) }
            return String(localized: "Total: \(Format.bytes(total)).")
        case .orphans(let groups):
            return String(localized: "\(Format.bytes(groups.reduce(0) { $0 + $1.bytes })) will go to the Trash. The space is freed when you empty it.")
        case .brokenLinks:
            return String(localized: "Links in /usr/local/bin that no longer point to anything.")
        case .duplicates:
            return String(localized: "Total: \(Format.bytes(duplicatesBytes)). The space is freed when you empty the Trash.")
        default: return ""
        }
    }

    private var confirmTitle: String {
        switch request.kind {
        case .uninstall(let requests):
            let count = requests.count - blocked.count
            return count <= 1 ? String(localized: "Uninstall") : String(localized: "Uninstall \(Theme.count(count)) Apps")
        case .orphans, .duplicates: return String(localized: "Move to Trash")
        case .brokenLinks: return String(localized: "Remove Broken Links")
        default: return ""
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(isIrreversible ? AnyShapeStyle(Theme.Airy.destructiveGradient) : AnyShapeStyle(Theme.brand))
                Image(systemName: isDuplicates ? "doc.on.doc.fill" : "xmark.app.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(.title2, design: .rounded, weight: .bold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch request.kind {
        case .uninstall(let requests):
            ForEach(Array(requests.enumerated()), id: \.element.id) { index, request in
                if index > 0 { Divider().opacity(0.5) }
                appSection(request)
            }
            if requests.count > 1 {
                note("list.number", .secondary,
                     "They’re uninstalled one at a time; before each one Airy checks again that it’s still safe.")
            }
        case .orphans(let groups):
            ForEach(groups) { group in
                line(group.bundleID, detail: group.paths.map { Format.tildePath($0) }.joined(separator: "\n"),
                     size: group.bytes, risk: group.risk)
            }
            note("arrow.uturn.backward.circle", Theme.Airy.riskInk(.safe),
                 "What goes to the Trash can be recovered until you empty it.")
            note("checkmark.shield", .secondary,
                 "Right before moving them, Airy checks again that their app still isn’t installed.")
        case .brokenLinks(let links):
            ForEach(links) { link in
                line("\((link.path as NSString).lastPathComponent) → \(link.target)", detail: link.path, size: nil,
                     risk: nil)
            }
            note("exclamationmark.triangle.fill", Theme.Airy.riskInk(.yourCall),
                 "Broken links are deleted: they point to nothing and don’t go to the Trash.")
            if links.contains(where: \.needsAdmin) {
                note("lock.fill", .secondary, "You’ll be asked for your administrator password.")
            }
        case .duplicates(let removals):
            ForEach(Array(removals.enumerated()), id: \.offset) { index, removal in
                if index > 0 { Divider().opacity(0.5) }
                VStack(alignment: .leading, spacing: 6) {
                    note("checkmark.circle.fill", Theme.Airy.riskInk(.safe),
                         "Kept: \(Format.tildePath(removal.keep))")
                    note("trash", .secondary,
                         "To the Trash: \(removal.remove.map { Format.tildePath($0) }.joined(separator: ", "))")
                }
            }
            HStack {
                Text("Total").font(.callout.weight(.semibold))
                Spacer()
                Text(Format.bytes(duplicatesBytes)).font(.callout.weight(.semibold)).monospacedDigit()
            }
            note("checkmark.shield", .secondary, "Before moving anything, Airy compares each copy again.")
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func appSection(_ request: UninstallRequest) -> some View {
        let plan = request.plan
        let app = plan.app
        let chosen = plan.leftovers.filter { $0.canSelect && request.selected.contains($0.id) }
        let green = chosen.filter { $0.risk == .safe }
        let amber = chosen.filter { $0.risk == .yourCall }
        let red = plan.leftovers.filter { !$0.canSelect }
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(app.name).font(.headline).strikethrough(plan.refusal != nil)
                Spacer()
                Text(Format.bytes(plan.bytes(selected: request.selected)))
                    .font(.callout.weight(.semibold)).monospacedDigit()
            }
            if let refusal = plan.refusal {
                note("nosign", Theme.Airy.riskInk(.doNotTouch), "Won’t be done: \(refusal)")
            } else {
                note("power", .secondary, "“\(app.name)” will quit if it’s open (it may ask you to save).")
                if let token = app.caskToken {
                    switch caskVerdicts[request.id] {
                    case .some(.useBrew):
                        note("exclamationmark.triangle.fill", Theme.Airy.riskInk(.doNotTouch),
                             "Homebrew deletes the app directly with `brew uninstall --cask \(token)`: it doesn’t go to the Trash and can’t be recovered from it.")
                        note("terminal", .secondary,
                             "Homebrew may run the app’s own uninstall steps; Airy has reviewed them first.")
                    case .some(.fallback(let reason)):
                        note("info.circle", .secondary, verbatim: reason)
                        note("trash", Theme.Airy.riskInk(.safe), "The app will go to the Trash.")
                    case .none:
                        note("hourglass", .secondary, "Checking what Homebrew would do with “\(app.name)”…")
                    }
                } else {
                    note("trash", Theme.Airy.riskInk(.safe), "The app will go to the Trash.")
                }
                if !chosen.filter({ $0.kind != .receipt && $0.kind != .systemLocation }).isEmpty {
                    note("arrow.uturn.backward.circle", .secondary,
                         "The leftovers you choose go to the Trash (Airy checks them before moving them).")
                }
                ForEach(green) { leftover in
                    line(Format.tildePath(leftover.path), detail: leftover.reason, size: leftover.bytes, risk: .safe)
                }
                if !amber.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Check: this doesn’t regenerate by itself", systemImage: Theme.symbol(for: .yourCall))
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(Theme.Airy.riskInk(.yourCall))
                        ForEach(amber) { leftover in
                            line(Format.tildePath(leftover.path), detail: leftover.reason, size: leftover.bytes,
                                 risk: .yourCall)
                        }
                    }
                    .padding(10)
                    .background(Theme.Airy.riskFill(.yourCall).opacity(0.10),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                if !red.isEmpty {
                    Text("Stays").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(red) { leftover in
                        line(Format.tildePath(leftover.path), detail: leftover.reason, size: nil, risk: .doNotTouch)
                    }
                }
                if chosen.contains(where: { $0.kind == .receipt }) {
                    note("lock.fill", .secondary, "You’ll be asked for your administrator password (once for each app with install receipts).")
                }
            }
        }
    }

    private func line(_ title: String, detail: String?, size: Int64?, risk: Risk?) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if let risk { RiskBadge(risk: risk, compact: true) }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                if let detail, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(4)
                }
            }
            Spacer(minLength: 8)
            if let size { Text(Format.bytes(size)).font(.callout).monospacedDigit().foregroundStyle(.secondary) }
        }
    }

    /// `text` is a localization key; `verbatim:` takes a `String` already localized (e.g. from DiskMapCore).
    private func note(_ symbol: String, _ tint: Color, _ text: LocalizedStringKey) -> some View {
        note(symbol, tint, label: Text(text))
    }

    private func note(_ symbol: String, _ tint: Color, verbatim text: String) -> some View {
        note(symbol, tint, label: Text(text))
    }

    private func note(_ symbol: String, _ tint: Color, label text: Text) -> some View {
        Label { text } icon: { Image(systemName: symbol).foregroundStyle(tint) }
            .font(.callout)
            .foregroundStyle(.secondary)
    }
}
