import AppKit
import Foundation
import Observation
import DiskMapCore

/// Sidebar sections.
enum Section: String, CaseIterable, Identifiable, Hashable {
    case map, cleanup, performance, assistant
    case uninstaller, largeOld, duplicates, types
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .map: String(localized: "Map")
        case .cleanup: String(localized: "Cleanup")
        case .performance: String(localized: "Performance")
        case .assistant: String(localized: "AI Assistant")
        case .uninstaller: String(localized: "Uninstaller")
        case .largeOld: String(localized: "Large & Old")
        case .duplicates: String(localized: "Duplicates")
        case .types: String(localized: "File Types")
        case .settings: String(localized: "Settings")
        }
    }

    var symbol: String {
        switch self {
        case .map: "square.grid.3x3.square"
        case .cleanup: "sparkles"
        case .performance: "gauge.with.dots.needle.67percent"
        case .assistant: "brain.head.profile"
        case .uninstaller: "xmark.app"
        case .largeOld: "calendar.badge.clock"
        case .duplicates: "doc.on.doc"
        case .types: "chart.pie"
        case .settings: "gearshape"
        }
    }

    var isAvailable: Bool { true }

    static let available: [Section] = allCases.filter(\.isAvailable)
}

/// A scannable volume: the startup disk and mounted writable external ones.
struct Volume: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let isStartup: Bool
    let totalBytes: Int64
    /// Truly free (`volumeAvailableCapacityKey`, what `df` reports).
    let availableBytes: Int64
    /// Free including purgeable space (`volumeAvailableCapacityForImportantUsageKey`, what Finder reports).
    let importantAvailableBytes: Int64

    var id: String { url.path }
    var symbol: String { isStartup ? "internaldrive.fill" : "externaldrive.fill" }

    static let startupFallback = Volume(url: URL(fileURLWithPath: "/"), name: "Macintosh HD",
                                        isStartup: true, totalBytes: 0, availableBytes: 0,
                                        importantAvailableBytes: 0)

    /// Reads mounted volumes (`skipHiddenVolumes`) and drops read-only and system ones.
    static func mounted() -> [Volume] {
        let keys: [URLResourceKey] = [
            .volumeLocalizedNameKey, .volumeIsReadOnlyKey, .volumeIsRootFileSystemKey,
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        var volumes: [Volume] = []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let isStartup = url.path == "/" || values.volumeIsRootFileSystem == true
            if !isStartup {
                if values.volumeIsReadOnly == true || url.path.hasPrefix("/System/Volumes") { continue }
            }
            volumes.append(Volume(
                url: isStartup ? URL(fileURLWithPath: "/") : url,
                name: values.volumeLocalizedName ?? (isStartup ? "Macintosh HD" : url.lastPathComponent),
                isStartup: isStartup,
                totalBytes: Int64(values.volumeTotalCapacity ?? 0),
                availableBytes: Int64(values.volumeAvailableCapacity ?? 0),
                importantAvailableBytes: values.volumeAvailableCapacityForImportantUsage ?? 0))
        }
        if !volumes.contains(where: \.isStartup) { volumes.insert(startupFallback, at: 0) }
        return volumes.sorted { ($0.isStartup ? 0 : 1, $0.name) < ($1.isStartup ? 0 : 1, $1.name) }
    }
}

/// Non-blocking notice the UI shows as a dismissible banner.
struct Notice: Identifiable, Equatable {
    enum Kind: String { case scan, save, history, catalog, migration, url, settings, audit, performance, spaceDrop }
    let kind: Kind
    let message: String
    var id: String { kind.rawValue }
}

/// A URL command with its own identity: two `airy://rescan` in a row are two distinct requests.
struct PendingURLCommand: Identifiable, Equatable {
    let id = UUID()
    let command: AiryURLCommand
}

/// Global app state. Everything heavy (scanning, index reading, probes, commands)
/// runs off the main thread; only the results are published here.
@MainActor @Observable
final class AppModel {
    // MARK: Published state

    var section: Section = .map
    var scan: ScanResult? {
        didSet { partialIndex = PartialScanIndex(inaccessible: scan?.inaccessible ?? []) }
    }
    /// Which paths in the last scan contain something unreadable (their size carries a "+"). Sorted once per scan.
    @ObservationIgnored private(set) var partialIndex = PartialScanIndex(inaccessible: [])
    /// What the Map and its footer say: complete, partial (N unreadable folders) or no scan.
    var scanCompleteness: ScanCompleteness { .of(scan) }
    var progress: ScanProgress?
    var isScanning = false
    var cleanupItems: [CleanupItem] = []
    var isRefreshingCleanup = false
    /// `nil` if `~/.Trash` can't be read (no Full Disk Access): "unknown", not "empty".
    var trashBytes: Int64? = 0
    var totalFreed: Int64 = 0
    /// `false` if the history couldn't be read: `totalFreed` is the last known value.
    var totalFreedKnown = true
    var hasFullDiskAccess = true
    var navigation = MapNavigation()
    /// Date of the scan shown (the saved index's until the new one finishes).
    var lastScanDate: Date?
    /// What grew and shrank between the last two finished scans of the shown volume (the Map's "What changed" card).
    var scanChanges: ScanChanges?
    /// Error from the last scan. With no scan to show it fills the screen; otherwise it goes in `notices`.
    var scanError: String?
    /// Problems that don't stop the app from working but change what the numbers mean.
    var notices: [Notice] = []
    /// Question the map ("Explain with AI") leaves for the assistant; `AssistantView` consumes it.
    var pendingAssistantQuestion: String?
    /// Report, chat and the located Claude: they survive section changes.
    let assistant = AssistantSession()
    /// State of the phase 2 sections (filters, results and selection): survives section changes.
    let sections = SectionStores()
    /// Performance: samples only while the section is visible.
    let performance: PerformanceSession
    /// App quit funnel (ConfirmSheet → AppModel → QuitExecutor).
    let quitExecutor: QuitExecutor
    /// Pending `airy://` link command: `RootView` consumes it with its `CleanupFlow`.
    /// It never runs anything: at most it opens the confirmation sheet.
    var pendingURLCommand: PendingURLCommand?
    /// Any app or website can open `airy://`: a burst of links is dropped.
    private var urlLimiter = URLCommandRateLimiter()
    /// Bumps every time the shown tree changes in place (e.g. something moved to the Trash).
    private(set) var treeRevision = 0

    var volumes: [Volume] = [.startupFallback]
    var selectedVolume: URL = URL(fileURLWithPath: "/") {
        didSet {
            guard oldValue != selectedVolume else { return }
            startScan(.automatic)
        }
    }

    // MARK: Dependencies

    let catalog: Catalog?
    let catalogError: String?
    let paths: AppPaths
    /// Operation log shared with `airy-mcp`.
    let operationLog: OperationLog
    /// `settings.json`: re-read when returning to the app and before every destructive action.
    private var settingsSession: SettingsSession
    private let runner = ProcessRunner()
    private let probes = SystemProbes()
    private let appDirectory: URL
    /// Startup disk index and cleanup history.
    private let store: IndexStore
    private var scanTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var scanGeneration = 0
    private var cleanupGeneration = 0
    /// When automatic detection may run (after the saved index or after the new scan).
    private var detectionGate = DetectionGate()
    private var observers: [NSObjectProtocol] = []
    /// Access turns on the live tree: background readers versus changes (Trash).
    let treeGate = TreeGate()
    /// Store of the index being shown (to save it again after a change) and its key.
    private var shownStore: IndexStore?
    private var shownStoreKey = "/"
    private let saveSequencer = SaveSequencer()
    private var lastSave: [String: Task<SaveResult, Never>] = [:]
    /// Paths an action (Trash or cleanup) removed or changed, with their time. A scan that
    /// started earlier may have seen them as they were: when it is published, only those are re-measured.
    private var touchedPaths: [String: Date] = [:]
    /// Free-space drop alert: checks once a minute at `.background` while Airy runs. It never acts.
    @ObservationIgnored private var spaceDropTask: Task<Void, Never>?

