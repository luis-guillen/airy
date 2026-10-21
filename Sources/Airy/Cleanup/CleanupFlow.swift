import AppKit
import SwiftUI
import Observation
import DiskMapCore

/// Coordinates everything that deletes something from the UI: the confirmation sheet, batch
/// execution, the celebration, "Empty Trash" (also from the sidebar), the Time Machine
/// snapshots notice and "Quit <App>". It lives in `RootView` and is shared through the environment.
@MainActor @Observable
final class CleanupFlow {
    struct ConfirmRequest: Identifiable {
        enum Kind {
            case items([CleanupItem])
            /// Size read when requested, only for the sheet; it is read again on confirmation.
            /// `nil` = the Trash can't be read (Finder will empty it, on every disk).
            case emptyTrash(Int64?)
            /// Individual paths (map or assistant) that will go to the Trash via `AppModel.trash(paths:title:)`.
            case trashPaths([String], title: String)
            /// Uninstaller: apps (one by one), orphaned leftovers (Trash) and broken links (deleted).
            case uninstall([UninstallRequest])
            case orphans([OrphanGroup])
            case brokenLinks([BrokenLink])
            /// Quit apps from Performance (normal quit first) via `AppModel.quit` → `QuitExecutor`.
            case quitApps([AppGroup])
            /// Force quit what didn't respond; always a separate second confirmation.
            case forceQuitApps([AppGroup])
            /// Duplicates: per group, the copy that is kept and the ones that go to the Trash (verified first).
            case duplicates([DuplicateRemoval])
        }
        /// Optional first step (the assistant's "This is your call"): the real confirmation comes
        /// only after "Yes, Move It…".
        struct Warning {
            let title: String
            let subtitle: String
            let reason: String
            let note: String
            /// Button to go on to the confirmation (an uninstall isn't "moving it" to the Trash).
            var continueTitle = String(localized: "Yes, Move It…")
        }

        let id = UUID()
        /// One batch: its preview and its execution are logged with this same `runID`.
        let runID = UUID()
        let kind: Kind
        var warning: Warning? = nil
        /// Agent that proposed this and through what (`airy://propose`: `OperationContext.viaUnverifiedURL`, the
        /// name is only what the link says); the user's confirmation logs it as
        /// `.user(…, proposedBy:, proposedVia:)`.
        var proposedBy: String? = nil
        var proposedVia: String? = nil
        /// On confirmation (before running) and with each item's result, for whoever requested the
        /// confirmation (e.g. the assistant's card or the map toast).
        var onConfirm: (@MainActor () -> Void)? = nil
        var onOutcome: (@MainActor (CleanupOutcome) -> Void)? = nil

        /// The user confirms it; if an agent proposed it, that is logged as such.
        var context: OperationContext { .user(runID: runID, proposedBy: proposedBy, proposedVia: proposedVia) }
    }

    struct SnapshotNotice: Identifiable {
        let id = UUID()
        let emptied: Int64
        let rose: Int64
        let retained: Int64
        let snapshotCount: Int
    }

    enum Sheet: Identifiable {
        case confirm(ConfirmRequest)
        case snapshots(SnapshotNotice)

        var id: UUID {
            switch self {
            case .confirm(let request): request.id
            case .snapshots(let notice): notice.id
            }
        }
    }

    struct Celebration: Identifiable, Equatable {
        let id = UUID()
        let bytes: Int64
    }

    /// Result of the last batch, shown at the top of the Cleanup view.
    struct LastResult: Identifiable {
        let id = UUID()
        let summary: CleanupRunSummary
    }

    // MARK: State

    var sheet: Sheet?
    var celebration: Celebration?
    var lastResult: LastResult?
    /// Pending ids of the batch in progress (in order) and the one running.
    private(set) var queuedIDs: [String] = []
    private(set) var currentID: String?
    private(set) var isEmptyingTrash = false
    /// Cleaned in this batch: hidden right away, without waiting for the new detection.
    private(set) var hiddenIDs: Set<String> = []
    /// Bundle IDs being quit ("Quit Spotify") and notices for apps that refused to quit.
    private(set) var closingApps: Set<String> = []
    private(set) var appRefusals: [String: String] = [:]

