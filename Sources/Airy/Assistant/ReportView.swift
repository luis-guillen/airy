import SwiftUI
import DiskMapCore

/// Report: "Analyze with AI", a loading shine over skeleton cards and, when it arrives, the summary
/// with "Reclaimable" (computed in code, not the AI's text) and the three risk columns.
struct ReportView: View {
    @Environment(AppModel.self) private var model
    @Environment(CleanupFlow.self) private var flow: CleanupFlow?

    private var session: AssistantSession { model.assistant }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                headerCard
                    .animation(Theme.sectionSpring, value: phaseKey)

                switch session.report {
                case .idle:
                    EmptyColumnsHint()
                case .loading:
                    SkeletonColumns()
                        .transition(.opacity)
                case .loaded(_, let columns):
                    columnsView(columns)
                        .id(session.reportDate)
                case .failed(let message):
                    ReportErrorCard(message: message) { session.runReport(model: model) }
                        .transition(.opacity.combined(with: .offset(y: 8)))
                }
            }
            .padding(.bottom, 12)
        }
        .scrollIndicators(.automatic)
        .animation(Theme.sectionSpring, value: phaseKey)
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .airyAssistantDebug)) { note in
            debugAction(note.userInfo?["action"] as? String ?? "", note.userInfo?["argument"] as? String ?? "")
        }
        #endif
    }

    private var phaseKey: Int {
        switch session.report {
        case .idle: 0
        case .loading: 1
        case .loaded: 2
        case .failed: 3
        }
    }

    // MARK: Header

    @ViewBuilder private var headerCard: some View {
        GlassCard(padding: 22) {
            switch session.report {
            case .loaded(let report, _):
                summary(report)
            default:
                intro
            }
        }
    }

    private var intro: some View {
        HStack(alignment: .center, spacing: 18) {
            AssistantGlyph(symbol: session.isReportLoading ? "sparkle.magnifyingglass" : "sparkles", size: 50)
                .symbolEffect(.pulse, isActive: session.isReportLoading)
            VStack(alignment: .leading, spacing: 5) {
                Text(session.isReportLoading ? "Claude is reviewing your disk…" : "Your Disk Report")
                    .font(.title3.weight(.semibold))
                    .contentTransition(.opacity)
                Text("Sorts what takes up space into “Safe to remove”, “Your call” and “Don't delete”, with the reason for each. Everything it proposes is checked against Airy’s catalog first.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 7) {
                PrimaryButton(session.isReportLoading ? "Analyzing…" : "Analyze with AI", systemImage: "sparkles",
                              isBusy: session.isReportLoading) {
                    session.runReport(model: model)
                }
                .fixedSize()
                CostNote()
            }
        }
    }

    private func summary(_ report: AIReport) -> some View {
        HStack(alignment: .top, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    AssistantGlyph(size: 26)
                    Text("Claude’s Opinion")
                        .font(.headline)
                    if let date = session.reportDate {
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            Text("· \(Theme.relative(date, now: context.date))")
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                Text(report.summary)
                    .font(.body)
                    .foregroundStyle(.primary.opacity(0.85))
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider().frame(height: 96)

            VStack(alignment: .trailing, spacing: 6) {
                Text("Reclaimable")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                BytesCounter(bytes: report.reclaimableBytes,
                             font: .system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.Airy.riskInk(.safe))
                    .help("The sum of items marked “Safe to remove” that have an action, without counting a folder inside another twice. Airy computes it, not Claude’s text.")
                PrimaryButton("Analyze Again", systemImage: "arrow.clockwise", style: .secondary) {
                    session.runReport(model: model)
                }
                .fixedSize()
                .padding(.top, 4)
                CostNote()
            }
            .fixedSize()
        }
    }

    // MARK: Columns

    private func columnsView(_ columns: [ReportColumns.Column]) -> some View {
        // Global index of each card for the staggered entrance (12 ms per block, max 0.6 s).
        var offsets: [Int] = []
        var running = 0
        for column in columns {
            offsets.append(running)
            running += column.recommendations.count + 1
        }
        return HStack(alignment: .top, spacing: 14) {
            ForEach(Array(columns.enumerated()), id: \.element.id) { index, column in
                RiskColumn(column: column, firstIndex: offsets[index]) { rec, offer, title in
                    requestConfirmation(rec, offer: offer, title: title)
                }
            }
        }
    }

    /// Opens the app's single confirmation (`CleanupFlow` → `ConfirmSheet`) with what is really touched:
    /// the exact detected item or the individual path. "Your call" first adds "This is your call".
    private func requestConfirmation(_ rec: AIRecommendation, offer: AssistantActionOffer, title: String) {
        guard let flow else { return }
        let session = session
        let generation = session.generation
        let recID = rec.id
        let onConfirm: @MainActor () -> Void = { session.actionConfirmed(for: recID, generation: generation) }
        let onOutcome: @MainActor (CleanupOutcome) -> Void = { session.record($0, for: recID, generation: generation) }
        switch offer.action {
        case .perform(let item):
            flow.requestClean([item], onConfirm: onConfirm, onOutcome: onOutcome)
        case .trashPaths(let paths):
            let warning = offer.needsSecondConfirmation
                ? CleanupFlow.ConfirmRequest.Warning(
                    title: String(localized: "This is your call"),
                    subtitle: String(localized: "It isn’t safe to delete without looking."),
                    reason: rec.reason,
                    note: String(localized: "Check \(title) before continuing. If you move it to the Trash, you can recover it as long as you don’t empty it."))
                : nil
            flow.requestTrash(paths: paths, title: title, warning: warning, onConfirm: onConfirm, onOutcome: onOutcome)
        }
    }

    #if DEBUG
    private func debugAction(_ action: String, _ argument: String) {
        switch action {
        case "confirm":
            guard case .loaded(_, let columns) = session.report,
                  let column = columns.first(where: { $0.risk.rawValue == Int(argument) ?? 0 }) else { return }
            for rec in column.recommendations {
                if case .offer(let offer) = session.offer(for: rec, model: model) {
                    requestConfirmation(rec, offer: offer, title: ReportText.title(rec, model: model))
                    return
                }
            }
        // "second" and "cancel" are handled by ConfirmSheet itself.
        default: break
        }
    }
    #endif
}

// MARK: - Texts

@MainActor
enum ReportText {
    /// Short name: the catalog entry for items without a path, otherwise the last component.
    static func title(_ rec: AIRecommendation, model: AppModel) -> String {
        if !rec.path.hasPrefix("/") {
            return model.cleanupItems.first { $0.id == rec.path }?.title
                ?? model.catalog?.entry(id: rec.path)?.title ?? rec.path
        }
        let name = (rec.path as NSString).lastPathComponent
        return name.isEmpty ? rec.path : name
    }

    static func subtitle(_ rec: AIRecommendation, model: AppModel) -> String {
        guard rec.path.hasPrefix("/") else { return String(localized: "Catalog cleanup") }
        return Format.tildePath(rec.path)
    }
}

// MARK: - Column

private struct RiskColumn: View {
    @Environment(AppModel.self) private var model
    let column: ReportColumns.Column
    let firstIndex: Int
    var onAction: (AIRecommendation, AssistantActionOffer, String) -> Void

    @ViewState private var appeared = false

    var body: some View {
        let tint = Theme.color(for: column.risk)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: Theme.symbol(for: column.risk))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.Airy.night)
                    .frame(width: 24, height: 24)
                    .background(tint.gradient, in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(column.risk.title)
                        .font(.headline)
                    Text(columnDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 10)
            .onAppear { withAnimation(Theme.stagger(index: firstIndex)) { appeared = true } }

            if column.recommendations.isEmpty {
                Text(emptyText)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 26)
                    .background {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(.primary.opacity(0.10), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    }
                    .opacity(appeared ? 1 : 0)
            }

            ForEach(Array(column.recommendations.enumerated()), id: \.element.id) { index, rec in
                RecommendationCard(rec: rec, index: firstIndex + 1 + index, onAction: onAction)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var columnDetail: String {
        let count = column.recommendations.count
        guard count > 0 else { return String(localized: "Nothing") }
        return count == 1 ? String(localized: "1 item · \(Format.bytes(column.totalBytes))")
                          : String(localized: "\(Theme.count(count)) items · \(Format.bytes(column.totalBytes))")
    }

    private var emptyText: String {
        switch column.risk {
        case .safe: String(localized: "Nothing safe to delete")
        case .yourCall: String(localized: "Nothing to decide")
        case .doNotTouch: String(localized: "Nothing sensitive")
        }
    }
}

// MARK: - Recommendation card

private struct RecommendationCard: View {
    @Environment(AppModel.self) private var model
    let rec: AIRecommendation
    let index: Int
    var onAction: (AIRecommendation, AssistantActionOffer, String) -> Void

    @ViewState private var appeared = false
    @ViewState private var hovering = false

    private var session: AssistantSession { model.assistant }

    var body: some View {
        let tint = Theme.color(for: rec.verdict)
        let title = ReportText.title(rec, model: model)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.system(.callout, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text(Format.bytes(rec.bytes))
                    .font(.system(.callout, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.Airy.riskInk(rec.verdict))
            }
            Text(ReportText.subtitle(rec, model: model))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(rec.path)
            Text(rec.reason)
                .font(.callout)
                .foregroundStyle(.primary.opacity(0.78))
                .textSelection(.enabled)

            footer(title: title)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(hovering ? 0.14 : 0.07), radius: hovering ? 12 : 7, y: hovering ? 5 : 3)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(tint.opacity(hovering ? 0.45 : 0.22), lineWidth: 0.75)
        }
        .overlay(alignment: .leading) {
            Capsule()
                .fill(tint.gradient)
                .frame(width: 3)
                .padding(.vertical, 14)
                .offset(x: 1)
        }
        .onHover { hovering = $0 }
        .animation(Theme.pressSpring, value: hovering)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 12)
        .scaleEffect(appeared ? 1 : 0.98, anchor: .top)
        .onAppear { withAnimation(Theme.stagger(index: index)) { appeared = true } }
    }

    @ViewBuilder private func footer(title: String) -> some View {
        let offer = session.offer(for: rec, model: model)
        let routable = rec.path.hasPrefix("/") && model.node(atPath: rec.path) != nil
        if let outcome = session.outcomes[rec.id] {
            OutcomeLine(outcome: outcome)
        }
        let done = session.outcomes[rec.id].map(isFinished) ?? false
        if !done || routable {
            HStack(spacing: 8) {
                if !done {
                    switch offer {
                    case .offer(let actionOffer):
                        actionButton(actionOffer, title: title)
                    case .unavailable(let reason):
                        Label(model.isRefreshingCleanup ? String(localized: "Checking in Cleanup…") : reason,
                              systemImage: model.isRefreshingCleanup ? "hourglass" : "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    case .none:
                        EmptyView()
                    }
                }
                Spacer(minLength: 0)
                if routable {
                    // With a button next to it, only the icon (the text doesn't fit in narrow columns).
                    let compact: Bool = {
                        if done { return false }
                        if case .none = offer { return false }
                        return true
                    }()
                    Button {
                        model.showInMap(path: rec.path)
                    } label: {
                        if compact {
                            Image(systemName: "square.grid.3x3.square")
                                .font(.system(size: 14, weight: .medium))
                                .frame(width: 28, height: 28)
                                .background(Theme.userFilesColor.opacity(0.10), in: Circle())
                        } else {
                            Label("Show on Map", systemImage: "square.grid.3x3.square")
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.userFilesColor)
                    .fixedSize()
                    .help("Show on Map")
                }
            }
            .padding(.top, 2)
        }
    }

    @ViewBuilder private func actionButton(_ offer: AssistantActionOffer, title: String) -> some View {
        let busy = session.busyRecommendation == rec.id
        if offer.needsSecondConfirmation {
            PrimaryButton("Move to Trash…", systemImage: "trash", style: .secondary, isBusy: busy) {
                onAction(rec, offer, title)
            }
            .fixedSize()
            .controlSize(.small)
        } else {
            PrimaryButton(offer.isCommand ? "Clean" : "To the Trash",
                          systemImage: offer.isCommand ? "wand.and.sparkles" : "trash", isBusy: busy) {
                onAction(rec, offer, title)
            }
            .fixedSize()
            .controlSize(.small)
            .help(offer.method)
        }
    }

    private func isFinished(_ outcome: CleanupOutcome) -> Bool {
        switch outcome {
        case .freed, .movedToTrash: true
        case .blocked, .failed: false
        }
    }
}

/// Result of an action inside its card.
private struct OutcomeLine: View {
    let outcome: CleanupOutcome

    var body: some View {
        let (symbol, tint, text) = parts
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .font(.caption.weight(.medium))
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }

    private var parts: (String, Color, String) {
        switch outcome {
        case .movedToTrash(let bytes):
            ("trash.fill", Theme.Airy.riskInk(.safe), String(localized: "In the Trash (\(Format.bytes(bytes))). The space is freed when you empty it."))
        case .freed(let bytes):
            ("checkmark.circle.fill", Theme.Airy.riskInk(.safe), String(localized: "Freed \(Format.bytes(bytes))."))
        case .blocked(let reason):
            ("hand.raised.fill", Theme.Airy.riskInk(.yourCall), String(localized: "Not done: \(reason)"))
        case .failed(let reason):
            ("exclamationmark.triangle.fill", Theme.Airy.riskInk(.doNotTouch), reason)
        }
    }
}

// MARK: - Loading

/// Three columns of skeleton cards swept by a shine.
private struct SkeletonColumns: View {
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(0..<3, id: \.self) { column in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Circle().frame(width: 24, height: 24)
                        VStack(alignment: .leading, spacing: 5) {
                            Capsule().frame(width: 110, height: 10)
                            Capsule().frame(width: 70, height: 7)
                        }
                    }
                    .padding(.horizontal, 4)
                    ForEach(0..<(3 - column / 2), id: \.self) { row in
                        SkeletonCard(lines: 2 + (row + column) % 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .foregroundStyle(.primary.opacity(0.07))
        .shimmering()
    }
}

private struct SkeletonCard: View {
    let lines: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Capsule().frame(width: 96, height: 11)
                Spacer()
                Capsule().frame(width: 46, height: 11)
            }
            Capsule().frame(width: 150, height: 8)
            ForEach(0..<lines, id: \.self) { line in
                Capsule().frame(maxWidth: line == lines - 1 ? 120 : .infinity).frame(height: 8)
            }
            Capsule().frame(width: 92, height: 22).padding(.top, 4)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.primary.opacity(0.035))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.primary.opacity(0.06), lineWidth: 0.75)
        }
    }
}

