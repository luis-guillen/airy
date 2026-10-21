import AppKit
import Foundation
import Observation
import DiskMapCore

/// Uninstaller state: inventory, plans (one by one, little by little), orphaned leftovers and broken links.
/// It lives in `SectionStores`. It only computes on first appearance, with "Refresh" or if what was computed is
/// more than 10 min old; if you left halfway, it finishes what is missing when you return. Never in the background.
@MainActor @Observable
final class UninstallerStore {
    enum Tab: String, CaseIterable, Identifiable {
        case apps, orphans, links
        var id: String { rawValue }
        var title: String {
            switch self {
            case .apps: String(localized: "Apps")
            case .orphans: String(localized: "Orphaned Leftovers")
            case .links: String(localized: "Broken Links")
            }
        }
    }

    enum Sort: String, CaseIterable, Identifiable {
        case realSize, name, lastUsed
        var id: String { rawValue }
        var title: String {
            switch self {
            case .realSize: String(localized: "Real Size")
            case .name: String(localized: "Name")
            case .lastUsed: String(localized: "Last Used")
            }
        }
    }

    var tab: Tab = .apps
    var sort: Sort = .realSize
    var searchText = ""
    var inventory: AppInventorySnapshot?
    /// By `app.path`; filled in little by little.
    var plans: [String: UninstallPlan] = [:]
    var checkedApps: Set<String> = []
    /// By `app.path`; `plan.defaultSelection` by default.
    var leftoverSelection: [String: Set<String>] = [:]
    var orphans: OrphanScan?
    var orphanSelection: Set<String> = []
    var links: [BrokenLink] = []
    var linksLoaded = false
    var linkSelection: Set<String> = []
    /// App open in the detail view.
    var openedApp: String?
    /// Bundle ids open at refresh time ("Open" badge).
    private(set) var runningIDs: Set<String> = []
    private(set) var isLoading = false
    private var tasks: [Task<Void, Never>] = []
    private var generation = 0

    /// When the last "Refresh" (or the first computation) started.
    private(set) var loadedAt: Date?
    /// Inventory, plans, orphans and links finished (it wasn't cut off by leaving the section).
    private var complete = false
    /// After this time, everything is recomputed when returning to the section.
    static let staleAfter: TimeInterval = 600

    /// When the section appears: it lives in `SectionStores`, so the selection and results are kept.
    /// It only recomputes if there is nothing, if it is older than `staleAfter`, or finishes what was left halfway.
    func appear(model: AppModel, now: Date = Date()) {
        runningIDs = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        guard let loadedAt, now.timeIntervalSince(loadedAt) < Self.staleAfter else {
            refresh(model: model)
            return
        }
        if !complete { load(model: model) }
    }

    /// "Refresh": starts from scratch.
    func refresh(model: AppModel) {
        cancel()
        loadedAt = Date()
        complete = false
        inventory = nil
        plans = [:]
        checkedApps = []
        leftoverSelection = [:]
        orphans = nil
        orphanSelection = []
        linksLoaded = false
        links = []
        linkSelection = []
        runningIDs = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        load(model: model)
    }

    /// Computes only what is missing (inventory, plans, orphans, links), without touching the selection.
    private func load(model: AppModel) {
        cancel()
        generation += 1
        let generation = generation
        isLoading = true
        if !linksLoaded {
            tasks.append(Task { [weak self] in
                let links = await model.brokenLinks()
                guard let self, !Task.isCancelled, generation == self.generation else { return }
                self.links = links
                self.linksLoaded = true
            })
        }
        tasks.append(Task { [weak self] in
            guard let self else { return }
            let inventory: AppInventorySnapshot
            if let known = self.inventory {
                inventory = known
            } else {
                inventory = await model.inventorySnapshot()
                guard !Task.isCancelled, generation == self.generation else { return }
                self.inventory = inventory
            }
            // Orphaned leftovers and plans: the visible part first (apps), then orphans.
            for app in self.sorted(inventory.apps) where !app.isSystem && self.plans[app.path] == nil {
                if Task.isCancelled || generation != self.generation { return }
                let plan = await model.uninstallPlan(for: app, inventory: inventory)
                guard !Task.isCancelled, generation == self.generation else { return }
                self.plans[app.path] = plan
                if self.leftoverSelection[app.path] == nil { self.leftoverSelection[app.path] = plan.defaultSelection }
            }
            if self.orphans == nil {
                let scan = await model.orphanScan(inventory: inventory)
                guard !Task.isCancelled, generation == self.generation else { return }
                self.orphans = scan
            }
            self.complete = true
            self.isLoading = false
        })
    }