    /// Gust of a batch of two rows or more: when it started and the execution order (`gustSway`).
    struct Gust: Equatable {
        /// Which list it sweeps: each view shows only its own (an uninstall doesn't shake Cleanup).
        enum Owner: Equatable { case items, uninstall }
        let id: UUID
        let start: Date
        let order: [String]
        let owner: Owner
    }
    private(set) var gust: Gust?
    /// The gust in progress if it sweeps `owner`'s list (Cleanup or Uninstaller); otherwise `nil`.
    func gust(for owner: Gust.Owner) -> Gust? { gust?.owner == owner ? gust : nil }
    /// What the `.items` batch in progress has cleared so far ("freed"/"cleared" pill).
    private(set) var batchTally = BatchMotion.Tally()
    var batchFreed: Int64 { batchTally.bytes }

    var isRunning: Bool { currentID != nil || !queuedIDs.isEmpty }
    var isBusy: Bool { isRunning || isEmptyingTrash }

    private let probes = SystemProbes()

    // MARK: Requests (they open the confirmation)

    func requestClean(_ items: [CleanupItem], warning: ConfirmRequest.Warning? = nil, proposedBy: String? = nil,
                      proposedVia: String? = nil,
                      onConfirm: (@MainActor () -> Void)? = nil,
                      onOutcome: (@MainActor (CleanupOutcome) -> Void)? = nil) {
        guard !items.isEmpty, !isBusy else { return }
        sheet = .confirm(ConfirmRequest(kind: .items(items), warning: warning, proposedBy: proposedBy,
                                        proposedVia: proposedVia, onConfirm: onConfirm, onOutcome: onOutcome))
    }

    func requestQuit(_ groups: [AppGroup], warning: ConfirmRequest.Warning? = nil, proposedBy: String? = nil,
                     proposedVia: String? = nil) {
        guard !groups.isEmpty, !isBusy else { return }
        sheet = .confirm(ConfirmRequest(kind: .quitApps(groups), warning: warning, proposedBy: proposedBy,
                                        proposedVia: proposedVia))
    }

    func requestForceQuit(_ groups: [AppGroup]) {
        guard !groups.isEmpty, !isBusy else { return }
        sheet = .confirm(ConfirmRequest(kind: .forceQuitApps(groups)))
    }

    func requestEmptyTrash(_ model: AppModel) {
        guard !isBusy else { return }
        sheet = .confirm(ConfirmRequest(kind: .emptyTrash(model.trashBytes)))
    }

    func requestTrash(paths: [String], title: String, warning: ConfirmRequest.Warning? = nil,
                      proposedBy: String? = nil, proposedVia: String? = nil,
                      onConfirm: (@MainActor () -> Void)? = nil,
                      onOutcome: (@MainActor (CleanupOutcome) -> Void)? = nil) {
        guard !paths.isEmpty, !isBusy else { return }
        sheet = .confirm(ConfirmRequest(kind: .trashPaths(paths, title: title), warning: warning,
                                        proposedBy: proposedBy, proposedVia: proposedVia,
                                        onConfirm: onConfirm, onOutcome: onOutcome))
    }

    /// Uninstall one or more apps (with an optional prior warning, e.g. an agent's proposal).
    func requestUninstall(_ requests: [UninstallRequest], warning: ConfirmRequest.Warning? = nil,
                          proposedBy: String? = nil, proposedVia: String? = nil,
                          onOutcome: (@MainActor (CleanupOutcome) -> Void)? = nil) {
        guard !requests.isEmpty, !isBusy else { return }
        sheet = .confirm(ConfirmRequest(kind: .uninstall(requests), warning: warning, proposedBy: proposedBy,
                                        proposedVia: proposedVia, onOutcome: onOutcome))
    }

