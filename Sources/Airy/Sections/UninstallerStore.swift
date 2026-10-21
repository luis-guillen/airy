import AppKit
import Foundation
import Observation
import DiskMapCore

/// Estado del Desinstalador: inventario, planes (uno a uno, poco a poco), restos huérfanos y enlaces rotos.
/// Solo calcula al primer aparecer y con «Actualizar»; nunca en segundo plano.
@MainActor @Observable
final class UninstallerStore {
    enum Tab: String, CaseIterable, Identifiable {
        case apps, orphans, links
        var id: String { rawValue }
        var title: String {
            switch self {
            case .apps: "Apps"
            case .orphans: "Restos huérfanos"
            case .links: "Enlaces rotos"
            }
        }
    }

    enum Sort: String, CaseIterable, Identifiable {
        case realSize, name, lastUsed
        var id: String { rawValue }
        var title: String {
            switch self {
            case .realSize: "Tamaño real"
            case .name: "Nombre"
            case .lastUsed: "Último uso"
            }
        }
    }

    var tab: Tab = .apps
    var sort: Sort = .realSize
    var searchText = ""
    var inventory: AppInventorySnapshot?
    /// Por `app.path`; se rellenan poco a poco.
    var plans: [String: UninstallPlan] = [:]
    var checkedApps: Set<String> = []
    /// Por `app.path`; por defecto `plan.defaultSelection`.
    var leftoverSelection: [String: Set<String>] = [:]
    var orphans: OrphanScan?
    var orphanSelection: Set<String> = []
    var links: [BrokenLink] = []
    var linksLoaded = false
    var linkSelection: Set<String> = []
    /// App abierta en el detalle.
    var openedApp: String?
    /// Bundle ids abiertos al refrescar (insignia «Abierta»).
    private(set) var runningIDs: Set<String> = []
    private(set) var isLoading = false
    private var tasks: [Task<Void, Never>] = []
    private var generation = 0

    func refresh(model: AppModel) {
        cancel()
        generation += 1
        let generation = generation
        isLoading = true
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
        tasks.append(Task { [weak self] in
            let links = await model.brokenLinks()
            guard let self, !Task.isCancelled, generation == self.generation else { return }
            self.links = links
            self.linksLoaded = true
        })
        tasks.append(Task { [weak self] in
            let inventory = await model.inventorySnapshot()
            guard let self, !Task.isCancelled, generation == self.generation else { return }
            self.inventory = inventory
            // Restos huérfanos y planes: primero lo visible (apps), luego huérfanos.
            for app in self.sorted(inventory.apps) where !app.isSystem {
                if Task.isCancelled || generation != self.generation { return }
                let plan = await model.uninstallPlan(for: app, inventory: inventory)
                guard !Task.isCancelled, generation == self.generation else { return }
                self.plans[app.path] = plan
                if self.leftoverSelection[app.path] == nil { self.leftoverSelection[app.path] = plan.defaultSelection }
            }
            let scan = await model.orphanScan(inventory: inventory)
            guard !Task.isCancelled, generation == self.generation else { return }
            self.orphans = scan
            self.isLoading = false
        })
    }

    /// Al salir de la sección: nada sigue calculando.
    func cancel() {
        for task in tasks { task.cancel() }
        tasks = []
        isLoading = false
    }

    // MARK: Lista

    /// Apps de la lista (sin las del sistema, que nunca se desinstalan), filtradas y ordenadas.
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
            // Las que llevan más tiempo sin abrirse primero; sin datos al final.
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

    /// Apps marcadas con plan y sin rechazo.
    func checkedRequests(hiding gone: Set<String>) -> [UninstallRequest] {
        checkedApps.subtracting(gone).sorted().compactMap { path in
            guard let plan = plans[path], plan.refusal == nil, !Self.isLinked(plan.app) else { return nil }
            return request(for: plan)
        }
    }

    /// Igual que el ejecutor: `--zap` solo si el usuario dejó elegidos todos los restos y ninguno es rojo.
    static func zapExpected(_ request: UninstallRequest) -> Bool {
        request.plan.leftovers.filter { $0.kind != .receipt }.allSatisfy { $0.canSelect && request.selected.contains($0.id) }
    }

    /// Un `.app` que es un enlace: Airy no lo desinstala (no toca el original ni sabe si es el mismo).
    static func isLinked(_ app: AppRecord) -> Bool {
        var info = stat()
        return lstat(app.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
    }

    static let linkedRefusal =
        "Es un enlace a una app que está en otro sitio: Airy no la desinstala para no tocar el original. Bórrala a mano si quieres."

    /// Motivo para no ofrecer desinstalarla, o `nil`.
    func refusal(for plan: UninstallPlan) -> String? {
        if Self.isLinked(plan.app) { return Self.linkedRefusal }
        return plan.refusal
    }

    // MARK: Huérfanos

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