    init() {
        let paths = AppPaths.standard()
        self.paths = paths
        appDirectory = paths.support
        operationLog = OperationLog(file: paths.operationsFile)
        let performance = PerformanceSession()
        self.performance = performance
        let monitor = performance.monitor
        quitExecutor = QuitExecutor(currentGroups: { await monitor.refresh().groups }, log: operationLog)
        var migrationFailure: String?
        if case .failed(let reason) = DataMigration.migrateIfNeeded(paths) { migrationFailure = reason }
        store = IndexStore(directory: appDirectory)
        // After the migration: it may have brought over the legacy `settings.json`.
        settingsSession = SettingsSession(store: SettingsStore(file: paths.settingsFile))
        do {
            catalog = try Catalog.bundled()
            catalogError = nil
        } catch {
            catalog = nil
            catalogError = String(localized: "Couldn’t load the cleanup catalog (\(String(describing: error))). The Cleanup section isn’t available.")
        }
        if let catalogError { notices.append(Notice(kind: .catalog, message: catalogError)) }
        if let migrationFailure {
            notices.append(Notice(kind: .migration, message: String(localized: "Couldn’t copy the data from \(AppPaths.legacyFolderName) (\(migrationFailure)). It’s still in its folder; Airy will try again next time it opens.")))
        }
        syncSettingsNotice()
        // Core text (catalog, notices) in the language chosen in Settings; `nil` follows the app's UI.
        AiryLanguage.override = settingsSession.effective.language.code
        launchLanguageChoice = settingsSession.effective.language
        observeSystem()
        refreshSystemState()
        performance.model = self
        startSpaceDropMonitor()
    }

    /// Watches free space once a minute (sleeping in between). On a fast drop it shows a
    /// notice with the largest deleted-but-open file; the snapshot also reaches `airy-mcp` (`get_disk_summary`).
    private func startSpaceDropMonitor() {
        let monitor = SpaceDropMonitor(runner: runner, store: SpaceDropStore(directory: paths.support))
        spaceDropTask = Task.detached(priority: .background) { [weak self] in
            await monitor.run { snapshot in
                await MainActor.run { self?.report(.spaceDrop, snapshot.message) }
            }
        }
    }

    // MARK: Settings

    var settingsLoad: SettingsLoad { settingsSession.load }
    var settings: AirySettings { settingsLoad.effective }

    /// Applies a change and saves it; if the mode or the protected list changes, detection runs again.
    /// With an unreadable `settings.json` nothing is saved: it has to be reset first.
    func updateSettings(_ change: (inout AirySettings) -> Void) {
        do {
            if try settingsSession.update(change) { refreshCleanup() }
            syncSettingsNotice()
        } catch is SettingsSession.Unreadable {
            syncSettingsNotice()
        } catch {
            report(.settings, String(localized: "Couldn’t save the settings (\(error.localizedDescription))."))
        }
    }