    /// On leaving the section: nothing keeps computing.
    func cancel() {
        for task in tasks { task.cancel() }
        tasks = []
        isLoading = false
    }

    // MARK: List

    /// Apps in the list (without system ones, which are never uninstalled), filtered and sorted.
    func visibleApps(hiding gone: Set<String>) -> [AppRecord] {
        let apps = (inventory?.apps ?? []).filter { !$0.isSystem && !gone.contains($0.path) }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let filtered = query.isEmpty ? apps : apps.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.bundleID.localizedCaseInsensitiveContains(query)
        }
        return sorted(filtered)
    }

    private func sorted(_ apps: [AppRecord]) -> [AppRecord] {
        switch sort {
        case .name:
            return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .realSize:
            return apps.sorted { (plans[$0.path]?.realBytes ?? -1) > (plans[$1.path]?.realBytes ?? -1) }
        case .lastUsed:
            // The ones unopened the longest first; those without data last.
            return apps.sorted { ($0.lastUsed ?? .distantFuture) < ($1.lastUsed ?? .distantFuture) }
        }
    }

    func selection(for plan: UninstallPlan) -> Set<String> {
        leftoverSelection[plan.id] ?? plan.defaultSelection
    }

    func toggle(_ leftover: Leftover, in plan: UninstallPlan) {
        guard leftover.canSelect else { return }
        var set = selection(for: plan)
        set.formSymmetricDifference([leftover.id])
        leftoverSelection[plan.id] = set
    }

    func request(for plan: UninstallPlan) -> UninstallRequest {
        UninstallRequest(plan: plan, selected: selection(for: plan).filter { id in
            plan.leftovers.contains { $0.id == id && $0.canSelect }
        })
    }

    /// Checked apps with a plan and no refusal.
    func checkedRequests(hiding gone: Set<String>) -> [UninstallRequest] {
        checkedApps.subtracting(gone).sorted().compactMap { path in
            guard let plan = plans[path], plan.refusal == nil, !Self.isLinked(plan.app) else { return nil }
            return request(for: plan)
        }
    }

    /// An `.app` that is a link: Airy doesn't uninstall it (it won't touch the original or know if it is the same).
    static func isLinked(_ app: AppRecord) -> Bool {
        var info = stat()
        return lstat(app.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
    }

    static let linkedRefusal =
        String(localized: "It’s a link to an app stored somewhere else: Airy doesn’t uninstall it so the original isn’t touched. Delete it by hand if you want.")

    /// Reason not to offer uninstalling it, or `nil`.
    func refusal(for plan: UninstallPlan) -> String? {
        if Self.isLinked(plan.app) { return Self.linkedRefusal }
        return plan.refusal
    }

    // MARK: Orphans

    var orphanGroups: [OrphanGroup] {
        if case .found(let groups) = orphans { return groups }
        return []
    }

    func removeOrphans(_ ids: Set<String>) {
        orphans = .found(orphanGroups.filter { !ids.contains($0.id) })
        orphanSelection.subtract(ids)
    }

    var selectedOrphans: [OrphanGroup] { orphanGroups.filter { orphanSelection.contains($0.id) } }
    var selectedLinks: [BrokenLink] { links.filter { linkSelection.contains($0.id) } }
}