    func requestTrashOrphans(_ groups: [OrphanGroup], onOutcome: (@MainActor (CleanupOutcome) -> Void)? = nil) {
        guard !groups.isEmpty, !isBusy else { return }
        sheet = .confirm(ConfirmRequest(kind: .orphans(groups), onOutcome: onOutcome))
    }

    func requestRemoveBrokenLinks(_ links: [BrokenLink], onOutcome: (@MainActor (CleanupOutcome) -> Void)? = nil) {
        guard !links.isEmpty, !isBusy else { return }
        sheet = .confirm(ConfirmRequest(kind: .brokenLinks(links), onOutcome: onOutcome))
    }

    func requestRemoveDuplicates(_ removals: [DuplicateRemoval],
                                 onOutcome: (@MainActor (CleanupOutcome) -> Void)? = nil) {
        guard !removals.isEmpty, !isBusy else { return }
        sheet = .confirm(ConfirmRequest(kind: .duplicates(removals), onOutcome: onOutcome))
    }

    func cancelSheet() { sheet = nil }

    /// The user confirmed in the sheet. The "busy" state is set right here, before launching the
    /// task, so a second click can't start another batch. `blocked`: ids of items (or individual
    /// paths) the preview found blocked: they don't run. `removed`: ids the user removed
    /// in the sheet (a click on "Remove"): they don't run either; empty ⇒ everything requested.
    func confirm(_ request: ConfirmRequest, model: AppModel, blocked: Set<String> = [],
                 excluding removed: Set<String> = []) {
        guard !isBusy else { return }
        let context = request.context
        switch request.kind {
        case .items(let all):
            let items = all.filter { !blocked.contains($0.id) && !removed.contains($0.id) }
            guard !items.isEmpty else { return }
            start(request)
            queuedIDs = items.map(\.id)
            startGust(order: BatchMotion.gustOrder(ids: queuedIDs), owner: .items)
            Task { await run(items, model: model, context: context, onOutcome: request.onOutcome) }
        case .emptyTrash:
            start(request)
            isEmptyingTrash = true
            Task { await emptyTrash(model: model, context: context) }
        case .trashPaths(let all, let title):
            let paths = all.filter { !blocked.contains($0) }
            guard !paths.isEmpty else { return }
            start(request)
            queuedIDs = [title]
            Task { await trash(paths: paths, title: title, model: model, context: context, onOutcome: request.onOutcome) }
        case .uninstall(let all):
            let requests = all.filter { !blocked.contains($0.id) }
            guard !requests.isEmpty else { return }
            start(request)
            uninstallResult = nil
            queuedIDs = requests.map(\.id)
            startGust(order: BatchMotion.gustOrder(ids: queuedIDs), owner: .uninstall)
            Task { await uninstall(requests, model: model, context: context, onOutcome: request.onOutcome) }
        case .orphans(let groups):
            start(request)
            uninstallResult = nil
            queuedIDs = groups.map(\.id)
            Task {
                await single(id: "orphans", title: String(localized: "Orphaned leftovers"), onOutcome: request.onOutcome) {
                    await model.trashOrphans(groups, context: context)
                }
            }
        case .brokenLinks(let links):
            start(request)
            uninstallResult = nil
            queuedIDs = links.map(\.id)
            Task {
                await single(id: "links", title: String(localized: "Broken links"), onOutcome: request.onOutcome) {
                    await model.removeBrokenLinks(links, context: context)
                }
            }
        case .quitApps(let groups), .forceQuitApps(let groups):
            var force = false
            if case .forceQuitApps = request.kind { force = true }
            start(request)
            queuedIDs = groups.map(\.id)
            Task { await quit(groups, force: force, model: model, context: context) }
        case .duplicates(let removals):
            start(request)
            duplicatesResult = nil
            queuedIDs = ["duplicates"]
            Task {
                currentID = "duplicates"
                let (outcome, notes) = await model.trashDuplicates(removals, context: context)
                currentID = nil
                queuedIDs = []
                var summary = CleanupRunSummary()
                summary.record(id: "duplicates", title: String(localized: "Duplicates"), outcome: outcome)
                for note in notes { summary.problems.append(.init(title: String(localized: "Not moved"), message: note)) }
                request.onOutcome?(outcome)
                withAnimation(Theme.sectionSpring) { duplicatesResult = LastResult(summary: summary) }
            }
        }
    }

