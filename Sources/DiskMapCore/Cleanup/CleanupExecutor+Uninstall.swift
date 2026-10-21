import Foundation

public struct UninstallRequest: Sendable, Equatable, Identifiable {
    public let plan: UninstallPlan
    /// `Leftover` ids.
    public let selected: Set<String>
    public var id: String { plan.id }

    public init(plan: UninstallPlan, selected: Set<String>) {
        self.plan = plan
        self.selected = selected
    }
}

public struct UninstallReport: Sendable, Equatable {
    /// `.movedToTrash(trashed)` if something went to the Trash; otherwise `.freed(freed)`; or `.blocked`/`.failed`.
    public var outcome: CleanupOutcome
    public var trashedBytes: Int64
    public var freedBytes: Int64
    /// Steps that failed without stopping the rest (localized).
    public var notes: [String]

    public init(outcome: CleanupOutcome, trashedBytes: Int64 = 0, freedBytes: Int64 = 0, notes: [String] = []) {
        self.outcome = outcome
        self.trashedBytes = trashedBytes
        self.freedBytes = freedBytes
        self.notes = notes
    }
}

extension CleanupExecutor {
    static var agentsCannotUninstall: String { String(localized: "Agents cannot uninstall apps; they can only propose it in Airy.", bundle: .airyCore) }
    static let quitTimeout: Duration = .seconds(30)
    static let launchctlTimeout: TimeInterval = 15
    static let brewTimeout: TimeInterval = 600
    static var brewUnfinishedNote: String { String(localized: "Homebrew could not finish (maybe it asked for a password).", bundle: .airyCore) }
    static var receiptCancelledNote: String { String(localized: "You cancelled the password: the install receipt stays.", bundle: .airyCore) }

    /// Uninstalls an app through the funnel. Order: every check (agent, plan, waiver, `.app`,
    /// quit, `.app` again, leftovers, cask review) and only then, in order: Homebrew (without `--zap`) →
    /// `launchctl bootout` → `.app` to the Trash → leftovers → receipts. Each `blocked` leaves everything as it was.
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

        // 1–3. Agents, plan, waiver and the `.app`.
        if context.isAgent { return finish(.blocked(reason: Self.agentsCannotUninstall)) }
        let load = settings()
        if load.isUnreadable { return finish(.blocked(reason: Self.unreadableSettingsReason)) }
        if let refusal = request.plan.refusal { return finish(.blocked(reason: refusal)) }
        let roots = appRoots ?? ProtectionWaiver.productionAppRoots(home: home)
        guard let waiver = ProtectionWaiver.uninstall(app, appRoots: roots) else {
            return finish(.blocked(reason: String(localized: "Airy cannot uninstall “\(app.name)”.", bundle: .airyCore)))
        }
        let validatedApp: ValidatedPath
        switch gate(load).validate(app.path, waiver: waiver) {
        case .failure(let refusal): return finish(.blocked(reason: refusal.reason))
        case .success(let ok): validatedApp = ok
        }

        // 4. Quit (normally, never forced).
        let quitIDs = uniqueIDs([app.bundleID] + app.helperBundleIDs)
        var open: [String] = []
        for id in quitIDs {
            guard let running = quitter.isRunning(bundleID: id) else {
                return finish(.blocked(reason: String(localized: "Could not check whether “\(app.name)” is open; Airy does not go on.", bundle: .airyCore)))
            }
            if running { open.append(id) }
        }
        for id in open {
            switch await quitter.quit(bundleID: id, timeout: Self.quitTimeout) {
            case .notRunning, .quit: continue
            case .stillRunning, .unknown:
                return finish(.blocked(
                    reason: String(localized: "“\(app.name)” is still open (maybe it is asking you to save something). Quit it and try again.", bundle: .airyCore)))
            }
        }

