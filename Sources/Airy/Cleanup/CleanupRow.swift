import SwiftUI
import DiskMapCore

/// A cleanup row. Collapsed, one line: checkbox, icon, title, size, risk and a small marker if something
/// blocks it. Expanded (click on the line), what it is, who creates it, whether it regenerates, where it is and,
/// if needed, why it can't be cleaned right now. The details are only built while the row is open.
struct CleanupRow: View {
    @Environment(AppModel.self) private var model
    @Environment(CleanupFlow.self) private var flow

    let item: CleanupItem
    let isSelected: Bool
    var isExpanded = false
    var onToggle: () -> Void
    var onExpand: () -> Void = {}

    @ViewState private var hovering = false

    private var showsCheckbox: Bool { CleanupBoard.showsCheckbox(item) }
    private var canSelect: Bool { CleanupBoard.canSelect(item) && !flow.isBusy }
    private var isCurrent: Bool { flow.currentID == item.id }
    private var isQueued: Bool { flow.queuedIDs.contains(item.id) }
    private var isInfo: Bool { if case .info = item.entry.cleanup { true } else { false } }
    /// The method comes from the live catalog entry (the one the executor will use).
    private var liveMethod: CleanupMethod { model.catalog?.entry(id: item.entry.id)?.cleanup ?? item.entry.cleanup }

