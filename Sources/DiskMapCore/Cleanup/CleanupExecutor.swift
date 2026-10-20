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
    public static let referenceTimeout: TimeInterval = 10

    private let runner: any CommandRunning
    private let probes: any SystemProbing
    private let store: IndexStore
    private let catalog: Catalog
    private let references: ReferenceChecker
    private let home: String
    private let commandTimeout: TimeInterval
    private let freeSpace: @Sendable () -> Int64

    /// `catalog` es obligatorio: toda acción se decide con la ficha viva del catálogo, nunca con la
    /// copia que trae el elemento. `references` (por defecto, las carpetas de proyectos de `home`)
    /// vuelve a comprobar si un modelo está en uso. `freeSpace` mide el espacio disponible del
    /// volumen de `home` (inyectable en pruebas).
    public init(
        runner: any CommandRunning, probes: any SystemProbing, store: IndexStore, catalog: Catalog,
        references: ReferenceChecker? = nil, home: String = NSHomeDirectory(),
        commandTimeout: TimeInterval = CleanupExecutor.defaultCommandTimeout,
        freeSpace: (@Sendable () -> Int64)? = nil
    ) {
        let home = home.count > 1 && home.hasSuffix("/") ? String(home.dropLast()) : home
        self.runner = runner
        self.probes = probes
        self.store = store
        self.catalog = catalog
        self.references = references ?? ReferenceChecker(home: home)
        self.home = home
        self.commandTimeout = commandTimeout
        self.freeSpace = freeSpace ?? { SystemProbes.availableCapacity(home: home) }
    }

    // MARK: - API

    public func execute(_ item: CleanupItem) async -> CleanupOutcome {
        // La ficha viva manda: método, apps que cerrar y riesgo salen del catálogo, no del elemento.
        let parts = item.id.split(separator: ":", maxSplits: 1).map(String.init)
        guard let catalogID = parts.first, let live = catalog.entry(id: catalogID) else {
            return .blocked(reason: "No está en el catálogo: no se ejecuta nada.")
        }
        let title = parts.count > 1 ? "\(live.title): \(parts[1])" : live.title
        if let reason = blockReason(for: item, live: live) { return .blocked(reason: reason) }
        switch live.cleanup {
        case .info:
            return .blocked(reason: "Este elemento es solo informativo.")
        case .trash:
            guard !item.paths.isEmpty else { return .failed("No hay nada que enviar a la Papelera.") }
            let allowed = Set(live.paths.flatMap { CleanupScanner.expand($0, home: home) }.map(RiskPolicy.canonical))
            for path in item.paths where !allowed.contains(RiskPolicy.canonical(path)) {
                return .blocked(reason: "La ruta no corresponde a «\(live.title)»: \(path).")
            }
            return await trash(item.paths, title: title, mustBeClosed: live.mustBeClosed + item.entry.mustBeClosed)
        case .command(let executable, let arguments, _):
            return await runCommand(executable: executable, arguments: arguments, title: title)
        }
    }

    /// Vacía la Papelera (solo tras pulsar el usuario "Vaciar Papelera").
    /// Ojo: si `~/.Trash` no se puede leer, `SystemProbing.emptyTrash` recurre a Finder, que vacía
    /// las papeleras de todos los volúmenes; la interfaz lo advierte antes de confirmar.
    public func emptyTrash() async -> CleanupOutcome {
        do {
            let bytes = try await probes.emptyTrash()
            record(title: "Vaciar Papelera", bytes: bytes, wentToTrash: false)
            return .freed(bytes)
        } catch {
            return .failed("No se pudo vaciar la Papelera: \(error.localizedDescription)")
        }
    }

    /// Envía rutas sueltas (elegidas en el mapa o propuestas por la IA) a la Papelera.
    /// Si una sola ruta no es segura, no se mueve ninguna.
    public func trashPaths(_ paths: [String], title: String) async -> CleanupOutcome {
        guard !paths.isEmpty else { return .failed("No hay nada que enviar a la Papelera.") }
        return await trash(paths, title: title, mustBeClosed: [])
    }

    // MARK: - Revalidación

    private func blockReason(for item: CleanupItem, live: CatalogEntry) -> String? {
        if case .info = live.cleanup { return "Este elemento es solo informativo." }
        if !item.usedBy.isEmpty { return "Lo usa: \(item.usedBy.joined(separator: ", "))." }
        if live.risk == .doNotTouch || item.risk == .doNotTouch || item.entry.risk == .doNotTouch {
            return "Marcado como «No tocar»."
        }
        for path in item.paths
        where RiskPolicy.effectiveRisk(path: path, home: home, catalog: live.risk, ai: nil) == .doNotTouch {
            return "Marcado como «No tocar»: \(path)."
        }
        return openAppsReason(live.mustBeClosed + item.entry.mustBeClosed)
    }

    private func openAppsReason(_ bundleIDs: [String]) -> String? {
        guard !bundleIDs.isEmpty else { return nil }
        let running = probes.runningBundleIDs()
        var open: [String] = []
        for id in bundleIDs where running.contains(id) && !open.contains(id) { open.append(id) }
        return open.isEmpty ? nil : "Cierra primero: \(open.joined(separator: ", "))."
    }

    // MARK: - Papelera

    private func trash(_ paths: [String], title: String, mustBeClosed: [String]) async -> CleanupOutcome {
        var apps = mustBeClosed
        for path in paths {
            if let reason = unsafeTrashReason(path) { return .blocked(reason: reason) }
            // Apps de cualquier ficha relacionada (la ruta está dentro de ella o la contiene).
            let forms = Self.forms(of: path)
            for entry in catalog.entries where !entry.mustBeClosed.isEmpty
            && entry.paths.contains(where: { pattern in forms.contains { related($0, pattern) } }) {
                apps.append(contentsOf: entry.mustBeClosed)
            }
        }
        if let reason = await referenceReason(paths) { return .blocked(reason: reason) }
        if let reason = openAppsReason(apps) { return .blocked(reason: reason) }

        var moved: Int64 = 0
        for path in paths {
            // Se revalida justo antes de cada movimiento (la ruta pudo cambiar mientras tanto).
            if let reason = unsafeTrashReason(path) {
                if moved > 0 { record(title: title, bytes: moved, wentToTrash: true) }
                return .blocked(reason: reason)
            }
            let size = AllocatedSize.of(path) ?? 0
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

        let forms = Self.forms(of: path)
        let homes = homeForms()
        for form in forms {
            if let reason = RiskPolicy.trashRefusal(forCanonicalPath: form, homes: homes) {
                return "\(reason) No se envía a la Papelera: \(path)."
            }
            if RiskPolicy.minimumRisk(forPath: form, home: home) == .doNotTouch {
                return "Marcado como «No tocar»: \(path)."
            }
        }
        if let entry = catalog.match(path: path, home: home), entry.risk == .doNotTouch {
            return "Marcado como «No tocar»: \(path)."
        }
        // Las cachés con comando oficial se limpian solo con ese comando, nunca a mano.
        for entry in catalog.entries {
            guard case .command = entry.cleanup else { continue }
            for pattern in entry.paths where forms.contains(where: { related($0, pattern) }) {
                return "«\(entry.title)» se limpia solo con su comando oficial: \(path)."
            }
        }
        // Ni dentro de un patrón "No tocar" ni una carpeta que lo contenga (exista o no ahora).
        for entry in catalog.entries where entry.risk == .doNotTouch {
            for pattern in entry.paths where forms.contains(where: { related($0, pattern) }) {
                return "Contiene o está dentro de algo marcado como «No tocar» (\(entry.title)): \(path)."
            }
        }
        return nil
    }

    /// La ruta tal cual y con su carpeta padre resuelta (por si pasa por un enlace), canónicas.
    private static func forms(of path: String) -> [String] {
        var forms = [RiskPolicy.canonical(path)]
        let parent = (path as NSString).deletingLastPathComponent
        if let real = realpath(parent, nil) {
            let resolvedParent = String(cString: real)
            free(real)
            let resolved = RiskPolicy.canonical(resolvedParent + "/" + (path as NSString).lastPathComponent)
            if resolved != forms[0] { forms.append(resolved) }
        }
        return forms
    }

    /// `true` si la ruta canónica está dentro del patrón (o lo iguala) o es una carpeta superior suya.
    private func related(_ canonicalPath: String, _ pattern: String) -> Bool {
        var expanded = pattern
        if pattern == "~" { expanded = home } else if pattern.hasPrefix("~/") { expanded = home + pattern.dropFirst(1) }
        let patternParts = RiskPolicy.canonical(expanded).split(separator: "/").map(String.init)
        let pathParts = canonicalPath.split(separator: "/").map(String.init)
        return zip(patternParts, pathParts).allSatisfy { pat, name in
            pat.contains("*") ? fnmatch(pat, name, 0) == 0 : pat == name
        }
    }

    /// Si alguna ruta toca algo con comprobación de referencias (modelos de Hugging Face…),
    /// se vuelve a buscar en los proyectos: si se usa, no se toca.
    private func referenceReason(_ paths: [String]) async -> String? {
        var needles: [String] = []
        for path in paths {
            let forms = Self.forms(of: path)
            for entry in catalog.entries where entry.referenceCheck != nil {
                for pattern in entry.paths {
                    for match in CleanupScanner.expand(pattern, home: home) {
                        let canonicalMatch = RiskPolicy.canonical(match)
                        guard forms.contains(where: {
                            RiskPolicy.isInside($0, root: canonicalMatch) || RiskPolicy.isInside(canonicalMatch, root: $0)
                        }), let needle = entry.referenceNeedle(forMatchedFolder: match) else { continue }
                        if !needles.contains(needle) { needles.append(needle) }
                    }
                }
            }
        }
        guard !needles.isEmpty else { return nil }
        let found = await references.references(toAny: needles, timeout: Self.referenceTimeout)
        let users = needles.flatMap { found[$0] ?? [] }
        return users.isEmpty ? nil : "Lo usa: \(users.joined(separator: ", "))."
    }

    /// `home` tal cual y resuelto (por si pasa por un enlace).
    private func homeForms() -> [String] {
        var homes = [home]
        if let real = realpath(home, nil) {
            homes.append(String(cString: real))
            free(real)
        }
        return homes
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
