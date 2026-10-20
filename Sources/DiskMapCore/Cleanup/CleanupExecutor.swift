import Foundation

public enum CleanupOutcome: Sendable, Equatable {
    /// Espacio liberado de verdad (comando oficial o Papelera vaciada).
    case freed(Int64)
    /// Enviado a la Papelera: no cuenta como liberado hasta vaciarla.
    case movedToTrash(Int64)
    case blocked(reason: String)
    case failed(String)
}

/// Quién pide la operación y en qué tanda (`runID`). `proposedBy`: el agente que la propuso, si la
/// confirmó el usuario; `proposedVia`: por dónde llegó la propuesta (`viaUnverifiedURL` = un enlace
/// `airy://`, cuyo nombre de agente no se puede verificar).
public struct OperationContext: Sendable, Equatable {
    public static let viaUnverifiedURL = "url-unverified"

    public let runID: UUID, actor: OperationActor, proposedBy: String?, proposedVia: String?

    public static func user(runID: UUID = UUID(), proposedBy: String? = nil,
                            proposedVia: String? = nil) -> OperationContext {
        OperationContext(runID: runID, actor: .user, proposedBy: proposedBy, proposedVia: proposedVia)
    }

    public static func agent(_ client: String, runID: UUID = UUID()) -> OperationContext {
        OperationContext(runID: runID, actor: .agent(client: client), proposedBy: nil, proposedVia: nil)
    }

    var isAgent: Bool {
        if case .agent = actor { return true }
        return false
    }
}

/// Lo que haría `execute` ahora mismo, sin hacerlo.
public enum CleanupPreview: Sendable, Equatable {
    case wouldTrash(paths: [String], bytes: Int64)
    /// `upperBound`: el comando solo quita una parte; `bytes` es un máximo.
    case wouldRun(command: [String], bytes: Int64, upperBound: Bool)
    case blocked(reason: String)
}

/// Embudo único de borrado: toda acción destructiva pasa por aquí.
/// - Un solo plan (`plan`) para la vista previa y la ejecución, con los ajustes leídos en cada llamada.
/// - Archivos: solo a la Papelera (`FileManager.trashItem`), con la identidad de cada ruta confirmada
///   justo antes de moverla; nunca borrado definitivo.
/// - Cachés de herramientas: su comando oficial con `Process` y array de argumentos.
/// - Agentes: solo lo «Sin problema» y no bloqueado; nunca rutas sueltas ni vaciar la Papelera.
/// - Cada operación deja un `OperationRecord` (el ejecutor es el dueño de esos registros).
public struct CleanupExecutor: Sendable {
    public static let defaultCommandTimeout: TimeInterval = 600
    public static let referenceTimeout: TimeInterval = TimeBudget.references

    static let unreadableSettingsReason =
        "Airy no puede leer sus ajustes; no se ejecuta nada hasta que los revises en la app."
    static let agentsOffReason =
        "Has desactivado en Airy que los agentes ejecuten acciones (Ajustes › Agentes)."

    private let runner: any CommandRunning
    private let probes: any SystemProbing
    private let store: IndexStore
    private let catalog: Catalog
    private let references: ReferenceChecker
    private let home: String
    private let commandTimeout: TimeInterval
    private let freeSpace: @Sendable () -> Int64
    private let trashSettleAttempts: Int
    private let trashSettleDelay: Duration
    private let settings: @Sendable () -> SettingsLoad
    private let log: OperationLog?
    private let processGuard: ProcessGuard
    private let protections: HardProtections
    /// Para que las fuentes de objetivos revaliden (versiones en uso) y su reloj.
    private let processListing: any ProcessListing
    private let now: @Sendable () -> Date
    /// Solo para pruebas: se llama con cada ruta entre el plan y su movimiento.
    private let beforeMove: (@Sendable (String) -> Void)?

