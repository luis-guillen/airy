import AppKit
import Foundation

/// Abre URLs (p. ej. `airy://…`) para pasar propuestas a la app.
public protocol URLOpening: Sendable {
    func open(_ url: URL) async -> Bool
}

/// Abre con `NSWorkspace`; si Airy está cerrada, macOS la arranca.
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

/// Todo lo que necesitan las herramientas MCP (el mismo estado en disco que la app).
/// Los ajustes se leen de nuevo en cada uso: nunca se cachean.
public struct AiryEnvironment: Sendable {
    public let home: String, paths: AppPaths
    public let catalog: Catalog?, catalogError: String?
    public let settings: SettingsStore, index: IndexStore, log: OperationLog
    public let runner: any CommandRunning, probes: any SystemProbing, processGuard: ProcessGuard
    public let references: ReferenceChecker, urlOpener: any URLOpening
    public let capacity: @Sendable () -> VolumeCapacity?

    public init(home: String, paths: AppPaths, catalog: Catalog?, catalogError: String?,
                settings: SettingsStore, index: IndexStore, log: OperationLog,
                runner: any CommandRunning, probes: any SystemProbing, processGuard: ProcessGuard,
                references: ReferenceChecker, urlOpener: any URLOpening,
                capacity: @escaping @Sendable () -> VolumeCapacity?) {
        self.home = home.count > 1 && home.hasSuffix("/") ? String(home.dropLast()) : home
        self.paths = paths
        self.catalog = catalog; self.catalogError = catalogError
        self.settings = settings; self.index = index; self.log = log
        self.runner = runner; self.probes = probes; self.processGuard = processGuard
        self.references = references; self.urlOpener = urlOpener
        self.capacity = capacity
    }

    /// Entorno real del usuario. Sin acceso a la Papelera, nunca recurre a Finder (vaciaría las
    /// papeleras de todos los volúmenes sin que la app lo avise).
    public static func live(paths: AppPaths = .standard()) -> AiryEnvironment {
        let home = NSHomeDirectory()
        let catalog: Catalog?, catalogError: String?
        do {
            catalog = try Catalog.bundled()
            catalogError = nil
        } catch {
            catalog = nil
            catalogError = "No se pudo cargar el catálogo de limpiezas (\(error))."
        }
        let runner = ProcessRunner()
        return AiryEnvironment(
            home: home, paths: paths, catalog: catalog, catalogError: catalogError,
            settings: SettingsStore(file: paths.settingsFile), index: IndexStore(directory: paths.support),
            log: OperationLog(file: paths.operationsFile), runner: runner,
            probes: SystemProbes(home: home, runner: runner, allowFinderFallback: false),
            processGuard: ProcessGuard(), references: ReferenceChecker(home: home),
            urlOpener: WorkspaceURLOpener(),
            capacity: { SystemProbes.volumeCapacity(home: home) })
    }

    /// Clasificador con los ajustes leídos ahora (`effective`: ilegibles ⇒ agentes apagados). `nil` sin catálogo.
    public func classifier() -> RiskClassifier? {
        guard let catalog else { return nil }
        return RiskClassifier(catalog: catalog, settings: settings.load().effective, home: home)
    }

    public func makeScanner() -> CleanupScanner? {
        guard let catalog else { return nil }
        return CleanupScanner(catalog: catalog, runner: runner, probes: probes, references: references,
                              home: home, classifier: classifier())
    }

    /// Ejecutor sobre el mismo historial que la app.
    /// TODO(Task 8): pasar `settings: { settings.load() }, log: log` cuando `CleanupExecutor` los admita.
    public func makeExecutor() -> CleanupExecutor? {
        guard let catalog else { return nil }
        return CleanupExecutor(runner: runner, probes: probes, store: index, catalog: catalog,
                               references: references, home: home)
    }
}