    // MARK: Uninstall

    /// Result of the last Duplicates batch (with the reasons for what wasn't moved).
    private(set) var duplicatesResult: LastResult?
    /// Result of the last Uninstaller batch (apps, orphans or links).
    private(set) var uninstallResult: LastResult?
    /// Apps already uninstalled (`.app` path): their rows fly away without waiting for "Refresh".
    private(set) var uninstalledPaths: Set<String> = []

    /// One by one, in order, with per-row progress (`currentID`) and a final summary, like `CleanupBatch`.
    private func uninstall(_ requests: [UninstallRequest], model: AppModel, context: OperationContext,
                           onOutcome: (@MainActor (CleanupOutcome) -> Void)?) async {
        var summary = CleanupRunSummary()
        for request in requests {
            currentID = request.id
            queuedIDs.removeAll { $0 == request.id }
            let report = await model.uninstall(request, context: context)
            let name = request.plan.app.name
            summary.record(id: request.id, title: name, outcome: report.outcome)
            for note in report.notes { summary.problems.append(.init(title: name, message: note)) }
            switch report.outcome {
            case .freed, .movedToTrash:
                withAnimation(Theme.zoomSpring) { _ = uninstalledPaths.insert(request.id) }
            case .blocked, .failed: break
            }
            onOutcome?(report.outcome)
        }
        currentID = nil
        queuedIDs = []
        withAnimation(Theme.sectionSpring) { uninstallResult = LastResult(summary: summary) }
        if summary.freed > 0 { celebration = Celebration(bytes: summary.freed) }
    }

    private func single(id: String, title: String, onOutcome: (@MainActor (CleanupOutcome) -> Void)?,
                        _ action: () async -> CleanupOutcome) async {
        currentID = id
        let outcome = await action()
        currentID = nil
        queuedIDs = []
        onOutcome?(outcome)
        var summary = CleanupRunSummary()
        summary.record(id: id, title: title, outcome: outcome)
        withAnimation(Theme.sectionSpring) { uninstallResult = LastResult(summary: summary) }
    }

    private func start(_ request: ConfirmRequest) {
        sheet = nil
        lastResult = nil
        // Each batch starts its own count: another operation (airy://, MCP, uninstall) doesn't inherit the
        // previous batch's "freed" pill; only `.items` adds to it again.
        batchTally = BatchMotion.Tally()
        request.onConfirm?()
    }

