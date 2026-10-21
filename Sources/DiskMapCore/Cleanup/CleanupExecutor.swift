import Foundation

public enum CleanupOutcome: Sendable, Equatable {
    /// Space really freed (official command or emptied Trash).
    case freed(Int64)
    /// Sent to the Trash: it does not count as freed until it is emptied.
    case movedToTrash(Int64)
    case blocked(reason: String)
    case failed(String)
}

/// Who asks for the operation and in which batch (`runID`). `proposedBy`: the agent that proposed it, if the
/// user confirmed it; `proposedVia`: where the proposal came from (`viaUnverifiedURL` = an
/// `airy://` link, whose agent name cannot be verified).
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

/// What `execute` would do right now, without doing it.
public enum CleanupPreview: Sendable, Equatable {
    case wouldTrash(paths: [String], bytes: Int64)
    /// `upperBound`: the command only removes part; `bytes` is a maximum.
    case wouldRun(command: [String], bytes: Int64, upperBound: Bool)
    case blocked(reason: String)
}

/// The single deletion funnel: every destructive action goes through here.
/// - A single plan (`plan`) for the preview and the execution, with the settings read on every call.
/// - Files: only to the Trash (`FileManager.trashItem`), with the identity of each path confirmed
///   right before moving it; never permanent deletion.
/// - Tool caches: their official command with `Process` and an argument array.
/// - Agents: only "Safe to remove" items that are not blocked; never loose paths nor emptying the Trash.
/// - Every operation leaves an `OperationRecord` (the executor owns those records).
public struct CleanupExecutor: Sendable {
    public static let defaultCommandTimeout: TimeInterval = 600
    public static let referenceTimeout: TimeInterval = TimeBudget.references

    static var unreadableSettingsReason: String {
        String(localized: "Airy cannot read its settings; nothing runs until you check them in the app.", bundle: .airyCore) }
    static var agentsOffReason: String {
        String(localized: "You have turned off agent actions in Airy (Settings › Agents).", bundle: .airyCore) }

    let runner: any CommandRunning
    private let probes: any SystemProbing
    let store: IndexStore
    private let catalog: Catalog
    private let references: ReferenceChecker
    let home: String
    private let commandTimeout: TimeInterval
    private let freeSpace: @Sendable () -> Int64
    private let trashSettleAttempts: Int
    private let trashSettleDelay: Duration
    let settings: @Sendable () -> SettingsLoad
    let log: OperationLog?
    private let processGuard: ProcessGuard
    let protections: HardProtections
    /// So that the target sources can revalidate (versions in use), and their clock.
    private let processListing: any ProcessListing
    private let now: @Sendable () -> Date
    /// Tests only: called with each path between the plan and its move (and with each `{target}`
    /// target before it runs).
    let beforeMove: (@Sendable (String) -> Void)?
    let privileged: any PrivilegedRunning
    let quitter: any AppQuitting
    /// `nil` ⇒ `ProtectionWaiver.productionAppRoots(home:)`.
    let appRoots: [String]?

    /// `catalog` is required: every action is decided with the catalog's live entry, never with the
    /// copy the item carries. `references` (by default, the project folders in `home`)
    /// checks again whether a model is in use. `freeSpace` measures the available space of the
    /// `home` volume (injectable in tests). `settings` is required (no default value, so that
    /// forgetting it lets nothing through) and is read on every operation and again before acting: turning off the
    /// agents switch or protecting a path takes effect immediately.
    public init(
        runner: any CommandRunning, probes: any SystemProbing, store: IndexStore, catalog: Catalog,
        references: ReferenceChecker? = nil, home: String = NSHomeDirectory(),
        commandTimeout: TimeInterval = CleanupExecutor.defaultCommandTimeout,
        freeSpace: (@Sendable () -> Int64)? = nil,
        trashSettleAttempts: Int = 3, trashSettleDelay: Duration = .seconds(1),
        settings: @escaping @Sendable () -> SettingsLoad,
        log: OperationLog? = nil, processGuard: ProcessGuard = ProcessGuard(),
        protections: HardProtections = .standard,
        processListing: any ProcessListing = LibprocListing(), now: @escaping @Sendable () -> Date = { Date() },
        privileged: any PrivilegedRunning = OsascriptPrivilegedRunner(),
        quitter: any AppQuitting = WorkspaceQuitter(),
        appRoots: [String]? = nil
    ) {
        self.init(runner: runner, probes: probes, store: store, catalog: catalog, references: references,
                  home: home, commandTimeout: commandTimeout, freeSpace: freeSpace,
                  trashSettleAttempts: trashSettleAttempts, trashSettleDelay: trashSettleDelay,
                  settings: settings, log: log, processGuard: processGuard, protections: protections,
                  processListing: processListing, now: now,
                  privileged: privileged, quitter: quitter, appRoots: appRoots, beforeMove: nil)
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
        privileged: any PrivilegedRunning = OsascriptPrivilegedRunner(),
        quitter: any AppQuitting = WorkspaceQuitter(),
        appRoots: [String]? = nil,
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
        self.privileged = privileged
        self.quitter = quitter
        self.appRoots = appRoots
    }

