import Foundation

public enum CleanupOutcome: Sendable, Equatable {
    /// Espacio liberado de verdad (comando oficial o Papelera vaciada).
    case freed(Int64)
    /// Enviado a la Papelera: no cuenta como liberado hasta vaciarla.
    case movedToTrash(Int64)
    case blocked(reason: String)
    case failed(String)
}

/// Ejecuta limpiezas con revalidación completa justo antes de actuar.
/// - Archivos: solo a la Papelera (`FileManager.trashItem`), nunca borrado definitivo.
/// - Cachés de herramientas: su comando oficial con `Process` y array de argumentos.
/// - Nada de privilegios de administrador en la fase 1.
public struct CleanupExecutor: Sendable {
    public static let defaultCommandTimeout: TimeInterval = 600

    private let runner: any CommandRunning
    private let probes: any SystemProbing
    private let store: IndexStore
    private let home: String
    private let catalog: Catalog?
    private let commandTimeout: TimeInterval
    private let freeSpace: @Sendable () -> Int64

    /// `catalog` (recomendado en la app) añade comprobaciones contra la ficha viva del catálogo
    /// y bloquea enviar a la Papelera lo que contenga rutas "No tocar".
    /// `freeSpace` mide el espacio disponible del volumen de `home` (inyectable en pruebas).
    public init(
        runner: any CommandRunning, probes: any SystemProbing, store: IndexStore,
        home: String = NSHomeDirectory(), catalog: Catalog? = nil,
        commandTimeout: TimeInterval = CleanupExecutor.defaultCommandTimeout,
        freeSpace: (@Sendable () -> Int64)? = nil
    ) {
        let home = home.count > 1 && home.hasSuffix("/") ? String(home.dropLast()) : home
        self.runner = runner
        self.probes = probes
        self.store = store
        self.home = home
        self.catalog = catalog
        self.commandTimeout = commandTimeout
        self.freeSpace = freeSpace ?? { SystemProbes.availableCapacity(home: home) }
    }

    // MARK: - API

    public func execute(_ item: CleanupItem) async -> CleanupOutcome {
        if let reason = blockReason(for: item) { return .blocked(reason: reason) }
        switch item.entry.cleanup {
        case .info:
            return .blocked(reason: "Este elemento es solo informativo.")
        case .trash:
            return trash(item.paths, title: item.title, mustBeClosed: item.entry.mustBeClosed)
        case .command(let executable, let arguments, _):
            return await runCommand(executable: executable, arguments: arguments, title: item.title)
        }
    }

    public func emptyTrash() async -> CleanupOutcome {
        do {
            let bytes = try probes.emptyTrash()
            record(title: "Vaciar Papelera", bytes: bytes, wentToTrash: false)
            return .freed(bytes)
        } catch {
            return .failed("No se pudo vaciar la Papelera: \(error.localizedDescription)")
        }
    }

    /// Envía rutas sueltas (elegidas en el mapa o propuestas por la IA) a la Papelera.
    /// Si una sola ruta no es segura, no se mueve ninguna.
    public func trashPaths(_ paths: [String], title: String) async -> CleanupOutcome {
        trash(paths, title: title, mustBeClosed: [])
    }

    // MARK: - Revalidación

    private func blockReason(for item: CleanupItem) -> String? {
        if case .info = item.entry.cleanup { return "Este elemento es solo informativo." }
        if !item.usedBy.isEmpty { return "Lo usa un proyecto: \(item.usedBy.joined(separator: ", "))." }
        if item.risk == .doNotTouch || item.entry.risk == .doNotTouch { return "Marcado como «No tocar»." }
        if let live = catalog?.entry(id: item.entry.id) {
            if live.risk == .doNotTouch { return "Marcado como «No tocar»." }
            if live.cleanup != item.entry.cleanup { return "La acción no coincide con el catálogo." }
        }
        for path in item.paths
        where RiskPolicy.effectiveRisk(path: path, home: home, catalog: item.entry.risk, ai: nil) == .doNotTouch {
            return "Marcado como «No tocar»: \(path)."
        }
        return openAppsReason(item.entry.mustBeClosed)
    }

    private func openAppsReason(_ bundleIDs: [String]) -> String? {
        guard !bundleIDs.isEmpty else { return nil }
        let running = probes.runningBundleIDs()
        let open = bundleIDs.filter { running.contains($0) }
        return open.isEmpty ? nil : "Cierra primero: \(open.joined(separator: ", "))."
    }

    // MARK: - Papelera