    /// Only reacts to an already confirmed batch; it removes itself when the gust ends.
    private func startGust(order: [String]?, owner: Gust.Owner) {
        guard let order else { gust = nil; return }
        let gust = Gust(id: UUID(), start: .now, order: order, owner: owner)
        self.gust = gust
        let lifetime = WindMotion.gustLifetime(rowCount: order.count)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(lifetime))
            if self?.gust == gust { self?.gust = nil }
        }
    }

    /// The new detection already reflects what was cleaned: nothing to hide by hand.
    func detectionFinished() {
        guard !isRunning else { return }
        hiddenIDs = []
    }

    // MARK: Clean

    private func run(_ items: [CleanupItem], model: AppModel, context: OperationContext,
                     onOutcome: (@MainActor (CleanupOutcome) -> Void)?) async {
        // One execution batch: the expensive detection is repeated once (not the preview's), not per row.
        let pass = RevalidationPass()
        let summary = await CleanupBatch.run(items, onStart: { [weak self] index in
            guard let self else { return }
            self.currentID = items[index].id
            self.queuedIDs.removeAll { $0 == items[index].id }
        }, perform: { [weak self] item in
            // What disappeared since detection doesn't block the rest (the executor revalidates what remains).
            guard let current = CleanupBoard.withExistingPaths(item, exists: Self.exists) else {
                withAnimation(Theme.zoomSpring) { _ = self?.hiddenIDs.insert(item.id) }
                let gone = CleanupOutcome.blocked(reason: String(localized: "It no longer exists."))
                onOutcome?(gone)
                return gone
            }
            let outcome = await model.perform(current, context: context, refreshesCleanup: false, pass: pass)
            switch outcome {
            case .freed, .movedToTrash:
                self?.batchTally.add(outcome)
                // The row collapses with the spring as soon as it finishes (detection comes later).
                withAnimation(Theme.zoomSpring) { _ = self?.hiddenIDs.insert(item.id) }
            case .blocked, .failed: break
            }
            onOutcome?(outcome)
            return outcome
        })
        currentID = nil
        queuedIDs = []
        // A single detection at the end of the batch (not one per item).
        model.refreshCleanup()
        withAnimation(Theme.sectionSpring) { lastResult = LastResult(summary: summary) }
        if summary.freed > 0 { celebration = Celebration(bytes: summary.freed) }
    }

    private nonisolated static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    private func trash(paths: [String], title: String, model: AppModel, context: OperationContext,
                       onOutcome: (@MainActor (CleanupOutcome) -> Void)?) async {
        currentID = title
        queuedIDs = []
        let outcome = await model.trash(paths: paths, title: title, context: context)
        currentID = nil
        onOutcome?(outcome)
        var summary = CleanupRunSummary()
        summary.record(id: title, title: title, outcome: outcome)
        withAnimation(Theme.sectionSpring) { lastResult = LastResult(summary: summary) }
    }

    // MARK: Quit apps (Performance)

    /// One at a time; never chains "Force Quit" without another confirmation.
    private func quit(_ groups: [AppGroup], force: Bool, model: AppModel, context: OperationContext) async {
        let session = model.performance
        for group in groups {
            currentID = group.id
            queuedIDs.removeAll { $0 == group.id }
            session.markClosing(group.id, true)
            let outcome = force ? await model.forceQuit(group, context: context)
                                : await model.quit(group, context: context)
            session.markClosing(group.id, false)
            switch outcome {
            case .closed: withAnimation(Theme.zoomSpring) { session.markClosed(group.id) }
            case .didNotClose: session.markUnresponsive(group.id)
            case .blocked(let message), .failed(let message): session.setMessage(group.id, message)
            }
        }
        currentID = nil
        queuedIDs = []
    }

    // MARK: Empty Trash

    private func emptyTrash(model: AppModel, context: OperationContext) async {
        defer { isEmptyingTrash = false }
        let home = NSHomeDirectory()
        // What is there now (not what was there when the sheet opened), read off the main thread.
        let probes = probes
        let expected = await Task.detached(priority: .userInitiated) { probes.trashSizeIfReadable() }.value
        let freeBefore = await Self.freeSpace(home: home)
        let outcome = await model.emptyTrash(context: context)
        switch outcome {
        case .freed:
            var freeAfter = await Self.freeSpace(home: home)
            var snapshots: [String] = []
            if let expected, expected > 0, Double(freeAfter - freeBefore) < Double(expected) * TrashFollowUp.expectedRiseFraction {
                // APFS may take a moment to give the space back: check again before concluding.
                for _ in 0..<3 where Double(freeAfter - freeBefore) < Double(expected) * TrashFollowUp.expectedRiseFraction {
                    try? await Task.sleep(for: .seconds(1))
                    freeAfter = await Self.freeSpace(home: home)
                }
                snapshots = await probes.localSnapshots()
            }
            if TrashFollowUp.shouldExplainSnapshots(expectedBytes: expected, freeBefore: freeBefore,
                                                    freeAfter: freeAfter, snapshotCount: snapshots.count),
               let expected {
                sheet = .snapshots(SnapshotNotice(
                    emptied: expected, rose: max(0, freeAfter - freeBefore),
                    retained: TrashFollowUp.retainedBytes(expectedBytes: expected, freeBefore: freeBefore, freeAfter: freeAfter),
                    snapshotCount: snapshots.count))
            } else {
                // Celebrate how much free space really went up, not what the Trash took.
                let rose = freeAfter - freeBefore
                if rose > 0 {
                    celebration = Celebration(bytes: rose)
                } else {
                    var summary = CleanupRunSummary()
                    summary.record(id: "empty-trash", title: String(localized: "Empty Trash"), outcome: .freed(0))
                    withAnimation(Theme.sectionSpring) { lastResult = LastResult(summary: summary) }
                }
            }
        case .movedToTrash, .blocked, .failed:
            var summary = CleanupRunSummary()
            summary.record(id: "empty-trash", title: String(localized: "Empty Trash"), outcome: outcome)
            withAnimation(Theme.sectionSpring) { lastResult = LastResult(summary: summary) }
            model.section = .cleanup
        }
    }

    /// From the snapshots notice: the catalog's `time-machine-snapshots` entry, with confirmation.
    func requestSnapshotCleanup(_ notice: SnapshotNotice, model: AppModel) {
        guard let catalog = model.catalog,
              let item = TrashFollowUp.snapshotItem(catalog: catalog, retainedBytes: notice.retained) else {
            sheet = nil
            var summary = CleanupRunSummary()
            summary.record(id: TrashFollowUp.snapshotEntryID, title: String(localized: "Time Machine snapshots"),
                           outcome: .failed(String(localized: "Its entry wasn’t found in the cleanup catalog; Airy can’t thin them.")))
            withAnimation(Theme.sectionSpring) { lastResult = LastResult(summary: summary) }
            model.section = .cleanup
            return
        }
        sheet = .confirm(ConfirmRequest(kind: .items([item])))
    }

    private nonisolated static func freeSpace(home: String) async -> Int64 {
        await Task.detached(priority: .userInitiated) { SystemProbes.availableCapacity(home: home) }.value
    }

    // MARK: Quitting apps

    /// Name of the open app (the system's) or one known by its bundle ID.
    static func appName(_ bundleID: String) -> String {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName
            ?? CleanupBoard.appName(forBundleID: bundleID)
    }

    /// "Quit Spotify": `terminate()` (the app may ask to save), waits up to 10 s and detects again.
    /// If the app doesn't quit, it says so.
    func closeApp(_ bundleID: String, model: AppModel) {
        guard !closingApps.contains(bundleID) else { return }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        let name = Self.appName(bundleID)
        appRefusals[bundleID] = nil
        guard !apps.isEmpty else {
            model.refreshCleanup()
            return
        }
        closingApps.insert(bundleID)
        for app in apps { app.terminate() }
        poll(apps, bundleID: bundleID, name: name, deadline: Date().addingTimeInterval(10), model: model)
    }

    /// Checks every 250 ms on the main queue (without the cooperative *pool*, which is slow during a scan).
    private func poll(_ apps: [NSRunningApplication], bundleID: String, name: String, deadline: Date, model: AppModel) {
        let stillOpen = apps.contains { !$0.isTerminated }
        guard stillOpen, Date() < deadline else {
            closingApps.remove(bundleID)
            if stillOpen {
                appRefusals[bundleID] = String(localized: "\(name) didn’t quit. It may have unsaved work: quit it yourself and try again.")
            }
            model.refreshCleanup()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            MainActor.assumeIsolated {
                self?.poll(apps, bundleID: bundleID, name: name, deadline: deadline, model: model)
            }
        }
    }

    // MARK: Debugging

    #if DEBUG
    /// Captures only: replaces detected blockers (e.g. Spotify open without opening it).
    var debugBlocked: [String: [String]] = [:]
    var debugScrollTarget: String?
    #endif
}