        // Checks after quitting, before touching anything (F6): the `.app` and each selected leftover.
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
            case .failure(let refusal): notes.append(String(localized: "Not touching \(leftover.path): \(refusal.reason)", bundle: .airyCore))
            case .success(let ok): toTrash.append((leftover, ok))
            }
        }

        // Homebrew: never `--zap` (leftovers only come from Airy's list, already validated, to the Trash). Before
        // using `brew uninstall --cask`, Airy reads what the cask would do (read-only); if there is something it cannot
        // check, or it cannot read it, the app takes the normal path: the `.app` to the Trash with the waiver.
        var brew: String?
        if let review = await reviewCask(app, gate: gateNow) {
            brew = review.brew
            if case .fallback(let reason) = review.verdict { notes.append(reason) }
        }

        // 5. Homebrew (deletes the `.app` directly, without the Trash, and runs the already reviewed cask steps).
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
                // No standard input (`/dev/null`): if it asks for a password, it fails instead of waiting.
                output = try await runner.run(brew, arguments, timeout: Self.brewTimeout)
            } catch {
                notes.append(Self.brewUnfinishedNote)
                return finish(.failed(String(localized: "Homebrew could not uninstall it: \(String(String(describing: error).prefix(300)))", bundle: .airyCore)))
            }
            guard output.status == 0 else {
                notes.append(Self.brewUnfinishedNote)
                let detail = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)
                return finish(.failed(String(localized: "Homebrew could not uninstall it: \(String(detail))", bundle: .airyCore)))
            }
            freedBytes = measured.filter { !exists($0.key) }.values.reduce(0, +)
        }

        // 6. Stop the selected login agents (only those that passed validation). After
        // Homebrew: if Homebrew fails, the app stays installed with its agents running.
        for item in toTrash where item.leftover.kind == .launchAgent {
            guard let label = item.leftover.launchLabel, !label.isEmpty else { continue }
            do {
                let output = try await runner.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"],
                                                  timeout: Self.launchctlTimeout)
                if output.status != 0 {
                    let detail = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    notes.append(String(localized: "Could not stop \(label): \(detail).", bundle: .airyCore))
                }
            } catch {
                notes.append(String(localized: "Could not stop \(label): \(String(describing: error)).", bundle: .airyCore))
            }
        }

        // 7. The `.app` to the Trash (if it is still there), checked again right before.
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
                return finish(.failed(String(localized: "Could not move \(app.path) to the Trash: \(error.localizedDescription)", bundle: .airyCore)))
            }
        }

        // 8. Selected leftovers that still exist.
        for item in toTrash where exists(item.leftover.path) {
            let path = item.leftover.path
            beforeMove?(path)
            let gateLast = gate(settings())
            if case .failure(let refusal) = gateLast.validate(path, waiver: waiver) {
                notes.append(String(localized: "Not touching \(path): \(refusal.reason)", bundle: .airyCore))
                continue
            }
            if let refusal = gateLast.confirmUnchanged(item.validated) {
                notes.append(String(localized: "Not touching \(path): \(refusal.reason)", bundle: .airyCore))
                continue
            }
            do {
                trashedBytes += try trashValidated(item.validated)
                trashed.append(path)
            } catch {
                notes.append(String(localized: "Could not move \(path) to the Trash: \(error.localizedDescription)", bundle: .airyCore))
            }
        }

        // 9. Receipts: a single password prompt.
        let receipts = selected.filter { $0.kind == .receipt }.map(\.path)
        if !receipts.isEmpty {
            let outcome = await privileged.run(
                receipts.map { ["/usr/sbin/pkgutil", "--forget", $0] },
                prompt: String(localized: "Airy needs your password to delete the install receipt of “\(app.name)”.", bundle: .airyCore))
            switch outcome {
            case .ok: break
            case .cancelled: notes.append(Self.receiptCancelledNote)
            case .failed(let reason): notes.append(String(localized: "Could not delete the install receipt: \(reason)", bundle: .airyCore))
            }
        }

        // 10. Log.
        return finish(.freed(freedBytes))
    }

    /// Cask review before using Homebrew; `nil` if the app does not come from Homebrew. `brew` is Homebrew's
    /// path only if the verdict is `.useBrew`.
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

    /// For the confirmation sheet: what Airy will do with a Homebrew app (`nil` if it does not come from Homebrew).
    /// The executor decides it again when uninstalling.
    public func caskVerdict(for app: AppRecord) async -> CaskVerdict? {
        let load = settings()
        guard app.caskToken?.isEmpty == false else { return nil }
        if load.isUnreadable { return .fallback(reason: CaskReview.unreadableReason) }
        return await reviewCask(app, gate: gate(load))?.verdict
    }

    // MARK: - Broken links

    /// Agents ⇒ `.blocked`. Calls `BrokenLinks.find` again and only acts on the ones still broken with the
    /// same target (names without "/", outside "Protect this"). If any needs privileges: a single password
    /// prompt; otherwise, the normal `find`. Result `.freed(0)`; record `"remove_broken_links"`.
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
            appendLog(context, action: "remove_broken_links", itemID: nil, title: String(localized: "Broken links", bundle: .airyCore),
                      paths: chosen.map(\.path), command: nil, dryRun: false, outcome: name, bytes: 0,
                      message: message)
            return outcome
        }
        if context.isAgent {
            return finish(.blocked(reason: String(localized: "Agents cannot remove links; only the user can, from Airy.", bundle: .airyCore)))
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
        guard !chosen.isEmpty else { return finish(.failed(String(localized: "There are no broken links left to remove.", bundle: .airyCore))) }
        let command = BrokenLinks.deleteCommand(directory: directory,
                                                names: chosen.map { ($0.path as NSString).lastPathComponent })
        if chosen.contains(where: \.needsAdmin) {
            switch await privileged.run([command], prompt: String(localized: "Airy needs your password to remove broken links from /usr/local/bin.", bundle: .airyCore)) {
            case .ok: return finish(.freed(0))
            case .cancelled: return finish(.blocked(reason: String(localized: "You cancelled the password: the links stay.", bundle: .airyCore)))
            case .failed(let reason): return finish(.failed(String(localized: "Could not remove the links: \(reason)", bundle: .airyCore)))
            }
        }
        do {
            let output = try await runner.run(command[0], Array(command.dropFirst()), timeout: 30)
            guard output.status == 0 else {
                let detail = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)
                return finish(.failed(String(localized: "Could not remove the links: \(String(detail))", bundle: .airyCore)))
            }
        } catch {
                return finish(.failed(String(localized: "Could not remove the links: \(String(describing: error))", bundle: .airyCore)))
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