/// Before the first report: the three columns it will fill, as a hint.
private struct EmptyColumnsHint: View {
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach([Risk.safe, .yourCall, .doNotTouch], id: \.self) { risk in
                let tint = Theme.Airy.riskInk(risk)
                VStack(alignment: .leading, spacing: 8) {
                    Label(risk.title, systemImage: Theme.symbol(for: risk))
                        .font(.headline)
                        .foregroundStyle(tint)
                    Text(hint(for: risk))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(tint.opacity(0.28), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                }
            }
        }
    }

    private func hint(for risk: Risk) -> String {
        switch risk {
        case .safe: String(localized: "Caches and leftovers that regenerate by themselves. Cleaned with one click.")
        case .yourCall: String(localized: "Things you may want to keep. It’s your call, with a double confirmation.")
        case .doNotTouch: String(localized: "Data you shouldn’t touch, like Docker volumes.")
        }
    }
}

private struct ReportErrorCard: View {
    let message: String
    var onRetry: () -> Void

    var body: some View {
        GlassCard {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.Airy.riskInk(.yourCall))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Couldn’t Prepare the Report")
                        .font(.headline)
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 12)
                PrimaryButton("Try Again", systemImage: "arrow.clockwise") { onRetry() }
                    .fixedSize()
            }
        }
    }
}