    /// `catalog` es obligatorio: toda acción se decide con la ficha viva del catálogo, nunca con la
    /// copia que trae el elemento. `references` (por defecto, las carpetas de proyectos de `home`)
    /// vuelve a comprobar si un modelo está en uso. `freeSpace` mide el espacio disponible del
    /// volumen de `home` (inyectable en pruebas). `settings` es obligatorio (sin valor por defecto, para
    /// que olvidarlo no deje pasar nada) y se lee en cada operación y otra vez antes de actuar: apagar el
    /// interruptor de agentes o proteger una ruta surte efecto al momento.
    public init(
        runner: any CommandRunning, probes: any SystemProbing, store: IndexStore, catalog: Catalog,
        references: ReferenceChecker? = nil, home: String = NSHomeDirectory(),
        commandTimeout: TimeInterval = CleanupExecutor.defaultCommandTimeout,
        freeSpace: (@Sendable () -> Int64)? = nil,
        trashSettleAttempts: Int = 3, trashSettleDelay: Duration = .seconds(1),
        settings: @escaping @Sendable () -> SettingsLoad,
        log: OperationLog? = nil, processGuard: ProcessGuard = ProcessGuard(),
        protections: HardProtections = .standard,
        processListing: any ProcessListing = LibprocListing(), now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(runner: runner, probes: probes, store: store, catalog: catalog, references: references,
                  home: home, commandTimeout: commandTimeout, freeSpace: freeSpace,
                  trashSettleAttempts: trashSettleAttempts, trashSettleDelay: trashSettleDelay,
                  settings: settings, log: log, processGuard: processGuard, protections: protections,
                  processListing: processListing, now: now, beforeMove: nil)
    }

    init(
        runner: any CommandRunning, probes: any SystemProbing, store: IndexStore, catalog: Catalog,
        references: ReferenceChecker? = nil, home: String = NSHomeDirectory(),
        commandTimeout: TimeInterval = CleanupExecutor.defaultCommandTimeout,
        freeSpace: (@Sendable () -> Int64)? = nil,
        trashSettleAttempts: Int = 3, trashSettleDelay: Duration = .seconds(1),
        settings: @escaping @Sendable () -> SettingsLoad,
        log: OperationLog? = nil, processGuard: ProcessGuard = ProcessGuard(),
        protections: HardProtections = .standard,
        processListing: any ProcessListing = LibprocListing(), now: @escaping @Sendable () -> Date = { Date() },
        beforeMove: (@Sendable (String) -> Void)?
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
        self.trashSettleAttempts = max(0, trashSettleAttempts)
        self.trashSettleDelay = trashSettleDelay
        self.settings = settings
        self.log = log
        self.processGuard = processGuard
        self.protections = protections
        self.processListing = processListing
        self.now = now
        self.beforeMove = beforeMove
    }

    // MARK: - API

    /// Lo que haría `execute(item, context:)` ahora: mismo plan, sin mover ni ejecutar nada.
    /// `logged`: anotarla en el registro como simulación (`dry_run` pedido por un agente). La vista previa
    /// de la hoja de confirmación no es una operación y no se anota (`false`).
    public func preview(_ item: CleanupItem, context: OperationContext = .user(),
                        logged: Bool = true) async -> CleanupPreview {
        let preview: CleanupPreview
        var title = item.title
        switch await plan(item, context: context) {
        case .failure(let refusal):
            preview = .blocked(reason: refusal.reason)
        case .success(let planned):
            title = planned.title
            switch planned.kind {
            case .trash(let paths): preview = .wouldTrash(paths: paths.map(\.validated.path), bytes: planned.bytes)
            case .command(let executable, let arguments, _, _, let targets):
                let first = targets.first.map { Self.substitute($0, in: arguments) } ?? arguments
                preview = .wouldRun(command: [executable] + first, bytes: planned.bytes,
                                    upperBound: planned.upperBound)
            }
        }
        let command: [String]? = if case .wouldRun(let c, _, _) = preview { c } else { nil }
        let (outcome, bytes, message): (String, Int64, String?) = switch preview {
        case .wouldTrash(_, let b): ("would_trash", b, nil)
        case .wouldRun(_, let b, _): ("would_run", b, nil)
        case .blocked(let reason): ("blocked", 0, reason)
        }
        guard logged else { return preview }
        let paths: [String] = if case .wouldTrash(let p, _) = preview { p } else { item.paths }
        appendLog(context, action: "clean", itemID: item.id, title: title, paths: paths, command: command,
                  dryRun: true, outcome: outcome, bytes: bytes, message: message)
        return preview
    }

    public func execute(_ item: CleanupItem, context: OperationContext = .user()) async -> CleanupOutcome {
        let outcome: CleanupOutcome
        var title = item.title
        var paths = item.paths
        var command: [String]?
        var moved: [String] = [], movedBytes: Int64 = 0
        switch await plan(item, context: context) {
        case .failure(let refusal):
            outcome = .blocked(reason: refusal.reason)
        case .success(let planned):
            title = planned.title
            if case .trash(let planned) = planned.kind { paths = planned.map(\.validated.path) }
            if case .command(let e, let a, _, let p, let targets) = planned.kind {
                command = [e] + a
                paths = targets.isEmpty ? p : targets
            }
            (outcome, moved, movedBytes) = await act(planned, context: context)
        }
        appendLog(context, action: "clean", itemID: item.id, title: title, paths: paths, command: command, outcome,
                  moved: moved, movedBytes: movedBytes)
        return outcome
    }