    private func trash(_ paths: [String], title: String, mustBeClosed: [String]) -> CleanupOutcome {
        guard !paths.isEmpty else { return .failed("No hay nada que enviar a la Papelera.") }
        var apps = mustBeClosed
        for path in paths {
            if let reason = unsafeTrashReason(path) { return .blocked(reason: reason) }
            if let entry = catalog?.match(path: path, home: home) { apps.append(contentsOf: entry.mustBeClosed) }
        }
        if let reason = openAppsReason(apps) { return .blocked(reason: reason) }

        let sizes = paths.map { AllocatedSize.of($0) ?? 0 }
        var moved: Int64 = 0
        for (path, size) in zip(paths, sizes) {
            do {
                // `trashItem` mueve la entrada en sí: un enlace simbólico va a la Papelera, no su destino.
                try FileManager.default.trashItem(at: URL(fileURLWithPath: path, isDirectory: false),
                                                  resultingItemURL: nil)
                moved += size
            } catch {
                if moved > 0 { record(title: title, bytes: moved, wentToTrash: true) }
                return .failed("No se pudo mover \(path) a la Papelera: \(error.localizedDescription)")
            }
        }
        record(title: title, bytes: moved, wentToTrash: true)
        return .movedToTrash(moved)
    }

    /// `nil` si la ruta se puede enviar a la Papelera; si no, el motivo.
    func unsafeTrashReason(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return "Ruta no absoluta: \(path)." }
        guard path != "/" else { return "No se puede tocar la raíz del disco." }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            return "Ruta no canónica: \(path)."
        }
        var info = stat()
        guard lstat(path, &info) == 0 else { return "No existe: \(path)." }

        // Se comprueba la ruta tal cual y con su carpeta padre resuelta (por si pasa por un enlace).
        var forms = [RiskPolicy.canonical(path)]
        let parent = (path as NSString).deletingLastPathComponent
        if let real = realpath(parent, nil) {
            let resolvedParent = String(cString: real)
            free(real)
            forms.append(RiskPolicy.canonical(resolvedParent + "/" + (path as NSString).lastPathComponent))
        }
        let protected = protectedLocations()
        for form in forms {
            if RiskPolicy.isInside(form, root: "/system") { return "Ruta del sistema: \(path)." }
            for location in protected where form == location || RiskPolicy.isInside(location, root: form) {
                return "Carpeta protegida: \(path)."
            }
            if RiskPolicy.minimumRisk(forPath: form, home: home) == .doNotTouch { return "Marcado como «No tocar»: \(path)." }
        }

        if let catalog {
            if let entry = catalog.match(path: path, home: home), entry.risk == .doNotTouch {
                return "Marcado como «No tocar»: \(path)."
            }
            // Tampoco una carpeta que contenga algo "No tocar" (p. ej. el runtime en uso de Codex).
            for entry in catalog.entries where entry.risk == .doNotTouch {
                for pattern in entry.paths {
                    for match in CleanupScanner.expand(pattern, home: home)
                    where forms.contains(where: { RiskPolicy.isInside(RiskPolicy.canonical(match), root: $0) }) {
                        return "Contiene algo marcado como «No tocar»: \(match)."
                    }
                }
            }
        }
        return nil
    }

    /// Ubicaciones que nunca se envían a la Papelera, ni ellas ni sus carpetas superiores.
    private func protectedLocations() -> [String] {
        var homes = [home]
        if let real = realpath(home, nil) {
            homes.append(String(cString: real))
            free(real)
        }
        var locations = [
            "/", "/system", "/users", "/applications", "/library", "/usr", "/bin", "/sbin", "/etc",
            "/var", "/private", "/private/var", "/private/etc", "/opt", "/volumes", "/cores",
        ]
        for base in homes.map(RiskPolicy.canonical) {
            locations.append(base)
            for name in RiskPolicy.personalRoots + ["Library", "Applications", ".Trash"] {
                locations.append(RiskPolicy.canonical(base + "/" + name))
            }
        }
        return locations
    }

    // MARK: - Comandos

    private func runCommand(executable: String, arguments: [String], title: String) async -> CleanupOutcome {
        guard let resolved = await runner.resolve(executable) else {
            return .failed("No se encontró \(executable) en este Mac.")
        }
        let before = freeSpace()
        let output: CommandOutput
        do {
            output = try await runner.run(resolved, arguments, timeout: commandTimeout)
        } catch {
            return .failed(String(describing: error))
        }
        guard output.status == 0 else {
            let detail = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed("\(executable) terminó con código \(output.status)\(detail.isEmpty ? "" : ": \(detail)")")
        }
        let freed = max(0, freeSpace() - before)
        record(title: title, bytes: freed, wentToTrash: false)
        return .freed(freed)
    }

    private func record(title: String, bytes: Int64, wentToTrash: Bool) {
        try? store.append(CleanupRecord(date: Date(), title: title, bytes: bytes, wentToTrash: wentToTrash))
    }
}