    /// "Reset Settings": re-reads `settings.json`; if it is still unreadable, asks for confirmation (saying
    /// what is kept and what is lost), moves it aside and writes new settings with what was recovered. Reports
    /// what happened (e.g. that the "Protect This" list couldn't be recovered).
    func resetSettings() {
        guard let explanation = settingsSession.resetConfirmation() else {
            syncSettingsNotice()
            refreshCleanup()
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Reset Airy’s settings?")
        alert.informativeText = explanation
        alert.addButton(withTitle: String(localized: "Reset"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            guard let result = try settingsSession.reset() else {
                syncSettingsNotice()
                refreshCleanup()
                return
            }
            report(.settings, result.message)
            refreshCleanup()
        } catch {
            report(.settings, String(localized: "Couldn’t reset the settings (\(error.localizedDescription))."))
        }
    }

    /// "Protect This" (non-destructive: no confirmation).
    func protect(path: String) { protect(paths: [path]) }

    func protect(paths: [String]) {
        let home = NSHomeDirectory()
        updateSettings { settings in for path in paths { _ = settings.protect(path, home: home) } }
    }

    func unprotect(_ pattern: String) {
        updateSettings { $0.unprotect(pattern) }
    }

    /// Settings › Scanning › Excluded folders (applies from the next scan).
    func exclude(paths: [String]) {
        let home = NSHomeDirectory()
        updateSettings { settings in for path in paths { _ = settings.exclude(path, home: home) } }
    }

    func unexclude(_ path: String) {
        updateSettings { $0.unexclude(path) }
    }

    // MARK: Settings › General

    /// Language choice the process started with: a different one needs a relaunch.
    @ObservationIgnored private(set) var launchLanguageChoice: AppLanguage = .system

    /// `true` when the language chosen in Settings differs from the one this process started with.
    var languageNeedsRestart: Bool { settings.language != launchLanguageChoice }

    /// Saves the language and writes the app's own `AppleLanguages` (never the global one), which macOS reads on
    /// the next launch. In DEBUG with `AIRY_SUPPORT_DIR` the real user defaults aren't touched: the relaunch
    /// passes the language as an argument instead.
    func setLanguage(_ language: AppLanguage) {
        updateSettings { $0.language = language }
        guard settings.language == language, Self.touchesUserDefaults else { return }
        Self.writeAppleLanguages(language)
    }

    private static func writeAppleLanguages(_ language: AppLanguage) {
        if let code = language.code {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
    }

    private static var touchesUserDefaults: Bool { AppPaths.standard().legacySupport != nil }

    /// "Restart now": opens a new instance of Airy and quits this one once it has launched. Refused while a
    /// cleanup, uninstall or quit is running (`busy`).
    /// Returns why it couldn't, or `nil` once the new instance has been asked to open.
    @discardableResult
    func relaunch(busy: Bool) -> String? {
        guard !busy else { return String(localized: "Airy is busy; restart it when the current task has finished.") }
        var arguments: [String] = []
        if let code = settings.language.code { arguments += ["-AppleLanguages", "(\(code))"] }
        let bundle = Bundle.main.bundleURL
        if bundle.pathExtension == "app" {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            configuration.arguments = arguments
            configuration.environment = ProcessInfo.processInfo.environment
            NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { [weak self] _, error in
                Task { @MainActor in
                    if let error {
                        self?.report(.settings, String(localized: "Couldn’t restart Airy (\(error.localizedDescription)). Quit and open it again."))
                    } else {
                        NSApp.terminate(nil)
                    }
                }
            }
            return nil
        } else if let executable = Bundle.main.executableURL {
            // A bare executable (`swift run`, DEBUG checks): same binary, same environment.
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = ProcessInfo.processInfo.environment
            do {
                try process.run()
                NSApp.terminate(nil)
            } catch {
                return String(localized: "Couldn’t restart Airy (\(error.localizedDescription)). Quit and open it again.")
            }
        }
        return nil
    }

    // MARK: Settings › Data

    /// Airy's own support folder (index, history, settings, operation log).
    var dataFolder: URL { paths.support }

    /// Shows the support folder (or the operation log inside it) in Finder, creating the folder if needed.
    func revealDataFolder(selecting file: URL? = nil) {
        try? FileManager.default.createDirectory(at: paths.support, withIntermediateDirectories: true)
        if let file, FileManager.default.fileExists(atPath: file.path) {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else {
            NSWorkspace.shared.open(paths.support)
        }
    }

    /// Asks before an action on Airy's own files. `true` if the user confirmed.
    private func confirm(_ title: String, _ message: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// "Delete scan index": removes the saved indexes (startup disk and external ones) after confirming. Only
    /// Airy's own `scan.plist` files: the cleanup history and every user file stay. Not while scanning.
    /// Returns what happened for the Settings card, or `nil` if the user cancelled.
    func deleteScanIndex() -> String? {
        guard !isScanning else { return nil }
        guard confirm(String(localized: "Delete the scan index?"),
                      String(localized: "Airy forgets its saved scans of every disk and scans again the next time it opens. Your files aren’t touched, and the cleanup history stays."),
                      button: String(localized: "Delete Index")) else { return nil }
        var stores = [store]
        let volumes = appDirectory.appendingPathComponent("Volumes", isDirectory: true)
        let folders = (try? FileManager.default.contentsOfDirectory(at: volumes, includingPropertiesForKeys: nil)) ?? []
        stores += folders.map { IndexStore(directory: $0) }
        do {
            for store in stores { try store.deleteScan() }
            return String(localized: "Scan index deleted. The map shown stays until you scan again.")
        } catch {
            return String(localized: "Couldn’t delete the scan index (\(error.localizedDescription)).")
        }
    }

    /// "Clear operation log": empties `operations.jsonl` after confirming.
    func clearOperationLog() -> String? {
        guard confirm(String(localized: "Clear the operation log?"),
                      String(localized: "Airy deletes the record of what it and your agents cleaned. This can’t be undone. Your files and the Trash aren’t touched."),
                      button: String(localized: "Clear Log")) else { return nil }
        do {
            try operationLog.clear()
            return String(localized: "Operation log cleared.")
        } catch {
            return String(localized: "Couldn’t clear the operation log (\(error.localizedDescription)).")
        }
    }

    /// "Reset all settings": every preference back to its default after confirming; the "Protect this" list is
    /// kept. With an unreadable `settings.json` it is the existing recovery flow instead (`resetSettings`).
    func resetAllSettings() -> String? {
        guard !settingsLoad.isUnreadable else {
            resetSettings()
            return nil
        }
        guard confirm(String(localized: "Reset all settings?"),
                      String(localized: "Language, animations, scanning, cleanup mode, agents and AI go back to their defaults. Agents will be allowed to run safe cleanups. Your “Protected by you” list is kept."),
                      button: String(localized: "Reset")) else { return nil }
        updateSettings { $0 = $0.resettingPreferences() }
        guard settings == settings.resettingPreferences(), !settingsLoad.isUnreadable else {
            return String(localized: "Couldn’t reset the settings.")
        }
        if Self.touchesUserDefaults { Self.writeAppleLanguages(.system) }
        return String(localized: "Settings reset to their defaults.")
    }

    /// Notice while `settings.json` can't be read, or `nil`.
    var unreadableSettingsNotice: String? { settingsSession.unreadableNotice }

    /// Reason not to delete anything right now (unreadable settings), or `nil`.
    var destructiveRefusal: String? { settingsSession.destructiveRefusal }

    /// Classifier with the loaded settings: the same one for Cleanup, the map and the assistant.
    var classifier: RiskClassifier {
        RiskClassifier(catalog: catalog ?? Catalog(entries: []), settings: settings, home: NSHomeDirectory())
    }

    func classify(path: String) -> Classification { classifier.classify(path: path) }

    /// Path gate with the loaded settings ("Protect This" list included).
    func gate() -> PathGate {
        let home = NSHomeDirectory()
        return PathGate(home: home, catalog: catalog,
                        userProtected: ProtectList(patterns: settings.protectedPaths, home: home))
    }

    /// Large & Old finder with the loaded settings.
    func largeOldFinder() -> LargeOldFinder {
        LargeOldFinder(classifier: classifier, catalog: catalog, gate: gate(), home: NSHomeDirectory())
    }

    /// Duplicates finder with the loaded settings.
    func duplicateFinder() -> DuplicateFinder {
        DuplicateFinder(home: NSHomeDirectory(), classifier: classifier, gate: gate())
    }

    /// Saves the last Duplicates result (paths, sizes and dates only); on failure, reports it and carries on.
    func saveDuplicates(_ result: DuplicateResult) {
        let url = paths.duplicatesFile
        Task { [weak self] in
            let failure = await Task.detached(priority: .utility) { () -> String? in
                do {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                            withIntermediateDirectories: true)
                    try DuplicateReport.save(result, to: url)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            if let failure { self?.report(.save, String(localized: "Couldn’t save the Duplicates result (\(failure)).")) }
        }
    }

    /// Re-reads `settings.json`; if it changed, reports it and detects again.
    func reloadSettings() {
        guard settingsSession.reload() else { return }
        syncSettingsNotice()
        refreshCleanup()
    }

    private func syncSettingsNotice() {
        if let notice = settingsSession.unreadableNotice { report(.settings, notice) } else { dismiss(.settings) }
    }

    /// Fail closed: with unreadable settings nothing is deleted (not even the Trash).
    private func settingsRefusal() -> CleanupOutcome? {
        reloadSettings()
        return settingsSession.destructiveRefusal.map { .blocked(reason: $0) }
    }

    // MARK: Notices

    func report(_ kind: Notice.Kind, _ message: String) {
        notices.removeAll { $0.kind == kind }
        notices.append(Notice(kind: kind, message: message))
    }

    func dismiss(_ kind: Notice.Kind) {
        notices.removeAll { $0.kind == kind }
        if kind == .scan { scanError = nil }
    }

    // MARK: airy:// links

    /// `.onOpenURL` entry point: validates and leaves the command pending. An invalid URL only shows a notice.
    func handle(url: URL) {
        guard urlLimiter.allow() else {
            report(.url, URLProposalPolicy.rateLimited)
            return
        }
        guard let command = AiryURLCommand(url: url) else {
            report(.url, String(localized: "Airy didn’t understand that link, so it did nothing."))
            return
        }
        pendingURLCommand = PendingURLCommand(command: command)
    }

    /// Deminiaturizes and brings Airy's main window to the front (never another app).
    static func bringMainWindowForward() {
        if NSApp.isHidden { NSApp.unhide(nil) }
        guard let window = NSApp.windows.first(where: {
            $0.contentView != nil && $0.sheetParent == nil && $0.canBecomeMain && ($0.isVisible || $0.isMiniaturized)
        }) else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Processes the pending command (called by `RootView`). It never runs a cleanup by itself:
    /// a proposal only opens the confirmation sheet, and the user is the one who confirms.
    func run(_ pending: PendingURLCommand, flow: CleanupFlow) async {
        defer { if pendingURLCommand?.id == pending.id { pendingURLCommand = nil } }
        switch pending.command {
        case .rescan:
            section = .map
            if !isScanning { startScan(.agent) }
        case .show(let path):
            section = .map
            guard await waitUntil({ $0.scan != nil }) else { return }
            navigation.reveal(path: path)
        case .proposeQuit(let app, let reason, let agent):
            // It never quits anything: at most it opens the confirmation, and the user decides.
            // M8: with another sheet open or something running, it doesn't even switch sections.
            if let refusal = URLProposalPolicy.refusal(sheetOpen: flow.sheet != nil, busy: flow.isBusy) {
                report(.performance, refusal)
                return
            }
            // I3: the confirmation lives in the window, so it is brought to the front first (if it was minimized or
            // hidden). If it never becomes visible, Performance doesn't measure: the window's real visibility decides.
            Self.bringMainWindowForward()
            section = .performance
            let snapshot = await performance.freshSnapshot()
            guard let row = PerformanceBoard(snapshot: snapshot, policy: QuitPolicy()).row(matching: app) else {
                report(.performance, String(localized: "An agent proposed quitting “\(app)”, but it isn’t open."))
                return
            }
            guard PerformanceBoard.canSelect(row) else {
                report(.performance, String(localized: "An agent proposed quitting “\(row.group.name)”, but Airy never quits it."))
                return
            }
            guard !flow.isBusy, flow.sheet == nil else {
                report(.performance, String(localized: "Airy is busy; ask again in a moment."))
                return
            }
            let warning = CleanupFlow.ConfirmRequest.Warning(
                title: String(localized: "An agent proposes quitting this"),
                subtitle: "\(agent ?? String(localized: "An agent")) · \(reason.isEmpty ? String(localized: "no reason given") : reason)",
                reason: String(localized: "Nothing quits until you confirm it here."),
                note: String(localized: "If it has unsaved work, the app will ask you."))
            flow.requestQuit([row.group], warning: warning, proposedBy: agent,
                             proposedVia: OperationContext.viaUnverifiedURL)
        case .uninstall(let bundleID, let reason, let agent):
            // It only prepares the confirmation: the user decides (and what runs is logged as `.user(…, proposedBy:)`).
            if let refusal = URLProposalPolicy.refusal(sheetOpen: flow.sheet != nil, busy: flow.isBusy) {
                report(.url, refusal)
                return
            }
            section = .uninstaller
            let inventory = await inventorySnapshot()
            guard !Task.isCancelled else { return }
            guard let app = inventory.apps.filter({ $0.bundleID.caseInsensitiveCompare(bundleID) == .orderedSame })
                .sorted(by: { $0.path < $1.path }).first else {
                report(.url, String(localized: "An agent proposed uninstalling “\(bundleID)”, but it isn’t installed."))
                return
            }
            let plan = await uninstallPlan(for: app, inventory: inventory)
            if let refusal = plan.refusal {
                report(.url, String(localized: "An agent proposed uninstalling “\(app.name)”, but \(refusal.prefix(1).lowercased() + refusal.dropFirst())"))
                return
            }
            if let refusal = URLProposalPolicy.refusal(sheetOpen: flow.sheet != nil, busy: flow.isBusy) {
                report(.url, refusal)
                return
            }
            let warning = CleanupFlow.ConfirmRequest.Warning(
                title: URLProposalPolicy.warningTitle(),
                subtitle: URLProposalPolicy.warningSubtitle(agent: agent, reason: reason),
                reason: URLProposalPolicy.warningReason,
                note: URLProposalPolicy.warningNote,
                continueTitle: String(localized: "See What Gets Uninstalled…"))
            flow.requestUninstall([UninstallRequest(plan: plan, selected: plan.defaultSelection)], warning: warning,
                                  proposedBy: URLProposalPolicy.claimedAgent(agent),
                                  proposedVia: OperationContext.viaUnverifiedURL)
        case .propose(let target, let reason, let agent):
            // It never replaces a sheet already open (the user would confirm something else) or a cleanup in progress.
            if let refusal = URLProposalPolicy.refusal(sheetOpen: flow.sheet != nil, busy: flow.isBusy) {
                report(.url, refusal)
                return
            }
            // The name is set by whoever opens the link: it is shown and logged as something it "claims to be".
            let claimed = URLProposalPolicy.claimedAgent(agent)
            let warning = CleanupFlow.ConfirmRequest.Warning(
                title: URLProposalPolicy.warningTitle(),
                subtitle: URLProposalPolicy.warningSubtitle(agent: agent, reason: reason),
                reason: URLProposalPolicy.warningReason,
                note: URLProposalPolicy.warningNote)
            let via = OperationContext.viaUnverifiedURL
            switch target {
            case .item(let id):
                section = .cleanup
                // The finished detection (or the one in progress) decides whether the id still exists.
                guard await waitUntil({ !$0.isRefreshingCleanup && ($0.scan != nil || !$0.isScanning) }) else { return }
                guard let item = cleanupItems.first(where: { $0.id == id }) else {
                    report(.url, String(localized: "A link proposed “\(URLProposalPolicy.shortPath(id))”, but it no longer appears in Cleanup."))
                    return
                }
                guard item.protection == nil else {
                    report(.url, String(localized: "A link proposed “\(item.title)”, but it’s “Don't delete”: Airy doesn’t offer it."))
                    return
                }
                // While waiting for detection, another sheet may have opened or a cleanup may have started.
                if let refusal = URLProposalPolicy.refusal(sheetOpen: flow.sheet != nil, busy: flow.isBusy) {
                    report(.url, refusal)
                    return
                }
                flow.requestClean([item], warning: warning, proposedBy: claimed, proposedVia: via)
            case .path(let path):
                if let refusal = trashRefusal(path: path) {
                    report(.url, String(localized: "A link proposed moving “\(URLProposalPolicy.shortPath(path))” to the Trash, but Airy can’t: \(refusal)"))
                    return
                }
                let title = path.split(separator: "/").last.map(String.init) ?? path
                flow.requestTrash(paths: [path], title: title, warning: warning, proposedBy: claimed, proposedVia: via)
            }
        }
    }

    /// Waits (up to 2 minutes, cancellable) for `condition` to hold on the main thread.
    private func waitUntil(_ condition: (AppModel) -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(120)
        while !condition(self) {
            guard !Task.isCancelled, Date() < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return !Task.isCancelled
    }

    // MARK: Derived

    var currentVolume: Volume {
        volumes.first { $0.url == selectedVolume } ?? volumes.first ?? .startupFallback
    }

    /// Bytes taken by what was scanned ("Scanned"); during the first scan, what has been walked so far.
    var analyzedBytes: Int64 { scan?.root.allocatedSize ?? progress?.bytesScanned ?? 0 }

    /// Disk breakdown: scanned, system and other, purgeable and free (see `DiskUsageBreakdown`).
    var diskUsage: DiskUsageBreakdown {
        let volume = currentVolume
        return DiskUsageBreakdown(totalBytes: volume.totalBytes, availableBytes: volume.availableBytes,
                                  importantAvailableBytes: volume.importantAvailableBytes,
                                  analyzedBytes: analyzedBytes)
    }

    var inaccessibleCount: Int { scan?.inaccessible.count ?? 0 }

    // MARK: Scanning

    /// Instantly shows the saved index of the chosen volume, rescans it in the background
    /// with progress, saves it and refreshes the cleanup. Cancels any previous scan.
    /// On launch (`.automatic`) an index younger than 6 h isn't rescanned; automatic scans and
    /// agent scans run at `background` intensity (see `ScanSchedule` and `ScanBudget`).
    func startScan(_ trigger: ScanTrigger = .user) {
        scanTask?.cancel()
        scanGeneration += 1
        let generation = scanGeneration
        dismiss(.scan)
        progress = nil
        isScanning = true
        #if DEBUG
        if DebugSnapshot.previewsScan {
            // Screen only: nothing is read, scanned or saved.
            scan = nil
            progress = ScanProgress(filesScanned: 184_302, bytesScanned: 61_000_000_000,
                                    currentPath: "/Users/Shared/Example/Library/Photos")
            return
        }
        #endif
        // Automatic detection waits for the index or the new scan; meanwhile, Cleanup says "Searching…".
        detectionGate.scanStarted()
        isRefreshingCleanup = true

        // Arrives at most every 100 ms from the scanner threads.
        let onProgress: @Sendable (ScanProgress) -> Void = { [weak self] snapshot in
            Task { @MainActor [weak self] in
                guard let self, generation == self.scanGeneration else { return }
                self.progress = snapshot
            }
        }

        scanTask = Task { [weak self] in
            // 0. Up-to-date volumes (capacities and name), read off the main thread.
            await self?.refreshVolumes()
            guard let self, generation == self.scanGeneration else { return }
            let volume = self.currentVolume
            let store = self.store(for: volume)

            // 1. Saved index, read off the main thread.
            let expectedRoot = Self.expectedRootName(for: volume)
            let stored = await Task.detached(priority: .userInitiated) { () -> (ScanResult, Date?)? in
                guard let result = try? store.loadScan(), result.root.name == expectedRoot else { return nil }
                // The scan date lives in the index (not the file's: every cleanup rewrites it).
                return (result, result.scannedAt)
            }.value
            guard generation == self.scanGeneration else { return }
            let changeStore = self.changeStore(for: volume)
            self.scanChanges = await Task.detached(priority: .utility) { changeStore.changes() }.value
            guard generation == self.scanGeneration else { return }
            if let (result, date) = stored {
                self.show(result, date: date, volume: volume)
            } else {
                self.scan = nil
                self.lastScanDate = nil
                self.navigation = MapNavigation(rootTitle: volume.name)
            }

            // 2. Is it needed? A recent index stays (the map says "Last scan: … ago").
            // Automatic detection runs right away on an index that stays; if a scan is coming, it waits for it
            // (detecting on a tree about to be replaced is wasted work, and it would compete with the scan).
            let preferences = self.settings
            let plan = ScanSchedule.plan(trigger, hasIndex: stored != nil, indexDate: stored?.1, now: Date(),
                                         autoRescan: preferences.autoRescanOnLaunch,
                                         maxAge: preferences.rescanAge.interval)
            if let detection = self.detectionGate.indexRead(hasIndex: stored != nil, plan: plan) {
                self.refreshCleanup(detection)
            }
            let intensity: ScanIntensity
            switch plan {
            case .skip:
                self.isScanning = false
                return
            case .scan(let level):
                intensity = level
            }

            // 3. New scan with threads and QoS limited by the intensity, cancellable.
            let scanStarted = Date()
            // Folders excluded in Settings › Scanning are never opened (read now, right before walking).
            let options = ScanOptions(roots: Self.scanRoots(for: volume), userExcluded: self.settings.excludedPaths)
            let scanner = DiskScanner(options: options, intensity: intensity)
            let job = Task.detached(priority: intensity == .background ? .background : .utility) {
                try await scanner.scan(progress: onProgress)
            }
            let result: ScanResult
            do {
                result = try await withTaskCancellationHandler {
                    try await job.value
                } onCancel: {
                    job.cancel()
                }
            } catch {
                if generation == self.scanGeneration {
                    self.isScanning = false
                    self.detectionAfterStoppedScan()
                    if !(error is CancellationError) {
                        let message = String(localized: "Couldn’t scan “\(volume.name)”: \(error.localizedDescription)")
                        self.scanError = message
                        self.report(.scan, message)
                    }
                }
                return
            }
            guard generation == self.scanGeneration else { return }

            // 4. What was cleaned or moved to the Trash during the scan doesn't come back.
            let touched = self.touchedPaths.filter { $0.value >= scanStarted }.map(\.key)
            if !touched.isEmpty {
                let measured = await Task.detached(priority: .userInitiated) {
                    ScanTreeRefresh.measure(touched)
                }.value
                guard generation == self.scanGeneration else { return }
                // The new tree isn't published yet: nobody else walks it.
                ScanTreeRefresh.apply(measured, to: result.root)
            }
            self.touchedPaths = self.touchedPaths.filter { $0.value >= scanStarted }

            // 5. Publish, save and refresh the cleanup.
            self.show(result, date: result.scannedAt ?? Date(), volume: volume)
            self.isScanning = false
            self.progress = nil
            self.refreshSystemState()
            if let detection = self.detectionGate.scanFinished(trigger) { self.refreshCleanup(detection) }
            await self.recordChanges(result, previousTree: stored?.0, store: changeStore, generation: generation)
            await self.saveIndex(result, to: store, key: volume.url.path)
        }
    }

    /// Launch: selects the default disk from Settings (if it is mounted) and starts the automatic scan.
    func startLaunchScan() async {
        if let preferred = settings.defaultVolume {
            await refreshVolumes()
            if let volume = volumes.first(where: { $0.url.path == preferred }), volume.url != selectedVolume {
                // `selectedVolume`'s `didSet` starts the automatic scan of that disk.
                selectedVolume = volume.url
                return
            }
        }
        startScan(.automatic)
    }

    /// Scan roots: the whole volume. In DEBUG, `AIRY_SCAN_ROOTS` replaces them
    /// (app checks on a small folder instead of the disk).
    private static func scanRoots(for volume: Volume) -> [URL] {
        #if DEBUG
        if let roots = ScanRootsOverride.roots(from: ProcessInfo.processInfo.environment) { return roots }
        #endif
        return [volume.url]
    }

    /// Root name of a valid index for this volume (with several roots, the unnamed node).
    private static func expectedRootName(for volume: Volume) -> String {
        let roots = scanRoots(for: volume)
        return roots.count == 1 ? roots[0].path : ""
    }

    /// Saves the index off the main thread. It walks the live tree, so it enters as a
    /// `treeGate` reader (not cancellable: a change waits for the write to finish).
    /// Saves of the same index go one at a time (each waits for the previous one) and, right
    /// before writing, one that is no longer the latest request is skipped: the older tree
    /// never ends up on disk.
    private func saveIndex(_ result: ScanResult, to store: IndexStore, key: String) async {
        #if DEBUG
        // With AIRY_SCAN_ROOTS and without AIRY_SUPPORT_DIR, the partial tree never overwrites the real index.
        guard ScanRootsOverride.allowsSaving(environment: ProcessInfo.processInfo.environment) else { return }
        #endif
        let sequencer = saveSequencer
        let ticket = sequencer.begin(key)
        let previous = lastSave[key]
        let job = treeGate.read(cancellable: false) { () -> SaveResult in
            _ = await previous?.value
            guard sequencer.isLatest(ticket, for: key) else { return .skipped }
            do { try store.saveScan(result); return .saved } catch { return .failed(error.localizedDescription) }
        }
        lastSave[key] = job
        let outcome = await job.value
        if lastSave[key] == job { lastSave[key] = nil }
        switch outcome {
        case .skipped: return
        case .saved: dismiss(.save)
        case .failed(let saveError):
            report(.save, String(localized: "Couldn’t save the scan (\(saveError)). It looks fine now, but you’ll need to scan again next time you open Airy."))
        }
    }

    private enum SaveResult: Sendable { case saved, skipped, failed(String) }

    /// Keeps a compact summary of the new scan and compares it with the previous one. Without a stored summary (an
    /// index saved by an older Airy), the previous index read at launch is summarized instead. Only the summary file is
    /// written; a failure only means there is no "What changed" this time.
    private func recordChanges(_ result: ScanResult, previousTree: ScanResult?, store: ScanChangeStore,
                               generation: Int) async {
        #if DEBUG
        guard ScanRootsOverride.allowsSaving(environment: ProcessInfo.processInfo.environment) else { return }
        #endif
        let changes = await treeGate.read(cancellable: false, priority: .utility) { () -> ScanChanges? in
            let summary = ScanSummary.make(from: result)
            // The previous tree is no longer shown: nobody changes it any more.
            guard let record = try? store.record(summary, fallbackPrevious: { previousTree.map { ScanSummary.make(from: $0) } }),
                  let previous = record.previous else { return nil }
            return ScanChanges.compute(previous: previous, current: record.current)
        }.value
        guard generation == scanGeneration else { return }
        scanChanges = changes
    }

    func cancelScan() {
        scanTask?.cancel()
        scanGeneration += 1
        isScanning = false
        progress = nil
        detectionAfterStoppedScan()
    }

    /// A cancelled or failed scan won't bring a tree: automatic detection runs on what is shown.
    private func detectionAfterStoppedScan() {
        let wasWaiting = !detectionGate.allowsAutomatic
        if let detection = detectionGate.scanStopped(hasTree: scan != nil) {
            refreshCleanup(detection)
        } else if wasWaiting {
            // Without a tree there is nothing to detect: Cleanup stops saying "Searching…".
            isRefreshingCleanup = false
        }
    }

    /// Publishes a tree. If it is from the same volume as the one shown, the map level is kept
    /// (as deep as it still exists) instead of going back to the root.
    private func show(_ result: ScanResult, date: Date?, volume: Volume) {
        let sameRoot = navigation.root?.name == result.root.name && navigation.rootTitle == volume.name
        scan = result
        shownStore = store(for: volume)
        shownStoreKey = volume.url.path
        lastScanDate = date
        navigation = sameRoot ? navigation.restoring(in: result.root)
                              : MapNavigation(root: result.root, rootTitle: volume.name)
    }

    /// The startup disk uses the main store; each external one, its own folder.
    private func store(for volume: Volume) -> IndexStore {
        guard !volume.isStartup else { return store }
        return IndexStore(directory: directory(for: volume))
    }

    private func directory(for volume: Volume) -> URL {
        guard !volume.isStartup else { return appDirectory }
        let safeName = volume.url.path.replacingOccurrences(of: "/", with: "_")
        return appDirectory.appendingPathComponent("Volumes/\(safeName)", isDirectory: true)
    }

    /// Scan summaries of a volume, next to its index.
    private func changeStore(for volume: Volume) -> ScanChangeStore {
        ScanChangeStore(directory: directory(for: volume))
    }

    // MARK: Cleanup

    /// Detects cleanups again on the last scan and refreshes the Trash and the total freed.
    /// `.user` (default): requested by the user, at QoS `.utility`. `.automatic`: on launch or after an
    /// automatic scan, at QoS `.background`; only with the final tree (`detectionGate`).
    /// Detection reuses the index (sizes and paths) and only reads the disk for what the index lacks.
    func refreshCleanup(_ trigger: DetectionTrigger = .user) {
        let previous = cleanupTask
        previous?.cancel()
        cleanupGeneration += 1
        let generation = cleanupGeneration
        isRefreshingCleanup = true
        let root = scan?.root
        let inaccessible = scan?.inaccessible ?? []
        let classifier = classifier
        let scanner = catalog.map {
            CleanupScanner(catalog: $0, runner: runner, probes: probes, references: ReferenceChecker(),
                           classifier: classifier, scope: Self.detectionScope)
        }
        // The same priority for the waiting task: if a main-thread task (`.userInitiated`) waited
        // for it, detection would be raised to that priority.
        let priority = DetectionSchedule.priority(for: DetectionSchedule.current(trigger))
        cleanupTask = Task(priority: priority) { [weak self] in
            // One pass at a time: the cancelled one stops reading the disk before this one starts.
            await previous?.value
            guard !Task.isCancelled else { return }
            await self?.refreshCounters()
            // Reads the live tree: a cancellable `treeGate` reader (a change cancels it and waits for it).
            guard let gate = self?.treeGate else { return }
            let job = gate.read(cancellable: true, priority: priority) {
                await scanner?.findItems(scan: root, inaccessible: inaccessible) ?? []
            }
            // The detached task doesn't inherit cancellation: it is passed on by hand.
            let items = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
            // Only the latest complete detection is published: a cancelled one (partial result: e.g.
            // references not checked) or an already replaced one is never published.
            guard let self, !Task.isCancelled, !job.isCancelled, generation == self.cleanupGeneration else { return }
            self.cleanupItems = items
            self.isRefreshingCleanup = false
        }
    }

    /// Disk scope of detection: in DEBUG with `AIRY_SCAN_ROOTS`, only those roots (no projects and no
    /// catalog folders from the real home). Otherwise, everything.
    private static var detectionScope: DiskScope? {
        #if DEBUG
        if let roots = ScanRootsOverride.roots(from: ProcessInfo.processInfo.environment) {
            return DiskScope(roots: roots.map(\.path))
        }
        #endif
        return nil
    }

    /// When Cleanup opens while automatic detection is waiting for a scan: detect now (user QoS)
    /// on the index shown. With automatic detection already done or running, nothing.
    func cleanupOpened() {
        guard let trigger = detectionGate.cleanupOpened(hasTree: scan != nil) else { return }
        refreshCleanup(trigger)
    }

    /// What each item would do now (same plan as `perform`), without doing it: the confirmation sheet
    /// shows it row by row and doesn't run what is blocked.
    func preview(_ items: [CleanupItem], context: OperationContext = .user()) async -> [String: CleanupPreview] {
        guard let executor else {
            return Dictionary(items.map { ($0.id, .blocked(reason: String(localized: "Couldn’t load the cleanup catalog."))) },
                              uniquingKeysWith: { a, _ in a })
        }
        var previews: [String: CleanupPreview] = [:]
        // The sheet's preview isn't an operation: it isn't written to the log.
        // One batch: the expensive detection (versions, projects, `brew uses`) is done once for all rows.
        let pass = RevalidationPass()
        for item in items {
            previews[item.id] = await executor.preview(item, context: context, logged: false, pass: pass)
        }
        return previews
    }

    /// Runs a catalog cleanup (with full revalidation) and refreshes the counters.
    /// The UI is what confirms before calling this.
    /// `refreshesCleanup: false` for batches: the caller refreshes detection just once at the end.
    /// `pass`: the execution batch (one per confirmation), shared by all its rows.
    func perform(_ item: CleanupItem, context: OperationContext = .user(),
                 refreshesCleanup: Bool = true, pass: RevalidationPass? = nil) async -> CleanupOutcome {
        if let refusal = settingsRefusal() { return refusal }
        guard let executor else { return .failed(String(localized: "Couldn’t load the cleanup catalog.")) }
        let outcome = await executor.execute(item, context: context, pass: pass)
        switch outcome {
        case .freed, .movedToTrash: await updateTree(afterTouching: item.paths)
        case .blocked, .failed: break
        }
        await refreshCounters()
        await refreshVolumes()
        if refreshesCleanup { refreshCleanup() }
        reportAuditFailure()
        return outcome
    }

    // MARK: Quitting apps

    /// Normal quit (the app may ask to save). The UI confirms before calling this.
    func quit(_ group: AppGroup, context: OperationContext) async -> QuitOutcome {
        let outcome = await quitExecutor.quit(group, context: context)
        reportAuditFailure()
        return outcome
    }

    /// Force: only what didn't respond to the normal quit; always after a second confirmation.
    func forceQuit(_ group: AppGroup, context: OperationContext) async -> QuitOutcome {
        let outcome = await quitExecutor.forceQuit(group, context: context)
        reportAuditFailure()
        return outcome
    }

    /// If something couldn't be written to the operation log or the history, say so (don't hide it).
    private func reportAuditFailure() {
        guard let failure = operationLog.takeWriteFailure() else { return }
        report(.audit, String(localized: "Airy completed the operation, but \(failure). The exportable log may be incomplete."))
    }

    /// Moves paths chosen on the map to the Trash with all the checks of
    /// `CleanupExecutor.trashPaths`, removes them from the shown tree and refreshes like `perform`.
    /// The UI is what confirms before calling this.
    func trash(paths: [String], title: String, context: OperationContext = .user()) async -> CleanupOutcome {
        if let refusal = settingsRefusal() { return refusal }
        guard let executor else { return .failed(String(localized: "Couldn’t load the cleanup catalog.")) }
        let outcome = await executor.trashPaths(paths, title: title, context: context)
        // What is no longer in place leaves the map (also if only part of it was moved).
        // Order: (1) the nodes are looked up here (main thread, owner of the tree); (2) `treeGate`
        // cancels the cleanup detection in progress and WAITS for all readers (including the
        // index save to finish); (3) the tree is changed; (4) the index is saved again
        // without what was deleted and cleanups are detected again.
        let now = Date()
        let gone = paths.compactMap { path -> FileNode? in
            var info = stat()
            guard lstat(path, &info) != 0 else { return nil }
            touchedPaths[path] = now
            return node(atPath: path)
        }
        if !gone.isEmpty, let scan {
            // The detection in progress is invalidated (it won't publish anything) and is repeated at the end.
            cleanupTask?.cancel()
            cleanupGeneration += 1
            isRefreshingCleanup = true
            await treeGate.mutate { [weak self] in
                for node in gone { node.removeFromParent() }
                self?.treeRevision += 1
            }
            // The index is saved again without waiting (through the tree's turn): the Trash result
            // comes back right away even if saving the whole tree takes a few seconds.
            if let shownStore, self.scan?.root === scan.root {
                let key = shownStoreKey
                Task { [weak self] in await self?.saveIndex(scan, to: shownStore, key: key) }
            }
        }
        await refreshCounters()
        await refreshVolumes()
        refreshCleanup()
        reportAuditFailure()
        return outcome
    }

    /// After a cleanup, re-measures its paths (off the main thread) and updates the shown tree:
    /// what no longer exists leaves; what remains (e.g. a cache cleaned with its command, which
    /// keeps the folder) stays with its new size. That way neither the map nor cleanup detection
    /// (which prefers the tree's size) shows it with the old size. Then the index is saved
    /// again through the save turn.
    private func updateTree(afterTouching paths: [String]) async {
        guard !paths.isEmpty else { return }
        let now = Date()
        for path in paths { touchedPaths[path] = now }
        guard let scan else { return }
        let measured = await Task.detached(priority: .userInitiated) { ScanTreeRefresh.measure(paths) }.value
        guard self.scan?.root === scan.root else { return }
        // The detection in progress is invalidated (it won't publish anything); `perform` repeats it at the end.
        cleanupTask?.cancel()
        cleanupGeneration += 1
        var changed = false
        await treeGate.mutate { [weak self] in
            guard let self, self.scan?.root === scan.root else { return }
            changed = ScanTreeRefresh.apply(measured, to: scan.root)
            if changed { self.treeRevision += 1 }
        }
        if changed, let shownStore, self.scan?.root === scan.root {
            let key = shownStoreKey
            Task { [weak self] in await self?.saveIndex(scan, to: shownStore, key: key) }
        }
    }

    /// `true` if "Move to Trash…" makes sense for this path: the same rule
    /// `CleanupExecutor.trashPaths` will apply (protected, "Don't delete", caches with an official command…).
    func canOfferTrash(path: String) -> Bool {
        guard let executor else { return false }
        return !executor.wouldRefuseTrash(path: path)
    }

    /// Reason `trashPaths` would refuse this path, or `nil` if it could be offered.
    func trashRefusal(path: String) -> String? {
        guard let executor else { return String(localized: "the cleanup catalog isn’t available.") }
        return executor.unsafeTrashReason(path)
    }

    /// Node of the shown scan for an absolute path, walking down by name from the root.
    func node(atPath path: String) -> FileNode? {
        guard let root = scan?.root else { return nil }
        let rootPath = root.path
        var rest: Substring
        if rootPath == "/" {
            rest = Substring(path)
        } else if path == rootPath || path.hasPrefix(rootPath + "/") {
            rest = path.dropFirst(rootPath.count)
        } else {
            return nil
        }
        var cursor = root
        for name in rest.split(separator: "/") {
            guard let next = cursor.children.first(where: { $0.name == name && $0.aggregatedCount == 0 }) else {
                return nil
            }
            cursor = next
        }
        return cursor === root ? nil : cursor
    }

    /// Empties the Trash without asking: the UI must confirm it first.
    /// Careful: if `~/.Trash` can't be read, it falls back to Finder, which empties the Trash of
    /// **all** volumes, not just the startup disk's; the confirmation must warn about it.
    @discardableResult
    func emptyTrash(context: OperationContext = .user()) async -> CleanupOutcome {
        let outcome: CleanupOutcome
        if let refusal = settingsRefusal() {
            outcome = refusal
        } else if let executor {
            outcome = await executor.emptyTrash(context: context)
        } else {
            outcome = .failed(String(localized: "Couldn’t load the cleanup catalog."))
        }
        await refreshVolumes()
        await refreshCounters()
        refreshCleanup()
        reportAuditFailure()
        return outcome
    }

    /// Settings read from disk on every operation (never cached) and the operation log shared with `airy-mcp`.
    private var executor: CleanupExecutor? {
        let settings = settingsSession.store
        let log = operationLog
        return catalog.map {
            CleanupExecutor(runner: runner, probes: probes, store: store, catalog: $0,
                            settings: { settings.load() }, log: log, appRoots: Self.uninstallAppRoots)
        }
    }

    // MARK: Uninstaller

    /// Roots where an `.app` can be uninstalled: exactly `productionAppRoots(home:)`; only in DEBUG,
    /// `AIRY_APP_ROOTS` (paths separated by `:`) replaces them, and the inventory's too.
    static var uninstallAppRoots: [String] {
        #if DEBUG
        if let roots = debugAppRoots { return roots }
        #endif
        return ProtectionWaiver.productionAppRoots(home: NSHomeDirectory())
    }

    #if DEBUG
    static var debugAppRoots: [String]? {
        guard let raw = ProcessInfo.processInfo.environment["AIRY_APP_ROOTS"] else { return nil }
        let roots = raw.split(separator: ":").map(String.init).filter { !$0.isEmpty }
        return roots.isEmpty ? nil : roots
    }
    #endif

    private var inventoryRoots: [String] {
        #if DEBUG
        if let roots = Self.debugAppRoots { return roots }
        #endif
        return AppInventory.standardRoots(home: NSHomeDirectory())
    }

    /// Inventory and leftover reads (`brew info`, `pkgutil`, `mdfind`). With `AIRY_APP_ROOTS`
    /// (DEBUG) no real command runs.
    private var appsRunner: any CommandRunning {
        #if DEBUG
        if Self.debugAppRoots != nil { return OfflineRunner() }
        #endif
        return runner
    }

    private func uninstallGate() -> PathGate {
        let home = NSHomeDirectory()
        return PathGate(home: home, catalog: catalog,
                        userProtected: ProtectList(patterns: settings.protectedPaths, home: home))
    }

    /// Installed Homebrew casks and apps in the inventory roots, off the main thread.
    func inventorySnapshot() async -> AppInventorySnapshot {
        let runner = appsRunner, roots = inventoryRoots
        return await Task.detached(priority: .utility) {
            let casks = await HomebrewCasks.installed(runner: runner) ?? [:]
            return await AppInventory(roots: roots, casks: casks).snapshot()
        }.value
    }

    func uninstallPlan(for app: AppRecord, inventory: AppInventorySnapshot) async -> UninstallPlan {
        let finder = LeftoverFinder(home: NSHomeDirectory(), gate: uninstallGate(), runner: appsRunner,
                                    appRoots: Self.uninstallAppRoots)
        return await Task.detached(priority: .utility) { await finder.plan(for: app, inventory: inventory) }.value
    }

    private func orphanFinder() -> OrphanFinder {
        OrphanFinder(home: NSHomeDirectory(), gate: uninstallGate(), lookup: SpotlightLookup(runner: appsRunner))
    }

    func orphanScan(inventory: AppInventorySnapshot) async -> OrphanScan {
        let finder = orphanFinder()
        return await Task.detached(priority: .utility) { await finder.scan(inventory: inventory) }.value
    }

    func brokenLinks() async -> [BrokenLink] {
        await Task.detached(priority: .utility) { BrokenLinks.find() }.value
    }

    /// For the sheet: what Airy will do with a Homebrew app (`brew info`, read-only); `nil` if it doesn't come from
    /// Homebrew. The executor decides again when uninstalling.
    func caskVerdict(for app: AppRecord) async -> CaskVerdict? {
        guard app.caskToken?.isEmpty == false else { return nil }
        guard let executor else { return .fallback(reason: CaskReview.unreadableReason) }
        return await Task.detached(priority: .utility) { await executor.caskVerdict(for: app) }.value
    }

    /// Uninstalls an app through the executor's funnel. The UI is what confirms before calling this.
    func uninstall(_ request: UninstallRequest, context: OperationContext = .user()) async -> UninstallReport {
        if let refusal = settingsRefusal() { return UninstallReport(outcome: refusal) }
        guard let executor else { return UninstallReport(outcome: .failed(String(localized: "Couldn’t load the cleanup catalog."))) }
        let report = await executor.uninstall(request, context: context)
        let moved = [request.plan.app.path] + request.plan.leftovers
            .filter { request.selected.contains($0.id) && $0.kind != .receipt && $0.kind != .systemLocation }
            .map(\.path)
        switch report.outcome {
        case .freed, .movedToTrash, .failed: await updateTree(afterTouching: moved)
        case .blocked: break
        }
        await refreshCounters()
        await refreshVolumes()
        refreshCleanup()
        reportAuditFailure()
        return report
    }

    /// With a fresh inventory, only the groups that are still orphaned go to the Trash.
    func trashOrphans(_ groups: [OrphanGroup], context: OperationContext = .user()) async -> CleanupOutcome {
        if let refusal = settingsRefusal() { return refusal }
        let inventory = await inventorySnapshot()
        let finder = orphanFinder()
        let confirmable = await Task.detached(priority: .userInitiated) {
            await finder.confirmable(groups, inventory: inventory)
        }.value
        guard !confirmable.isEmpty else {
            return .blocked(reason: String(localized: "They no longer look like orphaned leftovers (or it couldn’t be checked); nothing is moved."))
        }
        return await trash(paths: confirmable.flatMap(\.paths), title: String(localized: "Orphaned leftovers"), context: context)
    }

    /// For each removal: `DuplicateFinder.confirmable` re-reads the kept file and the copies; rejected ones aren't moved and
    /// their reason comes back in `notes`; the rest go to the Trash in a single call.
    func trashDuplicates(_ removals: [DuplicateRemoval],
                         context: OperationContext = .user()) async -> (outcome: CleanupOutcome, notes: [String]) {
        if let refusal = settingsRefusal() { return (refusal, []) }
        let finder = duplicateFinder()
        let (paths, notes) = await Task.detached(priority: .userInitiated) {
            await finder.confirmable(removals)
        }.value
        guard !paths.isEmpty else {
            return (.blocked(reason: String(localized: "No copy passed the check; nothing is moved.")), notes)
        }
        return (await trash(paths: paths, title: String(localized: "Duplicates"), context: context), notes)
    }

    func removeBrokenLinks(_ links: [BrokenLink], context: OperationContext = .user()) async -> CleanupOutcome {
        if let refusal = settingsRefusal() { return refusal }
        guard let executor else { return .failed(String(localized: "Couldn’t load the cleanup catalog.")) }
        let outcome = await executor.removeBrokenLinks(links, context: context)
        reportAuditFailure()
        return outcome
    }

    /// Trash and total freed, read off the main thread.
    private func refreshCounters() async {
        let probes = probes
        let store = store
        let (trash, freed) = await Task.detached(priority: .utility) { () -> (Int64?, Result<Int64, Error>) in
            (probes.trashSizeIfReadable(), Result { try store.totalFreed() })
        }.value
        trashBytes = trash
        switch freed {
        case .success(let bytes):
            totalFreed = bytes
            totalFreedKnown = true
            dismiss(.history)
        case .failure(let error):
            // The last known value is kept and a notice is shown: never a 0 that looks real.
            totalFreedKnown = false
            report(.history, String(localized: "Couldn’t read the cleanup history (\(error.localizedDescription)). The total freed may be out of date."))
        }
    }

    // MARK: System

    func openFullDiskAccessSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Reads the mounted volumes (disk I/O) off the main thread and publishes the result.
    /// If the chosen volume is no longer mounted, falls back to the startup disk.
    func refreshVolumes() async {
        let mounted = await Task.detached(priority: .userInitiated) { Volume.mounted() }.value
        volumes = mounted
        if !mounted.contains(where: { $0.url == selectedVolume }) {
            selectedVolume = URL(fileURLWithPath: "/")
        }
    }

    /// Full Disk Access permission and volumes, both read off the main thread.
    func refreshSystemState() {
        let probes = probes
        Task { [weak self] in
            let access = await Task.detached(priority: .utility) { probes.hasFullDiskAccess() }.value
            self?.hasFullDiskAccess = access
            await self?.refreshVolumes()
        }
    }

    /// On returning to the app the permission is checked again; on mounting or ejecting disks, the list.
    private func observeSystem() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reloadSettings()
                self?.refreshSystemState()
            }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    Task { await self.refreshVolumes() }
                }
            })
        }
    }
}

#if DEBUG
/// With `AIRY_APP_ROOTS`: no real command to read apps (no `brew`, `pkgutil` or `mdfind`).
private struct OfflineRunner: CommandRunning {
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> CommandOutput {
        throw CommandError.launchFailed(executable: executable, message: "disabled with AIRY_APP_ROOTS")
    }
    func resolve(_ executable: String) async -> String? { nil }
}
#endif