    /// Envía rutas sueltas (elegidas en el mapa o propuestas por la IA y confirmadas por el usuario) a
    /// la Papelera. Si una sola ruta no es segura, no se mueve ninguna. Nunca para agentes.
    public func trashPaths(_ paths: [String], title: String, context: OperationContext = .user()) async -> CleanupOutcome {
        let outcome: CleanupOutcome
        var moved: [String] = [], movedBytes: Int64 = 0
        if context.isAgent {
            outcome = .blocked(reason: "Los agentes no pueden enviar rutas sueltas a la Papelera; solo el usuario, desde Airy.")
        } else if paths.isEmpty {
            outcome = .failed("No hay nada que enviar a la Papelera.")
        } else {
            switch await planLoose(paths, title: title, context: context) {
            case .failure(let refusal): outcome = .blocked(reason: refusal.reason)
            case .success(let planned): (outcome, moved, movedBytes) = await act(planned, context: context)
            }
        }
        appendLog(context, action: "trash_paths", itemID: nil, title: title, paths: paths, command: nil, outcome,
                  moved: moved, movedBytes: movedBytes)
        return outcome
    }

    /// Vacía la Papelera (solo tras pulsar el usuario "Vaciar Papelera"; nunca para agentes).
    /// Ojo: si `~/.Trash` no se puede leer, `SystemProbing.emptyTrash` recurre a Finder, que vacía
    /// las papeleras de todos los volúmenes; la interfaz lo advierte antes de confirmar.
    /// Se anota (y se devuelve) lo que de verdad subió el espacio libre del volumen, igual que la
    /// celebración: no lo que ocupaba la Papelera (las instantáneas locales pueden retenerlo).
    /// APFS puede tardar un momento en devolver el espacio: si sube menos de lo esperado, se vuelve
    /// a medir hasta `trashSettleAttempts` veces, con `trashSettleDelay` entre medidas.
    public func emptyTrash(context: OperationContext = .user()) async -> CleanupOutcome {
        let outcome: CleanupOutcome
        if context.isAgent {
            outcome = .blocked(reason: "Los agentes no pueden vaciar la Papelera; solo el usuario, desde Airy.")
        } else if let refusal = policyRefusal(settings(), context: context) {
            outcome = .blocked(reason: refusal.reason)
        } else {
            outcome = await emptyTrashNow(context: context)
        }
        appendLog(context, action: "empty_trash", itemID: nil, title: "Vaciar Papelera", paths: [], command: nil, outcome)
        return outcome
    }

    /// `true` si el ejecutor rechazaría enviar esta ruta a la Papelera: la regla de `PathGate.validate`
    /// con los ajustes actuales. La interfaz lo usa para no ofrecer "Mover a la Papelera…" donde el
    /// ejecutor se negará: misma regla en los dos sitios.
    public func wouldRefuseTrash(path: String) -> Bool { unsafeTrashReason(path) != nil }

    /// `nil` si `PathGate` acepta la ruta; si no, su motivo.
    public func unsafeTrashReason(_ path: String) -> String? { gate(settings()).validate(path).failure?.reason }

    // MARK: - Plan

    struct PlannedPath: Sendable {
        let validated: ValidatedPath
        let bytes: Int64
    }

    struct PlannedAction: Sendable {
        enum Kind: Sendable {
            case trash([PlannedPath])
            /// `entry` y `paths` (las de la ficha viva): para volver a mirar «Proteger esto» antes de ejecutar.
            /// `targets`: valores de `{target}` ya validados; vacío ⇒ una sola ejecución sin sustituir.
            case command(executable: String, arguments: [String], entry: CatalogEntry, paths: [String],
                         targets: [String])
        }
        let kind: Kind
        let title: String
        let bytes: Int64
        let upperBound: Bool
        /// Para reclasificar justo antes de actuar (agentes): la ficha viva, las rutas y el riesgo de la IA.
        var risk: RiskInputs? = nil
        /// Para volver a comprobarlos justo antes de actuar.
        let processNames: [String]
        let guardPaths: [String]
        let checkOpenFiles: Bool
    }

    struct RiskInputs: Sendable {
        let entry: CatalogEntry
        let paths: [String]
        let ai: Risk?
        let itemDoNotTouch: Bool
    }

    /// Riesgo con los ajustes vivos: el mismo cálculo en el plan y justo antes de actuar.
    private func classify(_ inputs: RiskInputs, settings: AirySettings) -> Classification {
        var verdict = RiskClassifier(catalog: catalog, settings: settings, home: home, protections: protections)
            .classify(entry: inputs.entry, paths: inputs.paths, ai: inputs.ai)
        if inputs.itemDoNotTouch { verdict.risk = .doNotTouch }
        return verdict
    }

