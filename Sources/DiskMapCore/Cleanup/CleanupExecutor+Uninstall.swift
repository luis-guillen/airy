import Foundation

public struct UninstallRequest: Sendable, Equatable, Identifiable {
    public let plan: UninstallPlan
    /// Ids de `Leftover`.
    public let selected: Set<String>
    public var id: String { plan.id }

    public init(plan: UninstallPlan, selected: Set<String>) {
        self.plan = plan
        self.selected = selected
    }
}

public struct UninstallReport: Sendable, Equatable {
    /// `.movedToTrash(trashed)` si algo fue a la Papelera; si no, `.freed(freed)`; o `.blocked`/`.failed`.
    public var outcome: CleanupOutcome
    public var trashedBytes: Int64
    public var freedBytes: Int64
    /// Pasos que fallaron sin parar el resto (español).
    public var notes: [String]

    public init(outcome: CleanupOutcome, trashedBytes: Int64 = 0, freedBytes: Int64 = 0, notes: [String] = []) {
        self.outcome = outcome
        self.trashedBytes = trashedBytes
        self.freedBytes = freedBytes
        self.notes = notes
    }
}

extension CleanupExecutor {
    static let agentsCannotUninstall = "Los agentes no pueden desinstalar apps; solo proponerlo en Airy."
    static let quitTimeout: Duration = .seconds(30)
    static let launchctlTimeout: TimeInterval = 15
    static let brewTimeout: TimeInterval = 600
    static let brewUnfinishedNote = "Homebrew no pudo terminar (quizá pidió contraseña)."
    static let receiptCancelledNote = "Cancelaste la contraseña: el registro de instalación se queda."

