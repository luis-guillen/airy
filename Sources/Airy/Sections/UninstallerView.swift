import AppKit
import SwiftUI
import DiskMapCore

/// Uninstaller section: apps with their real size, orphaned leftovers and broken links. Everything that deletes
/// goes through `CleanupFlow` (confirmation sheet) → `AppModel` → `CleanupExecutor`.
struct UninstallerView: View {
    @Environment(AppModel.self) private var model
    @Environment(CleanupFlow.self) private var flow
    /// Lives in `AppModel.sections`: the selection and results survive section changes.
    private var store: UninstallerStore { model.sections.uninstaller }

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: Theme.spacing) {
            SectionHeader(title: Section.uninstaller.title,
                          subtitle: String(localized: "Removes apps along with their leftovers. Everything goes to the Trash unless noted.")) {
                HStack(spacing: 10) {
                    if store.isLoading { ProgressView().controlSize(.small) }
                    Button("Refresh", systemImage: "arrow.clockwise") { store.refresh(model: model) }
                        .disabled(flow.isBusy)
                }
            }
            Picker("", selection: $store.tab) {
                ForEach(UninstallerStore.Tab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 420)

            if let result = flow.uninstallResult {
                UninstallerResultBanner(summary: result.summary)
            }

            switch store.tab {
            case .apps:
                if let path = store.openedApp, let plan = store.plans[path], !flow.uninstalledPaths.contains(path) {
                    UninstallDetail(store: store, plan: plan)
                        .transition(.opacity.combined(with: .offset(x: 12)))
                } else {
                    appList
                }
            case .orphans:
                OrphansView(store: store)
            case .links:
                BrokenLinksView(store: store)
            }
        }
        .padding(Theme.contentPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(Theme.sectionSpring, value: store.openedApp)
        .onAppear { store.appear(model: model) }
        .onDisappear { store.cancel() }
    }

    // MARK: Apps

    private var appList: some View {
        @Bindable var store = store
        let apps = store.visibleApps(hiding: flow.uninstalledPaths)
        let checked = store.checkedRequests(hiding: flow.uninstalledPaths)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                TextField("Search Apps", text: $store.searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Picker("Sort By", selection: $store.sort) {
                    ForEach(UninstallerStore.Sort.allCases) { Text($0.title).tag($0) }
                }
                .fixedSize()
                Spacer()
            }
            if store.inventory == nil {
                ProgressView("Looking for apps…").frame(maxWidth: .infinity, minHeight: 160)
            } else if apps.isEmpty {
                Text(store.searchText.isEmpty ? "There are no apps to uninstall." : "No apps match.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    GlassCard(padding: 0) {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                                VStack(spacing: 0) {
                                    if index > 0 { Divider().opacity(0.5).padding(.leading, 60) }
                                    AppRow(store: store, app: app, plan: store.plans[app.path],
                                           isRunning: flow.currentID == app.path)
                                }
                                .gustSway(index: flow.gust(for: .uninstall)?.order.firstIndex(of: app.path), start: flow.gust(for: .uninstall)?.start)
                                .transition(.leafAway)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                    }
                    .padding(.bottom, 70)
                }
                .overlay {
                    if let gust = flow.gust(for: .uninstall) { GustSweep(start: gust.start).id(gust.id) }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if !checked.isEmpty {
                let total = checked.reduce(Int64(0)) { $0 + $1.plan.bytes(selected: $1.selected) }
                PrimaryButton(checked.count == 1 ? "Uninstall · \(Format.bytes(total))"
                                                 : "Uninstall \(Theme.count(checked.count)) Apps · \(Format.bytes(total))",
                              systemImage: "trash") {
                    flow.requestUninstall(checked)
                }
                .fixedSize()
                .disabled(flow.isBusy)
                .padding(.bottom, 18)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Theme.zoomSpring, value: flow.uninstalledPaths)
    }
}

// MARK: - App row

private struct AppRow: View {
    let store: UninstallerStore
    let app: AppRecord
    let plan: UninstallPlan?
    let isRunning: Bool

    var body: some View {
        let refusal = plan.flatMap { store.refusal(for: $0) }
        HStack(spacing: 12) {
            Group {
                if let plan, refusal == nil {
                    Toggle("", isOn: Binding(
                        get: { store.checkedApps.contains(app.path) },
                        set: { on in if on { store.checkedApps.insert(app.path) } else { store.checkedApps.remove(app.path) } }))
                        .toggleStyle(.airyCheckbox)
                        .labelsHidden()
                        .accessibilityLabel("Select \(plan.app.name)")
                } else {
                    Color.clear
                }
            }
            .frame(width: 18)
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                .resizable()
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(app.name).font(.callout.weight(.semibold)).lineLimit(1)
                    if let version = app.version { Text(version).font(.caption).foregroundStyle(.secondary) }
                    if store.runningIDs.contains(app.bundleID) { UninstallerBadge("Open") }
                    if app.caskToken != nil { UninstallerBadge("Homebrew") }
                    if app.isAppStore { UninstallerBadge("App Store") }
                }
                Text(usageText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if isRunning { ProgressView().controlSize(.small) }
            sizeText
            if plan != nil {
                RiskBadge(risk: refusal == nil ? .yourCall : .doNotTouch, reason: refusal)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture { if plan != nil { store.openedApp = app.path } }
        .help(plan == nil ? "Measuring…" : "See Its Leftovers")
    }

    private var usageText: String {
        guard let date = app.lastUsed else { return String(localized: "No usage data") }
        let rel = Format.relativeDate(date)
        return String(localized: "Not opened since \(rel)")
    }

    @ViewBuilder
    private var sizeText: some View {
        if let plan {
            Text(Format.bytes(plan.realBytes) + (plan.sizeComplete ? "" : "+"))
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .help(plan.sizeComplete ? "App + leftovers" : "Measuring didn’t finish: it’s at least this much")
        } else {
            Text("Measuring…").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct UninstallerBadge: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }
    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.primary.opacity(0.08), in: Capsule())
            .foregroundStyle(.secondary)
    }
}

/// Summary of the Uninstaller's last batch.
struct UninstallerResultBanner: View {
    let summary: CleanupRunSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let headline = summary.headline {
                Label(headline, systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Theme.Airy.riskInk(.safe))
            }
            ForEach(summary.problems) { problem in
                Label("\(problem.title): \(problem.message)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.Airy.riskInk(.yourCall))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