    private static func agentRiskRefusal(_ risk: Risk, title: String) -> PathRefusal {
        PathRefusal(reason: risk == .doNotTouch
            ? "«\(title)» es «\(Risk.doNotTouch.label)»: Airy no lo toca."
            : "«\(title)» es «\(risk.label)»: solo se ejecuta lo marcado «\(Risk.safe.label)».")
    }

    /// Único camino de decisión para `preview` y `execute`. Orden: ajustes vivos → clasificador vivo →
    /// política de agente → bloqueos actuales → procesos → referencias → rutas (`PathGate`) → tamaños.
    private func plan(_ item: CleanupItem, context: OperationContext) async -> Result<PlannedAction, PathRefusal> {
        let load = settings()
        if let refusal = policyRefusal(load, context: context) { return .failure(refusal) }

        // La ficha viva manda: método, apps que cerrar y riesgo salen del catálogo, no del elemento.
        let parts = item.id.split(separator: ":", maxSplits: 1).map(String.init)
        guard let catalogID = parts.first, let live = catalog.entry(id: catalogID) else {
            return .failure(PathRefusal(reason: "No está en el catálogo: no se ejecuta nada."))
        }
        let title = parts.count > 1 ? "\(live.title): \(parts[1])" : live.title
        // Comandos: las protecciones y referencias se comprueban sobre las rutas de la ficha viva que
        // existen ahora, nunca sobre las que trae el elemento (que solo pueden ser un subconjunto).
        var checkPaths = item.paths
        if case .command = live.cleanup {
            let livePaths = Self.existingPaths(of: live, home: home)
            if !live.paths.isEmpty, livePaths.isEmpty {
                return .failure(PathRefusal(reason: "No se encuentra «\(live.title)» en este Mac; no se ejecuta nada."))
            }
            let allowed = Set(livePaths.map(RiskPolicy.canonical))
            for path in item.paths where !allowed.contains(RiskPolicy.canonical(path)) {
                return .failure(PathRefusal(reason: "La ruta no corresponde a «\(live.title)»: \(path)."))
            }
            checkPaths = livePaths
            if let reason = await revalidate(live, item: item) { return .failure(PathRefusal(reason: reason)) }
        }
        let riskInputs = RiskInputs(entry: live, paths: checkPaths, ai: item.risk,
                                    itemDoNotTouch: item.entry.risk == .doNotTouch)
        let verdict = classify(riskInputs, settings: load.effective)
        let risk = verdict.risk

        if context.isAgent, risk != .safe { return .failure(Self.agentRiskRefusal(risk, title: title)) }

        if case .info = live.cleanup { return .failure(PathRefusal(reason: "Este elemento es solo informativo.")) }
        if !item.usedBy.isEmpty {
            return .failure(PathRefusal(reason: "Lo usa: \(item.usedBy.joined(separator: ", "))."))
        }
        if risk == .doNotTouch {
            return .failure(PathRefusal(reason: verdict.protection.map { "Marcado como «No tocar»: \($0.reason)" }
                ?? "Marcado como «No tocar»."))
        }
        let isTrash = live.cleanup == .trash
        if isTrash, item.paths.isEmpty { return .failure(PathRefusal(reason: "No hay nada que enviar a la Papelera.")) }
        var apps = live.mustBeClosed + item.entry.mustBeClosed
        if isTrash { apps += relatedEntries(of: item.paths).flatMap(\.mustBeClosed) }
        if let reason = openAppsReason(apps) { return .failure(PathRefusal(reason: reason)) }

        let planned: Result<PlannedAction, PathRefusal>
        let guardPaths = isTrash ? item.paths : []
        if let reason = await processReason(live.processNames, paths: guardPaths, checkOpenFiles: isTrash) {
            return .failure(PathRefusal(reason: reason))
        }
        // Las referencias se comprueban de nuevo: no se fía de `item.usedBy` (puede venir vacío de una
        // detección cancelada o anterior a la referencia).
        if let reason = await referenceReason(checkPaths) { return .failure(PathRefusal(reason: reason)) }

        switch live.cleanup {
        case .info:
            return .failure(PathRefusal(reason: "Este elemento es solo informativo."))
        case .command(let executable, let arguments, _):
            var targets: [String] = []
            if live.cleanup.usesTargets {
                guard !item.targets.isEmpty else {
                    return .failure(PathRefusal(reason: "No hay nada sobre lo que ejecutar «\(live.title)»."))
                }
                for target in item.targets {
                    if let reason = targetRefusal(target, entry: live, load: load) {
                        return .failure(PathRefusal(reason: reason))
                    }
                }
                targets = item.targets
            }
            planned = .success(PlannedAction(
                kind: .command(executable: executable, arguments: arguments, entry: live, paths: checkPaths,
                               targets: targets),
                title: title, bytes: item.bytes, upperBound: live.partialCleanup, processNames: live.processNames,
                guardPaths: [], checkOpenFiles: false))
        case .trash:
            // La fuente de la ficha decide si las rutas siguen siendo suyas (patrones, versiones antiguas…).
            if let reason = await revalidate(live, item: item) { return .failure(PathRefusal(reason: reason)) }
            planned = await planTrash(item.paths, gate: gate(load), title: title, processNames: live.processNames,
                                      checkOpenFiles: true)
        }
        return planned.map { var action = $0; action.risk = riskInputs; return action }
    }