    /// Desinstala una app por el embudo. Orden: todas las comprobaciones (agente, plan, dispensa, `.app`,
    /// cerrar, `.app` otra vez, restos, revisión del cask) y solo después, en orden: Homebrew (sin `--zap`) →
    /// `launchctl bootout` → Papelera del `.app` → restos → recibos. Cada `blocked` deja todo como estaba.
    public func uninstall(_ request: UninstallRequest, context: OperationContext = .user()) async -> UninstallReport {
        let app = request.plan.app
        var notes: [String] = []
        var trashed: [String] = []
        var trashedBytes: Int64 = 0
        var freedBytes: Int64 = 0
        var brewCommand: [String]?

        func finish(_ outcome: CleanupOutcome) -> UninstallReport {
            if trashedBytes > 0 || !trashed.isEmpty {
                record(title: app.name, bytes: trashedBytes, wentToTrash: true, context: context)
            }
            if freedBytes > 0 { record(title: app.name, bytes: freedBytes, wentToTrash: false, context: context) }
            var final = outcome
            if case .blocked = outcome {} else if case .failed = outcome {} else {
                final = trashed.isEmpty ? .freed(freedBytes) : .movedToTrash(trashedBytes)
            }
            let (name, message): (String, String?) = switch final {
            case .freed: ("freed", nil)
            case .movedToTrash: ("moved_to_trash", nil)
            case .blocked(let reason): (trashed.isEmpty ? "blocked" : "partial", reason)
            case .failed(let error): (trashed.isEmpty ? "failed" : "partial", error)
            }
            let joined = ([message].compactMap { $0 } + notes).joined(separator: " · ")
            appendLog(context, action: "uninstall", itemID: app.bundleID, title: app.name, paths: trashed,
                      command: brewCommand, dryRun: false, outcome: name, bytes: trashedBytes + freedBytes,
                      message: joined.isEmpty ? nil : joined)
            return UninstallReport(outcome: final, trashedBytes: trashedBytes, freedBytes: freedBytes, notes: notes)
        }

        // 1–3. Agentes, plan, dispensa y el `.app`.
        if context.isAgent { return finish(.blocked(reason: Self.agentsCannotUninstall)) }
        let load = settings()
        if load.isUnreadable { return finish(.blocked(reason: Self.unreadableSettingsReason)) }
        if let refusal = request.plan.refusal { return finish(.blocked(reason: refusal)) }
        let roots = appRoots ?? ProtectionWaiver.productionAppRoots(home: home)
        guard let waiver = ProtectionWaiver.uninstall(app, appRoots: roots) else {
            return finish(.blocked(reason: "Airy no puede desinstalar «\(app.name)»."))
        }
        let validatedApp: ValidatedPath
        switch gate(load).validate(app.path, waiver: waiver) {
        case .failure(let refusal): return finish(.blocked(reason: refusal.reason))
        case .success(let ok): validatedApp = ok
        }

        // 4. Cerrar (normal, nunca forzado).
        let quitIDs = uniqueIDs([app.bundleID] + app.helperBundleIDs)
        var open: [String] = []
        for id in quitIDs {
            guard let running = quitter.isRunning(bundleID: id) else {
                return finish(.blocked(reason: "No se pudo comprobar si «\(app.name)» está abierta; Airy no sigue."))
            }
            if running { open.append(id) }
        }
        for id in open {
            switch await quitter.quit(bundleID: id, timeout: Self.quitTimeout) {
            case .notRunning, .quit: continue
            case .stillRunning, .unknown:
                return finish(.blocked(
                    reason: "«\(app.name)» sigue abierta (quizá te pide guardar algo). Ciérrala y vuelve a intentarlo."))
            }
        }

        // Comprobaciones tras cerrar, antes de tocar nada (F6): el `.app` y cada resto seleccionado.
        let gateNow = gate(settings())
        if case .failure(let refusal) = gateNow.validate(app.path, waiver: waiver) {
            return finish(.blocked(reason: refusal.reason))
        }
        if let refusal = gateNow.confirmUnchanged(validatedApp) { return finish(.blocked(reason: refusal.reason)) }

        let selected = request.plan.leftovers.filter { request.selected.contains($0.id) && $0.canSelect }
        let pathLeftovers = selected.filter { $0.kind != .receipt && $0.kind != .systemLocation }
        var toTrash: [(leftover: Leftover, validated: ValidatedPath)] = []
        for leftover in pathLeftovers where exists(leftover.path) {
            switch gateNow.validate(leftover.path, waiver: waiver) {
            case .failure(let refusal): notes.append("No se toca \(leftover.path): \(refusal.reason)")
            case .success(let ok): toTrash.append((leftover, ok))
            }
        }

        // Homebrew: nunca `--zap` (los restos solo salen de la lista de Airy, ya validada, a la Papelera). Antes
        // de usar `brew uninstall --cask`, Airy lee qué haría el cask (solo lectura); si hay algo que no puede
        // comprobar, o no puede leerlo, la app sigue el camino normal: el `.app` a la Papelera con la dispensa.
        var brew: String?
        if let review = await reviewCask(app, gate: gateNow) {
            brew = review.brew
            if case .fallback(let reason) = review.verdict { notes.append(reason) }
        }

        // 5. Homebrew (borra el `.app` directamente, sin Papelera, y ejecuta los pasos ya revisados del cask).
        if let brew, let token = app.caskToken {
            let arguments = ["uninstall", "--cask", token]
            if let reason = CommandPolicy.refusal(executable: brew, arguments: arguments) {
                return finish(.blocked(reason: reason))
            }
            brewCommand = [brew] + arguments
            var measured: [String: Int64] = [:]
            for path in [app.path] + pathLeftovers.map(\.path) where exists(path) {
                measured[path] = AllocatedSize.of(path) ?? 0
            }
            let output: CommandOutput
            do {
                // Sin entrada estándar (`/dev/null`): si pide contraseña, falla en vez de esperar.
                output = try await runner.run(brew, arguments, timeout: Self.brewTimeout)
            } catch {
                notes.append(Self.brewUnfinishedNote)
                return finish(.failed("Homebrew no pudo desinstalarla: \(String(String(describing: error).prefix(300)))"))
            }
            guard output.status == 0 else {
                notes.append(Self.brewUnfinishedNote)
                let detail = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)
                return finish(.failed("Homebrew no pudo desinstalarla: \(detail)"))
            }
            freedBytes = measured.filter { !exists($0.key) }.values.reduce(0, +)
        }