    // MARK: - API

    /// What `execute(item, context:)` would do now: same plan, without moving or running anything.
    /// `logged`: record it in the log as a simulation (`dry_run` requested by an agent). The confirmation
    /// sheet's preview is not an operation and is not recorded (`false`).
    /// `pass`: the batch it belongs to (one per confirmation sheet): the rows share the expensive detection.
    public func preview(_ item: CleanupItem, context: OperationContext = .user(),
                        logged: Bool = true, pass: RevalidationPass? = nil) async -> CleanupPreview {
        let preview: CleanupPreview
        var title = item.title
        switch await plan(item, context: context, pass: pass) {
        case .failure(let refusal):
            preview = .blocked(reason: refusal.reason)
        case .success(let planned):
            title = planned.title
            switch planned.kind {
            case .trash(let paths): preview = .wouldTrash(paths: paths.map(\.validated.path), bytes: planned.bytes)
            case .command(let executable, let arguments, _, _, let targets):
                let first = targets.first.map { Self.substitute($0.value, in: arguments) } ?? arguments
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

    /// `pass`: the batch it belongs to (one per confirmed execution); never the preview's.
    public func execute(_ item: CleanupItem, context: OperationContext = .user(),
                        pass: RevalidationPass? = nil) async -> CleanupOutcome {
        let outcome: CleanupOutcome
        var title = item.title
        var paths = item.paths
        var command: [String]?
        var moved: [String] = [], movedBytes: Int64 = 0
        switch await plan(item, context: context, pass: pass) {
        case .failure(let refusal):
            outcome = .blocked(reason: refusal.reason)
        case .success(let planned):
            title = planned.title
            if case .trash(let planned) = planned.kind { paths = planned.map(\.validated.path) }
            if case .command(let e, let a, _, let p, let targets) = planned.kind {
                // What really runs: with the first target substituted.
                command = [e] + (targets.first.map { Self.substitute($0.value, in: a) } ?? a)
                paths = targets.isEmpty ? p : targets.map(\.value)
            }
            (outcome, moved, movedBytes) = await act(planned, context: context)
        }
        appendLog(context, action: "clean", itemID: item.id, title: title, paths: paths, command: command, outcome,
                  moved: moved, movedBytes: movedBytes)
        return outcome
    }

    /// Sends loose paths (chosen on the map or proposed by the AI and confirmed by the user) to
    /// the Trash. If a single path is not safe, none is moved. Never for agents.
    public func trashPaths(_ paths: [String], title: String, context: OperationContext = .user()) async -> CleanupOutcome {
        let outcome: CleanupOutcome
        var moved: [String] = [], movedBytes: Int64 = 0
        if context.isAgent {
            outcome = .blocked(reason: String(localized: "Agents cannot send loose paths to the Trash; only the user can, from Airy.", bundle: .airyCore))
        } else if paths.isEmpty {
            outcome = .failed(String(localized: "There is nothing to send to the Trash.", bundle: .airyCore))
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

    /// Empties the Trash (only after the user presses "Empty Trash"; never for agents).
    /// Careful: if `~/.Trash` cannot be read, `SystemProbing.emptyTrash` falls back to Finder, which empties
    /// the trash of every volume; the UI warns about it before confirming.
    /// What is recorded (and returned) is how much the volume's free space really rose, just like the
    /// celebration: not what the Trash took up (local snapshots can hold it).
    /// APFS may take a moment to give the space back: if it rises less than expected, it is measured
    /// again up to `trashSettleAttempts` times, with `trashSettleDelay` between measurements.
    public func emptyTrash(context: OperationContext = .user()) async -> CleanupOutcome {
        let outcome: CleanupOutcome
        if context.isAgent {
            outcome = .blocked(reason: String(localized: "Agents cannot empty the Trash; only the user can, from Airy.", bundle: .airyCore))
        } else if let refusal = policyRefusal(settings(), context: context) {
            outcome = .blocked(reason: refusal.reason)
        } else {
            outcome = await emptyTrashNow(context: context)
        }
        appendLog(context, action: "empty_trash", itemID: nil, title: String(localized: "Empty Trash", bundle: .airyCore), paths: [], command: nil, outcome)
        return outcome
    }

    /// `true` if the executor would refuse to send this path to the Trash: the `PathGate.validate` rule
    /// with the current settings. The UI uses it so as not to offer "Move to Trash…" where the
    /// executor will refuse: the same rule in both places.
    public func wouldRefuseTrash(path: String) -> Bool { unsafeTrashReason(path) != nil }

    /// `nil` if `PathGate` accepts the path; otherwise, its reason.
    public func unsafeTrashReason(_ path: String) -> String? { gate(settings()).validate(path).failure?.reason }

    // MARK: - Plan

    /// A `{target}` value and, if it is a path, its validation (`PathGate`, identity) from the plan.
    struct PlannedTarget: Sendable {
        let value: String
        let validated: ValidatedPath?
    }

    struct PlannedPath: Sendable {
        let validated: ValidatedPath
        let bytes: Int64
    }

    struct PlannedAction: Sendable {
        enum Kind: Sendable {
            case trash([PlannedPath])
            /// `entry` and `paths` (those of the live entry): to look at "Protect this" again before running.
            /// `targets`: `{target}` values already validated; empty ⇒ a single run without substitution.
            case command(executable: String, arguments: [String], entry: CatalogEntry, paths: [String],
                         targets: [PlannedTarget])
        }
        let kind: Kind
        let title: String
        let bytes: Int64
        let upperBound: Bool
        /// To reclassify right before acting (agents): the live entry, the paths and the AI's risk.
        var risk: RiskInputs? = nil
        /// To check them again right before acting.
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

    /// Risk with the live settings: the same computation in the plan and right before acting.
    private func classify(_ inputs: RiskInputs, settings: AirySettings) -> Classification {
        var verdict = RiskClassifier(catalog: catalog, settings: settings, home: home, protections: protections)
            .classify(entry: inputs.entry, paths: inputs.paths, ai: inputs.ai)
        if inputs.itemDoNotTouch { verdict.risk = .doNotTouch }
        return verdict
    }

    private static func agentRiskRefusal(_ risk: Risk, title: String) -> PathRefusal {
        PathRefusal(reason: risk == .doNotTouch
            ? String(localized: "“\(title)” is “\(Risk.doNotTouch.label)”: Airy does not touch it.", bundle: .airyCore)
            : String(localized: "“\(title)” is “\(risk.label)”: only what is marked “\(Risk.safe.label)” runs.", bundle: .airyCore))
    }

    /// The single decision path for `preview` and `execute`. Order: live settings → live classifier →
    /// agent policy → current blocks → processes → references → paths (`PathGate`) → sizes.
    private func plan(_ item: CleanupItem, context: OperationContext,
                      pass: RevalidationPass?) async -> Result<PlannedAction, PathRefusal> {
        let load = settings()
        if let refusal = policyRefusal(load, context: context) { return .failure(refusal) }

        // The live entry rules: method, apps to close and risk come from the catalog, not from the item.
        let parts = item.id.split(separator: ":", maxSplits: 1).map(String.init)
        guard let catalogID = parts.first, let live = catalog.entry(id: catalogID) else {
            return .failure(PathRefusal(reason: String(localized: "It is not in the catalog: nothing runs.", bundle: .airyCore)))
        }
        let title = parts.count > 1 ? "\(live.title): \(parts[1])" : live.title
        // What the detection left blocked (not measured in time, daemon down…) does not run: it has to be
        // detected again.
        if let reason = item.blockedReason {
            return .failure(PathRefusal(reason: String(localized: "“\(title)” cannot be cleaned right now: \(reason)", bundle: .airyCore)))
        }
        // Commands: protections and references are checked on the live entry's paths that
        // exist now, never on the ones the item carries (which can only be a subset).
        var checkPaths = item.paths
        if case .command(let executable, let arguments, _) = live.cleanup {
            // Veto before any probe: a forbidden command (Docker volumes…) gets nowhere else.
            for args in item.targets.isEmpty ? [arguments] : item.targets.map({ Self.substitute($0, in: arguments) }) {
                if let reason = CommandPolicy.refusal(executable: executable, arguments: args) {
                    return .failure(PathRefusal(reason: reason))
                }
            }
            let livePaths = Self.existingPaths(of: live, home: home)
            if !live.paths.isEmpty, livePaths.isEmpty {
                return .failure(PathRefusal(reason: String(localized: "“\(live.title)” is not found on this Mac; nothing runs.", bundle: .airyCore)))
            }
            let allowed = Set(livePaths.map(RiskPolicy.canonical))
            for path in item.paths where !allowed.contains(RiskPolicy.canonical(path)) {
                return .failure(PathRefusal(reason: String(localized: "The path does not belong to “\(live.title)”: \(path).", bundle: .airyCore)))
            }
            checkPaths = livePaths
            if let reason = await revalidate(live, item: item, pass: pass) { return .failure(PathRefusal(reason: reason)) }
        }
        let riskInputs = RiskInputs(entry: live, paths: checkPaths, ai: item.risk,
                                    itemDoNotTouch: item.entry.risk == .doNotTouch)
        let verdict = classify(riskInputs, settings: load.effective)
        let risk = verdict.risk

        if context.isAgent, risk != .safe { return .failure(Self.agentRiskRefusal(risk, title: title)) }

        if case .info = live.cleanup { return .failure(PathRefusal(reason: String(localized: "This item is informational only.", bundle: .airyCore))) }
        if !item.usedBy.isEmpty {
            return .failure(PathRefusal(reason: String(localized: "Used by: \(item.usedBy.joined(separator: ", ")).", bundle: .airyCore)))
        }
        if risk == .doNotTouch {
            return .failure(PathRefusal(reason: verdict.protection.map { String(localized: "Marked as “Do not touch”: \($0.reason)", bundle: .airyCore) }
                ?? String(localized: "Marked as “Do not touch”.", bundle: .airyCore)))
        }
        let isTrash = live.cleanup == .trash
        if isTrash, item.paths.isEmpty { return .failure(PathRefusal(reason: String(localized: "There is nothing to send to the Trash.", bundle: .airyCore))) }
        var apps = live.mustBeClosed + item.entry.mustBeClosed
        if isTrash { apps += relatedEntries(of: item.paths).flatMap(\.mustBeClosed) }
        if let reason = openAppsReason(apps) { return .failure(PathRefusal(reason: reason)) }

        let planned: Result<PlannedAction, PathRefusal>
        let guardPaths = isTrash ? item.paths : []
        if let reason = await processReason(live.processNames, paths: guardPaths, checkOpenFiles: isTrash) {
            return .failure(PathRefusal(reason: reason))
        }
        // References are checked again: `item.usedBy` is not trusted (it may come empty from a
        // cancelled detection or one from before the reference).
        if let reason = await referenceReason(checkPaths) { return .failure(PathRefusal(reason: reason)) }

        switch live.cleanup {
        case .info:
            return .failure(PathRefusal(reason: String(localized: "This item is informational only.", bundle: .airyCore)))
        case .command(let executable, let arguments, _):
            var targets: [PlannedTarget] = []
            if live.cleanup.usesTargets {
                guard !item.targets.isEmpty else {
                    return .failure(PathRefusal(reason: String(localized: "There is nothing to run “\(live.title)” on.", bundle: .airyCore)))
                }
                for target in item.targets {
                    switch validateTarget(target, entry: live, load: load) {
                    case .failure(let refusal): return .failure(refusal)
                    case .success(let validated): targets.append(PlannedTarget(value: target, validated: validated))
                    }
                }
            }
            planned = .success(PlannedAction(
                kind: .command(executable: executable, arguments: arguments, entry: live, paths: checkPaths,
                               targets: targets),
                title: title, bytes: item.bytes, upperBound: live.partialCleanup, processNames: live.processNames,
                guardPaths: [], checkOpenFiles: false))
        case .trash:
            // The entry's source decides whether the paths still belong to it (patterns, old versions…).
            if let reason = await revalidate(live, item: item, pass: pass) { return .failure(PathRefusal(reason: reason)) }
            planned = await planTrash(item.paths, gate: gate(load), title: title, processNames: live.processNames,
                                      checkOpenFiles: true)
        }
        return planned.map { var action = $0; action.risk = riskInputs; return action }
    }

    /// Plan for loose paths: first `PathGate` (what is invalid is simply rejected), then apps, processes,
    /// references and sizes.
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

    /// Validates each path with `PathGate` (keeping its identity) and measures its size within the budget.
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
            return .failure(PathRefusal(reason: String(localized: "Could not measure in time how much it takes up; Airy does not touch it.", bundle: .airyCore)))
        }
        let planned = zip(validated, sizes).map { PlannedPath(validated: $0, bytes: $1) }
        return .success(PlannedAction(
            kind: .trash(planned), title: title, bytes: sizes.reduce(0, +), upperBound: false,
            processNames: processNames, guardPaths: checkOpenFiles ? paths : [], checkOpenFiles: checkOpenFiles))
    }

    // MARK: - Acting

    /// Result and what really reached the Trash (paths and bytes), also if it stopped halfway.
    private func act(_ plan: PlannedAction, context: OperationContext) async
        -> (outcome: CleanupOutcome, moved: [String], movedBytes: Int64) {
        switch plan.kind {
        case .command(let executable, let arguments, let entry, _, let targets):
            if let reason = await recheck(plan, context: context).reason { return (.blocked(reason: reason), [], 0) }
            guard !targets.isEmpty else {
                return (await runCommand(executable: executable, arguments: arguments, title: plan.title,
                                         context: context), [], 0)
            }
            // One run per target; the first failure stops the batch. What was freed adds up and, if it stops
            // halfway, what really ran is returned (the log records it as `partial`).
            var freed: Int64 = 0
            var executed: [String] = []
            func stop(_ outcome: CleanupOutcome) -> (outcome: CleanupOutcome, moved: [String], movedBytes: Int64) {
                guard !executed.isEmpty else { return (outcome, [], 0) }
                record(title: plan.title, bytes: freed, wentToTrash: false, context: context)
                return (outcome, executed, freed)
            }
            for (index, target) in targets.enumerated() {
                beforeMove?(target.value)
                // Right before each run (the first one too): live settings, risk and protections, the
                // same `PathGate` rule and the same identity as in the plan.
                if index > 0, let reason = await recheck(plan, context: context, processes: false).reason {
                    return stop(.blocked(reason: reason))
                }
                if let reason = confirmTarget(target, entry: entry) { return stop(.blocked(reason: reason)) }
                switch await runOnce(executable: executable, arguments: Self.substitute(target.value, in: arguments)) {
                case .failure(let message): return stop(.failed(message.text))
                case .success(let bytes): freed += bytes; executed.append(target.value)
                }
            }
            record(title: plan.title, bytes: freed, wentToTrash: false, context: context)
            return (.freed(freed), executed, freed)
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
                // Right before each move: live settings (switch, "Protect this"), processes (the
                // first time), the `PathGate` rules and the same identity that was checked in the plan.
                let check = await recheck(plan, context: context, processes: index == 0)
                if let reason = check.reason { return stop(.blocked(reason: reason)) }
                if case .failure(let refusal) = check.gate.validate(path) {
                    return stop(.blocked(reason: Self.pathRefusal(refusal, path).reason))
                }
                if let refusal = check.gate.confirmUnchanged(planned.validated) {
                    return stop(.blocked(reason: Self.pathRefusal(refusal, path).reason))
                }
                do {
                    try moveToTrash(planned.validated)
                    moved += planned.bytes
                    movedPaths.append(path)
                } catch {
                    return stop(.failed(String(localized: "Could not move \(path) to the Trash: \(error.localizedDescription)", bundle: .airyCore)))
                }
            }
            record(title: plan.title, bytes: moved, wentToTrash: true, context: context)
            return (.movedToTrash(moved), movedPaths, moved)
        }
    }

    /// Settings read again and, if `processes`, the process guard again. Returns the `PathGate` with
    /// the current "Protect this" list.
    private func recheck(_ plan: PlannedAction, context: OperationContext, processes: Bool = true) async
        -> (gate: PathGate, reason: String?) {
        let load = settings()
        let gate = gate(load)
        if let refusal = policyRefusal(load, context: context) { return (gate, refusal.reason) }
        // An agent only acts on what is still "Safe to remove" with the current settings (the mode or the
        // protected list may have changed since the plan).
        if context.isAgent, let inputs = plan.risk {
            let risk = classify(inputs, settings: load.effective).risk
            if risk != .safe { return (gate, Self.agentRiskRefusal(risk, title: plan.title).reason) }
        }
        if case .command(_, _, let entry, let paths, _) = plan.kind,
           let protection = RiskClassifier(catalog: catalog, settings: load.effective, home: home,
                                           protections: protections).classify(entry: entry, paths: paths).protection {
            return (gate, String(localized: "Marked as “Do not touch”: \(protection.reason)", bundle: .airyCore))
        }
        guard processes else { return (gate, nil) }
        let reason = await processReason(plan.processNames, paths: plan.guardPaths, checkOpenFiles: plan.checkOpenFiles)
        return (gate, reason)
    }

    // MARK: - Checks

    /// Unreadable settings ⇒ nobody cleans (the "Protect this" list is unknown); switch off ⇒
    /// no agent.
    private func policyRefusal(_ load: SettingsLoad, context: OperationContext) -> PathRefusal? {
        if load.isUnreadable { return PathRefusal(reason: Self.unreadableSettingsReason) }
        if context.isAgent, !load.allowsAgentActions { return PathRefusal(reason: Self.agentsOffReason) }
        return nil
    }

    func gate(_ load: SettingsLoad) -> PathGate {
        PathGate(home: home, catalog: catalog,
                 userProtected: ProtectList(patterns: load.effective.protectedPaths, home: home),
                 protections: protections)
    }

    /// The live entry's source checks the item again (same rule as when detecting it).
    /// With `pass`, the context (and its memoization) is the batch's; without it, a new one for this row.
    private func revalidate(_ live: CatalogEntry, item: CleanupItem, pass: RevalidationPass?) async -> String? {
        let make = {
            DiscoveryContext(catalog: catalog, home: home, runner: runner, processListing: processListing,
                             now: now(), scan: nil)
        }
        let context = pass?.context(make) ?? make()
        return await CleanupTargets.source(for: live).revalidate(live, item: item, context: context)
    }

    /// A `{target}` target that is a path goes through `PathGate` with the catalog **without** its own entry
    /// (which, being a command entry, would reject its paths as "only cleaned with its official command"); the other
    /// rules (hard list, "Protect this", inodes, the remaining entries) stay the same.
    /// An empty target, one starting with `-` (an option slipped into the arguments) or with `~` is always rejected.
    private func validateTarget(_ target: String, entry: CatalogEntry, load: SettingsLoad)
        -> Result<ValidatedPath?, PathRefusal> {
        if target.isEmpty || target.hasPrefix("-") || target.hasPrefix("~")
            || target.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            return .failure(PathRefusal(reason: String(localized: "Invalid target for “\(entry.title)”: \(target).", bundle: .airyCore)))
        }
        guard target.hasPrefix("/") else { return .success(nil) }
        switch targetGate(entry: entry, load: load).validate(target) {
        case .failure(let refusal):
            return .failure(PathRefusal(reason: String(localized: "\(refusal.reason) “\(entry.title)” is not run on \(target).", bundle: .airyCore)))
        case .success(let validated):
            return .success(validated)
        }
    }

    /// Before running on a target: the `PathGate` rule with the current settings and the same
    /// identity (`confirmUnchanged`) that was checked in the plan.
    private func confirmTarget(_ target: PlannedTarget, entry: CatalogEntry) -> String? {
        let load = settings()
        switch validateTarget(target.value, entry: entry, load: load) {
        case .failure(let refusal): return refusal.reason
        case .success:
            // Not validated in the plan ⇒ it is not a path (the same rule decides it again above).
            guard let planned = target.validated else { return nil }
            if let refusal = targetGate(entry: entry, load: load).confirmUnchanged(planned) {
                return String(localized: "\(refusal.reason) “\(entry.title)” is not run on \(target.value).", bundle: .airyCore)
            }
            return nil
        }
    }

    private func targetGate(entry: CatalogEntry, load: SettingsLoad) -> PathGate {
        PathGate(home: home, catalog: Catalog(entries: catalog.entries.filter { $0.id != entry.id }),
                 userProtected: ProtectList(patterns: load.effective.protectedPaths, home: home),
                 protections: protections, commandTarget: entry)
    }

    private static func pathRefusal(_ refusal: PathRefusal, _ path: String) -> PathRefusal {
        PathRefusal(reason: String(localized: "\(refusal.reason) It is not sent to the Trash: \(path).", bundle: .airyCore))
    }

    /// Open apps read on the spot (`currentRunningBundleIDs`: in `airy-mcp`, without an AppKit loop, the
    /// `NSWorkspace` list may be stale). If it cannot be known, it fails closed.
    private func openAppsReason(_ bundleIDs: [String]) -> String? {
        guard !bundleIDs.isEmpty else { return nil }
        guard let running = probes.currentRunningBundleIDs() else {
            var unique: [String] = []
            for id in bundleIDs where !unique.contains(id) { unique.append(id) }
            return String(localized: "Could not check whether \(unique.joined(separator: ", ")) is open; Airy does not touch it.", bundle: .airyCore)
        }
        var open: [String] = []
        for id in bundleIDs where running.contains(id) && !open.contains(id) { open.append(id) }
        return open.isEmpty ? nil : String(localized: "Quit first: \(open.joined(separator: ", ")).", bundle: .airyCore)
    }

    /// Running, or unable to check ⇒ reason (fails closed).
    private func processReason(_ names: [String], paths: [String], checkOpenFiles: Bool) async -> String? {
        guard !names.isEmpty || (checkOpenFiles && !paths.isEmpty) else { return nil }
        var unique: [String] = []
        for name in names where !unique.contains(name) { unique.append(name) }
        return await processGuard.check(processNames: unique, paths: paths, checkOpenFiles: checkOpenFiles)
            .blockedReason
    }

    /// The entry's paths that exist on disk now, without repeats.
    private static func existingPaths(of entry: CatalogEntry, home: String) -> [String] {
        var unique: [String] = []
        for path in entry.paths.flatMap({ CleanupScanner.expand($0, home: home) }) where !unique.contains(path) {
            unique.append(path)
        }
        return unique
    }

    /// Canonical forms of a path (as is, resolved parent, link target) to look for entries.
    private static func forms(of path: String) -> [String] {
        PathGate.forms(of: path, isSymlink: PathGate.identity(of: path)?.isSymlink ?? false)
            ?? [RiskPolicy.canonical(path)]
    }

    /// Catalog entries related to some path (the path lies inside them or contains them).
    private func relatedEntries(of paths: [String]) -> [CatalogEntry] {
        let forms = paths.flatMap(Self.forms)
        return catalog.entries.filter { entry in
            entry.paths.contains { pattern in forms.contains { related($0, pattern) } }
        }
    }

    /// `true` if the canonical path lies inside the pattern (or equals it) or is one of its parent folders.
    private func related(_ canonicalPath: String, _ pattern: String) -> Bool {
        var expanded = pattern
        if pattern == "~" { expanded = home } else if pattern.hasPrefix("~/") { expanded = home + pattern.dropFirst(1) }
        let patternParts = HardProtections.components(RiskPolicy.canonical(expanded))
        let pathParts = HardProtections.components(canonicalPath)
        return zip(patternParts, pathParts).allSatisfy { HardProtections.componentMatches($0, $1) }
    }

    /// If some path touches something with a reference check (Hugging Face models…), the projects are
    /// searched again: if it is used, or if the search does not finish in time, it is not touched.
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
        if !users.isEmpty { return String(localized: "Used by: \(users.joined(separator: ", ")).", bundle: .airyCore) }
        return checked.complete ? nil : String(localized: "Could not check in time whether a project uses it.", bundle: .airyCore)
    }

    // MARK: - Commands and Trash

    /// Measures and sends to the Trash a path already validated (and confirmed unchanged by the caller).
    /// Returns the bytes measured right before moving it.
    func trashValidated(_ v: ValidatedPath) throws -> Int64 {
        let bytes = AllocatedSize.of(v.path) ?? 0
        try moveToTrash(v)
        return bytes
    }

    /// The only call to the Trash in all of Airy. It moves the entry itself: a symbolic link goes to the
    /// Trash, not its target.
    private func moveToTrash(_ v: ValidatedPath) throws {
        try FileManager.default.trashItem(at: URL(fileURLWithPath: v.path, isDirectory: false), resultingItemURL: nil)
    }

    private func runCommand(executable: String, arguments: [String], title: String,
                            context: OperationContext) async -> CleanupOutcome {
        switch await runOnce(executable: executable, arguments: arguments) {
        case .failure(let message): return .failed(message.text)
        case .success(let freed):
            record(title: title, bytes: freed, wentToTrash: false, context: context)
            return .freed(freed)
        }
    }

    /// Runs the command once; what was freed (rise in free space) or the failure message.
    private func runOnce(executable: String, arguments: [String]) async -> Result<Int64, CommandFailureMessage> {
        guard let resolved = await runner.resolve(executable) else {
            return .failure(CommandFailureMessage(String(localized: "\(executable) was not found on this Mac.", bundle: .airyCore)))
        }
        // Last barrier, with the resolved path and the final arguments, right before running.
        if let reason = CommandPolicy.refusal(executable: resolved, arguments: arguments) {
            return .failure(CommandFailureMessage(reason))
        }
        let before = freeSpace()
        let output: CommandOutput
        do {
            // Neutral directory: never the inherited one (a `yarn cache clean` inside a Berry project would empty the
            // project's cache; `go` could download another toolchain because of a go.mod).
            output = try await runner.run(resolved, arguments, stdin: nil,
                                          workingDirectory: Self.commandWorkingDirectory, timeout: commandTimeout)
        } catch {
            return .failure(CommandFailureMessage(String(describing: error)))
        }
        guard output.status == 0 else {
            let detail = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(CommandFailureMessage(
                detail.isEmpty ? String(localized: "\(executable) exited with code \(output.status)", bundle: .airyCore) : String(localized: "\(executable) exited with code \(output.status): \(detail)", bundle: .airyCore)))
        }
        return .success(max(0, freeSpace() - before))
    }

    /// Working directory of every cleanup command.
    public static let commandWorkingDirectory = "/"

    /// `{target}` substituted (exact argument) by `target`.
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
            record(title: String(localized: "Empty Trash", bundle: .airyCore), bytes: rose, wentToTrash: false, context: context)
            return .freed(rose)
        } catch {
            return .failed(String(localized: "Could not empty the Trash: \(error.localizedDescription)", bundle: .airyCore))
        }
    }

    // MARK: - Records

    /// Cleanup history (what is shown in the app).
    func record(title: String, bytes: Int64, wentToTrash: Bool, context: OperationContext) {
        do {
            try store.append(CleanupRecord(date: Date(), title: title, bytes: bytes, wentToTrash: wentToTrash,
                                           byAgent: context.isAgent))
        } catch {
            log?.reportFailure(String(localized: "could not record “\(title)” in the cleanup history (\(error.localizedDescription))", bundle: .airyCore))
        }
    }

    /// `moved`/`movedBytes`: what reached the Trash. If the operation stopped halfway, the record
    /// is `partial` with those paths and bytes (like the history) and the reason in `message`.
    func appendLog(_ context: OperationContext, action: String, itemID: String?, title: String,
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

    func appendLog(_ context: OperationContext, action: String, itemID: String?, title: String,
                           paths: [String], command: [String]?, dryRun: Bool, outcome: String, bytes: Int64,
                           message: String?) {
        // A failure stays pending in `log.takeWriteFailure()`: the app warns about it and `airy-mcp` returns it to the agent.
        try? log?.append(OperationRecord(
            runID: context.runID, date: Date(), actor: context.actor, action: action, itemID: itemID, title: title,
            paths: paths, command: command, dryRun: dryRun, outcome: outcome, bytes: bytes, message: message,
            proposedBy: context.proposedBy, proposedVia: context.proposedVia))
    }
}

/// Message of a command that failed (for `Result`).
struct CommandFailureMessage: Error, Sendable {
    let text: String
    init(_ text: String) { self.text = text }
}