    /// Plan de rutas sueltas: primero `PathGate` (lo inválido se rechaza sin más), luego apps, procesos,
    /// referencias y tamaños.
    private func planLoose(_ paths: [String], title: String, context: OperationContext) async
        -> Result<PlannedAction, PathRefusal> {
        let load = settings()
        if let refusal = policyRefusal(load, context: context) { return .failure(refusal) }
        let gate = gate(load)
        for path in paths {
            if case .failure(let refusal) = gate.validate(path) { return .failure(Self.pathRefusal(refusal, path)) }
        }
        let related = relatedEntries(of: paths)
        if let reason = openAppsReason(related.flatMap(\.mustBeClosed)) { return .failure(PathRefusal(reason: reason)) }
        let names = related.flatMap(\.processNames)
        if let reason = await processReason(names, paths: [], checkOpenFiles: false) {
            return .failure(PathRefusal(reason: reason))
        }
        if let reason = await referenceReason(paths) { return .failure(PathRefusal(reason: reason)) }
        return await planTrash(paths, gate: gate, title: title, processNames: names, checkOpenFiles: false)
    }

    /// Valida cada ruta con `PathGate` (guardando su identidad) y mide su tamaño dentro del presupuesto.
    private func planTrash(_ paths: [String], gate: PathGate, title: String, processNames: [String],
                           checkOpenFiles: Bool) async -> Result<PlannedAction, PathRefusal> {
        var validated: [ValidatedPath] = []
        for path in paths {
            switch gate.validate(path) {
            case .failure(let refusal): return .failure(Self.pathRefusal(refusal, path))
            case .success(let ok): validated.append(ok)
            }
        }
        guard let sizes = await TimeBudget.run(TimeBudget.sizeMeasure, { paths.map { AllocatedSize.of($0) ?? 0 } })
        else {
            return .failure(PathRefusal(reason: "No se pudo medir a tiempo lo que ocupa; Airy no lo toca."))
        }
        let planned = zip(validated, sizes).map { PlannedPath(validated: $0, bytes: $1) }
        return .success(PlannedAction(
            kind: .trash(planned), title: title, bytes: sizes.reduce(0, +), upperBound: false,
            processNames: processNames, guardPaths: checkOpenFiles ? paths : [], checkOpenFiles: checkOpenFiles))
    }

    // MARK: - Actuar

