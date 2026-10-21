import AppKit
import Foundation

/// Opens URLs (e.g. `airy://…`) to hand proposals to the app.
public protocol URLOpening: Sendable {
    func open(_ url: URL) async -> Bool
}

/// Opens with `NSWorkspace`; if Airy is closed, macOS launches it.
public struct WorkspaceURLOpener: URLOpening {
    public init() {}

    public func open(_ url: URL) async -> Bool {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            _ = try await NSWorkspace.shared.open(url, configuration: configuration)
            return true
        } catch {
            return false
        }
    }
}

/// Everything the MCP tools need (the same on-disk state as the app).
/// Settings are read again on every use: they are never cached.
public struct AiryEnvironment: Sendable {
    public let home: String, paths: AppPaths
    public let catalog: Catalog?, catalogError: String?
    public let settings: SettingsStore, index: IndexStore, log: OperationLog
    public let runner: any CommandRunning, probes: any SystemProbing, processGuard: ProcessGuard
    public let references: ReferenceChecker, urlOpener: any URLOpening
    public let capacity: @Sendable () -> VolumeCapacity?
    /// Performance: it only measures when a tool calls it.
    public let sampler: any PerformanceSampling
    public let appCatalog: AppCatalog?
    /// Uninstaller (read-only and proposals): inventory roots, last use, installed ids and
    /// whether an app is open (nothing is ever quit from here).
    public let appRoots: [String]
    public let usage: any AppUsageReading
    public let bundleLookup: any BundleIDLookup
    public let runningApps: any AppQuitting
    public let fileUsage: any FileUsageReading

    public init(home: String, paths: AppPaths, catalog: Catalog?, catalogError: String?,
                settings: SettingsStore, index: IndexStore, log: OperationLog,
                runner: any CommandRunning, probes: any SystemProbing, processGuard: ProcessGuard,
                references: ReferenceChecker, urlOpener: any URLOpening,
                capacity: @escaping @Sendable () -> VolumeCapacity?,
                sampler: any PerformanceSampling = LiveSampler(), appCatalog: AppCatalog? = try? AppCatalog.bundled(language: AiryLanguage.source),
                appRoots: [String]? = nil, usage: any AppUsageReading = SpotlightUsage(),
                bundleLookup: (any BundleIDLookup)? = nil, runningApps: any AppQuitting = WorkspaceQuitter(),
                fileUsage: any FileUsageReading = SpotlightFileUsage()) {
        self.home = home.count > 1 && home.hasSuffix("/") ? String(home.dropLast()) : home
        self.paths = paths
        self.catalog = catalog; self.catalogError = catalogError
        self.settings = settings; self.index = index; self.log = log
        self.runner = runner; self.probes = probes; self.processGuard = processGuard
        self.references = references; self.urlOpener = urlOpener
        self.capacity = capacity
        self.sampler = sampler; self.appCatalog = appCatalog
        self.appRoots = appRoots ?? AppInventory.standardRoots(home: self.home)
        self.usage = usage
        self.bundleLookup = bundleLookup ?? SpotlightLookup(runner: runner)
        self.runningApps = runningApps
        self.fileUsage = fileUsage
    }

    /// Homebrew casks (only `brew list`, read-only) and apps from `appRoots`.
    public func inventorySnapshot() async -> AppInventorySnapshot {
        let casks = await HomebrewCasks.installed(runner: runner) ?? [:]
        return await AppInventory(roots: appRoots, usage: usage, casks: casks).snapshot()
    }

    /// Gatekeeper with the "Protect this" list read now.
    public func pathGate() -> PathGate {
        PathGate(home: home, catalog: catalog,
                 userProtected: ProtectList(patterns: settings.load().effective.protectedPaths, home: home))
    }

    /// Leftover finder with the production uninstall roots (the app validates again on confirmation).
    public func leftoverFinder() -> LeftoverFinder {
        LeftoverFinder(home: home, gate: pathGate(), runner: runner,
                       appRoots: ProtectionWaiver.productionAppRoots(home: home))
    }

    /// The user's real environment. Without access to the Trash, it never falls back to Finder (it would empty the
    /// trash of every volume without the app warning about it). The MCP always works in English.
    public static func live(paths: AppPaths = .standard()) -> AiryEnvironment {
        let home = NSHomeDirectory()
        let catalog: Catalog?, catalogError: String?
        do {
            catalog = try Catalog.bundled(language: AiryLanguage.source)
            catalogError = nil
        } catch {
            catalog = nil
            catalogError = "Could not load the cleanup catalog (\(error))."
        }
        let runner = ProcessRunner()
        return AiryEnvironment(
            home: home, paths: paths, catalog: catalog, catalogError: catalogError,
            settings: SettingsStore(file: paths.settingsFile), index: IndexStore(directory: paths.support),
            log: OperationLog(file: paths.operationsFile), runner: runner,
            probes: SystemProbes(home: home, runner: runner, allowFinderFallback: false),
            processGuard: ProcessGuard(), references: ReferenceChecker(home: home),
            urlOpener: WorkspaceURLOpener(),
            capacity: { SystemProbes.volumeCapacity(home: home) },
            sampler: LiveSampler(runner: runner))
    }

    /// Classifier with the settings read now (`effective`: unreadable ⇒ agents off). `nil` without a catalog.
    public func classifier() -> RiskClassifier? {
        guard let catalog else { return nil }
        return RiskClassifier(catalog: catalog, settings: settings.load().effective, home: home)
    }

    public func makeScanner() -> CleanupScanner? {
        guard let catalog else { return nil }
        return CleanupScanner(catalog: catalog, runner: runner, probes: probes, references: references,
                              home: home, classifier: classifier())
    }

    /// Executor on the same history, settings (read on every operation) and log as the app.
    public func makeExecutor() -> CleanupExecutor? {
        guard let catalog else { return nil }
        let store = settings
        return CleanupExecutor(runner: runner, probes: probes, store: index, catalog: catalog,
                               references: references, home: home, settings: { store.load() }, log: log,
                               processGuard: processGuard)
    }
}