    /// Where the details start: under the title (padding, checkbox, icon and their gaps).
    static let detailsInset: CGFloat = 16 + 24 + 12 + 28 + 12

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            line
            if isExpanded {
                details
                    .padding(.leading, Self.detailsInset)
                    .padding(.trailing, 18)
                    .padding(.bottom, 14)
                    .transition(.opacity)
            }
        }
        .contextMenu {
            // Non-destructive: no confirmation. Not offered for what is already protected (or has no paths, like Docker).
            if item.protection == nil, !item.paths.isEmpty {
                Button("Protect This", systemImage: "lock") { model.protect(paths: item.paths) }
            }
        }
    }

    /// The one line that is always there. A click opens or closes the details; the checkbox only selects.
    private var line: some View {
        HStack(spacing: 12) {
            leading
                .frame(width: 24, height: 24)

            CleanupIcon(entry: item.entry, dimmed: item.risk == .doNotTouch, size: 28)

            Text(item.title)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)

            blockedMarker

            Spacer(minLength: 8)

            Text(CleanupBoard.sizeText(item))
                .font(.system(.body, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(item.risk == .doNotTouch ? .secondary : .primary)
                .lineLimit(1)
                .fixedSize()

            if protectsOnlyTheFolder {
                ProtectedFolderBadge(compact: true, reason: why)
            } else {
                RiskBadge(risk: item.risk, compact: true, reason: why)
            }

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
        .accessibilityValue(accessibilityValue)
        .accessibilityAction(named: Text(isSelected ? "Remove from Selection" : "Select")) {
            if canSelect { onToggle() }
        }
    }

    private var accessibilityValue: String {
        let expansion = isExpanded ? String(localized: "Expanded") : String(localized: "Collapsed")
        guard showsCheckbox else { return expansion }
        return (isSelected ? String(localized: "Selected") : String(localized: "Not selected")) + ", " + expansion
    }

    /// Something keeps it from being cleaned now: an open app, a project using it or another block.
    @ViewBuilder private var blockedMarker: some View {
        let blocked = item.risk == .doNotTouch ? [] : blockedApps
        if !blocked.isEmpty {
            Image(systemName: "lock.app.dashed")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Airy.riskInk(.yourCall))
                .help(CleanupBoard.blockedMessage(appNames: blocked.map(CleanupFlow.appName)) ?? "")
        } else if let reason = CleanupBoard.blockedReasonText(item) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.Airy.riskInk(.yourCall))
                .help(reason)
        } else if let used = CleanupBoard.usedByMessage(item.usedBy) {
            Image(systemName: "link")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.Airy.riskInk(.doNotTouch))
                .help(used)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Why it has this label: in the risk color if it needs thought (amber or red).
            Text(why)
                .font(.callout.weight(.medium))
                .foregroundStyle(item.risk == .safe ? AnyShapeStyle(.secondary)
                                                    : AnyShapeStyle(Theme.Airy.riskInk(item.risk)))
                .lineLimit(nil)
                .frame(maxWidth: 640, alignment: .leading)

            Text(item.entry.explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 640, alignment: .leading)

            if !item.details.isEmpty {
                Text(detailsText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            metadata

            if let location {
                Text(location)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            notices
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Parts

    @ViewBuilder private var leading: some View {
        if isCurrent {
            ProgressView().controlSize(.small)
        } else if isQueued {
            Image(systemName: "clock")
                .foregroundStyle(.tertiary)
                .help("Queued")
        } else if showsCheckbox {
            CheckCircle(isOn: isSelected, enabled: canSelect)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
                .onTapGesture { if canSelect { onToggle() } }
                .help(canSelect ? (isSelected ? String(localized: "Remove from Selection") : String(localized: "Select"))
                      : CleanupBoard.blockedReasonText(item) ?? String(localized: "Can’t be cleaned right now"))
        } else {
            Image(systemName: isInfo && item.risk != .doNotTouch ? "info.circle"
                  : (protectsOnlyTheFolder ? "lock.open.fill" : "lock.fill"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tertiary)
                .help(item.protection.map(CleanupBoard.protectionText)
                      ?? (isInfo ? String(localized: "Informational only") : String(localized: "Don't delete")))
        }
    }

    private var metadata: some View {
        HStack(spacing: 8) {
            MetaChip(symbol: "person.crop.circle", text: "Created by: \(item.entry.whoCreatesIt)")
            MetaChip(symbol: item.entry.regenerates ? "arrow.triangle.2.circlepath" : "exclamationmark.arrow.circlepath",
                     text: item.entry.regenerates ? "Regenerates" : "Doesn’t regenerate")
            MethodChip(method: liveMethod)
            if protectsOnlyTheFolder {
                ProtectedFolderBadge(reason: why)
            }
        }
    }

    /// Protected only as a whole (a parent of something protected): not the red "Don't delete" (display only).
    private var protectsOnlyTheFolder: Bool { item.protection?.scope == .folderOnly }

    @ViewBuilder private var notices: some View {
        if isCurrent {
            Text("Cleaning…").font(.caption.weight(.medium)).foregroundStyle(.secondary)
        } else if isQueued {
            Text("Queued").font(.caption.weight(.medium)).foregroundStyle(.tertiary)
        }
        let blocked = item.risk == .doNotTouch ? [] : blockedApps
        if !blocked.isEmpty {
            let names = blocked.map(CleanupFlow.appName)
            HStack(spacing: 10) {
                Image(systemName: "lock.app.dashed")
                    .foregroundStyle(Theme.Airy.riskInk(.yourCall))
                Text(CleanupBoard.blockedMessage(appNames: names) ?? "")
                    .font(.callout.weight(.medium))
                Spacer(minLength: 8)
                ForEach(blocked, id: \.self) { bundleID in
                    let closing = flow.closingApps.contains(bundleID)
                    PrimaryButton(closing ? "Quitting…" : "Quit \(CleanupFlow.appName(bundleID))",
                                  systemImage: "xmark.circle", style: .secondary, isBusy: closing) {
                        flow.closeApp(bundleID, model: model)
                    }
                    .fixedSize()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.Airy.riskFill(.yourCall).opacity(0.10),
                        in: RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous))
            ForEach(blocked, id: \.self) { bundleID in
                if let refusal = flow.appRefusals[bundleID] {
                    Label(refusal, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.Airy.riskInk(.yourCall))
                }
            }
        }
        if let protection = item.protection {
            Label(CleanupBoard.protectionText(protection), systemImage: protectsOnlyTheFolder ? "lock.open.fill" : "lock.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if protectsOnlyTheFolder {
                Text(CleanupBoard.protectionScopeText(protection))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.Airy.accent)
                    .lineLimit(2)
            }
        }
        if let reason = CleanupBoard.blockedReasonText(item) {
            Label(reason, systemImage: "hand.raised.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(Theme.Airy.riskInk(.yourCall))
                .lineLimit(3)
        }
        if let used = CleanupBoard.usedByMessage(item.usedBy) {
            Label(used, systemImage: "link")
                .font(.callout.weight(.medium))
                .foregroundStyle(Theme.Airy.riskInk(.doNotTouch))
                .lineLimit(2)
                .truncationMode(.middle)
        }
        if isInfo {
            Label("Informational only: Airy doesn’t delete it.", systemImage: "eye")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    private var blockedApps: [String] {
        #if DEBUG
        if let fake = flow.debugBlocked[item.id] { return fake }
        #endif
        return item.blockedByOpenApps
    }

    private var why: String { RiskExplanation.why(item) }

    /// The first three details and "and N more".
    private var detailsText: String {
        let shown = item.details.prefix(3).joined(separator: ", ")
        let rest = item.details.count - 3
        return rest > 0 ? String(localized: "\(shown) and \(rest) more") : shown
    }

    /// Where it is (same text as the confirmation).
    private var location: String? { CleanupBoard.locationSummary(item) }
}

// MARK: - Pieces

/// The chevron at the end of a row or a group header: it points down when open.
struct DisclosureChevron: View {
    let isExpanded: Bool
    var size: CGFloat = 11

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(.tertiary)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .frame(width: 16, height: 16)
            .accessibilityHidden(true)
    }
}

/// Round checkbox with the checkmark and a small spring when checked.
private struct CheckCircle: View {
    let isOn: Bool
    let enabled: Bool

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(.secondary.opacity(enabled ? 0.6 : 0.25), lineWidth: 1.5)
                .opacity(isOn ? 0 : 1)
            Circle()
                .fill(Theme.brand)
                .opacity(isOn ? 1 : 0)
                .scaleEffect(isOn ? 1 : 0.6)
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(.white)
                .opacity(isOn ? 1 : 0)
                .scaleEffect(isOn ? 1 : 0.4)
        }
        .frame(width: 20, height: 20)
        .opacity(enabled || isOn ? 1 : 0.5)
        .animation(Theme.pressSpring, value: isOn)
        .contentShape(Circle())
    }
}

/// Icon per kind: a tile in the palette color and an SF Symbol for the item.
struct CleanupIcon: View {
    let entry: CatalogEntry
    var dimmed = false
    var size: CGFloat = 36
    @Environment(\.airyQuietShadows) private var quietShadows

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(Theme.gradient(for: entry.kind))
                .saturation(dimmed ? 0.35 : 1)
            Image(systemName: Self.symbol(for: entry))
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundStyle(glyphInk)
        }
        .frame(width: size, height: size)
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 0.75)
        }
        .shadow(color: Theme.color(for: entry.kind).opacity(dimmed || quietShadows ? 0 : 0.28),
                radius: quietShadows ? 0 : 6, y: quietShadows ? 0 : 3)
    }

    /// Glyph with AA contrast on both ends of the kind's gradient, as on the map.
    private var glyphInk: Color {
        let base = AiryPalette.kind(entry.kind)
        return Color(hex: AiryPalette.inkForFill([ColorMath.mix(base, 0xffffff, 0.18), base]))
    }

    static func symbol(for entry: CatalogEntry) -> String {
        let id = entry.id
        if id.hasPrefix("docker-volumes") { return "cylinder.split.1x2" }
        if id.hasPrefix("docker") { return "shippingbox.fill" }
        if id == "homebrew" { return "mug.fill" }
        if ["pip", "uv", "conda"].contains(id) { return "puzzlepiece.extension.fill" }
        if ["npm", "pnpm"].contains(id) { return "cube.fill" }
        if id == "cargo" { return "gearshape.2.fill" }
        if id.hasPrefix("huggingface") || id.hasPrefix("ollama") { return "brain" }
        if id.hasPrefix("whisper") { return "waveform" }
        if id == "playwright" { return "theatermasks.fill" }
        if id.hasSuffix("-cache"), ["brave", "chrome", "safari"].contains(where: id.hasPrefix) { return "globe" }
        if id.hasPrefix("spotify") { return "music.note" }
        if id == "xcode-deriveddata" { return "hammer.fill" }
        if id == "xcode-simulators" { return "iphone" }
        if id == "user-logs" { return "doc.text.magnifyingglass" }
        if id.hasPrefix("codex") { return "terminal.fill" }
        if id == "claude-vm" { return "desktopcomputer" }
        if id == "time-machine-snapshots" { return "clock.arrow.circlepath" }
        return Theme.symbol(for: entry.kind)
    }
}

private struct MetaChip: View {
    let symbol: String
    let text: LocalizedStringKey

    var body: some View {
        Label {
            Text(text).lineLimit(1)
        } icon: {
            Image(systemName: symbol).imageScale(.small)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.primary.opacity(0.05), in: Capsule())
    }
}

/// "To the Trash" or "Official command" (the full command in the tooltip and the confirmation).
private struct MethodChip: View {
    let method: CleanupMethod

    var body: some View {
        switch method {
        case .trash:
            MetaChip(symbol: "trash", text: "To the Trash")
        case .command:
            MetaChip(symbol: "terminal", text: "Official command")
                .help(CleanupBoard.methodDescription(method))
        case .info:
            EmptyView()
        }
    }
}