    /// Resultado y lo que de verdad llegó a la Papelera (rutas y bytes), también si se paró a medias.
    private func act(_ plan: PlannedAction, context: OperationContext) async
        -> (outcome: CleanupOutcome, moved: [String], movedBytes: Int64) {
        switch plan.kind {
        case .command(let executable, let arguments, let entry, _, let targets):
            if let reason = await recheck(plan, context: context).reason { return (.blocked(reason: reason), [], 0) }
            guard !targets.isEmpty else {
                return (await runCommand(executable: executable, arguments: arguments, title: plan.title,
                                         context: context), [], 0)
            }
            // Una ejecución por objetivo; el primer fallo detiene la tanda. Lo liberado se suma.
            var freed: Int64 = 0
            var ran = 0
            func stop(_ outcome: CleanupOutcome) -> (outcome: CleanupOutcome, moved: [String], movedBytes: Int64) {
                if ran > 0 { record(title: plan.title, bytes: freed, wentToTrash: false, context: context) }
                return (outcome, [], 0)
            }
            for (index, target) in targets.enumerated() {
                if index > 0 {
                    let load = settings()
                    if let reason = policyRefusal(load, context: context)?.reason
                        ?? targetRefusal(target, entry: entry, load: load) {
                        return stop(.blocked(reason: reason))
                    }
                }
                switch await runOnce(executable: executable, arguments: Self.substitute(target, in: arguments)) {
                case .failure(let message): return stop(.failed(message.text))
                case .success(let bytes): freed += bytes; ran += 1
                }
            }
            record(title: plan.title, bytes: freed, wentToTrash: false, context: context)
            return (.freed(freed), [], 0)
        case .trash(let paths):
            var moved: Int64 = 0
            var movedPaths: [String] = []
            func stop(_ outcome: CleanupOutcome) -> (outcome: CleanupOutcome, moved: [String], movedBytes: Int64) {
                if !movedPaths.isEmpty { record(title: plan.title, bytes: moved, wentToTrash: true, context: context) }
                return (outcome, movedPaths, moved)
            }
            for (index, planned) in paths.enumerated() {
                let path = planned.validated.path
                beforeMove?(path)
                // Justo antes de cada movimiento: ajustes vivos (interruptor, «Proteger esto»), procesos (la
                // primera vez), las reglas de `PathGate` y la misma identidad que se comprobó en el plan.
                let check = await recheck(plan, context: context, processes: index == 0)
                if let reason = check.reason { return stop(.blocked(reason: reason)) }
                if case .failure(let refusal) = check.gate.validate(path) {
                    return stop(.blocked(reason: Self.pathRefusal(refusal, path).reason))
                }
                if let refusal = check.gate.confirmUnchanged(planned.validated) {
                    return stop(.blocked(reason: Self.pathRefusal(refusal, path).reason))
                }
                do {
                    // Mueve la entrada en sí: un enlace simbólico va a la Papelera, no su destino.
                    try FileManager.default.trashItem(at: URL(fileURLWithPath: path, isDirectory: false),
                                                      resultingItemURL: nil)
                    moved += planned.bytes
                    movedPaths.append(path)
                } catch {
                    return stop(.failed("No se pudo mover \(path) a la Papelera: \(error.localizedDescription)"))
                }
            }
            record(title: plan.title, bytes: moved, wentToTrash: true, context: context)
            return (.movedToTrash(moved), movedPaths, moved)
        }
    }

    /// Ajustes releídos y, si `processes`, el guardián de procesos otra vez. Devuelve la `PathGate` con
    /// la lista «Proteger esto» actual.
    private func recheck(_ plan: PlannedAction, context: OperationContext, processes: Bool = true) async
        -> (gate: PathGate, reason: String?) {
        let load = settings()
        let gate = gate(load)
        if let refusal = policyRefusal(load, context: context) { return (gate, refusal.reason) }
        // Un agente solo actúa sobre lo que sigue siendo «Sin problema» con los ajustes de ahora (el modo o la
        // lista protegida pueden haber cambiado desde el plan).
        if context.isAgent, let inputs = plan.risk {
            let risk = classify(inputs, settings: load.effective).risk
            if risk != .safe { return (gate, Self.agentRiskRefusal(risk, title: plan.title).reason) }
        }
        if case .command(_, _, let entry, let paths, _) = plan.kind,
           let protection = RiskClassifier(catalog: catalog, settings: load.effective, home: home,
                                           protections: protections).classify(entry: entry, paths: paths).protection {
            return (gate, "Marcado como «No tocar»: \(protection.reason)")
        }
        guard processes else { return (gate, nil) }
        let reason = await processReason(plan.processNames, paths: plan.guardPaths, checkOpenFiles: plan.checkOpenFiles)
        return (gate, reason)
    }

    // MARK: - Comprobaciones

    /// Ajustes ilegibles ⇒ nadie limpia (no se conoce la lista «Proteger esto»); interruptor apagado ⇒
    /// ningún agente.
    private func policyRefusal(_ load: SettingsLoad, context: OperationContext) -> PathRefusal? {
        if load.isUnreadable { return PathRefusal(reason: Self.unreadableSettingsReason) }
        if context.isAgent, !load.allowsAgentActions { return PathRefusal(reason: Self.agentsOffReason) }
        return nil
    }

    private func gate(_ load: SettingsLoad) -> PathGate {
        PathGate(home: home, catalog: catalog,
                 userProtected: ProtectList(patterns: load.effective.protectedPaths, home: home),
                 protections: protections)
    }

    /// La fuente de la ficha viva vuelve a comprobar el elemento (misma regla que al detectarlo).
    private func revalidate(_ live: CatalogEntry, item: CleanupItem) async -> String? {
        let context = DiscoveryContext(catalog: catalog, home: home, runner: runner, processListing: processListing,
                                       now: now(), scan: nil)
        return await CleanupTargets.source(for: live).revalidate(live, item: item, context: context)
    }