        // 6. Detener los agentes de inicio seleccionados (solo los que pasaron la validación). Después de
        // Homebrew: si Homebrew falla, la app sigue instalada con sus agentes en marcha.
        for item in toTrash where item.leftover.kind == .launchAgent {
            guard let label = item.leftover.launchLabel, !label.isEmpty else { continue }
            do {
                let output = try await runner.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"],
                                                  timeout: Self.launchctlTimeout)
                if output.status != 0 {
                    let detail = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    notes.append("No se pudo detener \(label): \(detail).")
                }
            } catch {
                notes.append("No se pudo detener \(label): \(error).")
            }
        }

        // 7. El `.app` a la Papelera (si sigue ahí), comprobado otra vez justo antes.
        if exists(app.path) {
            beforeMove?(app.path)
            let gateLast = gate(settings())
            if case .failure(let refusal) = gateLast.validate(app.path, waiver: waiver) {
                return finish(.blocked(reason: refusal.reason))
            }
            if let refusal = gateLast.confirmUnchanged(validatedApp) { return finish(.blocked(reason: refusal.reason)) }
            do {
                trashedBytes += try trashValidated(validatedApp)
                trashed.append(app.path)
            } catch {
                return finish(.failed("No se pudo mover \(app.path) a la Papelera: \(error.localizedDescription)"))
            }
        }

        // 8. Restos seleccionados que aún existan.
        for item in toTrash where exists(item.leftover.path) {
            let path = item.leftover.path
            beforeMove?(path)
            let gateLast = gate(settings())
            if case .failure(let refusal) = gateLast.validate(path, waiver: waiver) {
                notes.append("No se toca \(path): \(refusal.reason)")
                continue
            }
            if let refusal = gateLast.confirmUnchanged(item.validated) {
                notes.append("No se toca \(path): \(refusal.reason)")
                continue
            }
            do {
                trashedBytes += try trashValidated(item.validated)
                trashed.append(path)
            } catch {
                notes.append("No se pudo mover \(path) a la Papelera: \(error.localizedDescription)")
            }
        }

        // 9. Recibos: una sola petición de contraseña.
        let receipts = selected.filter { $0.kind == .receipt }.map(\.path)
        if !receipts.isEmpty {
            let outcome = await privileged.run(
                receipts.map { ["/usr/sbin/pkgutil", "--forget", $0] },
                prompt: "Airy necesita tu contraseña para borrar el registro de instalación de «\(app.name)».")
            switch outcome {
            case .ok: break
            case .cancelled: notes.append(Self.receiptCancelledNote)
            case .failed(let reason): notes.append("No se pudo borrar el registro de instalación: \(reason)")
            }
        }

        // 10. Registro.
        return finish(.freed(freedBytes))
    }

    /// Revisión del cask antes de usar Homebrew; `nil` si la app no viene de Homebrew. `brew` es la ruta de
    /// Homebrew solo si el veredicto es `.useBrew`.
    func reviewCask(_ app: AppRecord, gate: PathGate) async -> (verdict: CaskVerdict, brew: String?)? {
        guard let token = app.caskToken, !token.isEmpty else { return nil }
        let unreadable = (verdict: CaskVerdict.fallback(reason: CaskReview.unreadableReason), brew: String?.none)
        guard CaskReview.isValidToken(token) else { return unreadable }
        guard let brew = await runner.resolve("brew") else {
            return (.fallback(reason: CaskReview.brewMissingReason), nil)
        }
        let arguments = CaskReview.infoArguments(token: token)
        guard CommandPolicy.refusal(executable: brew, arguments: arguments) == nil else { return unreadable }
        let output: CommandOutput
        do {
            output = try await runner.run(brew, arguments, timeout: CaskReview.infoTimeout)
        } catch {
            return unreadable
        }
        guard output.status == 0 else { return unreadable }
        let verdict = CaskReview.verdict(json: output.stdout, token: token, app: app, home: home,
                                         refusal: { gate.refusalWithoutWaiver($0) })
        return (verdict, verdict.usesBrew ? brew : nil)
    }

    /// Para la hoja de confirmación: qué hará Airy con una app de Homebrew (`nil` si no viene de Homebrew).
    /// El ejecutor lo vuelve a decidir al desinstalar.
    public func caskVerdict(for app: AppRecord) async -> CaskVerdict? {
        let load = settings()
        guard app.caskToken?.isEmpty == false else { return nil }
        if load.isUnreadable { return .fallback(reason: CaskReview.unreadableReason) }
        return await reviewCask(app, gate: gate(load))?.verdict
    }

    // MARK: - Enlaces rotos

    /// Agentes ⇒ `.blocked`. Vuelve a llamar a `BrokenLinks.find` y solo actúa sobre los que siguen rotos con el
    /// mismo destino (nombres sin "/", fuera de «Proteger esto»). Si alguno necesita permisos: una sola petición
    /// de contraseña; si no, el `find` normal. Resultado `.freed(0)`; registro `"remove_broken_links"`.
    public func removeBrokenLinks(_ links: [BrokenLink], context: OperationContext = .user()) async -> CleanupOutcome {
        await removeBrokenLinks(links, directory: BrokenLinks.directory, context: context)
    }

    func removeBrokenLinks(_ links: [BrokenLink], directory: String, context: OperationContext) async -> CleanupOutcome {
        var chosen: [BrokenLink] = []
        func finish(_ outcome: CleanupOutcome) -> CleanupOutcome {
            let message: String? = switch outcome {
            case .blocked(let reason): reason
            case .failed(let error): error
            default: chosen.map { "\($0.path) → \($0.target)" }.joined(separator: " · ")
            }
            let name = switch outcome {
            case .blocked: "blocked"
            case .failed: "failed"
            default: "freed"
            }
            appendLog(context, action: "remove_broken_links", itemID: nil, title: "Enlaces rotos",
                      paths: chosen.map(\.path), command: nil, dryRun: false, outcome: name, bytes: 0,
                      message: message)
            return outcome
        }
        if context.isAgent {
            return finish(.blocked(reason: "Los agentes no pueden quitar enlaces; solo el usuario, desde Airy."))
        }
        let load = settings()
        if load.isUnreadable { return finish(.blocked(reason: Self.unreadableSettingsReason)) }
        let protected = ProtectList(patterns: load.effective.protectedPaths, home: home)
        let current = BrokenLinks.find(in: directory)
        for link in links {
            let name = (link.path as NSString).lastPathComponent
            guard !name.isEmpty, !name.contains("/"), link.path == directory + "/" + name,
                  let now = current.first(where: { $0.path == link.path }), now.target == link.target,
                  protected.match(RiskPolicy.canonical(link.path)) == nil,
                  !chosen.contains(where: { $0.path == now.path }) else { continue }
            chosen.append(now)
        }
        guard !chosen.isEmpty else { return finish(.failed("No quedan enlaces rotos que quitar.")) }
        let command = BrokenLinks.deleteCommand(directory: directory,
                                                names: chosen.map { ($0.path as NSString).lastPathComponent })
        if chosen.contains(where: \.needsAdmin) {
            switch await privileged.run([command], prompt: "Airy necesita tu contraseña para quitar enlaces rotos de /usr/local/bin.") {
            case .ok: return finish(.freed(0))
            case .cancelled: return finish(.blocked(reason: "Cancelaste la contraseña: los enlaces se quedan."))
            case .failed(let reason): return finish(.failed("No se pudieron quitar los enlaces: \(reason)"))
            }
        }
        do {
            let output = try await runner.run(command[0], Array(command.dropFirst()), timeout: 30)
            guard output.status == 0 else {
                let detail = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)
                return finish(.failed("No se pudieron quitar los enlaces: \(detail)"))
            }
        } catch {
            return finish(.failed("No se pudieron quitar los enlaces: \(error)"))
        }
        return finish(.freed(0))
    }

    private func uniqueIDs(_ ids: [String]) -> [String] {
        var unique: [String] = []
        for id in ids where !id.isEmpty && !unique.contains(id) { unique.append(id) }
        return unique
    }

    func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }
}