    /// Un objetivo de `{target}` que es una ruta pasa por `PathGate` con el catálogo **sin** su propia ficha
    /// (que, por ser de comando, rechazaría sus rutas «se limpia solo con su comando oficial»); las demás
    /// reglas (lista dura, «Proteger esto», inodos, el resto de fichas) siguen igual.
    private func targetRefusal(_ target: String, entry: CatalogEntry, load: SettingsLoad) -> String? {
        guard target.hasPrefix("/") else { return nil }
        let others = Catalog(entries: catalog.entries.filter { $0.id != entry.id })
        let gate = PathGate(home: home, catalog: others,
                            userProtected: ProtectList(patterns: load.effective.protectedPaths, home: home),
                            protections: protections)
        if case .failure(let refusal) = gate.validate(target) {
            return "\(refusal.reason) No se ejecuta «\(entry.title)» sobre \(target)."
        }
        return nil
    }

    private static func pathRefusal(_ refusal: PathRefusal, _ path: String) -> PathRefusal {
        PathRefusal(reason: "\(refusal.reason) No se envía a la Papelera: \(path).")
    }

    /// Apps abiertas leídas al momento (`currentRunningBundleIDs`: en `airy-mcp`, sin bucle de AppKit, la lista
    /// de `NSWorkspace` puede estar desfasada). Si no se puede saber, falla cerrado.
    private func openAppsReason(_ bundleIDs: [String]) -> String? {
        guard !bundleIDs.isEmpty else { return nil }
        guard let running = probes.currentRunningBundleIDs() else {
            var unique: [String] = []
            for id in bundleIDs where !unique.contains(id) { unique.append(id) }
            return "No se pudo comprobar si \(unique.joined(separator: ", ")) está abierta; Airy no lo toca."
        }
        var open: [String] = []
        for id in bundleIDs where running.contains(id) && !open.contains(id) { open.append(id) }
        return open.isEmpty ? nil : "Cierra primero: \(open.joined(separator: ", "))."
    }

    /// En marcha o sin poder comprobarlo ⇒ motivo (falla cerrado).
    private func processReason(_ names: [String], paths: [String], checkOpenFiles: Bool) async -> String? {
        guard !names.isEmpty || (checkOpenFiles && !paths.isEmpty) else { return nil }
        var unique: [String] = []
        for name in names where !unique.contains(name) { unique.append(name) }
        return await processGuard.check(processNames: unique, paths: paths, checkOpenFiles: checkOpenFiles)
            .blockedReason
    }

    /// Rutas de la ficha que existen ahora en disco, sin repetir.
    private static func existingPaths(of entry: CatalogEntry, home: String) -> [String] {
        var unique: [String] = []
        for path in entry.paths.flatMap({ CleanupScanner.expand($0, home: home) }) where !unique.contains(path) {
            unique.append(path)
        }
        return unique
    }

    /// Formas canónicas de una ruta (tal cual, padre resuelto, destino del enlace) para buscar fichas.
    private static func forms(of path: String) -> [String] {
        PathGate.forms(of: path, isSymlink: PathGate.identity(of: path)?.isSymlink ?? false)
            ?? [RiskPolicy.canonical(path)]
    }

    /// Fichas del catálogo relacionadas con alguna ruta (la ruta está dentro de ellas o las contiene).
    private func relatedEntries(of paths: [String]) -> [CatalogEntry] {
        let forms = paths.flatMap(Self.forms)
        return catalog.entries.filter { entry in
            entry.paths.contains { pattern in forms.contains { related($0, pattern) } }
        }
    }

    /// `true` si la ruta canónica está dentro del patrón (o lo iguala) o es una carpeta superior suya.
    private func related(_ canonicalPath: String, _ pattern: String) -> Bool {
        var expanded = pattern
        if pattern == "~" { expanded = home } else if pattern.hasPrefix("~/") { expanded = home + pattern.dropFirst(1) }
        let patternParts = HardProtections.components(RiskPolicy.canonical(expanded))
        let pathParts = HardProtections.components(canonicalPath)
        return zip(patternParts, pathParts).allSatisfy { HardProtections.componentMatches($0, $1) }
    }

    /// Si alguna ruta toca algo con comprobación de referencias (modelos de Hugging Face…), se vuelve a
    /// buscar en los proyectos: si se usa, o si la búsqueda no termina a tiempo, no se toca.
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
        let checked = await references.referencesChecked(toAny: needles, timeout: Self.referenceTimeout)
        let users = needles.flatMap { checked.found[$0] ?? [] }
        if !users.isEmpty { return "Lo usa: \(users.joined(separator: ", "))." }
        return checked.complete ? nil : "No se pudo comprobar a tiempo si lo usa algún proyecto."
    }

    // MARK: - Comandos y Papelera

    private func runCommand(executable: String, arguments: [String], title: String,
                            context: OperationContext) async -> CleanupOutcome {
        switch await runOnce(executable: executable, arguments: arguments) {
        case .failure(let message): return .failed(message.text)
        case .success(let freed):
            record(title: title, bytes: freed, wentToTrash: false, context: context)
            return .freed(freed)
        }
    }

    /// Ejecuta el comando una vez; lo liberado (subida del espacio libre) o el mensaje del fallo.
    private func runOnce(executable: String, arguments: [String]) async -> Result<Int64, CommandFailureMessage> {
        guard let resolved = await runner.resolve(executable) else {
            return .failure(CommandFailureMessage("No se encontró \(executable) en este Mac."))
        }
        let before = freeSpace()
        let output: CommandOutput
        do {
            output = try await runner.run(resolved, arguments, timeout: commandTimeout)
        } catch {
            return .failure(CommandFailureMessage(String(describing: error)))
        }
        guard output.status == 0 else {
            let detail = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(CommandFailureMessage(
                "\(executable) terminó con código \(output.status)\(detail.isEmpty ? "" : ": \(detail)")"))
        }
        return .success(max(0, freeSpace() - before))
    }

    /// `{target}` sustituido (argumento exacto) por `target`.
    static func substitute(_ target: String, in arguments: [String]) -> [String] {
        arguments.map { $0 == CleanupMethod.targetPlaceholder ? target : $0 }
    }

    private func emptyTrashNow(context: OperationContext) async -> CleanupOutcome {
        do {
            let before = freeSpace()
            let emptied = try await probes.emptyTrash()
            var rose = max(0, freeSpace() - before)
            var attempts = 0
            while emptied > 0, Double(rose) < Double(emptied) * TrashFollowUp.expectedRiseFraction,
                  attempts < trashSettleAttempts {
                attempts += 1
                try? await Task.sleep(for: trashSettleDelay)
                rose = max(rose, freeSpace() - before)
            }
            record(title: "Vaciar Papelera", bytes: rose, wentToTrash: false, context: context)
            return .freed(rose)
        } catch {
            return .failed("No se pudo vaciar la Papelera: \(error.localizedDescription)")
        }
    }

    // MARK: - Registros

    /// Historial de limpiezas (lo que se ve en la app).
    private func record(title: String, bytes: Int64, wentToTrash: Bool, context: OperationContext) {
        do {
            try store.append(CleanupRecord(date: Date(), title: title, bytes: bytes, wentToTrash: wentToTrash,
                                           byAgent: context.isAgent))
        } catch {
            log?.reportFailure("no se pudo anotar «\(title)» en el historial de limpiezas (\(error.localizedDescription))")
        }
    }

    /// `moved`/`movedBytes`: lo que llegó a la Papelera. Si la operación se paró a medias, el registro
    /// es `partial` con esas rutas y bytes (igual que el historial) y el motivo en `message`.
    private func appendLog(_ context: OperationContext, action: String, itemID: String?, title: String,
                           paths: [String], command: [String]?, _ outcome: CleanupOutcome,
                           moved: [String] = [], movedBytes: Int64 = 0) {
        var paths = paths
        var (name, bytes, message): (String, Int64, String?) = switch outcome {
        case .freed(let b): ("freed", b, nil)
        case .movedToTrash(let b): ("moved_to_trash", b, nil)
        case .blocked(let reason): ("blocked", 0, reason)
        case .failed(let error): ("failed", 0, error)
        }
        if case .movedToTrash = outcome { paths = moved }
        if name == "blocked" || name == "failed", !moved.isEmpty {
            (name, bytes, paths) = ("partial", movedBytes, moved)
        }
        appendLog(context, action: action, itemID: itemID, title: title, paths: paths, command: command,
                  dryRun: false, outcome: name, bytes: bytes, message: message)
    }

    private func appendLog(_ context: OperationContext, action: String, itemID: String?, title: String,
                           paths: [String], command: [String]?, dryRun: Bool, outcome: String, bytes: Int64,
                           message: String?) {
        // Un fallo queda pendiente en `log.takeWriteFailure()`: la app lo avisa y `airy-mcp` lo devuelve al agente.
        try? log?.append(OperationRecord(
            runID: context.runID, date: Date(), actor: context.actor, action: action, itemID: itemID, title: title,
            paths: paths, command: command, dryRun: dryRun, outcome: outcome, bytes: bytes, message: message,
            proposedBy: context.proposedBy, proposedVia: context.proposedVia))
    }
}

/// Mensaje de un comando que falló (para `Result`).
struct CommandFailureMessage: Error, Sendable {
    let text: String
    init(_ text: String) { self.text = text }
}
